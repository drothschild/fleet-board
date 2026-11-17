#!/usr/bin/env bash
#
# Plain-bash test that CLAUDE.md and README.md document the transcript endpoints,
# the status `log` field and the drawer's Transcripts list.
#
# Usage: bash plugins/fleet-board/tests/test-transcripts-docs.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAUDE_MD="$SCRIPT_DIR/../CLAUDE.md"
README="$SCRIPT_DIR/../README.md"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

has() { # name file text
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}

has "CLAUDE.md documents GET /api/cards/<n>/transcripts" "$CLAUDE_MD" 'GET /api/cards/<n>/transcripts`'
has "CLAUDE.md documents GET /api/cards/<n>/transcripts/<id>" "$CLAUDE_MD" 'GET /api/cards/<n>/transcripts/<id>`'
has "CLAUDE.md documents the 404 for an unknown session" "$CLAUDE_MD" 'no such session for card'
has "CLAUDE.md documents the 404 for a missing log file" "$CLAUDE_MD" 'the log file is missing for session'
has "CLAUDE.md documents the log field on running actions in the supervisor status" "$CLAUDE_MD" '`log` on each running action'
has "README.md describes the drawer's Transcripts list" "$README" 'Transcripts list'
has "README.md says a running session's transcript is a snapshot refreshed by reloading the tab" "$README" 'snapshot'
has "README.md says reloading the tab refreshes it" "$README" 'reloading the tab'

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
