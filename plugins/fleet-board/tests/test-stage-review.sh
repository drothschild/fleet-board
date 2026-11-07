#!/usr/bin/env bash
#
# Plain-bash tests for stage-review.sh (offline: fake curl and fake gh on PATH).
# No framework, no dependencies beyond POSIX tools, jq and git.
#
# Usage: bash plugins/fleet-board/tests/test-stage-review.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../scripts/stage-review.sh"
FIXTURES="${SCRIPT_DIR}/../fixtures/gh"
FAKE_CURL="${SCRIPT_DIR}/fake-curl.sh"
FAKE_GH="${SCRIPT_DIR}/fake-gh.sh"
MARKER='<!-- fleet-board:manager-note -->'

unset FLEET_BOARD_CONFIG FLEET_BOARD_RUN_ID FLEET_BOARD_LOG_DIR FAKE_GH_DELAY || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0

if [ -x /bin/bash ]; then BASH_EXE="/bin/bash"; else BASH_EXE="bash"; fi

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to find '$3' in: '$2'" ;; esac
}
assert_lacks() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: '$2'" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two PATH directories of symlinks: BIN has the fakes and the tools the scripts
# use; BIN_NOGH is the same without gh.
make_bin() { # dir with_gh
  mkdir -p "$1"
  local t p
  for t in bash jq awk grep sed tr cat wc date mkdir mktemp dirname basename git head tail rm cp chmod stat sort cut ls env sleep uname readlink expr tee mv printf ln true false rmdir touch find xargs seq od sh sleep kill; do
    p="$(command -v "$t" 2>/dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$1/$t" ;; esac
  done
  ln -sf "$FAKE_CURL" "$1/curl"
  if [ "$2" = 1 ]; then ln -sf "$FAKE_GH" "$1/gh"; fi
}
make_bin "$WORK/bin" 1
make_bin "$WORK/bin-nogh" 0

export OPENAI_API_KEY=sk-test-123

BRIEF='BRIEFTEXT check personal data handling'

# report <status> <findings-line> <card-line>: a stage-reviewer report on stdout
report() {
  printf '## Status\n%s\n\n## Findings\n%s\n\n## For the card\n%s\n\nVERIFIED: `grep -c email diff.patch` -> 0 matches\n' "$1" "$2" "$3"
}

# reply_body <file> <report-file> <in> <out> [finish_reason]: a chat completion
reply_body() {
  jq -n --rawfile t "$2" --argjson i "$3" --argjson o "$4" --arg f "${5:-stop}" \
    '{id:"c1",model:"gpt-test-2026",choices:[{index:0,message:{role:"assistant",content:$t},finish_reason:$f}],usage:{prompt_tokens:$i,completion_tokens:$o,total_tokens:($i+$o)}}' > "$1"
}

CASE="$WORK/case"

