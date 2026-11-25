#!/usr/bin/env bash
# implementor-run.sh <card> <worktree> <branch> - run the implementor through implementor.provider:
# the provider's implement_command in the card's worktree, behind providers/guard/, then check and
# post the one report it wrote. Run from the card's repo checkout.
#
# Exit 0: report posted; stdout {status, report_file, parsed, provider, model, attempts}.
# 1: setup or posting failure. 2: usage, or implementor.provider is claude.
# 3: attention (stdout {"attention": ...}, one comment on the card): the guard refused to start or
#    rejected the session, a gated call was blocked, or implementor.persona cannot be read.
# 4: provider failure (non-zero exit, empty output, timeout): nothing posted, retry later.
# 6: two rejected reports: nothing posted.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/board-lib.sh"

die() {
  printf 'implementor-run: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ $# -eq 3 ] || die "usage: implementor-run.sh <card> <worktree> <branch>" 2
N="$1" WT_IN="$2" BRANCH="$3"
fb_valid_number "$N" || die "card number must be numeric, got: $N" 2

fb_load_config
PROVIDER="$(fb_cfg implementor.provider)"
[ "$PROVIDER" != claude ] || die "implementor.provider is claude: the supervisor runs that implementor" 2
MODEL="$(fb_cfg implementor.model)"
[ -n "$MODEL" ] || die "implementor.model must be set for provider $PROVIDER"
COMMAND="$(jq -r --arg p "$PROVIDER" '.providers[$p].implement_command // empty' <<<"$FLEET_CFG")"
[ -n "$COMMAND" ] || die "providers.$PROVIDER has no implement_command"
TIMEOUT="$(jq -r '.implementor.timeout // .supervisor.attempt_timeout_seconds // 7200 | tostring' <<<"$FLEET_CFG")"
case "$TIMEOUT" in ''|0*|*[!0-9]*) die "implementor.timeout must be a positive integer, got: $TIMEOUT" ;; esac

attention() { # attention REASON: comment on the card, print the JSON, exit 3
  local f
  printf 'implementor-run: attention: %s\n' "$1" >&2
  f="$(mktemp)" && {
    printf 'Waiting for a person: the provider implementor raised an attention: %s\n' "$1" > "$f"
    bash "$HERE/board-comment.sh" "$N" "$f" > /dev/null 2>&1 || printf 'implementor-run: cannot comment on #%s\n' "$N" >&2
    rm -f "$f"
  }
  jq -nc --arg r "$1" '{attention: $r}'
  exit 3
}

# The card repo's checkout: persona paths are relative to it. The board may live elsewhere (FLEET_ROOT).
COMMON="$(fb_git_common_dir .)"
if [ -n "$COMMON" ]; then CHECKOUT="$(dirname "$COMMON")"; else CHECKOUT="$PWD"; fi

umask 077
TMP="" PTMP="" FB_ACTIVE_FILE=""
trap 'rm -rf ${TMP:+"$TMP"} ${PTMP:+"$PTMP"}; if [ -n "$FB_ACTIVE_FILE" ]; then rm -f "$FB_ACTIVE_FILE"; fi' EXIT
trap 'exit 1' INT TERM
# TMP is the runner's own; PTMP is the only temp directory the provider may write.
TMP="$(mktemp -d)" && TMP="$(cd "$TMP" && pwd -P)" || die "cannot create a temporary directory"
PTMP="$(mktemp -d)" && PTMP="$(cd "$PTMP" && pwd -P)" || die "cannot create a temporary directory"

# implementor.persona (file text), then implementor.persona_append: the same rules as the Claude path.
: > "$TMP/rules"
PERSONA="$(fb_cfg implementor.persona)"
if [ -n "$PERSONA" ]; then
  case "/$PERSONA/" in //*|*/../*) attention "implementor.persona not found: $PERSONA" ;; esac
  [ -f "$CHECKOUT/$PERSONA" ] || attention "implementor.persona not found: $PERSONA"
  text="$(cat "$CHECKOUT/$PERSONA")" || attention "implementor.persona unreadable: $PERSONA"
  printf '%s\n' "$text" >> "$TMP/rules"
