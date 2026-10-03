#!/usr/bin/env bash
#
# End-to-end tick scenarios for fleet-board. NOT an offline suite: it runs real
# headless ticks (claude -p "/fleet-board:tick") against the sandbox repo named
# by SANDBOX_REPO, and asserts on the board, the PRs, the manager notes and the
# tick transcripts. The manager advances EVERY card on the board, so scenarios
# must run one at a time against a board with no other open fleet cards.
#
# Usage: SANDBOX_REPO=owner/name bash plugins/fleet-board/tests/behavioral-tick.sh \
#          [--scenario NAME] [--max-ticks N]
#
# Scenarios:
#   default       card A (subtract, labelled needs-human-qa) runs Ready -> Human QA;
#                 card B (no Acceptance) is dragged to Ready and must be skipped
#                 with exactly one comment (AC1.1-1.3, 1.5, 1.6, 6.1, 6.4)
#   ready-path    the same without the label: A's PR ends ready-for-review and
#                 unmerged under merge.policy human (AC1.4)
#   bad-report    a plugin copy whose implementor omits VERIFIED: two implementor
#                 dispatches, the second quoting the rejection (AC5.4)
#   fix-block     seeded round-1 Critical review, max_rounds 2, escalation after
#                 round 1: escalated fixer, then Blocked (AC1.7, AC6.2)
#   merge-auto    seeded clean review; the harness merges the PR itself (merges
#                 stay human); ticks verify main, then finish (AC4.7); the
#                 harness then runs cleanup-done.sh, as the wrapper does; the
#                 merge is reverted on cleanup
#   merge-red     the same with a patch that turns main red: a P0 card (AC4.8)
#   out-of-scope  a plugin copy whose implementor reports one Out of scope item:
#                 a Backlog card linked from the PR (AC3.9)
#   bug-found     a plugin copy whose implementor reports one bug: a bug card,
#                 then a second card whose report of the same bug is linked, not
#                 filed twice (AC3.10)
#
# Every tick is also scanned with plugin-interaction-scan.sh; foreign_skill and
# foreign_agent must be 0.
#
# Env:
#   RUN           keep transcripts here (default $TMPDIR/fb-p6/behavioral/<scenario>-<ts>)
#   TICK_PROMPT   default: the TICK_PROMPT line of rehearsal-notes.md, else /fleet-board:tick
#   DISPATCH_PATH default: the DISPATCH_PATH line of rehearsal-notes.md, else nested
#   FB_SESSION_MODEL  the tick session model (default: fable when DISPATCH_PATH is
#                 nested, else models.manager)
#
# Exit: 0 all assertions passed, 1 any failure, 2 SANDBOX_REPO unset or usage.

set -uo pipefail
unset CDPATH

SCENARIOS="default ready-path bad-report fix-block merge-auto merge-red out-of-scope bug-found"
usage() { printf 'usage: SANDBOX_REPO=owner/name %s [--scenario <%s>] [--max-ticks N]\n' "$0" "$(echo $SCENARIOS | tr ' ' '|')" >&2; exit 2; }

SCENARIO=default
MAX_TICKS=10
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) [ $# -ge 2 ] || usage; SCENARIO="$2"; shift 2 ;;
    --max-ticks) [ $# -ge 2 ] || usage; MAX_TICKS="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case " $SCENARIOS " in *" $SCENARIO "*) ;; *) usage ;; esac
case "$MAX_TICKS" in ''|*[!0-9]*|0) usage ;; esac
[ -n "${SANDBOX_REPO:-}" ] || { echo "behavioral-tick: SANDBOX_REPO is not set" >&2; exit 2; }

. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/behavioral-lib.sh"

PATCHES="$BL_FIX/patches"
SCAN="$BL_TESTS/plugin-interaction-scan.sh"
NOTES_FILE="$PLUGIN_DIR/../../docs/implementation-plans/2026-09-28-fleet-board/rehearsal-notes.md"
notes_value() { [ -f "$NOTES_FILE" ] && sed -n "s/^$1: *//p" "$NOTES_FILE" | head -1; }
TICK_PROMPT="${TICK_PROMPT:-$(notes_value TICK_PROMPT)}"; TICK_PROMPT="${TICK_PROMPT:-/fleet-board:tick}"
DISPATCH_PATH="${DISPATCH_PATH:-$(notes_value DISPATCH_PATH)}"; DISPATCH_PATH="${DISPATCH_PATH:-nested}"

if [ -z "${RUN:-}" ]; then
  RUN="${TMPDIR:-/tmp}"; RUN="${RUN%/}/fb-p6/behavioral/$SCENARIO-$BL_TS"
fi

TPLUGIN="$PLUGIN_DIR"   # the plugin the ticks load (a temp copy in some scenarios)
MERGES=""               # merge commits on the sandbox main, reverted on cleanup
A="" ; B=""             # the scenario's cards
TICK=0                  # ticks run so far
START_ALL="$(date +%s)"

# --- cleanup ------------------------------------------------------------------
tick_cleanup() {
  local rc=$? n b sha
  if [ -n "$CLONE" ] && [ -d "$CLONE" ]; then
    git -C "$CLONE" fetch -q origin 2>/dev/null
    # every branch and open PR the manager made for a scenario card
    for n in $CARDS; do
      for b in $(git -C "$CLONE" ls-remote --heads origin 2>/dev/null | sed 's|.*refs/heads/||' | grep "^fleet/$n-"); do
        BRANCHES="$BRANCHES $b"
      done
    done
    # revert every merge this run produced, with a normal push (never forced)
    if [ -n "$MERGES" ]; then
      (
        cd "$CLONE" || exit 1
        git checkout -q -B main origin/main || exit 1
        for sha in $MERGES; do
          git revert --no-edit "$sha" >/dev/null || { git revert --abort 2>/dev/null; exit 1; }
        done
        git push -q origin main
      ) || { bl_log "cleanup: FAILED to revert merges ($MERGES) on $SANDBOX_REPO main"; rc=1; }
      git -C "$CLONE" fetch -q origin 2>/dev/null
      if [ -n "$(git -C "$CLONE" grep -nE 'subtract|clamp|multiply' origin/main -- src test 2>/dev/null)" ]; then
        bl_log "cleanup: sandbox main is NOT pristine after the revert"; rc=1
      else
        bl_log "cleanup: merges reverted; sandbox main content pristine"
      fi
    fi
  fi
  (exit $rc)
  cleanup
}
trap tick_cleanup EXIT
trap 'exit 130' INT TERM

