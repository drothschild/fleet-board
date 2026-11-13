#!/bin/bash
# The supervisor snapshot says why each card is held (card 309).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-holds.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import calendar
import sys
import time
import unittest
from pathlib import Path

PLUGIN, BASE = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(PLUGIN) / 'fixtures' / 'supervisor'))
sys.argv = [sys.argv[0], BASE]
import driver_cases as dc  # noqa: E402
import loop_cases as lc  # noqa: E402


class Holds(lc.LoopCase):
    def holds(self):
        return self.b.state.snapshot().get('holds', {})

    def test_a_planner_wait_for_card_5_shows_its_reason_and_source_planner(self):
        reason = 'waits for #3 (ready)'
        self.rows = lambda: [dc.candidate('wait', number=5, reason=reason, state='ready', declared_paths=['p5'])]
        self.start()
        self.until(lambda: 'holds' in self.b.state.snapshot() and '5' in self.holds(), what='the planner hold')
        self.assertEqual(self.holds()['5']['reason'], reason)
        self.assertEqual(self.holds()['5']['source'], 'planner')

    def test_a_scheduler_hold_for_card_6_shows_scope_reserved_and_source_scheduler(self):
        self.b.state.reserve(4, ['pz6'])
        self.rows = lambda: [dc.candidate('start', number=6, state='ready', declared_paths=['pz6'])]
        self.start()
        self.until(lambda: '6' in self.holds(), what='the scheduler hold')
        self.assertEqual(self.holds()['6']['reason'], 'scope reserved by #4')
        self.assertEqual(self.holds()['6']['source'], 'scheduler')

    def test_a_card_7_held_for_a_merge_retry_shows_until_set_to_the_retry_time(self):
        stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(self.clock() + 3600))
        self.rows = lambda: [dc.candidate('merge', number=7, state='in_review', declared_paths=['p7'],
                                          head_sha='abc1234', pr=34, retry_after=stamp)]
        self.start()
        self.until(lambda: '7' in self.holds(), what='the retry hold')
        self.assertEqual(self.holds()['7']['until'], float(calendar.timegm(time.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ'))))
        self.assertEqual(self.holds()['7']['source'], 'limit')

    def test_a_card_admitted_in_the_next_cycle_no_longer_appears_in_holds(self):
        self.b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 6})
        self.b.state.reserve(4, ['p12'])
        # the planner no longer plans a card that is already running
        self.rows = lambda: [] if 12 in self.b.state.snapshot()['active'] else [
            dc.candidate('start', number=12, state='ready', declared_paths=['p12'])]
        self.start()
        self.until(lambda: '12' in self.holds(), what='the hold')
        self.b.state.reservations.pop(4)
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='card 12 admitted')
        self.cycles_done(2)
        self.assertNotIn('12', self.holds())


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], 'Holds'])
PY
