#!/usr/bin/env bash
# lint.sh - lints cards before they are moved to Ready (or created).
#
# Usage: lint.sh [card...]
#        lint.sh --bodies <dir> [--no-file-check] [card...]
#
# With card numbers it lints those cards; with none, every Ready and Backlog
# card. --bodies reads the cards from <dir>/<id>.md instead of the board (id is
# a number, or any key; import-plan.sh lints its generated cards this way, with
# a dependency written as "- <key>"). --no-file-check skips missing-file.
#
# Prints one line per violation, "#<id>: <rule>: <detail>", and exits 1; prints
# nothing and exits 0 when every card passes. Rules:
#   (all of card-lint.sh's rules: no-heading, no-bullets, manual-check; this
#    script runs card-lint.sh --body-file on each card rather than reimplement them)
#   untestable-bullet      an Acceptance bullet holds "manual", "manually",
#                          "visually" or "looks"; it is not a testable assertion.
#   dependency-cycle       the card is in a cycle of "## Depends on" references
#                          among the linted cards; the detail names every card in it.
#   unresolved-dependency  a "## Depends on" reference is neither a linted card
#                          nor an issue "gh issue view" finds (on the local
#                          backend a board.repo reference is a card file
#                          under board.dir; a missing file is unresolved).
#   missing-file           a backticked path (dir/name.ext) is not on the default
#                          branch. A line with create, new or add(s) is skipped:
#                          it names a file the card makes.
#
# Exit codes: 0 pass, 1 lint failed, 2 usage error, 3 a card could not be read.

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

USAGE="usage: lint.sh [--bodies <dir>] [--no-file-check] [card...]"
BODIES="" FILECHECK=1 ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bodies) [ $# -ge 2 ] || fb_die 2 "$USAGE"; BODIES="$2"; shift 2 ;;
    --no-file-check) FILECHECK=0; shift ;;
    -*) fb_die 2 "$USAGE" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LCARDS="" # set on the local backend: the card files a board.repo ref resolves to
OUT="$WORK/out"; : > "$OUT"
EDGES="$WORK/edges"; : > "$EDGES"
IDS=()

