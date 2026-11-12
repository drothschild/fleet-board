"""Launch a role (a headless `claude -p --agent` session or a provider review script) and turn its output
into a RoleResult.

Every session runs in its own process group with stdin /dev/null and cwd = the repository root; the group
is signalled when the leader exits, when a deadline passes and on cancel, so nothing outlives its session.
Deadlines use the monotonic clock only. Nothing here prices tokens: unreadable usage is None, never 0.
"""
import json
import os
import re
import signal
import subprocess
import time
from collections import namedtuple
from pathlib import Path

Usage = namedtuple('Usage', 'input output cache_write cache_read model')
RoleResult = namedtuple('RoleResult', 'exit_code report_text usage failure reason session_id log_path '
                                      'timed_out cancelled')

_UNKNOWN = Usage(None, None, None, None, None)
_PROVIDER_RE = re.compile(r'rate.?limit|429|overloaded|529|authentication|invalid api key|401|usage limit|'
                          r'resets? at', re.I)
_STAGE_RE = re.compile(r'provider: HTTP (429|5\d\d)|curl failed|usage limit', re.I)
_STAGE_SCRIPTS = ('stage-review.sh', 'evidence-review.sh')
_USAGE_FIELDS = (('input_tokens', 'inputTokens'), ('output_tokens', 'outputTokens'),
                 ('cache_creation_input_tokens', 'cacheCreationInputTokens'),
                 ('cache_read_input_tokens', 'cacheReadInputTokens'))
DEFAULT_KILL_GRACE = 5.0


def command(dispatch, prompt, config, plugin_dir, stage_args=()):
    """The argv for one dispatch. `stage_args` are the provider script's arguments (card, PR, round, ...),
    which the driver knows and Dispatch does not."""
    if dispatch.runner in ('stage-review', 'evidence-review'):
        script = Path(plugin_dir) / 'scripts' / (dispatch.runner + '.sh')
        return ['bash', str(script)] + [str(a) for a in stage_args]
    argv = [os.environ.get('FLEET_BOARD_CLAUDE') or 'claude', '-p', prompt, '--agent', dispatch.agent]
    if os.environ.get('FLEET_BOARD_PLUGIN_DIR'):
        argv += ['--plugin-dir', os.environ['FLEET_BOARD_PLUGIN_DIR']]
    if dispatch.model is not None:
        argv += ['--model', dispatch.model]
    argv += ['--permission-mode', ((config or {}).get('headless') or {}).get('permission_mode') or 'auto',
             '--output-format', 'stream-json', '--verbose',
             '--max-turns', str((((config or {}).get('limits')) or {}).get('max_turns', 200))]
    return argv


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def _events(path):
    try:
        with open(str(path), 'r', errors='replace') as f:
            for line in f:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict):
                    yield ev
    except OSError:
        return


def _usage_of(result, init_model):
    usage = result.get('usage') if isinstance(result.get('usage'), dict) else {}
    mu = result.get('modelUsage') if isinstance(result.get('modelUsage'), dict) else {}
    values = []
    for key, mu_key in _USAGE_FIELDS:
        v = _int(usage.get(key))
        if v is None:
            parts = [_int(m.get(mu_key)) for m in mu.values() if isinstance(m, dict)]
            parts = [p for p in parts if p is not None]
            v = sum(parts) if parts else None
        values.append(v)
    model = next(iter(mu), None) or init_model
    return Usage(values[0], values[1], values[2], values[3], model)


def _scan(path):
    init = result = None
    for ev in _events(path):
        if ev.get('type') == 'system' and ev.get('subtype') == 'init' and init is None:
            init = ev
        elif ev.get('type') == 'result':
            result = ev
    init = init or {}
    if result is None:
        return {'has_result': False, 'text': '', 'usage': Usage(None, None, None, None, init.get('model')),
                'is_error': False, 'subtype': None, 'session_id': None,
                'permission_mode': init.get('permissionMode')}
    text = result.get('result')
    return {'has_result': True, 'text': text if isinstance(text, str) else '',
            'usage': _usage_of(result, init.get('model')), 'is_error': result.get('is_error') is True,
            'subtype': result.get('subtype'), 'session_id': result.get('session_id'),
            'permission_mode': init.get('permissionMode')}


def parse_stream(path):
    """(text, usage, is_error, subtype, session_id, permission_mode) from the last result event."""
    s = _scan(path)
    return s['text'], s['usage'], s['is_error'], s['subtype'], s['session_id'], s['permission_mode']


