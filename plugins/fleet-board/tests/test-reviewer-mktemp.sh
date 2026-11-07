#!/usr/bin/env bash
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_MKTEMP="$(command -v mktemp)"
WORK="$("$REAL_MKTEMP" -d)"
trap 'rm -rf "$WORK"' EXIT
export FLEET_REVIEW_MKTEMP="$REAL_MKTEMP" TMPDIR="$WORK/scratch space"
mkdir -p "$TMPDIR"
WRAPPER="$HERE/../scripts/providers/reviewer-mktemp.sh"
file="$(bash "$WRAPPER")"
dir="$(bash "$WRAPPER" -d)"
case "$file" in "$TMPDIR"/*) ;; *) echo 'FAIL default file escaped scratch'; exit 1 ;; esac
case "$dir" in "$TMPDIR"/*) ;; *) echo 'FAIL default directory escaped scratch'; exit 1 ;; esac
[ -f "$file" ] && [ -d "$dir" ]
explicit="$(bash "$WRAPPER" "$WORK/explicit.XXXXXX")"
[ -f "$explicit" ]
case "$explicit" in "$WORK"/explicit.*) ;; *) exit 1 ;; esac
printf 'PASS default file, default directory, spaces, explicit template\n'