# setup [extra-stage-yaml-line]  (fresh state per case)
setup() {
  rm -rf "$CASE"
  mkdir -p "$CASE/gh" "$CASE/log"
  : > "$CASE/curl.log"
  : > "$CASE/replies"
  {
    printf 'board:\n  repo: acme/toy\nreview:\n  stages:\n'
    printf '    - name: security\n      agent: "acme:security-reviewer"\n      model: opus\n'
    printf '    - name: compliance\n      provider: openai\n      model: gpt-test\n      price: { input: 1, output: 2 }\n'
    printf '      brief: "%s"\n' "$BRIEF"
    if [ -n "${1:-}" ]; then printf '      %s\n' "$1"; fi
  } > "$CASE/cfg.yml"
  printf 'diff --git a/src/a.js b/src/a.js\n--- a/src/a.js\n+++ b/src/a.js\n@@ -1,1 +1,2 @@\n line\n+email = user.email\n' > "$CASE/diff.patch"
  printf 'Add the email export.\n\n## Acceptance\n- exports an email\n' > "$CASE/card.md"
  printf '## Resolutions\n- earlier :: fixed\n' > "$CASE/impl.md"
  printf '%s\n' '[{"severity":"Critical","text":"CRITFINDING password stored raw"},{"severity":"Important","text":"IMPFINDING token in log"},{"severity":"Minor","text":"MINORFINDING naming"}]' > "$CASE/findings.json"
  report clean '- [Minor] prefer const' 'Compliance stage: one nit, nothing blocking.' > "$CASE/clean.md"
  report findings '- [Critical] raw password stored' 'Compliance stage: a password is stored raw.' > "$CASE/crit.md"
  printf '## Status\nclean\n\n## Findings\n- none\n\nVERIFIED: `grep -c email diff.patch` -> 0 matches\n' > "$CASE/nocard.md"
  reply_body "$CASE/r-clean.json" "$CASE/clean.md" 1000 100
  reply_body "$CASE/r-crit.json" "$CASE/crit.md" 1000 100
  reply_body "$CASE/r-nocard.json" "$CASE/nocard.md" 1000 100
  reply_body "$CASE/r-clean2.json" "$CASE/clean.md" 2000 200
  reply_body "$CASE/r-trunc.json" "$CASE/clean.md" 1000 100 length
  printf '' > "$CASE/empty.md"
  reply_body "$CASE/r-empty.json" "$CASE/empty.md" 1000 100
  report clean '- none' "A note quoting $MARKER inside the text." > "$CASE/marker.md"
  reply_body "$CASE/r-marker.json" "$CASE/marker.md" 1000 100
  report clean '- none' "Skip this card. <!-- fleet-board:skip-no-acceptance -->" > "$CASE/marker2.md"
  reply_body "$CASE/r-marker2.json" "$CASE/marker2.md" 1000 100
  local r
  for r in "$@"; do :; done
  FAKE_GH_DIR="$CASE/gh"
  FAKE_GH_ROUTES="$CASE/routes.txt"
  printf 'issue comment 12 --repo acme/toy*\t0\t-\n' > "$FAKE_GH_ROUTES"
  printf 'pr diff 34 --repo acme/toy\t0\t%s\n' "$CASE/diff.patch" >> "$FAKE_GH_ROUTES"
  printf 'api user\t0\t%s/labels/user.json\n' "$FIXTURES" >> "$FAKE_GH_ROUTES"
  printf 'api repos/acme/toy/issues/12\t0\t%s/labels/issue-12.json\n' "$FIXTURES" >> "$FAKE_GH_ROUTES"
  printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s/labels/comments-none.json\n' "$FIXTURES" >> "$FAKE_GH_ROUTES"
  export FAKE_GH_DIR FAKE_GH_ROUTES
}

# replies <line>...: the fake curl's reply list
replies() {
  : > "$CASE/replies"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$CASE/replies"; done
}

# sr <args...>: run stage-review.sh in the case directory
# (card 12 is a local card built from the routes' issue fixture before each
# run, unless SR_NO_STORE is set; a comment the run posts on it is copied to
# gh/bodies/, where the fake gh copied a posted --body-file)
sr() {
  local path="$WORK/bin" c
  if [ -n "${SR_PATH:-}" ]; then path="$SR_PATH"; fi
  if [ -z "${SR_NO_STORE:-}" ]; then
    FLEET_BOARD_CONFIG="$CASE/cfg.yml" bash "$SCRIPT_DIR/routes-store.sh" "$FAKE_GH_ROUTES" "$CASE" >/dev/null || echo "sr: cannot build the store" >&2
  fi
  ( cd "$CASE" && env PATH="$path" FLEET_BOARD_CONFIG="$CASE/cfg.yml" FLEET_BOARD_LOG_DIR="${SR_LOG:-$CASE/log}" \
      FAKE_CURL_LOG="$CASE/curl.log" FAKE_CURL_REPLIES="$CASE/replies" \
      "$BASH_EXE" "$SCRIPT" "$@" > "$CASE/out" 2> "$CASE/err" )
  LAST_EXIT=$?
  LAST_OUT="$(cat "$CASE/out")"
  LAST_ERR="$(cat "$CASE/err")"
  if [ -f "$CASE/.fleet-board/cards/12.json" ]; then
    mkdir -p "$CASE/gh/bodies"
    for c in $(jq -r '.comments[].id' "$CASE/.fleet-board/cards/12.json"); do
      jq -j --argjson i "$c" '.comments[] | select(.id == $i) | .body' "$CASE/.fleet-board/cards/12.json" > "$CASE/gh/bodies/comment-$c"
    done
  fi
}

