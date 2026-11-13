#!/usr/bin/env bash
#
# Plain-bash tests for the `fleet-board` command-line launcher (scripts/fleet-board)
# and its installer (scripts/install-cli.sh). Offline; needs only bash, jq and git.
# Every case uses a temporary HOME and bin directory: nothing touches the real
# ~/.local/bin or ~/.claude.
#
# Usage: bash plugins/fleet-board/tests/test-fleet-board-cli.sh
set -uo pipefail
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
LAUNCHER="$SCRIPTS/fleet-board"
INSTALL="$SCRIPTS/install-cli.sh"
unset FLEET_BOARD_PLUGIN_ROOT FLEET_BOARD_BIN_DIR || true

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
contains() { # contains NAME NEEDLE HAYSTACK
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected to find [$2] in [$3]" ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# A fake plugin root whose scripts record how they were called.
make_root() { # make_root DIR VERSION
  mkdir -p "$1/scripts"
  local s
  for s in board-web.sh supervisor.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s %s %%s\\n" "%s" "$*"\n' "$2" "$s" > "$1/scripts/$s"
  done
}

# A fake HOME with installed_plugins.json listing fleet-board installs.
# Each extra argument is SCOPE|PROJECTPATH|INSTALLPATH|VERSION.
make_home() { # make_home DIR ENTRY...
  local home="$1"; shift
  mkdir -p "$home/.claude/plugins"
  local entries="[]" e scope proj path ver
  for e in "$@"; do
    IFS='|' read -r scope proj path ver <<< "$e"
    entries="$(jq -c --arg s "$scope" --arg p "$proj" --arg i "$path" --arg v "$ver" \
      '. + [{scope: $s, installPath: $i, version: $v} + (if $p == "" then {} else {projectPath: $p} end)]' <<< "$entries")"
  done
  jq -n --argjson e "$entries" \
    '{version: 2, plugins: {"other@x": [{scope: "user", installPath: "/nowhere", version: "9.9.9"}],
                            "fleet-board@fleet-board": $e}}' > "$home/.claude/plugins/installed_plugins.json"
}

make_repo() { mkdir -p "$1" && git -C "$1" init -q; }

echo "Test: fleet-board command-line launcher"
echo ""

R1="$TMP/roots/0.25.0"; make_root "$R1" 0.25.0
R2="$TMP/roots/0.27.1"; make_root "$R2" 0.27.1
R3="$TMP/roots/0.26.0"; make_root "$R3" 0.26.0
REPO_A="$TMP/work/repo-a"; make_repo "$REPO_A"
REPO_B="$TMP/work/repo-b"; make_repo "$REPO_B"

# --- install-cli.sh --------------------------------------------------------
BIN="$TMP/bin"
out="$(HOME="$TMP/home-none" FLEET_BOARD_BIN_DIR="$BIN" PATH="/usr/bin:/bin" bash "$INSTALL" 2>&1)"; rc=$?
check "install: exits 0" 0 "$rc"
if [ -x "$BIN/fleet-board" ]; then pass "install: launcher is executable in FLEET_BOARD_BIN_DIR"
else fail "install: launcher is executable in FLEET_BOARD_BIN_DIR" "missing $BIN/fleet-board"; fi
contains "install: names where it installed" "$BIN/fleet-board" "$out"
contains "install: tells you to add the directory to PATH when it is missing" "export PATH=\"$BIN:\$PATH\"" "$out"

out="$(FLEET_BOARD_BIN_DIR="$BIN" PATH="$BIN:/usr/bin:/bin" bash "$INSTALL" 2>&1)"; rc=$?
check "install: running it again exits 0" 0 "$rc"
case "$out" in *"export PATH"*) fail "install: no PATH hint when the directory is on PATH" "$out" ;;
  *) pass "install: no PATH hint when the directory is on PATH" ;; esac

FOREIGN="$TMP/bin-foreign"; mkdir -p "$FOREIGN"; printf '#!/bin/sh\necho mine\n' > "$FOREIGN/fleet-board"
out="$(FLEET_BOARD_BIN_DIR="$FOREIGN" bash "$INSTALL" 2>&1)"; rc=$?
check "install: refuses to overwrite a fleet-board file it did not write" 1 "$rc"
check "install: the other file is untouched" "echo mine" "$(sed -n 2p "$FOREIGN/fleet-board")"

out="$(HOME="$TMP/home-default" PATH="/usr/bin:/bin" bash "$INSTALL" 2>&1)"; rc=$?
check "install: defaults to ~/.local/bin" 0 "$rc"
if [ -x "$TMP/home-default/.local/bin/fleet-board" ]; then pass "install: wrote ~/.local/bin/fleet-board"
else fail "install: wrote ~/.local/bin/fleet-board" "$out"; fi

