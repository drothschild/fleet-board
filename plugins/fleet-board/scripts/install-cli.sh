#!/usr/bin/env bash
# install-cli.sh - put the `fleet-board` command on your PATH
#
# Copies scripts/fleet-board to $FLEET_BOARD_BIN_DIR (default ~/.local/bin).
# The copy finds the plugin's current install each time it runs, so this only
# needs running once; running it again refreshes the copy. It never overwrites a
# file named fleet-board that it did not write, nor any symlink there.
#
# Usage: install-cli.sh
# Exit codes: 0 installed (or refreshed); 1 refused or could not write.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/fleet-board"
MARK="# fleet-board command-line launcher"

# strip_slash PATH: PATH without trailing slashes ("/" stays "/").
strip_slash() {
  local p="$1"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

DIR="$(strip_slash "${FLEET_BOARD_BIN_DIR:-$HOME/.local/bin}")"
DEST="${DIR%/}/fleet-board"

die() { printf 'install-cli: %s\n' "$1" >&2; exit 1; }

[ -f "$SRC" ] || die "missing $SRC"
mkdir -p "$DIR" || die "cannot create $DIR"
# Any symlink at the destination is not ours, wherever it points (even at a
# launcher, or nowhere): leave it alone.
if [ -L "$DEST" ]; then
  die "$DEST is a symbolic link, not the fleet-board launcher; remove it or set FLEET_BOARD_BIN_DIR"
fi
if [ -e "$DEST" ] && ! grep -qxF -- "$MARK" "$DEST" 2>/dev/null; then
  die "$DEST exists and is not the fleet-board launcher; move it away or set FLEET_BOARD_BIN_DIR"
fi
TMP="$DEST.tmp.$$"
cp "$SRC" "$TMP" && chmod 755 "$TMP" && mv -f "$TMP" "$DEST" || { rm -f "$TMP"; die "cannot write $DEST"; }
printf 'installed: %s\n' "$DEST"

# Is DIR on PATH? Each entry is compared without its trailing slashes and with a
# leading ~ expanded to $HOME.
on_path=0
rest="$PATH:"
while [ -n "$rest" ]; do
  e="${rest%%:*}"; rest="${rest#*:}"
  case "$e" in '~'|'~/'*) e="$HOME${e#?}" ;; esac
  [ "$(strip_slash "$e")" = "$DIR" ] && { on_path=1; break; }
done
if [ "$on_path" -eq 0 ]; then
  printf '%s is not on your PATH. Add this line to your shell profile (~/.zshrc or ~/.bashrc):\n  export PATH="%s:$PATH"\n' \
    "$DIR" "$DIR"
fi
exit 0
