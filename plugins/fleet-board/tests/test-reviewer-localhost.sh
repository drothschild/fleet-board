#!/usr/bin/env bash
# Preset contract plus an opt-in real sandbox probe (no model call).
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shlex, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
args = shlex.split(json.loads((root/'plugins/fleet-board/scripts/providers/presets.json').read_text())['codex']['review_command'])
flags = []
config = {}
for i, arg in enumerate(args[:-1]):
    if arg == '-c':
        flags.extend(['-c', args[i+1]])
        key, value = args[i+1].split('=', 1)
        config[key] = value
assert config.get('sandbox_workspace_write.network_access') == 'true', 'reviewer must permit local HTTP tests'
assert config.get('features.network_proxy.enabled') == 'true', 'network proxy must restrict egress'
assert config.get('features.network_proxy.allow_local_binding') == 'true'
for key in ['proxy_url', 'socks_url']:
    assert config.get('features.network_proxy.'+key) == '"http://127.0.0.1:0"', 'parallel reviews need ephemeral proxy ports'
assert config.get('features.network_proxy.domains') == '{"localhost"="allow","127.0.0.1"="allow","::1"="allow"}'
for key in ['exclude_tmpdir_env_var', 'exclude_slash_tmp']:
    assert config.get('sandbox_workspace_write.'+key) == 'true', 'preserve scratch isolation'
print('PASS localhost preset and isolation contract')
if os.environ.get('FLEET_TEST_CODEX_SANDBOX') != '1':
    print('SKIP live sandbox probe (set FLEET_TEST_CODEX_SANDBOX=1)')
    sys.exit(0)
probe = r'''
import errno, http.server, os, pathlib, socket, subprocess, threading, urllib.request
for command in (["mktemp"], ["mktemp", "-d"]):
    result = pathlib.Path(subprocess.check_output(command, text=True).strip())
    assert result.parent == pathlib.Path(os.environ["TMPDIR"])
print("PASS shell temporary files stay inside scratch")
pathlib.Path('scratch-write').write_text('ok')
pathlib.Path('scratch-write').unlink()
print('PASS scratch writes permitted')
server = http.server.HTTPServer(('127.0.0.1', 0), http.server.BaseHTTPRequestHandler)
thread = threading.Thread(target=server.handle_request, daemon=True); thread.start()
try:
    urllib.request.build_opener(urllib.request.ProxyHandler({})).open('http://127.0.0.1:%s/' % server.server_port)
except urllib.error.HTTPError as e:
    assert e.code == 501
thread.join(5); server.server_close(); assert not thread.is_alive()
print('PASS localhost bind/listen/request')
with socket.socket() as s:
    s.settimeout(2)
    assert s.connect_ex(('1.1.1.1', 443)) in (errno.EPERM, errno.EACCES), 'direct public networking must be denied'
print('PASS direct public networking denied')
try:
    pathlib.Path('../outside-write').write_text('unexpected')
except PermissionError:
    print('PASS writes outside scratch denied')
else:
    raise AssertionError('write escaped scratch')
'''
with tempfile.TemporaryDirectory() as parent:
    scratch = pathlib.Path(parent)/'scratch'; scratch.mkdir()
    bindir = scratch/'.fleet-board-bin'; bindir.mkdir()
    tmpdir = scratch/'.fleet-board-tmp'; tmpdir.mkdir()
    shutil.copy(root/'plugins/fleet-board/scripts/providers/reviewer-mktemp.sh', bindir/'mktemp')
    (bindir/'mktemp').chmod(0o755)
    env_args = ['env', 'TMPDIR='+str(tmpdir), 'FLEET_REVIEW_MKTEMP='+shutil.which('mktemp'), 'PATH='+str(bindir)+os.pathsep+os.environ['PATH']]
    subprocess.run(['codex' , 'sandbox', '-c', 'sandbox_mode="workspace-write"', *flags, '--', *env_args, sys.executable, '-c', probe], cwd=scratch, check=True)
PY
