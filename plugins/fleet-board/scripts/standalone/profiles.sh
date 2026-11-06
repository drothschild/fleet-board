#!/usr/bin/env bash
# Resolve standalone execution profiles without launching a worker.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
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
    elif $s.provider != null then {profile:null, runner:"diff-chat", provider:$s.provider, model:$s.model, escalated:false, source:"legacy-provider"}
    elif $s.agent != null then error("stage " + $stage + " uses plugin agent " + $s.agent + "; map it with review.stages[].profile")
    else from_profile(.execution.roles.reviewer; false) end
  else
    (.execution.escalation != null and ($role == "implementor" or $role == "fixer") and $round >= (.execution.escalation.after_round // 0)) as $escalated |
    from_profile((if $escalated then .execution.escalation.profile else .execution.roles[$role] end); $escalated)
  end
' <<<"$config"