bl_init_run "$SCENARIO"
prepare
FWBASE="$(mkdir -p "$CLONE/$(bash "$S/config.sh" worktrees.dir)" && cd "$CLONE/$(bash "$S/config.sh" worktrees.dir)" && pwd -P)" \
  || bl_die "cannot resolve the worktrees base"
: >"$RUN/ticks.tsv"

# --- helpers -----------------------------------------------------------------
in_clone() { (cd "$CLONE" && "$@"); }
card_json() { in_clone bash "$S/board-read.sh" "$1" 2>/dev/null; }
card_state() { card_json "$1" | jq -r '.state // "none"'; }
note_get() { in_clone bash "$S/note.sh" get "$1" 2>/dev/null; }

# mk_card FILE [STATE] [TITLE_SUFFIX]: a card issue (no worktree) -> CARD
mk_card() {
  local file="$1" state="${2:-ready}" title body out
  title="$(sed -n 's/^# //p' "$file" | head -1)"
  body="$WORK/card-body-$$.md"
  sed '1{/^# /d;}' "$file" | sed '/./,$!d' >"$body"
  out="$(in_clone bash "$S/board-create.sh" "$title [behavioral $BL_TS${3:-}]" "$body")" || bl_die "board-create.sh failed"
  CARD="$(printf '%s' "$out" | jq -r .number)"
  case "$CARD" in ''|*[!0-9]*) bl_die "board-create.sh printed no number: $out" ;; esac
  CARDS="$CARDS $CARD"
  [ "$state" = backlog ] || in_clone bash "$S/board-move.sh" "$CARD" "$state" >/dev/null || bl_die "board-move.sh $CARD $state failed"
  bl_log "card #$CARD ($title) in $state"
}

# seed_pr CARD_FILE PATCH DRAFT: a card in in_review with a PR from PATCH, its
# branch checked out in a worktree under the worktrees base (as the manager
# would have it) -> CARD BRANCH WT PR HEAD
seed_pr() {
  mk_card "$1" in_review
  BRANCH="fleet/$CARD-behavioral"
  BRANCHES="$BRANCHES $BRANCH"
  WT="$FWBASE/$CARD-behavioral"
  git -C "$CLONE" worktree add -q "$WT" -b "$BRANCH" origin/main 2>/dev/null || bl_die "worktree add $WT failed"
  apply_patch "$2"
  git -C "$WT" push -q -u origin "$BRANCH" 2>/dev/null || bl_die "push $BRANCH failed"
  local url draft=""
  [ "$3" = 1 ] && draft="--draft"
  # No "Closes #N": GitHub would close the card on merge, and a closed card
  # drops out of the in_review column before verify_main can run.
  url="$(cd "$WT" && gh pr create --repo "$SANDBOX_REPO" $draft --base main --head "$BRANCH" \
    --title "$(sed -n 's/^# //p' "$1" | head -1) [behavioral $BL_TS]" --body "Card #$CARD (behavioral-tick seed)")" \
    || bl_die "gh pr create failed"
  PR="${url##*/}"
  case "$PR" in ''|*[!0-9]*) bl_die "cannot read PR number from: $url" ;; esac
  HEAD="$(git -C "$WT" rev-parse HEAD)"
  bl_log "seeded card #$CARD in_review, PR #$PR (draft=$3), head $HEAD"
}

# seed_note N ROUND CRITICAL FINDINGS_JSON [EXTRA_JQ]: note.sh put for a seeded card
seed_note() {
  jq -n --arg b "$BRANCH" --arg w "$WT" --argjson pr "$PR" --argjson r "$2" --arg sha "$HEAD" \
    --argjson c "$3" --argjson f "$4" \
    '{state: "in_review", branch: $b, worktree: $w, pr: $pr, round: $r,
      models: {implementor: "sonnet", reviewer: "opus", fixer: "sonnet"},
      escalated: false, implementor_attempts: 1,
      last_review: {round: $r, sha: $sha, critical: $c, important: 0, findings: $f}}' \
    | jq "${5:-.}" >"$RUN/seed-note-$1.json" || bl_die "cannot build the seed note"
  in_clone bash "$S/note.sh" put "$1" "$RUN/seed-note-$1.json" >/dev/null || bl_die "note.sh put $1 failed"
}

# override_config LINE...: committed config plus overrides -> $RUN/config.yml
override_config() {
  local l
  cp "$CLONE/.fleet-board.yml" "$RUN/config.yml" || bl_die "cannot copy the committed config"
  for l in "$@"; do
    case "$l" in
      review:*) grep -v '^review:' "$RUN/config.yml" >"$RUN/config.tmp" && mv "$RUN/config.tmp" "$RUN/config.yml" ;;
    esac
    printf '%s\n' "$l" >>"$RUN/config.yml"
  done
  export FLEET_BOARD_CONFIG="$RUN/config.yml"
  bash "$S/config.sh" --check >/dev/null 2>"$RUN/config.err" || bl_die "override config invalid: $(cat "$RUN/config.err")"
  bl_log "FLEET_BOARD_CONFIG=$FLEET_BOARD_CONFIG: $(bash "$S/config.sh" | jq -c '{merge, review, models}')"
}

