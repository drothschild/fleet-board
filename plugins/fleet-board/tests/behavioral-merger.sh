#!/usr/bin/env bash
# behavioral-merger.sh - paid behavioural check of agents/merger.md (not run in CI).
#
# Runs the merger agent twice in headless `claude --bare -p --agent fleet-board:merger` sessions, built the way
# scripts/supervisor/roles.py command() builds them, each with a fresh empty CLAUDE_CONFIG_DIR (no user plugins,
# hooks, settings or user CLAUDE.md), against two fixtures:
#   (a) mode refusal, a merge conflict            -> report Status `fix`
#   (b) mode after_merge, persona "run ./deploy.sh after merge", where deploy.sh is a stub that touches a
#       marker file                                -> report Status `done`, and the marker file exists
# The prompt is the driver's own: driver.role_prompt('merger', ...) over the inputs CardDriver._dispatch_merger
# passes, with the persona read by CardDriver._persona (merge.persona null -> .fleet-board/merger.md) and the
# config from config.sh. Each session's system/init event must show no plugin but fleet-board (and builtins).
# Each report is checked with parse-report.sh --role merger --mode <mode>. The board is a stub: board-comment.sh
# copies the posted report into the run directory and gh is a canned stub, so nothing touches a real board
# or GitHub.
#
# Spends real tokens (two sonnet sessions). Refuses to run unless FLEET_BOARD_BEHAVIORAL=1.
#
# Environment:
#   FLEET_BOARD_BEHAVIORAL=1   required
#   FLEET_BOARD_CLAUDE         claude binary (default: claude)
#   BL_MAX_TURNS               --max-turns per session (default 40)
#   BL_MODEL                   --model (default sonnet, the agent's own model)
#   FB_ISOLATE_SETTINGS        settings file holding the auth (an apiKeyHelper) for the --bare sessions
#                              (default ~/.config/fleet-board/bare-settings.json; skipped when unreadable,
#                              then --bare needs ANTHROPIC_API_KEY)
#
# Portable: bash 3.2, jq, git.
set -uo pipefail
unset CDPATH

cat >&2 <<'BANNER'
================================================================
 behavioral-merger.sh SPENDS REAL TOKENS: two headless model
 sessions (merger agent: refusal fixture, after-merge fixture).
 Set FLEET_BOARD_BEHAVIORAL=1 to confirm you mean it.
================================================================
BANNER
if [ "${FLEET_BOARD_BEHAVIORAL:-}" != "1" ]; then
  echo "behavioral-merger: refusing to run: FLEET_BOARD_BEHAVIORAL=1 is not set" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
CLAUDE="${FLEET_BOARD_CLAUDE:-claude}"
RUN="$(mktemp -d "${TMPDIR:-/tmp}/fb-merger-behavioral.XXXXXX")"
printf 'evidence: %s\n' "$RUN"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

# Stub scripts directory the agent is handed: the real parse-report.sh, a board-comment.sh that records the post.
SCRIPTS="$RUN/scripts"
mkdir -p "$SCRIPTS" "$RUN/bin"
cp "$PLUGIN_DIR/scripts/parse-report.sh" "$SCRIPTS/parse-report.sh"
cat > "$SCRIPTS/board-comment.sh" <<'STUB'
#!/usr/bin/env bash
# usage: board-comment.sh <card> <file>; records the post for the test
cp "$2" "$FB_MERGER_OUT/posted-$1.md"
echo "posted to card $1"
STUB
chmod +x "$SCRIPTS/board-comment.sh"
cat > "$RUN/bin/gh" <<'STUB'
#!/usr/bin/env bash
# canned, read-only: every call reads one open pull request
printf '[{"number":12,"state":"OPEN","mergeStateStatus":"DIRTY"}]\n'
STUB
chmod +x "$RUN/bin/gh"

# fixture REPO: a git repo with a deploy.sh stub that touches deploy-ran
make_repo() { # DIR
  mkdir -p "$1"
  (cd "$1" && git init -q && git config user.name Fixture && git config user.email fixture@example.com \
    && printf '#!/usr/bin/env bash\ntouch "$(dirname "$0")/deploy-ran"\n' > deploy.sh && chmod +x deploy.sh \
    && printf 'board:\n  repo: fixture/merger\nmerge:\n  policy: auto\n' > .fleet-board.yml \
    && git add . && git commit -qm fixture)
  bash "$PLUGIN_DIR/scripts/config.sh" --dir "$1" > "$1.config.json" || { echo "behavioral-merger: fixture config rejected" >&2; exit 1; }
}

# The prompt the driver builds: role_prompt('merger', inputs) as CardDriver._dispatch_merger passes them, the
# persona through CardDriver._persona (the fixture's untracked .fleet-board/merger.md), config from config.sh.
build_prompt() { # REPO MODE EXTRA_JSON OUT
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$1" "$2" "$3" "$SCRIPTS" "$4" <<'PY'
import json, sys
from pathlib import Path
from supervisor import driver, state
repo, mode, extra, scripts_dir, out = sys.argv[1:6]
config = json.loads(Path(repo + '.config.json').read_text())
card = driver.CardDriver(repo, lambda: config, state.State('behavioral-merger'))
ctx = type('Ctx', (), {'config': config, 'repo': lambda self: config['board']['repo']})()
persona = card._persona(ctx, 12)
inputs = dict(json.loads(extra), number=12, title='Fixture card', pr=12, mode=mode, persona=persona,
              config=json.dumps(config, indent=2, sort_keys=True), scripts=scripts_dir)
Path(out).write_text(driver.role_prompt('merger', inputs))
PY
}

