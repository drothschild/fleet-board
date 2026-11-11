"""Deterministic, bounded admission policy for persistent supervisor jobs.

The scheduler owns policy only. Callers provide an immutable planner snapshot,
current claims, validated limits, and an atomic attempt-preparation callback.
Clock and planning are injectable so tests never wait on wall time.
"""
from concurrent.futures import ThreadPoolExecutor
import copy
import math
import threading

_ACTION_CLASS = {
    'continue_implementor': 0, 'fix': 0, 'review': 0, 'review_stage': 0,
    'start_review': 1, 'unblock': 1, 'start': 2,
}
_PRIORITY = {'high': 0, 'normal': 1, 'low': 2}


class _BoundedExecutor:
    """Thread pool with a hard bound on running plus queued submissions."""
    def __init__(self, workers, queue_limit, name):
        if type(workers) is not int or workers < 1 or type(queue_limit) is not int or queue_limit < 0:
            raise ValueError('invalid ' + name + ' capacity')
        self._pool = ThreadPoolExecutor(max_workers=workers)
        self._slots = threading.BoundedSemaphore(workers + queue_limit)
        self.name = name

    def submit(self, operation, *args, **kwargs):
        if not self._slots.acquire(blocking=False):
            raise RuntimeError(self.name + ' queue is full')
        try:
            future = self._pool.submit(operation, *args, **kwargs)
        except Exception:
            self._slots.release()
            raise
        future.add_done_callback(lambda _future: self._slots.release())
        return future

    def shutdown(self, wait=False, cancel_futures=True):
        self._pool.shutdown(wait=wait, cancel_futures=cancel_futures)


class _SystemTimerDriver:
    def __init__(self, clock):
        self.clock = clock

    def call_at(self, when, callback):
        timer = threading.Timer(max(0, when - self.clock()), callback)
        timer.daemon = True
        timer.start()
        return timer


def _scope(path):
    if not isinstance(path, str) or not path or path.startswith('/'):
        return ''
    parts = path.replace('\\', '/').split('/')
    if any(part in ('', '.', '..') for part in parts):
        return ''
    return '/'.join(parts).lower() if path.isascii() else ''


def _overlap(left, right):
    if not left or not right:
        return True
    for a in left:
        x = _scope(a)
        for b in right:
            y = _scope(b)
            if not x or not y or x == y or x.startswith(y + '/') or y.startswith(x + '/'):
                return True
    return False


