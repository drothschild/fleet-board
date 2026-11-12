"""Role runner contract tests: argv, stream parsing, classification, process-group hygiene, deadlines."""
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parents[1]
sys.path.insert(0, str(PLUGIN / 'scripts'))
from supervisor import roles
from supervisor.resolver import Dispatch

FAKE = HERE / 'fake_role.py'
CONFIG = {'limits': {'max_turns': 200}, 'headless': {'permission_mode': 'auto'},
          'supervisor': {'attempt_timeout_seconds': 7200, 'progress_timeout_seconds': 900}}
IMPL = Dispatch('claude', 'fleet-board:implementor', 'claude', 'sonnet', False)


class Env:
    """A scratch dir with FAKE_ROLE_DIR, a fake repo root and a log dir."""

    def __init__(self, *plans):
        self.tmp = Path(tempfile.mkdtemp(prefix='roles-case-')).resolve()
        self.fake = self.tmp / 'fake'
        self.root = self.tmp / 'repo'
        self.logs = self.tmp / 'logs'
        for d in (self.fake, self.root, self.logs):
            d.mkdir()
        for i, plan in enumerate(plans, 1):
            (self.fake / ('%d.json' % i)).write_text(json.dumps(plan))
        self.sessions = []

    def env(self):
        e = dict(os.environ)
        e['FAKE_ROLE_DIR'] = str(self.fake)
        e['FAKE_ROLE_ROLE'] = 'implementor'
        e['FAKE_ROLE_CARD'] = '7'
        return e

    def launch(self, label='s1', argv=None, **kw):
        argv = argv or [str(FAKE), '-p', 'do it', '--agent', 'fleet-board:implementor', '--model', 'sonnet',
                        '--permission-mode', 'auto']
        s = roles.launch(argv, root=self.root, log_dir=self.logs, label=label, env=self.env(), **kw)
        self.sessions.append(s)
        return s

    def wait(self, session, limit=20):
        end = time.monotonic() + limit
        while time.monotonic() < end:
            r = session.poll()
            if r is not None:
                return r
            time.sleep(0.05)
        raise AssertionError('session did not finish')

    def child_pids(self):
        return [int(p.read_text()) for p in sorted(self.fake.glob('*.child'))]

    def close(self):
        for s in self.sessions:
            try:
                s.cancel(0.1)
            except Exception:
                pass
        for pid in self.child_pids():
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def with_plans(*plans):
    def deco(fn):
        def run():
            e = Env(*plans)
            try:
                fn(e)
            finally:
                e.close()
        run.__name__ = fn.__name__
        return run
    return deco


def test_command_line_for_each_runner():
    os.environ.pop('FLEET_BOARD_PLUGIN_DIR', None)
    os.environ['FLEET_BOARD_CLAUDE'] = '/bin/claude-x'
    try:
        argv = roles.command(IMPL, 'PROMPT', CONFIG, PLUGIN)
        assert argv == ['/bin/claude-x', '-p', 'PROMPT', '--agent', 'fleet-board:implementor', '--model', 'sonnet',
                        '--permission-mode', 'auto', '--output-format', 'stream-json', '--verbose',
                        '--max-turns', '200'], argv
        os.environ['FLEET_BOARD_PLUGIN_DIR'] = '/p/dir'
        argv = roles.command(IMPL, 'PROMPT', CONFIG, PLUGIN)
        assert argv[:7] == ['/bin/claude-x', '-p', 'PROMPT', '--agent', 'fleet-board:implementor',
                            '--plugin-dir', '/p/dir'], argv
        assert argv[7:9] == ['--model', 'sonnet'], argv
        del os.environ['FLEET_BOARD_CLAUDE']
        assert roles.command(IMPL, 'x', CONFIG, PLUGIN)[0] == 'claude'
    finally:
        os.environ.pop('FLEET_BOARD_CLAUDE', None)
        os.environ.pop('FLEET_BOARD_PLUGIN_DIR', None)
    stage = Dispatch('stage-review', None, 'codex', 'gpt-5', False)
    ev = Dispatch('evidence-review', None, 'codex', 'gpt-5', False)
    scripts = str(PLUGIN / 'scripts')
    a = roles.command(stage, 'ignored', CONFIG, PLUGIN, stage_args=['7', '12', '--stage', 'sec', '--round', '1'])
    assert a == ['bash', scripts + '/stage-review.sh', '7', '12', '--stage', 'sec', '--round', '1'], a
    a = roles.command(ev, 'ignored', CONFIG, PLUGIN, stage_args=['7', '12', '--round', '1'])
    assert a == ['bash', scripts + '/evidence-review.sh', '7', '12', '--round', '1'], a