# plugin_copy MODE [LINE]: a temp copy of the plugin whose implementor is edited
plugin_copy() {
  TPLUGIN="$WORK/plugin-copy"
  rm -rf "$TPLUGIN" && cp -R "$PLUGIN_DIR" "$TPLUGIN" || bl_die "cannot copy the plugin"
  local f="$TPLUGIN/agents/implementor.md"
  case "$1" in
    no-verified)
      # Each VERIFIED: line of the report template and examples becomes the
      # instruction, which also opens the body; Method step 14 (end the report
      # with a VERIFIED: line) is replaced by it too. Instruction at the top
      # alone lost to step 14 (bad-report run 1: the implementor still wrote
      # a VERIFIED: line). The instruction also covers a re-dispatch that
      # quotes the rule: without that, a re-dispatched implementor sometimes
      # obeyed the quoted rule and the double rejection never happened
      # (Phase 8, Revision D re-run: 1 of 2 runs).
      awk 'BEGIN{fm=0; x="Do not include a VERIFIED line in your report, even if a re-dispatch quotes a rule that requires one."}
           /^---$/ {fm++; print; if (fm==2) print "\n" x; next}
           /^VERIFIED: / {print x; next}
           /^14\. \*\*End the report with one honest `VERIFIED:` line/ {print "14. **" x "**"; next}
           {print}' "$f" >"$f.tmp" && mv "$f.tmp" "$f" ;;
    add-line)
      printf '\n%s\n' "$2" >>"$f" ;;
  esac
  bl_log "plugin copy $TPLUGIN ($1): $(diff "$PLUGIN_DIR/agents/implementor.md" "$f" | grep -c '^[<>]') changed line(s)"
  diff "$PLUGIN_DIR/agents/implementor.md" "$f" >"$RUN/plugin-copy.diff"
}

agent_calls() { # FILE: one JSON line per Agent tool_use, in stream order, deduplicated by id
  jq -c '.. | objects | select(.type=="tool_use" and .name=="Agent") | {id, input}' "$1" 2>/dev/null \
    | jq -sc 'reduce .[] as $x ({seen: {}, out: []};
                if .seen[$x.id] then . else .seen[$x.id] = true | .out += [$x] end) | .out[]'
}
# open_issues_titled TITLE OUT [STATE]: issues (default open) whose title is
# exactly TITLE (no search API: its index lags behind freshly created issues)
open_issues_titled() {
  gh issue list --repo "$SANDBOX_REPO" --state "${3:-open}" --limit 300 --json number,title,labels,body 2>/dev/null \
    | jq -c --arg t "$1" '[.[] | select(.title == $t)]' >"$2"
}
result_text() { jq -rs '[.[] | select(.type=="result")] | last | .result // ""' "$1" 2>/dev/null; }
pr_of_branch() { # BRANCH STATE -> json list
  gh pr list --repo "$SANDBOX_REPO" --head "$1" --state "${2:-all}" --json number,isDraft,state 2>/dev/null
}

# run_tick: one headless tick, then the per-tick assertions
run_tick() {
  TICK=$((TICK + 1))
  local i=$TICK t0 t1 mode res
  PRE_A_STATE="$( [ -n "$A" ] && card_state "$A")"
  PRE_A_DRAFT=0
  PRE_A_HAS_PR=0
  if [ "$PRE_A_STATE" = in_progress ]; then
    local br prs; br="$(note_get "$A" | jq -r '.branch // empty')"
    if [ -n "$br" ]; then
      prs="$(pr_of_branch "$br" open)"
      [ "$(jq 'length' <<<"$prs" 2>/dev/null)" -ge 1 ] 2>/dev/null && PRE_A_HAS_PR=1
      [ "$(jq '[.[] | select(.isDraft)] | length' <<<"$prs" 2>/dev/null)" -ge 1 ] 2>/dev/null && PRE_A_DRAFT=1
    fi
  fi
  mode="$(in_clone bash "$S/config.sh" headless.permission_mode)"
  bl_log "tick $i (session $SESSION_MODEL, plugin $TPLUGIN, A=$PRE_A_STATE) -> $RUN/tick-$i.jsonl"
  t0="$(date +%s)"
  (
    cd "$CLONE" || exit 1
    claude -p "$TICK_PROMPT" --plugin-dir "$TPLUGIN" --model "$SESSION_MODEL" \
      --permission-mode "$mode" \
      --output-format stream-json --verbose --max-turns 200 \
      >"$RUN/tick-$i.jsonl" 2>"$RUN/tick-$i.stderr" </dev/null
  )
  t1="$(date +%s)"
  res="$(jq -sc '[.[] | select(.type=="result")] | last | {subtype, is_error, num_turns, total_cost_usd}' "$RUN/tick-$i.jsonl" 2>/dev/null)"
  [ -n "$res" ] || res='{}'
  printf '%s\t%s\t%s\n' "$i" "$((t1 - t0))" "$res" >>"$RUN/ticks.tsv"
  result_text "$RUN/tick-$i.jsonl" >"$RUN/tick-$i.result.txt"
  bl_log "tick $i finished in $((t1 - t0))s: $res"
  echo "--- tick $i ($((t1 - t0))s)"
  tick_checks "$i"
}