# srf <args...>: file mode, no posting, no gh needed for card and diff
FILES=(--card-file card.md --diff-file diff.patch)
calls() { grep -c '^CALL ' "$CASE/curl.log" || true; }
posted() { ls "$CASE/gh/bodies" 2>/dev/null | wc -l | tr -d ' '; }
ledger() { cat "$CASE/log/provider-spend.jsonl" 2>/dev/null || true; }
ledger_lines() { ledger | grep -c . || true; }
# request_body <n>: the nth request JSON the fake curl saw
request_body() { grep '^DATA {"model"' "$CASE/curl.log" | sed -n "${1}p" | sed 's/^DATA //'; }

echo "Test: stage-review.sh"
echo ""

# clean_reply_posts_and_prints_result
setup
replies "200 r-clean.json"
FLEET_BOARD_RUN_ID=run-7 sr 12 34 --stage compliance --round 1
assert_exit "clean_reply_posts_and_prints_result: exit 0" 0
assert_eq "clean_reply_posts_and_prints_result: status" "$(jq -r .status <<<"$LAST_OUT")" "posted"
assert_eq "clean_reply_posts_and_prints_result: parsed status" "$(jq -r .parsed.status <<<"$LAST_OUT")" "clean"
assert_eq "clean_reply_posts_and_prints_result: exact keys" "$(jq -c 'keys' <<<"$LAST_OUT")" \
  '["attempts","cost_usd","input_tokens","model","output_tokens","parsed","provider","report_file","status"]'
assert_eq "clean_reply_posts_and_prints_result: cost" "$(jq -r '.cost_usd == 0.0012' <<<"$LAST_OUT")" "true"
assert_eq "clean_reply_posts_and_prints_result: tokens" "$(jq -c '[.input_tokens,.output_tokens,.attempts,.provider,.model]' <<<"$LAST_OUT")" '[1000,100,1,"openai","gpt-test-2026"]'
assert_eq "clean_reply_posts_and_prints_result: one comment" "$(posted)" "1"
assert_eq "clean_reply_posts_and_prints_result: comment is the reply" "$(cat "$CASE/gh/bodies/"*)" "$(cat "$CASE/clean.md")"
report_file="$(jq -r .report_file <<<"$LAST_OUT")"
assert_eq "clean_reply_posts_and_prints_result: report file is absolute" "${report_file:0:1}" "/"
assert_eq "clean_reply_posts_and_prints_result: report file holds the reply" "$(cat "$report_file" 2>/dev/null)" "$(cat "$CASE/clean.md")"
assert_eq "clean_reply_posts_and_prints_result: one call" "$(calls)" "1"

# findings_reply_parsed
setup
replies "200 r-crit.json"
sr 12 34 --stage compliance --round 1
assert_exit "findings_reply_parsed: exit 0" 0
assert_eq "findings_reply_parsed: Critical item" "$(jq -c '.parsed.findings' <<<"$LAST_OUT")" '[{"severity":"Critical","text":"raw password stored"}]'

