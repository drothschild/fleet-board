#!/usr/bin/env bash
# Card 115: rules that PRs added to clean-room files by hand must also be in their specs, so a full
# regeneration from the spec keeps them. Checks specs/manager.md (and agents/manager.md), specs/status.md
# (and skills/status/SKILL.md), the Revision 14 audit record, and the version bump.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/.."
SPECS="${SPECS_DIR:-$PLUGIN/../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

# line_has LABEL FILE LINE_PATTERN NEEDLE: a line matching LINE_PATTERN also holds NEEDLE.
line_has() {
  if grep -E -e "$3" "$2" | grep -qF -e "$4"; then ok "$1"; else bad "$1"; fi
}
# has LABEL FILE NEEDLE: some line holds NEEDLE.
has() {
  if grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; fi
}
# lacks LABEL FILE NEEDLE: no line holds NEEDLE.
lacks() {
  if grep -qF -e "$3" "$2"; then bad "$1"; else ok "$1"; fi
}

manager_rules() {
  local who="$1" f="$2"
  line_has "$who: adversarial review before merge is a standing rule" "$f" '^0\.[0-9]+\. ' 'adversarial'
  line_has "$who: the standing rule says never skip it and names gh pr merge" "$f" 'dversarial' 'gh pr merge'
  line_has "$who: re-fetch the remote before acting on PR state" "$f" '^0\.[0-9]+\. ' 'the remote before acting on PR state'
  line_has "$who: roles have no Skill tool" "$f" '^0\.15\. ' 'Roles have no `Skill` tool'
  line_has "$who: to_human_qa runs human-qa-handoff.sh" "$f" '^\| `to_human_qa` ' 'human-qa-handoff.sh [--qa-summary <file>] N <pr>'
  has "$who: qa_build summary goes to a temp file passed as --qa-summary" "$f" 'it as `--qa-summary <file>`'
  has "$who: human-qa-handoff.sh lists the pre-merge steps and the Human QA bullets" "$f" 'each bullet of the card'"'"'s `## Human QA` section'
  line_has "$who: skip_card_lint row starts with the lint_marker" "$f" '^\| `skip_card_lint` ' 'lint_marker'
  line_has "$who: skip_card_lint row lists each lint line" "$f" '^\| `skip_card_lint` ' '`<rule>: <detail>`'
  line_has "$who: 2.17a skip_card_lint comments once per distinct lint result" "$f" '^2\.17a\. ' 'a changed result (a new marker) posts a new comment'
  line_has "$who: skip_card_lint progress in 2.C.3" "$f" '^ +- `skip_card_lint`: ' 'the comment was posted, or none was needed'
  line_has "$who: wait row comments on a ready card's unmet dependencies" "$f" '^\| `wait` ' 'Waiting for <waiting_on, joined with ", ">'
  line_has "$who: wait row records deps_commented only after the comment posts" "$f" '^\| `wait` ' '`deps_commented` = `waiting_on`'
  line_has "$who: 4.4 excepts the deps_commented write" "$f" '^4\.4\. ' '`deps_commented` write for a `ready` card'"'"'s `wait`'
  line_has "$who: finish runs after-merge.sh run first" "$f" '^2\.15\. ' 'after-merge.sh run <body-file>'
  has "$who: finish records after_merge in the note" "$f" '`after_merge` = the printed `note` lines'
  has "$who: an after-merge block gets no Human QA step and stops" "$f" 'gets no Human QA step'
  line_has "$who: an after-merge done outcome continues" "$f" '^ +- When `outcome` is `done`' 'with the steps below'
  lacks "$who: 2.15 no longer opens with only two steps" "$f" '2.15. **`finish`.** Only two steps'
  has "$who: Never ask a role to use the reporting skill" "$f" 'Ask a role to use, load or follow the reporting skill'
}

manager_rules agent "$PLUGIN/agents/manager.md"
if [ -f "$SPECS/manager.md" ]; then
  manager_rules spec "$SPECS/manager.md"
  has "spec: an empty final reply is written and checked as empty text" "$SPECS/manager.md" 'If the final reply is empty or missing'
  has "spec: never check a report with another role or without --role" "$SPECS/manager.md" 'Check a report with a role other than the one it dispatched'
  has "spec: the model in the agent frontmatter is only a fallback" "$SPECS/manager.md" 'only a fallback'
else
  echo "skip - no spec at $SPECS/manager.md (installed plugin)"
fi

# status --forecast
has "skill: status runs status.sh --forecast for a forecast" "$PLUGIN/skills/status/SKILL.md" '--forecast'
if [ -f "$SPECS/status.md" ]; then
  has "spec: status runs status.sh --forecast for a forecast or overnight preflight" "$SPECS/status.md" 'status.sh --forecast'
  has "spec: --forecast is never passed together with --all" "$SPECS/status.md" 'never together with `--all`'
  has "spec: --forecast prints the nothing-to-warn line" "$SPECS/status.md" 'forecast: nothing to warn about'
  has "spec: --forecast output is passed through verbatim" "$SPECS/status.md" 'forecast output'
  has "brief: status requirements name --forecast" "$SPECS/briefs/spec-req-status.md" 'status.sh --forecast'
  has "brief: manager requirements record the Revision 14 catch-up" "$SPECS/briefs/spec-req-manager.md" 'Revision 14'

  # the audit record in specs/README.md
  R="$SPECS/README.md"
  has "README: Revision 14 is recorded" "$R" '### Revision 14'
  rev="$(awk '/^### Revision 14/{f=1;next} f&&/^### /{exit} f' "$R")"
  for need in 'Brief sha256' 'Init sha256' 'Isolation' 'Path audit' 'Cost' 'Output sha256' 'Running total'; do
    if printf '%s\n' "$rev" | grep -qF -e "$need"; then ok "README Revision 14 records: $need"; else bad "README Revision 14 records: $need"; fi
  done
  sk="$(shasum -a 256 "$PLUGIN/skills/status/SKILL.md" | cut -c1-16)"
  if printf '%s\n' "$rev" | grep -qF "$sk"; then ok "README Revision 14 records the output sha256 of skills/status/SKILL.md ($sk)"; else bad "README Revision 14 records the output sha256 of skills/status/SKILL.md ($sk)"; fi
else
  echo "skip - no spec at $SPECS/status.md (installed plugin)"
fi

# version bump
pv=$(sed -n 's/^  "version": "\([^"]*\)".*/\1/p' "$PLUGIN/.claude-plugin/plugin.json" | head -1)
mv=$(awk '/"source": "\.\/plugins\/fleet-board"/{f=1} f && /"version"/{gsub(/.*"version": "|".*/,""); print; exit}' "$PLUGIN/../../.claude-plugin/marketplace.json")
if [ "$pv" = "$mv" ]; then ok "plugin.json and marketplace.json agree ($pv)"; else bad "versions drifted: $pv vs $mv"; fi
if [ "$pv" != "0.6.4" ] && [ -n "$pv" ]; then ok "version is bumped past 0.6.4 ($pv)"; else bad "version is still 0.6.4"; fi
exit $fail