def classify(rc, stderr, is_error, result_text, stage=False, subtype=None):
    """None, "provider" (the account or service, retry later) or "card" (this attempt failed).
    A session that ended in error_max_turns is always a card failure, whatever its text says."""
    if subtype == 'error_max_turns':
        return 'card'
    if stage:
        if rc == 0:
            return None
        if rc == 3 or (rc == 1 and _STAGE_RE.search(stderr or '')):
            return 'provider'
        return 'card'
    if rc == 0 and not is_error:
        return None
    if (rc != 0 and result_text is None) or is_error:
        if _PROVIDER_RE.search('%s\n%s' % (stderr or '', result_text or '')):
            return 'provider'
    return 'card'


def _first_line(text, regex=None):
    lines = [ln.strip() for ln in (text or '').splitlines() if ln.strip()]
    if regex is not None:
        lines = [ln for ln in lines if regex.search(ln)] or lines
    return lines[0][:200] if lines else None


def _stage_scan(stdout_path):
    try:
        raw = Path(stdout_path).read_text(errors='replace')
    except OSError:
        raw = ''
    usage = _UNKNOWN
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            usage = Usage(_int(obj.get('input_tokens')), _int(obj.get('output_tokens')), None, None,
                          obj.get('model') if isinstance(obj.get('model'), str) else None)
    except ValueError:
        pass
    return raw.strip(), usage


