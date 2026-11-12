"""The supervisor loop: one thread that reads the board, admits actions, drives cards, polls role
sessions and answers control commands.

Each cycle reloads the config (an invalid one pauses; running sessions carry on), honours a provider
rate limit, fetches the candidates, annotates them, asks the scheduler which to admit and hands each to
the card driver. Between cycles the loop polls every session without blocking and reconciles the ones that
ended. The service thread never touches the loop's work: `stop` flips State.mode to "stopping" at once,
`pause` and `resume` are queued for the loop (the service waits a bounded time for the answer).
"""
import calendar
import json
import queue
import re
import signal
import tempfile
import threading
import time
from pathlib import Path

from . import candidates, errors, merging, resolver, scopes, scripts, usage
from .state import DUPLICATE_ADMISSION

STOP_MODES = ('drain', 'cancel')
CARD_LIMIT_WAIT = 'card token limit reached'
BACKOFF_CAP = 3600
POLL = 0.1            # seconds between session polls while any session runs
COMMAND_WAIT = 0.5    # how long the service thread waits for the loop to apply pause or resume
_NAME = re.compile(r'[a-z][a-z0-9_]*')


def config_loader(root, run=scripts.run):
    """A callable returning the merged config for `root`; it raises ValueError(first problem) when invalid."""
    def load():
        result = run(root, 'config.sh', '--dir', str(root), timeout=30)
        if result.timed_out:
            raise ValueError('config.sh timed out')
        if result.rc != 0:
            lines = [line.strip() for line in (result.stderr or '').splitlines() if line.strip()]
            raise ValueError(lines[0] if lines else 'config.sh exited %d' % result.rc)
        try:
            data = json.loads(result.stdout)
        except ValueError:
            raise ValueError('config.sh printed invalid JSON') from None
        if not isinstance(data, dict):
            raise ValueError('config.sh printed no configuration')
        return data
    return load


def _clean(value):
    return re.sub(r'[\x00-\x1f\x7f]', ' ', str(value))[:300]


def _iso(seconds):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(seconds))


