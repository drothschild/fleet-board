#!/bin/bash
# Rules in the shipped default merger persona (defaults/merger-persona.md).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
persona="$plugin_dir/scripts/supervisor/defaults/merger-persona.md"
failed=0

check() {
  if [ "$2" = 0 ]; then echo "ok - $1"; else failed=$((failed + 1)); echo "not ok - $1"; fi
}

flat=$(tr '\n' ' ' < "$persona" | tr -s ' ')
has() { case "$flat" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

rc=0; has 'choose `fix` for a merge conflict' || rc=1
check 'The default persona says to choose `fix` for a merge conflict.' "$rc"

rc=0; has 'choose `retry` at most once for a check that was still pending' || rc=1
check 'The default persona says to choose `retry` at most once for a check that was still pending.' "$rc"

rc=0; has 'choose `attention` for anything else, including a failed check of main' || rc=1
check 'The default persona says to choose `attention` for anything else, including a failed check of main.' "$rc"

rc=0; has 'after a merge with no project steps the report is `done`' || rc=1
check 'The default persona says that after a merge with no project steps the report is `done`.' "$rc"

last=$(grep -v '^[[:space:]]*$' "$persona" | tail -n 1)
prev=$(grep -v '^[[:space:]]*$' "$persona" | tail -n 2 | head -n 1)
rc=0
case "$prev" in *'merge.persona'*) ;; *) rc=1 ;; esac
case "$prev" in *'merge.persona_append'*) rc=1 ;; esac
case "$last" in *'merge.persona_append'*) ;; *) rc=1 ;; esac
check 'The default persona ends with the merge.persona and merge.persona_append customization lines.' "$rc"

[ "$failed" = 0 ]
