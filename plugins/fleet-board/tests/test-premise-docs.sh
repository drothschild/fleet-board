#!/usr/bin/env bash
# The README documents the premise check: a "## Premise check" section naming its config keys and commands.
set -euo pipefail
unset CDPATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README="$HERE/../README.md"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1" >&2; fail=1; }

section="$(awk '/^## Premise check[[:space:]]*$/ {on=1; next} /^## / {on=0} on' "$README")"
if [ -n "$section" ]; then ok "README has a ## Premise check section"; else bad "README has no ## Premise check section"; fi
for term in 'premise_check.enabled' 'models.checker' 'followups.auto_ready' 'followups.auto_ready_cap' \
            'premise-settle.sh approve' 'premise-settle.sh confirm' 'fleet:closed-as-built'; do
  if printf '%s\n' "$section" | grep -cF -- "$term" >/dev/null; then ok "section names $term"; else bad "section does not name $term"; fi
done
exit "$fail"
