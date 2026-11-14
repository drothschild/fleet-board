#!/bin/bash
# The merger after a merge holds the merge lane and counts toward limits.concurrency (card 259).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-merger-hold.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import time
import unittest
from pathlib import Path

PLUGIN, BASE = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(PLUGIN) / 'fixtures' / 'supervisor'))
sys.argv = [sys.argv[0], BASE]
from merging_cases import MergeCase  # noqa: E402
import loop_cases as lc  # noqa: E402
from supervisor.state import Action  # noqa: E402


def role_action(card, name, provider='claude'):
    # disjoint paths: the scope check must not be what holds another card's merge
    return Action(card=card, action=name, column='merging', role='merger', provider=provider, paths=['zz%d' % card],
                  started_at=time.time(), started_mono=time.monotonic(), kind='role')


class MergerHold(MergeCase):
    def merger_sessions(self):
        """begin_merger starts a (fake) merger session: an active after_merge action for the card."""
        def begin(card, mode, detail):
            self.mergers.append((card, mode, detail))
            self.b.state.begin(role_action(card, 'after_merge'))
        self.b.driver.begin_merger = begin

    def test_a_loop_merges_card_b_only_after_card_a_merger_session_ends(self):
        self.merger_sessions()
        self.add_card(13, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': lc.BRANCH[13],
                         'worktree': self.b.worktree, 'last_review': lc.dc.LAST_REVIEW}, 13)
        self.merge_cards = [12, 13]
        self.start()
        self.until(lambda: self.mergers, what="card A's merger to start")
        first = self.mergers[0][0]
        self.cycles_done(4)
        self.assertEqual(len(self.spawns()), 1, "card B's merge must wait for A's merger session")
        self.assertEqual(len(self.mergers), 1)
        self.assertIn(first, self.b.state.active)
        self.b.state.end(first)
        self.until(lambda: len(self.spawns()) == 2, what="card B's merge after A's merger ended")
        spawned = ' '.join(args for _, args in self.spawns())
        self.assertIn('--card 12 ', spawned)
        self.assertIn('--card 13 ', spawned)

    def test_a_merge_with_no_after_merge_steps_frees_the_lane_and_the_next_merge_starts(self):
        del self.b.driver.begin_merger      # the driver's own flow: the default persona skips the session
        self.add_card(13, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': lc.BRANCH[13],
                         'worktree': self.b.worktree, 'last_review': lc.dc.LAST_REVIEW}, 13)
        self.merge_cards = [12, 13]
        self.start()
        self.until(lambda: len(self.spawns()) == 2, what="card B's merge after A's skipped merger")
        self.assertEqual(self.b.note(12)['merger'], {'mode': 'after_merge', 'status': 'done', 'head': 'abc1234'})
        self.assertNotIn(12, self.b.state.active)
        self.assertEqual(self.b.fake_calls(), [])

    def test_a_loop_counts_a_running_merger_toward_limits_concurrency(self):
        self.merger_sessions()
        self.hold.write_text('')                          # the merge child keeps running
        self.b.state.begin(role_action(99, 'review'))     # concurrency is 2: one slot used, the merge fits
        self.start()
        self.spawned(1)
        self.b.state.begin(role_action(98, 'review'))     # the cap is now full when the merge ends
        self.hold.unlink()
        self.until(lambda: any(e['type'] == 'merge_merged' for e in self.b.state.events), what='the merge to end')
        self.cycles_done(2)
        self.assertEqual(self.mergers, [], 'a merger must not start beyond limits.concurrency')
        self.assertLessEqual(len(self.b.state.active), 2)
        self.assertTrue(any(e['type'] == 'merger_deferred' for e in self.b.state.events))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], 'MergerHold'])
PY