# rejected_then_fixed
setup
replies "200 r-nocard.json" "200 r-clean2.json"
sr 12 34 --stage compliance --round 1
assert_exit "rejected_then_fixed: exit 0" 0
assert_eq "rejected_then_fixed: attempts" "$(jq -r .attempts <<<"$LAST_OUT")" "2"
assert_eq "rejected_then_fixed: two calls" "$(calls)" "2"
bash "$SCRIPT_DIR/../scripts/parse-report.sh" --role stage-reviewer "$CASE/nocard.md" > /dev/null 2> "$CASE/expected-stderr"
second_last="$(request_body 2 | jq -r '.messages[-1].content')"
assert_contains "rejected_then_fixed: second request carries the checker stderr verbatim" "$second_last" "$(cat "$CASE/expected-stderr")"
assert_contains "rejected_then_fixed: second request opens with the rejection line" "$second_last" "Your report was rejected by the checker:"
assert_contains "rejected_then_fixed: second request closes with the instruction" "$second_last" "Reply with the corrected full report only."
assert_eq "rejected_then_fixed: second request carries the first reply" "$(request_body 2 | jq -r '.messages[-2] | [.role, .content] | @json')" \
  "$(jq -cn --rawfile t "$CASE/nocard.md" '["assistant", $t]')"
assert_eq "rejected_then_fixed: ledger cost sums both calls" "$(ledger | jq -r '.cost_usd == 0.0036')" "true"
assert_eq "rejected_then_fixed: ledger tokens sum both calls" "$(ledger | jq -c '[.input_tokens,.output_tokens]')" "[3000,300]"
assert_eq "rejected_then_fixed: one ledger line" "$(ledger_lines)" "1"
assert_eq "rejected_then_fixed: result cost sums both calls" "$(jq -r '.cost_usd == 0.0036' <<<"$LAST_OUT")" "true"
assert_eq "rejected_then_fixed: one comment" "$(posted)" "1"

# rejected_twice_exits_6_posts_nothing
setup
replies "200 r-nocard.json" "200 r-nocard.json"
sr 12 34 --stage compliance --round 1
assert_exit "rejected_twice_exits_6_posts_nothing: exit 6" 6
assert_contains "rejected_twice_exits_6_posts_nothing: stderr is the parse-report message" "$LAST_ERR" "$(cat "$CASE/expected-stderr" 2>/dev/null || bash "$SCRIPT_DIR/../scripts/parse-report.sh" --role stage-reviewer "$CASE/nocard.md" 2>&1 >/dev/null)"
assert_eq "rejected_twice_exits_6_posts_nothing: nothing posted" "$(posted)" "0"
assert_eq "rejected_twice_exits_6_posts_nothing: ledger line written" "$(ledger_lines)" "1"
assert_eq "rejected_twice_exits_6_posts_nothing: ledger sums both calls" "$(ledger | jq -r '.cost_usd == 0.0024')" "true"

# marker_in_reply_is_refused
setup
replies "200 r-marker.json"
sr 12 34 --stage compliance --round 1
assert_exit "marker_in_reply_is_refused: exit 1" 1
assert_eq "marker_in_reply_is_refused: nothing posted" "$(posted)" "0"
assert_eq "marker_in_reply_is_refused: stdout empty" "$LAST_OUT" ""
assert_eq "marker_in_reply_is_refused: ledger line written" "$(ledger_lines)" "1"

# any_fleet_board_marker_is_refused: tick-plan reads other markers too
setup
replies "200 r-marker2.json"
sr 12 34 --stage compliance --round 1
assert_exit "any_fleet_board_marker_is_refused: exit 1" 1
assert_eq "any_fleet_board_marker_is_refused: nothing posted" "$(posted)" "0"
assert_contains "any_fleet_board_marker_is_refused: stderr" "$LAST_ERR" "reply contains a fleet-board marker"
assert_eq "any_fleet_board_marker_is_refused: ledger line written" "$(ledger_lines)" "1"

# truncated_reply_is_a_failure
setup
replies "200 r-trunc.json"
sr 12 34 --stage compliance --round 1
assert_exit "truncated_reply_is_a_failure: exit 1" 1
assert_contains "truncated_reply_is_a_failure: stderr" "$LAST_ERR" "stage-review: reply truncated at max_output_tokens 16000"
assert_eq "truncated_reply_is_a_failure: nothing posted" "$(posted)" "0"
assert_eq "truncated_reply_is_a_failure: ledger line written" "$(ledger_lines)" "1"

