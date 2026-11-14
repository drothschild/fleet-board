#!/bin/bash
# Card 401: render one session .jsonl as readable text (supervisor/sessiontext.py).
set -u
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/session-text.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }
render() {
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 -c \
    'import sys; from supervisor import sessiontext; sys.stdout.write(sessiontext.render(sys.argv[1]))' "$1" 2>&1
}

printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the assistant, verbatim."}]}}' > "$tmp/text.jsonl"
out=$(render "$tmp/text.jsonl")
case "$out" in *"Hello from the assistant, verbatim."*) ok "An assistant text event in the .jsonl appears verbatim in the rendered text";; *) bad "An assistant text event in the .jsonl appears verbatim in the rendered text: $out";; esac

printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la /tmp/zzz"}}]}}' > "$tmp/tool.jsonl"
out=$(render "$tmp/tool.jsonl")
case "$out" in *Bash*"ls -la /tmp/zzz"*) ok "A tool call event renders showing the tool's name and its input";; *) bad "A tool call event renders showing the tool's name and its input: $out";; esac

printf '%s\n' 'provider says: plain line, not json' > "$tmp/plain.jsonl"
out=$(render "$tmp/plain.jsonl")
[ "$out" = "provider says: plain line, not json" ] && ok "A non-JSON line in the log passes through to the rendered text unchanged" || bad "A non-JSON line in the log passes through to the rendered text unchanged: $out"

: > "$tmp/empty.jsonl"
out=$(render "$tmp/empty.jsonl")
[ "$out" = "no output" ] && ok 'An empty log file renders as "no output"' || bad "An empty log file renders as \"no output\": $out"

{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"first survives"}]}}'; printf '%s' '{"type":"assistant","message":{"content":[{"type":"te'; } > "$tmp/half.jsonl"
out=$(render "$tmp/half.jsonl"); rc=$?
case "$out" in *"first survives"*) case "$out" in *'"type":"te'*|*Traceback*) bad "A half-written last line in the log is skipped and the rest renders, instead of failing: $out";; *) ok "A half-written last line in the log is skipped and the rest renders, instead of failing";; esac;; *) bad "A half-written last line in the log is skipped and the rest renders, instead of failing: $out";; esac

[ "$fail" = 0 ]