fi
APPEND="$(jq -r '.implementor.persona_append // "" | if test("\\S") then . else "" end' <<<"$FLEET_CFG")"
if [ -n "$APPEND" ]; then
  [ ! -s "$TMP/rules" ] || printf '\n' >> "$TMP/rules"
  printf '%s\n' "$APPEND" >> "$TMP/rules"
fi

WT="$(cd "$WT_IN" 2>/dev/null && pwd -P)" || attention "worktree $WT_IN does not exist"
GITDIR="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" && GITDIR="$(cd "$GITDIR" && pwd -P)" ||
  attention "$WT is not a git worktree"
GITCOMMON="$(fb_git_common_dir "$WT")" && GITCOMMON="$(cd "$GITCOMMON" && pwd -P)" ||
  attention "$WT is not a git worktree"
# git writes reflogs here; the sandbox can only add a directory that exists
mkdir -p "$GITCOMMON/logs" || die "cannot create $GITCOMMON/logs"

CARD="$(bash "$HERE/board-read.sh" "$N")" || die "cannot read card #$N"
NOTE="$(bash "$HERE/note.sh" get "$N")" || die "cannot read the manager note of #$N"
NOTE="$(jq -rS 'if . == {} then "none" else . end' <<<"$NOTE")" || die "cannot read the manager note of #$N"
# One array per state, in board order; done and wont_do are the last two.
OPEN="$(bash "$HERE/board-list.sh" --all 2>/dev/null | jq -rs --argjson n "$N" '
  .[:-2] | add // [] | map(select(.number != $n)) | sort_by(.number)
  | map("#\(.number) \(.title | gsub("\\s+"; " "))") | join("\n")')" || OPEN=""
[ -n "$OPEN" ] || OPEN=none
CONFIG="$(jq -S . <<<"$FLEET_CFG")" || die "cannot prepare the prompt config"

# The spec is agents/implementor.md without its frontmatter.
awk 'NR == 1 && $0 == "---" { fm = 1; next } fm { if ($0 == "---") fm = 0; next } { print }' \
  "$HERE/../agents/implementor.md" > "$TMP/spec" && [ -s "$TMP/spec" ] || die "cannot read the implementor spec"

