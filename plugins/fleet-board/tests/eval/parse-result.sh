#!/usr/bin/env bash
#
# parse-result.sh REPORT DEFECT_ID
#
# Prints "caught" when REPORT has a Critical or Important finding that matches the
# defect's pattern in defects/catalogue.tsv, otherwise "missed". A match anywhere
# else (a Minor finding, the For-the-card text) does not count. Exits 0 either way,
# 2 on a usage error (unreadable report, unknown defect id).

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CAT="$HERE/defects/catalogue.tsv"

if [ "$#" -ne 2 ]; then
  echo "usage: parse-result.sh REPORT DEFECT_ID" >&2
  exit 2
fi
report="$1"
id="$2"
[ -r "$report" ] || { echo "parse-result: cannot read report: $report" >&2; exit 2; }

pattern="$(awk -F'\t' -v id="$id" '$1 !~ /^#/ && $1 == id { print $5; exit }' "$CAT")"
if [ -z "$pattern" ]; then
  echo "parse-result: unknown defect id: $id" >&2
  exit 2
fi

# Only lines of the ## Findings section that start with a Critical or Important tag.
if tr -d '\r' < "$report" \
   | awk '/^##[ \t]+/ { in_f = ($0 ~ /^##[ \t]+Findings[ \t]*$/); next } in_f && /^- \[(Critical|Important)\] /' \
   | grep -Eiq -- "$pattern"; then
  echo caught
else
  echo missed
fi
