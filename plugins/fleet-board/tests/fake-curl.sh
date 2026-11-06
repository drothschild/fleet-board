#!/usr/bin/env bash
#
# Fake 'curl' for offline testing of providers/chat.sh.
#
# Environment:
#   FAKE_CURL_LOG:     file the calls are appended to
#   FAKE_CURL_REPLIES: file with one reply per call, consumed in order:
#                        <http_code> <body-file> [retry-after-seconds]
#                      a relative body-file is relative to the replies file;
#                      a blank or '#' line is ignored
#
# Log format, per call:
#   CALL <n>
#   ARG <argv element>             one per argv element
#   FILE <path>                    for every argument of the form @<path>
#   DATA <line>                    the file's contents, one DATA per line
#   MODE <path> <octal>            the file's permission bits at call time
#
# Honours -w '%{http_code}' (printed on stdout), -D <file> (response headers,
# with Retry-After when the reply has a third field), -o <file> (body) and
# --data-binary @<file>. Without -o the body goes to stdout.

set -uo pipefail

die() {
  printf 'fake-curl: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ -n "${FAKE_CURL_LOG:-}" ] || die "FAKE_CURL_LOG not set" 1
[ -n "${FAKE_CURL_REPLIES:-}" ] || die "FAKE_CURL_REPLIES not set" 1
[ -f "$FAKE_CURL_REPLIES" ] || die "FAKE_CURL_REPLIES file not found: $FAKE_CURL_REPLIES" 1

COUNT_FILE="${FAKE_CURL_REPLIES}.count"
n=0
[ -f "$COUNT_FILE" ] && n="$(cat "$COUNT_FILE")"
n=$((n + 1))
printf '%d\n' "$n" > "$COUNT_FILE"

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || printf '?'
}

out_file=""
hdr_file=""
want_code=0
prev=""
{
  printf 'CALL %d\n' "$n"
  for a in "$@"; do
    printf 'ARG %s\n' "$a"
    case "$a" in
      @*)
        f="${a#@}"
        printf 'FILE %s\n' "$f"
        if [ -f "$f" ]; then
          while IFS= read -r line || [ -n "$line" ]; do
            printf 'DATA %s\n' "$line"
          done < "$f"
          printf 'MODE %s %s\n' "$f" "$(file_mode "$f")"
        fi
        ;;
    esac
  done
} >> "$FAKE_CURL_LOG"

for a in "$@"; do
  case "$prev" in
    -o) out_file="$a" ;;
    -D) hdr_file="$a" ;;
    -w) case "$a" in *'%{http_code}'*) want_code=1 ;; esac ;;
  esac
  prev="$a"
done

# nth non-blank, non-comment reply line (the last one repeats if exhausted)
reply=""
i=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  i=$((i + 1))
  reply="$line"
  [ "$i" -eq "$n" ] && break
done < "$FAKE_CURL_REPLIES"
[ -n "$reply" ] || die "no reply configured" 1

code="$(printf '%s' "$reply" | awk '{print $1}')"
body="$(printf '%s' "$reply" | awk '{print $2}')"
retry="$(printf '%s' "$reply" | awk '{print $3}')"
case "$body" in
  /*) ;;
  *) body="$(dirname "$FAKE_CURL_REPLIES")/$body" ;;
esac
[ -f "$body" ] || die "reply body not found: $body" 1

if [ -n "$hdr_file" ]; then
  {
    printf 'HTTP/1.1 %s X\r\n' "$code"
    printf 'Content-Type: application/json\r\n'
    [ -n "$retry" ] && printf 'Retry-After: %s\r\n' "$retry"
    printf '\r\n'
  } > "$hdr_file"
fi

if [ -n "$out_file" ]; then
  cat "$body" > "$out_file"
else
  cat "$body"
fi
[ "$want_code" -eq 1 ] && printf '%s' "$code"
exit 0
