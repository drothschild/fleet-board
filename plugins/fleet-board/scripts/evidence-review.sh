#!/usr/bin/env bash
# Run a command-provider evidence review in a disposable clone of the PR head.
# Exit 0: posted or checked. 1: setup, provider, safety or posting failure.
# Exit 2: usage or string reviewer. 3: missing program. 6: two rejected replies.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/board-lib.sh"

die() {
  printf 'evidence-review: %s\n' "$1" >&2
  exit "${2:-1}"
}

N="" PR="" ROUND="" PREV_SHA="" FINDINGS_FILE="" IMPL_FILE="" CARD_FILE="" DIFF_FILE="" NO_POST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post) NO_POST=1; shift ;;
    --round|--prev-sha|--findings|--impl-report|--card-file|--diff-file)
      [ $# -ge 2 ] || die "missing value for $1" 2
      case "$1" in
        --round) ROUND="$2" ;;
        --prev-sha) PREV_SHA="$2" ;;
        --findings) FINDINGS_FILE="$2" ;;
        --impl-report) IMPL_FILE="$2" ;;
        --card-file) CARD_FILE="$2" ;;
        --diff-file) DIFF_FILE="$2" ;;
      esac
      shift 2
      ;;
    -*) die "unknown argument: $1" 2 ;;
    *)
      if [ -z "$N" ]; then N="$1"
      elif [ -z "$PR" ]; then PR="$1"
      else die "unexpected argument: $1" 2
      fi
      shift
      ;;
  esac
done

[ -n "$N" ] && [ -n "$PR" ] && [ -n "$ROUND" ] ||
  die "usage: evidence-review.sh <n> <pr> --round <r> [--prev-sha <sha>] [--findings <file>] [--impl-report <file>] [--card-file <f>] [--diff-file <f>] [--no-post]" 2
fb_valid_number "$N" || die "card number must be numeric, got: $N" 2
fb_valid_number "$PR" || die "pr number must be numeric, got: $PR" 2
case "$ROUND" in ''|*[!0-9]*) die "--round must be a positive integer" 2 ;; esac
[ "$ROUND" -ge 1 ] 2>/dev/null || die "--round must be a positive integer" 2
if [ "$ROUND" -ge 2 ] && [ -z "$PREV_SHA" ]; then
  die "--prev-sha is required from round 2" 2
fi
for f in "$FINDINGS_FILE" "$IMPL_FILE" "$CARD_FILE" "$DIFF_FILE"; do
  [ -z "$f" ] || [ -f "$f" ] || die "file not found: $f" 2
done

fb_load_config
REVIEWER="$(jq -ce '.models.reviewer | objects' <<<"$FLEET_CFG")" ||
  die "models.reviewer is not an object" 2
PROVIDER="$(jq -r .provider <<<"$REVIEWER")"
MODEL="$(jq -r .model <<<"$REVIEWER")"
TIMEOUT="$(jq -r .timeout <<<"$REVIEWER")"
REVIEW_COMMAND="$(jq -r --arg p "$PROVIDER" '.providers[$p].review_command' <<<"$FLEET_CFG")"
read -r PROGRAM SUBCOMMAND _ <<<"$REVIEW_COMMAND"
# codex prints token usage only in its JSON event stream.
CHAT_JSON=""
if [ "${PROGRAM##*/}" = codex ] && [ "$SUBCOMMAND" = exec ]; then
  REVIEW_COMMAND="${REVIEW_COMMAND/codex exec/codex exec --json}"
  CHAT_JSON="--json-events"
fi
command -v "$PROGRAM" >/dev/null 2>&1 || die "$PROGRAM is not on PATH" 3

umask 077
TMP="$(mktemp -d)" || die "cannot create a temporary directory"
TMP="$(cd "$TMP" && pwd -P)" || die "cannot resolve the temporary directory"
FB_ACTIVE_FILE=""
trap 'rm -rf "$TMP"; if [ -n "$FB_ACTIVE_FILE" ]; then rm -f "$FB_ACTIVE_FILE"; fi' EXIT
trap 'exit 1' INT TERM
fb_mark_active "$N"

