#!/usr/bin/env bash
# import-plan.sh - turn a grouped cards file into board cards.
#
# Usage: import-plan.sh <cards.json> [--status backlog|ready] [--dry-run]
#
# <cards.json> is {"cards": [...]}, each card:
#   key        short unique id used inside the file
#   title, repo (owner/repo), labels [..], why, scope [..], acceptance [..]
#   consumes [..], produces [..]   interface names; a card that consumes a name
#                                   another card produces depends on that card
#   depends_on [..]                optional: other card keys, or "owner/repo#N"
#
# Prints a table (Title, Repo, Depends on, Labels). With --dry-run it stops
# there. Otherwise it asks "Create N cards? [y/N]" on stdin and creates
# nothing unless the answer is y or yes. Cards are created on the local board
# in dependency order, in the --status column (default backlog), through
# board-create.sh: acceptance goes into the acceptance field and each
# dependency into blocked_by (a card key becomes the real number, because the
# dependency was created first; "#N" or "<board.repo>#N" is that card). A
# dependency in another repo is outside this board: it stays in the body as
# prose, with a warning.
#
# import-plan.sh parse <plan.md>
#   Prints {"cards": [{title, scope, acceptance}, ...]} as JSON, one card per
#   "## Task N: <title>" heading. scope comes from the bullets under "Files:",
#   acceptance from the bullets under "Test steps:" (copied verbatim, never
#   invented). Same input, same output. Exit 1 when there is no task heading.
#
# Before the table, every card is checked with lint.sh (untestable bullets,
# unresolved dependencies, ...); a card that fails stops the run with nothing
# created.
#
# Exit codes: 0 done (or declined), 1 failure (cycle, unknown dependency, lint, gh),
# 2 usage error.

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

FLEET_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "parse" ]; then
  [ $# -eq 2 ] || fb_die 2 "usage: import-plan.sh parse <plan.md>"
  [ -f "$2" ] || fb_die 2 "file not found: $2"
  OUT="$(LC_ALL=C awk '
    function esc(t) { gsub(/\\/, "\\\\", t); gsub(/"/, "\\\"", t); gsub(/\t/, "\\t", t); return t }
    function flush() { if (n) { printf "%s{\"title\":\"%s\",\"scope\":[%s],\"acceptance\":[%s]}", (n > 1 ? "," : ""), title, sc, ac } }
    /\r$/ { sub(/\r$/, "") }
    /^## Task [^:]*:/ { flush(); n++; t = $0; sub(/^## Task [^:]*:[ \t]*/, "", t); sub(/[ \t]+$/, "", t); title = esc(t); sc = ""; ac = ""; mode = ""; next }
    /^## / { mode = ""; next }
    n == 0 { next }
    /^[ \t]*Files:[ \t]*$/ { mode = "s"; next }
    /^[ \t]*Test steps:[ \t]*$/ { mode = "a"; next }
    /^- / && mode != "" { b = "\"" esc(substr($0, 3)) "\""; if (mode == "s") sc = sc (sc == "" ? "" : ",") b; else ac = ac (ac == "" ? "" : ",") b; next }
    /^[ \t]*$/ { next }
    { mode = "" }
    END { flush(); if (n) print ""; exit (n ? 0 : 3) }
  ' "$2")" && [ -n "$OUT" ] || fb_die 1 "no task headings (## Task N: <title>) found in $2"
  printf '{"cards":[%s]}\n' "$OUT" | jq -S .
  exit 0
fi

USAGE="usage: import-plan.sh <cards.json> [--status backlog|ready] [--dry-run]"
CARDS="" STATUS=backlog DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --status) [ $# -ge 2 ] || fb_die 2 "$USAGE"; STATUS="$2"; shift 2 ;;
    -*) fb_die 2 "$USAGE" ;;
    *) [ -z "$CARDS" ] || fb_die 2 "$USAGE"; CARDS="$1"; shift ;;
  esac
