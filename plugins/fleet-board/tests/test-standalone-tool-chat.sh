#!/usr/bin/env bash
# Focused tool-chat protocol cases against an ephemeral loopback provider.
set -uo pipefail
unset CDPATH
case "${1:-}" in protocol|limit|malformed|escape|hardlink|write|unapproved|test-run|test-real|test-kill-real|paid-unknown|paid-budget) ;; *) echo 'usage: test-standalone-tool-chat.sh protocol|limit|malformed' >&2; exit 2 ;; esac
TESTS="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$TESTS/../scripts/standalone/tool-chat.py"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; SERVER=""
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
  name='read_file'; args='{"path":"readme.txt"}'
  if case == 'malformed': args='{bad'
  if case in ('escape','hardlink'): args='{"path":"link"}'
  if case == 'write': name='write_file'; args='{"path":"output.txt","content":"changed"}'
  if case == 'unapproved': name='run_test'; args='{"test_id":"not-approved"}'
  if case in ('test-run','test-real','test-kill-real'): name='run_test'; args='{"test_id":"smoke"}'
  calls=[{'id':'call-1','type':'function','function':{'name':name,'arguments':args}}]
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
if [ "$1" = paid-budget ]; then
  export TEST_SECRET=controller-secret
  jq '.key_env = "TEST_SECRET" | .pricing = {input_usd_per_million:1000000,output_usd_per_million:1000000} | .max_cost_usd = 1' "$TMP/request.json" > "$TMP/new" && mv "$TMP/new" "$TMP/request.json"
  if python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out"; then echo 'FAIL: exhausted budget accepted' >&2; exit 1; fi
  [ -e "$TMP/request-1.json" ] && [ ! -e "$TMP/request-2.json" ] || exit 1
  jq -e '.outcome == "failed" and .usage.cost_usd == 13 and .usage.unknown == false and (.error | contains("budget"))' "$TMP/out" >/dev/null || { cat "$TMP/out" >&2; exit 1; }
  echo 'PASS: paid-budget'; exit 0
fi
if [ "$1" = paid-unknown ]; then
  export TEST_SECRET=controller-secret
  jq '.key_env = "TEST_SECRET"' "$TMP/request.json" > "$TMP/new" && mv "$TMP/new" "$TMP/request.json"
  if python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out"; then echo 'FAIL: unbudgeted paid dispatch accepted' >&2; exit 1; fi
  [ ! -e "$TMP/request-1.json" ] || exit 1
  jq -e '.outcome == "failed" and (.error | contains("budget"))' "$TMP/out" >/dev/null || exit 1
  echo 'PASS: paid-unknown'; exit 0
fi
if [ "$1" = escape ]; then ln -s "$TMP/secret" "$TMP/work/link"; echo secret > "$TMP/secret"; fi
if [ "$1" = hardlink ]; then echo secret > "$TMP/secret"; ln "$TMP/secret" "$TMP/work/link"; fi
if [ "$1" = test-kill-real ]; then
  mkdir -p "$TMP/work/.git/objects/info"
  jq '.image = "ghcr.io/home-assistant/home-assistant:stable" | .tests = {smoke:["/bin/sh","-c","echo ready > /work/ready; exec sleep 30"]}' "$TMP/request.json" > "$TMP/new" && mv "$TMP/new" "$TMP/request.json"
  python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out" & adapter=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$TMP/work/ready" ] && break; sleep 1; done
  [ -e "$TMP/work/ready" ] || { kill -KILL "$adapter" 2>/dev/null || true; echo 'FAIL: isolated test did not start' >&2; exit 1; }
  kill -KILL "$adapter"; wait "$adapter" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    remaining="$(docker ps -a --filter "name=fleet-tool-$adapter-" --format '{{.Names}}')"
    if [ -z "$remaining" ]; then echo 'PASS: test-kill-real'; exit 0; fi
    sleep 1
  done
  echo 'FAIL: container survived hard interruption' >&2; exit 1
fi
if [ "$1" = test-real ]; then
  mkdir -p "$TMP/work/.git/objects/info"
  export TEST_SECRET=controller-secret
  printf 'hidden' > "$TMP/work/.git/config"
  printf 'secret' > "$TMP/host-secret"
  ln -s "$TMP/host-secret" "$TMP/work/link"
  jq '.image = "ghcr.io/home-assistant/home-assistant:stable" | .tests = {smoke:["/bin/sh","-c","test -z \"${TEST_SECRET:-}\" && test ! -e /host-secret && test ! -r /work/link && test ! -e /work/.git/config && ! grep -q '^eth' /proc/net/route && echo tested && echo isolated > /work/result.txt"]}' "$TMP/request.json" > "$TMP/new" && mv "$TMP/new" "$TMP/request.json"
fi
if [ "$1" = test-run ]; then
  mkdir -p "$TMP/work/.git/objects/info" "$TMP/bin"
  cat > "$TMP/bin/docker" <<DOCKER
#!/bin/sh
printf '%s\\n' "\$*" >> "$TMP/docker.log"
if [ -n "\${TEST_SECRET:-}" ]; then exit 1; fi
case "\$1" in create) echo fixture ;; start) echo tested ;; rm) : ;; *) exit 1 ;; esac
DOCKER
  chmod +x "$TMP/bin/docker"
  export PATH="$TMP/bin:$PATH" TEST_SECRET=controller-secret
  jq '.tests = {smoke:["/bin/true"]}' "$TMP/request.json" > "$TMP/new" && mv "$TMP/new" "$TMP/request.json"
fi
if [ "$1" = protocol ] || [ "$1" = write ] || [ "$1" = test-run ] || [ "$1" = test-real ]; then
  python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out" || exit 1
  jq -e '.outcome == "done" and .text == "finished" and .usage.input_tokens == 20 and .usage.output_tokens == 6' "$TMP/out" >/dev/null || exit 1
  jq -e '.tools | length == 3' "$TMP/request-1.json" >/dev/null || exit 1
  jq -e '[.messages[] | select(.role == "assistant" and .tool_calls[0].id == "call-1")] | length == 1' "$TMP/request-2.json" >/dev/null || exit 1
  if [ "$1" = protocol ]; then jq -e 'any(.messages[]; .role == "tool" and .tool_call_id == "call-1" and (.content | contains("hello")))' "$TMP/request-2.json" >/dev/null || exit 1; fi
  if [ "$1" = write ]; then [ "$(cat "$TMP/work/output.txt")" = changed ] || exit 1; fi
  if [ "$1" = test-real ]; then
    [ "$(cat "$TMP/work/result.txt" 2>/dev/null)" = isolated ] || { cat "$TMP/request-2.json" >&2; exit 1; }
    jq -e 'any(.messages[]; .role == "tool" and .tool_call_id == "call-1" and (.content | contains("tested")))' "$TMP/request-2.json" >/dev/null || exit 1
  fi
  if [ "$1" = test-run ]; then
    grep -q -- '--network none' "$TMP/docker.log" && grep -q -- '--read-only' "$TMP/docker.log" && grep -q '^rm -f ' "$TMP/docker.log" || exit 1
    jq -e 'any(.messages[]; .role == "tool" and .tool_call_id == "call-1" and (.content | contains("tested")))' "$TMP/request-2.json" >/dev/null || exit 1
  fi
else
  if python3 "$SCRIPT" --request "$TMP/request.json" --scratch "$TMP/scratch" > "$TMP/out"; then echo "FAIL: $1 accepted" >&2; exit 1; fi
  [ -f "$TMP/request-1.json" ] && [ ! -e "$TMP/request-2.json" ] || exit 1
fi
echo "PASS: $1"
