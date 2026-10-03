#!/usr/bin/env bash
# behavioral-lib.sh - shared setup for the behavioral suites (sourced, not run).
#
# Hits the REAL sandbox repo named by SANDBOX_REPO: it pushes branches, opens
# draft PRs, creates card issues and posts comments there. Callers:
# behavioral-role.sh (Phase 5), behavioral-tick.sh (Phase 6) and the Phase 7
# overnight run.
#
# Provides:
#   pass / fail / check / check_jq    the pass/fail harness (PASS, FAIL)
#   bl_summary                        prints passed/failed, returns 1 on failure
#   prepare                           clone, seed if empty, pristine check, labels
#   new_card CARD_FILE [STATE]        card issue in STATE (default ready) + worktree
#                                     -> CARD WT BRANCH
#   open_patch_pr PATCH...            git am the patches in $WT, push, draft PR -> PR
#   review_worktree                   detached worktree at the PR head -> RWT
#   dispatch_role ROLE MODEL PROMPT   headless session dispatching fleet-board:ROLE
#   latest_report N OUT               newest non-note comment on card N -> OUT
#   test_blocks_kept PRE POST         pre-existing test blocks unchanged at POST
#   cleanup                           close PRs (deleting branches), close cards,
#                                     remove clones and worktrees; keeps $RUN
#
# Environment:
#   SANDBOX_REPO   owner/name of the sandbox repo (required)
#   RUN            where transcripts and metrics are kept (default: a new dir
#                  under $TMPDIR/fb-p5/behavioral). Never deleted by cleanup.
#   BL_MAX_TURNS   --max-turns for dispatch_role (default 120)
#   FB_ISOLATE     1: dispatch_role runs the session isolated from the user's
#                  own setup: CLAUDE_CONFIG_DIR is a fresh empty dir (no user
#                  plugins, hooks, settings or ~/.claude/CLAUDE.md) and auth
#                  comes from --settings "$FB_ISOLATE_SETTINGS". fleet-board
#                  still loads via --plugin-dir, gate hook included. RUN dirs
#                  get an -iso suffix.
#   FB_ISOLATE_SETTINGS  settings file holding the auth (an apiKeyHelper) for
#                  isolated sessions (default ~/.config/fleet-board/bare-settings.json)
#
# Portable: bash 3.2, jq, gh, git (plus node, which the toy repo needs).

unset CDPATH

BL_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$BL_TESTS/.." && pwd)"
S="$PLUGIN_DIR/scripts"
BL_FIX="$PLUGIN_DIR/fixtures/behavioral"
BL_REPORTS="$PLUGIN_DIR/fixtures/reports"
BL_MARKER='<!-- fleet-board:manager-note -->'
BL_TS="$(date +%Y%m%d-%H%M%S)"

PASS=0
FAIL=0
WORK=""
CLONE=""
CARDS=""      # space-separated card numbers to close on cleanup
BRANCHES=""   # space-separated branches whose PRs/remote refs are removed on cleanup
BL_T0="$(date +%s)"

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
bl_log() { printf '[behavioral] %s\n' "$*" >&2; }
bl_die() { printf '[behavioral] error: %s\n' "$*" >&2; exit 1; }

# check NAME CMD...: passes when CMD exits 0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

# check_jq NAME FILE FILTER: passes when jq -e FILTER holds for the JSON in FILE
check_jq() {
  if [ -s "$2" ] && jq -e "$3" "$2" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1" "expected jq '$3' to hold for $2: $(head -c 600 "$2" 2>/dev/null)"
  fi
}

