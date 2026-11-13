#!/usr/bin/env bash
# Contract checks for conflict dispatch and the narrow reviewer exception.
# These check the written contracts; they are not behavioral agent tests.
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/../../.." "${1:-}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
spec = root / 'docs/implementation-plans/2026-09-28-fleet-board/specs'
# The manager contract checks went with the tick system (the manager agent is deleted): the supervisor's
# driver carries the conflict flow, pinned by driver_cases.py test_conflict_fix_* and test_update_branch_*.
roles = [('reviewer spec', spec / 'reviewer.md')]
if sys.argv[2] != '--spec-only':
    roles += [('reviewer agent', root / 'plugins/fleet-board/agents/reviewer.md')]
checks = {
 'reviewer': [
  ('explicit conflict classification', '**Conflict-resolved:**'),
  ('does not skip an unchanged first-parent test', 'even when the first-parent diff is empty'),
  ('reconstructs merge to verify conflict boundaries', 'reconstruct the merge'),
  ('checks both parent versions', 'both parents'),
  ('preserves all assertions', 'every test and assertion from both sides'),
  ('exception is allowed for fixer reports', "even when the latest report is the fixer's"),
  ('unrelated test edits still fail', 'outside the reconstructed conflict regions'),
  ('passing tests are required', 'the touched test file passes'),
  ('earlier weakening is not erased', 'does not excuse earlier test weakening'),
 ]
}
failed = 0
for name, path in roles:
    text = path.read_text()
    for label, needle in checks[name.split()[0]]:
        ok = needle in text
        print(('PASS ' if ok else 'FAIL ') + name + ': ' + label)
        failed += not ok
print(f'{sum(len(checks[name.split()[0]]) for name, _ in roles)} checks; {failed} failed')
sys.exit(bool(failed))
PY
