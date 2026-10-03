#!/usr/bin/env bash
# init.sh - write .fleet-board.yml and set up the board backend
#
# Usage:
#   init.sh --backend github-labels|github-projects --repo OWNER/NAME
#           [--project N] [--owner LOGIN] [--state canonical=Name]...
#           [--test-one CMD] [--typecheck CMD] [--lint CMD] [--qa-build CMD]
#           [--worktrees-dir DIR] [--setup CMD] [--human-qa-path GLOB]...
#           [--merge human|auto] [--dir DIR] [--force]
#
# Exit codes:
#   0 - config written
#   1 - refused (missing scope, missing Status options, existing config
#       without --force, a rendered config that fails config.sh --check,
#       or a gh call that failed)
#   2 - usage error
#
# Nothing is written until the final step. On every non-zero exit the
# target .fleet-board.yml is unchanged, and it does not exist if it did not
# exist before.

set -uo pipefail
# With CDPATH exported, a relative cd (a relative --dir, or this script run by
# a relative path) can land in a CDPATH directory and echo its path, which
# $(cd ... && pwd) would capture as a second line.
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=board-lib.sh
. "$HERE/board-lib.sh"
CANONICAL="backlog ready in_progress in_review human_qa blocked done wont_do"
HEADER='# fleet-board config. Supported YAML subset: see the fleet-board README.'
NL='
'

usage() {
  [ -n "${1:-}" ] && printf 'fleet-board init: %s\n' "$1" >&2
  cat >&2 << 'EOF'
usage: init.sh --backend github-labels|github-projects --repo OWNER/NAME
               [--project N] [--owner LOGIN] [--state canonical=Name]...
               [--test-one CMD] [--typecheck CMD] [--lint CMD] [--qa-build CMD]
               [--worktrees-dir DIR] [--setup CMD] [--human-qa-path GLOB]...
               [--merge human|auto] [--dir DIR] [--force]
EOF
  exit 2
}

die() { printf 'fleet-board init: %s\n' "$2" >&2; exit "$1"; }

# --- Step 1: parse flags ---------------------------------------------------
# Optional scalar flags stay unset when omitted, so they are left out of the
# rendered file and config-defaults.json applies. They carry the FBI_ prefix
# and are unset here, so a caller's environment can never supply one: only a
# flag sets them. Every other global is assigned before it is read.
unset FBI_OWNER FBI_TEST_ONE FBI_TYPECHECK FBI_LINT FBI_QA_BUILD FBI_WT_DIR FBI_WT_SETUP FBI_MERGE
BACKEND=""; REPO=""; PROJECT=""; DIR=""; FORCE=0
STATE_KEYS=(); STATE_VALS=(); QA_PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift; continue ;;
    --backend|--repo|--project|--owner|--state|--test-one|--typecheck|--lint|--qa-build|--worktrees-dir|--setup|--human-qa-path|--merge|--dir)
      [ $# -ge 2 ] || usage "$1 needs a value" ;;
    *) usage "unknown argument: $1" ;;
  esac
  case "$1" in
    --backend) BACKEND="$2" ;;
    --repo) REPO="$2" ;;
    --project) PROJECT="$2" ;;
    --owner) FBI_OWNER="$2" ;;
    --test-one) FBI_TEST_ONE="$2" ;;
    --typecheck) FBI_TYPECHECK="$2" ;;
    --lint) FBI_LINT="$2" ;;
    --qa-build) FBI_QA_BUILD="$2" ;;
    --worktrees-dir) FBI_WT_DIR="$2" ;;
    --setup) FBI_WT_SETUP="$2" ;;
    --merge) FBI_MERGE="$2" ;;
    --dir) DIR="$2" ;;
    --human-qa-path) QA_PATHS+=("$2") ;;
    --state)
      case "$2" in *=*) ;; *) usage "--state takes canonical=Name, got: $2" ;; esac
      k="${2%%=*}"
      case " $CANONICAL " in
        *" $k "*) ;;
        *) usage "--state key must be one of: $CANONICAL (got: $k)" ;;
      esac
      case " ${STATE_KEYS[*]+"${STATE_KEYS[*]}"} " in
        *" $k "*) usage "--state $k given more than once" ;;
      esac
      [ -n "${2#*=}" ] || usage "--state $k needs a column name, got: $2"
      STATE_KEYS+=("$k"); STATE_VALS+=("${2#*=}")
      ;;
  esac
  shift 2
