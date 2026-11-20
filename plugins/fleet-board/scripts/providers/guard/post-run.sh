#!/usr/bin/env bash
# post-run.sh snapshot|check <snapshot-file> <root> <worktree> <branch> <card>
#
# snapshot records, at the start of a provider session: the hash of <root>/.fleet-board.yml, a hash of
# each file under <root>/.fleet-board/ that is not the board's own runtime data (cards, claims,
# active, next, usage), the card's state, the heads of origin's branches, and the content hash of each
# file git status shows changed in <root> outside the worktree.
# check compares those with now. No difference: exit 0, no output. Any difference: stdout is one JSON
# line {"attention": <reason>, "differences": [...]}, the reason on stderr, exit 3.
# Exit 2 on a usage error or when a snapshot or comparison cannot be made (fail closed).
set -uo pipefail
unset CDPATH
[ $# -eq 6 ] || { echo "usage: post-run.sh snapshot|check <snapshot-file> <root> <worktree> <branch> <card>" >&2; exit 2; }
MODE="$1"; SNAP="$2"; ROOT_IN="$3"; WT_IN="$4"; BRANCH="$5"; CARD="$6"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${FLEET_SCRIPTS:-$(cd "$HERE/../.." && pwd)}"
die() { printf 'fleet-board guard: post-run: %s\n' "$1" >&2; exit 2; }

ROOT="$(cd "$ROOT_IN" 2>/dev/null && pwd -P)" || die "root $ROOT_IN is not a directory"
WT="$(cd "$WT_IN" 2>/dev/null && pwd -P)" || die "worktree $WT_IN is not a directory"
[ "$MODE" = snapshot ] || [ "$MODE" = check ] || die "unknown mode $MODE"

sha() { # sha FILE: sha256 of a file, or "none" when it is not there
  [ -f "$1" ] || { echo none; return 0; }
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

collect() { # prints the state as one JSON object
  local yml files="{}" f rel state branches outside="{}" line path
  yml="$(sha "$ROOT/.fleet-board.yml")"
  if [ -d "$ROOT/.fleet-board" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f#"$ROOT"/}"
      files="$(jq -c --arg k "$rel" --arg v "$(sha "$f")" '. + {($k): $v}' <<<"$files")" || die "cannot record $rel"
    done < <(find "$ROOT/.fleet-board" \( -name cards -o -name .claims -o -name active -o -name usage.jsonl.lock \) -prune -o \
               -type f ! -name next ! -name 'usage.jsonl' ! -name .DS_Store -print 2>/dev/null | LC_ALL=C sort)
  fi
  state="$(bash "$SCRIPTS/board-read.sh" "$CARD" 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" || state=""
  [ -n "$state" ] || die "cannot read the state of card $CARD"
  branches="$(git -C "$WT" ls-remote --heads origin 2>/dev/null | awk '{sub("refs/heads/", "", $2); print $2 " " $1}' | LC_ALL=C sort \
              | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries')" || die "cannot list origin's branches"
  [ -n "$branches" ] || branches="{}"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    case "$path" in .fleet-board.yml|.fleet-board|.fleet-board/*) continue ;; esac
    case "$ROOT/$path" in "$WT"/*|"$WT") continue ;; esac
    outside="$(jq -c --arg k "$path" --arg v "$(sha "$ROOT/$path")" '. + {($k): $v}' <<<"$outside")" || die "cannot record $path"
  done < <(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null | LC_ALL=C sort)
  jq -nc --arg yml "$yml" --argjson files "$files" --arg state "$state" --argjson branches "$branches" --argjson outside "$outside" \
    '{yml: $yml, files: $files, card_state: $state, branches: $branches, outside: $outside}'
}

NOW="$(collect)" || exit 2
if [ "$MODE" = snapshot ]; then
  printf '%s\n' "$NOW" > "$SNAP" || die "cannot write $SNAP"
  exit 0
fi

[ -f "$SNAP" ] || die "no snapshot at $SNAP"
DIFF="$(jq -nc --slurpfile a "$SNAP" --argjson b "$NOW" --arg branch "$BRANCH" '
  $a[0] as $a
  | [ (if $a.yml != $b.yml then ".fleet-board.yml changed" else empty end),
      (($a.files + $b.files | keys_unsorted | unique)[] as $k
        | select(($a.files[$k] // "none") != ($b.files[$k] // "none"))
        | "\($k) changed"),
      (if $a.card_state != $b.card_state then "card state changed from \($a.card_state) to \($b.card_state)" else empty end),
      (($a.branches + $b.branches | keys_unsorted | unique)[] as $k
        | select(($a.branches[$k] // "none") != ($b.branches[$k] // "none"))
        | select($k != $branch)
        | "branch \($k) was pushed or changed on origin"),
      (($a.outside + $b.outside | keys_unsorted | unique)[] as $k
        | select(($a.outside[$k] // "none") != ($b.outside[$k] // "none"))
        | "file \($k) changed outside the worktree") ]')" || die "cannot compare the state with the snapshot"
if [ "$(jq 'length' <<<"$DIFF")" = 0 ]; then exit 0; fi
REASON="provider session changed: $(jq -r 'join("; ")' <<<"$DIFF")"
printf 'fleet-board guard: %s\n' "$REASON" >&2
jq -nc --arg r "$REASON" --argjson d "$DIFF" '{attention: $r, differences: $d}'
exit 3
