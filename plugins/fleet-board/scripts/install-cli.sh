#!/usr/bin/env bash
# install-cli.sh - put the `fleet-board` command on your PATH
#
# Copies scripts/fleet-board to $FLEET_BOARD_BIN_DIR (default ~/.local/bin).
# The copy finds the plugin's current install each time it runs, so this only
# needs running once; running it again refreshes the copy. It never overwrites a
# file named fleet-board that it did not write.
#
# Usage: install-cli.sh
# Exit codes: 0 installed (or refreshed); 1 refused or could not write.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/fleet-board"
MARK="# fleet-board command-line launcher"
DIR="${FLEET_BOARD_BIN_DIR:-$HOME/.local/bin}"
DEST="$DIR/fleet-board"

die() { printf 'install-cli: %s\n' "$1" >&2; exit 1; }

[ -f "$SRC" ] || die "missing $SRC"
mkdir -p "$DIR" || die "cannot create $DIR"
if [ -e "$DEST" ] && ! grep -qxF -- "$MARK" "$DEST" 2>/dev/null; then
  die "$DEST exists and is not the fleet-board launcher; move it away or set FLEET_BOARD_BIN_DIR"
fi
TMP="$DEST.tmp.$$"
cp "$SRC" "$TMP" && chmod 755 "$TMP" && mv -f "$TMP" "$DEST" || { rm -f "$TMP"; die "cannot write $DEST"; }
printf 'installed: %s\n' "$DEST"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) printf '%s is not on your PATH. Add this line to your shell profile (~/.zshrc or ~/.bashrc):\n  export PATH="%s:$PATH"\n' \
       "$DIR" "$DIR" ;;
esac
exit 0
