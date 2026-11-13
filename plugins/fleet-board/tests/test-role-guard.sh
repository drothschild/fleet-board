#!/bin/bash
# The role driver flow: an implementor, reviewer or fixer session that edits the main checkout's .fleet-board.yml
# or moves its card pauses the board and sets the card's attention; a session that only posts its report does not.
# Usage: bash plugins/fleet-board/tests/test-role-guard.sh
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/role-guard.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" PLUGIN_DIR="$plugin_dir" python3 - "$tmp" <<'PY'
import os
import stat
import sys
import unittest
from pathlib import Path

PLUGIN = Path(os.environ['PLUGIN_DIR'])
BASE_ARG = sys.argv[1]
sys.path.insert(0, str(PLUGIN / 'fixtures' / 'supervisor'))
import merging_cases as mc  # noqa: E402  (pops the base directory from argv)
dc = mc.dc


class RoleGuard(unittest.TestCase):
    def setUp(self):
        self.dir = mc.BASE / self.id().rsplit('.', 1)[-1]
        self.dir.mkdir()
        self.b = dc.Board(self.dir)

    def tamper(self, command):
        """The fake role runs `command` (shell, at the start of its session) before reporting."""
        wrapper = self.dir / 'tamper-claude.sh'
        wrapper.write_text('#!/bin/bash\n%s\nexec python3 "%s" "$@"\n' % (command, dc.FAKE_ROLE))
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
        os.environ['FLEET_BOARD_CLAUDE'] = str(wrapper)

    def edit_config(self):
        self.tamper('echo "# tampered" >> "%s"' % (self.b.root / '.fleet-board.yml'))

    def move_card(self, old, new):
        card = self.b.root / '.fleet-board' / 'cards' / '12.json'
        self.tamper('sed -i.bak \'s/"state": "%s"/"state": "%s"/\' "%s"' % (old, new, card))

    def implementor(self):
        self.b.seed(12, 'ready')
        self.b.plans({'report': 'implementor-ok'})
        self.b.stubs['worktree.sh'] = dc.ok(self.b.worktree + '\n')
        return dc.begin(self.b, 'start')

    def reviewer(self):
        self.b.seed(12, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': dc.BRANCH, 'worktree': self.b.worktree})
        dc.worktree_ok(self.b)
        self.b.gh_result = dc.ok('diff --git a/x b/x\n+line\n')
        self.b.plans({'report': 'reviewer-findings'})
        return dc.begin(self.b, 'review', state='in_review', round=1)

    def fixer(self):
        self.b.seed(12, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': dc.BRANCH,
                         'worktree': self.b.worktree, 'last_review': dc.LAST_REVIEW})
        self.b.stubs['worktree.sh'] = dc.ok(self.b.worktree + '\n')
        self.b.plans({'report': 'fixer-ok'})
        return dc.begin(self.b, 'fix', state='in_review', round=1)

    def finish(self, started):
        self.assertEqual(started.kind, 'session')
        return dc.run_role(self.b, started)

    def assert_paused_on(self, needle):
        self.assertEqual(self.b.state.mode, 'paused')
        self.assertIn(needle, self.b.state.pause_reason)
        guard = self.b.note(12)['role_guard']
        self.assertEqual(guard['status'], 'attention')
        self.assertIn(needle, guard['reason'])
        events = [e for e in self.b.state.events if e['type'] == 'attention']
        self.assertTrue(any(needle in e['payload'].get('reason', '') for e in events))

    def test_an_implementor_that_edits_the_config_pauses_the_board_and_sets_attention(self):
        self.edit_config()
        started = self.implementor()
        self.finish(started)
        self.assert_paused_on('.fleet-board.yml')

    def test_a_reviewer_that_edits_the_config_pauses_the_board_and_sets_attention(self):
        self.edit_config()
        started = self.reviewer()
        self.finish(started)
        self.assert_paused_on('.fleet-board.yml')

    def test_a_fixer_that_edits_the_config_pauses_the_board_and_sets_attention(self):
        self.edit_config()
        started = self.fixer()
        self.finish(started)
        self.assert_paused_on('.fleet-board.yml')

    def test_a_fixer_that_moves_its_card_to_done_pauses_the_board_and_names_the_card_state(self):
        self.move_card('in_review', 'done')
        started = self.fixer()
        self.finish(started)
        self.assert_paused_on('card state')

    def test_an_implementor_that_only_posts_its_report_leaves_the_board_running(self):
        started = self.implementor()
        self.finish(started)
        self.assertEqual(self.b.state.mode, 'running')
        self.assertNotIn('role_guard', self.b.note(12))


if __name__ == '__main__':
    sys.argv = [sys.argv[0]]
    names = [n for n in dir(RoleGuard) if n.startswith('test_')]
    suite = unittest.TestSuite(RoleGuard(n) for n in names)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
PY
