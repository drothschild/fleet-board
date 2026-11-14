#!/bin/bash
# Card 347: an unreadable configured merge.persona is attention, never a fallback to the default persona.
set -u
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'chmod 644 "$tmp/p.md" 2>/dev/null; rm -rf "$tmp"' EXIT
echo "# Custom persona" > "$tmp/p.md"
chmod 000 "$tmp/p.md"

out=$(PYTHONPATH="$plugin_dir/scripts" python3 -I -c '
import sys, types
sys.path.insert(0, sys.argv[1])
from supervisor import driver
fake = types.SimpleNamespace(root=__import__("pathlib").Path(sys.argv[2]), _persona_changed=lambda *a: False)
c = types.SimpleNamespace(config={"merge": {"persona": "p.md"}})
try:
    print("RETURNED " + driver.CardDriver._persona(fake, c, 1))
except driver._Attention as exc:
    print("ATTENTION " + str(exc))
' "$plugin_dir/scripts" "$tmp" 2>&1)

failed=0
case "$out" in
  "ATTENTION persona unreadable"*) echo "ok - unreadable merge.persona raises attention ($out)" ;;
  *) echo "not ok - unreadable merge.persona raises attention (got: $out)"; failed=1 ;;
esac
exit $failed