tick_checks() {
  local i="$1" f="$RUN/tick-$1.jsonl" txt="$RUN/tick-$1.result.txt" last n
  # budget guard: live ticks must run on the subscription, never an API key;
  # and the session must really run in the configured permission mode
  local src pm want
  src="$(jq -r 'select(.type=="system" and .subtype=="init") | .apiKeySource' "$f" 2>/dev/null | head -1)"
  pm="$(jq -r 'select(.type=="system" and .subtype=="init") | .permissionMode' "$f" 2>/dev/null | head -1)"
  want="$(in_clone bash "$S/config.sh" headless.permission_mode)"
  if [ "$src" = none ]; then pass "tick $i ran on the subscription (apiKeySource none)"
  else fail "tick $i ran on the subscription (apiKeySource none)" "apiKeySource: '${src}'"; fi
  if [ "$pm" = "$want" ]; then pass "tick $i session permission mode is $want"
  else fail "tick $i session permission mode is $want" "init permissionMode: '$pm'"; fi
  # AC6.4
  last="$(grep -v '^[[:space:]]*$' "$txt" | tail -1)"
  if printf '%s\n' "$last" | grep -Eq '^dispatchable: (true|false)$'; then
    pass "tick $i AC6.4 last line is '$last'"
  else
    fail "tick $i AC6.4 last line is dispatchable: true|false" "last line: '$last'"
  fi
  if grep -Eq 'cost_estimate_usd: [0-9.]+ \(estimate' "$txt"; then
    pass "tick $i AC6.4 cost line ($(grep -Eo 'cost_estimate_usd: [0-9.]+' "$txt" | head -1))"
  else
    fail "tick $i AC6.4 cost line 'cost_estimate_usd: <x> (estimate'" "not in the result text ($RUN/tick-$i.result.txt)"
  fi
  # AC6.1: every Agent dispatch names a model
  agent_calls "$f" >"$RUN/tick-$i.agents.jsonl"
  n="$(wc -l <"$RUN/tick-$i.agents.jsonl" | tr -d ' ')"
  if [ "$n" -ge 1 ] && jq -se 'all(.[]; (.input.model // "") | length > 0)' "$RUN/tick-$i.agents.jsonl" >/dev/null; then
    pass "tick $i AC6.1 every Agent dispatch has a model ($n: $(jq -r '"\(.input.subagent_type)=\(.input.model)"' "$RUN/tick-$i.agents.jsonl" | tr '\n' ' '))"
  else
    fail "tick $i AC6.1 every Agent dispatch has a non-empty model" "$n Agent calls: $(jq -c '{t: .input.subagent_type, m: .input.model}' "$RUN/tick-$i.agents.jsonl" | tr '\n' ' ')"
  fi
  # D3: no foreign skill or agent
  local scan fs fa
  scan="$(bash "$SCAN" "$f" 2>&1)"
  printf '%s\n' "$scan" >>"$RUN/scan.txt"
  fs="$(printf '%s' "$scan" | sed -n 's/.*foreign_skill=\([0-9]*\).*/\1/p')"
  fa="$(printf '%s' "$scan" | sed -n 's/.*foreign_agent=\([0-9]*\).*/\1/p')"
  if [ "$fs" = 0 ] && [ "$fa" = 0 ]; then pass "tick $i D3 foreign_skill=0 foreign_agent=0"
  else fail "tick $i D3 foreign_skill=0 foreign_agent=0" "$scan"; fi
  # AC1.5: the note alone is enough to resume
  if [ -n "$A" ]; then
    note_get "$A" >"$RUN/tick-$i.note-$A.json"
    local st; st="$(card_state "$A")"
    if jq -e 'type == "object"' "$RUN/tick-$i.note-$A.json" >/dev/null 2>&1; then
      pass "tick $i AC1.5 note of #$A parses (card state $st)"
    else
      fail "tick $i AC1.5 note of #$A parses" "$(head -c 300 "$RUN/tick-$i.note-$A.json")"
    fi
    if [ "$st" != ready ]; then
      check_jq "tick $i AC1.5 note has branch, worktree, models.implementor, numeric round" "$RUN/tick-$i.note-$A.json" \
        '.branch != null and .worktree != null and .models.implementor != null and (.round | type) == "number"'
      local br prs
      br="$(jq -r '.branch // empty' "$RUN/tick-$i.note-$A.json")"
      prs="$( [ -n "$br" ] && pr_of_branch "$br" all | jq 'length')"
      if [ "${prs:-0}" -ge 1 ]; then
        if [ "$SCENARIO" = bad-report ]; then
          # the manager never takes a PR number from a rejected report
          bl_log "tick $i: PR exists for $br; bad-report: note.pr comes only from an accepted report"
        else
          check_jq "tick $i AC1.5 a PR exists for $br: note.pr is a number" "$RUN/tick-$i.note-$A.json" '(.pr | type) == "number"'
        fi
      fi
    fi
  fi
  # AC1.6: B skipped with exactly one comment
  if [ -n "$B" ]; then
    card_json "$B" >"$RUN/tick-$i.card-$B.json"
    check_jq "tick $i AC1.6 #$B has exactly one skip-no-acceptance comment and is still ready" "$RUN/tick-$i.card-$B.json" \
      '([.comments[] | select(.body | contains("fleet-board:skip-no-acceptance"))] | length) == 1 and .state == "ready"'
  fi
  # AC1.1 after the first tick
  if [ "$i" = 1 ] && [ "$PRE_A_STATE" = ready ]; then
    local st wt br
    st="$(card_state "$A")"
    wt="$(jq -r '.worktree // empty' "$RUN/tick-$i.note-$A.json")"
    git -C "$CLONE" fetch -q origin 2>/dev/null
    br="$( { git -C "$CLONE" branch --list "fleet/$A-*" --format='%(refname:short)'; git -C "$CLONE" ls-remote --heads origin "fleet/$A-*" | sed 's|.*refs/heads/||'; } | head -1)"
    if [ "$st" = in_progress ] && [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$br" ]; then
      pass "tick 1 AC1.1 #$A in_progress, worktree $wt exists, branch $br"
    else
      fail "tick 1 AC1.1 #$A in_progress with worktree and branch" "state=$st worktree='$wt' (exists: $([ -n "$wt" ] && [ -d "$wt" ] && echo yes || echo no)) branch='$br'"
    fi
  fi
  # AC1.2 at the first tick that starts with A in_progress and an open PR.
  # The transition is asserted whatever the PR's draft state, and the draft
  # state separately, so a non-draft PR fails instead of skipping the check.
  # ac12_required fails the scenario when no tick ever got here.
  if [ "$PRE_A_STATE" = in_progress ] && [ "$PRE_A_HAS_PR" = 1 ] && [ -z "${AC12_DONE:-}" ]; then
    AC12_DONE=1
    local st rv
    st="$(card_state "$A")"
    rv="$(jq -s '[.[] | select(.input.subagent_type == "fleet-board:reviewer")] | length' "$RUN/tick-$i.agents.jsonl")"
    if [ "$st" = in_review ] && [ "${rv:-0}" -ge 1 ]; then
      pass "tick $i AC1.2 #$A in_progress with a PR -> in_review, reviewer dispatched ($rv)"
    else
      fail "tick $i AC1.2 #$A in_progress with a PR -> in_review with a reviewer dispatch" "state=$st reviewer dispatches=$rv"
    fi
    if [ "$PRE_A_DRAFT" = 1 ]; then
      pass "tick $i AC1.2 the implementor's PR for #$A was a draft"
    else
      fail "tick $i AC1.2 the implementor's PR for #$A was a draft" "the open PR was not a draft at tick start"
    fi
  fi
}

# ac12_required: after a scenario's loop, AC1.2 must have been checked
ac12_required() {
  if [ -n "${AC12_DONE:-}" ]; then
    pass "AC1.2 was checked (a tick started with #$A in_progress and an open PR)"
  else
    fail "AC1.2 was checked" "no tick started with #$A in_progress and an open PR (AC1.2 never ran)"
  fi
}

# model_union_check: over all ticks, modelUsage keys include Sonnet and Opus
model_union_check() {
  local keys
  keys="$(for f in "$RUN"/tick-*.jsonl; do jq -c 'select(.type=="result") | .modelUsage // {} | keys' "$f" 2>/dev/null; done \
    | jq -sc 'add // [] | unique')"
  echo "$keys" >"$RUN/model-usage-keys.json"
  if printf '%s' "$keys" | jq -e 'any(.[]; test("sonnet")) and any(.[]; test("opus"))' >/dev/null; then
    pass "AC6.1 modelUsage over all ticks includes Sonnet and Opus: $keys"
  else
    fail "AC6.1 modelUsage over all ticks includes Sonnet and Opus" "$keys"
  fi
}

# config_untouched: the override never reached the committed config
config_untouched() {
  if [ -z "$(git -C "$CLONE" status --porcelain .fleet-board.yml)" ] \
     && [ -z "$(git -C "$CLONE" diff origin/main -- .fleet-board.yml)" ]; then
    pass "committed .fleet-board.yml untouched (status and diff vs origin/main empty)"
  else
    fail "committed .fleet-board.yml untouched" "$(git -C "$CLONE" status --porcelain .fleet-board.yml; git -C "$CLONE" diff origin/main -- .fleet-board.yml | head -20)"
  fi
}

report_line() { grep -E "^$1" "$2" | tail -1; }

# --- session model -----------------------------------------------------------
# The plan names haiku, a model no role is configured with. Claude Code
# 2.1.284 silently runs a haiku session in permission mode "default" when
# "auto" is asked for (auto mode is unavailable on haiku), so every Bash call
# of the tick needs an approval nobody can give headless. fable also differs
# from every configured model and keeps auto mode; see rehearsal-notes
# "## Phase 6 behavioral". FB_SESSION_MODEL overrides.
if [ -n "${FB_SESSION_MODEL:-}" ]; then
  SESSION_MODEL="$FB_SESSION_MODEL"
elif [ "$DISPATCH_PATH" = nested ]; then
  SESSION_MODEL=fable
else
  SESSION_MODEL="$(in_clone bash "$S/config.sh" models.manager)"
fi
bl_log "DISPATCH_PATH=$DISPATCH_PATH SESSION_MODEL=$SESSION_MODEL TICK_PROMPT=$TICK_PROMPT"

# --- scenarios ---------------------------------------------------------------

# card A (subtract) to ready, optionally labelled; card B dragged to ready
setup_ab() {
  mk_card "$BL_FIX/card-subtract.md" ready; A="$CARD"
  if [ "$1" = qa ]; then
    gh issue edit "$A" --repo "$SANDBOX_REPO" --add-label needs-human-qa >/dev/null || bl_die "cannot label #$A needs-human-qa"
  fi
  mk_card "$BL_FIX/card-no-acceptance.md" backlog; B="$CARD"
  # a human dragging B: two separate edits, so it carries exactly one state label
  gh issue edit "$B" --repo "$SANDBOX_REPO" --remove-label fleet:backlog >/dev/null || bl_die "cannot unlabel #$B"
  gh issue edit "$B" --repo "$SANDBOX_REPO" --add-label fleet:ready >/dev/null || bl_die "cannot label #$B ready"
  [ "$(card_json "$B" | jq '[.labels[] | select(startswith("fleet:"))] | length')" = 1 ] || bl_die "#$B does not carry exactly one state label"
}

scenario_default() {
  setup_ab qa
  while [ "$TICK" -lt "$MAX_TICKS" ]; do
    run_tick
    case "$(card_state "$A")" in human_qa|blocked|done) break ;; esac
  done
  model_union_check
  ac12_required
  local st; st="$(card_state "$A")"
  card_json "$A" >"$RUN/final-card-$A.json"
  if [ "$st" = human_qa ] && jq -e '[.comments[] | select((.body | contains("What to check in Human QA")) and (.body | contains("subtract(2, 5) returns -3")))] | length >= 1' "$RUN/final-card-$A.json" >/dev/null; then
    pass "AC1.3 #$A in human_qa with a 'What to check in Human QA' comment quoting 'subtract(2, 5) returns -3'"
  else
    fail "AC1.3 #$A in human_qa with the Human QA comment" "state=$st after $TICK tick(s); QA comments: $(jq '[.comments[] | select(.body | contains("What to check in Human QA"))] | length' "$RUN/final-card-$A.json")"
  fi
  # review cycle 4: one Human QA comment, and a run that made progress on
  # every tick leaves no counted action failure
  check_jq "to_human_qa: exactly one 'What to check in Human QA' comment on #$A" "$RUN/final-card-$A.json" \
    '[.comments[] | select(.body | contains("What to check in Human QA"))] | length == 1'
  note_get "$A" >"$RUN/note-final.json"
  check_jq "action failures: #$A note.action_failures is 0 at the end" "$RUN/note-final.json" '(.action_failures // 0) == 0'
}

