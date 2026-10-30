#!/usr/bin/env bash
# cards.sh - the first-class helper for bulk card setup: create | add | move.
#
#   cards.sh create <title> <body-file> [--label L]... [--repo OWNER/REPO]
#   cards.sh add <number> [--repo OWNER/REPO]
#   cards.sh move <number> <state> [--repo OWNER/REPO]
#
# It replaces hand-written gh issue create / gh project item-add / gh project
# item-edit sequences (and their loops over a variable item id). The gate
# (hooks/gate.sh) recognizes it: a call is allowed for the configured repo
# only, and it never moves a card out of Human QA itself, so a loop that gives
# it a card number from a variable is safe to allow. Exit 2 is a usage error.
set -uo pipefail
unset CDPATH # a relative cd must not follow CDPATH (it would also echo the path)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

U_CREATE="usage: cards.sh create <title> <body-file> [--label L]... [--repo OWNER/REPO]"
U_ADD="usage: cards.sh add <number> [--repo OWNER/REPO]"
U_MOVE="usage: cards.sh move <number> <state> [--repo OWNER/REPO]"
U_ALL="usage: cards.sh create|add|move ... (see cards.sh <subcommand> --help)"

SUB="${1:-}"
[ $# -eq 0 ] || shift
case "$SUB" in
  create) USAGE="$U_CREATE" ;;
  add) USAGE="$U_ADD" ;;
  move) USAGE="$U_MOVE" ;;
  -h|--help) printf '%s\n%s\n%s\n' "$U_CREATE" "$U_ADD" "$U_MOVE"; exit 0 ;;
  *) fb_die 2 "$U_ALL" ;;
esac
case "${1:-}" in -h|--help) printf '%s\n' "$USAGE"; exit 0 ;; esac

# Split the arguments into positionals, labels and --repo
POS=()
LABELS=()
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label)
      [ "$SUB" = create ] || fb_die 2 "$USAGE"
      [ $# -ge 2 ] && [ -n "$2" ] || fb_die 2 "$USAGE"
      LABELS+=("--label" "$2"); shift 2 ;;
    --repo|-R)
      [ $# -ge 2 ] && [ -n "$2" ] || fb_die 2 "$USAGE"
      REPO="$2"; shift 2 ;;
    --repo=?*) REPO="${1#--repo=}"; shift ;;
    -R?*) REPO="${1#-R}"; shift ;;
    -*) fb_die 2 "$USAGE" ;;
    *) POS+=("$1"); shift ;;
  esac
done

case "$SUB" in
  create)
    [ ${#POS[@]} -eq 2 ] || fb_die 2 "$USAGE"
    [ -f "${POS[1]}" ] || fb_die 2 "file not found: ${POS[1]}; $USAGE" ;;
  add)
    [ ${#POS[@]} -eq 1 ] || fb_die 2 "$USAGE"
    fb_valid_number "${POS[0]}" || fb_die 2 "card number must be numeric, got: ${POS[0]}; $USAGE" ;;
  move)
    [ ${#POS[@]} -eq 2 ] || fb_die 2 "$USAGE"
    fb_valid_number "${POS[0]}" || fb_die 2 "card number must be numeric, got: ${POS[0]}; $USAGE"
    fb_valid_state "${POS[1]}" || fb_die 2 "invalid state: ${POS[1]}; $USAGE" ;;
esac

fb_load_config
if [ -n "$REPO" ]; then
  lc_repo="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
  lc_cfg="$(printf '%s' "$FLEET_REPO" | tr '[:upper:]' '[:lower:]')"
  [ "$lc_repo" = "$lc_cfg" ] \
    || fb_die 1 "repo $REPO is not the configured board repo ($FLEET_REPO)"
fi

# card_state N: prints the card's state (empty when it is not on the board)
card_state() {
  local out
  out="$(bash "$FLEET_SCRIPTS/board-read.sh" "$1")" || exit 1
  jq -r '.state // ""' <<<"$out"
}

# refuse_qa_exit N TARGET: a card in Human QA is moved only by a human
refuse_qa_exit() {
  local st
  [ "$2" = human_qa ] && return 0
  st="$(card_state "$1")" || exit 1
  [ "$st" != human_qa ] || fb_die 1 "card #$1 is in Human QA; only a human may move it out (GitHub UI)"
}

case "$SUB" in
  create)
    exec bash "$FLEET_SCRIPTS/board-create.sh" "${POS[0]}" "${POS[1]}" ${LABELS[@]+"${LABELS[@]}"} ;;
  add)
    st="$(card_state "${POS[0]}")" || exit 1
    [ -z "$st" ] || { printf 'card #%s is already on the board (%s)\n' "${POS[0]}" "$st"; exit 0; }
    exec bash "$FLEET_SCRIPTS/board-move.sh" "${POS[0]}" backlog ;;
  move)
    refuse_qa_exit "${POS[0]}" "${POS[1]}"
    exec bash "$FLEET_SCRIPTS/board-move.sh" "${POS[0]}" "${POS[1]}" ;;
esac
