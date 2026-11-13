#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-driver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/driver_cases.py" "$tmp"

# Worktree cleanup after done (card 149): cases that use the driver_cases fixtures.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc

base = sys.argv[2]


def cleanup_board(sub, rc=0, stderr='', state='in_review'):
    b = dc.board_for(sub, state, body='plain body')
    b.stubs['cleanup-done.sh'] = (dc.ok() if rc == 0 else dc.fail_with(stderr, rc))
    return b


def case_cleanup_runs_once_after_the_done_move(sub):
    b = cleanup_board(sub)
    assert dc.begin(b, 'finish', state='in_review').kind == 'done'
    names = [c[0] for c in b.calls]
    assert names.count('cleanup-done.sh') == 1, b.calls
    assert names.index('cleanup-done.sh') > names.index('board-move.sh'), b.calls
    assert b.card()['state'] == 'done'


def case_cleanup_failure_is_a_warning_and_never_fails_the_action(sub):
    b = cleanup_board(sub, 1, 'boom')
    assert dc.begin(b, 'finish', state='in_review').kind == 'done'
    assert [c[0] for c in b.calls].count('cleanup-done.sh') == 1, b.calls
    assert b.card()['state'] == 'done' and b.note()['action_failures'] == 0
    kinds = [e['type'] for e in b.state.events]
    assert 'action_failed' not in kinds, b.state.events
    warns = [e for e in b.state.events if e['type'] == 'warning' and 'cleanup-done.sh' in e['payload']['message']]
    assert warns, b.state.events


def case_human_qa_does_not_run_cleanup(sub):
    b = cleanup_board(sub)
    dc.Path(b.worktree).mkdir(parents=True)
    assert dc.begin(b, 'to_human_qa', state='in_review').kind == 'done'
    assert b.card()['state'] == 'human_qa'
    assert 'cleanup-done.sh' not in [c[0] for c in b.calls], b.calls


failed = 0
for name, fn in sorted(globals().items()):
    if name.startswith('case_'):
        try:
            fn(tempfile.mkdtemp(dir=base))
            print('  ok   ' + name)
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print('  FAIL %s: %r' % (name, exc))
sys.exit(1 if failed else 0)
PY
