#!/bin/bash
# A clean drain or cancel must not leave stuck cards (card 256).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-clean-drain.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$tmp" <<'PY'
import os
import select
import subprocess
import sys
import unittest

PLUGIN = os.environ['PLUGIN_DIR'] if 'PLUGIN_DIR' in os.environ else None
BASE = sys.argv[-1]
here = os.path.join(os.environ['PYTHONPATH'], '..', 'fixtures', 'supervisor')
sys.path.insert(0, here)
import loop_cases as lc  # noqa: E402  (pops the base dir off argv)
import driver_cases as dc  # noqa: E402
from supervisor import stuck  # noqa: E402

SCRIPTS = os.path.join(os.environ['PYTHONPATH'], 'supervisor.sh')


def start_exits_clean(case):
    """`supervisor start` against the board: it must acknowledge readiness (not refuse with exit 4)."""
    sock = os.environ['FLEET_BOARD_SOCKET_DIR']
    logs = str(case.dir / 'logs')
    os.makedirs(logs, mode=0o700, exist_ok=True)
    env = dict(os.environ, FLEET_BOARD_DOMAIN=str(case.b.root), FLEET_BOARD_SOCKET_DIR=sock,
               FLEET_BOARD_LOG_DIR=logs)
    proc = subprocess.Popen([SCRIPTS, 'start'], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([proc.stdout], [], [], 20)
        line = proc.stdout.readline() if ready else ''
        if not line:
            if proc.poll() is None:
                proc.kill()
            err = proc.stderr.read()
            if 'cannot bind' in err.lower() or 'ps call' in err.lower():
                case.skipTest('sandbox denies the supervisor socket')
            return proc.wait(), err
        subprocess.run([SCRIPTS, 'stop', '--cancel'], env=env, capture_output=True, text=True, timeout=20)
        return proc.wait(timeout=20), ''
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        for pipe in (proc.stdout, proc.stderr):
            pipe.close()


class CleanDrain(lc.LoopCase):
    def no_finding(self):
        found = [f for f in stuck.find(self.b.root, run=self.b.run) if f.card == 12]
        self.assertEqual(found, [], found)

    def test_a_drain_after_an_accepted_implementor_report_leaves_no_stuck_card_and_start_exits_0(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 3})
        self.rows = lambda: [dc.candidate('start', number=12, branch=lc.BRANCH[12], worktree=self.b.worktree,
                                          declared_paths=['a'])] if self.b.card(12)['state'] == 'ready' else []
        self.start()
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='the implementor to start')
        self.sup.handle({'command': 'stop', 'mode': 'drain'})
        self.assertEqual(self.finished(), 0)
        self.assertEqual(self.b.note(12).get('pr'), 12)
        self.no_finding()
        rc, err = start_exits_clean(self)
        self.assertEqual(rc, 0, err)

    def test_a_cancel_during_continue_implementor_leaves_no_stuck_card_and_start_exits_0(self):
        self.in_progress(12)
        self.b.plans({'report': 'implementor-ok', 'sleep': 30})
        self.rows = self.implement_plan
        self.start()
        self.until(lambda: self.b.fake_calls(1), what='the implementor to launch')
        self.sup.handle({'command': 'stop', 'mode': 'cancel'})
        self.assertEqual(self.finished(), 0)
        self.no_finding()
        rc, err = start_exits_clean(self)
        self.assertEqual(rc, 0, err)


class DriverLeavesCardInReview(unittest.TestCase):
    def test_an_accepted_implementor_report_with_a_pr_leaves_the_card_in_review(self):
        import tempfile
        base = tempfile.mkdtemp(dir=BASE)
        b = dc.board_for(base)
        started = dc.started_implementor(b)
        dc.run_role(b, started)
        self.assertEqual(b.card()['state'], 'in_review')
        self.assertEqual(b.note()['pr'], 12)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=1)
PY
