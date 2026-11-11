"""Script runner and candidate fetch contract tests."""
import calendar
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'scripts'))
from supervisor import candidates, scripts  # noqa: E402


def fixture_board(base, case):
    """A temp repo whose fake-gh board is the tick fixture <case>; returns (root, env)."""
    root = Path(base) / ('repo-' + case)
    root.mkdir()
    git = ['git', '-C', str(root)]
    subprocess.run(git + ['init', '-q'], check=True)
    (root / '.fleet-board.yml').write_text(
        'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nhuman_qa_paths: ["src/components/**"]\n')
    subprocess.run(git + ['add', '.fleet-board.yml'], check=True)
    subprocess.run(git + ['-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '-m', 'initial'],
                   check=True)
    bin_dir = Path(base) / ('bin-' + case)
    bin_dir.mkdir()
    (bin_dir / 'gh').symlink_to(PLUGIN / 'tests' / 'fake-gh.sh')
    tick = PLUGIN / 'fixtures' / 'gh' / 'tick'
    routes_dir = tick / case
    lines = []
    for line in (routes_dir / 'routes').read_text().splitlines():
        cols = line.split('\t')
        if len(cols) >= 3 and cols[2] != '-' and not cols[2].startswith('/'):
            cols[2] = str(routes_dir / cols[2])
        lines.append('\t'.join(cols))
    lines.append('issue list --repo acme/toy --label fleet:human_qa *\t0\t' + str(tick / 'common' / 'empty.json'))
    routes = Path(base) / ('routes-' + case)
    routes.write_text('\n'.join(lines) + '\n')
    gh_dir = Path(base) / ('ghstate-' + case)
    gh_dir.mkdir()
    env = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'], 'FAKE_GH_DIR': str(gh_dir),
           'FAKE_GH_ROUTES': str(routes)}
    sync = subprocess.run(
        ['bash', '-c', '. "$1"; store_sync "$2"; printf %s "$FLEET_BOARD_USER"', 'x',
         str(PLUGIN / 'tests' / 'store-sync.sh'), str(root)],
        env=dict(os.environ, **env), capture_output=True, text=True, check=True)
    env['FLEET_BOARD_USER'] = sync.stdout
    return root, env


def test_unlisted_script_is_refused(base):
    for name in ('rm', '../scripts/tick-plan.sh', '/bin/echo', 'tick-plan.sh/../x', 'config.sh '):
        try:
            scripts.run(Path(base), name)
        except ValueError:
            continue
        raise AssertionError('unlisted script ran: ' + name)
    assert 'tick-plan.sh' in scripts.ALLOWED and len(scripts.ALLOWED) == 18


def test_run_captures_output_and_args(base):
    d = Path(base) / 'cap'
    d.mkdir()
    result = scripts.run(d, 'config.sh', '--no-such-flag-xyz')
    assert isinstance(result, scripts.ScriptResult)
    assert result.timed_out is False
    assert isinstance(result.stdout, str) and isinstance(result.stderr, str)
    # stdin is passed through
    fake = Path(base) / 'scr'
    fake.mkdir()
    (fake / 'config.sh').write_text('#!/bin/bash\npwd -P; cat; echo "arg=$1" >&2; echo "e=$FB_X" >&2; exit 7\n')
    old = scripts.SCRIPTS_DIR
    scripts.SCRIPTS_DIR = fake
    try:
        r = scripts.run(d, 'config.sh', 'a b', stdin='hello', env={'FB_X': 'yes'})
    finally:
        scripts.SCRIPTS_DIR = old
    assert r.rc == 7 and r.stdout == os.path.realpath(d) + '\nhello', r
    assert r.stderr == 'arg=a b\ne=yes\n', r


def test_timeout_kills_the_group(base):
    fake = Path(base) / 'slow'
    fake.mkdir()
    pidfile = Path(base) / 'child.pid'
    (fake / 'deps.sh').write_text('#!/bin/bash\nsleep 300 &\necho $! > "%s"\nwait\n' % pidfile)
    old = scripts.SCRIPTS_DIR
    scripts.SCRIPTS_DIR = fake
    try:
        started = time.time()
        r = scripts.run(Path(base), 'deps.sh', timeout=1)
    finally:
        scripts.SCRIPTS_DIR = old
    assert r.timed_out is True and r.rc == 124, r
    assert time.time() - started < 20
    pid = int(pidfile.read_text())
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    os.kill(pid, 9)
    raise AssertionError('grandchild survived the timeout')


def test_fetch_parses_fixture_candidates(base):
    root, env = fixture_board(base, 'ready-start')
    run = lambda r, name, *args, **kw: scripts.run(r, name, *args, env=env, **kw)  # noqa: E731
    batch = candidates.fetch(root, run=run)
    assert batch.error is None and batch.rate_limit_until is None, batch
    assert [c['action'] for c in batch.candidates] == ['start'], batch.candidates
    assert batch.candidates[0]['number'] == 12


def fake_run(rc, stdout='', stderr=''):
    seen = []

    def run(root, name, *args, **kw):
        seen.append((name, args))
        return scripts.ScriptResult(rc, stdout, stderr, False)
    run.seen = seen
    return run


def test_rate_limit_is_detected(base):
    run = fake_run(1, stderr='tick-plan: gh: API rate limit exceeded, resets at 2026-11-11T22:00:00Z\n')
    batch = candidates.fetch(Path(base), run=run)
    assert batch.rate_limit_until == calendar.timegm((2026, 11, 11, 22, 0, 0)), batch
    assert batch.candidates == [] and batch.error is None
    assert run.seen == [('tick-plan.sh', ('--candidates',))], run.seen


def test_planner_failure_is_reported(base):
    batch = candidates.fetch(Path(base), run=fake_run(2, stderr='first\nboom: bad config\n'))
    assert batch.error == 'boom: bad config' and batch.candidates == [] and batch.rate_limit_until is None, batch
    assert candidates.fetch(Path(base), run=fake_run(0, stdout='not json')).error
    assert candidates.fetch(Path(base), run=fake_run(0, stdout='{"schema_version": 1, "candidates": []}')).error
    ok = candidates.fetch(Path(base), run=fake_run(0, stdout='{"schema_version": 2, "candidates": [{"number": 1}]}'))
    assert ok.error is None and ok.candidates == [{'number': 1}]


if __name__ == '__main__':
    base = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp()
    names = sorted(n for n in dict(globals()) if n.startswith('test_'))
    failed = 0
    for name in names:
        sub = tempfile.mkdtemp(dir=base)
        try:
            globals()[name](sub)
            print('  ok   ' + name)
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print('  FAIL %s: %r' % (name, exc))
    sys.exit(1 if failed else 0)