class Session:
    def __init__(self, argv, proc, log, err, label, clock, attempt_timeout, progress_timeout, permission_mode,
                 kill_grace, stage):
        self.argv = list(argv)
        self.proc = proc
        self.pid = proc.pid if proc is not None else None
        self.log_path = str(log)
        self.err_path = str(err)
        self.label = label
        self._clock = clock
        self._attempt = attempt_timeout
        self._progress = progress_timeout
        self._mode = permission_mode
        self._grace = kill_grace
        self._stage = stage
        self._started = clock()
        self._last_growth = self._started
        self._size = (0, 0)
        self._pos = 0
        self._buf = b''
        self._init_found = False
        self._init_mode = None
        self._term_deadline = None   # set when SIGTERM has been sent: clock() after which SIGKILL follows
        self._killed = False
        self._give_up = None         # real-monotonic bound on waiting after SIGKILL
        self._why = None            # 'cancel' | 'attempt' | 'progress' | 'mode'
        self._result = None

    # -- process group -------------------------------------------------------------------------
    def _signal(self, sig):
        try:
            os.killpg(self.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass

    def _group_alive(self):
        try:
            os.killpg(self.pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def _advance_cleanup(self, grace):
        """One non-blocking step towards an empty process group. True once the group is gone (or SIGKILL
        was sent and a short bounded wait ran out)."""
        self.proc.poll()
        if not self._group_alive():
            return True
        if self._term_deadline is None:
            self._signal(signal.SIGTERM)
            self._term_deadline = self._clock() + max(grace, 0)
        elif not self._killed and self._clock() >= self._term_deadline:
            self._signal(signal.SIGKILL)
            self._killed = True
            self._give_up = time.monotonic() + 2
        if self._killed and time.monotonic() >= self._give_up:
            return True
        return False

    def cancel(self, grace):
        """Start terminating the process group (SIGTERM now, SIGKILL once `grace` has passed on the session
        clock) and return at once; poll() completes it. Idempotent; a no-op once the result is built. A later
        call with a shorter grace brings the SIGKILL forward (a second Ctrl-C), never pushes it back."""
        if self._result is not None or self.proc is None:
            return
        if self._why is None:
            self._why = 'cancel'
        if self._term_deadline is not None:
            self._term_deadline = min(self._term_deadline, self._clock() + max(grace, 0))
        self._advance_cleanup(grace)

    # -- observation ---------------------------------------------------------------------------
    def _check_init(self):
        """Scan for the init event (the first system/init line, whatever precedes it)."""
        if self._init_found or self._mode is None:
            return
        try:
            with open(self.log_path, 'rb') as f:
                f.seek(self._pos)
                data = f.read()
        except OSError:
            return
        self._pos += len(data)
        self._buf += data
        *lines, self._buf = self._buf.split(b'\n')
        for line in lines:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if isinstance(ev, dict) and ev.get('type') == 'system' and ev.get('subtype') == 'init':
                self._init_found = True
                self._init_mode = ev.get('permissionMode')
                return

    def _breach(self):
        self._check_init()
        if self._init_found and self._init_mode != self._mode:
            return 'mode'
        now = self._clock()
        try:
            size = (os.stat(self.log_path).st_size, os.stat(self.err_path).st_size)
        except OSError:
            size = self._size
        if size != self._size:
            self._size = size
            self._last_growth = now
        if self._attempt is not None and now - self._started >= self._attempt:
            return 'attempt'
        if self._progress is not None and now - self._last_growth >= self._progress:
            return 'progress'
        return None

    def poll(self):
        """The RoleResult once the session is over and its group is gone, else None. Never blocks: each
        call sends at most one signal and records the SIGKILL deadline."""
        if self._result is not None:
            return self._result
        if self.proc.poll() is None and self._why is None:
            self._why = self._breach()
            if self._why is None:
                return None
        if not self._advance_cleanup(self._grace):
            return None
        return self._finalize()

    def _finalize(self):
        rc = self.proc.poll()
        if rc is None:
            rc = -signal.SIGKILL
        try:
            stderr = Path(self.err_path).read_text(errors='replace')
        except OSError:
            stderr = ''
        failure = reason = None
        timed_out = self._why in ('attempt', 'progress')
        cancelled = self._why == 'cancel'   # a mode breach is a card failure, not a cancel
        if self._stage:
            text, usage = _stage_scan(self.log_path)
            sid = None
            if self._why is None:
                failure = classify(rc, stderr, False, text, stage=True)
                if failure:
                    reason = _first_line(stderr) or 'exit %s' % rc
        else:
            s = _scan(self.log_path)
            text, usage, sid = s['text'], s['usage'], s['session_id']
            if self._why is None:
                failure = classify(rc, stderr, s['is_error'], text if s['has_result'] else None,
                                   subtype=s['subtype'])
                if failure == 'provider':
                    reason = _first_line('%s\n%s' % (stderr, text), _PROVIDER_RE)
                elif failure:
                    reason = (s['subtype'] if s['is_error'] and s['subtype'] else None) or \
                        ('result is an error' if s['is_error'] else 'exit %s' % rc)
        if self._why in ('attempt', 'progress'):
            failure, reason = 'card', '%s timeout' % self._why
        elif self._why == 'mode':
            failure, reason = 'card', 'permission-mode-mismatch'
        elif self._why == 'cancel':
            reason = 'cancelled'
        elif not self._stage and self._mode is not None and s['permission_mode'] != self._mode:
            # fail closed: a requested mode that the init event did not confirm (wrong, or no init at all)
            failure, reason = 'card', 'permission-mode-mismatch'
        self._result = RoleResult(rc, text, usage, failure, reason, sid, self.log_path, timed_out, cancelled)
        return self._result


def _open_private(path):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    return fd


def launch(argv, *, root, log_dir, label, env, clock=time.monotonic, attempt_timeout=None,
           progress_timeout=None, permission_mode=None, kill_grace=DEFAULT_KILL_GRACE, stage=None):
    """Start argv in its own process group with cwd=root. stdout goes to <log_dir>/<label>.jsonl and stderr
    to <label>.err (0600). `permission_mode` is the mode the session must report in its init event.
    `stage` marks a provider script (its stdout is not stream-json); by default it is inferred from argv.
    A missing or non-executable binary, an unwritable log directory or a root that is not a directory yields a
    finished Session whose result is a provider failure."""
    if stage is None:
        stage = len(argv) > 1 and os.path.basename(str(argv[1])) in _STAGE_SCRIPTS
    log_dir = Path(log_dir)
    out_path, err_path = log_dir / (label + '.jsonl'), log_dir / (label + '.err')

    def failed(exc):
        # a missing or non-executable binary, an unwritable log dir or a bad root is the environment, not the card
        missing = isinstance(exc, FileNotFoundError) and exc.filename is not None and \
            str(exc.filename) == str(argv[0])
        session = Session(argv, None, out_path, err_path, label, clock, attempt_timeout, progress_timeout,
                          permission_mode, kill_grace, stage)
        reason = ('binary not found: %s' % exc.filename) if missing else \
            ('cannot run %s: %s' % (exc.filename or argv[0], exc.strerror or type(exc).__name__))
        session._result = RoleResult(127 if missing else 126, '', _UNKNOWN, 'provider', reason,
                                     None, str(out_path), False, False)
        return session

    out_fd = err_fd = None
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        out_fd = _open_private(out_path)
        err_fd = _open_private(err_path)
        if not Path(root).is_dir():
            raise NotADirectoryError(str(root))
        proc = subprocess.Popen([str(a) for a in argv], cwd=str(root), env=env, stdin=subprocess.DEVNULL,
                                stdout=out_fd, stderr=err_fd, start_new_session=True, close_fds=True)
    except OSError as exc:
        return failed(exc)
    finally:
        for fd in (out_fd, err_fd):
            if fd is not None:
                os.close(fd)
    return Session(argv, proc, out_path, err_path, label, clock, attempt_timeout, progress_timeout,
                   permission_mode, kill_grace, stage)
