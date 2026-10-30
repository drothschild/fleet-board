#!/usr/bin/env bash
#
# Plain-bash structure test for the top README.
# Usage: bash tests/test-readme-structure.sh
# Checks headings order, demo image before install, demo.cast kept,
# the "Why it is built this way" link, and the authorship first sentence.

unset CDPATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
fails=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

# Line number of the first heading matching an ERE, in file $2.
hline() { grep -nE "^##+ +($1)" "$2" | head -1 | cut -d: -f1; }

# Prints nothing; returns 0 if headings are in order in file $1.
headings_in_order() {
  local f="$1" prev=0 n p
  for p in 'What it is' 'Demo' 'Results' 'Install' 'Provenance'; do
    n="$(hline "$p" "$f")"
    [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
  return 0
}

# Returns 0 if file $1 references a demo svg/gif before the Install heading
# and that file exists under docs/.
demo_before_install() {
  local f="$1" img inst
  img="$(grep -nE 'docs/demo\.(svg|gif)' "$f" | head -1 | cut -d: -f1)"
  inst="$(hline 'Install' "$f")"
  [ -n "$img" ] && [ -n "$inst" ] && [ "$img" -lt "$inst" ] || return 1
  [ -f "$ROOT/docs/demo.svg" ] || [ -f "$ROOT/docs/demo.gif" ]
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Heading order.
headings_in_order "$README" && ok "headings in order: what, demo, results, install, provenance" \
  || bad "headings not in order: what, demo, results, install, provenance"

# 1b. Negative: swapping two headings must fail.
sed -e 's/^## Demo/## TMPSWAP/' -e 's/^## Results/## Demo/' -e 's/^## TMPSWAP/## Results/' \
  "$README" > "$TMP/swapped.md"
if headings_in_order "$TMP/swapped.md"; then bad "swapped headings were accepted"; else ok "swapped headings rejected"; fi

# 2. Demo image before install.
demo_before_install "$README" && ok "demo svg/gif exists and is referenced before Install" \
  || bad "no demo svg/gif referenced before Install (or file missing)"

# 2b. Negative: with the image reference removed, it must fail.
grep -vE 'docs/demo\.(svg|gif)' "$README" > "$TMP/noimg.md"
if demo_before_install "$TMP/noimg.md"; then bad "README without demo image was accepted"; else ok "README without demo image rejected"; fi

# 3. demo.cast kept.
[ -f "$ROOT/plugins/fleet-board/docs/demo.cast" ] && ok "demo.cast present" || bad "demo.cast missing"

# 4. Why it is built this way, linking docs/design.md.
if grep -A3 -i 'Why it is built this way' "$README" | grep -q 'docs/design\.md' && [ -f "$ROOT/docs/design.md" ]; then
  ok "Why it is built this way links docs/design.md"
else
  bad "no 'Why it is built this way' paragraph linking an existing docs/design.md"
fi

# 5. Provenance section's first sentence states authorship.
first="$(awk '/^##+ +Provenance/{f=1;next} f&&/^#/{exit} f&&NF{print;exit}' "$README")"
if printf '%s\n' "$first" | grep -q 'I wrote the specs'; then ok "provenance opens with authorship"; else bad "provenance first line lacks 'I wrote the specs'"; fi

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
