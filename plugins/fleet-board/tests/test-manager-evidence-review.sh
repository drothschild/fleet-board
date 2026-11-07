#!/usr/bin/env bash
# Check the evidence-review dispatch and reconciliation contract on both sides of the clean-room boundary.
set -uo pipefail
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
SPECS="${SPECS_DIR:-$HERE/../../../docs/implementation-plans/2026-09-28-fleet-board/specs}"
failed=0

has() {
  local label="$1" text="$2" needle="$3"
  if grep -Fq -- "$needle" <<<"$text"; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s\n' "$label"
    failed=1
  fi
}

check_manager() {
  local name="$1" file="$2" contract row action rule
  contract="$(awk '/^0\.[0-9]+\. \*\*Evidence reviewer\./ {found=1}
    found && /^0\.[0-9]+\./ && !/\*\*Evidence reviewer\./ {exit}
    found && /^### / {exit}
    found {print}' "$file")"
  for rule in 'evidence-review.sh' 'models.reviewer' 'no Agent call' 'run_in_background: true' \
    '(models.reviewer.timeout + 300) * 1000' 'completion notice' 'output file' \
    'counts against `limits.concurrency`'; do
    has "$name evidence reviewer requires $rule" "$contract" "$rule"
  done
  row="$(grep -F '**Exit 0' <<<"$contract")"
  for rule in '--role reviewer' 'last_review' 'provider' 'model' 'sha'; do
    has "$name exit 0 reconciles $rule" "$row" "$rule"
  done
  row="$(grep -F '**Exit 1, 3 or 6' <<<"$contract")"
  for rule in 'report error' 'last_action_error' 'report_errors' '"role": "reviewer"'; do
    has "$name exits 1, 3 or 6 handle $rule" "$row" "$rule"
  done
  row="$(grep -F '**Exit 2' <<<"$contract")"
  has "$name exit 2 is the manager's own error" "$row" "own call"
  for action in start_review review; do
    row="$(grep -F "| \`$action\` |" "$file")"
    has "$name $action routes the command reviewer" "$row" 'evidence-review.sh'
  done
  has "$name fix re-review uses the evidence reviewer contract" "$contract" 're-review after `fix`'
  row="$(grep -F '| `fix` |' "$file")"
  has "$name fix replans before scheduling review" "$row" 'fresh plan'
}

check_manager agent "$HERE/../agents/manager.md"
if [ -f "$SPECS/manager.md" ]; then
  check_manager spec "$SPECS/manager.md"
else
  echo "skip - no manager spec at $SPECS (installed plugin)"
fi
exit "$failed"