bl_summary() {
  echo "-----------------------------------"
  printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# bl_init_run SCENARIO: sets RUN (kept after cleanup)
bl_init_run() {
  if [ -z "${RUN:-}" ]; then
    RUN="${TMPDIR:-/tmp}"; RUN="${RUN%/}/fb-p5/behavioral/$1-$BL_TS"
    [ "${FB_ISOLATE:-0}" = 1 ] && RUN="$RUN-iso"
  fi
  mkdir -p "$RUN" || bl_die "cannot create RUN dir $RUN"
  bl_log "RUN=$RUN"
}

# ---------------------------------------------------------------------------
# prepare: clone the sandbox, seed the toy repo into an empty main, assert main
# is pristine, create the labels without touching the committed config.
prepare() {
  local tool
  for tool in node git gh jq claude; do
    command -v "$tool" >/dev/null 2>&1 || bl_die "$tool is not on PATH"
  done
  WORK="$(mktemp -d)" || bl_die "mktemp failed"
  WORK="$(cd "$WORK" && pwd -P)"
  CLONE="$WORK/clone"
  gh repo clone "$SANDBOX_REPO" "$CLONE" -- -q >/dev/null 2>&1 || bl_die "cannot clone $SANDBOX_REPO"
  cd "$CLONE" || bl_die "cannot cd to $CLONE"
  git fetch -q origin 2>/dev/null

  # Step 2: seed only when origin/main lacks src/calc.js
  if ! git cat-file -e origin/main:src/calc.js 2>/dev/null; then
    bl_log "seeding the toy repo into $SANDBOX_REPO main"
    if git rev-parse -q --verify origin/main >/dev/null; then
      git checkout -q -B main origin/main || bl_die "cannot check out main"
    else
      git symbolic-ref HEAD refs/heads/main || bl_die "cannot start main"
    fi
    cp -R "$BL_FIX/toy-repo/." "$CLONE/" || bl_die "cannot copy the toy repo"
    local tmp; tmp="$(mktemp)"
    sed "s|__SANDBOX_REPO__|$SANDBOX_REPO|" "$CLONE/.fleet-board.yml" >"$tmp" && mv "$tmp" "$CLONE/.fleet-board.yml"
    git add -A && git commit -q -m "chore: seed toy repo for fleet-board behavioral tests" \
      || bl_die "cannot commit the seed"
    git push -q origin main || bl_die "cannot push the seed to main (never forced)"
    git fetch -q origin
  fi

  # Step 3: unconditional pristine check
  git fetch -q origin || bl_die "git fetch failed"
  if [ -n "$(git grep -nE 'subtract|clamp|multiply' origin/main -- src test 2>/dev/null)" ]; then
    bl_die "sandbox main is not pristine; revert merged scenario commits before re-running"
  fi
  git checkout -q -B main origin/main 2>/dev/null || bl_die "cannot check out main"

  # Step 4: labels, with the throwaway config written elsewhere
  local initdir; initdir="$(mktemp -d)"
  bash "$S/init.sh" --backend github-labels --repo "$SANDBOX_REPO" --test-one "node --test {file}" \
    --dir "$initdir" >/dev/null 2>"$WORK/init.err" || bl_die "init.sh failed: $(cat "$WORK/init.err")"
  rm -rf "$initdir"
  [ -z "$(git -C "$CLONE" status --porcelain .fleet-board.yml)" ] || bl_die "the committed .fleet-board.yml changed"
  [ "$(bash "$S/config.sh" commands.test_one)" = "node --test {file}" ] \
    || bl_die "config.sh commands.test_one in the clone is not 'node --test {file}'"
  git -C "$CLONE" config user.name >/dev/null 2>&1 || git -C "$CLONE" config user.name "fleet-board behavioral"
  git -C "$CLONE" config user.email >/dev/null 2>&1 || git -C "$CLONE" config user.email "behavioral@example.invalid"
  BASE_SHA="$(git rev-parse origin/main)"
}

# new_card CARD_FILE [STATE]: sets CARD, BRANCH, WT. STATE defaults to ready;
# board-move.sh refuses ready for a card without ## Acceptance, so such a card
# is seeded in another state (e.g. in_progress).
new_card() {
  local file="$1" state="${2:-ready}" title body out
  title="$(sed -n 's/^# //p' "$file" | head -1)"
  [ -n "$title" ] || bl_die "no '# title' line in $file"
  body="$WORK/card-body.md"
  sed '1{/^# /d;}' "$file" | sed '/./,$!d' >"$body"
  out="$(cd "$CLONE" && bash "$S/board-create.sh" "$title [behavioral $BL_TS]" "$body")" \
    || bl_die "board-create.sh failed"
  CARD="$(printf '%s' "$out" | jq -r .number)"
  case "$CARD" in ''|*[!0-9]*) bl_die "board-create.sh printed no number: $out" ;; esac
  CARDS="$CARDS $CARD"
  (cd "$CLONE" && bash "$S/board-move.sh" "$CARD" "$state") >/dev/null || bl_die "board-move.sh $CARD $state failed"
  BRANCH="fleet/$CARD-behavioral"
  BRANCHES="$BRANCHES $BRANCH"
  WT="$WORK/wt-$CARD"
  git -C "$CLONE" worktree add -q "$WT" -b "$BRANCH" origin/main 2>/dev/null || bl_die "worktree add failed"
  bl_log "card #$CARD, worktree $WT, branch $BRANCH"
}