class Supervisor:
    def __init__(self, root, *, config_loader, state, driver, scheduler, fetch=candidates.fetch,
                 clock=time.time, mono=time.monotonic, run=scripts.run, merge_lane=None):
        self.root = Path(root)
        self.config_loader = config_loader
        self.state = state
        self.driver = driver
        self.scheduler = scheduler
        self.fetch = fetch
        self.clock = clock
        self.mono = mono
        self.run_script = run
        self.merge_lane = merge_lane or merging.MergeLane(self.root, state, run=run, clock=clock, repo=self._repo)
        self.config = None
        self.last_cycle = {}
        self.command_wait = COMMAND_WAIT
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._inbox = queue.Queue()
        self._want_cycle = True
        self._next_cycle = 0.0
        self._started = None
        self._stop_mode = None
        self._sigints = 0
        self._force = False
        self._cancel_sent = False
        self._force_sent = False
        self._cancelled = {}
        self._config_error = None
        self._hold_until = None
        self._rate_since = None
        self._last_errors = {}
        self._last_attention = None
        self._warned = set()       # planner warnings already recorded (one that goes away may return)
        self._sched_pause = None   # the pause reason set because the scheduler reported a stop_reason

    # --- the service's side --------------------------------------------------------------------------
    def wake(self, reason='wake'):
        """Ask for a cycle now (a session ended, a command arrived, the config or the board changed)."""
        self._want_cycle = True
        self._wake.set()

    def request_stop(self, mode, force=False):
        """Enter the stopping mode at once. `cancel` sticks (a drain never downgrades it); `force` skips the
        grace period. Returns the effective stop mode."""
        if mode not in STOP_MODES:
            raise errors.Invalid('stop mode must be drain or cancel')
        with self._lock:
            if self._stop_mode != 'cancel':
                self._stop_mode = mode
            if force:
                self._stop_mode = 'cancel'
                self._force = True
            effective = self._stop_mode
        self.state.stop()
        self._wake.set()
        return effective

    def on_signal(self, signum, _frame=None):
        """SIGINT, SIGTERM and SIGHUP cancel; a second SIGINT also skips the grace period.

        Runs between two bytecodes of the main thread, so it takes no non-reentrant lock (no Event.set, no
        self._lock): it sets plain flags and flips the State (an RLock). The loop acts on them within its
        bounded wait (at most a second)."""
        self._stop_mode = 'cancel'
        if signum == signal.SIGINT:
            self._sigints += 1
            if self._sigints >= 2:
                self._force = True
        self.state.stop()

    def handle(self, command):
        """The service's handler. stop applies now; pause and resume are applied by the loop."""
        name = command.get('command')
        if name == 'status':
            return self.state.snapshot()
        if name == 'usage':
            return self._usage(command.get('card'))
        if name == 'stop':
            mode = command.get('mode')
            if mode not in STOP_MODES:
                raise errors.Invalid('stop mode must be drain or cancel')
            return {'stopping': True, 'mode': self.request_stop(mode)}
        if name not in ('pause', 'resume'):
            raise errors.Invalid('unsupported command')
        if self.state.mode == 'stopping':
            if name == 'resume':
                raise errors.Invalid('the supervisor is stopping: resume cannot reopen admissions')
            return {'mode': 'stopping', 'revision': self.state.revision}
        done, box = threading.Event(), {}
        self._inbox.put((command, done, box))
        self.wake('command')
        if not done.wait(self.command_wait):
            return {'mode': self.state.mode, 'revision': self.state.revision, 'queued': True}
        if 'error' in box:
            raise box['error']
        return box['result']

    def _repo(self):
        board = (self.config or {}).get('board')
        return board.get('repo') if isinstance(board, dict) else None

    def _board_dir(self):
        board = (self.config or {}).get('board')
        return (board.get('dir') if isinstance(board, dict) else None) or usage.DEFAULT_DIR

    def _usage(self, card=None):
        """Read-only view of the ledger for the `usage` command (the service thread calls this)."""
        try:
            result = usage.view(self.root, self._board_dir(), card=card, run_id=self.state.run_id)
        except ValueError as exc:
            raise errors.Invalid(str(exc)) from None
        if card is None:   # this run's figure comes from the same totals the limit uses
            result['run'] = dict(self.state.snapshot()['run_tokens'])
        return result

    # --- the loop ------------------------------------------------------------------------------------
    def run(self):
        """Run until stopped; returns the exit code. Whatever ends the loop, no session outlives it."""
        self._started = self.mono()
        try:
            while True:
                self._wake.clear()
                self._drain_commands()
                self._apply_stop()
                self._poll()
                self._poll_merge()
                self._check_max_hours()
                if self._stop_mode and not self.state.active:
                    return 0
                if not self._stop_mode and (self._want_cycle or self.mono() >= self._next_cycle):
                    try:
                        self._cycle()
                    except Exception as exc:  # noqa: BLE001 - one bad cycle must not end the supervisor
                        self._error('cycle_failed', '%s: %s' % (type(exc).__name__, exc))
                    self._next_cycle = self.mono() + self._interval()
                self._wake.wait(self._timeout())
        finally:
            self._reap()

    def _sup(self, key, default):
        value = ((self.config or {}).get('supervisor') or {}).get(key, default)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else default

    def _limit(self, key, default):
        value = ((self.config or {}).get('limits') or {}).get(key, default)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else default

    def _interval(self):
        return max(0.05, self._sup('reconcile_interval_seconds', 5))

    def _timeout(self):
        if self.state.lane is not None or any(a.session is not None for a in self.state.active.values()):
            return POLL
        return max(0.01, min(1.0, self._next_cycle - self.mono()))

    def _error(self, kind, message):
        """Record an error once per distinct message, so a persistent fault does not flood the events."""
        if self._last_errors.get(kind) != message:
            self._last_errors[kind] = message
            self.state.event(kind, message=message)

    # --- commands and stopping -----------------------------------------------------------------------
    def _drain_commands(self):
        while True:
            try:
                command, done, box = self._inbox.get_nowait()
            except queue.Empty:
                return
            try:
                if self.state.mode == 'stopping':
                    if command['command'] == 'resume':
                        raise errors.Invalid('the supervisor is stopping: resume cannot reopen admissions')
                elif command['command'] == 'pause':
                    self.state.pause(command.get('reason') or 'paused by operator')
                else:
                    self._rate_since = None
                    self.state.resume()
                box['result'] = {'mode': self.state.mode, 'revision': self.state.revision}
            except Exception as exc:  # noqa: BLE001 - handed back to the service thread
                box['error'] = exc
            self._want_cycle = True
            done.set()

    def _apply_stop(self):
        if self._stop_mode != 'cancel':
            return
        if self._force and not self._force_sent:
            self._force_sent = self._cancel_sent = True
            self._cancel_all(0)
        elif not self._cancel_sent:
            self._cancel_sent = True
            self._cancel_all(self._sup('shutdown_grace_seconds', 30))

    def _cancel_all(self, grace):
        for action in list(self.state.active.values()):
            if action.session is not None:
                self._cancelled.setdefault(action.card, action)
                action.session.cancel(grace)

    def _check_max_hours(self):
        hours = self._limit('max_hours', 0)
        if hours > 0 and not self._stop_mode and self.mono() - self._started >= hours * 3600:
            self.state.event('max_hours', hours=hours)
            self.request_stop('drain')

    def _reap(self):
        """Last resort on the way out: terminate and reconcile whatever is still running."""
        deadline = time.monotonic() + 15
        for action in list(self.state.active.values()):
            if action.session is not None:
                action.session.cancel(0)
        while time.monotonic() < deadline:
            running = [a for a in self.state.active.values() if a.session is not None]
            if not running:
                return
            for action in running:
                result = action.session.poll()
                if result is None:
                    continue
                try:
                    self.driver.finish(action, result, allow_redispatch=False)
                except Exception:  # noqa: BLE001
                    pass
                if action.card in self.state.active:
                    self.state.end(action.card)
                self.state.release(action.card)
            time.sleep(0.05)

    # --- sessions ------------------------------------------------------------------------------------
    def _poll(self):
        for action in list(self.state.active.values()):
            session = action.session
            if session is None:
                continue
            result = session.poll()
            if result is not None:
                self._ended(action, result)

    def _ended(self, action, result):
        card = action.card
        raised = False
        try:
            outcome = self.driver.finish(action, result,
                                         allow_redispatch=self._stop_mode is None and self.state.mode != 'stopping')
        except Exception as exc:  # noqa: BLE001 - the driver released the card; report, count and carry on
            self._count_exception(card, action.action, exc)
            outcome = None
            raised = True
        if outcome is not None and outcome.redispatch:
            return
        if card in self.state.active:
            self.state.end(card)
        self.state.release(card)
        if card in self._cancelled and result.cancelled:
            self._note_cancelled(self._cancelled.pop(card))
        elif outcome is not None and outcome.provider_failure:
            self._provider_failed(outcome.provider_failure, result.reason)
        elif result.failure != 'provider':
            self.state.clear_health(action.provider)
        if not raised:   # a finish that raised waits for the timer, like any other failed action
            self.wake('session ended')

    # --- the merge lane ------------------------------------------------------------------------------
    def _poll_merge(self):
        try:
            outcome = self.merge_lane.poll()
        except Exception as exc:  # noqa: BLE001 - the lane cannot say how the merge ended
            self.state.pause('merge lane failed: %s' % _clean(exc))
            return
        if outcome is not None:
            self._merge_ended(outcome)

    def _merge_ended(self, outcome):
        """merged and refused go to the merger session; not_attempted (the script's fresh plan skipped the card)
        leaves it in merging to be planned again; anything else pauses the board. While stopping the merger
        is deferred: the planner plans after_merge / merge_refusal for the card on the next run."""
        card, kind, detail = outcome
        self.state.release(card)
        self.state.event('merge_' + kind, card=card, reason=detail.get('reason'))
        if kind == 'verify_failed':
            self.state.pause('main verification failed after merging #%d' % card)
            return
        if kind == 'unclear':
            self.state.pause('merge result unclear for #%d: %s' % (card, _clean(detail.get('reason'))))
            return
        if kind == 'not_attempted':   # nothing merged: no pause, the card stays in merging and is re-planned
            self.wake('merge not attempted')
            return
        if kind == 'merged':
            try:
                self.driver.record_ignored_checks(card, detail.get('ignored_checks'))
            except Exception as exc:  # noqa: BLE001 - a malformed entry or a failed note write must not end the loop
                self.state.event('ignored_checks_failed', card=card, message=_clean(exc))
        if self._stop_mode or self.state.mode == 'stopping':
            self.state.event('merger_deferred', card=card, mode=kind, message='stopping')
        else:
            try:
                self.driver.begin_merger(card, kind, detail)
            except Exception as exc:  # noqa: BLE001
                self._count_exception(card, 'merger', exc)
        self.wake('merge ended')

    def _count_exception(self, card, action_name, exc):
        """An exception that escaped the driver is one no-progress failure of the card (best effort)."""
        first = (str(exc).splitlines() or [''])[0]
        message = re.sub(r'[\x00-\x1f\x7f]', ' ', '%s: %s' % (type(exc).__name__, first)).strip()[:200]
        self.state.event('action_failed', card=card, action=action_name, error=message)
        if type(card) is not int or card <= 0:
            return
        if isinstance(exc, ValueError) and str(exc) == DUPLICATE_ADMISSION:
            return   # a second admission of a running card: the running action is not at fault
        try:
            got = self.run_script(self.root, 'note.sh', 'get', card)
            note = json.loads(got.stdout) if got.rc == 0 else None
            if not isinstance(note, dict):
                return   # an unknown count must not be overwritten
            count = note.get('action_failures')
            patch = {'action_failures': (count if type(count) is int else 0) + 1, 'last_action_error': message}
            with tempfile.TemporaryDirectory(prefix='fleet-count-') as tmp:
                path = Path(tmp) / 'patch.json'
                path.write_text(json.dumps(patch))
                done = self.run_script(self.root, 'note.sh', 'merge', card, str(path))
            if done.rc != 0:
                self.state.event('warning', card=card, message='failure not counted')
        except Exception as inner:  # noqa: BLE001
            self.state.event('warning', card=card, message='failure not counted: %s' % inner)

    def _provider_failed(self, provider, reason):
        failures = (self.state.provider_health.get(provider) or {}).get('failures', 0) + 1
        delay = min(self._sup('retry_backoff_seconds', 60) * 2 ** (failures - 1), BACKOFF_CAP)
        self.state.set_health(provider, {'until': self.clock() + delay, 'reason': reason, 'failures': failures})

    def _note_cancelled(self, action):
        """A cancelled card goes back to the column it was in when the action began."""
        card, column = action.card, action.column
        try:
            with tempfile.TemporaryDirectory(prefix='fleet-cancel-') as tmp:
                path = Path(tmp) / 'patch.json'
                path.write_text(json.dumps({'cancelled': {'action': action.action, 'at': _iso(self.clock())}}))
                noted = self.run_script(self.root, 'note.sh', 'merge', card, str(path))
            if noted.rc != 0:
                self.state.event('warning', card=card, message='cancel note not written')
            if isinstance(column, str) and _NAME.fullmatch(column):
                moved = self.run_script(self.root, 'board-move.sh', card, column)
                if moved.rc != 0:
                    self.state.event('warning', card=card, message='card not moved back to ' + column)
        except Exception as exc:  # noqa: BLE001
            self.state.event('warning', card=card, message='cancel bookkeeping failed: %s' % exc)

    # --- one cycle -----------------------------------------------------------------------------------
    def _load_config(self):
        try:
            config = self.config_loader()
            if not isinstance(config, dict):
                raise ValueError('configuration is not an object')
        except Exception as exc:  # noqa: BLE001 - any loader failure is an invalid config
            message = (str(exc).splitlines() or [''])[0][:300] or 'invalid configuration'
            previous, self._config_error = self._config_error, message
            if self.state.mode == 'running' or (self.state.mode == 'paused' and self.state.pause_reason == previous):
                if self.state.pause_reason != message:
                    self.state.pause(message)
            return None
        if self._config_error is not None:
            error, self._config_error = self._config_error, None
            if self.state.mode == 'paused' and self.state.pause_reason == error:
                self.state.resume()
        self.config = config
        return config

    def _limits(self, config):
        sup, lim = config.get('supervisor') or {}, config.get('limits') or {}
        return {'global': lim.get('concurrency', 6), 'providers': dict(sup.get('provider_concurrency') or {}),
                'per_card': 1, 'aging_seconds': sup.get('aging_seconds', 900),
                'max_rate_wait': lim.get('rate_limit_max_wait', 3600),
                'rate_limit_wait': {name: health['until'] for name, health in
                                    self.state.provider_health.items() if 'until' in health}}

    def _cycle(self):
        self._want_cycle = False
        config = self._load_config()
        if config is not None and self._sched_pause is not None and self._probe_scheduler(config):
            return
        if config is None or self.state.mode != 'running':
            return
        now = self.clock()
        if self._hold_until is not None:
            if now < self._hold_until:
                return
            self._hold_until = None
        if self._token_limit_reached():
            return
        batch = self.fetch(self.root, self.run_script, self.clock)
        if batch.error:
            self._error('fetch_failed', batch.error)
            return
        self._last_errors.pop('fetch_failed', None)
        fresh = [w for w in batch.warnings if w not in self._warned]
        self._warned = set(batch.warnings)
        for warning in fresh:
            self.state.event('planner_warning', message=_clean(warning))
        if batch.rate_limit_until is not None:
            return self._rate_limited(batch.rate_limit_until, now)
        self._rate_since = None
        capped = self._capped_cards()
        rows, limit_waits = [], []
        for original in batch.candidates:
            if not isinstance(original, dict):
                continue
            row = dict(original)
            row['provider'] = resolver.provider_for(config, row)
            if row.get('number') in capped and row['provider'] != 'scripts':
                limit_waits.append({'number': row.get('number'), 'reason': CARD_LIMIT_WAIT})
                continue
            retry = self._retry_after(row) if row.get('action') == 'merge' else None
            if retry is not None and retry > now:
                limit_waits.append({'number': row.get('number'), 'reason': 'merge retry at %s' % _iso(retry)})
                continue
            if row.get('action') == 'wait' and row.get('waiting_on'):
                row['deps_commented'] = self._deps_commented(row.get('number'))
            rows.append(row)
        active = [{'number': a.card, 'provider': a.provider, 'paths': list(a.paths)}
                  for a in list(self.state.active.values())]
        reservations = [{'card': card, 'paths': list(paths)} for card, paths in list(self.state.reservations.items())]
        result = self.scheduler.admit(rows, active=active, limits=self._limits(config), reservations=reservations,
                                      now=now, lane_free=self.state.lane is None)
        if result.get('stop_reason'):
            self._sched_pause = result['stop_reason']
            self.state.pause(result['stop_reason'])
            return
        self.last_cycle = {'admitted': [r.get('number') for r in result['admitted']],
                           'waits': result['waits'] + limit_waits, 'attention': result['attention'],
                           'ignored': result['ignored']}
        attention = sorted((a.get('number'), a.get('reason')) for a in result['attention'])
        if attention != self._last_attention:
            self._last_attention = attention
            if attention:
                self.state.event('attention', cards=[{'number': n, 'reason': r} for n, r in attention])
        for row in result['admitted']:
            # A begin can be slow: apply a pause that arrived meanwhile before launching the next row.
            self._drain_commands()
            if self.state.mode != 'running' or self._stop_mode:
                break
            self._begin(row)

    @staticmethod
    def _retry_after(row):
        """The epoch before which a merge after a merger retry is held (the row's retry_after), else None."""
        value = row.get('retry_after')
        if not isinstance(value, str):
            return None
        try:
            return float(calendar.timegm(time.strptime(value, '%Y-%m-%dT%H:%M:%SZ')))
        except ValueError:
            return None

    def _token_limit_reached(self):
        """Pause admissions once this run's known tokens reach limits.max_tokens (running sessions finish).
        Checked every cycle, so lowering the limit, or resuming without raising it, pauses again."""
        cap = self._limit('max_tokens', 0)
        total = self.state.run_tokens.get('total', 0)
        if cap <= 0 or total < cap:
            return False
        if self.state.mode == 'running':
            partial = ' (known tokens only)' if self.state.run_tokens.get('partial') else ''
            self.state.pause('token limit reached: %d of limits.max_tokens %d%s' % (total, cap, partial))
        return True

    def _capped_cards(self):
        """Cards whose known tokens in THIS run have reached limits.max_tokens_per_card (in-memory totals;
        the ledger is never read to decide anything, and an earlier run's spend does not count)."""
        cap = self._limit('max_tokens_per_card', 0)
        if cap <= 0:
            return set()
        with self.state._lock:
            return {card for card, total in self.state.card_tokens.items() if total >= cap}

    def _probe_scheduler(self, config):
        """While paused by a scheduler stop_reason: True to skip this cycle, False once the scheduler no
        longer reports one (the pause is lifted). Never flips the mode while the stop_reason persists."""
        if self.state.mode != 'paused' or self.state.pause_reason != self._sched_pause:
            self._sched_pause = None   # an operator or something else took over the pause
            return False
        probe = self.scheduler.admit([], active=[], limits=self._limits(config), reservations=[],
                                     now=self.clock(), lane_free=False)
        if probe.get('stop_reason'):
            return True
        self._sched_pause = None
        self.state.resume()
        return False

    def _rate_limited(self, until, now):
        if self._rate_since is None:
            self._rate_since = now
        if until - self._rate_since > self._limit('rate_limit_max_wait', 3600):
            self._rate_since = None
            self.state.pause('rate limit resets at %s, beyond limits.rate_limit_max_wait' % _iso(until))
            return
        until += self._limit('rate_limit_margin', 0)
        self._hold_until = until
        self.state.event('rate_limited', until=until)

    def _deps_commented(self, number):
        if type(number) is not int or number <= 0:
            return None
        try:
            result = self.run_script(self.root, 'note.sh', 'get', number)
            note = json.loads(result.stdout) if result.rc == 0 else None
        except (ValueError, OSError):
            return None
        value = note.get('deps_commented') if isinstance(note, dict) else None
        return value if isinstance(value, list) else None

    def _begin(self, row):
        number, name = row.get('number'), row.get('action')
        if name == 'merge':   # the lane keeps no reservation: the scheduler sees its paths among the active
            try:
                self.merge_lane.start(row)
            except Exception as exc:  # noqa: BLE001 - one card's failure must not stop the others
                self._count_exception(number, name, exc)
            return
        free = row.get('provider') == 'scripts' and name != 'update_branch'
        reserved = False
        if not free:
            try:
                scope = scopes.normalize(list(row.get('declared_paths') or []) + list(row.get('actual_paths') or []),
                                         self.root)
            except ValueError as exc:
                self.state.event('action_failed', card=number, action=name, error='scope: %s' % exc)
                return
            if self.state.reserve(number, scope) is not None:
                return
            reserved = True
            self.state.event('admitted', card=number, action=name, provider=row.get('provider'))
        before = self.state.events[-1]['sequence'] if self.state.events else 0
        try:
            started = self.driver.begin(row)
        except Exception as exc:  # noqa: BLE001 - one card's failure must not stop the others
            self._count_exception(number, name, exc)
            started = None
        if started is None or started.kind != 'session':
            if reserved and number not in self.state.active:
                self.state.release(number)
            # Re-plan at once only when the action changed something; a failure waits for the timer.
            if not any(e['sequence'] > before and e['type'] == 'action_failed' for e in list(self.state.events)):
                self._want_cycle = True
