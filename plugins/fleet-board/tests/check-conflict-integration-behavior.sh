#!/usr/bin/env bash
# Check result artifacts from isolated manager/reviewer fixture exercises.
# Run each role against its instructions and fixtures, then pass the result dir.
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 1 ] || { echo 'usage: check-conflict-integration-behavior.sh <result-directory>' >&2; exit 2; }
python3 - "$HERE/../fixtures/conflict-integration/manager-scenarios.json" "$1" <<'PY'
import json
from pathlib import Path
import sys
scenarios = json.loads(Path(sys.argv[1]).read_text())
results = Path(sys.argv[2])
manager = {r['name']: r for r in json.loads((results / 'pr215-manager-behavior.json').read_text())}
assert len(manager) == len(scenarios)
for case in scenarios:
    r = manager[case['name']]
    assert r['fixer_findings'] == case['plan']['findings'], r
    assert r['review_dispatched_this_action'] is False, r
    note = {**case['note'], **r['note_patch']}
    if case['name'] == 'resolved_from_stage':
        assert r['final_state'] == 'in_review' and r['progress'] is True, r
        assert note['conflicted_files'] is None and note['last_review'] is None, r
        assert note['round'] == 1 and note['stage'] is None and note['reviewed_stages'] == [], r
        assert note['action_failures'] == 0 and note['blocked_findings'] == [], r
    elif case['name'] == 'blocked_from_review':
        assert r['final_state'] == 'blocked' and r['progress'] is True, r
        assert note['blocked_from'] == case['state'], r
        assert note['blocked_findings'] == case['plan']['findings'], r
        assert note['conflicted_files'] == case['note']['conflicted_files'], r
    else:
        assert r['final_state'] == case['state'] and r['progress'] is False, r
        assert note['action_failures'] == 2, r
        for key in ['conflicted_files', 'last_review', 'round']:
            assert note[key] == case['note'][key], r
    print('PASS manager:', case['name'])
reviewer = {r['name']: r for r in json.loads((results / 'pr215-reviewer-behavior.json').read_text())}
assert len(reviewer) == 3
for name, expected in [('candidate_1', 'Conflict-resolved'), ('candidate_2', 'Weakened'), ('candidate_3', 'Weakened')]:
    r = reviewer[name]
    assert r['classification'] == expected and r['test_passed'] is True, r
    assert r['evidence'], r
    if name == 'candidate_1':
        assert r['mutation_killed'] is True, r
    print('PASS reviewer:', name, expected)
print('8 behavioral scenarios passed')
PY
