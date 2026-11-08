"""Deterministic, bounded admission policy for persistent supervisor jobs.

The scheduler owns policy only. Callers provide an immutable planner snapshot,
current claims, validated limits, and an atomic attempt-preparation callback.
Clock, planning and persistence are injectable so tests never wait on wall time.
"""
from concurrent.futures import ThreadPoolExecutor
import threading


_ACTION_CLASS = {
    'continue_implementor': 0, 'fix': 0, 'review': 0, 'review_stage': 0,
    'start_review': 1, 'unblock': 1, 'start': 2,
}
_PRIORITY = {'high': 0, 'normal': 1, 'low': 2}


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
    def __init__(self, clock=None, state=None, max_workers=4, max_control_workers=2):
        self.clock = clock or __import__('time').time
        self.state = dict(state or {})
        self.state.setdefault('eligible_since', {})
        self.state.setdefault('rate_limit_since', {})
        self._lock = threading.RLock()
        self._cycles = threading.Semaphore(1)
        self._planning = ThreadPoolExecutor(max_workers=max(1, int(max_workers)))
        self._control = ThreadPoolExecutor(max_workers=max(1, int(max_control_workers)))
        self._cycle_future = None
        self._cycle_pending = False
        self._cycle_request = None
        self._limits = None
        self._last_launch = self.state.get('last_launch_at')

    def close(self):
        self._planning.shutdown(wait=False, cancel_futures=True)
        self._control.shutdown(wait=False, cancel_futures=True)

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
            if callback is not None:
                self._control.submit(callback, snapshot)
            with self._lock:
                if self._cycle_pending:
                    self._cycle_pending = False
                    self._start_cycle_locked()
        future.add_done_callback(finished)
        return future

    def control_async(self, operation, *args, **kwargs):
        """Run bounded control work on capacity separate from planning/workers."""
        return self._control.submit(operation, *args, **kwargs)

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

    def admit(self, candidates, active=None, limits=None, validate=None, prepare=None, now=None):
        """Select fitting candidates and optionally prepare each atomically.

        `validate(candidate)` rechecks board/head/revision immediately before
        `prepare(candidate)` claims resources and creates its durable attempt.
        A rejected candidate consumes no capacity or scope.
        """
        now = self.clock() if now is None else now
        active = [dict(item) for item in (active or [])]
        limits = limits if limits is not None else self._limits
        try:
            _validate_limits(limits)
        except (TypeError, ValueError):
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [], 'stop_reason': 'invalid limits', 'state': self.state.copy()}
        with self._cycles, self._lock:
            return self._admit_locked(candidates, active, limits, validate, prepare, now)

    def _admit_locked(self, candidates, active, limits, validate, prepare, now):
        eligible, attention, waits = [], [], []
        if limits.get('unknown_spend'):
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [],
                    'stop_reason': 'provider spend is unknown', 'state': self.state.copy()}
        if now >= limits.get('session_deadline', float('inf')):
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [],
                    'stop_reason': 'session deadline reached', 'state': self.state.copy()}
        if limits.get('max_cost') is not None and limits.get('known_spend', 0) >= limits['max_cost']:
            return {'admitted': [], 'active': active, 'attention': [], 'waits': [],
                    'stop_reason': 'session cost limit reached', 'state': self.state.copy()}
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
            if limits.get('unknown_spend'):
                waits.append({'number': number, 'reason': 'provider spend is unknown'}); continue
            if now >= limits.get('session_deadline', float('inf')):
                return {'admitted': admitted, 'active': occupied, 'attention': attention, 'waits': waits,
                        'stop_reason': 'session deadline reached', 'state': self.state.copy()}
            if limits.get('max_cost') is not None and limits.get('known_spend', 0) >= limits['max_cost']:
                return {'admitted': admitted, 'active': occupied, 'attention': attention, 'waits': waits,
                        'stop_reason': 'session cost limit reached', 'state': self.state.copy()}
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
                'state': {'eligible_since': dict(self.state['eligible_since']),
                          'rate_limit_since': dict(self.state['rate_limit_since']), 'last_launch_at': self._last_launch}}


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
    for key in ('session_deadline', 'max_cost', 'known_spend'):
        if key in limits and limits[key] is not None and (type(limits[key]) not in (int, float) or limits[key] < 0):
            raise ValueError('invalid ' + key)
    if 'unknown_spend' in limits and type(limits['unknown_spend']) is not bool:
        raise ValueError('invalid unknown spend state')
    if 'retry_at' in limits and not isinstance(limits['retry_at'], dict):
        raise ValueError('invalid retry schedule')
    rate_wait = limits.get('rate_limit_wait', {})
    if isinstance(rate_wait, dict):
        values = rate_wait.values()
    else:
        values = (rate_wait,)
    if any(type(value) not in (int, float) or value < 0 for value in values):
        raise ValueError('invalid rate-limit wait')