# --- choosing the install --------------------------------------------------
# The newest version whose directory exists wins, wherever it is registered: old
# per-project records can point at versions that predate a script.
H="$TMP/home-1"
make_home "$H" "user||$R1|0.25.0" "project|$REPO_A|$R2|0.27.1"

out="$(cd "$REPO_A" && HOME="$H" bash "$LAUNCHER" board 2>&1)"
check "board: runs the newest install with --repo set to the repo" \
  "board-web.sh 0.27.1 --repo $REPO_A" "$out"

mkdir -p "$REPO_A/sub/dir"
out="$(cd "$REPO_A/sub/dir" && HOME="$H" bash "$LAUNCHER" board --port 9001 2>&1)"
check "board: from a subdirectory, uses the repo root and passes extra arguments" \
  "board-web.sh 0.27.1 --repo $REPO_A --port 9001" "$out"

out="$(cd "$REPO_B" && HOME="$H" bash "$LAUNCHER" board 2>&1)"
check "board: in a repo the newest install was not registered for, still uses the newest" \
  "board-web.sh 0.27.1 --repo $REPO_B" "$out"

H2="$TMP/home-2"
make_home "$H2" "local|/elsewhere|$R3|0.26.0" "project|/other|$TMP/roots/0.30.0|0.30.0" "user||$R1|0.25.0"
out="$(cd "$REPO_B" && HOME="$H2" bash "$LAUNCHER" board 2>&1)"
check "board: skips a newer version whose directory is gone, and beats the user-wide record" \
  "board-web.sh 0.26.0 --repo $REPO_B" "$out"

H3="$TMP/home-3"
make_root "$TMP/roots/0.9.0" 0.9.0
make_root "$TMP/roots/0.10.0" 0.10.0
make_home "$H3" "user||$TMP/roots/0.9.0|0.9.0" "local|/x|$TMP/roots/0.10.0|0.10.0"
out="$(cd "$REPO_B" && HOME="$H3" bash "$LAUNCHER" board 2>&1)"
check "board: version order is numeric, not text (0.10.0 beats 0.9.0)" \
  "board-web.sh 0.10.0 --repo $REPO_B" "$out"

out="$(cd "$REPO_A" && HOME="$H" bash "$LAUNCHER" supervisor start --detach 2>&1)"
check "supervisor: passes its arguments to supervisor.sh" "supervisor.sh 0.27.1 start --detach" "$out"

out="$(cd "$REPO_A" && HOME="$H" bash "$LAUNCHER" path 2>&1)"
check "path: prints the plugin root it would use" "$R2" "$out"

out="$(cd "$REPO_A" && HOME="$H" FLEET_BOARD_PLUGIN_ROOT="$R3" bash "$LAUNCHER" supervisor status 2>&1)"
check "FLEET_BOARD_PLUGIN_ROOT overrides the lookup" "supervisor.sh 0.26.0 status" "$out"

# --- errors ----------------------------------------------------------------
out="$(cd "$REPO_A" && HOME="$TMP/home-none" bash "$LAUNCHER" board 2>&1)"; rc=$?
check "not installed: exits 1" 1 "$rc"
contains "not installed: says how to install" "/plugin install fleet-board@fleet-board" "$out"

NOTREPO="$TMP/plain"; mkdir -p "$NOTREPO"
out="$(cd "$NOTREPO" && HOME="$H" bash "$LAUNCHER" board 2>&1)"; rc=$?
check "board outside a git repository: exits 1" 1 "$rc"
contains "board outside a git repository: says so" "not inside a git repository" "$out"

out="$(HOME="$H" bash "$LAUNCHER" 2>&1)"; rc=$?
check "no subcommand: usage, exit 2" 2 "$rc"
contains "usage names board and supervisor" "fleet-board board" "$out"
out="$(HOME="$H" bash "$LAUNCHER" bogus 2>&1)"; rc=$?
check "unknown subcommand: exit 2" 2 "$rc"
out="$(HOME="$H" bash "$LAUNCHER" --help 2>&1)"; rc=$?
check "--help: exit 0" 0 "$rc"

# --- the installed copy works from anywhere --------------------------------
out="$(cd "$REPO_A" && HOME="$H" "$BIN/fleet-board" board 2>&1)"
check "installed launcher: same result as the plugin copy" "board-web.sh 0.27.1 --repo $REPO_A" "$out"

echo ""
echo "-----------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
