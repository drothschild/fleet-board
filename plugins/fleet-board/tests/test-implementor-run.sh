#!/usr/bin/env bash
#
# Plain-bash tests for scripts/implementor-run.sh (offline; local board, local bare remote, fake
# provider command, stub gh).
#
# Usage: bash plugins/fleet-board/tests/test-implementor-run.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$PLUGIN/scripts/implementor-run.sh"
SCRIPTS="$PLUGIN/scripts"

unset FLEET_BOARD_CONFIG FLEET_BOARD_HOME FB_CFG_FOR FLEET_CFG CDPATH GH_REPO GH_HOST || true
export FLEET_BOARD_USER=fleet-bot
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export FLEET_BOARD_LOG_DIR="$TMP/log" FAKE="$TMP/fake"

PASS=0 FAIL=0
check() {
  local label="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$label"
    printf '       rc=%s stderr: %s\n' "${rc:-}" "$(tail -c 600 "$TMP/err" 2>/dev/null)"
  fi
}

mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/gh.log"
GH
# The fake provider: fake-provider <dir> <model> [extra...]. It saves its prompt, then sources the
# actions file of this attempt. $REPORT is the report path the prompt names.
cat > "$TMP/bin/fake-provider" <<'PROVIDER'
#!/bin/bash
n=$(( $(cat "$FAKE/attempt" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE/attempt"
cat > "$FAKE/prompt.$n"
pwd -P > "$FAKE/cwd"
printf '%s\n' "$@" > "$FAKE/args"
printf '%s\n' "$TMPDIR" > "$FAKE/tmpdir"
REPORT="$(awk '/^## Report file$/ { getline; print; exit }' "$FAKE/prompt.$n")"
. "$FAKE/actions.$n"
PROVIDER
chmod +x "$TMP/bin/gh" "$TMP/bin/fake-provider"
export PATH="$TMP/bin:$PATH"

BRANCH="fleet/12-a-card"
REPO="$TMP/repo"
WT="$REPO/.trees/12"
git init -q --bare "$TMP/origin.git"
git init -q -b main "$REPO"
printf '.fleet-board/\n.fleet-board.yml\n.trees/\n' > "$REPO/.gitignore"
printf 'PERSONA FILE TEXT\n' > "$REPO/persona.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
git -C "$REPO" remote add origin "$TMP/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT"

config() { # config [timeout] [persona path]
  cat > "$REPO/.fleet-board.yml" <<YML
board: { repo: acme/toy }
worktrees: { dir: .trees }
commands: { test_one: "bash CONFIG-MARKER {file}" }
implementor:
  provider: fake
  model: fake-model
  timeout: ${1:-60}
  persona: ${2:-persona.md}
  persona_append: APPENDED PERSONA TEXT
providers:
  fake:
    implement_command: "fake-provider {dir} {model} {tmp} {gitdir} {gitcommon}"
YML
}

config
mkdir -p "$REPO/.fleet-board/cards"
echo 15 > "$REPO/.fleet-board/next"
card() { # card <n> <state> <title>
  jq -n --argjson n "$1" --arg s "$2" --arg t "$3" \
    '{number: $n, title: $t, body: "CARD BODY MARKER\n", acceptance: ["ACCEPTANCE MARKER one", "ACCEPTANCE MARKER two"],
      blocked_by: [], state: $s, labels: [], next_comment_id: 1, comments: []}' > "$REPO/.fleet-board/cards/$1.json"
}

report() { # report <for-the-card text>
  cat <<REPORT
## Status
done

## Findings
- none

## For the card
$1

## PR
Draft PR #7 on branch $BRANCH.

VERIFIED: \`bash test-x.sh\` -> 1 test passed
REPORT
}

setup() {
  rm -rf "$FAKE" "$FLEET_BOARD_LOG_DIR" "$REPO/.fleet-board/cards" "$REPO/.fleet-board/active"
  mkdir -p "$FAKE" "$REPO/.fleet-board/cards"
  card 12 in_progress 'CARD TITLE MARKER'
  card 13 ready 'OPEN CARD MARKER'
  card 14 done 'DONE CARD MARKER'
  config "$@"
  report 'FIRST REPORT' > "$FAKE/good"
  report 'SECOND REPORT' > "$FAKE/second"
  printf '## Status\nfinished\n' > "$FAKE/bad"
  printf 'cp "$FAKE/good" "$REPORT"; echo finished\n' > "$FAKE/actions.1"
}
run() {
  rc=0
  (cd "$REPO" && bash "$RUNNER" "${1:-12}" "$WT" "$BRANCH") > "$TMP/out" 2> "$TMP/err" < /dev/null || rc=$?
}
comments() { jq -r '.comments | length' "$REPO/.fleet-board/cards/12.json"; }
last_comment() { jq -r '.comments[-1].body // ""' "$REPO/.fleet-board/cards/12.json"; }
posted() { [ "$(last_comment)" = "$(cat "$FAKE/$1")" ]; }
attempts() { [ "$(cat "$FAKE/attempt" 2>/dev/null || echo 0)" = "$1" ]; }
out() { jq -e "$1" "$TMP/out" > /dev/null 2>&1; }

# --- a valid report ------------------------------------------------------------------------------
setup
cat > "$FAKE/actions.1" <<'ACT'
mkdir -p tests && echo 'exit 1' > tests/test-x.sh
git add tests/test-x.sh && git commit -qm 'test: failing test'
cp "$FAKE/good" "$REPORT"; echo finished
ACT
run
check "a valid report and a failing test commit: implementor-run.sh exits 0" test "$rc" = 0
check "a valid report: it is posted on the card once" test "$(comments)" = 1
check "a valid report: the comment is the report the provider wrote" posted good
check "a valid report: stdout says posted after one attempt" out '.status == "posted" and .attempts == 1 and .provider == "fake" and .model == "fake-model"'
check "a valid report: the failing test is committed on the card's branch" test "$(git -C "$WT" log -1 --format=%s "$BRANCH")" = 'test: failing test'
check "the provider runs in the worktree" test "$(cat "$FAKE/cwd")" = "$WT"
check "{dir} and {model} are substituted" test "$(sed -n 1,2p "$FAKE/args")" = "$(printf '%s\nfake-model' "$WT")"
check "{tmp} is the provider's TMPDIR" test "$(sed -n 3p "$FAKE/args")" = "$(cat "$FAKE/tmpdir")"
check "{gitdir} is the worktree's git directory" test "$(sed -n 4p "$FAKE/args")" = "$REPO/.git/worktrees/12"
check "{gitcommon} is the repository's git directory" test "$(sed -n 5p "$FAKE/args")" = "$REPO/.git"

# --- a rejected report ---------------------------------------------------------------------------
setup
printf 'cp "$FAKE/bad" "$REPORT"; echo finished\n' > "$FAKE/actions.1"
printf 'cp "$FAKE/second" "$REPORT"; echo finished\n' > "$FAKE/actions.2"
run
check "a report that fails parse-report.sh then a good one: exits 0" test "$rc" = 0
check "a rejected report: the provider is prompted exactly twice" attempts 2
check "a rejected report: the second prompt holds the parse error" grep -Fq 'parse-report: unknown status: finished' "$FAKE/prompt.2"
check "a rejected report: the second report is posted" posted second
check "a rejected report: only one comment" test "$(comments)" = 1

setup
printf 'cp "$FAKE/bad" "$REPORT"; echo finished\n' > "$FAKE/actions.1"
cp "$FAKE/actions.1" "$FAKE/actions.2"
cp "$FAKE/actions.1" "$FAKE/actions.3"
run
check "two rejected reports exit 6" test "$rc" = 6
check "two rejected reports: no third prompt" attempts 2
check "two rejected reports: nothing posted" test "$(comments)" = 0

setup
printf 'echo finished\n' > "$FAKE/actions.1"
printf 'cp "$FAKE/second" "$REPORT"; echo finished\n' > "$FAKE/actions.2"
run
check "no report file is re-prompted once" attempts 2
check "no report file: the retry names the missing file" grep -Fq 'no report was written' "$FAKE/prompt.2"
check "no report file: the second report is posted" posted second

setup
printf 'ln -s "%s" "$REPORT"; echo finished\n' "$FAKE/good" > "$FAKE/actions.1"
cp "$FAKE/actions.1" "$FAKE/actions.2"
run
check "a symlink as the report file is not posted" test "$rc" = 6 -a "$(comments)" = 0

setup
sed -i.bak 's/^FIRST REPORT$/FIRST REPORT <!-- fleet-board:manager-note -->/' "$FAKE/good"
printf 'cp "$FAKE/good" "$REPORT"; echo finished\n' > "$FAKE/actions.2"
run
check "a report holding a fleet-board marker is not posted" test "$rc" = 6 -a "$(comments)" = 0

# --- provider failures ---------------------------------------------------------------------------
for case in 'exits non-zero|cp "$FAKE/good" "$REPORT"; echo finished; exit 9|60' \
            'prints nothing|cp "$FAKE/good" "$REPORT"|60' \
            'runs past timeout|cp "$FAKE/good" "$REPORT"; echo finished; sleep 20|2'; do
  IFS='|' read -r name action limit <<< "$case"
  setup "$limit"
  printf '%s\n' "$action" > "$FAKE/actions.1"
  run
  check "a provider that $name: provider-failure code 4" test "$rc" = 4
  check "a provider that $name: posts nothing" test "$(comments)" = 0
  check "a provider that $name: is not prompted again" attempts 1
  check "a provider that $name: stderr says provider failure" grep -Fq 'provider failure' "$TMP/err"
done

# --- the prompt ----------------------------------------------------------------------------------
setup
printf '{"implementor_attempts": 4242}\n' > "$TMP/patch.json"
(cd "$REPO" && bash "$SCRIPTS/note.sh" merge 12 "$TMP/patch.json") > /dev/null 2>&1
check "the prompt fixture has a manager note" test "$(comments)" = 1
run
check "the prompt run exits 0" test "$rc" = 0
check "the prompt holds the spec text of agents/implementor.md" grep -Fxq '## Method' "$FAKE/prompt.1"
check "the prompt leaves out the agent frontmatter" bash -c '! grep -Eq "^(model|name|tools):" "$1"' _ "$FAKE/prompt.1"
in_order() { # each fixed string appears on a later line than the one before it, after the inputs start
  local at line s
  at="$(grep -nFx '## Card number' "$FAKE/prompt.1" | tail -1 | cut -d: -f1)"
  [ -n "$at" ] || return 1
  for s in "$@"; do
    line="$(awk -v s="$s" -v at="$at" 'NR > at && index($0, s) { print NR; exit }' "$FAKE/prompt.1")"
    [ -n "$line" ] || { echo "       not after line $at: $s"; return 1; }
    at="$line"
  done
}
check "the prompt holds card, acceptance, worktree, branch, config, manager note, open cards, persona file text then appended text, in that order" \
  in_order 'CARD TITLE MARKER' 'CARD BODY MARKER' 'ACCEPTANCE MARKER one' 'ACCEPTANCE MARKER two' \
    '## Worktree path' "$WT" '## Branch' "$BRANCH" '## Config' 'CONFIG-MARKER' '## Manager note' '"implementor_attempts": 4242' \
    '## Open cards' '#13 OPEN CARD MARKER' '## Project rules' 'PERSONA FILE TEXT' 'APPENDED PERSONA TEXT'
check "open cards leave out done cards and the card itself" \
  bash -c '! grep -Eq "^#(12|14) " "$1"' _ "$FAKE/prompt.1"
check "the prompt names the scripts directory" grep -Fxq "$SCRIPTS" "$FAKE/prompt.1"

setup 60 no-such-persona.md
run
check "a missing persona file is an attention" test "$rc" = 3
check "a missing persona file: stdout names it" out '.attention | contains("implementor.persona not found: no-such-persona.md")'
check "a missing persona file: no provider session" attempts 0

# --- the guard -----------------------------------------------------------------------------------
setup
cat > "$FAKE/actions.1" <<'ACT'
gh pr merge 7 --squash; echo "$?" > "$FAKE/merge.rc"
cp "$FAKE/good" "$REPORT"; echo finished
ACT
run
check "a provider that calls gh pr merge is blocked" test "$(cat "$FAKE/merge.rc" 2>/dev/null)" = 2
check "the blocked merge never reaches gh" bash -c '! grep -q "pr merge" "$1" 2>/dev/null' _ "$FAKE/gh.log"
check "a blocked gh pr merge: the run is an attention, exit 3" test "$rc" = 3
check "a blocked gh pr merge: stdout is the attention" out '.attention | contains("gh pr merge")'
check "a blocked gh pr merge: the report is not posted" bash -c '! jq -e ".comments[] | select(.body | contains(\"FIRST REPORT\"))" "$1" >/dev/null' _ "$REPO/.fleet-board/cards/12.json"
check "a blocked gh pr merge: one comment names the attention" bash -c 'jq -e ".comments | length == 1 and (.[0].body | contains(\"attention\"))" "$1" >/dev/null' _ "$REPO/.fleet-board/cards/12.json"

setup
cat > "$FAKE/actions.1" <<'ACT'
gh pr merge 7; echo finished; exit 9
ACT
run
check "a blocked call is an attention even when the provider then fails" test "$rc" = 3

setup
cat > "$FAKE/actions.1" <<ACT
echo '# changed' >> "$REPO/.fleet-board.yml"
cp "\$FAKE/good" "\$REPORT"; echo finished
ACT
run
check "a session the post-run check rejects is an attention" test "$rc" = 3
check "a post-run attention: the report is not posted" test "$(comments)" = 1

# --- a stopped run -------------------------------------------------------------------------------
stop_run() { # start the runner, send it TERM once the provider is sleeping; sets rc and took
  local pid i=0 start
  (cd "$REPO" && exec bash "$RUNNER" 12 "$WT" "$BRANCH") > "$TMP/out" 2> "$TMP/err" < /dev/null &
  pid=$!
  while [ ! -s "$FAKE/sleeper" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  start=$SECONDS rc=0
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  took=$((SECONDS - start))
}
provider_gone() { [ -s "$FAKE/sleeper" ] && ! kill -0 "$(cat "$FAKE/sleeper")" 2>/dev/null; }

setup
cat > "$FAKE/actions.1" <<ACT
echo stray > "$REPO/stray.txt"
sleep 20 & echo \$! > "\$FAKE/sleeper"; wait
ACT
stop_run
check "a stopped provider that wrote outside its worktree: the runner exits 3" test "$rc" = 3
check "a stopped provider that wrote outside its worktree: stdout is the attention naming the path" \
  out '.attention | contains("file stray.txt changed outside the worktree")'
check "a stopped provider that wrote outside its worktree: one comment names the path" \
  bash -c 'jq -e ".comments | length == 1 and (.[0].body | contains(\"stray.txt\"))" "$1" >/dev/null' _ "$REPO/.fleet-board/cards/12.json"
check "a stopped provider that wrote outside its worktree: the provider is stopped" provider_gone
rm -f "$REPO/stray.txt"

setup
printf 'sleep 20 & echo $! > "$FAKE/sleeper"; wait\n' > "$FAKE/actions.1"
stop_run
check "a stopped provider that only sleeps: the runner exits without an attention" test "$rc" = 1
check "a stopped provider that only sleeps: no attention on stdout or the card" \
  test "$(cat "$TMP/out")" = "" -a "$(comments)" = 0
check "a stopped provider that only sleeps: the runner does not wait for the provider" test "$took" -lt 15
check "a stopped provider that only sleeps: the provider is stopped" provider_gone
check "a stopped provider that only sleeps: no guard snapshot directory is left" \
  test -s "$FAKE/tmpdir" -a ! -e "$(cat "$FAKE/tmpdir")"

# --- the codex preset ----------------------------------------------------------------------------
preset() { jq -er '.codex.implement_command' "$SCRIPTS/providers/presets.json" 2>/dev/null; }
preset_has() { case "$(preset)" in *"$1"*) return 0 ;; esac; return 1; }
check "the codex preset's implement_command matches ^codex exec " bash -c 'jq -e ".codex.implement_command | test(\"^codex exec \")" "$1" >/dev/null' _ "$SCRIPTS/providers/presets.json"
check "the codex implement_command holds -C {dir}" preset_has '-C {dir}'
check "the codex implement_command holds -m {model}" preset_has '-m {model}'
check "the codex implement_command uses the workspace-write sandbox" preset_has '-s workspace-write'
check "the codex implement_command allows only the push and gh hosts" preset_has "domains={\"github.com\"=\"allow\",\"api.github.com\"=\"allow\"}'"
for p in '{tmp}' '{gitdir}' '{gitcommon}/objects' '{gitcommon}/refs' '{gitcommon}/logs'; do
  check "the codex implement_command can write $p" preset_has "--add-dir $p"
done

# --- usage and configuration ---------------------------------------------------------------------
setup
rc=0; (cd "$REPO" && bash "$RUNNER" 12 "$WT") > "$TMP/out" 2> "$TMP/err" || rc=$?
check "missing arguments exit 2" test "$rc" = 2
setup
printf 'board: { repo: acme/toy }\n' > "$REPO/.fleet-board.yml"
run
check "implementor.provider claude exits 2" test "$rc" = 2
check "implementor.provider claude: says so" grep -Fq 'implementor.provider is claude' "$TMP/err"
setup
rc=0; (cd "$REPO" && bash "$RUNNER" 12 "$WT" "$BRANCH" next-model) > "$TMP/out" 2> "$TMP/err" < /dev/null || rc=$?
check "a fourth argument runs the provider on that model instead of implementor.model" \
  test "$rc" = 0 -a "$(sed -n 2p "$FAKE/args" 2>/dev/null)" = next-model
check "a fourth argument: stdout names that model" out '.model == "next-model"'
setup
sed -i.bak 's/^  model: fake-model$/  model: null/' "$REPO/.fleet-board.yml"
run
check "a provider implementor without implementor.model exits 1" test "$rc" = 1
check "without implementor.model: says so" grep -Fq 'implementor.model' "$TMP/err"
setup nope
run
check "a timeout that is not a positive integer exits 1" test "$rc" = 1
check "a bad timeout: says so" grep -Fq 'implementor.timeout' "$TMP/err"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
