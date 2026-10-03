#!/usr/bin/env bash
# parse-report.sh - validate a fleet-board role report and convert it to JSON.
#
# Usage: parse-report.sh [--role implementor|reviewer|fixer] <file>
#
# The report shape. This script is the enforced definition; the role
# agents and the manager follow it (line rules: see Pass 1 below):
#   ## Status          one word: done | blocked | clean | findings
#   ## Findings        "- [Critical|Important|Minor] <text>" lines, or "- none"
#   ## For the card    free text, with optional "Out of scope:" and "Bugs found:"
#                      sub-lists and an optional "Blocked by: #N" line
#   role sections      ## PR, ## Resolutions (fixer), ## Acceptance map,
#                      ## Mutation, ## Claim check (reviewer)
#   exactly one line   VERIFIED: `<command>` -> <integer> <what it counts>
#                      (the integer is followed by whitespace or the line end)
#
# --role adds: the role's sections are required; Status is done|blocked for the
# implementor and fixer, clean|findings for the reviewer; ## PR holds #<n>
# unless Status is blocked (implementor, fixer); reviewer clean means zero
# Critical and Important findings, findings means at least one; the reviewer's
# Acceptance map and the fixer's Resolutions have at least one entry.
# Section contents are checked whenever a section is present, with or without
# --role.
#
# On success prints one JSON object on stdout:
#   {status, findings, counts, for_the_card, out_of_scope, bugs, blocked_by, pr,
#    verified, acceptance_map, mutation, claim, resolutions}
# Role-specific fields are null when their section is absent.
#
# On failure prints one stderr line per problem, each prefixed "parse-report: ".
#
# Exit codes:
#   0 - the report is well formed; JSON on stdout
#   1 - the report is malformed; problems on stderr, nothing on stdout
#   2 - usage error (bad flag, unknown role, missing or unreadable file)

set -uo pipefail
unset CDPATH

USAGE="usage: parse-report.sh [--role implementor|reviewer|fixer] <file>"

ROLE=""
FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)
      if [ $# -lt 2 ]; then echo "parse-report: $USAGE" >&2; exit 2; fi
      ROLE="$2"
      shift 2
      ;;
    -*)
      echo "parse-report: unknown flag: $1" >&2
      echo "parse-report: $USAGE" >&2
      exit 2
      ;;
    *)
      if [ -n "$FILE" ]; then echo "parse-report: $USAGE" >&2; exit 2; fi
      FILE="$1"
      shift
      ;;
  esac
done

if [ -z "$FILE" ]; then
  echo "parse-report: $USAGE" >&2
  exit 2
fi

case "$ROLE" in
  ""|implementor|reviewer|fixer) ;;
  *)
    echo "parse-report: unknown role: $ROLE" >&2
    echo "parse-report: $USAGE" >&2
    exit 2
    ;;
esac

if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  echo "parse-report: cannot read file: $FILE" >&2
  exit 2
fi

