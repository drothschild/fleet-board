#!/usr/bin/env bash
# Resolve standalone execution profiles without launching a worker.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ${1:-} == preflight ]]; then
  [[ $# == 1 ]] || { echo 'profiles: preflight accepts no options' >&2; exit 2; }
  config=$(bash "$SCRIPTS/config.sh") || exit 1
  docker_checked=0
  check_profile() {
    local result="$1" purpose="$2" runner provider key
    runner=$(jq -r '.runner' <<<"$result") || return 1
    provider=$(jq -r '.provider' <<<"$result") || return 1
    if [[ $purpose != reviewer && $runner == diff-chat ]]; then
      echo "profiles: $purpose requires a tool-capable runner" >&2; return 1
    fi
    case "$runner" in
      codex) command -v codex >/dev/null || { echo 'profiles: codex executable unavailable' >&2; return 1; }; command -v docker >/dev/null || { echo 'profiles: docker executable unavailable' >&2; return 1; } ;;
      tool-chat) command -v docker >/dev/null || { echo 'profiles: docker executable unavailable' >&2; return 1; } ;;
      diff-chat) command -v curl >/dev/null || { echo 'profiles: curl executable unavailable' >&2; return 1; } ;;
      *) echo "profiles: unsupported runner $runner" >&2; return 1 ;;
    esac
    if [[ $runner != diff-chat && $docker_checked == 0 ]]; then
      if [[ $(docker info --format '{{.OSType}}' 2>/dev/null) != linux ]]; then
        echo 'profiles: a running Linux Docker engine is required' >&2; return 1
      fi
      docker_checked=1
    fi
    key=$(jq -r --arg p "$provider" '.providers[$p].api_key_env // empty' <<<"$config") || return 1
    if [[ -n $key ]] && ! printenv "$key" | grep -q .; then
      echo "profiles: missing credential environment variable $key" >&2; return 1
    fi
  }
  for role in implementor fixer reviewer; do
    result=$(bash "$0" resolve --role "$role" --round 1) || exit 1
    check_profile "$result" "$role" || exit 1
  done
  escalation=$(jq -r '.execution.escalation.after_round // empty' <<<"$config") || exit 1
  if [[ -n $escalation ]]; then
    result=$(bash "$0" resolve --role implementor --round "$escalation") || exit 1
    check_profile "$result" implementor || exit 1
  fi
  while IFS= read -r stage; do
    result=$(bash "$0" resolve --stage "$stage" --round 1) || exit 1
    check_profile "$result" reviewer || exit 1
  done < <(jq -r '.review.stages[].name' <<<"$config")
  exit 0
fi
[[ ${1:-} == resolve ]] || { echo 'profiles: expected resolve' >&2; exit 2; }
shift
role= stage= round=
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { echo 'profiles: missing option value' >&2; exit 2; }
  case "$1" in
    --role) [[ -z $role ]] || exit 2; role=$2 ;;
    --stage) [[ -z $stage ]] || exit 2; stage=$2 ;;
    --round) [[ -z $round ]] || exit 2; round=$2 ;;
    *) echo "profiles: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done
[[ $round =~ ^[1-9][0-9]*$ ]] || { echo 'profiles: round must be a positive integer' >&2; exit 2; }
[[ ( -n $role && -z $stage ) || ( -z $role && -n $stage ) ]] || { echo 'profiles: specify exactly one role or stage' >&2; exit 2; }
if [[ -n $role && $role != implementor && $role != fixer && $role != reviewer ]]; then
  echo 'profiles: unknown role' >&2; exit 2
fi
config=$(bash "$SCRIPTS/config.sh")
jq -e --arg role "$role" --arg stage "$stage" --argjson round "$round" '
  def from_profile($name; $escalated):
    if ($name | type) != "string" or (.execution.profiles | has($name) | not) then
      error("no execution profile configured for " + (if $stage != "" then "stage " + $stage else "role " + $role end))
    else .execution.profiles[$name] + {profile:$name, escalated:$escalated} end;
  if $stage != "" then
    ([.review.stages[] | select(.name == $stage)] | first) as $s |
    if $s == null then error("unknown review stage " + $stage)
    elif $s.profile != null then from_profile($s.profile; false)
    elif $s.provider != null then $s + {profile:null, runner:"diff-chat", escalated:false, source:"legacy-provider"}
    elif $s.agent != null then error("stage " + $stage + " uses plugin agent " + $s.agent + "; map it with review.stages[].profile")
    else from_profile(.execution.roles.reviewer; false) end
  else
    (.execution.escalation != null and ($role == "implementor" or $role == "fixer") and $round >= (.execution.escalation.after_round // 0)) as $escalated |
    from_profile((if $escalated then .execution.escalation.profile else .execution.roles[$role] end); $escalated)
  end
' <<<"$config"
