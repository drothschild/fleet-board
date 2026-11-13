#!/usr/bin/env bash
#
# Behavioral scenarios for the documentation reviewer agent. NOT an offline
# suite: it drives real headless Claude sessions (API spend) against a throwaway
# fixture repo, and checks the reports they leave with parse-report.sh
# --role stage-reviewer. Skipped (exit 0, says so) unless FB_BEHAVIORAL=1.
#
# Scenarios (both run):
#   stale    a PR changes a config key and leaves its docs alone: the report is
#            accepted, has Status findings and names the docs file
#   updated  a PR changes the same key and updates its docs: Status clean
#
# Env: FB_BEHAVIORAL=1 to run; FB_ISOLATE_SETTINGS (auth settings, default
# ~/.config/fleet-board/bare-settings.json); BL_MODEL (default sonnet);
# BL_MAX_TURNS (default 40); BL_NO_BARE=1 runs with the caller's own login
# instead of the isolated --bare session; BL_KEEP=1 keeps the work dir.
#
# Usage: FB_BEHAVIORAL=1 bash plugins/fleet-board/tests/test-documentation-reviewer-behavior.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
AGENT="$PLUGIN_DIR/agents/documentation-reviewer.md"
SETTINGS="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"
MODEL="${BL_MODEL:-sonnet}"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

if [ "${FB_BEHAVIORAL:-}" != "1" ]; then
  echo "skip: set FB_BEHAVIORAL=1 to run the documentation reviewer behavioral scenarios (API spend)"
  exit 0
fi

if [ ! -f "$AGENT" ]; then
  fail "agents/documentation-reviewer.md exists"
  printf '%s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

WORK="$(mktemp -d)"
trap '[ -n "${BL_KEEP:-}" ] && echo "kept: $WORK" || rm -rf "$WORK"' EXIT

# Stub scripts dir: the real parse-report.sh, a board-comment.sh that saves the
# report instead of posting it.
STUBS="$WORK/scripts"
mkdir -p "$STUBS"
cp "$SCRIPTS/parse-report.sh" "$STUBS/parse-report.sh"
cat >"$STUBS/board-comment.sh" <<'EOF'
#!/usr/bin/env bash
cp "$2" "${POSTED_REPORT:?}"
EOF
chmod +x "$STUBS"/*.sh

# make_repo DIR UPDATE_DOCS: a repo whose PR head changes the config default
# retry_limit from 3 to 5, and (UPDATE_DOCS=1) the documented default too.
make_repo() {
  local d="$1" upd="$2"
  mkdir -p "$d/src" "$d/docs"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  printf 'retry_limit: 3\ntimeout_seconds: 30\n' >"$d/src/defaults.yml"
  printf '# Configuration\n\n## retry_limit\n\nHow many times a failed job is retried. Default: 3.\n\n## timeout_seconds\n\nSeconds before a job is abandoned. Default: 30.\n' >"$d/docs/config.md"
  git -C "$d" add -A
  git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b pr
  printf 'retry_limit: 5\ntimeout_seconds: 30\n' >"$d/src/defaults.yml"
  if [ "$upd" = 1 ]; then
    sed -i.bak 's/retried. Default: 3./retried. Default: 5./' "$d/docs/config.md"
    rm -f "$d/docs/config.md.bak"
  fi
  git -C "$d" add -A
  git -C "$d" commit -q -m "Raise the default retry_limit to 5"
}

# run_scenario NAME UPDATE_DOCS: runs the agent, sets REPORT to the posted file.
run_scenario() {
  local name="$1" upd="$2" repo="$WORK/$1-repo"
  make_repo "$repo" "$upd"
  REPORT="$WORK/$name-report.md"
  git -C "$repo" diff main pr >"$WORK/$name.diff"
  local body="$WORK/$name-agent.md"
  awk 'BEGIN{c=0} /^---$/ {c++; next} c>=2 {print}' "$AGENT" >"$body"
  cat >"$WORK/$name-prompt.md" <<EOF
Card number: 1
Card body:
## Why
Raise the default retry limit.
## Acceptance
- The default retry_limit is 5.

PR number: 1
PR diff:
$(cat "$WORK/$name.diff")

Latest implementor report: (none)
Review worktree path: $repo (checked out at the PR head)
Config JSON: {"test_paths": [], "commands": {}}
Stage name: documentation
Stage brief: Check that the PR keeps the documentation in step with the change.
Round: 1
prev_sha: (none)
Scripts directory: $STUBS
EOF
  (
    cd "$repo" || exit 1
    if [ "${BL_NO_BARE:-}" = 1 ]; then ISO=(); else ISO=(--bare --settings "$SETTINGS"); export CLAUDE_CONFIG_DIR="$(mktemp -d)"; fi
    POSTED_REPORT="$REPORT" claude -p ${ISO[@]+"${ISO[@]}"} \
      --model "$MODEL" \
      --tools "Read,Write,Bash,Grep,Glob" --permission-mode bypassPermissions \
      --add-dir "$WORK" --max-turns "${BL_MAX_TURNS:-40}" \
      --append-system-prompt-file "$body" \
      "$(cat "$WORK/$name-prompt.md")" >"$WORK/$name.log" 2>&1
  )
}

echo "stale: a PR that changes a config key without updating its docs"
run_scenario stale 0
if [ -s "$REPORT" ]; then pass "stale: a report was posted"; else fail "stale: a report was posted"; fi
if [ -s "$REPORT" ] && bash "$SCRIPTS/parse-report.sh" --role stage-reviewer "$REPORT" >/dev/null 2>&1; then
  pass "stale: parse-report.sh --role stage-reviewer accepts the report"
else
  fail "stale: parse-report.sh --role stage-reviewer accepts the report"
fi
if [ -s "$REPORT" ] && [ "$(awk '/^## Status/{getline; while($0==""){getline}; print; exit}' "$REPORT")" = "findings" ]; then
  pass "stale: Status is findings"
else
  fail "stale: Status is findings"
fi
if [ -s "$REPORT" ] && awk '/^## Findings/{f=1; next} /^## /{f=0} f' "$REPORT" | grep -q 'docs/config.md'; then
  pass "stale: a finding names docs/config.md"
else
  fail "stale: a finding names docs/config.md"
fi

echo "updated: a PR that changes a config key and updates its docs"
run_scenario updated 1
if [ -s "$REPORT" ]; then pass "updated: a report was posted"; else fail "updated: a report was posted"; fi
if [ -s "$REPORT" ] && bash "$SCRIPTS/parse-report.sh" --role stage-reviewer "$REPORT" >/dev/null 2>&1; then
  pass "updated: parse-report.sh --role stage-reviewer accepts the report"
else
  fail "updated: parse-report.sh --role stage-reviewer accepts the report"
fi
if [ -s "$REPORT" ] && [ "$(awk '/^## Status/{getline; while($0==""){getline}; print; exit}' "$REPORT")" = "clean" ]; then
  pass "updated: Status is clean"
else
  fail "updated: Status is clean"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