# Pass 1 (awk): split the report into tab-separated records, one per line.
#   sec     <heading>                         a "## <heading>" line
#   status  <word>                            first non-blank line of ## Status
#   find    <severity> <text>                 a "- [Severity] text" finding
#   card    <line>                            a body line of ## For the card
#   oos     <title> <detail>                  an Out of scope: entry
#   bug     <title> <repro> <expected> <observed>
#   bugerr  <line>                            a Bugs found: entry of the wrong shape
#   blk     <N>                               a "Blocked by: #N" line
#   pr      <N>                               first #N inside ## PR
#   amap    <item> <test or empty>            an Acceptance map entry
#   mut     counts <k> <s> <i> | skipped      the ## Mutation line
#   claim   <key> <value> | skipped           a ## Claim check line
#   res     <finding> <outcome> <why>         a ## Resolutions entry
#   ver     <line>                            a VERIFIED: line, from anywhere
#   err     <message>                         a shape problem (the report is rejected)
#
# Input is normalized first: a trailing CR is dropped (CRLF files) and every
# tab becomes a space, so "##<tab>Status" and "-<tab>[Minor]" read as usual.
# Headings are trimmed: "##  Status " is ## Status.
#
# Line rules, per section (blank lines are ignored unless noted):
#   ## Status        exactly one non-blank line.
#   ## Findings      every line is "- [Critical|Important|Minor] <text>" or
#                    exactly "- none"; at least one of the two; never both.
#   ## For the card  free text. "Out of scope:" / "Bugs found:" open a sub-list
#                    whose entries are "- " lines directly under the header or
#                    the previous entry. A blank or text line ends the list. A
#                    header with no entry is an error. A "- " line that follows
#                    a list only after blank lines, or an indented "  - " line
#                    inside a list, is an error (it would otherwise be lost).
#                    Out of scope entry: "<title> :: <detail>", both non-empty.
#                    Bug entry: "<title> :: repro: `<cmd>` :: expected: <x> ::
#                    observed: <y>", all non-empty, the repro backticked.
#   ## PR            first "#<n>" is the PR number.
#   ## Acceptance map  "- <item> -> <file>::<test name>" or "- <item> -> UNMAPPED"
#                    (split on the last " -> ").
#   ## Mutation      exactly one line: "killed: <n> survived: <n> invalid: <n>"
#                    or "skipped: review.mutation is off".
#   ## Claim check   one each of "claim: <text>", "command: `<cmd>`",
#                    "result: <text>", "matches: yes|no"; or only
#                    "skipped: review.verify_claim is off".
#   ## Resolutions   "- <finding> :: fixed" or "- <finding> :: not fixed: <why>".
#                    The boundary is the first " :: " followed by an outcome, so
#                    " :: " may appear inside the finding and inside the why.
#   any heading      at most once.
# With a role, awk also checks (END): the PR number (implementor, fixer; not
# needed when Status is blocked), clean/findings against the counts
# (reviewer), and non-empty Acceptance map (reviewer) and Resolutions (fixer).
RECORDS="$(awk -v role="$ROLE" '
function trim(s) { sub(/^[ ]+/, "", s); sub(/[ ]+$/, "", s); return s }
function unquote(s) { s = trim(s); sub(/^`/, "", s); sub(/`$/, "", s); return s }
function err(m) { print "err\t" m }
function lastidx(s, t,    i, j) {
  i = 0
  while ((j = index(substr(s, i + 1), t)) > 0) i += j
  return i
}
function close_list() {
  if (sublist != "" && entries == 0) err("empty sub-list: " (sublist == "oos" ? "Out of scope:" : "Bugs found:"))
  sublist = ""
}
function stray(l) {
  err("stray list line in ## For the card (sub-list entries follow their header or the previous entry directly, unindented): " trim(l))
}
function emit_bug(entry,    n, p, prefixed, repro, expd, obsd) {
  n = split(entry, p, " :: ")
  prefixed = (p[2] ~ /^repro:/ && p[3] ~ /^expected:/ && p[4] ~ /^observed:/)
  repro = p[2]; sub(/^repro:/, "", repro); repro = unquote(repro)
  expd = p[3]; sub(/^expected:/, "", expd); expd = trim(expd)
  obsd = p[4]; sub(/^observed:/, "", obsd); obsd = trim(obsd)
  # The four-part check: title, repro, expected, observed, each non-empty.
  if (n != 4 || !prefixed || trim(p[1]) == "" || repro == "" || expd == "" || obsd == "") {
    print "bugerr\t" entry
    return
  }
  if (p[2] !~ /^repro:[ ]*`[^`]+`[ ]*$/) {
    err("bug repro must be a backticked command: " trim(p[1]))
    return
  }
  print "bug\t" trim(p[1]) "\t" repro "\t" expd "\t" obsd
}
function emit_oos(entry,    i, t, d) {
  i = index(entry, " :: ")
  t = (i > 0) ? trim(substr(entry, 1, i - 1)) : ""
  d = (i > 0) ? trim(substr(entry, i + 4)) : ""
  if (t == "" || d == "") { err("out of scope entry needs <title> :: <detail>: " entry); return }
  print "oos\t" t "\t" d
}
# res_split ENTRY: find the first " :: " followed by an outcome; sets RES_ITEM
# and RES_TAIL and returns 1, or returns 0.
function res_split(entry,    off, j, tail) {
  off = 0
  while ((j = index(substr(entry, off + 1), " :: ")) > 0) {
    off += j
    tail = substr(entry, off + 4)
    if (tail ~ /^fixed[ ]*$/ || tail ~ /^not fixed:[ ]*[^ ]/) {
      RES_ITEM = trim(substr(entry, 1, off - 1))
      RES_TAIL = trim(tail)
      return 1
    }
  }
  return 0
}
{
  line = $0
  sub(/\r$/, "", line)
  gsub(/\t/, " ", line)
  t = trim(line)
}
line ~ /^VERIFIED:/ { print "ver\t" line; next }
line ~ /^## / {
  if (sec == "For the card") close_list()
  sec = trim(substr(line, 4))
  if (sec in seen) err("duplicate section: ## " sec)
  seen[sec] = 1
  sublist = ""; after = ""
  print "sec\t" sec
  next
}
sec == "Status" {
  if (t == "") next
  if (status == "" && !status_seen) { status = t; status_seen = 1; print "status\t" t }
  else err("## Status must be one line, extra line: " t)
  next
}
sec == "Findings" {
  if (t == "") next
  if (t == "- none") { nones++; next }
  if (t ~ /^- \[(Critical|Important|Minor)\] +[^ ]/ && substr(line, 1, 3) == "- [") {
    sev = substr(t, 4, index(t, "]") - 4)
    print "find\t" sev "\t" trim(substr(t, index(t, "]") + 1))
    nfind++; sevs[sev]++
  } else {
    err("malformed finding line: " t); fbad++
  }
  next
}
sec == "For the card" {
  print "card\t" line
  if (line ~ /^Out of scope:[ ]*$/) { close_list(); sublist = "oos"; entries = 0; after = ""; next }
  if (line ~ /^Bugs found:[ ]*$/) { close_list(); sublist = "bug"; entries = 0; after = ""; next }
  if (sublist != "" && substr(line, 1, 2) == "- ") {
    entries++
    entry = trim(substr(line, 3))
    if (sublist == "bug") emit_bug(entry)
    else emit_oos(entry)
    next
  }
  if (sublist != "" && line ~ /^ +- /) { stray(line); next }
  if (t == "") {
    if (sublist != "") { after = sublist; close_list() }
    next
  }
  if (after != "" && line ~ /^ *- /) { stray(line); next }
  # Any other text line ends the current sub-list.
  close_list(); after = ""
  if (line ~ /^Blocked by: #[0-9]+/) {
    match(line, /#[0-9]+/)
    print "blk\t" substr(line, RSTART + 1, RLENGTH - 1)
  }
  next
}
sec == "PR" {
  if (!pr_seen && match(line, /#[0-9]+/)) { print "pr\t" substr(line, RSTART + 1, RLENGTH - 1); pr_seen = 1 }
  next
}
sec == "Acceptance map" {
  if (t == "") next
  ok = 0
  if (substr(line, 1, 2) == "- ") {
    entry = trim(substr(line, 3))
    i = lastidx(entry, " -> ")
    if (i > 0) {
      item = trim(substr(entry, 1, i - 1))
      tt = trim(substr(entry, i + 4))
      j = index(tt, "::")
      if (item != "" && (tt == "UNMAPPED" || (j > 1 && j < length(tt) - 1))) ok = 1
    }
  }
  if (!ok) { err("malformed ## Acceptance map line: " t); next }
  if (tt == "UNMAPPED") tt = ""
  print "amap\t" item "\t" tt
  namap++
  next
}
sec == "Mutation" {
  if (t == "") next
  if (t ~ /^killed: [0-9]+ survived: [0-9]+ invalid: [0-9]+$/) {
    split(t, w, " ")
    print "mut\tcounts\t" w[2] "\t" w[4] "\t" w[6]
    nmut++
  } else if (t == "skipped: review.mutation is off") {
    print "mut\tskipped"
    nmut++
  } else {
    err("malformed ## Mutation line: " t)
  }
  next
}
sec == "Claim check" {
  if (t == "") next
  if (t == "skipped: review.verify_claim is off") { print "claim\tskipped"; cskip++; next }
  if (t ~ /^(claim|command|result|matches):/) {
    key = substr(t, 1, index(t, ":") - 1)
    val = trim(substr(t, index(t, ":") + 1))
    ckeys[key]++
    if (key == "command") {
      if (val !~ /^`[^`]+`$/) { err("## Claim check command must be one backticked command: " val); next }
      val = unquote(val)
    } else if (key == "matches") {
      if (val != "yes" && val != "no") { err("## Claim check matches must be yes or no: " val); next }
    } else if (val == "") {
      err("malformed ## Claim check line: " t); next
    }
    print "claim\t" key "\t" val
    next
  }
  err("malformed ## Claim check line: " t)
  next
}
sec == "Resolutions" {
  if (t == "") next
  if (substr(line, 1, 2) == "- " && res_split(trim(substr(line, 3))) && RES_ITEM != "") {
    outcome = RES_TAIL
    why = ""
    if (outcome ~ /^not fixed:/) { why = trim(substr(outcome, 11)); outcome = "not fixed" }
    else outcome = "fixed"
    print "res\t" RES_ITEM "\t" outcome "\t" why
    nres++
  } else {
    err("malformed ## Resolutions line (want - <finding> :: fixed | not fixed: <why>): " t)
  }
  next
}
END {
  if (sec == "For the card") close_list()
  if ("Findings" in seen) {
    if (nfind == 0 && nones == 0 && fbad == 0)
      err("## Findings needs \"- none\" or at least one \"- [Critical|Important|Minor] <text>\" line")
    if (nfind > 0 && nones > 0) err("## Findings mixes \"- none\" with findings")
  }
  if ("Mutation" in seen && nmut != 1)
    err("## Mutation needs exactly one \"killed: <n> survived: <n> invalid: <n>\" or \"skipped: review.mutation is off\" line")
  if ("Claim check" in seen) {
    full = (ckeys["claim"] == 1 && ckeys["command"] == 1 && ckeys["result"] == 1 && ckeys["matches"] == 1)
    nk = ckeys["claim"] + ckeys["command"] + ckeys["result"] + ckeys["matches"]
    if (!((cskip == 0 && full) || (cskip == 1 && nk == 0)))
      err("## Claim check needs one each of claim:, command:, result: and matches:, or only \"skipped: review.verify_claim is off\"")
  }
  if ((role == "implementor" || role == "fixer") && ("PR" in seen) && !pr_seen && status != "blocked")
    err("role " role " requires a PR number (#<n>) in ## PR unless status is blocked")
  if (role == "reviewer") {
    ci = sevs["Critical"] + sevs["Important"]
    if (status == "clean" && ci > 0) err("status clean needs zero Critical and Important findings, found " ci)
    if (status == "findings" && ci == 0) err("status findings needs at least one Critical or Important finding")
    if (("Acceptance map" in seen) && namap == 0) err("role reviewer requires at least one ## Acceptance map entry")
  }
  if (role == "fixer" && ("Resolutions" in seen) && nres == 0)
    err("role fixer requires at least one ## Resolutions entry")
}
' "$FILE")"

