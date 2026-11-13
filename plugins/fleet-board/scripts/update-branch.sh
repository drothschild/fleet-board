#!/usr/bin/env bash
# update-branch.sh - brings a card's PR branch up to date with its base branch
# by a merge commit and a plain push. Never rebases, never force-pushes.
#
# Usage: update-branch.sh <n> <pr> <branch> <worktree>
#
# Carries out tick-plan.sh's update_branch action. In <worktree> (the card's
# worktree, on <branch>) it fetches origin and merges origin/<base> into the
# branch, where <base> is the PR's baseRefName. Then:
#   clean merge     push origin <branch> (when the merge moved HEAD); the card
#                   stays where it is, and the manager note gains last_update
#                   {sha, base, changed}. last_review is left as it is: the
#                   next tick plans merge when this clean merge of the base is
#                   the only change since the review, and review otherwise
#                   (tick-plan.sh, review-drift.sh).
#   version-only    every conflicted file is JSON and every conflict hunk
#   conflict        differs only in lines setting "version": "X.Y.Z" (semver,
#                   optional -prerelease): each such line gets one version, the
#                   highest on either side (numeric semver order), or the base
#                   side's highest plus one patch when that is not strictly
#                   above the base. Lines outside the hunks are untouched, each
#                   file must still parse with jq, then the merge is committed
#                   and pushed like a clean merge (exit 0, last_update).
#   conflict        the merge is aborted (nothing is pushed), a comment names
#                   the conflicted files, the manager note gains
#                   conflicted_files (every file, test files included) and the
#                   card stays where it is. tick-plan.sh then plans the fixer
#                   with those files as its findings. The script exits 1 and
#                   the manager counts that as one failed action (note.sh
#                   fail); the script does not count it too. No other
#                   conflict is resolved here, and when any conflicted file
#                   is not version-only nothing is resolved or committed.
# Exit codes: 0 done (clean merge), 1 a git, gh or board step failed or the
# merge conflicted (the manager counts the failure), 2 usage error.

set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

[ $# -eq 4 ] || fb_die 2 "usage: update-branch.sh <n> <pr> <branch> <worktree>"
N="$1"; PR="$2"; BRANCH="$3"; WT="$4"
fb_valid_number "$N" || fb_die 2 "card number must be numeric, got: $N"
fb_valid_number "$PR" || fb_die 2 "PR number must be numeric, got: $PR"
case "$BRANCH" in
  fleet/[0-9]*-*) ;;
  *) fb_die 2 "branch must be fleet/<n>-<slug>, got: $BRANCH" ;;
esac
case "$BRANCH" in *[!A-Za-z0-9/._-]*) fb_die 2 "invalid branch: $BRANCH" ;; esac
[ -d "$WT" ] || fb_die 2 "worktree not found: $WT"

fb_load_config

BASE="$(gh pr view "$PR" --repo "$FLEET_REPO" --json baseRefName --jq .baseRefName)" \
  || fb_die 1 "cannot read the base branch of PR #$PR"
case "$BASE" in
  ''|*[!A-Za-z0-9/._-]*) fb_die 1 "unexpected base branch for PR #$PR: $BASE" ;;
esac

TMP="$(mktemp)" || fb_die 1 "cannot create a temp file"
TMPD="$(mktemp -d)" || { rm -f "$TMP"; fb_die 1 "cannot create a temp directory"; }
trap 'rm -f "$TMP"; rm -rf "$TMPD"' EXIT

