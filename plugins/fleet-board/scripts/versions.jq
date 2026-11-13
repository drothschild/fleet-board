# versions.jq - semver order and "version" line edits, shared by tick-plan.sh and
# update-branch.sh (supervisor.version_files).

def sv_re: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$";
def sv_valid: type == "string" and test(sv_re);
def sv_parse:
  capture("^(?<x>[0-9]+)\\.(?<y>[0-9]+)\\.(?<z>[0-9]+)(-(?<p>.*))?$")
  | {core: [(.x, .y, .z) | tonumber], pre: .p};

# Semver 2.0.0 precedence: -1, 0 or 1. The core compares numerically; a release
# ranks above its prereleases; prerelease identifiers compare numerically when
# both are digits, digits rank below letters, and a longer list ranks higher.
def sv_cmp($a; $b):
  ($a | sv_parse) as $p | ($b | sv_parse) as $q
  | if $p.core != $q.core then (if $p.core > $q.core then 1 else -1 end)
    elif $p.pre == $q.pre then 0
    elif $p.pre == null then 1
    elif $q.pre == null then -1
    else ($p.pre | split(".")) as $xa | ($q.pre | split(".")) as $xb
      | (first(range(0; [($xa | length), ($xb | length)] | min) as $i
          | $xa[$i] as $u | $xb[$i] as $v
          | ($u | test("^[0-9]+$")) as $nu | ($v | test("^[0-9]+$")) as $nv
          | (if $nu and $nv then (($u | tonumber) as $m | ($v | tonumber) as $n
                                  | if $m == $n then 0 elif $m > $n then 1 else -1 end)
             elif $nu then -1 elif $nv then 1
             elif $u == $v then 0 elif $u > $v then 1 else -1 end)
          | select(. != 0)) // null) as $r
      | if $r != null then $r
        elif ($xa | length) > ($xb | length) then 1
        elif ($xa | length) < ($xb | length) then -1
        else 0 end
    end;

# The lowest version this file may move to over a base: a prerelease base gives
# its own core (already above it), a release base gives base + 1 patch.
def sv_above($base):
  ($base | sv_parse) as $b
  | if $b.pre != null then $b.core | map(tostring) | join(".")
    else "\($b.core[0]).\($b.core[1]).\($b.core[2] + 1)" end;

# One conflicted line: the higher side, unless that is not strictly above the base side
def sv_resolve($ours; $theirs):
  (if sv_cmp($ours; $theirs) >= 0 then $ours else $theirs end) as $v
  | if sv_cmp($v; $theirs) > 0 then $v else sv_above($theirs) end;

# A line that sets "version" to a string: that string, else null
def vline_val:
  (capture("^[ \\t]*\"version\"[ \\t]*:[ \\t]*\"(?<v>[^\"]*)\"[ \\t]*,?[ \\t\\r]*$") | .v) // null;
def vline_tmpl: sub("\"version\"(?<s>[ \\t]*:[ \\t]*)\"[^\"]*\""; "\"version\"\(.s)\"@\"");
def vline_set($v): sub("\"version\"(?<s>[ \\t]*:[ \\t]*)\"[^\"]*\""; "\"version\"\(.s)\"\($v)\"");

# input: a file with conflict markers. {text} with every hunk resolved line by line
# (each line from its own two sides, sv_resolve), or {why} when a hunk holds anything
# but "version" lines that match pairwise apart from the value. A diff3/zdiff3 base
# section must hold only "version" lines; its values are not used.
def vc_resolve:
  split("\n") as $lines
  | reduce $lines[] as $l ({st: 0, out: [], o: [], t: [], hunks: 0, why: null};
      if .why != null then .
      elif .st == 0 then
        if ($l | test("^<<<<<<<( |$)")) then .st = 1 | .o = [] | .t = []
        else .out += [$l] end
      elif .st == 1 then
        if ($l | test("^[|]{7}( |\r?$)")) then .st = 2
        elif ($l | test("^=======\r?$")) then .st = 3
        elif ($l | test("^<<<<<<<( |$)")) then .why = "nested conflict markers"
        else .o += [$l] end
      elif .st == 2 then
        if ($l | test("^=======\r?$")) then .st = 3
        elif ($l | vline_val) == null then .why = "a conflict hunk's base section has a line that is not a \"version\" line"
        else . end
      elif ($l | test("^>>>>>>>( |$)")) then
        if any((.o + .t)[]; vline_val == null)
          then .why = "a conflict hunk changes lines other than \"version\" lines"
        elif any((.o + .t)[]; vline_val | . != null and (sv_valid | not))
          then .why = "a version in a conflict hunk is not semver: \(first((.o + .t)[] | vline_val | select(. != null and (sv_valid | not))))"
        elif (.o | length) == 0 or (.o | length) != (.t | length)
             or any(range(0; .o | length) as $i | [.o[$i], .t[$i]] | map(vline_tmpl) | .[0] != .[1]; .)
          then .why = "the two sides of a conflict hunk differ in more than the version value"
        else . as $h
          | .out += [range(0; $h.o | length) as $i
                     | $h.o[$i] | vline_set(sv_resolve($h.o[$i] | vline_val; $h.t[$i] | vline_val))]
          | .st = 0 | .hunks += 1
        end
      else .t += [$l] end)
  | if .why != null then {why}
    elif .st != 0 then {why: "a conflict hunk is not closed"}
    elif .hunks == 0 then {why: "no conflict hunks"}
    else {text: (.out | join("\n"))} end;

# The paths of string "version" keys, in document order
def vr_paths: [paths(type == "string") | select(length > 0 and .[-1] == "version")];
def vr_get($p): try getpath($p) catch null;

# The string "version" key paths whose values differ between two JSON documents
# (one commit of the branch and its parent; either may be null)
def vr_diff_paths($a; $b):
  [($a | vr_paths[]), ($b | vr_paths[])] | unique
  | map(select(. as $p | ($a | vr_get($p)) != ($b | vr_get($p))));

# input: the head JSON. Of the version keys in $changed (the paths the branch's own
# commits changed, version-lib.sh vl_changes), those whose head value is not strictly
# above the base branch's ($base): [{path, from, to}] with to = sv_above(base). A key
# missing or not semver on either side is left alone.
def vr_raise($changed; $base):
  . as $head
  | [vr_paths[] as $p
     | select(any($changed[]; . == $p))
     | ($head | vr_get($p)) as $h | ($base | vr_get($p)) as $t
     | select(($h | sv_valid) and ($t | sv_valid) and sv_cmp($h; $t) <= 0)
     | {path: $p, from: $h, to: sv_above($t)}];

# input: the raw text of a JSON file; sets each change's version line. Each string
# "version" key must sit on a line of its own, in document order, or this fails.
def vr_apply($changes):
  . as $text | ($text | fromjson) as $j | ($j | vr_paths) as $ps
  | ($text | split("\n")) as $lines
  | [range(0; $lines | length) | select(($lines[.] | vline_val) != null)] as $idx
  | if ($idx | length) != ($ps | length)
       or any(range(0; $ps | length) as $k | ($lines[$idx[$k]] | vline_val) != ($j | getpath($ps[$k])); .)
    then error("its \"version\" keys are not each on a line of their own")
    else reduce $changes[] as $c ($lines; ($ps | index([$c.path])) as $k | .[$idx[$k]] |= vline_set($c.to))
      | join("\n")
    end;