if [ -n "$BODIES" ]; then
  [ -d "$BODIES" ] || fb_die 2 "not a directory: $BODIES"
  CFG="$(bash "$FB_SCRIPTS/config.sh" 2>/dev/null)" || CFG=""
  REPO=""; [ -z "$CFG" ] || REPO="$(jq -r '.board.repo // ""' <<<"$CFG")"
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  if [ -n "$CFG" ] && [ "$(jq -r '.board.backend // ""' <<<"$CFG")" = local ]; then
    LCOMMON="$(fb_git_common_dir .)" && LROOT="$(dirname "$LCOMMON")" || LROOT="$(pwd)"
    LCARDS="$LROOT/$(jq -r '.board.dir // ".fleet-board"' <<<"$CFG")/cards"
  fi
  if [ ${#ARGS[@]} -gt 0 ]; then IDS=("${ARGS[@]}")
  else
    for f in "$BODIES"/*.md; do [ -e "$f" ] && { b="${f##*/}"; IDS+=("${b%.md}"); }; done
  fi
  for id in ${IDS[@]+"${IDS[@]}"}; do
    [ -r "$BODIES/$id.md" ] || fb_die 3 "cannot read card $id"
    tr -d '\r' < "$BODIES/$id.md" > "$WORK/$id.md"
  done
else
  fb_load_config
  REPO="$FLEET_REPO"; ROOT="$FLEET_ROOT"
  [ "$(fb_cfg board.backend)" != local ] || LCARDS="$FLEET_ROOT/$(fb_cfg board.dir)/cards"
  if [ ${#ARGS[@]} -gt 0 ]; then
    IDS=("${ARGS[@]}")
  else
    for st in ready backlog; do
      LIST="$(bash "$FLEET_SCRIPTS/board-list.sh" "$st")" || fb_die 3 "cannot list the $st column"
      while IFS= read -r n; do [ -n "$n" ] && IDS+=("$n"); done < <(jq -r '.[].number' <<<"$LIST")
    done
  fi
  for id in ${IDS[@]+"${IDS[@]}"}; do
    fb_valid_number "$id" || fb_die 2 "card number must be numeric, got: $id"
    READ="$(bash "$FLEET_SCRIPTS/board-read.sh" "$id")" || fb_die 3 "cannot read card #$id"
    jq -r '.body // ""' <<<"$READ" | tr -d '\r' > "$WORK/$id.md" || fb_die 3 "cannot parse card #$id"
  done
fi

emit() { printf '#%s: %s: %s\n' "$1" "$2" "$3" >> "$OUT"; }
in_set() { local i; for i in ${IDS[@]+"${IDS[@]}"}; do [ "$i" = "$1" ] && return 0; done; return 1; }

DEFBR=""
if [ "$FILECHECK" -eq 1 ]; then
  DEFBR="$(git -C "$ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || DEFBR=""
  if [ -z "$DEFBR" ]; then
    for b in main master; do git -C "$ROOT" rev-parse --verify -q "$b" >/dev/null 2>&1 && { DEFBR="$b"; break; }; done
  fi
fi

for id in ${IDS[@]+"${IDS[@]}"}; do
  F="$WORK/$id.md"

  # card-lint.sh's rules
  while IFS= read -r line; do
    [ -n "$line" ] && printf '#%s: %s\n' "$id" "$line" >> "$OUT"
  done < <(bash "$FB_SCRIPTS/card-lint.sh" --body-file "$F")

  # untestable-bullet
  while IFS= read -r line; do
    if grep -Eiq '(^|[^[:alpha:]])(manual|manually|visually|looks)([^[:alpha:]]|$)' <<<"$line"; then
      emit "$id" untestable-bullet "${line#- }"
    fi
  done < <(awk '/^##[ \t]+Acceptance([ \t].*)?$/{s=1;next} /^##[ \t]/{s=0} s && /^- /' "$F")

  # dependencies
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    key="$tok"; ext=0
    case "$tok" in
      "$REPO"#[0-9]*) [ -n "$REPO" ] && key="${tok#*#}" ;;
      */*#[0-9]*) ext=1 ;;
      '#'[0-9]*) key="${tok#\#}" ;;
    esac
    if [ "$ext" -eq 0 ] && in_set "$key"; then
      printf '%s %s\n' "$id" "$key" >> "$EDGES"
      continue
    fi
    num="${tok##*#}"; drepo="${tok%#*}"
    case "$tok" in
      '#'[0-9]*) drepo="$REPO" ;;
      */*#[0-9]*) ;;
      *) emit "$id" unresolved-dependency "$tok is not a card in this set"; continue ;;
    esac
    if [ -n "$LCARDS" ] && [ -n "$REPO" ] && [ "$drepo" = "$REPO" ]; then
      [ -f "$LCARDS/$num.json" ] || emit "$id" unresolved-dependency "$tok does not exist"
      continue
    fi
    if [ -z "$drepo" ] || ! gh issue view "$num" --repo "$drepo" --json state >/dev/null 2>&1; then
      emit "$id" unresolved-dependency "$tok does not exist"
    fi
  done < <(awk '
    /^##[ \t]+[Dd]epends[ \t]+[Oo]n[ \t]*$/ { s = 1; next }
    /^#/ { s = 0 }
    s && /^[-*][ \t]+/ { l = $0; sub(/^[-*][ \t]+/, "", l); sub(/[ \t].*$/, "", l); print l }
  ' "$F")

  # missing-file
  if [ -n "$DEFBR" ]; then
    while IFS= read -r line; do
      grep -Eiq '(^|[^[:alpha:]])(create[sd]?|new|adds?)([^[:alpha:]]|$)' <<<"$line" && continue
      while IFS= read -r span; do
        p="${span#\`}"; p="${p%\`}"
        grep -Eq '^[A-Za-z0-9_.@-][A-Za-z0-9_./@-]*/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+$' <<<"$p" || continue
        case "$p" in http*|*..*) continue ;; esac
        git -C "$ROOT" cat-file -e "$DEFBR:$p" 2>/dev/null || emit "$id" missing-file "$p is not on $DEFBR"
      done < <(grep -Eo '`[^`]+`' <<<"$line")
    done < "$F"
  fi
done

# dependency-cycle: a card that can reach itself through in-set edges
if [ -s "$EDGES" ]; then
  G="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ")) | reduce .[] as $e ({}; .[$e[0]] += [$e[1]])' < "$EDGES")"
  CYC="$(jq -r -n --argjson g "$G" '
    def reach($n):
      {seen: [], front: [$n]}
      | until(.front | length == 0;
          . as $s
          | ([$s.front[] | ($g[.] // [])[]] | unique) as $nx
          | ([$nx[] | select(. as $x | $s.seen | index($x) | not)]) as $new
          | {seen: ($s.seen + $new), front: $new})
      | .seen;
    ($g | keys[]) as $n
    | reach($n) as $r
    | select($r | index($n))
    | ([$n] + [$r[] | select(. as $m | reach($m) | index($n))] | unique | join(", #")) as $members
    | "\($n)\t#\($members)"')" || CYC=""
  while IFS=$'\t' read -r n members; do
    [ -n "$n" ] && emit "$n" dependency-cycle "depends on itself through $members"
  done <<<"$CYC"
fi

sort -t: -k1,1 -s "$OUT" > "$WORK/sorted"
cat "$WORK/sorted"
[ -s "$OUT" ] && exit 1
exit 0