# Pass 2 (bash): validate.
TAB="$(printf '\t')"
SECTIONS="|"
STATUS=""
VER_COUNT=0
VER_LINE=""
BUG_ERRORS=0
SHAPE_ERRORS=()
while IFS= read -r rec; do
  kind="${rec%%"$TAB"*}"
  rest="${rec#*"$TAB"}"
  case "$kind" in
    sec) SECTIONS="${SECTIONS}${rest}|" ;;
    status) [ -z "$STATUS" ] && STATUS="$rest" ;;
    ver) VER_COUNT=$((VER_COUNT + 1)); VER_LINE="$rest" ;;
    bugerr) BUG_ERRORS=$((BUG_ERRORS + 1)) ;;
    err) SHAPE_ERRORS+=("$rest") ;;
  esac
done <<EOF
$RECORDS
EOF

ERRORS=()
has_section() { case "$SECTIONS" in *"|$1|"*) return 0 ;; esac; return 1; }

for s in "Status" "Findings" "For the card"; do
  has_section "$s" || ERRORS+=("missing section: ## $s")
done

if has_section "Status"; then
  case "$STATUS" in
    done|blocked|clean|findings) ;;
    *) ERRORS+=("unknown status: $STATUS") ;;
  esac
  # Status values by role; an unknown word is reported once, above.
  case "$ROLE:$STATUS" in
    implementor:clean|implementor:findings|fixer:clean|fixer:findings|reviewer:done|reviewer:blocked)
      ERRORS+=("role $ROLE does not allow status: $STATUS") ;;
  esac
