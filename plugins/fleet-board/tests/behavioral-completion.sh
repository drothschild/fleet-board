#!/usr/bin/env bash
# Paid, isolated manager test. No production board or network-backed gh calls.
# --prepare-only builds and validates fixtures without any model invocation.
# --run requires explicit user approval; one invocation, no automatic retry.
set -euo pipefail
unset CDPATH
MODE="${1:-}"
case "$MODE" in --prepare-only|--run) ;; *) echo 'usage: behavioral-completion.sh --prepare-only|--run' >&2; exit 2 ;; esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fb-completion.XXXXXX")"
printf 'evidence: %s\n' "$WORK"
mkdir "$WORK/config" "$WORK/bin" "$WORK/repo" "$WORK/reports"
cp -R "$HERE/.." "$WORK/plugin"
S="$WORK/plugin/scripts"
export FB_COMPLETION_WORK="$WORK" FLEET_BOARD_USER=completion-fixture
export FLEET_BOARD_RUN_ID=completion-fixture
unset FLEET_BOARD_CONFIG FLEET_CFG FLEET_ROOT FLEET_SCRIPTS
export PATH="$WORK/bin:$PATH"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FB_COMPLETION_WORK/gh.log"
case "$1 $2" in
  'pr view') cat "$FB_COMPLETION_WORK/pr.json" ;;
  *) printf 'unexpected gh call\n' >&2; exit 97 ;;