REPORT="$PTMP/report.md"
# Substitute once so placeholders appearing in card text stay literal.
jq -n --rawfile tpl "$HERE/providers/implementor-prompt.md" --rawfile spec "$TMP/spec" \
  --rawfile rules "$TMP/rules" --argjson card "$CARD" --arg n "$N" --arg wt "$WT" --arg branch "$BRANCH" \
  --arg config "$CONFIG" --arg note "$NOTE" --arg open "$OPEN" --arg scripts "$HERE" --arg report "$REPORT" '
  {SPEC: $spec, SCRIPTS: $scripts, REPORT: $report, NUMBER: $n, TITLE: ($card.title // ""),
   BODY: ($card.body // ""),
   ACCEPTANCE: (($card.acceptance // []) | if length == 0 then "none" else map("- " + .) | join("\n") end),
   WORKTREE: $wt, BRANCH: $branch, CONFIG: $config, NOTE: $note, OPEN: $open,
   RULES: (if $rules == "" then "" else "\n## Project rules\n" + $rules end)} as $v
  | [{role: "user", content: ($tpl | gsub("\\{\\{(?<k>[A-Z]+)\\}\\}"; $v[.k]))}]' > "$TMP/messages.json" ||
  die "cannot build the prompt"

quote() { jq -nr --arg v "$1" '$v | @sh'; }
RUN="${COMMAND//\{tmp\}/$(quote "$PTMP")}"
RUN="${RUN//\{gitdir\}/$(quote "$GITDIR")}"
RUN="${RUN//\{gitcommon\}/$(quote "$GITCOMMON")}"
RUN="export TMPDIR=$(quote "$PTMP"); $RUN"

LOG_DIR="${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}"
mkdir -p "$LOG_DIR/implementor-reports" || die "cannot create report directory"
LOG_DIR="$(cd "$LOG_DIR" && pwd -P)" || die "cannot resolve report directory"
fb_mark_active "$N"

ATTEMPTS=0
deadline=$((SECONDS + TIMEOUT))
while :; do
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || die "provider failure: implementor timeout of ${TIMEOUT}s exhausted" 4
  ATTEMPTS=$((ATTEMPTS + 1))
  rm -rf "$REPORT" "$PTMP/guard-shims" "$TMP/rc"
  jq -c '{messages: .}' "$TMP/messages.json" > "$TMP/request.json" || die "cannot build the prompt"
  # The inner shell sits behind the guard. It keeps the reply in the runner's directory, so the
  # guard's own stdout holds nothing but an attention.
  grc=0
  bash "$HERE/providers/guard/start.sh" "$N" "$FLEET_ROOT" "$WT" "$BRANCH" "$PTMP" -- \
    bash -c 'bash "$1" --command "$2" --model "$3" --timeout "$4" --dir "$5" \
        < "$6/request.json" > "$6/reply.json" 2> "$6/chat.err"; echo $? > "$6/rc"' \
    implementor-run "$HERE/providers/chat.sh" "$RUN" "$MODEL" "$remaining" "$WT" "$TMP" \
    < /dev/null > "$TMP/guard.out" || grc=$?
  if [ "$grc" -ne 0 ]; then
    # start.sh has already commented on the card
    if jq -e 'has("attention")' "$TMP/guard.out" > /dev/null 2>&1; then cat "$TMP/guard.out"; exit 3; fi
    die "the provider guard failed (exit $grc)"
  fi
  if [ -s "$PTMP/guard-shims/blocked.log" ]; then
    attention "the guard blocked the provider session: $(head -n 5 "$PTMP/guard-shims/blocked.log" | tr '\n' ' ' | cut -c 1-600)"
  fi
  rc="$(cat "$TMP/rc" 2>/dev/null)" || rc=""
  if [ "$rc" != 0 ]; then
    cat "$TMP/chat.err" >&2
    [ "$rc" != 2 ] || die "the provider command or model cannot be run"
    die "provider failure: $PROVIDER did not complete" 4
  fi

  : > "$TMP/report"
  if [ -L "$REPORT" ] || [ ! -f "$REPORT" ] || [ ! -s "$REPORT" ]; then
    printf 'no report was written to %s (a regular, non-empty file)\n' "$REPORT" > "$TMP/parse.err"
    prc=1
  else
    cp "$REPORT" "$TMP/report" || die "cannot read the report"
    prc=0
    if grep -qE '<!--[[:space:]]*fleet-board:' "$TMP/report"; then
      printf 'the report contains a fleet-board marker\n' > "$TMP/parse.err"
      prc=1
    else
      PARSED="$(bash "$HERE/parse-report.sh" --role implementor "$TMP/report" 2> "$TMP/parse.err")" || prc=$?
    fi
  fi
  [ "$prc" -ne 0 ] || break
  cat "$TMP/parse.err" >&2
  [ "$prc" -eq 1 ] || die "cannot check the report"
  [ "$ATTEMPTS" -lt 2 ] || die "the provider's report was rejected twice" 6
  jq --rawfile report "$TMP/report" --rawfile err "$TMP/parse.err" --arg file "$REPORT" '
    . + [{role: "assistant", content: $report},
         {role: "user", content: ("Your report was rejected by the checker:\n" + $err
           + "\nThe work already committed and pushed stays: do not redo it. Write the corrected full report to " + $file + " and reply with the same text.")}]' \
    "$TMP/messages.json" > "$TMP/retry.json" && mv "$TMP/retry.json" "$TMP/messages.json" ||
    die "cannot build the retry prompt"
done

REPORT_FILE="$(mktemp "$LOG_DIR/implementor-reports/card-$N.XXXXXXXX")" || die "cannot create report file"
cp "$TMP/report" "$REPORT_FILE" || die "cannot save the report"
FLEET_BOARD_ROLE_REPORT=1 bash "$HERE/board-comment.sh" "$N" "$REPORT_FILE" >&2 || die "cannot post the report on #$N"
jq -cn --arg file "$REPORT_FILE" --argjson parsed "$PARSED" --arg provider "$PROVIDER" --arg model "$MODEL" \
  --argjson attempts "$ATTEMPTS" \
  '{status: "posted", report_file: $file, parsed: $parsed, provider: $provider, model: $model, attempts: $attempts}'
