#!/usr/bin/env bash
#
# Plain-bash test: the README's card-writing section states that a whole
# dependency chain can be moved to Ready, and that nothing promotes a Backlog card.
#
# Usage: bash plugins/fleet-board/tests/test-readme-claims.sh
# README_FILE and GATES_FILE override the files checked (used to prove the test can fail).

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
README="${README_FILE:-${SCRIPT_DIR}/../README.md}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "ok" ]; then
    PASS=$((PASS + 1)); echo "ok - $1"
  else
    FAIL=$((FAIL + 1)); echo "not ok - $1"
  fi
}

# The "### Writing a card" section: up to the next heading.
section="$(awk '/^### Writing a card/{f=1;next} f && /^##/{exit} f' "$README")"

r=bad
printf '%s\n' "$section" | grep -qF "Move the whole chain to Ready; each card starts once its dependencies are Done." && r=ok
check "card-writing section says to move the whole chain to Ready" "$r"

r=bad
printf '%s\n' "$section" | grep -E "Backlog.*promotes|promotes.*Backlog" | grep -qi "nothing" && r=ok
check "card-writing section says nothing promotes a Backlog card" "$r"

# The key table has rows for the providers map and a stage's provider key.
r=bad
grep -qE '^\| `providers` \|' "$README" && r=ok
check "key table has a providers row" "$r"

r=bad
grep -qF '| `review.stages[].provider` |' "$README" && r=ok
check "key table has a review.stages[].provider row" "$r"

# The Config section's key table has a row for the review stages list.
r=bad
awk '/^## Config/{f=1;next} f && /^## /{exit} f' "$README" | grep -qF '| `review.stages` |' && r=ok
check "config table has a review.stages row" "$r"

# settle.sh is gone (0.27.0): run by hand beside a running supervisor it moved cards and marked PRs ready
# outside the gate with no run-lock check. The README and gates.md no longer describe it.
DOCS_DIR="${SCRIPT_DIR}/../docs"
GATES="${GATES_FILE:-${DOCS_DIR}/gates.md}"
# The upgrade notes may say it was removed; nothing else in the README names it.
r=bad; awk '/^### Upgrading from an earlier version$/{u=1;next} u && /^#/{u=0} !u' "$README" | grep -q 'settle\.sh' || r=ok
check "README does not mention settle.sh outside its upgrade notes" "$r"
r=bad; grep -q 'settle\.sh' "$GATES" || r=ok
check "gates.md does not mention settle.sh" "$r"

# The README lists the /fleet-board:qa skill.
if grep -qF '/fleet-board:qa' "$README"; then
  PASS=$((PASS + 1)); echo "ok - README lists /fleet-board:qa"
else
  FAIL=$((FAIL + 1)); echo "FAIL - README lists /fleet-board:qa"
fi

# The merger docs: persona,ignore_checks, clearing an attention, and the order of after-merge steps.
CONFIG_MD="${CONFIG_FILE:-${DOCS_DIR}/config.md}"
OVERNIGHT="${OVERNIGHT_FILE:-${DOCS_DIR}/overnight.md}"
r=bad; [ "$(grep -c 'merge\.persona' "$README")" -ge 1 ] && r=ok
check "README mentions merge.persona" "$r"
r=bad; [ "$(grep -c 'merge\.ignore_checks' "$CONFIG_MD")" -ge 1 ] && r=ok
check "config.md mentions merge.ignore_checks" "$r"
r=bad; grep -qF '"merger": null' "$README" && r=ok
check "README has the attention-clearing step with \"merger\": null" "$r"
r=bad; grep -qF 'steps run before the merger' "$OVERNIGHT" && r=ok
check "overnight.md says the after-merge steps run before the merger" "$r"

# The local-board spec's adapter table: comment removes the active marker only for a validated role report.
SPEC="${SPEC_FILE:-${SCRIPT_DIR}/../../../docs/specs/2026-11-06-local-board-design.md}"
r=bad
grep -E '^\| `comment <n> <body-file>` \|' "$SPEC" | grep -qF 'removes `active/<n>` only for a validated role report' && r=ok
check "spec comment row says the marker is removed only for a validated role report" "$r"

# The CLI supervisor design lives at docs/specs/ and is the path the plugin docs name.
REPO_ROOT="${SCRIPT_DIR}/../../.."
CLI_SPEC="docs/specs/2026-11-11-cli-supervisor-design.md"
for doc in "${SCRIPT_DIR}/../CLAUDE.md" "${SCRIPT_DIR}/../docs/overnight.md"; do
  if [ -f "${REPO_ROOT}/${CLI_SPEC}" ] && grep -qF "$CLI_SPEC" "$doc"; then
    PASS=$((PASS + 1)); echo "ok - $(basename "$doc") names the existing spec $CLI_SPEC"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $(basename "$doc") names the existing spec $CLI_SPEC"
  fi
done

# board.terminal_command and the Open terminal link are documented.
r=bad; grep -qF '`board.terminal_command`' "$CONFIG_MD" && grep -qF '["open", "-a", "Terminal", "{dir}"]' "$CONFIG_MD" && r=ok
check "config.md lists board.terminal_command with its default [\"open\", \"-a\", \"Terminal\", \"{dir}\"]" "$r"
r=bad; grep -qF '["open", "-a", "iTerm", "{dir}"]' "$CONFIG_MD" && r=ok
check "config.md has an iTerm example [\"open\", \"-a\", \"iTerm\", \"{dir}\"]" "$r"
r=bad; grep -qF '| `board.terminal_command` |' "$README" && grep -qF 'Open terminal' "$README" && r=ok
check "README lists board.terminal_command and the Open terminal link" "$r"

# The overrides must work: a copy without the chain sentence, or one naming settle.sh, must fail.
if [ -z "${README_CLAIMS_NESTED:-}" ]; then
  tmp="$(mktemp -d)"
  sed 's/Move the whole chain to Ready/Move it/' "$README" > "$tmp/README_FILE.md"
  { cat "$GATES"; printf '\n`scripts/settle.sh` moves cards.\n'; } > "$tmp/GATES_FILE.md"
  for var in README_FILE GATES_FILE; do
    r=bad
    if ! env README_CLAIMS_NESTED=1 "$var=$tmp/$var.md" bash "${BASH_SOURCE[0]:-$0}" >/dev/null 2>&1; then r=ok; fi
    check "$var pointing at a broken copy makes the test fail" "$r"
  done
  rm -rf "$tmp"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
