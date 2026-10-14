# yaml.jq - parse the YAML subset a .fleet-board.yml uses into JSON, so
# config.sh needs only jq (which ships with macOS) and not yq.
#
# Usage: jq -Rsc -f yaml.jq FILE
#
# Supported: block maps and block lists; flow maps and lists, nested and
# across lines; plain, 'single' and "double" quoted scalars; | and > block
# scalars with - and + chomping; # comments; one leading "---".
# Rejected with "line N: <reason>": anchors, aliases and tags, tabs in
# indentation, duplicate keys, a second document, a map inside a block list
# item, and anything else outside the subset. Must run on jq 1.6.

def fail($n; $msg): error("line \($n): \($msg)");

def is_ws: . == 32 or . == 9;

# A plain scalar, resolved by the YAML 1.2 core schema.
def plain:
  if . == "" or . == "~" or . == "null" or . == "Null" or . == "NULL" then null
  elif . == "true" or . == "True" or . == "TRUE" then true
  elif . == "false" or . == "False" or . == "FALSE" then false
  elif test("^[-+]?[0-9]+$")
    or test("^[-+]?([0-9]+\\.[0-9]*|\\.[0-9]+)([eE][-+]?[0-9]+)?$")
    or test("^[-+]?[0-9]+[eE][-+]?[0-9]+$")
  then ltrimstr("+") | tonumber
  else . end;

def check_plain($n):
  if test("^[&*!]") then fail($n; "anchors, aliases and tags are not supported")
  elif test("^[|>@`%?]") then fail($n; "a value may not start with \(.[0:1]) here; quote it")
  else . end;