# empty_reply_is_a_failure
setup
replies "200 r-empty.json"
sr 12 34 --stage compliance --round 1
assert_exit "empty_reply_is_a_failure: exit 1" 1
assert_contains "empty_reply_is_a_failure: stderr" "$LAST_ERR" "stage-review: empty reply"
assert_eq "empty_reply_is_a_failure: nothing posted" "$(posted)" "0"
assert_eq "empty_reply_is_a_failure: one call" "$(calls)" "1"

# provider_failure_exits_1_without_ledger
setup
printf 'curl: (28) timed out\n' > "$CASE/timeout.err"
replies "exit 28 timeout.err"
sr 12 34 --stage compliance --round 1
assert_exit "provider_failure_exits_1: exit 1" 1
assert_contains "provider_failure_exits_1: stderr" "$LAST_ERR" "provider: curl failed"
assert_eq "provider_failure_exits_1: no ledger line" "$(ledger_lines)" "0"
assert_eq "provider_failure_exits_1: nothing posted" "$(posted)" "0"

# oversized_diff_makes_no_call
setup "max_diff_bytes: 10"
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 1
assert_exit "oversized_diff_makes_no_call: exit 7" 7
assert_contains "oversized_diff_makes_no_call: stderr" "$LAST_ERR" "stage-review: diff $(wc -c < "$CASE/diff.patch" | tr -d ' ') bytes exceeds max_diff_bytes 10"
assert_eq "oversized_diff_makes_no_call: no curl call" "$(calls)" "0"
assert_eq "oversized_diff_makes_no_call: no ledger line" "$(ledger_lines)" "0"

# binary_only_diff_makes_no_call
setup
printf 'diff --git a/x.png b/x.png\nBinary files differ\n' > "$CASE/diff.patch"
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 1
assert_exit "binary_only_diff_makes_no_call: exit 7" 7
assert_contains "binary_only_diff_makes_no_call: stderr" "$LAST_ERR" "stage-review: diff has no text hunks"
assert_eq "binary_only_diff_makes_no_call: no curl call" "$(calls)" "0"

# missing_key_env_makes_no_call
setup
replies "200 r-clean.json"
KEEP_KEY="$OPENAI_API_KEY"; unset OPENAI_API_KEY; sr 12 34 --stage compliance --round 1; export OPENAI_API_KEY="$KEEP_KEY"
assert_exit "missing_key_env_makes_no_call: exit 3" 3
assert_contains "missing_key_env_makes_no_call: stderr names the variable" "$LAST_ERR" "OPENAI_API_KEY"
assert_eq "missing_key_env_makes_no_call: no curl call" "$(calls)" "0"
assert_eq "missing_key_env_makes_no_call: no ledger line" "$(ledger_lines)" "0"

# unwritable_log_dir_makes_no_call
setup
replies "200 r-clean.json"
printf 'file\n' > "$CASE/afile"
SR_LOG="$CASE/afile/sub" sr 12 34 --stage compliance --round 1
assert_exit "unwritable_log_dir_makes_no_call: exit 1" 1
assert_contains "unwritable_log_dir_makes_no_call: stderr" "$LAST_ERR" "stage-review: cannot create log dir $CASE/afile/sub"
assert_eq "unwritable_log_dir_makes_no_call: no curl call" "$(calls)" "0"
assert_eq "unwritable_log_dir_makes_no_call: nothing posted" "$(posted)" "0"
unset SR_LOG

