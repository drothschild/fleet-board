#!/usr/bin/env bash
# common.sh - Shared GitHub Projects adapter functions
#
# Sourced by contract scripts; provides helper functions for Projects backend.
# Exports: fp_require_scope, fp_ensure_cache, fp_item_for, fp_option_id

# Get project owner from config or extract from FLEET_REPO
fp_get_owner() {
  local o; o="$(fb_cfg board.project_owner)"
  if [ -z "$o" ] || [ "$o" = "null" ]; then
    # Extract from FLEET_REPO (format: owner/repo)
    echo "$FLEET_REPO" | cut -d/ -f1
  else
    echo "$o"
  fi
}

# Verify the active gh account's token has the 'project' scope. gh auth status
# can exit non-zero because of another account, so its exit status alone is
# not fatal: the active account's scopes line decides. With no scopes line,
# a zero exit means a token gh cannot inspect (the API error will surface),
# and a non-zero exit means gh is not logged in.
fp_require_scope() {
  local out rc scopes
  out="$(gh auth status 2>&1)"; rc=$?
  scopes="$(fb_token_scopes "$out")"
  if [ -z "$scopes" ]; then
    [ "$rc" -eq 0 ] && return 0
    fb_die 1 "gh is not logged in (gh auth status exited $rc):"$'\n'"$out"
  fi
  fb_has_scope "$scopes" project && return 0
  fb_die 1 "the gh token lacks the 'project' scope. Run: gh auth refresh -s project"
}

# Ensure the id cache exists; populate it if missing. The cache is written
# only from a complete lookup, so a failed tick never leaves a bad cache.
fp_ensure_cache() {
  local cache="$1" pn po pid fields entry tmp
  [ -f "$cache" ] && return 0

  fp_require_scope || return 1
  pn="$(fb_cfg board.project_number)"
  po="$(fp_get_owner)"

  pid="$(gh project view "$pn" --owner "$po" --format json | jq -r '.id // empty')" || \
    fb_die 1 "cannot read project $pn (owner $po)"
  [ -n "$pid" ] || fb_die 1 "cannot read project $pn (owner $po): no project id"

  fields="$(gh project field-list "$pn" --owner "$po" --format json --limit 100)" || \
    fb_die 1 "cannot read fields of project $pn"
  entry="$(jq -c --arg pid "$pid" \
    'first(.fields[] | select(.name == "Status")) // empty
     | {project_id: $pid, field_id: .id, options: (.options | map({(.name): .id}) | add // {})}' \
    <<<"$fields")" || fb_die 1 "cannot parse fields of project $pn"
  [ -n "$entry" ] || fb_die 1 "project $pn has no Status field"

  mkdir -p "$(dirname "$cache")" || fb_die 1 "cannot create $(dirname "$cache")"
  tmp="$cache.$$"
  printf '%s\n' "$entry" > "$tmp" && mv "$tmp" "$cache" || { rm -f "$tmp"; fb_die 1 "cannot write $cache"; }
}

# fp_item_for <n>: prints "<item_id>\t<status name>" for the issue's item on
# this project, or nothing when the issue is not on the project. A failed
# lookup exits 1; it is never reported as "no item".
fp_item_for() {
  local n="$1" pn po result
  pn="$(fb_cfg board.project_number)"
  po="$(fp_get_owner)"
  result="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:20){nodes{id project{number} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' \
    -f o="${FLEET_REPO%%/*}" -f r="${FLEET_REPO#*/}" -F n="$n")" || \
    fb_die 1 "cannot look up project items for #$n"
  jq -r --argjson pn "$pn" '
    (.data.repository.issue.projectItems.nodes // error("no projectItems in response"))
    | map(select(.project.number == $pn)) | first // empty
    | "\(.id)\t\(.fieldValueByName.name // "")"' <<<"$result" || \
    fb_die 1 "cannot parse project items for #$n"
}

# Get option ID by name, or die with available options
fp_option_id() {
  local name="$1" cache="$2" opts

  opts="$(jq -r --arg n "$name" '.options[$n] // empty' "$cache")"
  [ -n "$opts" ] && { echo "$opts"; return 0; }

  # Option not found; list available
  local available
  available="$(jq -r '.options | keys | join(", ")' "$cache")"
  local pn
  pn="$(fb_cfg board.project_number)"
  fb_die 1 "Status option '$name' not found on project $pn; available: $available"
}