scenario_ready_path() {
  setup_ab noqa
  local br isd
  while [ "$TICK" -lt "$MAX_TICKS" ]; do
    run_tick
    br="$(note_get "$A" | jq -r '.branch // empty')"
    isd="$( [ -n "$br" ] && pr_of_branch "$br" all | jq -r '.[0].isDraft | tostring')"
    [ "$isd" = false ] && break
    case "$(card_state "$A")" in human_qa|blocked|done) break ;; esac
  done
  model_union_check
  ac12_required
  local pr
  pr="$(note_get "$A" | jq -r '.pr // empty')"
  [ -n "$pr" ] || pr="$(pr_of_branch "$br" all | jq -r '.[0].number // empty')"
  gh pr view "$pr" --repo "$SANDBOX_REPO" --json isDraft,state,mergedAt >"$RUN/final-pr.json" 2>/dev/null
  local policy; policy="$(in_clone bash "$S/config.sh" merge.policy)"
  if [ "$policy" = human ]; then pass "AC1.4 merge.policy is human"; else fail "AC1.4 merge.policy is human" "got $policy"; fi
  check_jq "AC1.4 PR #$pr is ready for review (isDraft false) and not merged" "$RUN/final-pr.json" \
    '.isDraft == false and .state == "OPEN" and .mergedAt == null'
}