done
[ -n "$CARDS" ] || fb_die 2 "$USAGE"
[ -f "$CARDS" ] || fb_die 2 "file not found: $CARDS"
case "$STATUS" in backlog|ready) ;; *) fb_die 2 "--status must be backlog or ready" ;; esac
jq -e '.cards | type == "array" and length > 0' "$CARDS" >/dev/null 2>&1 || fb_die 2 "$CARDS has no cards"

# Resolve dependencies and order: {cards: [... + deps: [keys or refs]]} in creation order.
PLAN="$(jq -c '
  def isref: test("^[^/]+/[^#]+#[0-9]+$");
  .cards as $all
  | ($all | map(.key)) as $keys
  | ($all | map(. as $c
      | $c + {deps: ((($c.depends_on // [])
          + [$all[] | select(.key != $c.key
              and ((.produces // []) | any(. as $p | ($c.consumes // []) | index($p) != null))) | .key])
        | unique)})) as $res
  | ([$res[].deps[] | select((isref | not) and (. as $d | $keys | index($d) == null))]) as $unknown
  | if ($unknown | length) > 0 then error("unknown dependency: " + ($unknown | join(", "))) else . end
  | reduce range(0; $res | length) as $_ ({order: [], placed: []};
      . as $s
      | [$res[] | select(.key as $k | $s.placed | index($k) == null)
               | select(.deps | all(. as $d | isref or ($s.placed | index($d) != null)))] as $ready
      | .order += $ready | .placed += ($ready | map(.key)))
  | if (.order | length) < ($res | length) then error("dependency cycle among cards") else {cards: .order} end
' "$CARDS" 2>&1)" || fb_die 1 "$(sed -n -e 's/^jq: error ([^)]*): //' -e 's/^jq: error: //' -e 's/ at <[^>]*>.*$//' -e '/^jq: /d' -e '1p' <<<"$PLAN")"
N="$(jq '.cards | length' <<<"$PLAN")"

# render_body <refs-json>: the issue body of the card on stdin; a dependency
# key found in <refs-json> becomes its real reference, any other stays as written
render_body() {
  jq -r --argjson refs "$1" '
    "## Why\n\(.why // "")\n\n## Scope\n" + ((.scope // []) | map("- " + .) | join("\n"))
    + "\n\n## Acceptance\n" + ((.acceptance // []) | map("- " + .) | join("\n"))
    + (if (.deps | length) > 0
       then "\n\n## Depends on\n" + (.deps | map("- " + ($refs[.] // .)) | join("\n")) else "" end)
    + (if .embedded then "\n\n## Referenced docs\n" + .embedded else "" end)'
}

# The card linter: render every card with its dependencies as plan keys and
# lint the set. A failing card stops the import before anything is created.
LINTDIR="$(mktemp -d)"
BODY="$(mktemp)"; trap 'rm -rf "$LINTDIR" "$BODY"' EXIT
n=0
while [ "$n" -lt "$N" ]; do
  jq -c --argjson i "$n" '.cards[$i]' <<<"$PLAN" > "$LINTDIR/.card"
  lkey="$(jq -r '.key | gsub("[^A-Za-z0-9_.-]"; "_")' "$LINTDIR/.card")"
  render_body '{}' < "$LINTDIR/.card" > "$LINTDIR/$lkey.md"
  jq -r '.repo // ""' "$LINTDIR/.card" > "$LINTDIR/$lkey.repo"
  n=$((n + 1))
done
rm -f "$LINTDIR/.card"
LINTOUT="$(bash "$FLEET_SCRIPTS_DIR/lint.sh" --bodies "$LINTDIR")" || {
  printf '%s\n' "$LINTOUT" >&2
  fb_die 1 "card lint failed; nothing was created"
}

echo "| Title | Repo | Depends on | Labels |"
echo "|---|---|---|---|"
jq -r 'def esc: gsub("\\|"; "\\|");
  .cards as $c | $c[]
  | "| \(.title | esc) | \(.repo) | \([.deps[] | . as $d | ($c | map(select(.key == $d)) | first | .title) // $d | esc] | join(", ")) | \((.labels // []) | join(", ")) |"' <<<"$PLAN"

[ "$DRY" -eq 1 ] && exit 0

printf 'Create %s cards? [y/N] ' "$N"
ANSWER=""; IFS= read -r ANSWER || true
echo
case "$ANSWER" in y|Y|yes|YES|Yes) ;; *) echo "Nothing created."; exit 0 ;; esac

fb_load_config

# Docs referenced from a card's why or acceptance must exist on the default branch,
# because role worktrees branch from it. A reference is path.md or path.md#section.
# Not checked: a path the card itself creates (it equals, or is a path suffix of, a
# path in the card's scope), and a path that exists neither on the default branch
# nor in the working tree (warned about and left as written: nothing to embed).
DOCRE='[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*/[A-Za-z0-9_.-]+\.md(?:#[A-Za-z0-9_-]+)?'
GITTOP="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFREF="$(git -C "$GITTOP" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
# each card gains .docrefs: its why/acceptance references, minus the ones its scope owns
PLAN="$(jq -c --arg re "$DOCRE" '
  .cards |= map(
    ([(.scope // [])[] | scan($re) | sub("#.*$"; "") | sub("^(\\./)+"; "")]) as $own
    | .docrefs = ([([.why // ""] + (.acceptance // []))[] | scan($re)] | unique
        | map(select(sub("#.*$"; "") | sub("^(\\./)+"; "") as $p | $own | any(. == $p or endswith("/" + $p)) | not))))' <<<"$PLAN")" \
  || fb_die 1 "cannot scan the cards for doc references"
MISSING=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  q="$p"; while [ "${q#./}" != "$q" ]; do q="${q#./}"; done  # ./docs/x.md is docs/x.md
  case "/$q/" in */./*|*/../*) echo "warning: $p is referenced but is not a plain repo path; left as written" >&2; continue ;; esac
  git -C "$GITTOP" cat-file -e "$DEFREF:$q" >/dev/null 2>&1 && continue
  if [ -f "$GITTOP/$q" ]; then MISSING+=("$p")
  else echo "warning: $p is referenced but exists neither on $DEFREF nor in the working tree; left as written" >&2
  fi
done < <(jq -r '[.cards[].docrefs[] | sub("#.*$"; "")] | unique[]' <<<"$PLAN")
EMBED=0
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "These docs are missing on the default branch ($DEFREF), so agents cannot see them:"
  printf '  %s\n' "${MISSING[@]}"
  echo "Choose: [m] commit and merge the docs first, [e] embed the section into the card"
  CHOICE=""; IFS= read -r CHOICE || true
  case "$CHOICE" in
    e|E|embed) EMBED=1 ;;
    *) echo "Nothing created. Commit and merge the docs above, then run import-plan again." >&2; exit 1 ;;
  esac
fi

# section_text <file> <anchor>: the section whose heading slug equals anchor, or the whole file.
section_text() {
  if [ -z "$2" ]; then cat "$1"; return; fi
  awk -v want="$2" '
    /^#+ / { h=$0; lvl=match(h, /[^#]/)-1; t=tolower(substr(h, lvl+2)); gsub(/[^a-z0-9]+/, "-", t); sub(/^-/, "", t); sub(/-$/, "", t)
             if (on && lvl <= L) exit
             if (!on && t == want) { on=1; L=lvl } }
    on { print }' "$1"
}

# Prepare every card first, so an embed failure (a missing section) stops the run
# before anything is created.
PREP="$(mktemp)" || fb_die 1 "cannot create a temp file"
ACC="$(mktemp)" || fb_die 1 "cannot create a temp file"
trap 'rm -rf "$LINTDIR" "$BODY" "$ACC" "$PREP"' EXIT
i=0
while [ "$i" -lt "$N" ]; do
  card="$(jq -c --argjson i "$i" '.cards[$i]' <<<"$PLAN")"
  i=$((i + 1))
  if [ "$EMBED" -eq 1 ]; then
    embedded=""; used=()
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      p="${ref%%#*}"; a=""; case "$ref" in *"#"*) a="${ref#*#}" ;; esac
      miss=0; for m in ${MISSING[@]+"${MISSING[@]}"}; do [ "$m" = "$p" ] && miss=1; done
      [ "$miss" -eq 1 ] || continue
      [ -f "$GITTOP/$p" ] || fb_die 1 "cannot embed $ref: $p is not in the working tree; nothing was created"
      text="$(section_text "$GITTOP/$p" "$a")"
      [ -n "$text" ] || fb_die 1 "cannot embed $ref: section not found; nothing was created"
      used+=("$p")
      embedded="$embedded
### Embedded from $(basename "$p")

$text
"
    done < <(jq -r '.docrefs[]' <<<"$card")
    if [ -n "$embedded" ]; then
      for m in "${MISSING[@]}"; do embedded="${embedded//$m/the doc}"; done
      card="$(jq -c --arg e "$embedded" --argjson miss "$(printf '%s\n' "${used[@]}" | jq -R . | jq -sc 'unique')" '
        def strip: reduce $miss[] as $m (.; split($m) | join("(embedded below)"));
        def stripref: gsub("\\(embedded below\\)#[A-Za-z0-9_-]+"; "(embedded below)");
        .why |= ((. // "") | strip | stripref)
        | .acceptance |= ((. // []) | map(strip | stripref))
        | .embedded = $e' <<<"$card")" || fb_die 1 "cannot embed the docs; nothing was created"
    fi
  fi
  printf '%s\n' "$card" >> "$PREP"
done

REFS='{}'
while IFS= read -r card <&3; do
  # the body holds the prose and any outside dependency; the fields hold the rest
  jq -r --arg repo "$FLEET_REPO" '
    def board_ref: (ascii_downcase | startswith(($repo | ascii_downcase) + "#")) or test("^#[0-9]+$");
    "## Why\n\(.why // "")\n\n## Scope\n" + ((.scope // []) | map("- " + .) | join("\n"))
    + ([.deps[] | select(test("^[^/]+/[^#]+#[0-9]+$") and (board_ref | not))] as $out
       | if ($out | length) > 0 then "\n\n## Depends on\n" + ($out | map("- " + .) | join("\n")) else "" end)
    + (if .embedded then "\n\n## Referenced docs\n" + .embedded else "" end)' <<<"$card" > "$BODY" \
    || fb_die 1 "cannot write the card body"
  jq -r '(.acceptance // [])[] | "- " + .' <<<"$card" > "$ACC" || fb_die 1 "cannot write the card acceptance"
  title="$(jq -r .title <<<"$card")"
  cargs=(--state "$STATUS" --acceptance-file "$ACC")
  while IFS= read -r l; do [ -n "$l" ] && cargs+=(--label "$l"); done < <(jq -r '(.labels // [])[]' <<<"$card")
  while IFS= read -r d; do [ -n "$d" ] && cargs+=(--blocked-by "$d"); done < <(jq -r --argjson refs "$REFS" --arg repo "$FLEET_REPO" '
    .deps[] | ($refs[.] // .)
    | if test("^#[0-9]+$") then .[1:]
      elif (ascii_downcase | startswith(($repo | ascii_downcase) + "#")) then split("#")[1]
      else empty end' <<<"$card")
  OUT="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" "${cargs[@]}")" || fb_die 1 "failed to create: $title"
  num="$(jq -r .number <<<"$OUT")"
  CREATED="#$num"
  REFS="$(jq -c --arg k "$(jq -r .key <<<"$card")" --arg r "#$num" '. + {($k): $r}' <<<"$REFS")"
  echo "Created $CREATED: $title"
done 3< "$PREP"