# Cut a # comment (one preceded by whitespace and outside quotes) and trailing
# whitespace. A quote opens a quoted scalar only where a scalar can start:
# after "key: ", "- ", "[", "{" or ",", or at the start of the line.
def strip_comment($n):
  explode as $c
  | reduce range(0; $c | length) as $i ({q: null, esc: false, skip: false, end: null, prev: 32, pns: null};
      if .end != null then .
      elif .skip then .skip = false
      elif .q == 34 then
        if .esc then .esc = false
        elif $c[$i] == 92 then .esc = true
        elif $c[$i] == 34 then .q = null
        else . end
      elif .q == 39 then
        if $c[$i] == 39 and $c[$i + 1] == 39 then .skip = true
        elif $c[$i] == 39 then .q = null
        else . end
      elif $c[$i] == 35 and (.prev | is_ws) then .end = $i
      elif ($c[$i] == 34 or $c[$i] == 39)
        and (.pns == null
             or (([.pns] | inside([58, 45, 44, 91, 123]))
                 and ((.prev | is_ws) or ([.prev] | inside([91, 123, 44])))))
      then .q = $c[$i]
      else . end
      | .prev = $c[$i]
      | if ($c[$i] | is_ws) then . else .pns = $c[$i] end)
  | if .q != null then fail($n; "unterminated quoted string") else . end
  | ($c[0:(.end // ($c | length))] | implode | sub("[ \t]+$"; ""));

# Flow parsing over one string. Each parser takes a position and returns
# [value, position after it]. Running out of input mid-collection fails with
# "unclosed flow collection", which the block parser uses to join lines.
def flow_parse($s; $n):
  ($s | explode) as $c | ($c | length) as $len
  | def ws($p): if $p < $len and ($c[$p] | is_ws) then ws($p + 1) else $p end;
    def hex4($p):
      ($c[$p:$p + 4] | implode) as $h
      | if ($h | test("^[0-9a-fA-F]{4}$")) | not then fail($n; "bad \\u escape") else . end
      | $h | ascii_downcase | explode
      | reduce .[] as $d (0; . * 16 + (if $d >= 97 then $d - 87 else $d - 48 end));
    def dq($p):
      def loop($p; $acc):
        if $p >= $len then fail($n; "unterminated quoted string")
        elif $c[$p] == 34 then [($acc | implode), $p + 1]
        elif $c[$p] == 92 then
          ($c[$p + 1] // -1) as $e
          | if $e == 110 then loop($p + 2; $acc + [10])
            elif $e == 116 then loop($p + 2; $acc + [9])
            elif $e == 114 then loop($p + 2; $acc + [13])
            elif $e == 48 then loop($p + 2; $acc + [0])
            elif $e == 34 or $e == 92 or $e == 47 or $e == 32 then loop($p + 2; $acc + [$e])
            elif $e == 117 then loop($p + 6; $acc + [hex4($p + 2)])
            else fail($n; "unsupported escape in a double-quoted string") end
        else loop($p + 1; $acc + [$c[$p]]) end;
      loop($p; []);
    def sq($p):
      def loop($p; $acc):
        if $p >= $len then fail($n; "unterminated quoted string")
        elif $c[$p] == 39 and $c[$p + 1] == 39 then loop($p + 2; $acc + [39])
        elif $c[$p] == 39 then [($acc | implode), $p + 1]
        else loop($p + 1; $acc + [$c[$p]]) end;
      loop($p; []);
    # A flow plain scalar ends at , ] } or a ": " (or ":" before , ] }).
    def plainf($p):
      def stop($q):
        $q >= $len or ([$c[$q]] | inside([44, 93, 125]))
        or ($c[$q] == 58 and ($q + 1 >= $len or ([$c[$q + 1]] | inside([32, 9, 44, 93, 125]))));
      def loop($q): if stop($q) then $q else loop($q + 1) end;
      loop($p) as $q
      | [($c[$p:$q] | implode | sub("[ \t]+$"; "")), $q];
    def scalar_at($p):
      if $c[$p] == 34 then dq($p + 1)
      elif $c[$p] == 39 then sq($p + 1)
      else plainf($p) | .[0] |= (check_plain($n) | plain) end;
    def key_at($p):
      if $c[$p] == 34 then dq($p + 1)
      elif $c[$p] == 39 then sq($p + 1)
      else plainf($p) | .[0] |= check_plain($n) end;
    def node($p):
      def seq($p; $acc):
        ws($p) as $p
        | if $p >= $len then fail($n; "unclosed flow collection")
          elif $c[$p] == 93 then [$acc, $p + 1]
          else node($p) as [$v, $q] | ws($q) as $q
            | if $q < $len and $c[$q] == 44 then seq($q + 1; $acc + [$v])
              elif $q < $len and $c[$q] == 93 then [$acc + [$v], $q + 1]
              elif $q >= $len then fail($n; "unclosed flow collection")
              else fail($n; "expected , or ] in a flow list") end
          end;
      def fmap($p; $acc):
        ws($p) as $p
        | if $p >= $len then fail($n; "unclosed flow collection")
          elif $c[$p] == 125 then [$acc, $p + 1]
          else key_at($p) as [$k, $q] | ws($q) as $q
            | (if $acc | has($k) then fail($n; "duplicate key \($k)") else . end)
            | (if $q < $len and $c[$q] == 58 then
                 ws($q + 1) as $r
                 | if $r < $len and ([$c[$r]] | inside([44, 125])) then [null, $r] else node($r) end
               else [null, $q] end) as [$v, $q]
            | ws($q) as $q
            | if $q < $len and $c[$q] == 44 then fmap($q + 1; $acc + {($k): $v})
              elif $q < $len and $c[$q] == 125 then [$acc + {($k): $v}, $q + 1]
              elif $q >= $len then fail($n; "unclosed flow collection")
              else fail($n; "expected , or } in a flow map") end
          end;
      ws($p) as $p
      | if $p >= $len then fail($n; "unclosed flow collection")
        elif $c[$p] == 91 then seq($p + 1; [])
        elif $c[$p] == 123 then fmap($p + 1; {})
        else scalar_at($p) end;
    { node: node(0), len: $len, c: $c };

# A whole value that starts with a quote or a bracket: nothing may follow it.
def flow_value($s; $n):
  flow_parse($s; $n) as $f
  | $f.node as [$v, $p]
  | if ($f.c[$p:] | implode | test("^[ \t]*$")) then $v
    else fail($n; "unexpected text after a quoted or flow value") end;

# A quoted key at the start of $s: [key, rest of the string after it].
def quoted_key($s; $n):
  flow_parse($s; $n) as $f
  | $f.node as [$k, $p]
  | [$k, ($f.c[$p:] | implode)];

def value_of($rest; $n):
  if $rest == "" then null
  elif ($rest | test("^[\"'\\[{]")) then flow_value($rest; $n)
  else $rest | check_plain($n) | plain end;

def block_scalar($hdr; $lines; $n):
  ($lines | map(select(test("^ *$") | not)) | if length == 0 then 0 else (.[0] | match("^ *").length) end) as $ci
  | ($lines | map(if test("^ *$") then ""
                  elif (match("^ *").length) < $ci then fail($n; "block scalar line is less indented than its first line")
                  else .[$ci:] end)) as $ls
  | ([$ls | to_entries[] | select(.value != "") | .key] | if length == 0 then -1 else max end) as $last
  | ($ls[0:$last + 1]) as $body
  | (($ls | length) - $last - 1) as $trail
  | (if ($hdr | startswith("|")) then $body | join("\n")
     else reduce range(0; $body | length) as $i ("";
       if $i == 0 then $body[0]
       elif $body[$i] == "" then . + "\n"
       elif $body[$i - 1] == "" then . + $body[$i]
       else . + " " + $body[$i] end) end) as $text
  | if ($hdr | endswith("-")) then $text
    elif ($hdr | endswith("+")) then $text + "\n" + ([range(0; $trail)] | map("\n") | join(""))
    elif $text == "" then ""
    else $text + "\n" end;

# One pass over the raw lines: drop blank and comment-only lines, strip
# comments, and attach the raw lines of each block scalar to its entry.
def entries:
  ltrimstr("﻿") | split("\n") | map(rtrimstr("\r")) | to_entries
  | reduce .[] as $l ({es: [], bs: null};
      ($l.key + 1) as $n
      | if .bs != null and (($l.value | test("^[ \t]*$")) or (($l.value | match("^ *").length) > .bs)) then
          .es[(.es | length) - 1].block += [$l.value]
        else
          .bs = null
          | ($l.value | strip_comment($n)) as $t
          | if ($t | test("^[ \t]*$")) then .
            elif ($t | test("^ *\t")) then fail($n; "tab characters are not allowed in indentation")
            else
              ($t | match("^ *").length) as $ind
              | ($t[$ind:]) as $text
              | if $ind == 0 and $text == "---" then
                  if (.es | length) == 0 then . else fail($n; "only one YAML document is supported") end
                elif $ind == 0 and ($text == "..." or ($text | startswith("%"))) then
                  fail($n; "document markers and directives are not supported")
                elif ($text | test("(^|: |^- )[|>][-+]?$")) then
                  .es += [{n: $n, ind: $ind, t: $text, block: []}] | .bs = $ind
                else .es += [{n: $n, ind: $ind, t: $text}] end
            end
        end)
  | .es;

def is_item: .t == "-" or (.t | startswith("- "));

# {k, r} for a "key: rest" entry, or null.
def split_key:
  . as $e
  | if ($e.t | test("^[\"']")) then
      quoted_key($e.t; $e.n) as [$k, $after]
      | (($after | capture("^[ \t]*:(?<r>([ \t].*)?)$")) // null) as $m
      | if $m == null then null else {k: $k, r: ($m.r | sub("^[ \t]+"; ""))} end
    elif ($e.t | test("^[\\[{]")) then null
    else
      ($e.t | capture("^(?<k>.*?)[ \t]*:(?<r>([ \t].*)?)$")) // null
      | if . == null then null
        else .k |= check_plain($e.n) | .r |= sub("^[ \t]+"; "") end
    end;

def parse($E):
  ($E | length) as $len
  | def node($i; $ind):
      # The value after "key:" or "-" on entry $i: [value, next entry].
      def value_after($i; $ind; $rest; $inmap):
        $E[$i] as $e
        | if $rest == "" then
            if $i + 1 < $len and $E[$i + 1].ind > $ind then node($i + 1; $E[$i + 1].ind)
            elif $inmap and $i + 1 < $len and $E[$i + 1].ind == $ind and ($E[$i + 1] | is_item) then node($i + 1; $ind)
            else [null, $i + 1] end
          elif ($rest | test("^[|>][-+]?$")) then [block_scalar($rest; $e.block // []; $e.n), $i + 1]
          elif ($rest | test("^[\\[{]")) then
            # A flow collection may continue on more-indented lines.
            def joined($j; $s):
              try [flow_value($s; $e.n), $j + 1]
              catch (if test("unclosed flow collection") and $j + 1 < $len
                         and ($E[$j + 1].ind > $ind or ($E[$j + 1].t | test("^[\\]}]")))
                     then joined($j + 1; $s + " " + $E[$j + 1].t) else error(.) end);
            joined($i; $rest)
          else [value_of($rest; $e.n), $i + 1] end;
      def items($i; $ind; $acc):
        if $i >= $len or $E[$i].ind < $ind or (($E[$i] | is_item) | not) then
          if $i < $len and $E[$i].ind > $ind then fail($E[$i].n; "unexpected indentation") else [$acc, $i] end
        elif $E[$i].ind > $ind then fail($E[$i].n; "unexpected indentation")
        else
          ($E[$i].t[1:] | sub("^[ \t]+"; "")) as $rest
          | if ({t: $rest, n: $E[$i].n} | split_key) != null then
              fail($E[$i].n; "a block list item must be a scalar or a flow collection")
            else value_after($i; $ind; $rest; false) as [$v, $j] | items($j; $ind; $acc + [$v]) end
        end;
      def pairs($i; $ind; $acc):
        if $i >= $len or $E[$i].ind < $ind then [$acc, $i]
        elif $E[$i].ind > $ind then fail($E[$i].n; "unexpected indentation")
        elif ($E[$i] | is_item) then fail($E[$i].n; "expected a key, found a list item")
        else
          ($E[$i] | split_key) as $kv
          | if $kv == null then fail($E[$i].n; "expected key: value") else . end
          | if ($acc | has($kv.k)) then fail($E[$i].n; "duplicate key \($kv.k)") else . end
          | value_after($i; $ind; $kv.r; true) as [$v, $j]
          | pairs($j; $ind; $acc + {($kv.k): $v})
        end;
      if ($E[$i] | is_item) then items($i; $ind; [])
      elif ($E[$i] | split_key) != null then pairs($i; $ind; {})
      else value_after($i; $ind; $E[$i].t; false) end;
    if $len == 0 then null
    else node(0; $E[0].ind) as [$v, $j]
      | if $j < $len then fail($E[$j].n; "unexpected indentation") else $v end
    end;

parse(entries)
