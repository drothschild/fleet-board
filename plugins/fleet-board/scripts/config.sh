#!/usr/bin/env bash
# config.sh - Configuration reader for fleet-board
#
# Reads and validates .fleet-board.yml, merges with defaults, and outputs configuration.
# Finds the config file in this order:
#   1. $FLEET_BOARD_CONFIG (if set)
#   2. <git-root>/.fleet-board.yml (where git-root is from git rev-parse --show-toplevel)
#   3. <main-worktree-root>/.fleet-board.yml (for linked worktrees)
# If DIR is not in a git repo, uses DIR as the root.
#
# Usage: config.sh [--dir DIR] [--check] [KEY]
#
# Exit codes:
#   0 - successful read/validation
#   2 - usage error (bad flag or KEY lookup error)
#   3 - config file not found
#   4 - YAML parse error (outside the supported subset)
#   5 - validation error (invalid values)

set -uo pipefail
# With CDPATH exported, a relative cd can land in a CDPATH directory and echo
# its path, which $(cd ... && pwd) would capture as a second line.
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/board-lib.sh" # fb_git_common_dir only; config.sh never calls fb_load_config

# Parse flags
DIR="${PWD}"
CHECK=0
KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      if [ $# -lt 2 ]; then echo "usage: config.sh [--dir DIR] [--check] [KEY]" >&2; exit 2; fi
      DIR="$2"
      shift 2
      ;;
    --check)
      CHECK=1
      shift
      ;;
    -*)
      echo "usage: config.sh [--dir DIR] [--check] [KEY]" >&2
      exit 2
      ;;
    *)
      KEY="$1"
      shift
      ;;
  esac
done

# Resolve FILE
FILE=""
SEARCH_PATH=""

if [ -n "${FLEET_BOARD_CONFIG:-}" ]; then
  FILE="$FLEET_BOARD_CONFIG"
  SEARCH_PATH="$FLEET_BOARD_CONFIG"
else
  # Try to find the git root first
  TOPLEVEL="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL=""

  if [ -z "$TOPLEVEL" ]; then
    # Not in a git repo - use DIR as toplevel
    TOPLEVEL="$DIR"
  fi

  if [ -f "$TOPLEVEL/.fleet-board.yml" ]; then
    FILE="$TOPLEVEL/.fleet-board.yml"
  else
    # Try main worktree root
    COMMON_DIR="$(fb_git_common_dir "$TOPLEVEL")" || COMMON_DIR=""
    if [ -n "$COMMON_DIR" ]; then
      MAIN_ROOT="$(dirname "$COMMON_DIR")"
      if [ -f "$MAIN_ROOT/.fleet-board.yml" ]; then
        FILE="$MAIN_ROOT/.fleet-board.yml"
      fi
    fi
    SEARCH_PATH="$TOPLEVEL/.fleet-board.yml"
  fi
fi

# Check if file exists
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "config.sh: no .fleet-board.yml at $SEARCH_PATH" >&2
  exit 3
fi

# Parse YAML to JSON
PARSED="$(awk -f "$HERE/yaml-subset.awk" "$FILE")" || exit 4

# Validate JSON
if ! echo "$PARSED" | jq -e . >/dev/null 2>&1; then
  echo "config.sh: line 0: parser produced invalid JSON" >&2
  exit 4
fi

# Merge with defaults
MERGED="$(jq -c -n --slurpfile d "$HERE/config-defaults.json" '$d[0] * input' <(echo "$PARSED"))" || {
  echo "config.sh: invalid config: failed to merge with defaults" >&2
  exit 5
}

