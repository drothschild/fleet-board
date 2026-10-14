#!/usr/bin/env bash
#
# Plain-bash tests for scripts/yaml.jq, the YAML-subset parser config.sh uses
# in place of yq. No framework, no dependencies beyond jq.
#
# Each case parses a YAML snippet and compares the compact JSON. When
# mikefarah/yq v4 happens to be installed, every accepted case is also parsed
# with yq and the two must agree (yq is never required).
#
# Usage: bash plugins/fleet-board/tests/test-yaml.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PARSER="${SCRIPT_DIR}/../scripts/yaml.jq"
FIXTURES="${SCRIPT_DIR}/../fixtures/config"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }

HAVE_YQ=0
case "$(yq --version 2>/dev/null)" in
  *mikefarah/yq*" version v4"*|*mikefarah/yq*" version 4"*) HAVE_YQ=1 ;;
esac

# parse FILE: sets OUT, ERR, RC
parse() {
  OUT="$(jq -Rsc -f "$PARSER" "$1" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}

# ok NAME EXPECTED_JSON  (YAML on stdin)
ok() {
  cat > "$TMP/in.yml"
  parse "$TMP/in.yml"
  if [ "$RC" -ne 0 ]; then fail "$1" "exit $RC: $ERR"; return; fi
  if [ "$OUT" = "$2" ]; then pass "$1"; else fail "$1" "expected $2, got $OUT"; fi
  if [ "$HAVE_YQ" = 1 ]; then
    local want; want="$(yq -o=json -I=0 'explode(.)' "$TMP/in.yml" 2>/dev/null | jq -c .)"
    if [ "$OUT" = "$want" ]; then pass "$1 (agrees with yq)"; else fail "$1 (agrees with yq)" "yq gives $want, parser gives $OUT"; fi
  fi
}

# bad NAME EXPECTED_STDERR_SUBSTRING  (YAML on stdin)
bad() {
  cat > "$TMP/in.yml"
  parse "$TMP/in.yml"
  if [ "$RC" -eq 0 ]; then fail "$1" "expected failure, got $OUT"; return; fi
  case "$ERR" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected '$2' in stderr: $ERR" ;;
  esac
}

echo "Test: yaml.jq"
echo ""

if [ ! -f "$PARSER" ]; then
  fail "parser exists" "no $PARSER"
fi

# --- documents ---------------------------------------------------------------
printf '' | ok "empty file is null" 'null'
printf '# only a comment\n\n' | ok "comment-only file is null" 'null'
printf -- '---\nboard:\n  repo: a/b\n' | ok "leading document marker" '{"board":{"repo":"a/b"}}'
printf 'board:\r\n  repo: a/b\r\n' | ok "CRLF line endings" '{"board":{"repo":"a/b"}}'

# --- block maps and lists ----------------------------------------------------
printf 'a:\n  b:\n    c:\n      d: deep\n' | ok "four nesting levels" '{"a":{"b":{"c":{"d":"deep"}}}}'
printf 'a: 1\nb:\nc: x\n' | ok "empty value is null" '{"a":1,"b":null,"c":"x"}'
printf 'l:\n  - "src/**"\n  - docs/ui # c\n' | ok "indented block list" '{"l":["src/**","docs/ui"]}'
printf 'l:\n- a\n- b\nm: 1\n' | ok "compact block list" '{"l":["a","b"],"m":1}'
printf -- '- a\n- b\n' | ok "top-level list" '["a","b"]'
printf 'a:b: c\nu: http://x.y/z\n' | ok "colons without a space stay in keys and values" '{"a:b":"c","u":"http://x.y/z"}'
printf '"quoted key": 1\n'"'"'single'"'"': 2\n' | ok "quoted keys" '{"quoted key":1,"single":2}'

# --- scalars -----------------------------------------------------------------
printf 'i: 42\nn: -7\nf: 2.5\nt: true\nF: false\nz: null\ntl: ~\ns: 1.2.3\nq: "42"\n' \
  | ok "scalar types" '{"i":42,"n":-7,"f":2.5,"t":true,"F":false,"z":null,"tl":null,"s":"1.2.3","q":"42"}'
printf 'w: Won'"'"'t Do # trailing\nh: a#b\n' | ok "apostrophe in plain scalar, # without space" '{"w":"Won'"'"'t Do","h":"a#b"}'
printf 'c: "echo a # b"\nd: '"'"'x # y'"'"'\n' | ok "# inside quotes kept" '{"c":"echo a # b","d":"x # y"}'
printf 'e: "a\\"b\\\\c\\td\\n\\u00e9"\n' | ok "double-quoted escapes" '{"e":"a\"b\\c\td\né"}'
printf 's: '"'"'it'"''"'s'"'"'\n' | ok "single-quoted doubled quote" '{"s":"it'"'"'s"}'
printf 'p: node --test {file}\n' | ok "plain scalar with braces inside" '{"p":"node --test {file}"}'

# --- block scalars -----------------------------------------------------------
printf 'a: |\n  line one\n  line two\nb: 1\n' | ok "literal block" '{"a":"line one\nline two\n","b":1}'
printf 'a: |-\n  one\n\n  two\n' | ok "literal block, strip" '{"a":"one\n\ntwo"}'
printf 'a: >\n  one\n  two\n\n  three\n' | ok "folded block" '{"a":"one two\nthree\n"}'

# --- flow collections --------------------------------------------------------
printf 'm: { a: 1, b: [x, "y z", { n: 2 }], c: }\n' | ok "nested flow" '{"m":{"a":1,"b":["x","y z",{"n":2}],"c":null}}'
printf 'l: [a, b,]\ne: []\no: {}\n' | ok "trailing comma and empty flow" '{"l":["a","b"],"e":[],"o":{}}'
printf 's: { wont_do: "Won'"'"'t Do", in_progress: In progress }\n' | ok "flow strings" '{"s":{"wont_do":"Won'"'"'t Do","in_progress":"In progress"}}'
printf 'm: {\n  a: 1,   # one\n  b: [2,\n      3]\n}\n' | ok "multi-line flow" '{"m":{"a":1,"b":[2,3]}}'

# --- every config fixture parses ---------------------------------------------
for f in "$FIXTURES"/*.yml; do
  name="fixture $(basename "$f")"
  case "$f" in *bad-tab.yml) continue ;; esac
  parse "$f"
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r type 2>/dev/null)" = object ]; then
    pass "$name parses to a map"
  else
    fail "$name parses to a map" "exit $RC: $ERR"
  fi
  if [ "$HAVE_YQ" = 1 ]; then
    want="$(yq -o=json -I=0 'explode(.)' "$f" 2>/dev/null | jq -c .)"
    if [ "$OUT" = "$want" ]; then pass "$name (agrees with yq)"; else fail "$name (agrees with yq)" "yq gives $want, parser gives $OUT"; fi
  fi
done

# --- rejected input: exit non-zero with the line number ----------------------
bad "tab indentation" 'line 2: tab' < "$FIXTURES/bad-tab.yml"
printf 'a: [unclosed\n' | bad "unclosed flow" 'line 1'
printf 'a: "open\n' | bad "unterminated quote" 'line 1: unterminated'
printf 'a: 1\na: 2\n' | bad "duplicate key" 'line 2: duplicate key a'
printf 'b: &x 1\nc: *x\n' | bad "anchor" 'line 1: anchors, aliases and tags are not supported'
printf 'c: !!str 1\n' | bad "tag" 'line 1: anchors, aliases and tags are not supported'
printf 'a: 1\n  b: 2\n' | bad "unexpected indentation" 'line 2: unexpected indentation'
printf 'a: 1\n---\nb: 2\n' | bad "second document" 'line 2: only one YAML document'
printf 'l:\n  - k: v\n' | bad "map inside a block list" 'line 2: a block list item must be a scalar or a flow collection'

echo ""
[ "$HAVE_YQ" = 1 ] && echo "(cross-checked against $(yq --version))"
echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
