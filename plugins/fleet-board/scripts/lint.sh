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
#    script runs card-lint.sh on each card's fields (--read-file) rather than
#    reimplement them; with --bodies it lints the file as a body)
#   untestable-bullet      an acceptance item holds "manual", "manually",
#                          "visually" or "looks"; it is not a testable assertion.
#   dependency-cycle       the card is in a cycle of blocked_by references
#                          among the linted cards; the detail names every card in it.
#   unresolved-dependency  a blocked_by reference (a card number) is
#                          neither a linted card nor a card file under
#                          board.dir. A reference to another repo is outside
#                          this board: it is not checked; card creation keeps
#                          it in the body as prose.
#   missing-file           a backticked path (dir/name.ext; in the body or an
#                          acceptance item) is not on the default
#                          branch of the card's own repo (with --bodies, the
#                          <dir>/<id>.repo file names it). Lines under a
#                          "## Creates" heading are skipped: they name files
#                          the card makes. A path that the open PR (pr_url) of a
#                          card in the linted card's blocked_by adds is not flagged.
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
LCARDS="" # the card files a board.repo ref resolves to (unset without a config)
OUT="$WORK/out"; : > "$OUT"
EDGES="$WORK/edges"; : > "$EDGES"
IDS=()

if [ -n "$BODIES" ]; then
  [ -d "$BODIES" ] || fb_die 2 "not a directory: $BODIES"
  CFG="$(bash "$FB_SCRIPTS/config.sh" 2>/dev/null)" || CFG=""
  REPO=""; [ -z "$CFG" ] || REPO="$(jq -r '.board.repo // ""' <<<"$CFG")"
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  if [ -n "$CFG" ]; then
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
  LCARDS="$FLEET_ROOT/$(fb_cfg board.dir)/cards"
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
    fb_card_text "$READ" | tr -d '\r' > "$WORK/$id.md" || fb_die 3 "cannot parse card #$id"
    # a card is linted on its fields (see card-lint.sh --read-file)
    printf '%s\n' "$READ" > "$WORK/$id.read"
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
  done < <(if [ -f "$WORK/$id.read" ]; then bash "$FB_SCRIPTS/card-lint.sh" --read-file "$WORK/$id.read"; else bash "$FB_SCRIPTS/card-lint.sh" --body-file "$F"; fi)

  # untestable-bullet
  while IFS= read -r line; do
    if grep -Eiq '(^|[^[:alpha:]])(manual|manually|visually|looks)([^[:alpha:]]|$)' <<<"$line"; then
      emit "$id" untestable-bullet "${line#- }"
    fi
  done < <(if [ -f "$WORK/$id.read" ]; then jq -r '(.acceptance // [])[] | tostring | gsub("\n"; " ") | "- " + .' "$WORK/$id.read"
           else awk '/^##[ \t]+Acceptance([ \t].*)?$/{s=1;next} /^##[ \t]/{s=0} s && /^- /' "$F"; fi)

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
    if [ -n "$REPO" ] && [ "$(printf '%s' "$drepo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
      continue # outside this board: nothing to look it up in
    fi
    if [ -z "$LCARDS" ] || [ ! -f "$LCARDS/$num.json" ]; then
      emit "$id" unresolved-dependency "$tok does not exist"
    fi
  done < <(if [ -f "$WORK/$id.read" ]; then
             jq -r --arg r "$REPO" '(.blocked_by // [])[] | $r + "#" + tostring' "$WORK/$id.read"
           else awk '
    /^##[ \t]+[Dd]epends[ \t]+[Oo]n[ \t]*$/ { s = 1; next }
    /^#/ { s = 0 }
    s && /^[-*][ \t]+/ { l = $0; sub(/^[-*][ \t]+/, "", l); sub(/[ \t].*$/, "", l); print l }
  ' "$F"; fi)

  # missing-file: in the card's own repo. A card whose repo differs from the
  # board repo (<dir>/<id>.repo, written by import-plan.sh) is checked on that
  # repo's default branch through gh; any other card on this checkout's.
  crepo=""; [ -r "$BODIES/$id.repo" ] && crepo="$(tr -d '\r\n' < "$BODIES/$id.repo")"
  remote=0; [ -n "$crepo" ] && [ "$crepo" != "$REPO" ] && remote=1
  rbr=""; rdone=0
  # the remote default branch is looked up on the first path to check, so a card with none makes no gh call
  rbranch() {
    [ "$FILECHECK" -eq 1 ] || return 1
    if [ "$remote" -eq 0 ]; then rbr="$DEFBR"
    elif [ "$rdone" -eq 0 ]; then rdone=1; rbr="$(gh repo view "$crepo" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)" || rbr=""; fi
    [ -n "$rbr" ]
  }
  # dep_pr_adds <path>: a card in this card's blocked_by has an open PR (its
  # pr_url, read with gh pr view --json files,state) that adds the path
  DEP_FILES="" DEP_DONE=0
  dep_pr_adds() {
    if [ "$DEP_DONE" -eq 0 ]; then
      DEP_DONE=1
      [ -f "$WORK/$id.read" ] || return 1
      local d url view
      for d in $(jq -r '(.blocked_by // [])[] | tostring' "$WORK/$id.read"); do
        [ -n "$LCARDS" ] && [ -f "$LCARDS/$d.json" ] || continue
        url="$(jq -r '.pr_url // empty' "$LCARDS/$d.json" 2>/dev/null)"
        [ -n "$url" ] || continue
        view="$(gh pr view "$url" --json files,state 2>/dev/null)" || continue
        DEP_FILES="$DEP_FILES
$(jq -r 'select(.state == "OPEN") | .files[]?.path' <<<"$view" 2>/dev/null)"
      done
    fi
    [ -n "$DEP_FILES" ] && grep -Fxq -- "$1" <<<"$DEP_FILES"
  }
  if [ "$FILECHECK" -eq 1 ]; then
    inc=0
    while IFS= read -r line; do
      case "$line" in
        '##'*) if grep -Eiq '^##[ \t]+Creates[ \t]*$' <<<"$line"; then inc=1; else inc=0; fi; continue ;;
      esac
      [ "$inc" -eq 1 ] && continue
      while IFS= read -r span; do
        p="${span#\`}"; p="${p%\`}"
        grep -Eq '^[A-Za-z0-9_.@-][A-Za-z0-9_./@-]*/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+$' <<<"$p" || continue
        case "$p" in http*|*..*) continue ;; esac
        rbranch || continue
        dep_pr_adds "$p" && continue
        where="$rbr"; [ "$remote" -eq 1 ] && where="$rbr of $crepo"
        if [ "$remote" -eq 1 ]; then
          gh api "repos/$crepo/contents/$p?ref=$rbr" >/dev/null 2>&1 || emit "$id" missing-file "$p is not on $where"
        else
          git -C "$ROOT" cat-file -e "$rbr:$p" 2>/dev/null || emit "$id" missing-file "$p is not on $where"
        fi
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
