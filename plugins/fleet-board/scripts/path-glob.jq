# path-glob.jq - repo-relative path globs, shared by tick-plan.sh and update-branch.sh.
# scripts/supervisor/scopes.py (glob_regex, drop_ignored) is the Python twin: it
# builds the same regex string, and scheduler_cases.py checks the two agree on
# fixtures/glob-cases.json. Change both together.
#
# A glob is matched one path segment at a time: `*` and `?` never cross `/`,
# `[...]` / `[!...]` is a character class inside one segment, and a `**` segment
# matches zero or more whole segments. Case-sensitive. Paths and globs are
# cleaned first: `\` becomes `/`, leading `./` and trailing `/` are dropped.

def pg_clean: gsub("\\\\"; "/") | sub("^(\\./)+"; "") | sub("/+$"; "");

# One segment (no `/`) to a regex fragment
def pg_seg:
  split("") as $c | ($c | length) as $n
  | def go($i):
      if $i >= $n then ""
      elif $c[$i] == "*" then "[^/]*" + go($i + 1)
      elif $c[$i] == "?" then "[^/]" + go($i + 1)
      elif $c[$i] == "[" then
        (if $i + 1 < $n and $c[$i + 1] == "!" then $i + 2 else $i + 1 end) as $s
        | (if $s < $n and $c[$s] == "]" then $s + 1 else $s end) as $s2
        | (first(range($s2; $n) | select($c[.] == "]")) // null) as $e
        | if $e == null then "\\[" + go($i + 1)
          else ($c[$s:$e] | map(if . == "\\" or . == "[" or . == "]" or . == "^" then "\\" + . else . end) | join("")) as $body
            | "[" + (if $s == $i + 2 then "^/" else "" end) + $body + "]" + go($e + 1)
          end
      elif ("\\.^$*+?()[]{}|" | index($c[$i])) != null then "\\" + $c[$i] + go($i + 1)
      else $c[$i] + go($i + 1) end;
    go(0);

# A glob to an unanchored regex (match it whole: \A(?:...)\z)
def pg_regex:
  (pg_clean | split("/")) as $segs
  | reduce range(0; $segs | length) as $k ({out: "", sep: false};
      if $segs[$k] == "**" then
        if $k == ($segs | length) - 1 and (.sep | not) then .out += ".*"
        elif .sep then .out += "(?:/[^/]+)*"
        else .out += "(?:[^/]+/)*" end
      else (if .sep then .out += "/" else . end) | .out += ($segs[$k] | pg_seg) | .sep = true end)
  | .out;

# input: a path; true when one of the globs matches it whole
def pg_match($globs):
  pg_clean as $p | any($globs[]; . as $g | $p | test("\\A(?:" + ($g | pg_regex) + ")\\z"));

# input: a list of paths; drops those a glob matches. A list every path of which
# matches is returned unchanged (an empty scope would mean the whole repository).
def pg_drop($globs):
  if ($globs | length) == 0 or length == 0 then .
  else ["\\A(?:" + ($globs[] | pg_regex) + ")\\z"] as $rx
    | [.[] | select((type != "string") or ((pg_clean) as $p | any($rx[]; . as $r | $p | test($r))) | not)] as $kept
    | if ($kept | length) == 0 then . else $kept end
  end;
