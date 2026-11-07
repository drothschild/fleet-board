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
#   4 - YAML parse error, or YAML outside the supported subset (see yaml.jq)
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

# Parse YAML to JSON with the bundled parser (scripts/yaml.jq), so jq is the
# only tool needed. It reads the subset a config uses and names the line of
# anything outside it.
PARSE_ERR="$(mktemp)" || exit 4
PARSED="$(jq -Rsc -f "$HERE/yaml.jq" "$FILE" 2>"$PARSE_ERR")" || {
  echo "config.sh: $FILE: $(sed -e 's/^jq: error (at [^)]*): //' "$PARSE_ERR" | head -3 | tr '\n' ' ' | sed -e 's/ $//')" >&2
  rm -f "$PARSE_ERR"
  exit 4
}
rm -f "$PARSE_ERR"

# An empty file or a comment-only file is an empty config; any other non-map top level is an error
case "$(printf '%s' "$PARSED" | jq -r 'type')" in
  null) PARSED='{}' ;;
  object) ;;
  *) echo "config.sh: $FILE: the top level must be a map" >&2; exit 4 ;;
esac

# Merge with defaults
MERGED="$(jq -c -n --slurpfile d "$HERE/config-defaults.json" '$d[0] * input' <(echo "$PARSED"))" || {
  echo "config.sh: invalid config: failed to merge with defaults" >&2
  exit 5
}