esac
GH
chmod +x "$WORK/bin/gh"
cat > "$WORK/pr.json" <<'JSON'
{"state":"OPEN","isDraft":true,"mergedAt":null,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS"}],"files":[{"path":"src/calc.js"}],"changedFiles":1}
JSON
cat > "$WORK/repo/.fleet-board.yml" <<'YAML'
board: {backend: local, repo: fixture/completion, dir: .board}
worktrees: {dir: .worktrees}
limits: {concurrency: 2}
merge: {policy: human}
models:
  implementor: sonnet
  reviewer: {provider: codex, model: fixture, price: {input: 0, output: 0}, timeout: 120}
  fixer: sonnet
  escalation: opus
review: {verify_claim: false, mutation: true}
YAML
cd "$WORK/repo"
git init -q
git config user.name 'Fixture'
git config user.email fixture@example.com
git add .fleet-board.yml
git commit -qm fixture
mkdir -p .board/cards
printf '1\n' > .board/next
cat > "$WORK/card.md" <<'CARD'
## Scope
- Modify `src/calc.js`
## Acceptance
- subtract(5, 2) returns 3
- subtract(2, 5) returns -3
CARD
cp "$HERE/../fixtures/reports/reviewer-ok.md" "$WORK/reports/reviewer.md"
bash "$S/parse-report.sh" --role reviewer "$WORK/reports/reviewer.md" > "$WORK/parsed.json"
for n in 1 2 3; do
  bash "$S/board-create.sh" "Review fixture $n" "$WORK/card.md" --label needs-human-qa > /dev/null
  bash "$S/board-move.sh" "$n" in_review > /dev/null
  jq -cn --argjson n "$n" '{state:"in_review",branch:("fleet/"+($n|tostring)+"-fixture"),pr:($n+100),round:1}' > "$WORK/note.json"
  bash "$S/note.sh" put "$n" "$WORK/note.json" > /dev/null
  sed "s/^#12$/#$((n+100))/" "$HERE/../fixtures/reports/implementor-ok.md" > "$WORK/impl.md"
  bash "$S/board-comment.sh" "$n" "$WORK/impl.md" > /dev/null
done
cat > "$S/evidence-review.sh" <<'REVIEW'
#!/usr/bin/env bash
set -euo pipefail
unset CDPATH
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
n="$1"
printf 'start %s\n' "$n" >> "$FB_COMPLETION_WORK/events"
touch "$FB_COMPLETION_WORK/started-$n"
if [ "$n" = 1 ]; then
  for ((i=0;i<120;i++)); do
    [ ! -f "$FB_COMPLETION_WORK/started-2" ] || break
    sleep 1
  done
  [ -f "$FB_COMPLETION_WORK/started-2" ] || printf 'timeout batch-barrier\n' >> "$FB_COMPLETION_WORK/events"
fi
if [ "$n" = 2 ]; then
  observed=false
  for ((i=0;i<120;i++)); do
    if [ -f "$FB_COMPLETION_WORK/started-3" ] \
      && bash "$S/note.sh" get 1 | jq -e '.last_review.sha=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' >/dev/null \
      && bash "$S/board-read.sh" 1 | jq -e '.state=="human_qa"' >/dev/null; then
      observed=true
      printf 'checkpoint fast-reconciled-and-refilled\n' >> "$FB_COMPLETION_WORK/events"
      break
    fi
    sleep 1
  done
  [ "$observed" = true ] || printf 'timeout batch-barrier\n' >> "$FB_COMPLETION_WORK/events"
fi
bash "$S/board-comment.sh" "$n" "$FB_COMPLETION_WORK/reports/reviewer.md" >/dev/null
printf 'finish %s\n' "$n" >> "$FB_COMPLETION_WORK/events"
jq -cn --arg file "$FB_COMPLETION_WORK/reports/reviewer.md" --slurpfile parsed "$FB_COMPLETION_WORK/parsed.json" \
 '{status:"clean",report_file:$file,parsed:$parsed[0],provider:"codex",model:"fixture",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",input_tokens:0,output_tokens:0,cost_usd:0,attempts:1}'
REVIEW
bash "$S/config.sh" --check
bash "$S/tick-plan.sh" > "$WORK/initial-plan.json"
jq -e '[.cards[].action] == ["review","review","review"]' "$WORK/initial-plan.json" > /dev/null
# Prove the event-order assertion rejects the old all-workers-finish-first order.
cat > "$WORK/check-events.py" <<'PY'
import sys
from pathlib import Path
lines=Path(sys.argv[1]).read_text().splitlines()
assert 'timeout batch-barrier' not in lines
assert max(lines.index('start 1'),lines.index('start 2')) < lines.index('finish 1')
assert lines.index('finish 1') < lines.index('start 3') < lines.index('finish 2')
assert lines.index('checkpoint fast-reconciled-and-refilled') < lines.index('finish 2')
active=set()
for line in lines:
    kind,card=line.split(' ',1)
    if kind=='start':
        assert card not in active
        active.add(card)
        assert len(active)<=2
    elif kind=='finish':
        assert card in active
        active.remove(card)
assert not active
for n in ('1','2','3'):
    assert lines.count('start '+n)==1 and lines.count('finish '+n)==1
PY
printf 'start 1\nstart 2\nfinish 1\nfinish 2\nstart 3\nfinish 3\n' > "$WORK/bad-events"
if python3 "$WORK/check-events.py" "$WORK/bad-events" > /dev/null 2>&1; then
  echo 'event assertion accepted a batch barrier' >&2; exit 1
fi
[ "$MODE" = --run ] || { echo 'offline fixture preparation passed; no paid run'; exit 0; }
AUTH_SETTINGS="${FLEET_BOARD_BARE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
[ -r "$AUTH_SETTINGS" ] || { echo 'isolated auth settings unavailable' >&2; exit 2; }
printf 'Run one fleet-board manager tick. Repo root: %s. Scripts dir: %s. Read .fleet-board.yml for config. Use the installed manager rules. The three review cards are controlled fixtures; use their configured evidence-review runner. For deterministic fixture ordering, initially fill the two slots with cards 1 and 2, with card 3 next in the queue. Follow the manager rules and return the tick report.\n' "$WORK/repo" "$S" > "$WORK/prompt"
# Explicit registration avoids CLI startup ordering of plugin agent discovery.
# Use the generated manager body verbatim, without fixture-specific instructions.
python3 - "$WORK/plugin/agents/manager.md" "$WORK/agents.json" <<'PYAGENT'
import json,sys
text=open(sys.argv[1]).read()
body=text.split('---',2)[2].lstrip()
json.dump({'completion-manager': {'description':'Fleet board manager', 'prompt':body,
    'tools':['Agent','Skill','Read','Write','Bash','Grep','Glob']}},open(sys.argv[2],'w'))
PYAGENT
CLAUDE_CONFIG_DIR="$WORK/config" claude -p --bare --agents "$WORK/agents.json" --agent completion-manager --model sonnet \
  --plugin-dir "$WORK/plugin" --add-dir "$WORK" --tools Bash,Read,Write,Skill,Agent,Grep,Glob --allowedTools Bash Read Write Skill --strict-mcp-config --settings "$AUTH_SETTINGS" \
  --permission-mode acceptEdits --max-turns 100 --max-budget-usd 3 \
  --verbose --output-format stream-json "$(cat "$WORK/prompt")" </dev/null > "$WORK/run.jsonl" 2> "$WORK/stderr"
jq -se 'any(.[]; .type=="system" and .subtype=="init" and (.mcp_servers|length)==0
  and ([.tools[]] | index("Write")) != null
  and all(.plugins[]; .name=="fleet-board" or .path=="builtin"))' "$WORK/run.jsonl" > /dev/null
jq -se '[.[] | select(.type=="result")][-1] | .is_error==false' "$WORK/run.jsonl" > /dev/null
python3 "$WORK/check-events.py" "$WORK/events"
for n in 1 2 3; do
  bash "$S/note.sh" get "$n" > "$WORK/note-$n.json"
  jq -e '.last_review.sha=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .last_review.round==1' "$WORK/note-$n.json" >/dev/null
  bash "$S/board-read.sh" "$n" | jq -e '.state=="human_qa"' > /dev/null
done
! grep -q 'pr merge' "$WORK/gh.log"
jq -c 'select(.type=="result") | {subtype,total_cost_usd,num_turns,is_error}' "$WORK/run.jsonl"
echo 'completion ordering, refill, concurrency, reconciliation and human-QA assertions passed'