class Scheduler:
    """Bounded, thread-safe admissions with fake-clock friendly timing."""
    def __init__(self, clock=None, state=None, max_workers=4, max_control_workers=2,
                 plan_queue_limit=16, control_queue_limit=16, priority_workers=2,
                 priority_queue_limit=32, timer_scheduler=None):
        self.clock = clock or __import__('time').time
        self.state = copy.deepcopy(state or {})
        self.state.setdefault('eligible_since', {})
        self.state.setdefault('rate_limit_since', {})
        self._lock = threading.RLock()
        self._cycles = threading.Semaphore(1)
        self._planning = _BoundedExecutor(max(1, int(max_workers)), plan_queue_limit, 'planning')
        self._control = _BoundedExecutor(max(1, int(max_control_workers)), control_queue_limit, 'control')
        self._priority_control = _BoundedExecutor(max(1, int(priority_workers)), priority_queue_limit, 'priority control')
        self._snapshot_control = _BoundedExecutor(1, 1, 'snapshot delivery')
        self._cycle_future = None
        self._cycle_pending = False
        self._cycle_request = None
        self._limits = None
        self._last_launch = self.state.get('last_launch_at')
        self._timer_scheduler = timer_scheduler or _SystemTimerDriver(self.clock)
        self._attempt_timers = {}

    def close(self):
        with self._lock:
            for handles in self._attempt_timers.values():
                for handle in handles:
                    _cancel_timer(handle)
            self._attempt_timers.clear()
        self._planning.shutdown(wait=False, cancel_futures=True)
        self._control.shutdown(wait=False, cancel_futures=True)
        self._priority_control.shutdown(wait=False, cancel_futures=True)
        self._snapshot_control.shutdown(wait=False, cancel_futures=True)

    def reload(self, limits):
        """Atomically install valid limits; invalid reload closes admissions."""
        try:
            _validate_limits(limits)
        except (TypeError, ValueError):
            with self._lock:
                self._limits = None
            return False
        with self._lock:
            self._limits = dict(limits)
        return True

    def plan_async(self, planner, *args, **kwargs):
        """Run a slow planner away from control operations and timers."""
        return self._planning.submit(planner, *args, **kwargs)

    def request_cycle(self, planner, on_snapshot=None, *args, **kwargs):
        """Queue one bounded planning snapshot and coalesce overlapping triggers.

        The returned Future represents the current snapshot. Extra triggers
        while it runs set one pending rerun, never a queue of stale plans.
        Snapshot delivery is dispatched on the control pool so slow planning
        cannot consume control capacity.
        """
        with self._lock:
            if self._cycle_future is not None and not self._cycle_future.done():
                self._cycle_pending = True
                return self._cycle_future
            self._cycle_request = (planner, on_snapshot, args, kwargs)
            return self._start_cycle_locked()

    def _start_cycle_locked(self):
        planner, callback, args, kwargs = self._cycle_request
        future = self._planning.submit(planner, *args, **kwargs)
        self._cycle_future = future

        def finished(done):
            try:
                snapshot = done.result()
            except Exception:
                snapshot = None
            with self._lock:
                if self._cycle_pending:
                    self._cycle_pending = False
                    self._start_cycle_locked()
            if callback is not None:
                self._deliver_snapshot(callback, snapshot)
        future.add_done_callback(finished)
        return future

    def _deliver_snapshot(self, callback, snapshot):
        """Keep cycle progress independent from saturated normal controls."""
        try:
            self._control.submit(callback, snapshot)
            return
        except RuntimeError:
            pass
        try:
            self._snapshot_control.submit(callback, snapshot)
        except RuntimeError:
            # Both bounded queues are full: deliver synchronously only as the
            # final fallback, after the coalesced-cycle state was advanced.
            callback(snapshot)

    def control_async(self, operation, *args, **kwargs):
        """Submit control work; status/cancel use reserved responsive capacity."""
        kind = kwargs.pop('kind', 'normal')
        if kind in ('status', 'cancel'):
            return self._priority_control.submit(operation, *args, **kwargs)
        if kind != 'normal':
            raise ValueError('unknown control operation kind')
        return self._control.submit(operation, *args, **kwargs)

    def watch_attempt(self, attempt, on_deadline=None, on_cancel_grace=None):
        """Independently schedule deadline and cancel-grace notifications.

        Timer callbacks run even while planning is blocked. They use a reserved
        control pool; if that bounded pool is saturated, delivery runs directly
        on the timer thread rather than dropping a cancellation signal.
        """
        if not isinstance(attempt, dict) or not isinstance(attempt.get('attempt_id'), str) or not attempt['attempt_id']:
            raise ValueError('invalid timed attempt')
        attempt_id = attempt['attempt_id']
        registrations = []
        for field, callback in (('deadline', on_deadline), ('cancel_grace_deadline', on_cancel_grace)):
            when = attempt.get(field)
            if callback is None or when is None:
                continue
            if type(when) not in (int, float) or not math.isfinite(when):
                raise ValueError('invalid attempt timer')
            snapshot = copy.deepcopy(attempt)

            def fire(callback=callback, snapshot=snapshot):
                try:
                    self._priority_control.submit(callback, copy.deepcopy(snapshot))
                except RuntimeError:
                    callback(copy.deepcopy(snapshot))

            registrations.append(self._timer_scheduler.call_at(when, fire))
        with self._lock:
            old = self._attempt_timers.pop(attempt_id, [])
            for handle in old:
                _cancel_timer(handle)
            self._attempt_timers[attempt_id] = registrations
        return len(registrations)

    def cancel_attempt_timers(self, attempt_id):
        with self._lock:
            handles = self._attempt_timers.pop(attempt_id, [])
        for handle in handles:
            _cancel_timer(handle)
        return len(handles)

    def export_state(self):
        return copy.deepcopy(self.state)

    def due_timers(self, attempts, now=None):
        """Return expired attempt deadlines and cancellation grace timers."""
        now = self.clock() if now is None else now
        due = []
        for attempt in attempts:
            deadline = attempt.get('deadline')
            grace = attempt.get('cancel_grace_deadline')
            if isinstance(deadline, (int, float)) and now >= deadline and not attempt.get('cancel_requested_at'):
                due.append({'attempt_id': attempt.get('attempt_id'), 'kind': 'deadline'})
            if isinstance(grace, (int, float)) and now >= grace:
                due.append({'attempt_id': attempt.get('attempt_id'), 'kind': 'cancel_grace'})
        return due

    def admit(self, candidates, active=None, limits=None, validate=None, prepare=None, now=None, reservations=None):
        """Select fitting candidates and optionally prepare each atomically.

        `validate(candidate)` rechecks board/head/revision immediately before
        `prepare(candidate)` claims resources and creates its durable attempt.
        A rejected candidate consumes no capacity or scope.
        """
        now = self.clock() if now is None else now
        active = [dict(item) for item in (active or [])]
        reservations = [dict(item) for item in (reservations or [])]
        limits = limits if limits is not None else self._limits
        try:
            _validate_limits(limits)
        except (TypeError, ValueError):
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [], 'stop_reason': 'invalid limits', 'state': self.export_state()}
        with self._cycles, self._lock:
            return self._admit_locked(candidates, active, limits, validate, prepare, now, reservations)

    def _admit_locked(self, candidates, active, limits, validate, prepare, now, reservations=None):
        reservations = reservations or []
        eligible, attention, waits = [], [], []
        if now >= limits.get('session_deadline', float('inf')):
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [],
                    'stop_reason': 'session deadline reached', 'state': self.export_state()}
        seen = set(self.state['eligible_since'])
        for original in candidates:
            c = dict(original)
            number = c.get('number')
            action = c.get('action')
            if action not in _ACTION_CLASS:
                attention.append({'number': number, 'reason': c.get('reason') or 'unknown workflow state; reconciliation required'})
                continue
            if c.get('priority_conflict') or c.get('priority') == 'conflict':
                attention.append({'number': number, 'reason': 'conflicting priority labels'})
                continue
            if c.get('scope_complete') is False:
                waits.append({'number': number, 'reason': 'actual scope is incomplete'})
                continue
            key = str(number)
            if key not in seen:
                self.state['eligible_since'][key] = c.get('eligible_since', now)
            # Preserve age while workflow eligibility remains continuous.
            since = self.state['eligible_since'][key]
            c['eligible_since'] = since
            priority = c.get('priority', 'normal')
            if priority not in _PRIORITY:
                attention.append({'number': number, 'reason': 'invalid priority'})
                continue
            base = _ACTION_CLASS[action] * 3 + _PRIORITY[priority]
            age = max(0, int((now - since) // max(1, limits.get('aging_seconds', 900))))
            c['_rank'] = max(0, base - age)
            eligible.append(c)
        active_numbers = {str(x.get('number', x.get('card'))) for x in active}
        # Keep unknown workflow candidates out of scheduling without disturbing claims.
        ordered = sorted(eligible, key=lambda c: (c['_rank'], c['eligible_since'], c.get('number', 0)))
        admitted = []
        occupied = list(active)
        provider_counts = {}
        for item in occupied:
            provider_counts[item.get('provider')] = provider_counts.get(item.get('provider'), 0) + 1
        last_launch = limits.get('last_launch_at', self._last_launch)
        for c in ordered:
            number = c.get('number')
            provider = c.get('provider') or c.get('model_provider') or 'default'
            if str(number) in active_numbers:
                waits.append({'number': number, 'reason': 'card already has an active claim'}); continue
            if now >= limits.get('session_deadline', float('inf')):
                return {'admitted': admitted, 'active': occupied, 'attention': attention, 'waits': waits,
                        'stop_reason': 'session deadline reached', 'state': self.export_state()}
            retry_at = limits.get('retry_at', {}).get(str(number))
            if retry_at is not None and now < retry_at:
                waits.append({'number': number, 'reason': 'retry backoff', 'until': retry_at}); continue
            rate_wait = limits.get('rate_limit_wait', {})
            rate_until = rate_wait.get(provider) if isinstance(rate_wait, dict) else rate_wait
            if rate_until is not None and now < rate_until:
                key = str(provider)
                since = self.state['rate_limit_since'].setdefault(key, now)
                cap_deadline = since + limits.get('max_rate_wait', float('inf'))
                if now >= cap_deadline:
                    attention.append({'number': number, 'reason': 'provider rate-limit wait cap reached'})
                    continue
                waits.append({'number': number, 'reason': 'provider rate limit', 'until': min(rate_until, cap_deadline)}); continue
            elif rate_until is None or now >= rate_until:
                self.state['rate_limit_since'].pop(str(provider), None)
            spacing = limits.get('min_launch_gap', 0)
            if last_launch is not None and now - last_launch < spacing:
                waits.append({'number': number, 'reason': 'launch spacing', 'until': last_launch + spacing}); continue
            if len(occupied) >= limits['global']:
                waits.append({'number': number, 'reason': 'global capacity'}); continue
            provider_cap = limits['providers'].get(provider, limits['providers'].get('*', limits['global']))
            if provider_counts.get(provider, 0) >= provider_cap:
                waits.append({'number': number, 'reason': 'provider capacity'}); continue
            if sum(str(x.get('number', x.get('card'))) == str(number) for x in occupied) >= limits.get('per_card', 1):
                waits.append({'number': number, 'reason': 'card capacity'}); continue
            paths = (c.get('declared_paths') or []) + (c.get('actual_paths') or [])
            reserved = next((x for x in reservations if str(x.get('card', x.get('number'))) != str(number)
                             and _overlap(paths, x.get('paths') or [])), None)
            if reserved:
                waits.append({'number': number, 'reason': 'scope reserved by #' + str(reserved.get('card', reserved.get('number')))})
                continue
            conflict = next((x for x in occupied if str(x.get('number', x.get('card'))) == str(number)
                             or _overlap(paths, x.get('paths') or [])), None)
            if conflict:
                waits.append({'number': number, 'reason': 'scope or card conflict'}); continue
            if validate is not None and not validate(dict(c)):
                waits.append({'number': number, 'reason': 'candidate preconditions changed'}); continue
            if prepare is not None:
                try:
                    claim = prepare(dict(c))
                except (ValueError, RuntimeError) as exc:
                    waits.append({'number': number, 'reason': str(exc)}); continue
                if claim is False or claim is None:
                    waits.append({'number': number, 'reason': 'atomic preparation rejected'}); continue
                if isinstance(claim, dict):
                    item = dict(claim)
                else:
                    item = {'number': number, 'provider': provider, 'paths': paths}
            else:
                item = {'number': number, 'provider': provider, 'paths': paths}
            item.setdefault('number', number); item.setdefault('provider', provider); item.setdefault('paths', paths)
            admitted.append(c); occupied.append(item)
            provider_counts[provider] = provider_counts.get(provider, 0) + 1
            last_launch = now
        admitted_numbers = {str(c.get('number')) for c in admitted}
        self.state['eligible_since'] = {k: v for k, v in self.state['eligible_since'].items()
                                        if k in admitted_numbers or any(str(c.get('number')) == k for c in eligible)}
        self._last_launch = last_launch
        self.state['last_launch_at'] = self._last_launch
        return {'admitted': [{k:v for k,v in c.items() if not k.startswith('_')} for c in admitted],
                'active': occupied, 'attention': attention, 'waits': waits, 'stop_reason': None,
                'state': self.export_state()}


def _cancel_timer(handle):
    cancel = getattr(handle, 'cancel', None)
    if callable(cancel):
        cancel()
    elif isinstance(handle, dict):
        handle['cancelled'] = True


def _validate_limits(limits):
    if not isinstance(limits, dict):
        raise ValueError('limits must be an object')
    for key in ('global',):
        if type(limits.get(key)) is not int or limits[key] < 1:
            raise ValueError('invalid global cap')
    if not isinstance(limits.get('providers'), dict) or any(type(v) is not int or v < 1 for v in limits['providers'].values()):
        raise ValueError('invalid provider caps')
    if type(limits.get('per_card', 1)) is not int or limits.get('per_card', 1) < 1:
        raise ValueError('invalid card cap')
    for key in ('aging_seconds', 'min_launch_gap', 'max_rate_wait'):
        if key in limits and (type(limits[key]) not in (int, float) or limits[key] < 0):
            raise ValueError('invalid ' + key)
    for key in ('session_deadline',):
        if key in limits and limits[key] is not None and (type(limits[key]) not in (int, float) or limits[key] < 0):
            raise ValueError('invalid ' + key)
    if 'retry_at' in limits and not isinstance(limits['retry_at'], dict):
        raise ValueError('invalid retry schedule')
    rate_wait = limits.get('rate_limit_wait', {})
    if isinstance(rate_wait, dict):
        values = rate_wait.values()
    else:
        values = (rate_wait,)
    if any(type(value) not in (int, float) or value < 0 for value in values):
        raise ValueError('invalid rate-limit wait')