# Fill each review stage's defaults so no reader re-derives them. A stage that is
# not an object is left as it is, for validation to name.
STAGE_DEFAULTS='
  . as $root
  | if (.review | type) == "object" and (.review.stages | type) == "array" then
      .review.stages |= map(
        if type == "object" then
          . as $s | {
            name: $s.name,
            agent: ($s.agent // null),
            provider: ($s.provider // null),
            model: (if $s | has("model") then $s.model
                    elif ($s.provider // null) != null or ($root.models | objects | .reviewer | type) == "object" then null
                    else $root.models.reviewer end),
            paths: (if $s | has("paths") then $s.paths else [] end),
            label: (if $s | has("label") then $s.label
                    elif ($s.name | type) == "string" then "needs-\($s.name)-review"
                    else null end),
            advisory: (if $s | has("advisory") then $s.advisory else false end),
            max_rounds: (if $s | has("max_rounds") then $s.max_rounds else $root.review.max_rounds end),
            brief: (if $s | has("brief") then $s.brief else null end),
            price: ($s.price // null),
            timeout: ($s.timeout // 600),
            max_output_tokens: ($s.max_output_tokens // 16000),
            max_diff_bytes: ($s.max_diff_bytes // 400000)
          }
        else . end)
    else . end
'
MERGED="$(jq -c "$STAGE_DEFAULTS" <<<"$MERGED")" || {
  echo "config.sh: invalid config: failed to fill review stage defaults" >&2
  exit 5
}

# Fill the providers map: an entry for every provider a stage names (a built-in
# preset) and every provider the file defines, the preset under the file's keys.
# A non-object entry is left as it is, for validation to name.
PROVIDER_DEFAULTS='
  def stage_providers:
    if (.review | type) == "object" and (.review.stages | type) == "array"
    then [.review.stages[] | select(type == "object") | .provider | select(type == "string")]
    else [] end;
  if (.models | type) == "object" and (.models.reviewer | type) == "object" then
    .models.reviewer |= (if has("timeout") then . else .timeout = 1500 end)
  else . end
  | . as $root
  | $presets[0] as $p
  | if (.providers | type) == "object" then
      .providers = (
        ([($root.providers | keys[]), ($root | (stage_providers[], (.models | objects | .reviewer | objects | .provider | strings)) | . as $sp | select($p | has($sp)))] | unique)
        | map(. as $n | ($root.providers[$n]) as $u
            | {key: $n,
               value: (if $u != null and ($u | type) != "object" then $u
                       else {base_url: null, api_key_env: null, max_tokens_param: "max_completion_tokens"}
                            * ($p[$n] // {}) * ($u // {}) end)})
        | from_entries)
    else . end
'
MERGED="$(jq -c --slurpfile presets "$HERE/providers/presets.json" "$PROVIDER_DEFAULTS" <<<"$MERGED")" || {
  echo "config.sh: invalid config: failed to fill providers" >&2
  exit 5
}

# Validate config
VALIDATION_SCRIPT='
  def stage_providers:
    if (.review | type) == "object" and (.review.stages | type) == "array"
    then [.review.stages[] | select(type == "object") | .provider | select(type == "string")]
    else [] end;
  def stage_names:
    if (.review | type) == "object" and (.review.stages | type) == "array"
    then [.review.stages[] | select(type == "object") | .name | select(type == "string")]
    else [] end;
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
        (if (.board.backend | type) != "string" or (.board.backend as $b | ($b == "github-labels" or $b == "github-projects" or $b == "local") | not) then "board.backend must be github-labels, github-projects or local" else empty end)
      else empty end),
      (if (.board | type) == "object" and .board.backend == "github-projects" then
        (if (.board.project_number | type) != "number" then "github-projects requires numeric board.project_number" else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.project_owner | type) as $t | $t != "null" and $t != "string" then "board.project_owner must be null or a string" else empty end)
      else empty end),
      (if (.board | type) == "object" and (.board.states | type) == "object" then
        (stage_names as $names
          | .board.states | to_entries | map(
              if (.key | test("^(backlog|ready|in_progress|in_review|human_qa|blocked|done|wont_do)$")) then empty
              elif (.key | startswith("review_")) then (.key | ltrimstr("review_")) as $n |
                (if ($names | index($n)) != null then empty else "board.states key \(.key) names no stage" end)
              else "board.states key \(.key) is not canonical" end)[])
      else empty end),
      (if (.review | type) == "object" then
        (if (.review.stages | type) != "array" then "review.stages must be a list"
         else
          (.review.stages as $stages | .providers as $provs | (.models | if type == "object" then .reviewer | type else "null" end) as $reviewer_type | $stages | to_entries[] | . as $e | $e.key as $i | $e.value as $s
            | if ($s | type) != "object" then "review.stages[\($i)] must be an object"
              else
                (if ($s.name | type) != "string" or ($s.name | test("^[a-z][a-z0-9_]*$") | not) then "review.stages[\($i)].name must match ^[a-z][a-z0-9_]*$"
                 elif (($stages[0:$i] | map(select(type == "object") | .name)) | index($s.name)) != null then "review.stages[\($i)].name \($s.name) is not unique"
                 else empty end),
                (if ($s.agent == null) == ($s.provider == null) then "review.stages[\($i)] must set exactly one of agent and provider" else empty end),
                (if $s.provider == null and $s.agent != null and (($s.agent | type) != "string" or ($s.agent | test("^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$") | not)) then "review.stages[\($i)].agent must match ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$" else empty end),
                (if $s.provider != null then
                  (if ($s.provider | type) != "string" or ($s.provider | test("^[a-z][a-z0-9_-]*$") | not) then "review.stages[\($i)].provider must match ^[a-z][a-z0-9_-]*$"
                   elif (($presets[0] | has($s.provider)) or (($provs | type) == "object" and ($provs | has($s.provider)))) | not then "review.stages[\($i)].provider \($s.provider) names no provider"
                   else empty end)
                else empty end),
                (if $s.provider != null and $s.model == null then "review.stages[\($i)].model must be set when provider is set"
                 elif $s.provider == null and $s.model == null and $reviewer_type == "object" then "review.stages[\($i)].model must be set when models.reviewer is a provider"
                 elif ($s.model | type) != "string" or $s.model == "" then "review.stages[\($i)].model must be a non-empty string" else empty end),
                (if $s.provider != null then
                  (if $s.price == null then "review.stages[\($i)].price is required when provider is set"
                   else
                    (("input", "output") as $k | ($s.price | if type == "object" then .[$k] else null end) as $v
                      | if ($v | type) != "number" or $v < 0 then "review.stages[\($i)].price.\($k) must be a non-negative number" else empty end)
                   end)
                else empty end),
                (("timeout", "max_output_tokens", "max_diff_bytes") as $k
                  | if ($s[$k] | type) != "number" or ($s[$k] | floor) != $s[$k] or $s[$k] <= 0 then "review.stages[\($i)].\($k) must be a positive integer" else empty end),
                (if ($s.paths | type) != "array" or ($s.paths | map(type != "string" or . == "") | any) then "review.stages[\($i)].paths must be a list of non-empty strings" else empty end),
                (if ($s.label | type) != "string" or $s.label == "" or $s.label == "needs-human-qa" or $s.label == "needs-manual-step"
                      or (($stages[0:$i] | map(select(type == "object") | .label)) | index($s.label)) != null
                 then "review.stages[\($i)].label must be a non-empty string" else empty end),
                (if ($s.advisory | type) != "boolean" then "review.stages[\($i)].advisory must be boolean" else empty end),
                (if ($s.max_rounds | type) != "number" or ($s.max_rounds | floor) != $s.max_rounds or $s.max_rounds <= 0 then "review.stages[\($i)].max_rounds must be a positive integer" else empty end),
                (if ($s.brief | type) != "null" and ($s.brief | type) != "string" then "review.stages[\($i)].brief must be a string" else empty end)
              end)
         end)
      else empty end),
      (if (.providers | type) != "object" then "providers must be an object"
       else
        (.providers | to_entries[] | . as $e | $e.key as $n | $e.value as $v
          | if ($n | test("^[a-z][a-z0-9_-]*$") | not) then "providers.\($n) name must match ^[a-z][a-z0-9_-]*$"
            elif ($v | type) != "object" then "providers.\($n) must be an object"
            else
              (("api_key", "key", "token", "secret") as $k
                | if $v | has($k) then "providers.\($n).\($k) is not allowed; name an environment variable in api_key_env" else empty end),
              (if $v | has("review_command") then
                (if ($v.review_command | type) != "string" or ($v.review_command | contains("{dir}") | not)
                 then "providers.\($n).review_command must contain {dir}" else empty end),
                (("--dangerously-bypass-approvals-and-sandbox", "danger-full-access", "--dangerously-bypass-hook-trust") as $flag
                 | if ($v.review_command | type) == "string" and ($v.review_command | contains($flag))
                   then "providers.\($n).review_command must not contain \($flag)" else empty end),
                (if $v.base_url != null then "providers.\($n) sets both review_command and base_url" else empty end)
              else empty end),
              (if $v | has("command") then
                (if ($v.command | type) != "string" or $v.command == "" then "providers.\($n).command must be a non-empty string" else empty end),
                (if $v.base_url != null then "providers.\($n) sets both command and base_url" else empty end),
                (if $v.api_key_env != null then "providers.\($n).api_key_env must be null when command is set" else empty end)
              elif ($v | has("review_command")) | not then
                # The authority (after the scheme, up to the first / ? # or end)
                # must hold no userinfo ("localhost:@evil.example" is a request to
                # evil.example). A plain-http host must itself be loopback, with
                # an optional numeric port.
                ((($v.base_url | type) == "string" and ($v.base_url | test("^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@"))) as $userinfo
                  | (($v.base_url | type) == "string" and ($userinfo | not)
                     and ($v.base_url | test("^(https://[^/?#]|http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?(/|$))"))) as $url_ok
                  | (if $userinfo then "providers.\($n).base_url must not contain userinfo"
                     elif $url_ok | not then "providers.\($n).base_url must start with https:// or a loopback http:// address" else empty end),
                    (if $v.api_key_env == null then
                      (if ($url_ok and ($v.base_url | startswith("http://"))) | not then "providers.\($n).api_key_env may be null only for a loopback base_url" else empty end)
                     elif ($v.api_key_env | type) != "string" or ($v.api_key_env | test("^[A-Z_][A-Z0-9_]*$") | not) then "providers.\($n).api_key_env must match ^[A-Z_][A-Z0-9_]*$"
                     else empty end)),
                (if $v.max_tokens_param != "max_tokens" and $v.max_tokens_param != "max_completion_tokens" then "providers.\($n).max_tokens_param must be max_tokens or max_completion_tokens" else empty end)
              else empty end)
            end)
       end),
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
      (if (.models | type) == "object" then
        (if (.models.escalation | type) != "null" and ((.models.escalation | type) != "string" or .models.escalation == "") then "models.escalation must be null or a non-empty string" else empty end)
      else empty end),
      (if (.followups | type) != "object" then "followups must be an object"
       elif (.followups.status | type) != "string" or (.followups.status as $s | ($s == "ready" or $s == "backlog") | not) then "followups.status must be ready or backlog" else empty end),
      (if (.after_merge | type) != "object" then "after_merge must be an object"
       elif (.after_merge.allow | type) != "array" or (.after_merge.allow | map(type != "string" or . == "") | any) then "after_merge.allow must be a list of non-empty strings"
       else empty end),
      (if (.worktrees | type) == "object" then
        (if (.worktrees.mutate_on_copy | type) != "boolean" then "worktrees.mutate_on_copy must be boolean" else empty end)
      else empty end),
      (if (.worktrees | type) == "object" then
        (if (.worktrees.dir | type) != "string" or .worktrees.dir == "" or (.worktrees.dir | startswith("/")) then "worktrees.dir must be a non-empty relative path" else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.dir | type) != "string" or .board.dir == "" or (.board.dir | startswith("/")) or (.board.dir | split("/") | index("..") != null) then "board.dir must be a non-empty relative path without .." else empty end)
      else empty end),
      (if (.board | type) == "object" then
        (if (.board.port | type) != "number" or (.board.port | floor) != .board.port or .board.port < 1024 or .board.port > 65535 then "board.port must be an integer between 1024 and 65535" else empty end)
      else empty end),
      (if (.models | type) == "object" then
        (("manager", "implementor", "fixer") as $r
          | if (.models[$r] | type) != "string" or .models[$r] == "" then "models.\($r) must be a non-empty string" else empty end),
        (.models.reviewer as $r
         | if ($r | type) == "object" then
             (if ($r.provider | type) != "string" or ((.providers | objects | has($r.provider)) // false | not)
              then "models.reviewer.provider \($r.provider) names no provider"
              elif (.providers[$r.provider].review_command | type) != "string"
              then "models.reviewer.provider \($r.provider) has no review_command" else empty end),
             (if ($r.model | type) != "string" or $r.model == "" then "models.reviewer.model must be a non-empty string" else empty end),
             (if ($r.price | type) != "object" or ([$r.price.input, $r.price.output] | any(type != "number" or . < 0))
              then "models.reviewer.price must have non-negative input and output" else empty end),
             (if ($r.timeout | type) != "number" or ($r.timeout | floor) != $r.timeout or $r.timeout < 1 or $r.timeout > 1500
              then "models.reviewer.timeout must be an integer from 1 to 1500" else empty end),
             (if (.models.escalation | type) != "string" or .models.escalation == ""
              then "models.escalation must be set when models.reviewer is a provider" else empty end)
           elif ($r | type) != "string" or $r == "" then "models.reviewer must be a non-empty string or an object"
           else empty end)
      else empty end),
      (if (.limits | type) == "object" then
        (if (.limits.concurrency | type) != "number" or (.limits.concurrency | floor) != .limits.concurrency or .limits.concurrency <= 0 then "limits.concurrency must be a positive integer" else empty end),
        (("rate_limit_max_wait", "rate_limit_margin", "min_tick_gap") as $k
          | if (.limits[$k] | type) != "number" or .limits[$k] < 0 then "limits.\($k) must be a non-negative number" else empty end)
      else empty end)
    ] | map(select(. != null))
  ;
  def warnings:
    if (.providers | type) == "object" then
      ((stage_providers + [(.models | objects | .reviewer | objects | .provider | strings)]) as $used | [.providers | keys[] | select(. as $n | $used | index($n) | not) | "warning: providers.\(.) is not used by any stage"])
    else [] end;
  (errors | .[]), (warnings | .[])
'

VALIDATION_ERRORS="$(echo "$MERGED" | jq -r --slurpfile presets "$HERE/providers/presets.json" "$VALIDATION_SCRIPT" 2>&1)" || {
  echo "config.sh: invalid config: validation script failed" >&2
  exit 5
}

# Lines starting "warning: " are warnings (exit stays 0); the rest are errors.
if [ -n "$VALIDATION_ERRORS" ]; then
  HAD_ERROR=0
  while IFS= read -r line; do
    case "$line" in
      "warning: "*) echo "config.sh: $line" >&2 ;;
      *) echo "config.sh: invalid config: $line" >&2; HAD_ERROR=1 ;;
    esac
  done <<< "$VALIDATION_ERRORS"
  [ "$HAD_ERROR" = "0" ] || exit 5
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
