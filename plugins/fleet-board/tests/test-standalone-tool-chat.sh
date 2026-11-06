#!/usr/bin/env bash
# Focused tool-chat protocol cases against an ephemeral loopback provider.
set -uo pipefail
unset CDPATH
case "${1:-}" in protocol|limit|malformed) ;; *) echo 'usage: test-standalone-tool-chat.sh protocol|limit|malformed' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$TESTS/../scripts/standalone/tool-chat.py"
TMP="$(mktemp -d)"; SERVER=""
trap '[ -z "$SERVER" ] || { kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; }; rm -rf "$TMP"' EXIT
mkdir "$TMP/work" "$TMP/scratch"
printf 'hello\n' > "$TMP/work/readme.txt"
cat > "$TMP/server.py" <<'PY'
import http.server,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); case=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  n=len(list(root.glob('request-*.json')))+1
  (root/f'request-{n}.json').write_text(json.dumps(req))
  args='{"path":"readme.txt"}' if case != 'malformed' else '{bad'
  calls=[{'id':'call-1','type':'function','function':{'name':'read_file','arguments':args}}]
  if case == 'limit': calls.append({'id':'call-2','type':'function','function':{'name':'read_file','arguments':'{"path":"readme.txt"}'}})
  msg={'role':'assistant','content':None,'tool_calls':calls} if n==1 else {'role':'assistant','content':'finished'}
  body=json.dumps({'model':'google/gemini-test','choices':[{'message':msg,'finish_reason':'tool_calls' if n==1 else 'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':3}}).encode()
  self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
s=http.server.HTTPServer(('127.0.0.1',0),H); (root/'port').write_text(str(s.server_port)); s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP" "$1" & SERVER=$!
for i in 1 2 3 4 5; do [ -s "$TMP/port" ] && break; sleep 1; done
[ -s "$TMP/port" ] || exit 1
jq -n --arg root "$TMP/work" --arg url "http://127.0.0.1:$(cat "$TMP/port")" '{version:1,base_url:$url,key_env:"-",model:"google/gemini-test",messages:[{role:"user",content:"read it"}],worktree:$root,image:"fixture-image",tests:{},limits:{max_calls:1,seconds:20,memory_mb:256,pids:64,max_output_bytes:4096}}' > "$TMP/request.json"
if [ "$1" = protocol ]; then
  python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out" || exit 1
  jq -e '.outcome == "done" and .text == "finished" and .usage.input_tokens == 20 and .usage.output_tokens == 6' "$TMP/out" >/dev/null || exit 1
  jq -e '.tools | length == 3' "$TMP/request-1.json" >/dev/null || exit 1
  jq -e '[.messages[] | select(.role == "assistant" and .tool_calls[0].id == "call-1")] | length == 1' "$TMP/request-2.json" >/dev/null || exit 1
  jq -e 'any(.messages[]; .role == "tool" and .tool_call_id == "call-1" and (.content | contains("hello")))' "$TMP/request-2.json" >/dev/null || exit 1
else
  if python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out"; then echo "FAIL: $1 accepted" >&2; exit 1; fi
  [ -f "$TMP/request-1.json" ] && [ ! -e "$TMP/request-2.json" ] || exit 1
fi
echo "PASS: $1"
