#!/bin/bash
# The merger driver flow: a merger session that edits .fleet-board.yml, the persona file or the card's state
# pauses the board and sets the card's attention; the merger prompt carries pr_head and merge_commit.
# Usage: bash plugins/fleet-board/tests/test-merger-guard.sh
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/merger-guard.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" PLUGIN_DIR="$plugin_dir" python3 - "$tmp" <<'PY'
import json
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

MERGE_COMMIT = 'f' * 40


class MergerGuard(mc.MergerFlow):
    def setUp(self):
        super().setUp()
        self.merge_commit = MERGE_COMMIT
        inner = self.b.gh_result

        def gh(*args):
            if args[:2] == ('pr', 'view') and 'mergeCommit' in args:
                return dc.ok(json.dumps({'mergeCommit': {'oid': self.merge_commit}}))
            return inner(*args)
        self.b.gh_result = gh
        (self.b.root / '.fleet-board' / 'merger.md').write_text('# Persona\nNo steps.\n')

    def tamper(self, command):
        """The fake merger runs `command` (shell, at the start of its session) before reporting."""
        wrapper = self.dir / 'tamper-claude.sh'
        wrapper.write_text('#!/bin/bash\n%s\nexec python3 "%s" "$@"\n' % (command, dc.FAKE_ROLE))
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
        os.environ['FLEET_BOARD_CLAUDE'] = str(wrapper)

    def assert_paused_on(self, needle):
        self.assertEqual(self.b.state.mode, 'paused')
        self.assertIn(needle, self.b.state.pause_reason)
        merger = self.b.note(12)['merger']
        self.assertEqual(merger['status'], 'attention')
        self.assertIn(needle, merger['reason'])
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertTrue(any(needle in e['payload'].get('reason', '') for e in self.attention_events_all()))

    def attention_events_all(self):
        return [e for e in self.b.state.events if e['type'] == 'attention']

    def test_a_merger_that_edits_the_config_pauses_the_board_and_sets_attention(self):
        self.tamper('echo "merge:" >> "%s"' % (self.b.root / '.fleet-board.yml'))
        self.merger('merged', mc.MERGED, 'merger-after-merge-done')
        self.assert_paused_on('.fleet-board.yml')

    def test_a_merger_that_edits_the_persona_file_pauses_the_board_and_sets_attention(self):
        self.tamper('echo "run rm" >> "%s"' % (self.b.root / '.fleet-board' / 'merger.md'))
        self.merger('merged', mc.MERGED, 'merger-after-merge-done')
        self.assert_paused_on('merger.md')

    def test_a_merger_that_changes_the_card_state_pauses_the_board_and_sets_attention(self):
        card = self.b.root / '.fleet-board' / 'cards' / '12.json'
        self.tamper('sed -i.bak \'s/"state": "merging"/"state": "done"/\' "%s"' % card)
        self.merger('merged', mc.MERGED, 'merger-after-merge-done')
        self.assert_paused_on('card state')

    def test_the_merger_prompt_carries_pr_head_and_merge_commit_and_no_merged_head_label(self):
        self.merger('merged', mc.MERGED, 'merger-after-merge-done')
        prompt = self.b.prompt(1)
        self.assertIn('## PR head (pr_head)\nabc1234\n', prompt)
        self.assertIn('## Merge commit (merge_commit)\n%s\n' % MERGE_COMMIT, prompt)
        self.assertNotIn('Merged head', prompt)
        self.assertEqual(self.b.state.mode, 'running')


if __name__ == '__main__':
    sys.argv = [sys.argv[0]]
    names = [n for n in dir(MergerGuard) if n.startswith('test_') and n not in dir(mc.MergerFlow)]
    suite = unittest.TestSuite(MergerGuard(n) for n in names)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
PY
