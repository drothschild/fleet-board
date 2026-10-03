#!/usr/bin/env bash
# item-status.sh <item-id>: prints the Status option name of a Projects v2
# item (an empty line when the item has no Status). Exits 1 when the item
# cannot be read. Used by the gate hook for `gh project item-edit --id ITEM`.
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../board-lib.sh"
. "$HERE/common.sh"

[ $# -eq 1 ] && [ -n "$1" ] || fb_die 2 "usage: item-status.sh <item-id>"
fb_load_config
fp_require_scope || exit 1

OUT="$(gh api graphql \
  -f query='query($id:ID!){node(id:$id){... on ProjectV2Item{fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}' \
  -f id="$1")" || fb_die 1 "cannot read project item $1"
jq -r 'if (.data.node | type) != "object" then error("no project item") else (.data.node.fieldValueByName.name // "") end' \
  <<<"$OUT" 2>/dev/null || fb_die 1 "cannot read project item $1"