# apply_patch PATCH: one commit in $WT, message from the patch
apply_patch() {
  git -C "$WT" am -q "$1" || { git -C "$WT" am --abort 2>/dev/null; bl_die "git am $1 failed"; }
}

# open_patch_pr PATCH...: apply, push, open a draft PR -> PR
open_patch_pr() {
  local p
  for p in "$@"; do apply_patch "$p"; done
  git -C "$WT" push -q -u origin "$BRANCH" 2>/dev/null || bl_die "push $BRANCH failed"
  local url
  url="$(cd "$WT" && gh pr create --repo "$SANDBOX_REPO" --draft --base main --head "$BRANCH" \
    --title "Add subtract [behavioral $BL_TS]" --body "Closes #$CARD")" || bl_die "gh pr create failed"
  PR="${url##*/}"
  case "$PR" in ''|*[!0-9]*) bl_die "cannot read PR number from: $url" ;; esac
  bl_log "PR #$PR"
}

# push_patch PATCH: apply as a new commit and push to the PR branch
push_patch() {
  apply_patch "$1"
  git -C "$WT" push -q origin "$BRANCH" 2>/dev/null || bl_die "push $BRANCH failed"
}

# review_worktree: detached worktree at origin/$BRANCH -> RWT
review_worktree() {
  git -C "$CLONE" fetch -q origin
  RWT="$WORK/review-$CARD"
  git -C "$CLONE" worktree add -q --detach "$RWT" "origin/$BRANCH" 2>/dev/null || bl_die "review worktree add failed"
}

# pass_count DIR FILE: the "# pass N" count of node --test FILE in DIR
pass_count() {
  (cd "$1" && node --test --test-reporter=tap "$2" 2>&1) | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p' | tail -1
}

# split_test_blocks PREFIX: read a test file on stdin, write each top-level
# block from a line starting "test(" through the next line that is exactly
# "});" to PREFIX.1, PREFIX.2, ...
split_test_blocks() {
  awk -v out="$1" '
    /^test\(/ { n++; inb = 1 }
    inb { print > (out "." n) }
    inb && /^\}\);[ ]*$/ { close(out "." n); inb = 0 }
  '
}

# test_blocks_kept PRE POST: every test block of every file under test/ at
# commit PRE appears byte-identical in the same file at POST. Prints the
# number of blocks checked, or the blocks that changed or vanished; returns 1
# when any did, or when PRE has no test block at all (nothing was checked).
test_blocks_kept() {
  local pre="$1" post="$2" d f b c found n=0 bad=""
  d="$WORK/test-blocks"
  rm -rf "$d" && mkdir -p "$d" || { echo "cannot create $d"; return 1; }
  for f in $(git -C "$CLONE" ls-tree -r --name-only "$pre" -- test/); do
    rm -f "$d"/pre.* "$d"/post.*
    git -C "$CLONE" show "$pre:$f" | split_test_blocks "$d/pre"
    git -C "$CLONE" show "$post:$f" 2>/dev/null | split_test_blocks "$d/post"
    for b in "$d"/pre.*; do
      [ -f "$b" ] || continue
      n=$((n + 1))
      found=0
      for c in "$d"/post.*; do
        [ -f "$c" ] && cmp -s "$b" "$c" && { found=1; break; }
      done
      [ $found -eq 1 ] || bad="$bad [$f: $(head -1 "$b")]"
    done
  done
  rm -rf "$d"
  if [ $n -eq 0 ]; then echo "no test( block under test/ at $pre"; return 1; fi
  if [ -n "$bad" ]; then echo "changed or removed:$bad"; return 1; fi
  echo "$n block(s)"
}

