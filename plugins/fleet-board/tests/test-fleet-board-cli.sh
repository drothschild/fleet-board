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
unset FLEET_BOARD_PLUGIN_ROOT FLEET_BOARD_BIN_DIR CLAUDE_CONFIG_DIR FLEET_BOARD_LAUNCHER_HANDOFF || true

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

# A fake plugin root whose scripts record how they were called. FAKE_EXIT sets
# their exit code; FAKE_PWD=1 also prints the directory they ran in.
make_root() { # make_root DIR VERSION [SCRIPT...]  (default: board-web.sh supervisor.sh install-cli.sh)
  local dir="$1" ver="$2" s; shift 2
  [ $# -gt 0 ] || set -- board-web.sh supervisor.sh install-cli.sh
  mkdir -p "$dir/scripts"
  for s in "$@"; do
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s %s %%s\\n" "%s" "$*"\n' "$ver" "$s"
      printf '[ -z "${FAKE_PWD:-}" ] || printf "pwd %%s\\n" "$(pwd -P)"\n'
      printf 'exit "${FAKE_EXIT:-0}"\n'; } > "$dir/scripts/$s"
  done
}

# A registry listing fleet-board installs. Each extra argument is
# SCOPE|PROJECTPATH|INSTALLPATH|VERSION; a VERSION of "-" leaves the key out.
make_registry() { # make_registry FILE ENTRY...
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  local entries="[]" e scope proj path ver
  for e in "$@"; do
    IFS='|' read -r scope proj path ver <<< "$e"
    entries="$(jq -c --arg s "$scope" --arg p "$proj" --arg i "$path" --arg v "$ver" \
      '. + [{scope: $s, installPath: $i} + (if $v == "-" then {} else {version: $v} end)
             + (if $p == "" then {} else {projectPath: $p} end)]' <<< "$entries")"
  done
  jq -n --argjson e "$entries" \
    '{version: 2, plugins: {"other@x": [{scope: "user", installPath: "/nowhere", version: "9.9.9"}],
                            "fleet-board@fleet-board": $e}}' > "$file"
}
# A fake HOME whose ~/.claude holds that registry.
make_home() { # make_home DIR ENTRY...
  local home="$1"; shift
  make_registry "$home/.claude/plugins/installed_plugins.json" "$@"
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

# --- CLAUDE_CONFIG_DIR -----------------------------------------------------
CC="$TMP/claude-config"
make_registry "$CC/plugins/installed_plugins.json" "user||$R3|0.26.0"
out="$(cd "$REPO_A" && HOME="$H" CLAUDE_CONFIG_DIR="$CC" bash "$LAUNCHER" board 2>&1)"
check "CLAUDE_CONFIG_DIR: reads its installed_plugins.json instead of ~/.claude's" \
  "board-web.sh 0.26.0 --repo $REPO_A" "$out"

# --- exit codes pass through -----------------------------------------------
(cd "$REPO_A" && HOME="$H" FAKE_EXIT=7 bash "$LAUNCHER" board >/dev/null 2>&1); rc=$?
check "board: returns board-web.sh's exit code" 7 "$rc"
(cd "$REPO_A" && HOME="$H" FAKE_EXIT=7 bash "$LAUNCHER" supervisor status >/dev/null 2>&1); rc=$?
check "supervisor: returns supervisor.sh's exit code" 7 "$rc"

# --- a per-project pin is reported, not silently ignored -------------------
NOTICE="fleet-board: using 0.27.1 ($R2); this repo is registered at 0.25.0 — set FLEET_BOARD_PLUGIN_ROOT to pin it"
H4="$TMP/home-4"
make_home "$H4" "user||$R2|0.27.1" "project|$REPO_A|$R1|0.25.0"
err="$(cd "$REPO_A/sub/dir" && HOME="$H4" bash "$LAUNCHER" board 2>&1 >/dev/null)"
check "pin: a project record at another version prints one notice on stderr" "$NOTICE" "$err"
out="$(cd "$REPO_A/sub/dir" && HOME="$H4" bash "$LAUNCHER" board 2>/dev/null)"
check "pin: stdout is unchanged (the newest install still runs)" "board-web.sh 0.27.1 --repo $REPO_A" "$out"
H4L="$TMP/home-4l"
make_home "$H4L" "user||$R2|0.27.1" "local|$REPO_A|$R1|0.25.0"
err="$(cd "$REPO_A" && HOME="$H4L" bash "$LAUNCHER" supervisor status 2>&1 >/dev/null)"
check "pin: a local record is reported too" "$NOTICE" "$err"
err="$(cd "$REPO_B" && HOME="$H4" bash "$LAUNCHER" board 2>&1 >/dev/null)"
check "pin: no notice in a repo with no record" "" "$err"
err="$(cd "$REPO_A" && HOME="$H" bash "$LAUNCHER" board 2>&1 >/dev/null)"
check "pin: no notice when the repo is registered at the version chosen" "" "$err"

# --- each subcommand needs its own script ----------------------------------
R4="$TMP/roots/0.28.0"; make_root "$R4" 0.28.0 supervisor.sh
H5="$TMP/home-5"
make_home "$H5" "user||$R2|0.27.1" "user||$R4|0.28.0"
out="$(cd "$REPO_B" && HOME="$H5" bash "$LAUNCHER" board 2>&1)"
check "board: skips a newer install that has no board-web.sh" "board-web.sh 0.27.1 --repo $REPO_B" "$out"
out="$(cd "$REPO_B" && HOME="$H5" bash "$LAUNCHER" supervisor status 2>&1)"
check "supervisor: uses the newest install that has supervisor.sh" "supervisor.sh 0.28.0 status" "$out"
H6="$TMP/home-6"
make_home "$H6" "user||$R4|0.28.0"
out="$(cd "$REPO_B" && HOME="$H6" bash "$LAUNCHER" board 2>&1)"; rc=$?
check "no install has the script: exits 1" 1 "$rc"
check "no install has the script: says which and what to do" \
  "fleet-board: no installed fleet-board version has board-web.sh; update the plugin" "$out"

# --- prerelease versions sort below their release --------------------------
RB="$TMP/roots/0.27.1-beta"; make_root "$RB" 0.27.1-beta
RN="$TMP/roots/0.28.0-rc.1"; make_root "$RN" 0.28.0-rc.1
H7="$TMP/home-7"
make_home "$H7" "user||$R2|0.27.1" "user||$RB|0.27.1-beta"
out="$(cd "$REPO_B" && HOME="$H7" bash "$LAUNCHER" path 2>&1)"
check "version order: 0.27.1 beats 0.27.1-beta (release listed first)" "$R2" "$out"
make_home "$H7" "user||$RB|0.27.1-beta" "user||$R2|0.27.1"
out="$(cd "$REPO_B" && HOME="$H7" bash "$LAUNCHER" path 2>&1)"
check "version order: 0.27.1 beats 0.27.1-beta (prerelease listed first)" "$R2" "$out"
make_home "$H7" "user||$R2|0.27.1" "user||$RN|0.28.0-rc.1"
out="$(cd "$REPO_B" && HOME="$H7" bash "$LAUNCHER" path 2>&1)"
check "version order: 0.28.0-rc.1 beats 0.27.1" "$RN" "$out"

# --- a bad registry is an error, not "not installed" -----------------------
H8="$TMP/home-8"; mkdir -p "$H8/.claude/plugins"
printf '{"plugins": [not json\n' > "$H8/.claude/plugins/installed_plugins.json"
out="$(cd "$REPO_B" && HOME="$H8" bash "$LAUNCHER" board 2>&1)"; rc=$?
check "bad registry: exits 1" 1 "$rc"
check "bad registry: says it cannot read it" \
  "fleet-board: cannot read $H8/.claude/plugins/installed_plugins.json" "$out"

# --- supervisor runs from the main checkout --------------------------------
REPO_C="$TMP/work/repo-c"; make_repo "$REPO_C"
git -C "$REPO_C" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty --no-verify -m init
git -C "$REPO_C" worktree add -q -b side "$TMP/work/wt-c" 2>/dev/null
mkdir -p "$TMP/work/wt-c/deep"
out="$(cd "$TMP/work/wt-c/deep" && HOME="$H" FAKE_PWD=1 bash "$LAUNCHER" supervisor status 2>&1)"
check "supervisor: from a linked worktree, runs in the main checkout" \
  "supervisor.sh 0.27.1 status
pwd $REPO_C" "$out"
mkdir -p "$REPO_C/sub"
out="$(cd "$REPO_C/sub" && HOME="$H" FAKE_PWD=1 bash "$LAUNCHER" supervisor status 2>&1)"
check "supervisor: from a subdirectory, runs at the repo root" \
  "supervisor.sh 0.27.1 status
pwd $REPO_C" "$out"
out="$(cd "$NOTREPO" && HOME="$H" FAKE_PWD=1 bash "$LAUNCHER" supervisor status 2>&1)"
check "supervisor: outside a repository, runs where you are" \
  "supervisor.sh 0.27.1 status
pwd $NOTREPO" "$out"

# --- installer: PATH hints and destinations --------------------------------
B2="$TMP/bin-slash"
out="$(FLEET_BOARD_BIN_DIR="$B2/" PATH="$B2:/usr/bin:/bin" bash "$INSTALL" 2>&1)"; rc=$?
check "install: trailing slash in FLEET_BOARD_BIN_DIR exits 0" 0 "$rc"
check "install: trailing slash in FLEET_BOARD_BIN_DIR, no PATH hint and no //" "installed: $B2/fleet-board" "$out"
B3="$TMP/bin-pathslash"
out="$(FLEET_BOARD_BIN_DIR="$B3" PATH="/usr/bin:$B3/:/bin" bash "$INSTALL" 2>&1)"
check "install: a trailing slash on the PATH entry still counts as on PATH" "installed: $B3/fleet-board" "$out"
HT="$TMP/home-tilde"
out="$(HOME="$HT" PATH="/usr/bin:/bin:~/.local/bin" bash "$INSTALL" 2>&1)"
check "install: a ~ PATH entry counts as on PATH" "installed: $HT/.local/bin/fleet-board" "$out"

B4="$TMP/bin-dangling"; mkdir -p "$B4"; ln -s "$TMP/no-such-file" "$B4/fleet-board"
out="$(FLEET_BOARD_BIN_DIR="$B4" PATH="$B4:/usr/bin:/bin" bash "$INSTALL" 2>&1)"; rc=$?
check "install: refuses a dangling symlink at the destination" 1 "$rc"
contains "install: says the destination is a symlink" "$B4/fleet-board is a symbolic link" "$out"
if [ -L "$B4/fleet-board" ] && [ "$(readlink "$B4/fleet-board")" = "$TMP/no-such-file" ] && [ ! -e "$TMP/no-such-file" ]; then
  pass "install: the symlink is untouched and nothing was written through it"
else fail "install: the symlink is untouched and nothing was written through it" "$(ls -l "$B4")"; fi

# --- installed copies hand off to the plugin's launcher --------------------
# The plugin root holds a newer launcher that announces itself: the old copy in
# $BIN runs it, once, with the root passed through.
RH="$TMP/roots/0.29.0"; make_root "$RH" 0.29.0
awk '{print} /^unset CDPATH$/ && !d {print "printf \"handoff %s %s\\n\" \"${FLEET_BOARD_LAUNCHER_HANDOFF:-}\" \"${FLEET_BOARD_PLUGIN_ROOT:-}\" >&2"; d=1}' \
  "$LAUNCHER" > "$RH/scripts/fleet-board"
H9="$TMP/home-9"
make_home "$H9" "user||$R2|0.27.1" "user||$RH|0.29.0"
out="$(cd "$REPO_A" && HOME="$H9" "$BIN/fleet-board" board --port 9 2>&1)"
check "handoff: an old copy runs the plugin's launcher once, with the root passed privately" \
  "handoff $RH 
board-web.sh 0.29.0 --repo $REPO_A --port 9" "$out"
out="$(cd "$REPO_A" && HOME="$H9" FLEET_BOARD_LAUNCHER_HANDOFF="$RH" "$BIN/fleet-board" board 2>&1)"
check "handoff: never repeats once FLEET_BOARD_LAUNCHER_HANDOFF names a root" \
  "board-web.sh 0.29.0 --repo $REPO_A" "$out"

# Nothing the launcher starts inherits the handoff: board-web.sh and supervisor.sh
# (and every agent session a supervisor starts) see neither variable.
RL="$TMP/roots/0.31.0"; mkdir -p "$RL/scripts"
for s in board-web.sh supervisor.sh; do
  printf '#!/usr/bin/env bash\nprintf "%s env %%s %%s\\n" "${FLEET_BOARD_LAUNCHER_HANDOFF:-none}" "${FLEET_BOARD_PLUGIN_ROOT:-none}"\n' "$s" > "$RL/scripts/$s"
done
{ cat "$LAUNCHER"; printf '# a newer launcher\n'; } > "$RL/scripts/fleet-board"
H10="$TMP/home-10"; make_home "$H10" "user||$RL|0.31.0"
out="$(cd "$REPO_A" && HOME="$H10" "$BIN/fleet-board" board 2>&1)"
check "handoff: board-web.sh inherits neither FLEET_BOARD_LAUNCHER_HANDOFF nor FLEET_BOARD_PLUGIN_ROOT" \
  "board-web.sh env none none" "$out"
out="$(cd "$REPO_A" && HOME="$H10" "$BIN/fleet-board" supervisor status 2>&1)"
check "handoff: supervisor.sh inherits neither variable" "supervisor.sh env none none" "$out"
cp "$LAUNCHER" "$R2/scripts/fleet-board"
out="$(cd "$REPO_A" && HOME="$H" "$BIN/fleet-board" board 2>&1)"
check "handoff: none when the plugin's launcher is the same file" "board-web.sh 0.27.1 --repo $REPO_A" "$out"
rm -f "$R2/scripts/fleet-board"

# --- the installed copy works from anywhere --------------------------------
out="$(cd "$REPO_A" && HOME="$H" "$BIN/fleet-board" board 2>&1)"
check "installed launcher: same result as the plugin copy" "board-web.sh 0.27.1 --repo $REPO_A" "$out"

# --- the README's install one-liner ----------------------------------------
# Every copy sits between <!-- install-cli-command --> and <!-- /install-cli-command -->.
README="$SCRIPT_DIR/../../../README.md"
blocks="$(awk '/<!-- install-cli-command -->/{f=1;next} /<!-- \/install-cli-command -->/{f=0;print "@@";next}
               f && !/^ *```/ {sub(/^ +/, ""); print}' "$README")"
n_blocks="$(printf '%s\n' "$blocks" | grep -c '^@@$')"
if [ "$n_blocks" -ge 2 ]; then pass "README: the install one-liner appears in setup and in Run it ($n_blocks copies)"
else fail "README: the install one-liner appears in setup and in Run it ($n_blocks copies)" "$blocks"; fi
README_CMD="$(printf '%s\n' "$blocks" | awk '/^@@$/{exit} {print}')"
check "README: the one-liner is one line" 1 "$(printf '%s\n' "$README_CMD" | grep -c .)"
check "README: every copy is the same command" 1 "$(printf '%s\n' "$blocks" | grep -v '^@@$' | sort -u | grep -c .)"

run_readme() { # run_readme CLAUDE_CONFIG_DIR: the README command, in a temporary HOME
  (cd "$TMP" && HOME="$TMP/readme-home" CLAUDE_CONFIG_DIR="$1" FLEET_BOARD_BIN_DIR="$TMP/readme-bin" \
    bash -c "$README_CMD" 2>&1)
}
RC1="$TMP/readme-cc-none"; mkdir -p "$RC1"
out="$(run_readme "$RC1")"; rc=$?
check "README one-liner, no registry: says fleet-board is not installed" \
  "fleet-board is not installed; run /plugin install fleet-board@fleet-board" "$out"
check "README one-liner, no registry: exits non-zero" 1 "$rc"
RC2="$TMP/readme-cc-nover"
make_registry "$RC2/plugins/installed_plugins.json" "user||$R1|-"
out="$(run_readme "$RC2")"
check "README one-liner, an entry with no version: not installed" \
  "fleet-board is not installed; run /plugin install fleet-board@fleet-board" "$out"
RC3="$TMP/readme-cc-gone"
make_registry "$RC3/plugins/installed_plugins.json" "user||$R1|0.25.0" "project|/x|$TMP/roots/gone|0.40.0"
out="$(run_readme "$RC3")"
check "README one-liner, newest directory gone: runs the newest that exists" "install-cli.sh 0.25.0 " "$out"
RC4="$TMP/readme-cc-ok"
make_registry "$RC4/plugins/installed_plugins.json" "user||$TMP/roots/0.9.0|0.9.0" "user||$R2|0.27.1" \
  "user||$RB|0.27.1-beta" "local|/x|$TMP/roots/0.10.0|0.10.0"
make_root "$TMP/roots/0.9.0" 0.9.0; make_root "$TMP/roots/0.10.0" 0.10.0
out="$(run_readme "$RC4")"; rc=$?
check "README one-liner: runs the newest install's install-cli.sh (0.27.1 over -beta and 0.10.0)" "install-cli.sh 0.27.1 " "$out"
check "README one-liner: exits with the installer's code" 0 "$rc"
RC5="$TMP/readme-cc-object"; mkdir -p "$RC5/plugins"
jq -n --arg i "$R3" '{version: 2, plugins: {"fleet-board@fleet-board": {scope: "user", installPath: $i, version: "0.26.0"}}}' \
  > "$RC5/plugins/installed_plugins.json"
out="$(run_readme "$RC5")"
check "README one-liner: accepts the plugin value as an object" "install-cli.sh 0.26.0 " "$out"
if command -v zsh >/dev/null 2>&1; then
  out="$(cd "$TMP" && HOME="$TMP/readme-home" CLAUDE_CONFIG_DIR="$RC4" FLEET_BOARD_BIN_DIR="$TMP/readme-bin" \
    zsh -fc "$README_CMD; echo still-here" 2>&1)"
  check "README one-liner under zsh: same result, and the shell survives" "install-cli.sh 0.27.1 
still-here" "$out"
fi

# --- up: starts the supervisor, then serves the board ----------------------
# A fake root: supervisor.sh records "start" in $UP_STATE and answers status from
# that record; board-web.sh serves GET /api/board with 200 on its --port.
RU="$TMP/roots/0.40.0"; mkdir -p "$RU/scripts"
cat > "$RU/scripts/supervisor.sh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  start) printf '%s\n' "$*" >> "$UP_STATE/supervisor-calls"; touch "$UP_STATE/started"; exit 0 ;;
  status) [ -f "$UP_STATE/started" ]; exit $? ;;
esac
exit 0
EOS
cat > "$RU/scripts/board-web.sh" <<'EOS'
#!/usr/bin/env bash
port=""; while [ $# -gt 0 ]; do case "$1" in --port) port="$2"; shift 2 ;; *) shift ;; esac; done
exec python3 -c '
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/api/board" else 404); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "${port:-8765}"
EOS
HU="$TMP/home-up"; make_home "$HU" "user||$RU|0.40.0"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
wait_port() { local i; for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$1/api/board" && return 0; sleep 0.1; done; return 1; }

REPO_UP="$TMP/work/repo-up"; make_repo "$REPO_UP"
UP_STATE="$TMP/up-state"; mkdir -p "$UP_STATE"
PORT_UP="$(free_port)"
(cd "$REPO_UP" && HOME="$HU" UP_STATE="$UP_STATE" bash "$LAUNCHER" up --port "$PORT_UP" >/dev/null 2>&1) &
UP_PID=$!
wait_port "$PORT_UP"; up_ready=$?
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_UP/api/board")"
check "up --port N: serves on port N (GET /api/board returns 200)" 200 "$code"
(cd "$REPO_UP" && HOME="$HU" UP_STATE="$UP_STATE" bash "$RU/scripts/supervisor.sh" status >/dev/null 2>&1); rc=$?
check "up: the supervisor is running in the background while up runs (status exits 0)" 0 "$rc"
check "up: started the supervisor detached" "start --detach" "$(cat "$UP_STATE/supervisor-calls" 2>/dev/null)"
pkill -P "$UP_PID" 2>/dev/null; kill "$UP_PID" 2>/dev/null; wait "$UP_PID" 2>/dev/null

UP_STATE2="$TMP/up-state2"; mkdir -p "$UP_STATE2"
out="$(cd "$NOTREPO" && HOME="$HU" UP_STATE="$UP_STATE2" bash "$LAUNCHER" up 2>&1)"; rc=$?
check "up outside a git repository: exits 1" 1 "$rc"
contains "up outside a git repository: says so" "not inside a git repository" "$out"
if [ -e "$UP_STATE2/started" ]; then fail "up outside a git repository: starts no supervisor" "supervisor was started"
else pass "up outside a git repository: starts no supervisor"; fi

# --- up: reuses a supervisor that is already running -----------------------
# This fake behaves like the real one: start exits 1 "supervisor already running"
# when a pid is recorded; status answers from the same record.
RR="$TMP/roots/0.41.0"; mkdir -p "$RR/scripts"
cp "$RU/scripts/board-web.sh" "$RR/scripts/board-web.sh"
cat > "$RR/scripts/supervisor.sh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  start)
    printf '%s\n' "$*" >> "$UP_STATE/supervisor-calls"
    if [ -f "$UP_STATE/pid" ]; then echo "supervisor already running (pid $(cat "$UP_STATE/pid"))" >&2; exit 1; fi
    echo 4242 > "$UP_STATE/pid"; exit 0 ;;
  status) [ -f "$UP_STATE/pid" ]; exit $? ;;
esac
exit 0
EOS
HR="$TMP/home-reuse"; make_home "$HR" "user||$RR|0.41.0"
REPO_RE="$TMP/work/repo-reuse"; make_repo "$REPO_RE"
RE_STATE="$TMP/re-state"; mkdir -p "$RE_STATE"; echo 4242 > "$RE_STATE/pid"
PORT_RE="$(free_port)"
(cd "$REPO_RE" && HOME="$HR" UP_STATE="$RE_STATE" bash "$LAUNCHER" up --port "$PORT_RE" >/dev/null 2>&1) &
RE_PID=$!
wait_port "$PORT_RE"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_RE/api/board")"
check "up with a supervisor already running: serves the board (GET /api/board returns 200)" 200 "$code"
check "up with a supervisor already running: the supervisor's pid is unchanged" 4242 "$(cat "$RE_STATE/pid")"
check "up with a supervisor already running: starts no second supervisor (pid file written once)" 1 "$(grep -c . "$RE_STATE/pid")"
pkill -P "$RE_PID" 2>/dev/null; kill "$RE_PID" 2>/dev/null; wait "$RE_PID" 2>/dev/null

# --- up: a supervisor refused for stuck cards (exit 4) still opens the board ---
RS="$TMP/roots/0.42.0"; mkdir -p "$RS/scripts"
cp "$RU/scripts/board-web.sh" "$RS/scripts/board-web.sh"
cat > "$RS/scripts/supervisor.sh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  start) exit 4 ;;
  status) exit 1 ;;
esac
exit 0
EOS
HS="$TMP/home-stuck"; make_home "$HS" "user||$RS|0.42.0"
REPO_ST="$TMP/work/repo-stuck"; make_repo "$REPO_ST"
PORT_ST="$(free_port)"
ST_ERR="$TMP/stuck-stderr"
(cd "$REPO_ST" && HOME="$HS" bash "$LAUNCHER" up --port "$PORT_ST" >/dev/null 2>"$ST_ERR") &
ST_PID=$!
wait_port "$PORT_ST"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT_ST/api/board")"
check "up with stuck cards (exit 4): the board is still served (GET /api/board returns 200)" 200 "$code"
check "up with stuck cards (exit 4): prints exactly one stderr line" 1 "$(grep -c . "$ST_ERR")"
contains "up with stuck cards (exit 4): the stderr line names fleet-board supervisor stuck" "fleet-board supervisor stuck" "$(cat "$ST_ERR")"
pkill -P "$ST_PID" 2>/dev/null; kill "$ST_PID" 2>/dev/null; wait "$ST_PID" 2>/dev/null

echo ""
echo "-----------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
