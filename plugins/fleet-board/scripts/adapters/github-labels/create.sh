#!/usr/bin/env bash
set -uo pipefail
. "$FLEET_SCRIPTS/board-lib.sh"

# Save title and body file before shifting
TITLE="$1"
BODY_FILE="$2"

# Collect labels starting with backlog state label
labels=()
labels+=("$(fb_state_name backlog)")

# Add any extra --label arguments
shift 2
while [ $# -gt 0 ]; do
  if [ "$1" = "--label" ]; then
    shift
    labels+=("$1")
    shift
  else
    shift
  fi
done

# Build gh command with label flags as array
args=()
for label in "${labels[@]}"; do
  args+=(--label "$label")
done

# Create the issue and extract number from URL
URL="$(gh issue create --repo "$FLEET_REPO" --title "$TITLE" --body-file "$BODY_FILE" "${args[@]}")" || fb_die 1 "failed to create issue"

# Output JSON
jq -nc --arg u "$URL" '{number: ($u | split("/") | last | tonumber), url: $u}'