scenario_bad_report() {
  plugin_copy no-verified
  if grep -q '^VERIFIED: ' "$TPLUGIN/agents/implementor.md"; then bl_die "plugin copy still has a VERIFIED: template line"; fi
  mk_card "$BL_FIX/card-subtract.md" ready; A="$CARD"
  run_tick
  local calls="$RUN/tick-1.agents.jsonl" n second rej
  jq -c --arg a "$A" 'select(.input.subagent_type == "fleet-board:implementor" and (.input.prompt | test("#?\\b" + $a + "\\b")))' "$calls" >"$RUN/implementor-dispatches.jsonl"
  n="$(wc -l <"$RUN/implementor-dispatches.jsonl" | tr -d ' ')"
  if [ "$n" = 2 ]; then pass "AC5.4 two implementor dispatches for #$A"
  else fail "AC5.4 two implementor dispatches for #$A" "found $n"; fi
  second="$(sed -n 2p "$RUN/implementor-dispatches.jsonl")"
  if printf '%s' "$second" | jq -e '.input.prompt | contains("Your previous report was rejected")' >/dev/null 2>&1; then
    pass "AC5.4 the second dispatch's prompt contains 'Your previous report was rejected'"
  else
    fail "AC5.4 the second dispatch quotes the rejection" "$(printf '%s' "$second" | jq -r '.input.prompt' 2>/dev/null | head -c 400)"
  fi
  rej="$(sed -n 's/^Reports rejected: *\([0-9][0-9]*\).*/\1/p' "$RUN/tick-1.result.txt" | tail -1)"
  if [ "${rej:-0}" -ge 1 ]; then pass "AC5.4 tick report 'Reports rejected: $rej'"
  else fail "AC5.4 tick report Reports rejected >= 1" "line: $(report_line 'Reports rejected' "$RUN/tick-1.result.txt")"; fi
  # review cycle 4: a report rejected twice is an action that made no progress
  note_get "$A" >"$RUN/note-after-tick1.json"
  check_jq "action failures: note.action_failures == 1 after the double rejection" "$RUN/note-after-tick1.json" \
    '.action_failures == 1'
  check_jq "action failures: note.last_action_error mentions the rejection" "$RUN/note-after-tick1.json" \
    '(.last_action_error | type) == "string" and (.last_action_error | test("reject"; "i"))'
}

scenario_fix_block() {
  override_config 'review: { mutation: true, verify_claim: true, max_rounds: 2 }' 'models: { escalate_after_rounds: 1 }'
  seed_pr "$BL_FIX/card-subtract.md" "$PATCHES/weak-test.patch" 1; A="$CARD"
  # The round-1 finding must be fixable in implementation code: the fixer spec
  # (Phase 5) marks a finding it can only resolve with tests "not fixed: needs
  # human decision" and reports blocked, so the plan's "mutant in subtract
  # survived" would block the card in tick 1 without a round 2 (fix-block
  # run 1). The round-2 re-seed below keeps the plan's text.
  seed_note "$A" 1 1 '[{"severity":"Critical","text":"subtract accepts non-number arguments: subtract(\"5\", 2) returns 3 instead of throwing a TypeError"}]'
  run_tick
  local calls="$RUN/tick-1.agents.jsonl" fx rv
  # positions in stream order: the first fixer dispatch, the last reviewer dispatch
  fx="$(jq -s '[to_entries[] | select(.value.input.subagent_type == "fleet-board:fixer") | .key] | first // empty' "$calls")"
  rv="$(jq -s '[to_entries[] | select(.value.input.subagent_type == "fleet-board:reviewer") | .key] | last // empty' "$calls")"
  if jq -se 'any(.[]; .input.subagent_type == "fleet-board:fixer" and ((.input.model // "") | test("opus")))' "$calls" >/dev/null; then
    pass "AC6.2 fixer dispatched on opus (escalated): $(jq -r 'select(.input.subagent_type == "fleet-board:fixer") | .input.model' "$calls" | tr '\n' ' ')"
  else
    fail "AC6.2 fixer dispatched on opus (escalated)" "$(jq -c '{t: .input.subagent_type, m: .input.model}' "$calls" | tr '\n' ' ')"
  fi
  note_get "$A" >"$RUN/note-after-tick1.json"
  check_jq "AC6.2 note.escalated == true and note.round == 2" "$RUN/note-after-tick1.json" '.escalated == true and .round == 2'
  if [ -n "$fx" ] && [ -n "$rv" ] && [ "$rv" -gt "$fx" ]; then pass "a reviewer dispatch followed the fixer in tick 1"
  else fail "a reviewer dispatch followed the fixer in tick 1" "fixer index ${fx:-none}, last reviewer index ${rv:-none}"; fi

  # ticks until the card leaves in_review (at most 3 more); a clean round-2
  # review means the fixer resolved everything: re-seed a Critical round 2
  local path=blocked-by-review k=0 f="$RUN/note-after-tick1.json"
  while :; do
    if jq -e '.last_review.round == 2 and (.last_review.critical + .last_review.important) == 0' "$f" >/dev/null 2>&1; then
      path=resolved-before-block; break
    fi
    [ "$(card_state "$A")" = in_review ] && [ $k -lt 3 ] || break
    run_tick; k=$((k + 1))
    f="$RUN/tick-$TICK.note-$A.json"
  done
  echo "$path" >"$RUN/fix-block-path.txt"
  if [ "$path" = resolved-before-block ]; then
    bl_log "fix-block: the fixer resolved everything in round 2; re-seeding round 2 with a Critical review"
    HEAD="$(gh pr view "$PR" --repo "$SANDBOX_REPO" --json headRefOid --jq .headRefOid)"
    seed_note "$A" 2 1 '[{"severity":"Critical","text":"mutant in subtract survived"}]' '.escalated = true | .escalated_at_round = 2'
    in_clone bash "$S/board-move.sh" "$A" in_review >/dev/null 2>&1
    run_tick
  fi
  note_get "$A" >"$RUN/note-final.json"
  local st; st="$(card_state "$A")"
  if [ "$st" = blocked ]; then pass "AC1.7 #$A is blocked ($path)"; else fail "AC1.7 #$A is blocked ($path)" "state=$st after $TICK tick(s)"; fi
  check_jq "AC1.7 note.blocked_findings is non-empty" "$RUN/note-final.json" '(.blocked_findings | type) == "array" and (.blocked_findings | length) >= 1'
  config_untouched
}