fi

VER_RE='^VERIFIED:[[:space:]]+`([^`]+)`[[:space:]]+(->|→)[[:space:]]+(-?[0-9]+)([[:space:]]|$)'
VER_CMD=""
VER_NUM=""
if [ "$VER_COUNT" -ne 1 ]; then
  ERRORS+=("expected exactly one VERIFIED: line, found $VER_COUNT")
elif [[ "$VER_LINE" =~ $VER_RE ]]; then
  VER_CMD="${BASH_REMATCH[1]}"
  VER_NUM="${BASH_REMATCH[3]}"
else
  ERRORS+=("VERIFIED line needs a backticked command and an integer after ->")
fi

if [ "$BUG_ERRORS" -gt 0 ]; then
  ERRORS+=("bug entry needs title, repro, expected, observed")
fi

case "$ROLE" in
  implementor) REQUIRED="PR" ;;
  fixer) REQUIRED="PR|Resolutions" ;;
  reviewer) REQUIRED="Acceptance map|Mutation|Claim check" ;;
  *) REQUIRED="" ;;
esac
if [ -n "$REQUIRED" ]; then
  OLD_IFS="$IFS"
  IFS="|"
  for s in $REQUIRED; do
    IFS="$OLD_IFS"
    has_section "$s" || ERRORS+=("role $ROLE requires ## $s")
  done
  IFS="$OLD_IFS"