def write_stream(tmp, events):
    p = Path(tmp) / 'x.jsonl'
    p.write_text('\n'.join(json.dumps(e) for e in events) + ('\n' if events else ''))
    return p


def test_usage_from_result_event():
    with tempfile.TemporaryDirectory() as t:
        p = write_stream(t, [
            {'type': 'system', 'subtype': 'init', 'model': 'init-model', 'permissionMode': 'auto'},
            {'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'old', 'session_id': 'old'},
            {'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'the report', 'session_id': 'sess-9',
             'usage': {'input_tokens': 11, 'output_tokens': 22, 'cache_creation_input_tokens': 33,
                       'cache_read_input_tokens': 44},
             'modelUsage': {'claude-sonnet-x': {'inputTokens': 1}}}])
        text, usage, is_error, subtype, sid, mode = roles.parse_stream(p)
        assert (text, is_error, subtype, sid, mode) == ('the report', False, 'success', 'sess-9', 'auto')
        assert usage == roles.Usage(11, 22, 33, 44, 'claude-sonnet-x'), usage
        p = write_stream(t, [
            {'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'r',
             'modelUsage': {'a': {'inputTokens': 1, 'outputTokens': 2, 'cacheCreationInputTokens': 3,
                                  'cacheReadInputTokens': 4},
                            'b': {'inputTokens': 10, 'outputTokens': 20, 'cacheCreationInputTokens': 30,
                                  'cacheReadInputTokens': 40}}}])
        usage = roles.parse_stream(p)[1]
        assert (usage.input, usage.output, usage.cache_write, usage.cache_read) == (11, 22, 33, 44), usage


def test_usage_unknown_when_absent():
    with tempfile.TemporaryDirectory() as t:
        p = write_stream(t, [{'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'r'}])
        usage = roles.parse_stream(p)[1]
        assert (usage.input, usage.output, usage.cache_write, usage.cache_read) == (None, None, None, None), usage
        assert usage.model is None
        p = write_stream(t, [])
        text, usage, is_error, subtype, sid, mode = roles.parse_stream(p)
        assert (text, subtype, sid, mode, is_error) == ('', None, None, None, False)
        assert usage.input is None
        assert roles.parse_stream(Path(t) / 'missing.jsonl')[1].input is None


def test_rate_limit_is_a_provider_failure():
    assert roles.classify(1, 'Error: 429 rate limit exceeded', False, None) == 'provider'
    assert roles.classify(0, '', True, 'API Error: Overloaded 529') == 'provider'
    assert roles.classify(1, 'Your usage limit resets at 5pm', False, None) == 'provider'
    assert roles.classify(1, 'invalid API key', False, None) == 'provider'
    assert roles.classify(0, '', False, 'fine') is None
    assert roles.classify(1, 'segfault', False, None) == 'card'
    assert roles.classify(0, 'rate limit mentioned', False, 'done') is None
    assert roles.classify(3, '', False, '', stage=True) == 'provider'
    assert roles.classify(1, 'provider: HTTP 503 after 3 attempts', False, '', stage=True) == 'provider'
    assert roles.classify(1, 'curl failed (exit 6): x', False, '', stage=True) == 'provider'
    assert roles.classify(1, 'codex: usage limit reached', False, '', stage=True) == 'provider'
    assert roles.classify(1, 'empty reply', False, '', stage=True) == 'card'
    assert roles.classify(6, 'parse-report: x', False, '', stage=True) == 'card'


@with_plans({'report': 'x', 'exit': 1, 'no_result': True, 'stderr': 'Error: 429 rate limit', 'post': False})
def test_rate_limit_session_end_to_end(e):
    r = e.wait(e.launch('a'))
    assert (r.exit_code, r.failure) == (1, 'provider'), r
    assert 'rate limit' in (r.reason or '').lower(), r


@with_plans({'report': 'Reached max turns', 'exit': 1, 'subtype': 'error_max_turns', 'is_error': True,
             'post': False})
def test_max_turns_is_a_card_failure(e):
    r = e.wait(e.launch())
    assert r.failure == 'card', r
    assert r.reason == 'error_max_turns', r
    assert roles.classify(1, '', True, 'Reached max turns (200)') == 'card'


@with_plans({'report': 'ok text', 'usage': {'input_tokens': 5, 'output_tokens': 6,
                                             'cache_creation_input_tokens': 7, 'cache_read_input_tokens': 8},
             'post': False})
def test_successful_session_result(e):
    r = e.wait(e.launch())
    assert (r.exit_code, r.failure, r.report_text, r.timed_out, r.cancelled) == (0, None, 'ok text', False, False), r
    assert r.usage.input == 5 and r.usage.cache_read == 8 and r.usage.model == 'sonnet', r.usage
    assert r.session_id == 'fake-1', r
    assert r.log_path == str(e.logs / 's1.jsonl'), r


@with_plans({'report': 'r', 'sleep': 60, 'ignore_term': True, 'post': False})
def test_cancel_kills_the_group_after_grace(e):
    s = e.launch()
    time.sleep(0.5)
    t0 = time.monotonic()
    s.cancel(0.6)
    assert time.monotonic() - t0 < 0.2, 'cancel must not block'
    r = e.wait(s, limit=10)
    dt = time.monotonic() - t0
    assert dt >= 0.5, dt
    assert not alive(s.pid)
    assert r.cancelled and not r.timed_out, r
    s.cancel(0.1)
    s.cancel(0.1)


@with_plans({'report': 'r', 'spawn_child': True, 'child_ignore_term': True, 'post': False})
def test_poll_never_blocks(e):
    s = e.launch(kill_grace=1.0)
    r, worst = None, 0.0
    end = time.monotonic() + 15
    while r is None and time.monotonic() < end:
        t0 = time.monotonic()
        r = s.poll()
        worst = max(worst, time.monotonic() - t0)
        time.sleep(0.05)
    assert r is not None and r.exit_code == 0, r
    assert worst < 0.2, worst
    assert not alive(e.child_pids()[0])


@with_plans({'report': 'r', 'post': False})
def test_cancel_after_exit_is_safe(e):
    s = e.launch()
    r = e.wait(s)
    s.cancel(0.1)
    s.cancel(0.1)
    assert s.poll() == r


@with_plans({'report': 'r', 'spawn_child': True, 'post': False})
def test_children_of_a_finished_session_are_killed(e):
    s = e.launch()
    r = e.wait(s)
    assert r.exit_code == 0, r
    pids = e.child_pids()
    assert len(pids) == 1, pids
    assert not alive(pids[0]), 'child survived its session'


@with_plans({'report': 'r', 'sleep': 60, 'post': False})
def test_progress_timeout_ends_a_silent_session(e):
    s = e.launch(progress_timeout=1.0, attempt_timeout=600, kill_grace=0.5)
    r = e.wait(s, limit=15)
    assert r.timed_out and r.failure == 'card', r
    assert 'progress' in (r.reason or ''), r
    assert not alive(s.pid)


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


@with_plans({'report': 'r', 'sleep': 60, 'post': False})
def test_deadlines_use_the_monotonic_clock(e):
    clock = FakeClock()
    real_time = time.time
    try:
        s = e.launch(progress_timeout=100, attempt_timeout=300, kill_grace=0.5, clock=clock)
        time.sleep(0.5)
        time.time = lambda: real_time() + 10 ** 7
        assert s.poll() is None
        clock.now += 50
        assert s.poll() is None
        clock.now += 60
        r = None
        end = time.monotonic() + 10
        while r is None and time.monotonic() < end:
            r = s.poll()
            time.sleep(0.05)
        assert r is not None and r.timed_out and r.failure == 'card', r
    finally:
        time.time = real_time


@with_plans({'report': 'r', 'sleep': 60, 'post': False})
def test_attempt_timeout_is_absolute(e):
    clock = FakeClock()
    s = e.launch(progress_timeout=10 ** 6, attempt_timeout=300, kill_grace=0.5, clock=clock)
    time.sleep(0.3)
    assert s.poll() is None
    clock.now += 301
    r = None
    end = time.monotonic() + 10
    while r is None and time.monotonic() < end:
        r = s.poll()
        time.sleep(0.05)
    assert r is not None and r.timed_out and 'attempt' in r.reason, r


@with_plans({'report': 'r', 'sleep': 60, 'permission_mode': 'bypassPermissions', 'post': False})
def test_permission_mode_mismatch_is_cancelled(e):
    s = e.launch(permission_mode='auto', kill_grace=0.5)
    r = e.wait(s)
    assert r.failure == 'card' and r.reason == 'permission-mode-mismatch' and not r.cancelled, r
    assert not alive(s.pid)


@with_plans({'report': 'r', 'post': False})
def test_logs_are_0600(e):
    e.wait(e.launch())
    for suffix in ('jsonl', 'err'):
        mode = os.stat(str(e.logs / ('s1.' + suffix))).st_mode & 0o777
        assert mode == 0o600, (suffix, oct(mode))


@with_plans({'report': 'r', 'post': False})
def test_cwd_is_the_repo_root(e):
    e.wait(e.launch())
    rec = json.loads((e.fake / 'log.jsonl').read_text().splitlines()[0])
    assert rec['cwd'] == str(e.root), rec
    assert rec['argv'][:2] == ['-p', 'do it'], rec


@with_plans({'report': 'r', 'sleep': 60, 'permission_mode': 'bypassPermissions', 'post': False,
             'pre_events': [{'type': 'system', 'subtype': 'hook_started', 'hook': 'SessionStart'}]})
def test_mismatch_is_found_after_a_non_init_event(e):
    s = e.launch(permission_mode='auto', kill_grace=0.5)
    r = e.wait(s)
    assert r.failure == 'card' and r.reason == 'permission-mode-mismatch' and not r.cancelled, r


@with_plans({'report': 'fine', 'permission_mode': 'bypassPermissions', 'post': False})
def test_fast_exiting_mismatch_is_not_success(e):
    r = e.wait(e.launch(permission_mode='auto'))
    assert r.failure == 'card' and r.reason == 'permission-mode-mismatch', r


@with_plans({'report': 'fine', 'no_init': True, 'post': False})
def test_missing_init_fails_closed(e):
    r = e.wait(e.launch(permission_mode='auto'))
    assert r.failure == 'card' and r.reason == 'permission-mode-mismatch', r
    r = Env({'report': 'fine', 'no_init': True, 'post': False})
    try:
        ok = r.wait(r.launch('nomode'))      # no mode requested: nothing to verify
        assert ok.failure is None, ok
    finally:
        r.close()


STAGE_CODE = ('import sys, time\n'
              'for i in range(4):\n'
              '    sys.stderr.write("working %d\\n" % i); sys.stderr.flush(); time.sleep(0.6)\n'
              'print(\'{"input_tokens": 3, "output_tokens": 4}\')\n')


def test_progress_counts_stderr_growth_for_stage_scripts():
    e = Env()
    try:
        s = e.launch(argv=[sys.executable, '-c', STAGE_CODE], stage=True, progress_timeout=1.2, kill_grace=0.5)
        r = e.wait(s)
        assert not r.timed_out and r.failure is None and r.exit_code == 0, r
        assert r.usage.input == 3 and r.usage.output == 4, r
    finally:
        e.close()


def test_max_turns_subtype_is_always_a_card_failure():
    assert roles.classify(1, 'rate limit 429', True, 'rate limit 429', subtype='error_max_turns') == 'card'
    assert roles.classify(1, 'rate limit 429', True, 'rate limit 429', subtype='success') == 'provider'


def test_missing_binary_is_a_provider_failure():
    e = Env()
    try:
        s = e.launch(argv=[str(e.tmp / 'no-such-claude'), '-p', 'x'])
        r = s.poll()
        assert r is not None and r.failure == 'provider' and 'not found' in r.reason, r
    finally:
        e.close()


def test_non_executable_binary_is_a_provider_failure():
    e = Env()
    try:
        path = e.tmp / 'claude-no-exec'
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o644)
        s = e.launch(argv=[str(path), '-p', 'x'])
        r = s.poll()
        assert r is not None and r.failure == 'provider' and not r.cancelled, r
    finally:
        e.close()


@with_plans({'report': 'implementor-ok.md', 'post': True})
def test_fake_role_runs_the_real_report_check(e):
    r = e.wait(e.launch())
    rec = json.loads((e.fake / 'log.jsonl').read_text().splitlines()[0])
    assert rec['parse_rc'] == 0, rec
    assert 'Added subtract' in r.report_text, r


@with_plans({'report': 'findings-empty.md', 'post': True})
def test_fake_role_does_not_post_a_rejected_report(e):
    e.wait(e.launch())
    rec = json.loads((e.fake / 'log.jsonl').read_text().splitlines()[0])
    assert rec['parse_rc'] == 1 and rec['comment_rc'] is None, rec


if __name__ == '__main__':
    names = sorted(n for n in dir() if n.startswith('test_'))
    for n in names:
        globals()[n]()
    print('ok - %d role cases' % len(names))