# --- version-only conflicts ------------------------------------------------
# vc_scan <file>: exit 0 and print "o <version>" / "t <version>" for each line of
# each conflict hunk (o = HEAD, the branch; t = the merged-in base) when every hunk
# holds only "version" lines that match pairwise apart from the value; else exit 1.
# A diff3 base section must hold only version lines too.
vc_scan() {
  LC_ALL=C awk '
    function vline(l) {
      return l ~ /^[ \t]*"version"[ \t]*:[ \t]*"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"[ \t]*,?[ \t\r]*$/
    }
    function val(l) { sub(/^[ \t]*"version"[ \t]*:[ \t]*"/, "", l); sub(/".*$/, "", l); return l }
    function tmpl(l,   rest) {
      match(l, /"version"[ \t]*:[ \t]*"/)
      rest = substr(l, RSTART + RLENGTH); sub(/^[^"]*/, "", rest)
      return substr(l, 1, RSTART + RLENGTH - 1) "@" rest
    }
    /^<<<<<<<( |$)/ { if (st != 0) bad = 1; st = 1; no = 0; nt = 0; next }
    st == 1 && /^[|][|][|][|][|][|][|]( |$)/ { st = 2; next }
    (st == 1 || st == 2) && /^=======[\r]?$/ { st = 3; next }
    st == 3 && /^>>>>>>>( |$)/ {
      if (no == 0 || no != nt) bad = 1
      for (i = 1; i <= no && !bad; i++) if (tmpl(o[i]) != tmpl(t[i])) bad = 1
      for (i = 1; i <= no && !bad; i++) { out = out "o " val(o[i]) "\n" "t " val(t[i]) "\n" }
      st = 0; hunks++; next
    }
    st == 1 { if (!vline($0)) bad = 1; o[++no] = $0; next }
    st == 2 { if (!vline($0)) bad = 1; next }
    st == 3 { if (!vline($0)) bad = 1; t[++nt] = $0; next }
    END { if (bad || st != 0 || hunks == 0) exit 1; printf "%s", out }
  ' "$1"
}

# vc_pick: reads vc_scan lines; prints the highest version, or the base side'"'"'s
# highest plus one patch when the highest is not strictly above it. Semver order:
# numeric core, a release above its prereleases, identifiers per semver 11.
vc_pick() {
  LC_ALL=C awk '
    function cmp(a, b,   i, pa, pb, ca, cb, xa, xb, n, m, na, nb) {
      pa = ""; pb = ""
      i = index(a, "-"); if (i) { pa = substr(a, i + 1); a = substr(a, 1, i - 1) }
      i = index(b, "-"); if (i) { pb = substr(b, i + 1); b = substr(b, 1, i - 1) }
      split(a, ca, "."); split(b, cb, ".")
      for (i = 1; i <= 3; i++) {
        if (ca[i] + 0 > cb[i] + 0) return 1
        if (ca[i] + 0 < cb[i] + 0) return -1
      }
      if (pa == pb) return 0
      if (pa == "") return 1
      if (pb == "") return -1
      n = split(pa, xa, "."); m = split(pb, xb, ".")
      for (i = 1; i <= n && i <= m; i++) {
        na = (xa[i] ~ /^[0-9]+$/); nb = (xb[i] ~ /^[0-9]+$/)
        if (na && nb) { if (xa[i] + 0 != xb[i] + 0) return (xa[i] + 0 > xb[i] + 0) ? 1 : -1 }
        else if (na) return -1
        else if (nb) return 1
        else if (xa[i] "" != xb[i] "") return (xa[i] "" > xb[i] "") ? 1 : -1
      }
      return (n > m) ? 1 : ((n < m) ? -1 : 0)
    }
    { if (hi == "" || cmp($2, hi) > 0) hi = $2
      if ($1 == "t" && (base == "" || cmp($2, base) > 0)) base = $2 }
    END {
      if (hi == "" || base == "") exit 1
      if (cmp(hi, base) > 0) { print hi; exit 0 }
      core = base; i = index(core, "-"); if (i) core = substr(core, 1, i - 1)
      split(core, c, "."); printf "%s.%s.%d\n", c[1], c[2], c[3] + 1
    }
  '
}

# vc_write <file> <version>: the file with each hunk replaced by its HEAD lines,
# each "version" value set to <version>. Lines outside hunks are copied unchanged.
vc_write() {
  LC_ALL=C awk -v v="$2" '
    st == 0 && /^<<<<<<<( |$)/ { st = 1; n = 0; next }
    st == 1 && /^[|][|][|][|][|][|][|]( |$)/ { st = 2; next }
    (st == 1 || st == 2) && /^=======[\r]?$/ { st = 3; next }
    st == 3 && /^>>>>>>>( |$)/ { for (i = 1; i <= n; i++) print o[i]; st = 0; next }
    st == 1 {
      l = $0
      if (match(l, /^[ \t]*"version"[ \t]*:[ \t]*"/)) {
        rest = substr(l, RSTART + RLENGTH); sub(/^[^"]*/, "", rest)
        l = substr(l, 1, RSTART + RLENGTH - 1) v rest
      }
      o[++n] = l; next
    }
    st == 2 || st == 3 { next }
    { print }
  ' "$1"
}

# vc_resolve <conflicted-files>: resolves and commits the merge when every file is
# version-only; prints the version. Exit 1 (nothing written or staged) otherwise.
vc_resolve() {
  local f i=0 v
  : > "$TMPD/values"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.json) ;; *) return 1 ;; esac
    [ -f "$WT/$f" ] && [ ! -L "$WT/$f" ] || return 1
    vc_scan "$WT/$f" >> "$TMPD/values" || return 1
  done <<EOF_FILES
$1
EOF_FILES
  v="$(vc_pick < "$TMPD/values")" || return 1
  case "$v" in ''|*[!0-9A-Za-z.-]*) return 1 ;; esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    vc_write "$WT/$f" "$v" > "$TMPD/$i" || return 1
    jq -e . "$TMPD/$i" >/dev/null 2>&1 || return 1
  done <<EOF_FILES
$1
EOF_FILES
  i=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    cat "$TMPD/$i" > "$WT/$f" || return 1
    git -C "$WT" add -- "$f" || return 1
  done <<EOF_FILES
$1
EOF_FILES
  git -C "$WT" commit -q -m "Merge origin/$BASE into $BRANCH: resolve version-only conflicts ($v)" >/dev/null || return 1
  printf '%s\n' "$v"
}

git -C "$WT" fetch origin || fb_die 1 "git fetch origin failed in $WT"
BEFORE="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"

git -C "$WT" merge --no-edit "origin/$BASE" >/dev/null 2>&1
RC=$?
CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"

RESOLVED=""
if [ -n "$CONFLICTS" ] && RESOLVED="$(vc_resolve "$CONFLICTS")"; then
  printf 'update-branch: resolved version-only conflicts in %s to %s\n' \
    "$(printf '%s\n' "$CONFLICTS" | paste -sd' ' -)" "$RESOLVED" >&2
  RC=0; CONFLICTS=""
fi

if [ "$RC" -ne 0 ] || [ -n "$CONFLICTS" ]; then
  [ -n "$CONFLICTS" ] || fb_die 1 "git merge origin/$BASE failed in $WT without a conflict"
  git -C "$WT" merge --abort || fb_die 1 "git merge --abort failed in $WT"
  {
    printf 'Merging `%s` into `%s` conflicts in:\n\n' "origin/$BASE" "$BRANCH"
    printf '%s\n' "$CONFLICTS" | sed 's/^/- /'
    printf '\nThe merge was aborted and nothing was pushed. The card stays where it is; the next tick dispatches the fixer to resolve these files.\n'
  } > "$TMP"
  bash "$FLEET_SCRIPTS/board-comment.sh" "$N" "$TMP" || fb_die 1 "cannot comment on #$N"
  # One note write: the files for the fixer. The exit 1 below is counted once,
  # by the manager (2.C.4), so a card that keeps conflicting is still blocked
  # by the action_failures rule instead of looping
  printf '%s\n' "$CONFLICTS" | jq -R . | jq -s '{conflicted_files: .}' > "$TMP" \
    || fb_die 1 "cannot build the note patch for #$N"
  bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"
  fb_die 1 "merge of origin/$BASE into $BRANCH conflicts; recorded the files for the fixer"
fi

AFTER="$(git -C "$WT" rev-parse HEAD)" || fb_die 1 "cannot read HEAD in $WT"
CHANGED=false
if [ "$AFTER" != "$BEFORE" ] && [ -n "$(git -C "$WT" diff --name-only "$BEFORE" "$AFTER")" ]; then
  CHANGED=true
fi

if [ "$AFTER" != "$BEFORE" ]; then
  git -C "$WT" push origin "$BRANCH" || fb_die 1 "git push origin $BRANCH failed"
fi

jq -n --arg sha "$AFTER" --arg base "$BASE" --argjson changed "$CHANGED" \
  '{last_update: {sha: $sha, base: $base, changed: $changed}}' > "$TMP"
bash "$FLEET_SCRIPTS/note.sh" merge "$N" "$TMP" || fb_die 1 "cannot update the note on #$N"