fi

if [ "${#SHAPE_ERRORS[@]}" -gt 0 ]; then
  ERRORS+=("${SHAPE_ERRORS[@]}")
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
  for e in "${ERRORS[@]}"; do
    echo "parse-report: $e" >&2
  done
  exit 1
fi

# Pass 3 (jq): assemble the JSON from the records.
printf '%s\n' "$RECORDS" | jq -Rn \
  --arg ver_line "$VER_LINE" \
  --arg ver_cmd "$VER_CMD" \
  --arg ver_num "$VER_NUM" '
  [inputs | select(length > 0) | split("\t")] as $r
  | def recs($k): [$r[] | select(.[0] == $k)];
    def nul: if . == "" then null else . end;
    def has($s): any($r[]; .[0] == "sec" and .[1] == $s);
    (recs("find") | map({severity: .[1], text: .[2]})) as $findings
  | {
      status: (recs("status") | .[0][1]),
      findings: $findings,
      counts: {
        critical: ($findings | map(select(.severity == "Critical")) | length),
        important: ($findings | map(select(.severity == "Important")) | length),
        minor: ($findings | map(select(.severity == "Minor")) | length)
      },
      for_the_card: (recs("card") | map(.[1] // "") | join("\n")
                     | sub("^\n+"; "") | sub("\n+$"; "")),
      out_of_scope: (recs("oos") | map({title: .[1], detail: (.[2] // "")})),
      bugs: (recs("bug") | map({title: .[1], repro: .[2], expected: .[3], observed: .[4]})),
      blocked_by: (recs("blk") | if length > 0 then (.[0][1] | tonumber) else null end),
      pr: (recs("pr") | if length > 0 then (.[0][1] | tonumber) else null end),
      verified: {command: $ver_cmd, number: ($ver_num | tonumber), line: $ver_line},
      acceptance_map: (if has("Acceptance map")
                       then recs("amap") | map({item: .[1], test: ((.[2] // "") | nul)})
                       else null end),
      mutation: (recs("mut") as $m
                 | if ($m | length) == 0 then null
                   elif $m[0][1] == "skipped" then {skipped: true}
                   else {killed: ($m[0][2] | tonumber), survived: ($m[0][3] | tonumber),
                         invalid: ($m[0][4] | tonumber)}
                   end),
      claim: (recs("claim") as $c
              | if ($c | length) == 0 then null
                elif any($c[]; .[1] == "skipped") then {skipped: true}
                else
                  def field($k): ([$c[] | select(.[1] == $k) | (.[2] // "")] | .[0]);
                  {claim: field("claim"), command: field("command"), result: field("result"),
                   matches: (field("matches") | if . == "yes" then true elif . == "no" then false else null end)}
                end),
      resolutions: (if has("Resolutions")
                    then recs("res") | map({finding: .[1], outcome: (.[2] // ""), why: ((.[3] // "") | nul)})
                    else null end)
    }'