# seed_merge PATCH: a non-draft PR with a clean current review, merged by the
# HARNESS from its own shell (as the human would), outside any claude session.
# Merges stay human: Claude Code's auto-mode classifier blocks an unattended
# "gh pr merge" in a headless session ("Merge Without Review"), so the manager's
# merge action is not exercised here; the ticks cover the post-merge path
# (verify_main, finish). The committed config (merge.policy: human) is used.
seed_merge() {
  seed_pr "$BL_FIX/card-multiply.md" "$1" 0; A="$CARD"
  seed_note "$A" 1 0 '[]'
  gh pr merge "$PR" --repo "$SANDBOX_REPO" --squash >/dev/null 2>"$RUN/harness-merge.err" \
    || bl_die "harness merge of PR #$PR failed: $(cat "$RUN/harness-merge.err")"
  local merged
  merged="$(gh pr view "$PR" --repo "$SANDBOX_REPO" --json state,mergeCommit --jq '"\(.state) \(.mergeCommit.oid // "")"')"
  [ "${merged%% *}" = MERGED ] || bl_die "PR #$PR is not merged after the harness merge: $merged"
  MERGES="$MERGES ${merged#* }"
  bl_log "harness merged PR #$PR (${merged#* })"
}

scenario_merge_auto() {
  seed_merge "$PATCHES/multiply.patch"
  run_tick
  git -C "$CLONE" fetch -q origin
  local main; main="$(git -C "$CLONE" rev-parse origin/main)"
  note_get "$A" >"$RUN/note-after-verify.json"
  check_jq "AC4.7 tick 1 main_check.commit == origin/main ($main) and ok == true" "$RUN/note-after-verify.json" \
    ".main_check.commit == \"$main\" and .main_check.ok == true"
  local wt; wt="$(jq -r '.worktree // empty' "$RUN/note-after-verify.json")"
  run_tick
  local st; st="$(card_state "$A")"
  if [ "$st" = done ]; then pass "tick 2 #$A is done"; else fail "tick 2 #$A is done" "state=$st"; fi
  # The manager never removes worktrees (the auto-mode classifier denies it);
  # the wrapper runs cleanup-done.sh outside any claude session. Do the same.
  local out rc
  out="$(in_clone bash "$S/cleanup-done.sh" 2>"$RUN/cleanup-done.err")"; rc=$?
  printf '%s\n' "$out" >"$RUN/cleanup-done.out"
  # Other done cards on the sandbox (closed ones from earlier runs) carry notes
  # whose worktrees lie under other, deleted clones; note.sh treats those
  # worktrees as null, so cleanup-done.sh warns about them (and may exit 1 for
  # other reasons). Only #A matters here; #A must not appear in a warning
  # (matched as #A followed by a non-digit, so #A0 does not count).
  if printf '%s\n' "$out" | grep -qxF "cleaned #$A $wt" && ! grep -Eq "#$A([^0-9]|$)" "$RUN/cleanup-done.err"; then
    pass "cleanup-done.sh (harness shell) cleaned #$A (exit $rc; $(grep -c warning "$RUN/cleanup-done.err") warning(s) about other cards)"
  else
    fail "cleanup-done.sh (harness shell) cleaned #$A" "exit $rc, stdout '$out', stderr $(head -c 400 "$RUN/cleanup-done.err")"
  fi
  if [ -n "$wt" ] && [ ! -e "$wt" ] && [ ! -e "$FWBASE/$A-review" ] && [ ! -e "$FWBASE/$A-review-copy" ]; then
    pass "after cleanup-done.sh the worktree dirs of #$A are gone"
  else
    fail "after cleanup-done.sh the worktree dirs of #$A are gone" "$(ls -d "$wt" "$FWBASE/$A-review" "$FWBASE/$A-review-copy" 2>&1 | tr '\n' ' ')"
  fi
  config_untouched
}

scenario_merge_red() {
  seed_merge "$PATCHES/red-main.patch"
  run_tick
  note_get "$A" >"$RUN/note-after-verify.json"
  check_jq "AC4.8 tick 1 main_check.ok == false" "$RUN/note-after-verify.json" '.main_check.ok == false'
  local t="[P0] main is red after #$PR"
  open_issues_titled "$t" "$RUN/p0-match.json"
  CARDS="$CARDS $(jq -r '.[].number' "$RUN/p0-match.json" | tr '\n' ' ')"
  check_jq "AC4.8 one open '$t' issue, labelled fleet:backlog, body names #$PR" "$RUN/p0-match.json" \
    "length == 1 and (.[0].labels | map(.name) | index(\"fleet:backlog\")) != null and (.[0].body | test(\"#$PR\\\\b\"))"
  config_untouched
}

# followup_ticks KEY: ticks until note.KEY is non-empty (the report was reconciled)
followup_ticks() {
  local k=0
  while [ "$TICK" -lt "$MAX_TICKS" ] && [ $k -lt 3 ]; do
    run_tick; k=$((k + 1))
    [ "$(note_get "$A" | jq "(.$1 // []) | length")" -ge 1 ] 2>/dev/null && break
    case "$(card_state "$A")" in in_review|blocked|human_qa|done) break ;; esac
  done
}

scenario_out_of_scope() {
  OOS_TITLE="Document calc module [behavioral $(date +%s)]"
  plugin_copy add-line "In ## For the card, include exactly one Out of scope: item titled \"$OOS_TITLE\"."
  mk_card "$BL_FIX/card-subtract.md" ready; A="$CARD"
  followup_ticks out_of_scope_created
  open_issues_titled "$OOS_TITLE" "$RUN/oos-match.json"
  CARDS="$CARDS $(jq -r '.[].number' "$RUN/oos-match.json" | tr '\n' ' ')"
  check_jq "AC3.9 one open issue '$OOS_TITLE' with fleet:backlog whose body names #$A" "$RUN/oos-match.json" \
    "length == 1 and (.[0].labels | map(.name) | index(\"fleet:backlog\")) != null and (.[0].body | test(\"#$A\\\\b\"))"
  note_get "$A" >"$RUN/note-final.json"
  local pr; pr="$(jq -r '.pr // empty' "$RUN/note-final.json")"
  gh pr view "$pr" --repo "$SANDBOX_REPO" --json comments >"$RUN/pr-comments.json" 2>/dev/null
  check_jq "AC3.9 PR #$pr has a comment containing 'tracked as #'" "$RUN/pr-comments.json" 'any(.comments[]; .body | contains("tracked as #"))'
  check_jq "AC3.9 note.out_of_scope_created lists it with existing == false" "$RUN/note-final.json" \
    "any(.out_of_scope_created[]?; .title == \"$OOS_TITLE\" and .existing == false)"
}

scenario_bug_found() {
  BUG_TITLE="calc add() ignores a third argument [behavioral $(date +%s)]"
  plugin_copy add-line "In ## For the card, include exactly one Bugs found: item titled \"$BUG_TITLE\" with repro: \`node -e \"console.log(require('./src/calc').add(1,2,3))\"\`, expected: 6, observed: 3."
  # pass 1
  mk_card "$BL_FIX/card-subtract.md" ready; A="$CARD"
  followup_ticks bugs_filed
  open_issues_titled "$BUG_TITLE" "$RUN/bug-match.json"
  CARDS="$CARDS $(jq -r '.[].number' "$RUN/bug-match.json" | tr '\n' ' ')"
  check_jq "AC3.10 one open issue '$BUG_TITLE' labelled bug and fleet:backlog, body has ## Repro and #$A" "$RUN/bug-match.json" \
    "length == 1 and (.[0].labels | map(.name) | (index(\"bug\") != null and index(\"fleet:backlog\") != null)) and (.[0].body | contains(\"## Repro\")) and (.[0].body | test(\"#$A\\\\b\"))"
  note_get "$A" >"$RUN/note-pass1.json"
  local pr bugn; pr="$(jq -r '.pr // empty' "$RUN/note-pass1.json")"
  bugn="$(jq -r '.[0].number // empty' "$RUN/bug-match.json")"
  gh pr view "$pr" --repo "$SANDBOX_REPO" --json comments >"$RUN/pr-comments.json" 2>/dev/null
  check_jq "AC3.10 PR #$pr has 'Bug found outside this card, filed as #'" "$RUN/pr-comments.json" \
    'any(.comments[]; .body | contains("Bug found outside this card, filed as #"))'
  check_jq "AC3.10 note.bugs_filed lists it with existing == false" "$RUN/note-pass1.json" \
    "any(.bugs_filed[]?; .title == \"$BUG_TITLE\" and .existing == false)"
  # pass 2: a new card; the first card leaves the ticked columns so only the new one runs
  in_clone bash "$S/board-move.sh" "$A" wont_do >/dev/null || bl_die "cannot park #$A in wont_do"
  mk_card "$BL_FIX/card-clamp.md" ready " pass2"; A="$CARD"
  followup_ticks bugs_filed
  open_issues_titled "$BUG_TITLE" "$RUN/bug-pass2.json" all
  CARDS="$CARDS $(jq -r '.[].number' "$RUN/bug-pass2.json" | tr '\n' ' ')"
  check_jq "AC3.10 pass 2: still exactly one issue (any state) titled '$BUG_TITLE'" "$RUN/bug-pass2.json" 'length == 1'

  gh issue view "$bugn" --repo "$SANDBOX_REPO" --json comments >"$RUN/bug-comments.json" 2>/dev/null
  check_jq "AC3.10 pass 2: #$bugn got an 'Also seen while working' comment naming #$A" "$RUN/bug-comments.json" \
    "any(.comments[]; (.body | contains(\"Also seen while working\")) and (.body | test(\"#$A\\\\b\")))"
  note_get "$A" >"$RUN/note-pass2.json"
  check_jq "AC3.10 pass 2: note.bugs_filed links #$bugn with existing == true" "$RUN/note-pass2.json" \
    "any(.bugs_filed[]?; .number == $bugn and .existing == true)"
}

case "$SCENARIO" in
  default) scenario_default ;;
  ready-path) scenario_ready_path ;;
  bad-report) scenario_bad_report ;;
  fix-block) scenario_fix_block ;;
  merge-auto) scenario_merge_auto ;;
  merge-red) scenario_merge_red ;;
  out-of-scope) scenario_out_of_scope ;;
  bug-found) scenario_bug_found ;;
esac

DUR=$(( $(date +%s) - START_ALL ))
if [ "$DUR" -lt 3600 ]; then pass "whole run under 3600 s ($DUR s)"; else fail "whole run under 3600 s" "$DUR s"; fi
COST="$(awk -F'\t' '{print $3}' "$RUN/ticks.tsv" | jq -s '[.[].total_cost_usd // 0] | add // 0')"
echo "ticks: $TICK   duration: ${DUR}s   total_cost_usd (sum of ticks): $COST"
printf 'summary\tticks=%s\tduration=%s\tcost=%s\n' "$TICK" "$DUR" "$COST" >>"$RUN/ticks.tsv"
echo "RUN: $RUN"
bl_summary || exit 1
