#!/usr/bin/env bash
#
# Shared helpers for the tick-plan suites (test-tick-plan-<area>.sh): the fake-gh
# setup, plan/splan/settle runners, the assertions and the scenario builders.
# Sourced by each suite, never run on its own (its name keeps it out of the
# tests/test-*.sh glob). One file, so the suites cannot drift apart.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh" # the local store, rebuilt from the routes before each run
SCRIPT="${SCRIPT_DIR}/../scripts/tick-plan.sh"
NOTE_SH="${SCRIPT_DIR}/../scripts/note.sh"
TICK="$SCRIPT_DIR/../fixtures/gh/tick"
# The absolute scripts dir, as tick-plan.sh resolves its own (cd && pwd)
SCRIPTS_ABS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

# FLEET_TEST_ONLY=<exact check name> runs only the scenario that holds that check (commands.test_case).
# At load, the suite file ($0) is scanned for the one assertion whose quoted name is that name: line L.
# P is the last scenario-opening call before it (a lib or suite helper that reaches setup_case). Helpers
# called from a suite line outside [P, L] do nothing (tp_skip, from BASH_LINENO); inside, everything
# runs, but only the selected check prints and counts. Empty or unset: nothing here changes a run.
TP_ONLY="${FLEET_TEST_ONLY:-}"
TP_P=0
TP_L=0
TP_OPENERS=""
TP_AWK='
function iscall(line, name,   re) {
  if (line ~ /^[ \t]*#/) return 0
  re = "(^|[;&|({!]|[ \t](then|do|else|if|elif))[ \t]*([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*" name "([ \t;&|)]|$)"
  return line ~ re
}
FNR == 1 { fileno++; cur = "" }
{
  line = $0
  if (fileno == 2) { S[FNR] = line; ns = FNR }
  if (cur != "") {
    body[cur] = body[cur] "\n" line
    if (fileno == 2) fnl[FNR] = 1
    if (line ~ /^[}]/) cur = ""
    next
  }
  if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[(][)] *[{]/) {
    nm = line; sub(/[(].*/, "", nm); isfn[nm] = 1
    rest = line; sub(/^[^{]*[{]/, "", rest)
    body[nm] = body[nm] "\n" rest
    if (fileno == 2) fnl[FNR] = 1
    if (rest !~ /[}][ \t]*$/) cur = nm
  }
}
END {
  name = ENVIRON["TP_NAME"]
  op["setup_case"] = 1
  do {
    ch = 0
    for (f in isfn) {
      if (f in op) continue
      n = split(body[f], bl, "\n")
      for (i = 1; i <= n; i++) {
        hit = 0
        for (o in op) if (iscall(bl[i], o)) { hit = 1; break }
        if (hit) { op[f] = 1; ch = 1; break }
      }
    }
  } while (ch)
  cnt = 0; L = 0; nfn = 0
  for (i = 1; i <= ns; i++) {
    if (S[i] ~ /^[ \t]*#/) continue
    idx = index(S[i], "\"" name "\"")
    if (idx > 0 && substr(S[i], 1, idx - 1) ~ /(^|[^A-Za-z0-9_])(assert_[a-z_]+|pass)[ \t]+$/) {
      if (fnl[i]) nfn++; else { cnt++; if (!L) L = i }
    }
  }
  P = 1
  for (i = L; i >= 1 && L; i--) {
    if (fnl[i]) continue
    hit = 0
    for (o in op) if (iscall(S[i], o)) { hit = 1; break }
    if (hit) { P = i; break }
  }
  print cnt, L, P, nfn
  list = ""
  for (o in op) list = list " " o
  print list
}'
if [ -n "$TP_ONLY" ]; then
  tp_sel="$(TP_NAME="$TP_ONLY" awk "$TP_AWK" "$SCRIPT_DIR/tick-plan-lib.sh" "$0")"
  read -r tp_count TP_L TP_P tp_nfn <<<"$(printf '%s\n' "$tp_sel" | sed -n 1p)"
  TP_OPENERS="$(printf '%s\n' "$tp_sel" | sed -n 2p)"
  if [ "$tp_count" = 0 ]; then
    if [ "$tp_nfn" != 0 ]; then
      echo "FLEET_TEST_ONLY=$TP_ONLY: 0 test(s) selected (the check is inside a function; select a check outside functions)" >&2
    else
      echo "FLEET_TEST_ONLY=$TP_ONLY: 0 test(s) selected" >&2
    fi
    exit 5
  fi
  if [ "$tp_count" -gt 1 ]; then
    echo "FLEET_TEST_ONLY=$TP_ONLY matches $tp_count checks" >&2
    exit 5
  fi
fi

# tp_skip: succeeds when FLEET_TEST_ONLY is set and the suite line that reached this helper (the
# outermost frame called from the suite file) lies outside the selected window
tp_skip() {
  [ -n "$TP_ONLY" ] || return 1
  local i ln=""
  i=$(( ${#BASH_SOURCE[@]} - 2 ))
  while [ "$i" -ge 0 ]; do
    if [ "${BASH_SOURCE[$((i + 1))]}" = "$0" ]; then ln="${BASH_LINENO[$i]}"; break; fi
    i=$((i - 1))
  done
  [ -n "$ln" ] || return 1
  [ "$ln" -lt "$TP_P" ] || [ "$ln" -gt "$TP_L" ]
}
# tp_mine <check name>: under FLEET_TEST_ONLY only the selected check reports
tp_mine() { [ -z "$TP_ONLY" ] || [ "$1" = "$TP_ONLY" ]; }

unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
LAST_OUT=""
LAST_ERR=""
LAST_EXIT=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"

if [ -x /bin/bash ]; then
  BASH_EXE="/bin/bash"
else
  BASH_EXE="bash"
fi

cleanup() {
  for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$dir" 2>/dev/null || true
  done
}
trap cleanup EXIT

pass() { tp_skip && return 0; tp_mine "$1" || return 0; PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { tp_skip && return 0; tp_mine "$1" || return 0; FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

assert_exit() {
  if [ "$LAST_EXIT" = "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $LAST_EXIT (stderr: $LAST_ERR)"; fi
}

assert_stdout_exact() {
  if [ "$LAST_OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected stdout: '$2', got: '$LAST_OUT'"; fi
}

assert_stderr_exact() {
  if [ "$LAST_ERR" = "$2" ]; then pass "$1"; else fail "$1" "expected exact stderr: '$2', got: '$LAST_ERR'"; fi
}

assert_stderr_not_contains() {
  case "$LAST_ERR" in
    *"$2"*) fail "$1" "did not expect '$2' in stderr" ;;
    *) pass "$1" ;;
  esac
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

run_check() {
  store_sync
  local script="$1"
  shift
  local tmpout tmperr
  tmpout="$(mktemp)"
  tmperr="$(mktemp)"
  "$BASH_EXE" "$script" "$@" > "$tmpout" 2> "$tmperr"
  LAST_EXIT=$?
  LAST_OUT="$(cat "$tmpout")"
  LAST_ERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
}

# jq -c of the last stdout; INVALID when it does not parse
jqc() { jq -c "$1" <<<"$LAST_OUT" 2>/dev/null || echo INVALID; }

# assert_jq <desc> <filter> <expected compact JSON>
assert_jq() { assert_eq "$1" "$(jqc "$2")" "$3"; }

# no_builtin_stages <extra YAML>: the extra YAML with the two built-in review
# stages (documentation, blast_radius) disabled, so a case that is not about them
# sees the board it was written for. TP_KEEP_BUILTINS=1 leaves them on.
no_builtin_stages() {
  local x="$1" dis nl
  nl="$(printf '\nx')"; nl="${nl%x}"
  dis="$(printf '    - name: documentation\n      enabled: false\n    - name: blast_radius\n      enabled: false')"
  if [ "${TP_KEEP_BUILTINS:-}" = 1 ]; then printf '%s' "$x"; return; fi
  if ! printf '%s\n' "$x" | grep -c '^review:' >/dev/null; then
    printf '%s%sreview:\n  stages:\n%s' "$x" "${x:+$nl}" "$dis"
  elif printf '%s\n' "$x" | grep -c '^  stages:' >/dev/null; then
    DIS="$dis" awk '{print} /^  stages:/ {print ENVIRON["DIS"]}' <<<"$x"
  else
    DIS="$dis" awk '{print} /^review:/ {print "  stages:"; print ENVIRON["DIS"]}' <<<"$x"
  fi
}

# setup_case <case> [extra YAML appended to the config]
# premise_check.enabled is written false unless the extra YAML sets the key.
setup_case() {
  REPO="$(mktemp -d)"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  {
    printf 'board:\n  repo: acme/toy\n'
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'worktrees:\n  dir: .fw\n'
    printf 'human_qa_paths: ["src/components/**"]\n'
    # the premise check is off unless the case turns it on (it plans check_premise in place of start)
    case "
${2:-}
${3:-}
" in
      *'
premise_check:'*) ;;
      *) printf 'premise_check:\n  enabled: false\n' ;;
    esac
    printf '%s\n' "$(no_builtin_stages "${2:-}")"
  } > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml
  git -C "$REPO" commit -q -m "initial"

  FAKE_GH_DIR="$(mktemp -d)"
  BIN="$FAKE_GH_DIR/bin"
  mkdir -p "$BIN"
  ln -s "$SCRIPT_DIR/fake-gh.sh" "$BIN/gh"

  # Reset environment between cases
  unset CDPATH FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT FLEET_BOARD_CONFIG || true
  PATH="$BIN:$ORIG_PATH"
  FAKE_GH_ROUTES="$TICK/$1/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH

  cd "$REPO"
  BASE="$(mkdir -p "$REPO/.fw" && cd "$REPO/.fw" && pwd -P)"

  CLEANUP_DIRS+=("$REPO")
  CLEANUP_DIRS+=("$FAKE_GH_DIR")
}

# plan <case> [extra YAML]: set up and run tick-plan.sh
plan() { setup_case "$@"; run_check "$SCRIPT"; }

# warns_json <text>...: the compact JSON array of the given warnings
warns_json() { jq -cn '$ARGS.positional' --args "$@"; }

# card <n> <field>: jq path of one card in the plan
card() { printf '(.cards[] | select(.number == %d)).%s' "$1" "$2"; }

# The calls whose argv (one element per line) is exactly the given words
call_count() {
  local want f n=0
  want="$(printf '%s\n' "$@")"
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

DEFAULT_MODELS='{"implementor":"sonnet","reviewer":"opus","fixer":"sonnet"}'
ESCALATED_MODELS='{"implementor":"opus","reviewer":"opus","fixer":"opus"}'

echo "Test: tick-plan.sh"
echo ""

# tp_finish: the summary line every suite ends with, and its exit status
tp_finish() {
  echo "-----------------------------------"
  printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
  if [ -n "$TP_ONLY" ] && [ $((PASS + FAIL)) -eq 0 ]; then
    echo "FLEET_TEST_ONLY=$TP_ONLY: the selected check did not run" >&2
    exit 1
  fi
  [ "$FAIL" -eq 0 ] || exit 1
}

AUTO="$(printf 'merge:\n  policy: auto')"
STAGES_ADVISORY_YAML="$(printf '%s\n' 'review:' '  stages:' '    - name: security' '      agent: "acme:sec"' '      model: opus' '    - name: ux' '      agent: ux-reviewer' '      model: sonnet' '      advisory: true')"
settle_skips_merging() { setup_case "$1" "$AUTO"; run_check "$SCRIPT" --settle-merge "$2"; }
# gh calls for one in_review card: the card is read from the local store (no
# gh call), then the PR view, the mergeable lookup, and the files lookup only
# when the review is clean and current. (On the GitHub board the card read
# added three: api user, issue, comments; before the note and labels were taken
# from the card read: 11 per card.)
per_card_calls() { echo $(( $(wc -l < "$FAKE_GH_DIR/calls.log") - $(grep -c $'\tissue list' "$FAKE_GH_DIR/calls.log") )); }
# Other columns with no PR still wait
# A done card that still holds pending items warns, naming each title.
# done_case <dir-name> <n> <state> <titles json>: writes a routes file (absolute
# paths, in a temp dir) for one card in <state> holding those pending items
done_case() {
  local d n st t body c
  d="$(mktemp -d)"; CLEANUP_DIRS+=("$d"); n="$2"; st="$3"; t="$4"
  jq -nc --argjson n "$n" --arg st "$st" '{number:$n,title:"Old card",html_url:"u",body:"Done.\n\n## Acceptance\n- it works\n",labels:[{name:("fleet:"+$st)}]}' > "$d/issue.json"
  jq -nc --argjson n "$n" --arg st "$st" '[{number:$n,title:"Old card",url:"u",labels:[{name:("fleet:"+$st)}]}]' > "$d/list.json"
  body="$(printf '<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: %s\n\n```json\n%s\n```\n' "$st" \
    "$(jq -nc --arg st "$st" --argjson n "$n" --argjson t "$t" '{state:$st,branch:"fleet/\($n)-old-card",pr:null,round:null,pending_followups:{out_of_scope:$t,bugs:[],pr:null}}')")"
  jq -nc --arg b "$body" '[{id:555,user:{login:"fleet-bot"},body:$b,created_at:"2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    printf 'api repos/acme/toy/issues/%s\t0\t%s/issue.json\n' "$n" "$d"
    printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments.json\n' "$n" "$d"
    for c in ready in_progress in_review blocked; do printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/common/empty.json\n' "$c" "$TICK"; done
    printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list.json\n' "$st" "$d"
  } > "$d/routes"
  DONE_CASE_DIR="$d"
}
plan_routes() {
  # like plan, with the routes file at "$1/routes"
  setup_case ready-start
  FAKE_GH_ROUTES="$1/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
# update_branch: a PR whose mergeable state is CONFLICTING is brought up to
# date by a merge. Routes are built at run time from an existing scenario plus
# a "pr view <pr> --json mergeable" answer, so no fixture directory is needed.
plan_mergeable() { # <case> <pr> <mergeable>
  setup_case "$1"
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  printf '{"mergeable":"%s"}\n' "$3" > "$d/mergeable.json"
  {
    printf 'pr view %s --repo acme/toy --json mergeable\t0\t%s\n' "$2" "$d/mergeable.json"
    sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-#	$TICK/$1/comments-#" "$TICK/$1/routes"
  } > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
# Conflicted files in the note: update-branch.sh recorded them after aborting a
# conflicting merge, so the card plans the fixer with those files as findings.
# plan_note builds the card's comments at run time from an existing in-review
# scenario and the given note JSON, so no fixture directory is needed.
plan_note() { # <note-json> [mergeable]
  setup_case action-failures-in-review-3
  local d="$FAKE_GH_DIR/routes.d"
  mkdir -p "$d"
  jq -cn --arg note "$1" '[{id: 555, user: {login: "fleet-bot"},
    body: ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\nState: x\n\n```json\n" + $note + "\n```\n"),
    created_at: "2026-09-28T00:01:00Z"}]' > "$d/comments.json"
  {
    if [ -n "${2:-}" ]; then
      printf '{"mergeable":"%s"}\n' "$2" > "$d/mergeable.json"
      printf 'pr view 34 --repo acme/toy --json mergeable\t0\t%s\n' "$d/mergeable.json"
    fi
    sed -e "s#	\.\./#	$TICK/#" -e "s#	comments-12.json#	$d/comments.json#" "$TICK/action-failures-in-review-3/routes"
  } > "$d/routes"
  FAKE_GH_ROUTES="$d/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
CONFLICT_NOTE='{"state":"in_review","branch":"fleet/12-add-subtract","pr":34,"round":1,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]},"action_failures":1,"last_action_error":"merge conflicts","conflicted_files":["src/calc.js","src/util.js","test/calc.test.js"]}'
# settle mode: tick-plan.sh --settle-merge <n>... (merge-reviewed.sh's planner) plans only the steps that
# start no agent, plus merge and verify_main. The by-hand --settle flag went with the by-hand settle script (0.27.0).
# settle <case> <n> [extra YAML]: set up the case and run --settle-merge <n>
settle() { local c="$1" n="$2"; shift 2; setup_case "$c" "$@"; run_check "$SCRIPT" --settle-merge "$n"; }
# every other table action is skipped, with a reason naming the action
settle_skips() { # <case> <card> <table action> [extra YAML]
  settle "$1" "$2" "${4:-}"
  assert_jq "settle: table action $3 plans skip ($1)" "$(card "$2" action)" '"skip"'
  assert_jq "settle: skip reason names $3 ($1)" "$(card "$2" reason)" "$(jq -cn --arg a "$3" '"\($a) waits for the next tick"')"
  assert_jq "settle: dispatchable false for $3 ($1)" '.dispatchable' 'false'
}
# Merge only reviewed heads: a clean review whose head moved past last_review.
# plan_real <kind>: builds real commits in the case repo (the plan checks them
# with git merge-tree) and routes the fake gh to them. kind is conflict (a
# merge of main whose conflict a person resolved), clean (a merge of main with
# no conflict) or nonmerge (an ordinary commit).
plan_real() {
  local kind="$1" b0 r m h dir main_msg mrg="${2:-}" qa="${3:-}" fnd="${4:-}" issue=in_review inrev=list-in_review-12.json files=files-plain.json
  [ -z "$mrg" ] || { issue=merging; inrev=empty.json; }
  [ -z "$qa" ] || files=files-components.json
  setup_case drift-clean "$(printf 'merge:\n  policy: auto')"
  dir="$FAKE_GH_DIR/real"; mkdir -p "$dir"
  printf 'base\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -q -m "add f"
  b0="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b feat
  printf 'feature\n' > "$REPO/f.txt"; git -C "$REPO" commit -q -am "feature change"
  r="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b mainline "$b0"
  if [ "$kind" = conflict ]; then printf 'mainline\n' > "$REPO/f.txt"; else printf 'other\n' > "$REPO/g.txt"; git -C "$REPO" add g.txt; fi
  git -C "$REPO" commit -q -am "change on main"
  m="$(git -C "$REPO" rev-parse HEAD)"
  # mainline is the base branch: publish it as origin/main, as GitHub would have it
  git -C "$REPO" update-ref refs/remotes/origin/main "$m"
  git -C "$REPO" checkout -q feat
  case "$kind" in
    clean) git -C "$REPO" merge -q --no-edit -m "Merge branch 'main' into feat" mainline ;;
    conflict)
      git -C "$REPO" merge -q --no-edit mainline >/dev/null 2>&1
      printf 'resolved by hand\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt
      git -C "$REPO" commit -q -m "Merge branch 'main' into feat" ;;
    nonmerge) printf 'more\n' > "$REPO/h.txt"; git -C "$REPO" add h.txt; git -C "$REPO" commit -q -m "more work" ;;
  esac
  h="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$kind" = nonmerge ]; then
    jq -n --arg h "$h" --arg r "$r" '{commits: [{sha: $h, parents: [{sha: $r}], commit: {message: "more work"}}]}' > "$dir/compare.json"
  else
    jq -n --arg h "$h" --arg r "$r" --arg m "$m" --arg b "$b0" \
      '{commits: [{sha: $m, parents: [{sha: $b}], commit: {message: "change on main"}},
                  {sha: $h, parents: [{sha: $r}, {sha: $m}], commit: {message: "Merge branch '"'"'main'"'"' into feat"}}]}' > "$dir/compare.json"
  fi
  printf '{"files":[{"filename":"src/calc.js"}]}\n' > "$dir/commit.json"
  jq -n --arg h "$h" '{isDraft: false, state: "OPEN", mergedAt: null, headRefOid: $h,
    statusCheckRollup: [{__typename: "CheckRun", conclusion: "SUCCESS"}]}' > "$dir/pr.json"
  if [ -n "$fnd" ]; then sed -e "s/abc1234/$r/g" "$TICK/drift-merge/comments-12.json" > "$dir/comments.json"
  else sed -e "s/abc1234/$r/g" -e 's/\\"important\\":1/\\"important\\":0/' "$TICK/drift-merge/comments-12.json" > "$dir/comments.json"; fi
  if [ -n "$mrg" ]; then sed -i.bak 's/\\"state\\":\\"in_review\\"/\\"state\\":\\"merging\\"/' "$dir/comments.json"; fi
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    printf 'api repos/acme/toy/issues/12\t0\t%s/common/issue-12-%s.json\n' "$TICK" "$issue"
    printf 'api --paginate repos/acme/toy/issues/12/comments\t0\t%s/comments.json\n' "$dir"
    printf 'pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/pr.json\n' "$dir"
    printf 'pr view 34 --repo acme/toy --json files*\t0\t%s/common/%s\n' "$TICK" "$files"
    printf 'issue list --repo acme/toy --label fleet:ready *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:in_progress *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:in_review *\t0\t%s/common/%s\n' "$TICK" "$inrev"
    printf 'issue list --repo acme/toy --label fleet:merging *\t0\t%s/common/list-merging-12.json\n' "$TICK"
    printf 'issue list --repo acme/toy --label fleet:blocked *\t0\t%s/common/empty.json\n' "$TICK"
    printf 'api repos/acme/toy/compare/%s...%s\t0\t%s/compare.json\n' "$r" "$h" "$dir"
    printf 'api repos/acme/toy/commits/%s\t0\t%s/commit.json\n' "$h" "$dir"
  } > "$dir/routes"
  FAKE_GH_ROUTES="$dir/routes"; export FAKE_GH_ROUTES
  run_check "$SCRIPT"
}
# Scope overlap and one merge per tick. Fixtures are built at run time.
# scope_issue <dir> <n> <label> <scope section text, or NONE>: writes the issue
scope_issue() {
  local dir="$1" n="$2" label="$3" scope="$4" body
  body="Work."$'\n\n'
  if [ "$scope" != NONE ]; then body="$body## Scope"$'\n'"$scope"$'\n\n'; fi
  body="$body## Acceptance"$'\n'"- it works"$'\n'
  jq -n --argjson n "$n" --arg l "fleet:$label" --arg b "$body" \
    '{number: $n, title: "Card \($n)", html_url: "https://github.com/acme/toy/issues/\($n)", body: $b, labels: [{name: $l}]}' \
    > "$dir/issue-$n.json"
}
# scope_routes <dir> <ready numbers> <in_review numbers> [<stage columns>]:
# routes for those cards. <stage columns> is "review_<name>:<numbers> ...",
# one word per configured stage (cards in a stage column get PR routes too).
scope_routes() {
  local dir="$1" n pr stage_nums="" sc
  for sc in ${4:-}; do stage_nums="$stage_nums ${sc#*:}"; done
  {
    printf 'api user\t0\t%s/labels/user.json\n' "$TICK/.."
    for n in $2 $3 $stage_nums; do
      printf 'api repos/acme/toy/issues/%s\t0\t%s/issue-%s.json\n' "$n" "$dir" "$n"
      if [ -f "$dir/comments-$n.json" ]; then
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/comments-%s.json\n' "$n" "$dir" "$n"
      else
        printf 'api --paginate repos/acme/toy/issues/%s/comments\t0\t%s/common/empty.json\n' "$n" "$TICK"
      fi
    done
    for n in $3 $stage_nums; do
      pr=$((n + 22))
      printf 'pr view %s --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/common/pr-34-open-green.json\n' "$pr" "$TICK"
      printf 'pr view %s --repo acme/toy --json files*\t0\t%s/common/files-plain.json\n' "$pr" "$TICK"
    done
    for st in ready:"$2" in_progress: in_review:"$3" ${4:-} blocked:; do
      local col="${st%%:*}" nums="${st#*:}" arr="[]" x
      arr="$(for x in $nums; do jq -cn --argjson n "$x" --arg l "fleet:$col" '{number: $n, title: "Card \($n)", url: "u", labels: [{name: $l}]}'; done | jq -cs '.')"
      printf '%s\n' "$arr" > "$dir/list-$col.json"
      printf 'issue list --repo acme/toy --label fleet:%s *\t0\t%s/list-%s.json\n' "$col" "$dir" "$col"
    done
  } > "$dir/routes"
  FAKE_GH_ROUTES="$dir/routes"; export FAKE_GH_ROUTES
}
# scope_review_note <dir> <n>: a clean round 1 review note for card n, PR n+22
scope_review_note() {
  sed -e "s/fleet\\/12-add-subtract/fleet\\/$2-card/" -e "s/\\\\\"pr\\\\\":34/\\\\\"pr\\\\\":$(($2 + 22))/" \
    "$TICK/in-review-merge-auto/comments-12.json" > "$1/comments-$2.json"
}
# plan_scope <ready card's scope text or NONE>: ready card 14, in_review card 12 naming src/a.sh
plan_scope() {
  setup_case ready-start
  local dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
  scope_issue "$dir" 12 in_review '- Modify `src/a.sh`: the change'
  scope_issue "$dir" 14 ready "$1"
  scope_review_note "$dir" 12
  scope_routes "$dir" "14" "12"
  run_check "$SCRIPT"
}
# Candidate mode exposes the same workflow decision without tick-local admission.
candidate_empty_human_qa_route() {
  local route_dir
  route_dir="$(mktemp -d)"
  CLEANUP_DIRS+=("$route_dir")
  local route_base
  route_base="$(cd "$(dirname "$FAKE_GH_ROUTES")" && pwd)"
  awk -F '\t' -v OFS='\t' -v base="$route_base" \
    '$3 != "-" && substr($3, 1, 1) != "/" { $3 = base "/" $3 } { print }' \
    "$FAKE_GH_ROUTES" > "$route_dir/routes"
  FAKE_GH_ROUTES="$route_dir/routes"
  export FAKE_GH_ROUTES
  printf 'issue list --repo acme/toy --label fleet:human_qa *\t0\t%s/common/empty.json\n' "$TICK" >> "$FAKE_GH_ROUTES"
}
# Plain-text paths in a card's Scope (candidate mode exposes declared_paths).
# cand_scope <scope text>: ready card 14 alone; run --candidates
cand_scope() {
  setup_case ready-start
  local dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
  scope_issue "$dir" 14 ready "$1"
  scope_routes "$dir" "14" ""
  candidate_empty_human_qa_route
  run_check "$SCRIPT" --candidates
}
# supervisor.scope_ignore: a Ready card naming a manifest is not held back by an
# open PR that also touches the manifests (the same rule as scopes.drop_ignored)
# plan_scope_ignore <extra YAML>: card 12 in review, its PR touching src/a.sh and both manifests
plan_scope_ignore() {
  setup_case ready-start "$1"
  local dir="$FAKE_GH_DIR/scope"; mkdir -p "$dir"
  scope_issue "$dir" 12 in_review '- Modify `src/a.sh`: the change'
  scope_issue "$dir" 14 ready '- Bump `.claude-plugin/marketplace.json` and `plugins/fleet-board/.claude-plugin/plugin.json`'
  scope_review_note "$dir" 12
  scope_routes "$dir" "14" "12"
  printf '%s\n' '{"files":[{"path":"src/a.sh"},{"path":".claude-plugin/marketplace.json"},{"path":"plugins/fleet-board/.claude-plugin/plugin.json"}],"changedFiles":3}' > "$dir/files-manifests.json"
  { printf 'pr view 34 --repo acme/toy --json files*\t0\t%s/files-manifests.json\n' "$dir"; cat "$dir/routes"; } > "$dir/routes.new"
  mv "$dir/routes.new" "$dir/routes"
  run_check "$SCRIPT"
}
VERSION_YAML="$(printf 'supervisor:\n  version_files: ["plugins/*/.claude-plugin/plugin.json"]')"
# plan_version <base version after the branch was cut> <extra YAML>
# env: PV_BASE_BRANCH (the PR's baseRefName, default main), PV_HEAD (a headRefOid to
# report instead of the branch head), PV_EARLY_MERGE (the branch merged the base,
# with the same bump, before the base moved on). A git wrapper logs fetches.
plan_version() {
  setup_case in-review-merge-auto "$(printf 'merge:\n  policy: auto\n%s' "$2")"
  local dir="$FAKE_GH_DIR/scope" remote="$FAKE_GH_DIR/remote.git" head base bb="${PV_BASE_BRANCH:-main}" real_git
  mkdir -p "$dir"
  real_git="$(PATH="$ORIG_PATH" command -v git)"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = fetch ] && { printf "%%s\\n" "$*" >> "%s/git-fetch.log"; break; }; done\nexec "%s" "$@"\n' \
    "$FAKE_GH_DIR" "$real_git" > "$BIN/git"
  chmod +x "$BIN/git"
  git init -q --bare "$remote"
  git -C "$REPO" remote add origin "$remote"
  mkdir -p "$REPO/plugins/fb/.claude-plugin"
  printf '{\n  "name": "fb",\n  "version": "0.28.3"\n}\n' > "$REPO/plugins/fb/.claude-plugin/plugin.json"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m base
  base="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" push -q origin HEAD:refs/heads/main
  [ "$bb" = main ] || git -C "$REPO" push -q origin "HEAD:refs/heads/$bb"
  git -C "$REPO" checkout -q -b fleet/12-card
  printf '{\n  "name": "fb",\n  "version": "0.28.4"\n}\n' > "$REPO/plugins/fb/.claude-plugin/plugin.json"
  printf 'x\n' > "$REPO/src.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m branch
  git -C "$REPO" push -q origin fleet/12-card
  git -C "$REPO" checkout -q -b base-work "$base"
  if [ "$1" != 0.28.3 ]; then
    printf '{\n  "name": "fb",\n  "version": "%s"\n}\n' "$1" > "$REPO/plugins/fb/.claude-plugin/plugin.json"
    git -C "$REPO" commit -q -am base-bump
    git -C "$REPO" push -q origin "HEAD:refs/heads/$bb"
  fi
  if [ -n "${PV_TAKE_THEIRS:-}" ]; then
    git -C "$REPO" checkout -q fleet/12-card
    git -C "$REPO" merge -q --no-edit base-work >/dev/null 2>&1
    git -C "$REPO" checkout -q --theirs -- plugins/fb/.claude-plugin/plugin.json
    git -C "$REPO" add -A; git -C "$REPO" commit -q --no-edit
    git -C "$REPO" push -q origin fleet/12-card
    git -C "$REPO" checkout -q base-work
  fi
  if [ -n "${PV_DELETE:-}" ]; then
    git -C "$REPO" checkout -q fleet/12-card
    git -C "$REPO" rm -q plugins/fb/.claude-plugin/plugin.json; git -C "$REPO" commit -q -m drop
    git -C "$REPO" push -q origin fleet/12-card
    git -C "$REPO" checkout -q base-work
  fi
  if [ -n "${PV_EARLY_MERGE:-}" ]; then
    git -C "$REPO" checkout -q fleet/12-card
    git -C "$REPO" merge -q --no-edit base-work
    git -C "$REPO" push -q origin fleet/12-card
    git -C "$REPO" checkout -q base-work
    printf 'later\n' > "$REPO/later.txt"
    git -C "$REPO" add -A; git -C "$REPO" commit -q -m later
    git -C "$REPO" push -q origin "HEAD:refs/heads/$bb"
  fi
  head="${PV_HEAD:-$(git -C "$REPO" rev-parse fleet/12-card)}"
  scope_issue "$dir" 12 in_review NONE
  if [ -n "${PV_LABEL:-}" ]; then
    jq -c --arg l "$PV_LABEL" '.labels += [{name:$l}]' "$dir/issue-12.json" > "$dir/issue-12.new" && mv "$dir/issue-12.new" "$dir/issue-12.json"
  fi
  scope_review_note "$dir" 12
  scope_routes "$dir" "" "12"
  jq -c --arg h "$head" '.headRefOid = $h' "$TICK/common/pr-34-open-green.json" > "$dir/pr-34.json"
  printf '%s\n' "$bb" > "$dir/base-34.txt"
  { printf 'pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid\t0\t%s/pr-34.json\n' "$dir"
    printf 'pr view 34 --repo acme/toy --json baseRefName*\t0\t%s/base-34.txt\n' "$dir"
    cat "$dir/routes"; } > "$dir/routes.new"
  mv "$dir/routes.new" "$dir/routes"
  run_check "$SCRIPT"
}
fetch_count() { if [ -f "$FAKE_GH_DIR/git-fetch.log" ]; then grep -c -- "$1" "$FAKE_GH_DIR/git-fetch.log"; else echo 0; fi; }
VERSION_MERGE_YAML="$(printf 'supervisor:\n  version_files: ["plugins/*/.claude-plugin/plugin.json"]\n  version_bump: merge')"
# commands.preflight: one board-level alert instead of a failure on each card
PRE_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$PRE_DIR")
printf '#!/usr/bin/env bash\necho ran >> "%s/ran"\nfor i in $(seq 1 25); do echo "preflight line $i"; done\nexit 1\n' "$PRE_DIR" > "$PRE_DIR/fail.sh"
# mutating_calls: gh calls that edit, comment or write (a plan only reads)
mutating_calls() {
  local f n=0
  for f in "$FAKE_GH_DIR"/argv/*; do
    [ -f "$f" ] || continue
    grep -qxE 'edit|comment|create|close|-X|--method|--input' "$f" && n=$((n + 1))
  done
  echo "$n"
}
# variant <name> <pr json file under common> <note json> [extra YAML]
variant() {
  local d="$VROOT/tick/$1"
  mkdir -p "$d"
  sed "s#comments-12.json#$d/comments-12.json#; s#\.\./common/pr-34-draft.json#../common/$2#" "$TICK/in-review-fix/routes" > "$d/routes"
  jq -c --argjson note "$3" '
    .[1].body = ("<!-- fleet-board:manager-note -->\n### fleet-board manager note\n\n```json\n" + ($note | tojson) + "\n```\n")
  ' "$TICK/in-review-fix/comments-12.json" > "$d/comments-12.json"
  TICK="$VROOT/tick" plan "$1" "${4:-}"
}
LR='"last_review":{"round":1,"sha":"abc1234","critical":0,"important":1,"findings":[{"severity":"Important","text":"subtract ignores negatives"}]}'
BASE_NOTE='"branch":"fleet/12-add-subtract","pr":34,"round":1'
STAGES_YAML="$(printf '%s\n' \
  'review:' \
  '  stages:' \
  '    - name: security' \
  '      agent: "acme:sec"' \
  '      model: opus' \
  '      paths: ["src/auth/**"]' \
  '      max_rounds: 2' \
  '    - name: ux' \
  '      agent: ux-reviewer' \
  '      model: sonnet' \
  '      advisory: true' \
  '    - name: compliance' \
  '      provider: openai' \
  '      model: gpt-test' \
  '      price: { input: 1, output: 2 }')"  # an old price key: config.sh ignores it
unset OPENAI_API_KEY || true
splan() { plan "$1" "$STAGES_YAML"; }
ssettle() { settle "$1" "$2" "$STAGES_YAML"; }
COMPLIANCE_WARN='stage compliance: OPENAI_API_KEY is not set; provider reviews will fail'

# FLEET_TEST_ONLY: gate every helper that sets up, runs or asserts, so a suite line outside the
# selected window does nothing; a skipped setup's variables get a scratch value so suite code that
# reads them (set -u) still runs
if [ -n "$TP_ONLY" ]; then
  tp_gate() {
    eval "tp_orig_$1() $(declare -f "$1" | sed 1d)"
    eval "$1() { tp_skip && return 0; tp_orig_$1 \"\$@\"; }"
  }
  tp_scratch="$(mktemp -d)"
  CLEANUP_DIRS+=("$tp_scratch")
  REPO="$tp_scratch"; FAKE_GH_DIR="$tp_scratch"; BIN="$tp_scratch/bin"; BASE="$tp_scratch"
  FAKE_GH_ROUTES="$tp_scratch/routes"; DONE_CASE_DIR="$tp_scratch"
  for tp_f in $TP_OPENERS run_check assert_exit assert_stdout_exact assert_stderr_exact assert_stderr_not_contains \
    assert_eq assert_jq scope_issue scope_routes scope_review_note candidate_empty_human_qa_route; do
    if declare -F "$tp_f" >/dev/null; then tp_gate "$tp_f"; fi
  done
  echo "FLEET_TEST_ONLY=$TP_ONLY: 1 test(s) selected" >&2
fi
