# merge.ignore_checks, the one shared rule. tick-plan.sh (its `green`) and hooks/gate.sh
# (check_pr) prepend this file to their jq programs, so the planner and the gate cannot disagree.
#
# Every check falls in exactly one of four explicit sets; nothing outside the first three is ever green.
#   passed:  a CheckRun whose conclusion is SUCCESS, NEUTRAL or SKIPPED; a StatusContext in state SUCCESS.
#   red:     a CheckRun whose conclusion is FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED,
#            STARTUP_FAILURE or STALE; a StatusContext in state FAILURE or ERROR.
#   pending: a CheckRun whose status is QUEUED, IN_PROGRESS, WAITING, PENDING or REQUESTED with a
#            conclusion of "" or null; a StatusContext in state PENDING or EXPECTED.
#   other:   anything else (COMPLETED with no conclusion, an unknown value, an unknown kind): never green.
# A CheckRun and a StatusContext are told apart by __typename, or, without one, by their fields.
#
# A red check counts as green when its name (a check run's .name, a status context's .context)
# matches the glob of an entry whose `until` (YYYY-MM-DD) is $today or later. A pending check counts
# as green only when it matches such an entry that also says `pending: true` (opt in: merge without
# waiting for that check to finish); a `pending: true` entry covers red checks of that name as well.
# A check with no name is never ignored. $today is a UTC YYYY-MM-DD; anything else expires every entry.
# Globs are shell-style and case-sensitive: * is any run of characters, ? is one character.

def ic_glob_re:
  gsub("(?<c>[\\\\^$.|+(){}\\[\\]])"; "\\" + .c) | gsub("\\*"; ".*") | gsub("\\?"; ".");

def ic_name: (.name // .context // "") | if type == "string" then . else "" end;

def ic_in($xs): . as $v | any($xs[]; . == $v);

# "CheckRun", "StatusContext", or null for anything else
def ic_kind:
  if type != "object" then null
  elif has("__typename") then (.__typename | if . == "CheckRun" or . == "StatusContext" then . else null end)
  elif has("conclusion") or has("status") then "CheckRun"
  elif has("state") then "StatusContext"
  else null end;

def ic_passed:
  ic_kind as $k
  | if $k == "CheckRun" then .conclusion | ic_in(["SUCCESS", "NEUTRAL", "SKIPPED"])
    elif $k == "StatusContext" then .state == "SUCCESS"
    else false end;

def ic_red:
  ic_kind as $k
  | if $k == "CheckRun" then .conclusion
         | ic_in(["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"])
    elif $k == "StatusContext" then .state | ic_in(["FAILURE", "ERROR"])
    else false end;

def ic_pending:
  ic_kind as $k
  | if $k == "CheckRun" then (.status | ic_in(["QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"]))
         and (.conclusion | . == "" or . == null)
    elif $k == "StatusContext" then .state | ic_in(["PENDING", "EXPECTED"])
    else false end;

def ic_valid_day: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z");

def ic_active($ignores; $today):
  if ($today | ic_valid_day) | not then []
  else [($ignores // [])[] | select(type == "object" and (.name | type) == "string"
        and (.until | ic_valid_day) and .until >= $today)] end;

# the first active entry matching the check's name (only `pending: true` entries when $pending), or
# null; a check with no name matches nothing
def ic_find($ignores; $today; $pending):
  ic_name as $n
  | if $n == "" then null
    else first(ic_active($ignores; $today)[] | select(($pending | not) or .pending == true) | . as $e
               | select($n | test("\\A" + ($e.name | ic_glob_re) + "\\z"; "s"))) // null end;

# the active entry covering the check, or null: any matching entry for a red check, a matching
# `pending: true` entry for a pending check, nothing for a passed or unknown check
def ic_cover($ignores; $today):
  if ic_red then ic_find($ignores; $today; false)
  elif ic_pending then ic_find($ignores; $today; true)
  else null end;

def ic_ok($ignores; $today):
  ic_passed or ic_cover($ignores; $today) != null;

# the whole statusCheckRollup: an array in which every check is green or ignored
def ic_green($ignores; $today):
  type == "array" and all(.[]; ic_ok($ignores; $today));

# the red and pending checks the rollup went past, as {name, reason, until, state}
def ic_used($ignores; $today):
  if type != "array" then []
  else [.[] | . as $chk | ic_cover($ignores; $today) as $e | select($e != null)
        | {name: ($chk | ic_name), reason: $e.reason, until: $e.until,
           state: (if $chk | ic_red then "red" else "pending" end)}] end;

# a warning per entry whose date has passed
def ic_expired($ignores; $today):
  [($ignores // [])[] | select(type == "object" and (.until | ic_valid_day) and .until < $today)
   | "merge.ignore_checks entry \(.name) expired \(.until)"];
