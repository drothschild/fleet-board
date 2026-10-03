#!/usr/bin/env bash
#
# Fake 'gh' for offline testing.
#
# Environment:
#   FAKE_GH_DIR: writable state directory for calls.log, bodies/, inputs/
#   FAKE_GH_ROUTES: path to routes file
#   FAKE_GH_DELAY: (optional) seconds to sleep before replying to 'issue edit' calls
#
# Routes file format (tab-separated):
#   <glob>\t<exit-code>\t<fixture-path-or-dash>
#
# Blank lines and lines starting with '#' are ignored.
# The first matching glob wins.
# Paths starting with '/' are absolute; others are relative to the routes file's directory.

set -uo pipefail

die() {
  printf 'fake-gh: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ -n "${FAKE_GH_DIR:-}" ] || die "FAKE_GH_DIR not set" 1
[ -n "${FAKE_GH_ROUTES:-}" ] || die "FAKE_GH_ROUTES not set" 1
[ -d "$FAKE_GH_DIR" ] || die "FAKE_GH_DIR is not a directory: $FAKE_GH_DIR" 1
[ -f "$FAKE_GH_ROUTES" ] || die "FAKE_GH_ROUTES file not found: $FAKE_GH_ROUTES" 1

# Record argument boundaries: each argv element one per line to argv/<seq>
# Use mkdir-based counter for thread-safety (atomic create of "count.lock")
mkdir -p "$FAKE_GH_DIR/argv"
SEQ=0
tries=0
while ! mkdir "$FAKE_GH_DIR/count.lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -le 500 ] || die "argv counter lock stuck: $FAKE_GH_DIR/count.lock" 98
  sleep 0.01
done
if [ -f "$FAKE_GH_DIR/count" ]; then
  SEQ=$(cat "$FAKE_GH_DIR/count")
fi
SEQ=$((SEQ + 1))
printf '%d\n' "$SEQ" > "$FAKE_GH_DIR/count"
rmdir "$FAKE_GH_DIR/count.lock"

# Write each argument to a file
ARGV_FILE="$FAKE_GH_DIR/argv/$(printf '%010d' "$SEQ")"
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$ARGV_FILE"
done

# Log the call. The first column is $PPID, the process that ran gh, not
# this fake's own pid: every gh call is a fresh process, so $$ would differ
# on every line and could not show which caller made which calls.
{
  printf '%s\t%s\n' "$PPID" "$*"
} >> "$FAKE_GH_DIR/calls.log"

# Handle --body-file: copy the file byte-for-byte
for i in "$@"; do
  if [ "$i" = "--body-file" ]; then
    # Argument after --body-file is the filename
    # We need to find the next argument
    copy_next=1
    continue
  fi
  if [ "${copy_next:-0}" = 1 ]; then
    if [ -f "$i" ]; then
      mkdir -p "$FAKE_GH_DIR/bodies"
      cp "$i" "$FAKE_GH_DIR/bodies/$$-$RANDOM"
    fi
    copy_next=0
  fi
done

# Handle --input -: save stdin byte-for-byte
for i in "$@"; do
  if [ "$i" = "--input" ]; then
    input_next=1
    continue
  fi
  if [ "${input_next:-0}" = 1 ] && [ "$i" = "-" ]; then
    mkdir -p "$FAKE_GH_DIR/inputs"
    cat > "$FAKE_GH_DIR/inputs/$$-$RANDOM"
  fi
  if [ "${input_next:-0}" = 1 ]; then
    input_next=0
  fi
done

# Apply FAKE_GH_DELAY for 'issue edit' calls
if [ "${FAKE_GH_DELAY:-}" != "" ]; then
  case "$*" in
    *"issue edit"*)
      sleep "$FAKE_GH_DELAY"
      ;;
  esac
fi

# Find matching route
routes_dir="$(dirname "$FAKE_GH_ROUTES")"
while IFS=$'\t' read -r glob exit_code fixture; do
  # Skip blank lines and comments
  [ -z "$glob" ] && continue
  [[ "$glob" == \#* ]] && continue

  # Match with case (leaving glob unquoted on purpose for glob expansion)
  case "$*" in
    $glob)
      if [ "$fixture" = "-" ]; then
        exit "$exit_code"
      else
        # Resolve relative paths
        if [[ "$fixture" == /* ]]; then
          cat "$fixture" || die "cannot read fixture: $fixture" 1
        else
          cat "$routes_dir/$fixture" || die "cannot read fixture: $fixture" 1
        fi
        exit "$exit_code"
      fi
      ;;
  esac
done < "$FAKE_GH_ROUTES"

# No matching route
printf 'fake-gh: no route for: %s\n' "$*" >&2
exit 99
