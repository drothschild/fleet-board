#!/bin/bash
# A scheduler attention row shows in the status as a per-card attention entry (card 351).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-sched-attn.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import unittest
from pathlib import Path

PLUGIN, BASE = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(PLUGIN) / 'fixtures' / 'supervisor'))
sys.argv = [sys.argv[0], BASE]
import driver_cases as dc  # noqa: E402
import loop_cases as lc  # noqa: E402


class SchedulerAttention(lc.LoopCase):
    def test_result_attention_from_the_scheduler_becomes_a_per_card_attention_entry_in_the_status(self):
        reason = 'because'
        self.rows = lambda: [dc.candidate('bogus-action', number=8, state='ready', declared_paths=['p8'])]
        self.start()
        self.until(lambda: '8' in self.b.state.snapshot().get('attention', {}), what='the attention entry')
        self.assertEqual(self.b.state.snapshot()['attention']['8']['reason'], reason)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], 'SchedulerAttention'])
PY