done

[ -n "$BACKEND" ] || usage "--backend is required"
[ -n "$REPO" ] || usage "--repo is required"
case "$BACKEND" in
  github-labels|github-projects) ;;
  *) usage "--backend must be github-labels or github-projects" ;;
esac
if [ "$BACKEND" = github-projects ]; then
  [ -n "$PROJECT" ] || usage "--project is required for github-projects"
fi
if [ -n "$PROJECT" ]; then
  case "$PROJECT" in ''|*[!0-9]*) usage "--project must be a number" ;; esac
fi

if [ -n "$DIR" ]; then
  [ -d "$DIR" ] || usage "--dir is not a directory: $DIR"
else
  DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || DIR=""
  [ -n "$DIR" ] || DIR="$PWD"
fi
DIR="$(cd "$DIR" && pwd)" || usage "cannot enter --dir: $DIR"
TARGET="$DIR/.fleet-board.yml"

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || die 1 "$tool is not on PATH"
done

# --- Step 2: scopes --------------------------------------------------------
# The active account's scopes line decides (fb_token_scopes). With none, a
# zero exit is a token gh cannot inspect, so init continues; a non-zero exit
# means gh is not logged in.
OUT="$(gh auth status 2>&1)"; RC=$?
SCOPES="$(fb_token_scopes "$OUT")"
if [ -z "$SCOPES" ] && [ "$RC" -ne 0 ]; then
  die 1 "gh is not logged in (gh auth status exited $RC):$NL$OUT"
fi
if [ -n "$SCOPES" ]; then
  REQUIRED="repo"
  [ "$BACKEND" = github-projects ] && REQUIRED="repo project"
  MISSING=""
  for s in $REQUIRED; do
    fb_has_scope "$SCOPES" "$s" || MISSING="${MISSING:+$MISSING,}$s"
  done
  if [ -n "$MISSING" ]; then
    printf 'fleet-board init: gh token is missing scope(s): %s\n' "$(printf '%s' "$MISSING" | sed 's/,/, /g')" >&2
    printf 'Run: gh auth refresh -s %s\n' "$MISSING" >&2
    exit 1
  fi
fi

# --- Step 3: existing config -----------------------------------------------
if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  die 1 "$TARGET already exists; re-run with --force to replace it"
fi

# --- Step 4: render --------------------------------------------------------
# Refuse unrenderable values here, in this shell: a die inside $(...) would
# only leave the subshell.
check_value() {
  case "$2" in
    *"$NL"*) die 1 "$1 value contains a newline, which .fleet-board.yml cannot hold" ;;
    *'"'*"'"*|*"'"*'"'*) die 1 "$1 value contains both \" and ', which .fleet-board.yml cannot hold: $2" ;;
  esac
}

# q <value>: double-quoted, or single-quoted when it contains "
q() {
  case "$1" in
    *'"'*) printf "'%s'" "$1" ;;
    *) printf '"%s"' "$1" ;;
  esac
}