if ! TREE="$(bash "$HERE/worktree.sh" review "$N" "$PR" 2> "$TMP/worktree.err")"; then
  cat "$TMP/worktree.err" >&2
  if grep -q 'worktrees.setup failed' "$TMP/worktree.err"; then die "setup failed"; fi
  die "cannot prepare the review worktree"
fi
cat "$TMP/worktree.err" >&2
REVIEW_DIR="$(jq -er .path <<<"$TREE")" || die "cannot read the review worktree path"
SHA="$(jq -er .sha <<<"$TREE")" || die "cannot read the PR head"
BASE="$(jq -er .base <<<"$TREE")" || die "cannot read the merge-base"
REF_SHA="$BASE"
if [ "$ROUND" -ge 2 ]; then REF_SHA="$PREV_SHA"; fi

# Copy git objects without hardlinks. The provider gets its own refs and index
# and can inspect the reference commit and restore mutants inside the clone.
CLONE="$TMP/clone"
git clone -q --no-hardlinks "$REVIEW_DIR" "$CLONE" >&2 &&
  git -C "$CLONE" checkout -q --detach "$SHA" >&2 || die "cannot clone the review worktree"
SETUP="$(fb_cfg worktrees.setup)"
if [ "$SETUP" != null ] && [ -n "$SETUP" ]; then
  (cd "$CLONE" && bash -c "$SETUP") >&2 || die "setup failed"
fi

if [ -n "$CARD_FILE" ]; then
  cp "$CARD_FILE" "$TMP/card" || die "cannot read card file"
else
  CARD_READ="$(bash "$HERE/board-read.sh" "$N")" || die "cannot read card #$N"
  fb_card_text "$CARD_READ" > "$TMP/card" || die "cannot render the text of card #$N"
fi
if [ -n "$DIFF_FILE" ]; then
  cp "$DIFF_FILE" "$TMP/diff" || die "cannot read diff file"
else
  git -C "$CLONE" diff --no-ext-diff --no-textconv "$BASE" "$SHA" -- > "$TMP/diff" ||
    die "cannot read the diff of PR #$PR"
fi
if [ -n "$IMPL_FILE" ]; then
  cp "$IMPL_FILE" "$TMP/impl" || die "cannot read implementor report"
else
  printf '(none)' > "$TMP/impl"
fi
FINDINGS="(none)"
if [ "$ROUND" -ge 2 ] && [ -n "$FINDINGS_FILE" ]; then
  FINDINGS="$(jq -r '(if type == "array" then . else (.findings // []) end)
    | map(select(.severity == "Critical" or .severity == "Important") | "- [\(.severity)] \(.text)")
    | if length == 0 then "(none)" else join("\n") end' "$FINDINGS_FILE")" ||
    die "cannot read findings file $FINDINGS_FILE" 2
fi
CONFIG="$(jq '{commands: (.commands | {test_one, typecheck, lint}),
  review: (.review | {mutation, verify_claim}), test_paths}' <<<"$FLEET_CFG")" || die "cannot prepare prompt config"
MUTATION="$(fb_cfg review.mutation)"

printf '%s' "$FINDINGS" > "$TMP/findings" || die "cannot save previous findings"

# Substitute once so placeholders appearing in untrusted inputs stay literal.
jq -n --rawfile tpl "$HERE/providers/evidence-review-prompt.md" \
  --rawfile card "$TMP/card" --rawfile diff "$TMP/diff" --rawfile impl "$TMP/impl" \
  --rawfile findings "$TMP/findings" --arg config "$CONFIG" --arg round "$ROUND" --arg ref "$REF_SHA" '
  {ROUND: $round, REF_SHA: $ref, CONFIG: $config, CARD: $card, DIFF: $diff,
   IMPL_REPORT: $impl, FINDINGS: $findings} as $v
  | ($tpl | split("\n---USER---\n")) as $parts
  | [{role: "system", content: $parts[0]}, {role: "user", content: $parts[1]}]
  | map(.content |= gsub("\\{\\{(?<k>[A-Z_]+)\\}\\}"; $v[.k]))' > "$TMP/messages.json" ||
  die "cannot build the prompt"

