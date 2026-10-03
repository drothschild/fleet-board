# yaml-subset.awk: converts the fleet-board YAML subset to one line of JSON.
#
# Supported YAML subset:
# - Keys: bare identifiers matching [A-Za-z_][A-Za-z0-9_]*, at indentation 0 or 2 spaces only. At most two levels deep.
# - A value is one of:
#   - a double- or single-quoted string (no escape sequences)
#   - true, false or null
#   - an integer or decimal number
#   - a bare string
#   - a flow list [a, "b"]
#   - a flow map { k: v, k2: "v2" }
# - Comments: # at line start or preceded by whitespace, outside quotes.
# - Rejected with a line number: tabs in indentation, block lists (- item), a third nesting level, nested flow collections, anchors and aliases, multi-line strings, duplicate keys.

function die(msg) { printf "config.sh: line %d: %s\n", NR, msg > "/dev/stderr"; err = 1; exit 4 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function strip_comment(s,   i, c, q, out) {
  q = ""; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; out = out c; continue }
    if (c == "\"" || c == "'") { q = c; out = out c; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) break
    out = out c
  }
  if (q != "") die("unterminated quote")
  return out
}
function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
function scalar(v) {
  v = trim(v)
  if (v == "") die("empty value")
  if (v ~ /^".*"$/ || v ~ /^'.*'$/) return jstr(substr(v, 2, length(v) - 2))
  if (v == "true" || v == "false" || v == "null") return v
  if (v ~ /^-?[0-9]+(\.[0-9]+)?$/) return v
  if (v ~ /^[\[{&*!|>%@`"']/) die("unsupported YAML value: " v)
  return jstr(v)
}
function split_flow(s, arr,   i, c, q, cur, n) {
  n = 0; q = ""; cur = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == q) q = ""; cur = cur c; continue }
    if (c == "\"" || c == "'") { q = c; cur = cur c; continue }
    if (c == "[" || c == "{") die("nested flow collections are not supported")
    if (c == ",") { arr[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  if (trim(cur) != "") arr[++n] = cur
  return n
}
function value(v,   inner, n, i, items, k, colon, out) {
  v = trim(v)
  if (v ~ /^\[/) {
    if (v !~ /\]$/) die("unterminated flow list")
    inner = substr(v, 2, length(v) - 2); n = split_flow(inner, items); out = "["
    for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") scalar(items[i])
    return out "]"
  }
  if (v ~ /^\{/) {
    if (v !~ /\}$/) die("unterminated flow map")
    inner = substr(v, 2, length(v) - 2); n = split_flow(inner, items); out = "{"
    for (i = 1; i <= n; i++) {
      colon = index(items[i], ":")
      if (colon == 0) die("flow map entry without ':'")
      k = trim(substr(items[i], 1, colon - 1))
      if (k !~ /^[A-Za-z_][A-Za-z0-9_]*$/) die("unsupported key: " k)
      out = out (i > 1 ? "," : "") jstr(k) ":" scalar(substr(items[i], colon + 1))
    }
    return out "}"
  }
  return scalar(v)
}
function emit_top(s) { out = out (top_n++ ? "," : "") s }
function close_open() {
  if (open != "") emit_top(jstr(open) ":{" child "}")
  open = ""; child = ""; child_n = 0
}
BEGIN { out = "{"; top_n = 0; open = ""; child = ""; child_n = 0 }
{
  line = $0
  if (line ~ /^[ ]*\t/) die("tabs are not allowed for indentation")
  line = strip_comment(line)
  if (line ~ /^[ \t]*$/) next
  match(line, /^ */); ind = RLENGTH
  body = substr(line, ind + 1)
  if (body ~ /^-( |$)/) die("block lists are not supported; use [a, b]")
  colon = index(body, ":")
  if (colon == 0) die("expected 'key: value'")
  key = substr(body, 1, colon - 1)
  if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) die("unsupported key: " key)
  if (colon < length(body) && substr(body, colon + 1, 1) != " ") die("expected a space after ':'")
  rest = trim(substr(body, colon + 1))
  if (ind == 0) {
    close_open()
    if (key in seen_top) die("duplicate key: " key)
    seen_top[key] = 1
    if (rest == "") { open = key } else { emit_top(jstr(key) ":" value(rest)) }
  } else if (ind == 2) {
    if (open == "") die("indented key without a parent map")
    if (rest == "") die("only two levels of nesting are supported")
    if ((open SUBSEP key) in seen_child) die("duplicate key: " open "." key)
    seen_child[open, key] = 1
    child = child (child_n++ ? "," : "") jstr(key) ":" value(rest)
  } else {
    die("only two levels of nesting are supported (indent 0 or 2 spaces)")
  }
}
END { if (err) exit 4; close_open(); print out "}" }
