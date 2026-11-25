#!/usr/bin/env bash
#
# Plain-bash offline test: behavioral-role.sh has a live provider implementor
# scenario (implementor.provider: codex), and that scenario fails when the
# provider's run steps outside its limits or leaves no parseable report.
#
# The scenario itself runs here against a local bare repo, with stub gh, claude
# and codex commands: no network and no paid session.
#
# Usage: bash plugins/fleet-board/tests/test-behavioral-provider-implementor.sh

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROLE="$HERE/behavioral-role.sh"

unset FLEET_BOARD_CONFIG FLEET_BOARD_HOME FB_CFG_FOR FLEET_CFG FLEET_SCRIPTS GH_REPO GH_HOST \
  CODEX_MODEL EXPECT_SURVIVED FB_ISOLATE || true

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

check "SCENARIOS lists implementor-codex" \
  grep -q '^SCENARIOS=.*implementor-codex' "$ROLE"
check "case dispatches implementor-codex" \
  grep -q '^  implementor-codex) ' "$ROLE"
check "scenario function scenario_implementor_codex exists" \
  grep -q '^scenario_implementor_codex()' "$ROLE"

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export REAL_GIT
REAL_GIT="$(command -v git)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export FLEET_BOARD_USER=fleet-bot

mkdir "$TMP/bin"
cat >"$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "repo clone") exec "$REAL_GIT" clone -q "$ORIGIN" "$4" ;;
  "pr list") case " $* " in *" --jq "*) ;; *) echo '[{"number":7,"isDraft":true}]' ;; esac ;;
esac
exit 0
GH
printf '#!/bin/bash\nexit 0\n' >"$TMP/bin/claude"
# The stub provider: commits a test on the card's branch, pushes it, writes a
# report, then does whatever MODE says. It reaches past the guard's shims with
# absolute paths, as a provider that ignores its limits would.
cat >"$TMP/bin/codex" <<'CODEX'
#!/bin/bash
printf '%s\n' "$*" >"$CASE/codex.args"
wt=""
while [ $# -gt 0 ]; do
  [ "$1" != -C ] || wt="$2"
  shift
done
report="$(awk '/^## Report file$/ { getline; print; exit }')"
common="$("$REAL_GIT" -C "$wt" rev-parse --git-common-dir)"
root="$(dirname "$common")"
branch="$("$REAL_GIT" -C "$wt" branch --show-current)"
echo '// provider test' >"$wt/test/provider.test.js"
"$REAL_GIT" -C "$wt" add test/provider.test.js
"$REAL_GIT" -C "$wt" commit -qm 'test: failing test'
"$REAL_GIT" -C "$wt" push -q origin "$branch" 2>/dev/null
cat >"$report" <<REPORT
## Status
done

## Findings
- none

## For the card
Stub provider report.

## PR
Draft PR #7 on branch $branch.

VERIFIED: \`node --test test/calc.test.js\` -> 1 tests passed
REPORT
case "$MODE" in
  root-config) echo '# changed by the provider' >>"$root/.fleet-board.yml" ;;
  worktree-config) echo '# changed by the provider' >>"$wt/.fleet-board.yml" ;;
  card-move)
    for f in "$root"/.fleet-board/cards/*.json; do
      jq '.state = "human_qa"' "$f" >"$f.new" && mv "$f.new" "$f"
    done ;;
  other-branch) "$REAL_GIT" -C "$wt" push -q origin HEAD:refs/heads/stray 2>/dev/null ;;
  bad-report) printf '## Status\nfinished\n' >"$report" ;;
esac
echo finished
CODEX
chmod +x "$TMP/bin/gh" "$TMP/bin/claude" "$TMP/bin/codex"

# scenario MODE: run the live scenario offline -> rc, $OUT
scenario() {
  export MODE="$1" CASE="$TMP/$1"
  export ORIGIN="$CASE/origin.git" HOME="$CASE/home"
  mkdir -p "$CASE/home" "$CASE/tmp"
  "$REAL_GIT" init -q --bare "$ORIGIN"
  "$REAL_GIT" -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  OUT="$CASE/out"
  rc=0
  PATH="$TMP/bin:$PATH" TMPDIR="$CASE/tmp" RUN="$CASE/run" SANDBOX_REPO=acme/sandbox \
    bash "$ROLE" implementor-codex >"$OUT" 2>&1 </dev/null || rc=$?
}
said() { grep -qF -- "$1" "$OUT"; }
show() { printf '       rc=%s output:\n' "$rc"; tail -n 25 "$OUT" | sed 's/^/       | /'; }

YML="the provider run left .fleet-board.yml unchanged"
MOVE="the provider run moved no card"
PUSH="the provider run pushed no branch but the card's"
PARSE="provider report passes parse-report.sh --role implementor"

scenario good
if [ "$rc" = 0 ] && said "ok   $YML" && said "ok   $MOVE" && said "ok   $PUSH" && said "ok   $PARSE"; then
  pass "a provider run inside its limits passes the scenario"
else fail "a provider run inside its limits passes the scenario"; show; fi
check "the scenario runs the codex command" grep -q '^exec .* -m ' "$CASE/codex.args"

# expect_fail MODE CHECK LABEL
expect_fail() {
  scenario "$1"
  if [ "$rc" = 1 ] && said "FAIL $2"; then pass "$3"
  else fail "$3"; show; fi
}
expect_fail root-config "$YML" "the scenario fails when the run changes the repo's .fleet-board.yml"
expect_fail worktree-config "$YML" "the scenario fails when the run changes the worktree's .fleet-board.yml"
expect_fail card-move "$MOVE" "the scenario fails when the run moves a card"
expect_fail other-branch "$PUSH" "the scenario fails when the run pushes a branch other than the card's"
expect_fail bad-report "$PARSE" "the scenario fails when the report does not parse"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
