#!/bin/bash
# implementor.persona and implementor.persona_append: project rules added to the implementor's dispatch inputs.
# Runs against the driver_cases fixtures (a fake role session; board scripts run for real on a local store).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/implementor-persona.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc

base = sys.argv[2]


def persona_board(sub, **implementor):
    b = dc.board_for(sub)
    b.config = dict(b.config, implementor=implementor)
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
    return b


def case_with_implementor_persona_set_to_an_existing_file_the_dispatch_inputs_contain_the_files_text(sub):
    b = persona_board(sub, persona='docs/impl-rules.md')
    (b.root / 'docs').mkdir()
    (b.root / 'docs' / 'impl-rules.md').write_text('Never test documentation wording.\n')
    assert dc.begin(b, 'start').kind == 'session'
    prompt = b.prompt()
    assert 'Never test documentation wording.' in prompt, prompt


def case_with_both_keys_set_the_dispatch_inputs_contain_the_files_text_then_the_appended_text(sub):
    b = persona_board(sub, persona='docs/impl-rules.md', persona_append='Name every test after its bullet.')
    (b.root / 'docs').mkdir()
    (b.root / 'docs' / 'impl-rules.md').write_text('FILE-RULE-TEXT\n')
    assert dc.begin(b, 'start').kind == 'session'
    prompt = b.prompt()
    first, second = prompt.find('FILE-RULE-TEXT'), prompt.find('Name every test after its bullet.')
    assert 0 <= first < second, prompt


def case_with_neither_key_set_the_dispatch_inputs_are_the_same_as_before(sub):
    b = persona_board(sub)
    assert dc.begin(b, 'start').kind == 'session'
    prompt = b.prompt()
    headings = [line for line in prompt.splitlines() if line.startswith('## ')]
    assert headings == ['## Card number', '## Card title', '## Card body', '## Acceptance', '## Open cards',
                        '## Worktree', '## Branch', '## Config', '## Scripts dir'], headings


def case_with_implementor_persona_set_to_a_missing_file_the_card_gets_an_attention_and_no_session_starts(sub):
    b = persona_board(sub, persona='docs/missing-rules.md')
    started = dc.begin(b, 'start')
    assert started.kind == 'done', started.kind
    assert b.fake_calls() == [], b.fake_calls()
    reason = b.state.attention['12']['reason']
    assert 'docs/missing-rules.md' in reason, reason


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
