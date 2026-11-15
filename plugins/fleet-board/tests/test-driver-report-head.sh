#!/bin/bash
# A review re-checks a claim only from a report written at or after the reviewed head (card 410).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-report-head.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import json
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc

base = sys.argv[2]
HEAD_DATE = '2026-03-01T12:00:00Z'
REPORT_TEXT = ('## Status\ndone\n\n## Findings\n- none\n\n## For the card\nok\n\n## PR\nDraft PR #34.\n\n'
               'VERIFIED: `bash claim-marker-7.sh` -> 7 tests passed\n')


def prepare(sub, when, config=None):
    b = dc.board_for(sub, 'in_review', **({'config': config} if config else {}))
    b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': dc.BRANCH, 'worktree': b.worktree})
    card = b.card()
    card['comments'].append({'id': 50, 'author': 'fleet-bot', 'body': REPORT_TEXT, 'created_at': when})
    (b.root / '.fleet-board' / 'cards' / '12.json').write_text(json.dumps(card))
    b.gh_result = lambda *a: (dc.ok(HEAD_DATE + '\n') if a[:2] == ('pr', 'view')
                              else dc.ok('diff --git a/x b/x\n+line\n'))
    return b


def evidence(sub, when):
    b = prepare(sub, when, dc.EVIDENCE_CONFIG)
    dc.fake_plugin(b, 0, json.dumps({'status': 'posted', 'report_file': dc.report_file(b, 'reviewer-ok'),
                                     'parsed': {}, 'provider': 'codex', 'model': 'gpt-5', 'sha': 'deadbee',
                                     'input_tokens': None, 'output_tokens': None, 'attempts': 1}))
    dc.run_role(b, dc.begin(b, 'review', state='in_review', round=1))
    return b, (b.fake / 'args.txt').read_text().split('\n')


def case_a_reviewer_prompt_names_no_claim_from_a_report_that_predates_the_pr_head(sub):
    b = prepare(sub, '2026-03-01T09:00:00Z')
    dc.worktree_ok(b)
    b.plans({'report': 'reviewer-ok'})
    started = dc.begin(b, 'review', state='in_review', round=1)
    prompt = b.prompt()
    assert 'claim-marker-7' not in prompt, prompt
    assert 'predates the PR head' in prompt, prompt
    dc.run_role(b, started)


def case_a_reviewer_prompt_has_the_report_posted_after_the_pr_head(sub):
    b = prepare(sub, '2026-03-01T15:00:00Z')
    dc.worktree_ok(b)
    b.plans({'report': 'reviewer-ok'})
    started = dc.begin(b, 'review', state='in_review', round=1)
    prompt = b.prompt()
    assert 'claim-marker-7' in prompt, prompt
    assert 'predates the PR head' not in prompt, prompt
    dc.run_role(b, started)


def case_the_evidence_reviewer_gets_no_impl_report_when_the_report_predates_the_pr_head(sub):
    b, args = evidence(sub, '2026-03-01T09:00:00Z')
    assert '--impl-report' not in args, args


def case_the_evidence_reviewer_gets_the_impl_report_posted_after_the_pr_head(sub):
    b, args = evidence(sub, '2026-03-01T15:00:00Z')
    assert '--impl-report' in args, args
    assert 'claim-marker-7' in (b.fake / 'impl.txt').read_text()


def case_reviewer_md_says_a_report_that_predates_the_pr_head_gets_the_exact_skipped_line(sub):
    text = open(sys.argv[1] + '/agents/reviewer.md').read()
    assert 'predates the PR head' in text and '`skipped: the latest report predates the PR head`' in text, 'no rule'


failed = 0
for name in sorted(n for n in dict(globals()) if n.startswith('case_')):
    try:
        globals()[name](tempfile.mkdtemp(dir=base))
        print('  ok   ' + name)
    except Exception as exc:  # noqa: BLE001
        failed += 1
        print('  FAIL %s: %r' % (name, exc))
sys.exit(1 if failed else 0)
PY
