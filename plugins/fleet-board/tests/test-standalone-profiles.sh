#!/usr/bin/env bash
# Targeted standalone profile cases; no provider calls.
set -uo pipefail
unset CDPATH
case "${1:-}" in routing|legacy-config|preflight|preflight-tick|preflight-engine) ;; *) echo 'usage: test-standalone-profiles.sh routing|legacy-config' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; SCRIPTS="$TESTS/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
if [[ $1 == preflight-engine ]]; then
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"
  chmod +x "$TMP/bin/codex" "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH" OPENAI_API_KEY=test-key
  cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { repo: acme/toy }
execution:
  profiles: { code: { runner: codex, provider: openai, model: code-model } }
  roles: { implementor: code, fixer: code, reviewer: code }
YML
  cd "$TMP/repo" || exit 1
  if bash "$SCRIPTS/standalone/profiles.sh" preflight >"$TMP/out" 2>"$TMP/err"; then echo 'FAIL: unavailable Docker engine accepted' >&2; exit 1; fi
  grep -qi docker "$TMP/err" || { echo 'FAIL: Docker engine failure not identified' >&2; exit 1; }
  echo 'PASS: preflight-engine'
  exit 0
fi
if [[ $1 == preflight-tick ]]; then
  mkdir -p "$TMP/bin"
  for executable in codex docker; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$executable"; chmod +x "$TMP/bin/$executable"
  done
  cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { repo: acme/toy }
execution:
  profiles: { code: { runner: codex, provider: openai, model: code-model } }
  roles: { implementor: code, fixer: code, reviewer: code }
YML
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$TMP/planner-ran" > "$TMP/planner"
  cd "$TMP/repo" || exit 1
  unset OPENAI_API_KEY FLEET_BOARD_STANDALONE_FIXTURE
  export PATH="$TMP/bin:$PATH" FLEET_BOARD_TICK_PLAN="$TMP/planner"
  if bash "$SCRIPTS/standalone/controller.sh" tick >"$TMP/out" 2>"$TMP/err"; then echo 'FAIL: missing key accepted' >&2; exit 1; fi
  [[ ! -e "$TMP/planner-ran" ]] || { echo 'FAIL: planner ran before preflight' >&2; exit 1; }
  grep -q OPENAI_API_KEY "$TMP/err" || { echo 'FAIL: missing key not identified' >&2; exit 1; }
  echo 'PASS: preflight-tick'
  exit 0
fi
if [[ $1 == preflight ]]; then
  mkdir -p "$TMP/bin"
  for executable in codex docker; do
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$executable"
    chmod +x "$TMP/bin/$executable"
  done
  export PATH="$TMP/bin:$PATH" OPENAI_API_KEY=test-key OPENROUTER_API_KEY=test-key
  cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { repo: acme/toy }
execution:
  profiles:
    code: { runner: codex, provider: openai, model: code-model }
    review: { runner: diff-chat, provider: openrouter, model: review-model }
  roles: { implementor: code, fixer: code, reviewer: review }
YML
  cd "$TMP/repo" || exit 1
  check() { bash "$SCRIPTS/standalone/profiles.sh" preflight; }
  check || { echo 'FAIL: valid profiles failed preflight' >&2; exit 1; }
  unset OPENROUTER_API_KEY
  if check >"$TMP/out" 2>"$TMP/err"; then echo 'FAIL: missing key accepted' >&2; exit 1; fi
  rg -q 'OPENROUTER_API_KEY' "$TMP/err" || { echo 'FAIL: missing key not identified' >&2; exit 1; }
  export OPENROUTER_API_KEY=test-key
  sed 's/implementor: code/implementor: review/' .fleet-board.yml > "$TMP/next" && mv "$TMP/next" .fleet-board.yml
  if check >"$TMP/out" 2>"$TMP/err"; then echo 'FAIL: diff-only implementor accepted' >&2; exit 1; fi
  rg -q 'implementor' "$TMP/err" || exit 1
  sed 's/implementor: review/implementor: code/' .fleet-board.yml > "$TMP/next" && mv "$TMP/next" .fleet-board.yml
  rm "$TMP/bin/codex"
  PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH
  if check >"$TMP/out" 2>"$TMP/err"; then echo 'FAIL: missing codex accepted' >&2; exit 1; fi
  grep -q 'codex' "$TMP/err" || exit 1
  echo 'PASS: preflight'
  exit 0
fi
if [[ $1 == legacy-config ]]; then
  cat > "$TMP/repo/.fleet-board.yml" <<'YML'
board: { repo: acme/toy }
review:
  stages:
    - { name: security, provider: openrouter, model: model-review, price: { input: 1, output: 2 }, timeout: 91 }
    - { name: architecture, agent: 'fleet:architecture' }
YML
  cd "$TMP/repo" || exit 1
  bash "$SCRIPTS/config.sh" --check || exit 1
  out="$(bash "$SCRIPTS/standalone/profiles.sh" resolve --stage security --round 1)" || exit 1
  jq -e '.source == "legacy-provider" and .provider == "openrouter" and .model == "model-review" and .price.input == 1 and .timeout == 91' <<<"$out" >/dev/null || exit 1
  if bash "$SCRIPTS/standalone/profiles.sh" resolve --stage architecture --round 1 >"$TMP/out" 2>"$TMP/err"; then
    echo 'FAIL: unmapped agent was accepted' >&2; exit 1
  fi
  rg -q 'architecture.*profile' "$TMP/err" || { echo 'FAIL: migration error was not actionable' >&2; exit 1; }
  # Explicit profile and legacy provider are ambiguous, even when each is valid.
  cat > .fleet-board.yml <<'YML'
board: { repo: acme/toy }
execution:
  profiles: { review: { runner: diff-chat, provider: openrouter, model: model-review } }
review:
  stages:
    - { name: security, provider: openrouter, model: model-review, profile: review }
YML
  if bash "$SCRIPTS/config.sh" --check >/dev/null 2>&1; then echo 'FAIL: conflicting stage bindings accepted' >&2; exit 1; fi
  echo 'PASS: legacy-config'
  exit 0
fi
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
