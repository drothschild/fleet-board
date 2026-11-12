#!/usr/bin/env bash
# behavioral-merger.sh - paid behavioural check of agents/merger.md (not run in CI).
#
# Runs the merger agent twice in headless `claude -p --agent fleet-board:merger` sessions, built the way
# scripts/supervisor/roles.py command() builds them, against two fixtures:
#   (a) mode refusal, a merge conflict            -> report Status `fix`
#   (b) mode after_merge, persona "run ./deploy.sh after merge", where deploy.sh is a stub that touches a
#       marker file                                -> report Status `done`, and the marker file exists
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
    && printf 'board: {backend: local, repo: fixture/merger, dir: .board}\n' > .fleet-board.yml \
    && git add . && git commit -qm fixture)
}

# claude argv as roles.command builds it
run_merger() { # LABEL REPO PROMPT
  local label="$1" repo="$2" prompt="$3"
  local argv=("$CLAUDE" -p "$prompt" --agent fleet-board:merger --plugin-dir "$PLUGIN_DIR")
  [ -z "${BL_MODEL:-}" ] || argv+=(--model "$BL_MODEL")
  argv+=(--permission-mode auto --output-format stream-json --verbose --max-turns "${BL_MAX_TURNS:-40}")
  (cd "$repo" && PATH="$RUN/bin:$PATH" FB_MERGER_OUT="$RUN/$label" "${argv[@]}" > "$RUN/$label.stream.jsonl" 2> "$RUN/$label.stderr")
  printf 'run %s: exit %s\n' "$label" "$?"
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
printf '# Persona\nAfter a merge run nothing.\nA refusal because the PR conflicts with main is `fix`; a failing required check is `attention`.\n' > "$RUN/repo-refusal/merger-persona.md"
run_merger refusal "$RUN/repo-refusal" "You are dispatched as the merger. Card: 12, title 'Fixture card', PR: 12.
Mode: refusal. Refusal: {\"pr\":12,\"head\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"reason\":\"merge conflict: the PR cannot be merged cleanly into main\"}.
Persona text (file merger-persona.md in the repository root):
$(cat "$RUN/repo-refusal/merger-persona.md")
Config JSON: {\"merge\":{\"policy\":\"auto\"}}
Scripts directory: $SCRIPTS"
check_report refusal refusal fix

# (b) after-merge with a deploy persona
mkdir -p "$RUN/after"
make_repo "$RUN/repo-after"
printf '# Persona\nAfter a merge, run ./deploy.sh from the repository root.\n' > "$RUN/repo-after/merger-persona.md"
rm -f "$RUN/repo-after/deploy-ran"
run_merger after "$RUN/repo-after" "You are dispatched as the merger. Card: 12, title 'Fixture card', PR: 12.
Mode: after_merge. Merged head: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.
Persona text (file merger-persona.md in the repository root):
$(cat "$RUN/repo-after/merger-persona.md")
Config JSON: {\"merge\":{\"policy\":\"auto\"}}
Scripts directory: $SCRIPTS"
check_report after after_merge done
if [ -f "$RUN/repo-after/deploy-ran" ]; then pass "after: ./deploy.sh ran (marker file exists)"; else fail "after: ./deploy.sh ran" "no $RUN/repo-after/deploy-ran"; fi

echo "-----------------------------------"
printf 'passed: %d   failed: %d   evidence: %s\n' "$PASS" "$FAIL" "$RUN"
[ "$FAIL" -eq 0 ] || exit 1