LOG_DIR="${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}"
mkdir -p "$LOG_DIR/evidence-reports" || die "cannot create report directory"
LOG_DIR="$(cd "$LOG_DIR" && pwd -P)" || die "cannot resolve report directory"

snapshot() {
  git -C "$1" rev-parse HEAD && git --no-optional-locks -C "$1" status --porcelain --untracked-files=all
}
ROOT_BEFORE="$(snapshot "$FLEET_ROOT")" || die "cannot inspect $FLEET_ROOT"
REVIEW_BEFORE="$(snapshot "$REVIEW_DIR")" || die "cannot inspect $REVIEW_DIR"

IN_TOKENS=null OUT_TOKENS=null
add_tokens() { # <current|null> <reply value|null>
  jq -cn --argjson a "$1" --argjson b "$2" 'if $b == null then $a else ($a // 0) + $b end'
}
write_ledger() {
  jq -cn --argjson in "$IN_TOKENS" --argjson out "$OUT_TOKENS" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg run "${FLEET_BOARD_RUN_ID:-}" --arg repo "$FLEET_REPO" --argjson card "$N" \
    --arg provider "$PROVIDER" --arg model "$MODEL" \
    '{ts: $ts, run_id: (if $run == "" then null else $run end), repo: $repo, card: $card,
      role: "reviewer", provider: $provider, model: $model, input_tokens: $in, output_tokens: $out, cost_usd: 0}' \
    >> "$LOG_DIR/provider-spend.jsonl" || die "cannot write provider spend ledger"
}

# Set TMPDIR only inside the provider shell. The adapter and runner keep
# their transport and retry files outside the clone's writable root.
PROVIDER_TMP="$CLONE/.fleet-board-tmp"
mkdir "$PROVIDER_TMP" || die "cannot create provider temp directory"
PROVIDER_BIN="$CLONE/.fleet-board-bin"
mkdir "$PROVIDER_BIN" || die "cannot create provider utility directory"
cp "$FLEET_SCRIPTS/providers/reviewer-mktemp.sh" "$PROVIDER_BIN/mktemp" || die "cannot install provider mktemp"
chmod +x "$PROVIDER_BIN/mktemp" || die "cannot make provider mktemp executable"
if [ "$(uname -s)" = Darwin ]; then
  cp "$FLEET_SCRIPTS/providers/reviewer-ps.py" "$PROVIDER_BIN/ps" || die "cannot install provider ps"
  chmod +x "$PROVIDER_BIN/ps" || die "cannot make provider ps executable"
fi
REVIEW_COMMAND='export FLEET_REVIEW_MKTEMP="$(command -v mktemp)"; export TMPDIR="$PWD/.fleet-board-tmp"; export PATH="$PWD/.fleet-board-bin:$PATH"; '"$REVIEW_COMMAND"

