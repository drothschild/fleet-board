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
# the --status column (default backlog). Needs board.backend github-projects.
#
# Exit codes: 0 done (or declined), 1 failure (cycle, unknown dependency, gh),
# 2 usage error.

set -uo pipefail
unset CDPATH
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

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
' "$CARDS" 2>&1)" || fb_die 1 "$(sed -n 's/^jq: error[^:]*: \([^ ].*\) at <.*/\1/p' <<<"$PLAN" | head -1)"
N="$(jq '.cards | length' <<<"$PLAN")"

echo "| Title | Repo | Depends on | Labels |"
echo "|---|---|---|---|"
jq -r '.cards as $c | $c[]
  | "| \(.title) | \(.repo) | \([.deps[] | . as $d | ($c | map(select(.key == $d)) | first | .title) // $d] | join(", ")) | \((.labels // []) | join(", ")) |"' <<<"$PLAN"

[ "$DRY" -eq 1 ] && exit 0

printf 'Create %s issues? [y/N] ' "$N"
ANSWER=""; IFS= read -r ANSWER || true
echo
case "$ANSWER" in y|Y|yes|YES|Yes) ;; *) echo "Nothing created."; exit 0 ;; esac

fb_load_config
[ "$(fb_cfg board.backend)" = "github-projects" ] || fb_die 1 "import-plan needs board.backend github-projects"
. "$FLEET_SCRIPTS/adapters/github-projects/common.sh"
CACHE="$FLEET_ROOT/$(fb_cfg worktrees.dir)/.cache/projects.json"
fp_ensure_cache "$CACHE" || exit 1
OPT="$(fp_option_id "$(fb_state_name "$STATUS")" "$CACHE")" || exit 1
PN="$(fb_cfg board.project_number)"
PO="$(fp_get_owner)"

BODY="$(mktemp)"; trap 'rm -f "$BODY"' EXIT
REFS='{}'
i=0
while [ "$i" -lt "$N" ]; do
  card="$(jq -c --argjson i "$i" '.cards[$i]' <<<"$PLAN")"
  i=$((i + 1))
  jq -r --argjson refs "$REFS" '
    "## Why\n\(.why // "")\n\n## Scope\n" + ((.scope // []) | map("- " + .) | join("\n"))
    + "\n\n## Acceptance\n" + ((.acceptance // []) | map("- " + .) | join("\n"))
    + (if (.deps | length) > 0
       then "\n\n## Depends on\n" + (.deps | map("- " + ($refs[.] // .)) | join("\n")) else "" end)' <<<"$card" > "$BODY"
  title="$(jq -r .title <<<"$card")"; repo="$(jq -r .repo <<<"$card")"
  largs=(); while IFS= read -r l; do [ -n "$l" ] && largs+=(--label "$l"); done < <(jq -r '(.labels // [])[]' <<<"$card")
  URL="$(gh issue create --repo "$repo" --title "$title" --body-file "$BODY" ${largs[@]+"${largs[@]}"})" || fb_die 1 "failed to create: $title"
  num="${URL##*/}"
  ITEM="$(gh project item-add "$PN" --owner "$PO" --url "$URL" --format json | jq -r '.id // empty')"
  [ -n "$ITEM" ] || fb_die 1 "failed to add $URL to project $PN"
  gh project item-edit --id "$ITEM" --project-id "$(jq -r .project_id "$CACHE")" \
    --field-id "$(jq -r .field_id "$CACHE")" --single-select-option-id "$OPT" >/dev/null || fb_die 1 "failed to set status of $URL"
  REFS="$(jq -c --arg k "$(jq -r .key <<<"$card")" --arg r "$repo#$num" '. + {($k): $r}' <<<"$REFS")"
  echo "Created $repo#$num: $title"
done
