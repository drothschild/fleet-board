# merge.ignore_checks, the one shared rule. tick-plan.sh (its `green`) and hooks/gate.sh
# (check_pr) prepend this file to their jq programs, so the planner and the gate cannot disagree.
#
# A red check (FAILURE, ERROR, CANCELLED, TIMED_OUT, ACTION_REQUIRED) counts as green when its name
# (a check run's .name, a status context's .context) matches the glob of an entry whose `until`
# (YYYY-MM-DD) is $today or later. $today is a UTC YYYY-MM-DD; anything else expires every entry.
# A pending check ("", PENDING, IN_PROGRESS, QUEUED, ...) is never red. It counts as green only
# when it matches an unexpired entry that also says `pending: true` (opt in: merge without
# waiting for that check to finish). Without `pending: true` an entry never covers a pending check.
# Globs are shell-style and case-sensitive: * is any run of characters, ? is one character.

def ic_glob_re:
  gsub("(?<c>[\\\\^$.|+(){}\\[\\]])"; "\\" + .c) | gsub("\\*"; ".*") | gsub("\\?"; ".");

def ic_name: (.name // .context // "") | if type == "string" then . else "" end;

def ic_state: (.conclusion // .state);

def ic_red:
  ic_state | . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED";

def ic_valid_day: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z");

def ic_active($ignores; $today):
  if ($today | ic_valid_day) | not then []
  else [($ignores // [])[] | select(type == "object" and (.name | type) == "string"
        and (.until | ic_valid_day) and .until >= $today)] end;

# the active entry matching the check, or null
def ic_match($ignores; $today):
  ic_name as $n
  | first(ic_active($ignores; $today)[] | . as $e | select($n | test("\\A" + ($e.name | ic_glob_re) + "\\z"; "s"))) // null;

def ic_passed: ic_state | . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED";

# neither passed nor red: queued, in progress, or no conclusion yet
def ic_pending: (ic_passed or ic_red) | not;

# the active `pending: true` entry matching the check, or null
def ic_match_pending($ignores; $today):
  ic_name as $n
  | first(ic_active($ignores; $today)[] | select(.pending == true) | . as $e
          | select($n | test("\\A" + ($e.name | ic_glob_re) + "\\z"; "s"))) // null;

def ic_ok($ignores; $today):
  ic_passed
    or (ic_red and ic_match($ignores; $today) != null)
    or (ic_pending and ic_match_pending($ignores; $today) != null);

# the whole statusCheckRollup: an array in which every check is green or ignored
def ic_green($ignores; $today):
  type == "array" and all(.[]; ic_ok($ignores; $today));

# the red and pending checks the rollup went past, as {name, reason, until}
def ic_used($ignores; $today):
  if type != "array" then []
  else [.[] | . as $chk
        | (if ic_red then ic_match($ignores; $today)
           elif ic_pending then ic_match_pending($ignores; $today)
           else null end) as $e
        | select($e != null)
        | {name: ($chk | ic_name), reason: $e.reason, until: $e.until}] end;

# a warning per entry whose date has passed
def ic_expired($ignores; $today):
  [($ignores // [])[] | select(type == "object" and (.until | ic_valid_day) and .until < $today)
   | "merge.ignore_checks entry \(.name) expired \(.until)"];