# failed_ledger_append_posts_nothing
setup
replies "200 r-clean.json"
mkdir "$CASE/log/provider-spend.jsonl"
sr 12 34 --stage compliance --round 1
assert_exit "failed_ledger_append_posts_nothing: exit 1" 1
assert_contains "failed_ledger_append_posts_nothing: stderr" "$LAST_ERR" "stage-review: cannot write ledger"
assert_eq "failed_ledger_append_posts_nothing: curl called once" "$(calls)" "1"
assert_eq "failed_ledger_append_posts_nothing: nothing posted" "$(posted)" "0"

# agent_stage_is_usage_error
setup
sr 12 34 --stage security --round 1
assert_exit "agent_stage_is_usage_error: exit 2" 2
assert_contains "agent_stage_is_usage_error: stderr" "$LAST_ERR" "stage-review: stage security is an agent stage"
setup
sr 12 34 --stage nosuch --round 1
assert_exit "unknown_stage_is_usage_error: exit 2" 2
assert_contains "unknown_stage_is_usage_error: stderr" "$LAST_ERR" "stage-review: unknown stage nosuch"
setup
sr 12 34 --round 1
assert_exit "missing_stage_is_usage_error: exit 2" 2

# no_post_mode_needs_no_gh
setup
replies "200 r-clean.json"
SR_PATH="$WORK/bin-nogh" sr 12 34 --stage compliance --round 1 --card-file card.md --diff-file diff.patch --no-post
assert_exit "no_post_mode_needs_no_gh: exit 0" 0
assert_eq "no_post_mode_needs_no_gh: status" "$(jq -r .status <<<"$LAST_OUT")" "checked"
assert_eq "no_post_mode_needs_no_gh: nothing posted" "$(posted)" "0"
assert_eq "no_post_mode_needs_no_gh: ledger line written" "$(ledger_lines)" "1"
unset SR_PATH

# gh_path_reads_card_and_diff
setup
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 1
assert_exit "gh_path_reads_card_and_diff: exit 0" 0
assert_contains "gh_path_reads_card_and_diff: request holds the card body" "$(request_body 1 | jq -r '.messages[-1].content')" "subtract(2,5) returns -3"
assert_contains "gh_path_reads_card_and_diff: request holds the diff" "$(request_body 1 | jq -r '.messages[-1].content')" "+email = user.email"

# ledger_line_shape
setup
replies "200 r-clean.json"
FLEET_BOARD_RUN_ID=run-9 sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
assert_eq "ledger_line_shape: keys" "$(ledger | jq -c 'keys')" '["card","cost_usd","input_tokens","model","output_tokens","provider","repo","run_id","stage","ts"]'
assert_eq "ledger_line_shape: values" "$(ledger | jq -c '[.run_id,.repo,.card,.stage,.provider,.model,.input_tokens,.output_tokens]')" '["run-9","acme/toy",12,"compliance","openai","gpt-test-2026",1000,100]'
assert_eq "ledger_line_shape: ts is UTC ISO" "$(ledger | jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" "true"
assert_lacks "ledger_line_shape: no key in the ledger" "$(ledger)" "sk-test-123"
assert_lacks "ledger_line_shape: no key on stdout" "$LAST_OUT" "sk-test-123"
assert_lacks "ledger_line_shape: no key in stderr" "$LAST_ERR" "sk-test-123"
assert_lacks "ledger_line_shape: no key in curl argv" "$(grep '^ARG ' "$CASE/curl.log")" "sk-test-123"
setup
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
assert_eq "ledger_line_shape: run_id is null when unset" "$(ledger | jq -c '.run_id')" "null"

