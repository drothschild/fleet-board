#!/usr/bin/env bash
# Targeted standalone profile cases; no provider calls.
set -uo pipefail
unset CDPATH
case "${1:-}" in routing) ;; *) echo 'usage: test-standalone-profiles.sh routing' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; SCRIPTS="$TESTS/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { repo: acme/toy }
execution:
  profiles:
    coding: { runner: codex, provider: openai, model: model-code }
    stronger: { runner: codex, provider: openai, model: model-strong }
    independent: { runner: diff-chat, provider: openrouter, model: model-review }
  roles: { implementor: coding, fixer: coding, reviewer: independent }
  escalation: { profile: stronger, after_round: 3 }
review:
  stages:
    - name: security
      agent: fleet:security
      profile: independent
YML
cd "$TMP/repo" || exit 1
if ! bash "$SCRIPTS/config.sh" --check; then echo 'FAIL: valid profile config rejected' >&2; exit 1; fi
stage="$(bash "$SCRIPTS/config.sh" review.stages)" || exit 1
jq -e '.[0].profile == "independent" and .[0].agent == "fleet:security"' <<<"$stage" >/dev/null || { echo 'FAIL: stage profile mapping was lost' >&2; exit 1; }
resolve() { bash "$SCRIPTS/standalone/profiles.sh" resolve "$@"; }
if ! out="$(resolve --role implementor --round 1)"; then echo 'FAIL: implementor profile did not resolve' >&2; exit 1; fi
jq -e '.profile == "coding" and .runner == "codex" and .provider == "openai" and .model == "model-code"' <<<"$out" >/dev/null || exit 1
out="$(resolve --role fixer --round 3)" || exit 1
jq -e '.profile == "stronger" and .model == "model-strong" and .escalated == true' <<<"$out" >/dev/null || exit 1
out="$(resolve --stage security --round 1)" || exit 1
jq -e '.profile == "independent" and .runner == "diff-chat" and .provider == "openrouter" and .model == "model-review"' <<<"$out" >/dev/null || exit 1
sed 's/implementor: coding/implementor: absent/' .fleet-board.yml > "$TMP/invalid" && mv "$TMP/invalid" .fleet-board.yml
if bash "$SCRIPTS/config.sh" --check >/dev/null 2>&1; then echo 'FAIL: missing referenced profile accepted' >&2; exit 1; fi
echo 'PASS: routing'