# Validate config
VALIDATION_SCRIPT='
  def errors:
    [
      (("board", "commands", "worktrees", "merge", "review", "models", "limits", "headless") as $s
        | if (.[$s] | type) != "object" then "\($s) must be an object" else empty end),
      (("test_paths", "human_qa_paths") as $s
        | if (.[$s] | type) != "array" then "\($s) must be a list" else empty end),
      (if (.board | type) == "object" then
        (if (.board.states | type) != "object" then "board.states must be a map" else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.repo | type) != "string" or (.board.repo | test("^[^/ ]+/[^/ ]+$") | not) then "board.repo must match ^[^/ ]+/[^/ ]+$" else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.backend | type) != "string" or (.board.backend as $b | ($b == "github-labels" or $b == "github-projects") | not) then "board.backend must be github-labels or github-projects" else empty end)
      else empty end),
      (if (.board | type) == "object" and .board.backend == "github-projects" then
        (if (.board.project_number | type) != "number" then "github-projects requires numeric board.project_number" else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.project_owner | type) as $t | $t != "null" and $t != "string" then "board.project_owner must be null or a string" else empty end)
      else empty end),
      (if (.board | type) == "object" and (.board.states | type) == "object" then
        (.board.states | to_entries | map(if (.key | test("^(backlog|ready|in_progress|in_review|human_qa|blocked|done|wont_do)$") | not) then "board.states key \(.key) is not canonical" else empty end)[])
      else empty end),
      (if (.merge | type) == "object" then
        (if (.merge.policy | type) != "string" or (.merge.policy as $p | ($p == "human" or $p == "auto") | not) then "merge.policy must be human or auto" else empty end)
      else empty end),
      (if (.review | type) == "object" then
        (if (.review.max_rounds | type) != "number" or (.review.max_rounds | floor) != .review.max_rounds or .review.max_rounds <= 0 then "review.max_rounds must be a positive integer" else empty end)
      else empty end),
      (if (.review | type) == "object" then
        (if (.review.mutation | type) != "boolean" then "review.mutation must be boolean" else empty end)
      else empty end),
      (if (.review | type) == "object" then
        (if (.review.verify_claim | type) != "boolean" then "review.verify_claim must be boolean" else empty end)
      else empty end),
      (if (.models | type) == "object" then
        (if (.models.escalate_after_rounds | type) != "number" or (.models.escalate_after_rounds | floor) != .models.escalate_after_rounds or .models.escalate_after_rounds <= 0 then "models.escalate_after_rounds must be a positive integer" else empty end)
      else empty end),
      (if (.worktrees | type) == "object" then
        (if (.worktrees.mutate_on_copy | type) != "boolean" then "worktrees.mutate_on_copy must be boolean" else empty end)
      else empty end),
      (if (.worktrees | type) == "object" then
        (if (.worktrees.dir | type) != "string" or .worktrees.dir == "" or (.worktrees.dir | startswith("/")) then "worktrees.dir must be a non-empty relative path" else empty end)
      else empty end),
      (if (.models | type) == "object" then
        (("manager", "implementor", "reviewer", "fixer") as $r
          | if (.models[$r] | type) != "string" or .models[$r] == "" then "models.\($r) must be a non-empty string" else empty end)
      else empty end),
      (if (.limits | type) == "object" then
        (if (.limits.concurrency | type) != "number" or (.limits.concurrency | floor) != .limits.concurrency or .limits.concurrency <= 0 then "limits.concurrency must be a positive integer" else empty end)
      else empty end)
    ] | map(select(. != null))
  ;
  errors | .[]
'

VALIDATION_ERRORS="$(echo "$MERGED" | jq -r "$VALIDATION_SCRIPT" 2>&1)" || {
  echo "config.sh: invalid config: validation script failed" >&2
  exit 5
}

if [ -n "$VALIDATION_ERRORS" ]; then
  while IFS= read -r line; do
    echo "config.sh: invalid config: $line" >&2
  done <<< "$VALIDATION_ERRORS"
  exit 5
fi

# Output
if [ "$CHECK" = "1" ]; then
  exit 0
fi

if [ -z "$KEY" ]; then
  echo "$MERGED"
else
  # Parse KEY into jq path
  PATHJSON="$(jq -Rc 'split(".")' <<<"$KEY")" || {
    echo "config.sh: usage error: invalid key format" >&2
    exit 2
  }
  echo "$MERGED" | jq -r --argjson p "$PATHJSON" 'getpath($p) | if type == "object" or type == "array" then tojson elif . == null then empty else . end' 2>/dev/null || {
    echo "config.sh: usage error: key lookup failed" >&2
    exit 2
  }
fi