check_value --backend "$BACKEND"
check_value --repo "$REPO"
[ -n "${FBI_OWNER+x}" ] && check_value --owner "$FBI_OWNER"
[ -n "${FBI_TEST_ONE+x}" ] && check_value --test-one "$FBI_TEST_ONE"
[ -n "${FBI_TYPECHECK+x}" ] && check_value --typecheck "$FBI_TYPECHECK"
[ -n "${FBI_LINT+x}" ] && check_value --lint "$FBI_LINT"
[ -n "${FBI_QA_BUILD+x}" ] && check_value --qa-build "$FBI_QA_BUILD"
[ -n "${FBI_WT_DIR+x}" ] && check_value --worktrees-dir "$FBI_WT_DIR"
[ -n "${FBI_WT_SETUP+x}" ] && check_value --setup "$FBI_WT_SETUP"
[ -n "${FBI_MERGE+x}" ] && check_value --merge "$FBI_MERGE"
for v in ${STATE_VALS[@]+"${STATE_VALS[@]}"}; do check_value --state "$v"; done
for v in ${QA_PATHS[@]+"${QA_PATHS[@]}"}; do check_value --human-qa-path "$v"; done

render() {
  local i sep
  printf '%s\n' "$HEADER"
  printf 'board:\n'
  printf '  backend: %s\n' "$(q "$BACKEND")"
  printf '  repo: %s\n' "$(q "$REPO")"
  [ -n "$PROJECT" ] && printf '  project_number: %s\n' "$PROJECT"
  [ -n "${FBI_OWNER+x}" ] && printf '  project_owner: %s\n' "$(q "$FBI_OWNER")"
  if [ ${#STATE_KEYS[@]} -gt 0 ]; then
    printf '  states: {'
    sep=" "
    i=0
    while [ $i -lt ${#STATE_KEYS[@]} ]; do
      printf '%s%s: %s' "$sep" "${STATE_KEYS[$i]}" "$(q "${STATE_VALS[$i]}")"
      sep=", "
      i=$((i + 1))
    done
    printf ' }\n'
  fi
  if [ -n "${FBI_TEST_ONE+x}${FBI_TYPECHECK+x}${FBI_LINT+x}${FBI_QA_BUILD+x}" ]; then
    printf 'commands:\n'
    [ -n "${FBI_TEST_ONE+x}" ] && printf '  test_one: %s\n' "$(q "$FBI_TEST_ONE")"
    [ -n "${FBI_TYPECHECK+x}" ] && printf '  typecheck: %s\n' "$(q "$FBI_TYPECHECK")"
    [ -n "${FBI_LINT+x}" ] && printf '  lint: %s\n' "$(q "$FBI_LINT")"
    [ -n "${FBI_QA_BUILD+x}" ] && printf '  qa_build: %s\n' "$(q "$FBI_QA_BUILD")"
  fi
  if [ -n "${FBI_WT_DIR+x}${FBI_WT_SETUP+x}" ]; then
    printf 'worktrees:\n'
    [ -n "${FBI_WT_DIR+x}" ] && printf '  dir: %s\n' "$(q "$FBI_WT_DIR")"
    [ -n "${FBI_WT_SETUP+x}" ] && printf '  setup: %s\n' "$(q "$FBI_WT_SETUP")"
  fi
  if [ ${#QA_PATHS[@]} -gt 0 ]; then
    printf 'human_qa_paths: ['
    sep=""
    for v in "${QA_PATHS[@]}"; do printf '%s%s' "$sep" "$(q "$v")"; sep=", "; done
    printf ']\n'
  fi
  if [ -n "${FBI_MERGE+x}" ]; then
    printf 'merge:\n'
    printf '  policy: %s\n' "$(q "$FBI_MERGE")"
  fi
  return 0
}

# The temp file sits beside the target so the final mv is an atomic rename.
# It is removed on every exit path; after the mv it no longer exists.
TMP="$(mktemp "$DIR/.fleet-board.yml.XXXXXX")" || die 1 "cannot create a temp file in $DIR"
trap 'rm -f "$TMP"' EXIT
render > "$TMP" || die 1 "cannot write $TMP"
chmod 644 "$TMP"

# --- Step 5: validate ------------------------------------------------------
ERR="$(FLEET_BOARD_CONFIG="$TMP" bash "$HERE/config.sh" --check 2>&1 >/dev/null)" || {
  printf 'fleet-board init: the rendered config fails config.sh --check:\n%s\n' "$ERR" >&2
  exit 1
}
FLEET_CFG="$(FLEET_BOARD_CONFIG="$TMP" bash "$HERE/config.sh")" || die 1 "cannot read the rendered config"

# --- Step 6: backend setup -------------------------------------------------
state_color() {
  case "$1" in
    backlog) echo cfd3d7 ;;
    ready) echo 0e8a16 ;;
    in_progress) echo 1d76db ;;
    in_review) echo 5319e7 ;;
    human_qa) echo fbca04 ;;
    blocked) echo b60205 ;;
    done) echo 0e8a16 ;;
    wont_do) echo ffffff ;;
  esac
}