ATTEMPTS=0
REPLIED=0
deadline=$((SECONDS + TIMEOUT))
while :; do
  remaining=$((deadline - SECONDS))
  if [ "$remaining" -le 0 ]; then
    [ "$REPLIED" -eq 0 ] || write_ledger
    die "review timeout exhausted"
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  rc=0
  jq -c '{messages: .}' "$TMP/messages.json" | bash "$HERE/providers/chat.sh" \
    ${CHAT_JSON:+"$CHAT_JSON"} --command "$REVIEW_COMMAND" --model "$MODEL" --timeout "$remaining" --dir "$CLONE" \
    > "$TMP/reply.json" 2> "$TMP/chat.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    REPLIED=1
    IN_TOKENS="$(add_tokens "$IN_TOKENS" "$(jq -c '.input_tokens' "$TMP/reply.json")")" || die "cannot read provider usage"
    OUT_TOKENS="$(add_tokens "$OUT_TOKENS" "$(jq -c '.output_tokens' "$TMP/reply.json")")" || die "cannot read provider usage"
  fi
  if ! after="$(snapshot "$FLEET_ROOT")" || [ "$after" != "$ROOT_BEFORE" ]; then
    [ "$REPLIED" -eq 0 ] || write_ledger
    die "$FLEET_ROOT changed during the review"
  fi
  if ! after="$(snapshot "$REVIEW_DIR")" || [ "$after" != "$REVIEW_BEFORE" ]; then
    [ "$REPLIED" -eq 0 ] || write_ledger
    die "$REVIEW_DIR changed during the review"
  fi
  if [ "$rc" -ne 0 ]; then
    [ "$REPLIED" -eq 0 ] || write_ledger
    cat "$TMP/chat.err" >&2
    exit 1
  fi
  jq -j .text "$TMP/reply.json" > "$TMP/reply.txt" || die "cannot read provider reply"
  if grep -qE '<!--[[:space:]]*fleet-board:' "$TMP/reply.txt"; then
    write_ledger
    die "reply contains a fleet-board marker"
  fi

  prc=0
  PARSED="$(bash "$HERE/parse-report.sh" --role reviewer "$TMP/reply.txt" 2> "$TMP/parse.err")" || prc=$?
  if [ "$prc" -eq 0 ]; then
    # Require exactly one plain head line in the parsed For the card section.
    reviewed_head="$(jq -r '[.for_the_card | split("\n")[] | select(startswith("reviewed head: "))
      | ltrimstr("reviewed head: ")] | if length == 1 then .[0] else "(missing or ambiguous)" end' <<<"$PARSED")"
    if [ "$reviewed_head" != "$SHA" ]; then
      printf 'evidence-review: reviewed head %s is not the PR head %s\n' "$reviewed_head" "$SHA" > "$TMP/parse.err"
      prc=1
    elif [ "$MUTATION" = true ] && jq -e '.mutation.skipped == true' <<<"$PARSED" >/dev/null; then
      printf 'evidence-review: review.mutation is on but the report skipped mutation\n' > "$TMP/parse.err"
      prc=1
    else
      break
    fi
  fi
  if [ "$prc" -ne 1 ] || [ "$ATTEMPTS" -ge 2 ]; then
    write_ledger
    cat "$TMP/parse.err" >&2
    if [ "$prc" -eq 1 ]; then exit 6; fi
    exit 1
  fi
  jq --rawfile reply "$TMP/reply.txt" --rawfile err "$TMP/parse.err" '
    . + [{role: "assistant", content: $reply},
         {role: "user", content: ("Your report was rejected by the checker:\n" + $err + "\nReply with the corrected full report only.")}]' \
    "$TMP/messages.json" > "$TMP/retry.json" && mv "$TMP/retry.json" "$TMP/messages.json" ||
    die "cannot build the retry prompt"
done

write_ledger
REPORT_FILE="$(mktemp "$LOG_DIR/evidence-reports/card-$N-round$ROUND.XXXXXXXX")" || die "cannot create report file"
cp "$TMP/reply.txt" "$REPORT_FILE" || die "cannot save the report"
STATUS=checked
if [ "$NO_POST" -eq 0 ]; then
  FLEET_BOARD_ROLE_REPORT=1 bash "$HERE/board-comment.sh" "$N" "$REPORT_FILE" >&2 || die "cannot post the report on #$N"
  STATUS=posted
fi
jq -cn --arg status "$STATUS" --arg file "$REPORT_FILE" --slurpfile parsed <(printf '%s\n' "$PARSED") \
  --arg provider "$PROVIDER" --arg model "$MODEL" --arg sha "$SHA" --argjson attempts "$ATTEMPTS" --argjson in "$IN_TOKENS" --argjson out "$OUT_TOKENS" \
  '{status: $status, report_file: $file, parsed: $parsed[0], provider: $provider, model: $model,
    sha: $sha, input_tokens: $in, output_tokens: $out, cost_usd: 0, attempts: $attempts}'