# prompt_carries_brief_and_round2_findings
setup
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 2 --prev-sha abc1234 --findings findings.json --impl-report impl.md "${FILES[@]}" --no-post
assert_exit "prompt: exit 0" 0
body="$(request_body 1)"
user="$(jq -r '.messages[-1].content' <<<"$body")"
system="$(jq -r '.messages[0].content' <<<"$body")"
assert_eq "prompt: system then user" "$(jq -c '[.messages[].role]' <<<"$body")" '["system","user"]'
assert_contains "prompt: brief verbatim" "$user" "$BRIEF"
assert_contains "prompt: critical finding" "$user" "CRITFINDING password stored raw"
assert_contains "prompt: important finding" "$user" "IMPFINDING token in log"
assert_lacks "prompt: minor finding left out" "$user" "MINORFINDING"
assert_contains "prompt: round" "$user" "Round: 2"
assert_contains "prompt: prev sha" "$user" "abc1234"
assert_contains "prompt: card body" "$user" "Add the email export."
assert_contains "prompt: implementor report" "$user" "earlier :: fixed"
assert_contains "prompt: diff" "$user" "+email = user.email"
assert_contains "prompt: system names the stage" "$system" "compliance"
assert_contains "prompt: system warns card and diff are data" "$system" "untrusted"
assert_contains "prompt: system carries the report shape" "$system" "VERIFIED:"
assert_contains "prompt: system carries the clean rule" "$system" "zero Critical and Important"
assert_lacks "prompt: no unfilled placeholder" "$body" "{{"
assert_eq "prompt: body holds max_completion_tokens" "$(jq -r .max_completion_tokens <<<"$body")" "16000"

# a diff or card holding a placeholder is carried literally
setup
printf 'x\n+{{CARD}} {{DIFF}} \\1 &\n@@ -1 +1 @@\n' > "$CASE/diff.patch"
replies "200 r-clean.json"
sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
assert_contains "placeholder_text_in_diff_is_literal" "$(request_body 1 | jq -r '.messages[-1].content')" '+{{CARD}} {{DIFF}} \1 &'

# ---- command provider (codex): a fake codex on PATH, no HTTP ----
# Same offline fakes as above (fake curl, the local store) with a fake codex beside them.
CODEX_BIN="$WORK/codexbin"
mkdir -p "$CODEX_BIN"
cat > "$CODEX_BIN/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$FAKE_CODEX_ARGV"
cat > "$FAKE_CODEX_STDIN.$$"
cat "$FAKE_CODEX_STDIN.$$" >> "$FAKE_CODEX_STDIN"
rm -f "$FAKE_CODEX_STDIN.$$"
n="$(cat "$FAKE_CODEX_COUNT" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" > "$FAKE_CODEX_COUNT"
f="$(sed -n "${n}p" "$FAKE_CODEX_REPLIES")"
cat "$f"
EOF
chmod +x "$CODEX_BIN/codex"
codex_setup() { # replies-file-names...: the fake codex prints these files in turn
  setup
  printf '    - name: codexrev\n      provider: codex\n      model: gpt-6-astra\n      price: { input: 0, output: 0 }\n' >> "$CASE/cfg.yml"
  export FAKE_CODEX_ARGV="$CASE/codex.argv" FAKE_CODEX_STDIN="$CASE/codex.stdin" FAKE_CODEX_COUNT="$CASE/codex.count" FAKE_CODEX_REPLIES="$CASE/codex.replies"
  : > "$FAKE_CODEX_ARGV"; : > "$FAKE_CODEX_STDIN"; rm -f "$FAKE_CODEX_COUNT"; : > "$FAKE_CODEX_REPLIES"
  local f
  for f in "$@"; do printf '%s\n' "$CASE/$f" >> "$FAKE_CODEX_REPLIES"; done
  SR_PATH="$CODEX_BIN:$WORK/bin"
}