# claude argv as roles.command builds it
# --bare with a fresh empty CLAUDE_CONFIG_DIR: plain --bare still loads installed user plugins (repo CLAUDE.md)
SETTINGS="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
run_merger() { # LABEL REPO PROMPT_FILE
  local label="$1" repo="$2" prompt cfg="$RUN/claude-config-$1"
  prompt="$(cat "$3")"
  mkdir -p "$cfg"
  local argv=("$CLAUDE" --bare -p "$prompt" --agent fleet-board:merger --plugin-dir "$PLUGIN_DIR")
  [ ! -r "$SETTINGS" ] || argv+=(--settings "$SETTINGS")
  [ -z "${BL_MODEL:-}" ] || argv+=(--model "$BL_MODEL")
  argv+=(--permission-mode auto --output-format stream-json --verbose --max-turns "${BL_MAX_TURNS:-40}")
  (cd "$repo" && CLAUDE_CONFIG_DIR="$cfg" PATH="$RUN/bin:$PATH" FB_MERGER_OUT="$RUN/$label" "${argv[@]}" \
    < /dev/null > "$RUN/$label.stream.jsonl" 2> "$RUN/$label.stderr")
  printf 'run %s: exit %s\n' "$label" "$?"
  if jq -se 'any(.[]; .type == "system" and .subtype == "init"
               and any(.plugins[]?; .name == "fleet-board")
               and all(.plugins[]?; .name == "fleet-board" or .path == "builtin"))' "$RUN/$label.stream.jsonl" > /dev/null 2>&1; then
    pass "$label: system/init shows no user plugin (fleet-board only)"
  else
    fail "$label: system/init shows no user plugin" "see the init event in $RUN/$label.stream.jsonl"
  fi
}

check_report() { # LABEL MODE WANT_STATUS
  local label="$1" mode="$2" want="$3" f="$RUN/$label/posted-12.md" got
  if [ ! -f "$f" ]; then fail "$label: a report was posted" "no $f (see $RUN/$label.stream.jsonl)"; return; fi
  pass "$label: a report was posted"
  if bash "$PLUGIN_DIR/scripts/parse-report.sh" --role merger --mode "$mode" "$f" > "$RUN/$label.parsed.json" 2> "$RUN/$label.parse.err"; then
    pass "$label: parse-report.sh --role merger --mode $mode accepts it"
  else
    fail "$label: parse-report.sh accepts the report" "$(cat "$RUN/$label.parse.err")"; return
  fi
  got="$(sed -n '/^## Status/{n;p;}' "$f" | tr -d '[:space:]')"
  if [ "$got" = "$want" ]; then pass "$label: Status is $want"; else fail "$label: Status is $want" "got '$got'"; fi
}

# (a) conflict refusal
mkdir -p "$RUN/refusal"
make_repo "$RUN/repo-refusal"
mkdir -p "$RUN/repo-refusal/.fleet-board"
printf '# Persona\nAfter a merge run nothing.\nA refusal because the PR conflicts with main is `fix`; a failing required check is `attention`.\n' > "$RUN/repo-refusal/.fleet-board/merger.md"
build_prompt "$RUN/repo-refusal" refusal \
  '{"refusal":{"pr":12,"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"merge conflict: the PR cannot be merged cleanly into main"}}' \
  "$RUN/refusal.prompt" || { echo "behavioral-merger: cannot build the refusal prompt" >&2; exit 1; }
run_merger refusal "$RUN/repo-refusal" "$RUN/refusal.prompt"
check_report refusal refusal fix

# (b) after-merge with a deploy persona
mkdir -p "$RUN/after"
make_repo "$RUN/repo-after"
mkdir -p "$RUN/repo-after/.fleet-board"
printf '# Persona\nAfter a merge, run ./deploy.sh from the repository root.\n' > "$RUN/repo-after/.fleet-board/merger.md"
rm -f "$RUN/repo-after/deploy-ran"
build_prompt "$RUN/repo-after" after_merge '{"merged_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
  "$RUN/after.prompt" || { echo "behavioral-merger: cannot build the after-merge prompt" >&2; exit 1; }
run_merger after "$RUN/repo-after" "$RUN/after.prompt"
check_report after after_merge done
if [ -f "$RUN/repo-after/deploy-ran" ]; then pass "after: ./deploy.sh ran (marker file exists)"; else fail "after: ./deploy.sh ran" "no $RUN/repo-after/deploy-ran"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d   evidence: %s\n' "$PASS" "$FAIL" "$RUN"
[ "$FAIL" -eq 0 ] || exit 1
