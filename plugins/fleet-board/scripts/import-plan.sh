#!/usr/bin/env bash
# import-plan.sh - turn a grouped cards file into board issues.
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
# there. Otherwise it asks "Create N issues? [y/N]" on stdin and creates
# nothing unless the answer is y or yes. Issues are created in dependency order;
# a dependency becomes "- owner/repo#N" with the real number, because the
# dependency was created first. Each issue is added to the project and set to
# the --status column (default backlog). Needs board.backend github-projects or github-labels
# (on labels, the issue gets the fleet:<status> label instead of a project item).
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

printf 'Create %s issues? [y/N] ' "$N"
ANSWER=""; IFS= read -r ANSWER || true
echo
case "$ANSWER" in y|Y|yes|YES|Yes) ;; *) echo "Nothing created."; exit 0 ;; esac

fb_load_config
BACKEND="$(fb_cfg board.backend)"
case "$BACKEND" in
  github-projects)
    . "$FLEET_SCRIPTS/adapters/github-projects/common.sh"
    CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
    fp_ensure_cache "$CACHE" || exit 1
    OPT="$(fp_option_id "$(fb_state_name "$STATUS")" "$CACHE")" || exit 1
    PN="$(fb_cfg board.project_number)"
    PO="$(fp_get_owner)" ;;
  github-labels) ;;
  *) fb_die 1 "import-plan needs board.backend github-projects or github-labels" ;;
esac

# Docs referenced from a card's why or acceptance (scope lists files the card will
# create, so it is not scanned) must exist on the default branch, because role
# worktrees branch from it. A reference is path.md or path.md#section.
DOCRE='[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*/[A-Za-z0-9_.-]+\\.md(?:#[A-Za-z0-9_-]+)?'
GITTOP="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFREF="$(git -C "$GITTOP" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
MISSING=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  git -C "$GITTOP" cat-file -e "$DEFREF:$p" >/dev/null 2>&1 || MISSING+=("$p")
done < <(jq -r "[.cards[] | ([.why // \"\"] + (.acceptance // []))[] | scan(\"$DOCRE\")] | map(sub(\"#.*\$\"; \"\")) | unique[]" <<<"$PLAN" 2>/dev/null)
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

REFS='{}'
ENSURED=" "
i=0
while [ "$i" -lt "$N" ]; do
  card="$(jq -c --argjson i "$i" '.cards[$i]' <<<"$PLAN")"
  i=$((i + 1))
  if [ "$EMBED" -eq 1 ]; then
    embedded=""
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      p="${ref%%#*}"; a=""; case "$ref" in *"#"*) a="${ref#*#}" ;; esac
      miss=0; for m in "${MISSING[@]}"; do [ "$m" = "$p" ] && miss=1; done
      [ "$miss" -eq 1 ] || continue
      [ -f "$GITTOP/$p" ] || fb_die 1 "cannot embed $ref: $p is not in the working tree"
      text="$(section_text "$GITTOP/$p" "$a")"
      [ -n "$text" ] || fb_die 1 "cannot embed $ref: section not found"
      embedded="$embedded
### Embedded from $(basename "$p")

$text
"
    done < <(jq -r "[([.why // \"\"] + (.acceptance // []))[] | scan(\"$DOCRE\")] | unique[]" <<<"$card")
    if [ -n "$embedded" ]; then
      for m in "${MISSING[@]}"; do embedded="${embedded//$m/the doc}"; done
      card="$(jq -c --arg e "$embedded" --argjson miss "$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -sc .)" '
        def strip: reduce $miss[] as $m (.; split($m) | join("(embedded below)"));
        def stripref: gsub("(embedded below)#[A-Za-z0-9_-]+"; "(embedded below)");
        .why |= ((. // "") | strip | stripref)
        | .acceptance |= ((. // []) | map(strip | stripref))
        | .embedded = $e' <<<"$card")"
    fi
  fi
  render_body "$REFS" <<<"$card" > "$BODY"
  title="$(jq -r .title <<<"$card")"; repo="$(jq -r .repo <<<"$card")"
  if [ "$BACKEND" = "github-labels" ]; then
    case "$ENSURED" in
      *" $repo "*) ;;
      *)
        slabel="$(fb_state_name "$STATUS")"
        have="$(gh label list --repo "$repo" --limit 1000 --json name --jq '.[].name' 2>/dev/null)" || have=""
        printf '%s\n' "$have" | grep -qxF -- "$slabel" \
          || gh label create "$slabel" --repo "$repo" >/dev/null || fb_die 1 "failed to create label $slabel in $repo"
        ENSURED="$ENSURED$repo " ;;
    esac
  fi
  largs=()
  [ "$BACKEND" = "github-labels" ] && largs+=(--label "$(fb_state_name "$STATUS")")
  while IFS= read -r l; do [ -n "$l" ] && largs+=(--label "$l"); done < <(jq -r '(.labels // [])[]' <<<"$card")
  URL="$(gh issue create --repo "$repo" --title "$title" --body-file "$BODY" ${largs[@]+"${largs[@]}"})" || fb_die 1 "failed to create: $title"
  num="${URL##*/}"
  if [ "$BACKEND" = "github-projects" ]; then
  ITEM="$(gh project item-add "$PN" --owner "$PO" --url "$URL" --format json | jq -r '.id // empty')"
  [ -n "$ITEM" ] || fb_die 1 "failed to add $URL to project $PN"
  gh project item-edit --id "$ITEM" --project-id "$(jq -r .project_id "$CACHE")" \
    --field-id "$(jq -r .field_id "$CACHE")" --single-select-option-id "$OPT" >/dev/null || fb_die 1 "failed to set status of $URL"
  fi
  REFS="$(jq -c --arg k "$(jq -r .key <<<"$card")" --arg r "$repo#$num" '. + {($k): $r}' <<<"$REFS")"
  echo "Created $repo#$num: $title"
done