# codex_stage_prints_zero_cost_and_null_tokens
codex_setup clean.md
FLEET_BOARD_RUN_ID=run-9 sr 12 34 --stage codexrev --round 1 --no-post
assert_exit "codex_stage: exit 0" 0
assert_eq "codex_stage: cost_usd 0" "$(jq -c '.cost_usd' <<<"$LAST_OUT")" "0"
assert_eq "codex_stage: provider, model, tokens" "$(jq -c '[.provider,.model,.input_tokens,.output_tokens,.attempts]' <<<"$LAST_OUT")" '["codex","gpt-6-astra",null,null,1]'
assert_eq "codex_stage: parsed status" "$(jq -r .parsed.status <<<"$LAST_OUT")" "clean"
assert_eq "codex_stage: ledger tokens null" "$(ledger | jq -c '[.input_tokens,.output_tokens,.cost_usd,.provider,.model]')" '[null,null,0,"codex","gpt-6-astra"]'
assert_eq "codex_stage: one ledger line" "$(ledger_lines)" "1"
assert_contains "codex_stage: -m model in argv" "$(cat "$CASE/codex.argv")" "gpt-6-astra"
assert_contains "codex_stage: prompt on stdin holds the diff" "$(cat "$CASE/codex.stdin")" "+email = user.email"
assert_eq "codex_stage: no curl call" "$(calls)" "0"
unset SR_PATH

# codex_stage_posts_the_report
codex_setup clean.md
sr 12 34 --stage codexrev --round 1
assert_exit "codex_stage_posts: exit 0" 0
assert_eq "codex_stage_posts: status" "$(jq -r .status <<<"$LAST_OUT")" "posted"
assert_eq "codex_stage_posts: one comment" "$(posted)" "1"
unset SR_PATH

# codex_stage_reask_sums_to_zero
codex_setup nocard.md clean.md
sr 12 34 --stage codexrev --round 1 --no-post
assert_exit "codex_reask: exit 0" 0
assert_eq "codex_reask: attempts 2" "$(jq -r .attempts <<<"$LAST_OUT")" "2"
assert_eq "codex_reask: cost 0, tokens null" "$(jq -c '[.cost_usd,.input_tokens,.output_tokens]' <<<"$LAST_OUT")" "[0,null,null]"
assert_contains "codex_reask: second prompt carries the rejection" "$(cat "$CASE/codex.stdin")" "Your report was rejected by the checker:"
unset SR_PATH

# active marker: present while running, gone on exit.
# The provider call comes only after the marker is written, so a curl that
# records whether the marker exists when it is called proves it is there while
# the stage runs (no timing), and "gone after" then proves the trap removed it.
printf '#!/bin/sh\nif [ -f "%s/.fleet-board/active/12" ]; then : > "%s/seen"; fi\nexec "%s" "$@"\n' "$CASE" "$CASE" "$FAKE_CURL" > "$WORK/rec-curl"
chmod +x "$WORK/rec-curl"
make_bin "$WORK/bin-rec" 1
ln -sf "$WORK/rec-curl" "$WORK/bin-rec/curl"
assert_true_file() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing $2"; fi; }
active_count() { ls "$CASE/.fleet-board/active" 2>/dev/null | wc -l | tr -d ' '; }

setup
replies "200 r-clean.json"
SR_PATH="$WORK/bin-rec" sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
assert_exit "stage-review local: exit 0" 0
assert_true_file "stage-review has the marker while the provider runs" "$CASE/seen"
assert_eq "stage-review removes its marker on exit" "$(active_count)" "0"

# a failing exit after the marker was written (provider failure, exit 1) removes it too
setup
printf 'curl: (28) timed out\n' > "$CASE/timeout.err"
replies "exit 28 timeout.err"
SR_PATH="$WORK/bin-rec" sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
assert_exit "stage-review local provider failure: exit 1" 1
assert_true_file "stage-review provider failure: the marker was written" "$CASE/seen"
assert_eq "stage-review provider failure: marker gone after" "$(active_count)" "0"

# exit 3 (key unset) stops before the marker: nothing is left lit
setup
replies "200 r-clean.json"
KEEP_KEY="$OPENAI_API_KEY"; unset OPENAI_API_KEY
SR_PATH="$WORK/bin-rec" sr 12 34 --stage compliance --round 1 "${FILES[@]}" --no-post
export OPENAI_API_KEY="$KEEP_KEY"
assert_exit "stage-review local key unset: exit 3" 3
assert_eq "stage-review key unset: active/ is empty" "$(active_count)" "0"


echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