create_needs_human_qa() {
  gh label create needs-human-qa --repo "$REPO" --color d93f0b \
    --description "fleet-board: route to Human QA" --force >/dev/null \
    || die 1 "cannot create label needs-human-qa in $REPO"
}

if [ "$BACKEND" = github-labels ]; then
  for s in $FB_STATES; do
    name="$(fb_state_name "$s")"
    gh label create "$name" --repo "$REPO" --color "$(state_color "$s")" \
      --description "fleet-board state: $s" --force >/dev/null \
      || die 1 "cannot create label $name in $REPO"
  done
  create_needs_human_qa
else
  OWNER_EFF="$(fb_cfg board.project_owner)"
  [ -n "$OWNER_EFF" ] || OWNER_EFF="${REPO%%/*}"
  FIELDS="$(gh project field-list "$PROJECT" --owner "$OWNER_EFF" --format json --limit 100)" \
    || die 1 "cannot read the fields of project $PROJECT (owner $OWNER_EFF)"
  HAS_STATUS="$(jq -r 'any(.fields[]; .name == "Status")' <<<"$FIELDS" 2>/dev/null)" \
    || die 1 "cannot parse the fields of project $PROJECT"
  [ "$HAS_STATUS" = true ] || die 1 "project $PROJECT has no Status field"
  OPTIONS="$(jq -r 'first(.fields[] | select(.name == "Status")) | .options[].name' <<<"$FIELDS")" \
    || die 1 "cannot parse the Status options of project $PROJECT"
  LACKING=""; HINT=""
  for s in $FB_STATES; do
    name="$(fb_state_name "$s")"
    if ! printf '%s\n' "$OPTIONS" | grep -Fxq -- "$name"; then
      LACKING="${LACKING:+$LACKING, }$name"
      HINT="${HINT:+$HINT, }--state $s=<Name>"
    fi
  done
  if [ -n "$LACKING" ]; then
    die 1 "project $PROJECT Status field lacks option(s): $LACKING; add it in the project's Status field or map it with $HINT"
  fi
  create_needs_human_qa
fi

# The bug label (both backends): created only when absent, never overwritten.
# The search is fuzzy (it also returns bugfix, not-a-bug, ...), so list up to
# 1000 matches rather than gh's default 30, and match the name exactly below.
BUGS="$(gh label list --repo "$REPO" --search bug --json name --limit 1000)" \
  || die 1 "cannot check bug label in $REPO (gh label list failed)"
HAS_BUG="$(jq -r 'if type == "array" then any(.[]; .name == "bug") else error("not a list") end' <<<"$BUGS" 2>/dev/null)" \
  || die 1 "cannot check bug label in $REPO (unreadable gh label list output)"
if [ "$HAS_BUG" != true ]; then
  gh label create bug --repo "$REPO" --color d73a4a --description "Something isn't working" >/dev/null \
    || die 1 "cannot check bug label in $REPO (gh label create bug failed)"
fi

# --- Step 7: write ---------------------------------------------------------
mv -f "$TMP" "$TARGET" || die 1 "cannot write $TARGET"
printf 'wrote %s\n' "$TARGET"