# post_report N FILE: post FILE as a comment on card N (as the harness)
post_report() {
  (cd "$CLONE" && bash "$S/board-comment.sh" "$1" "$2") || bl_die "board-comment.sh $1 failed"
}

# latest_report N OUT: newest comment on card N that is not a manager note
latest_report() {
  (cd "$CLONE" && bash "$S/board-read.sh" "$1") 2>/dev/null \
    | jq -r --arg m "$BL_MARKER" '[.comments[] | select(.body | startswith($m) | not)] | last | .body // empty' >"$2"
}

# config_json [JQ_ARGS...]: the clone's merged config, optionally transformed
config_json() {
  [ $# -gt 0 ] || set -- .
  (cd "$CLONE" && bash "$S/config.sh") | jq "$@"
}

# dispatch_role ROLE MODEL PROMPT_FILE: mirrors the manager's dispatch
dispatch_role() {
  local role="$1" model="$2" prompt="$3" t0 t1 mode cfg="" settings=""
  mode="$(cd "$CLONE" && bash "$S/config.sh" headless.permission_mode)"
  if [ "${FB_ISOLATE:-0}" = 1 ]; then
    settings="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
    [ -r "$settings" ] || bl_die "FB_ISOLATE=1 needs a readable auth settings file: $settings"
    cfg="$WORK/claude-config-$role"
    mkdir -p "$cfg" || bl_die "cannot create $cfg"
  fi
  bl_log "dispatching fleet-board:$role ($model, permission mode $mode${cfg:+, isolated}) -> $RUN/$role.jsonl"
  t0="$(date +%s)"
  (
    cd "$CLONE" || exit 1
    if [ -n "$cfg" ]; then
      # Isolated: the empty config dir replaces ~/.claude for this process only.
      export CLAUDE_CONFIG_DIR="$cfg"
      set -- --settings "$settings"
    else
      set --
    fi
    claude -p ${1+"$@"} --plugin-dir "$PLUGIN_DIR" --model sonnet \
      --permission-mode "$mode" \
      --output-format stream-json --verbose --max-turns "${BL_MAX_TURNS:-120}" \
      "Use the Agent tool to dispatch the fleet-board:$role agent with model \"$model\" and exactly this prompt, then print its final report verbatim: $(cat "$prompt")" \
      >"$RUN/$role.jsonl" 2>"$RUN/$role.stderr"
  )
  t1="$(date +%s)"
  local res
  res="$(jq -c 'select(.type=="result") | {subtype, is_error, num_turns, total_cost_usd, duration_ms}' "$RUN/$role.jsonl" 2>/dev/null | tail -1)"
  [ -n "$res" ] || res='{}'
  printf '%s\t%s\t%s\t%s\n' "$role" "$model" "$((t1 - t0))" "$res" >>"$RUN/metrics.tsv"
  bl_log "$role finished in $((t1 - t0))s: $res"
}

# ---------------------------------------------------------------------------
cleanup() {
  local rc=$? b n
  cd / 2>/dev/null
  if [ -n "${SANDBOX_REPO:-}" ]; then
    for b in $BRANCHES; do
      for n in $(gh pr list --repo "$SANDBOX_REPO" --head "$b" --state open --json number --jq '.[].number' 2>/dev/null); do
        gh pr close "$n" --repo "$SANDBOX_REPO" --delete-branch >/dev/null 2>&1 \
          || bl_log "cleanup: could not close PR #$n"
      done
      if [ -n "$CLONE" ] && git -C "$CLONE" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
        git -C "$CLONE" push -q origin --delete "$b" 2>/dev/null || bl_log "cleanup: could not delete branch $b"
      fi
    done
    for n in $CARDS; do
      gh issue close "$n" --repo "$SANDBOX_REPO" --reason "not planned" >/dev/null 2>&1 \
        || bl_log "cleanup: could not close card #$n"
    done
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  if [ -n "${RUN:-}" ] && [ -d "$RUN" ]; then
    printf 'total\t-\t%s\t-\n' "$(($(date +%s) - BL_T0))" >>"$RUN/metrics.tsv"
    bl_log "kept transcripts in $RUN"
  fi
  return $rc
}
