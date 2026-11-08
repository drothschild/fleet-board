"""Host-enforced worker isolation policies. Unsupported hosts fail closed."""
import os
import errno
import json
import stat
from pathlib import Path
import selectors
import signal
import shutil
import shlex
import secrets
import socket
import struct
import subprocess
import tempfile
import threading
import time


class IsolationUnavailable(RuntimeError):
    pass


def _forged_control_frame(attempt_id, capability):
    """Build an authenticated request for an operation workers must not have."""
    if (not isinstance(attempt_id, str) or not attempt_id
            or not isinstance(capability, str) or not capability):
        raise ValueError('forged-control probe requires an authorized attempt')
    envelope = {'schema_version': 1, 'operation': 'human_control',
                'attempt_id': attempt_id, 'capability': capability,
                'request': {'attempt_id': attempt_id}}
    payload = json.dumps(envelope, separators=(',', ':'), allow_nan=False).encode('utf-8')
    return struct.pack('!I', len(payload)) + payload


def _forged_control_rejection_frame():
    payload = json.dumps({'schema_version': 1, 'error': 'request rejected'},
                         separators=(',', ':'), allow_nan=False).encode('utf-8')
    return struct.pack('!I', len(payload)) + payload


def _private_directory(path, *, create=False):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('isolation paths must be absolute')
    if create:
        if path.parent.is_symlink() or path.parent.resolve(strict=True) != path.parent:
            raise ValueError('isolation parent is not canonical')
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir() or path.resolve(strict=True) != path:
        raise ValueError('isolation path is not a real directory')
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('isolation path must be private to the current user')
    return str(path)


def build_policy(workspace, private_git, channels):
    """Build a deny-by-default policy around three attempt-owned directories."""
    workspace = _private_directory(workspace)
    private_git = _private_directory(private_git, create=True)
    channels = _private_directory(channels, create=True)
    roots = (workspace, private_git, channels)
    if any(os.path.commonpath((left, right)) in (left, right)
           for index, left in enumerate(roots) for right in roots[index + 1:]):
        raise ValueError('isolation roots must not contain one another')
    common = {'workspace': workspace, 'private_git': private_git,
              'channels': channels, 'channel_names': ('result', 'heartbeat', 'scope-request', 'inference')}
    if os.uname().sysname == 'Darwin':
        roots = (workspace, private_git, channels)
        if any(any(ord(char) < 32 for char in path) for path in roots):
            raise ValueError('control character in isolation path')
        allow_reads = ' '.join('(subpath ' + json.dumps(p) + ')' for p in
                               ('/System', '/usr', '/bin', '/sbin', '/Library/Apple/System/Library'))
        writable_roots = (workspace, private_git)
        allow_write = ' '.join('(subpath ' + json.dumps(p) + ')' for p in writable_roots)
        allow_work = ' '.join('(subpath ' + json.dumps(p) + ')' for p in roots)
        inference_socket = os.path.join(channels, 'inference.sock')
        text = ('(version 1)\n(deny default)\n(allow process-fork)\n(allow process-exec)\n(allow sysctl-read)\n'
                '(allow file-read* ' + allow_reads + ')\n'
                '(allow file-write* ' + allow_write + ')\n'
                '(allow file-read* ' + allow_work + ')\n'
                '(allow network-outbound (remote unix-socket (path-literal ' +
                json.dumps(inference_socket) + ')))\n')
        return {**common, 'backend': 'macos', 'text': text, 'command': shutil.which('sandbox-exec')}
    if os.uname().sysname == 'Linux':
        return {**common, 'backend': 'linux', 'text': 'bubblewrap deny-by-default; network and host home unshared',
                'command': shutil.which('bwrap')}
    return {**common, 'backend': 'unsupported', 'text': 'unsupported host', 'command': None}


def prepare_private_git(source_repository, workspace, private_git):
    """Create isolated local copies for the controller and worker without shared metadata."""
    source = Path(source_repository)
    workspace = Path(_private_directory(workspace))
    private_git = Path(_private_directory(private_git))
    if (not source.is_absolute() or source.is_symlink() or not source.is_dir()
            or source.resolve(strict=True) != source):
        raise IsolationUnavailable('source repository must be a canonical local directory')
    if any(workspace.iterdir()) or any(private_git.iterdir()):
        raise IsolationUnavailable('private Git destinations must be empty')
    environment = {'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent',
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                   'GIT_TERMINAL_PROMPT': '0'}

    def git(repository, *arguments):
        result = subprocess.run(['git', '-C', str(repository), *arguments],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30, check=False,
                                close_fds=True, env=environment)
        if result.returncode != 0:
            raise IsolationUnavailable('private Git setup failed: ' +
                                       result.stderr.decode('utf-8', 'replace')[:160].strip())
        return result.stdout.decode('utf-8', 'replace').strip()

    def clone(source_path, destination):
        result = subprocess.run(['git', 'clone', '--no-local', '--no-hardlinks',
                                 '--no-checkout', str(source_path), str(destination)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30, check=False,
                                close_fds=True, env=environment)
        if result.returncode != 0:
            raise IsolationUnavailable('private Git clone failed: ' +
                                       result.stderr.decode('utf-8', 'replace')[:160].strip())

    try:
        clone(source, private_git)
        git(private_git, 'remote', 'remove', 'origin')
        clone(private_git, workspace)
        git(workspace, 'remote', 'remove', 'origin')
        git(workspace, 'checkout', '--detach', 'HEAD')
        roots = (workspace.resolve(strict=True), private_git.resolve(strict=True))
        for repository, root in ((workspace, roots[0]), (private_git, roots[1])):
            metadata = repository / '.git'
            if metadata.is_symlink() or not metadata.is_dir() or metadata.resolve(strict=True) != metadata:
                raise IsolationUnavailable('private Git metadata is not a real directory')
            common = Path(git(repository, 'rev-parse', '--git-common-dir'))
            if not common.is_absolute():
                common = repository / common
            common = common.resolve(strict=True)
            if os.path.commonpath((str(root), str(common))) != str(root):
                raise IsolationUnavailable('Git common directory escaped private root')
            if (metadata / 'objects' / 'info' / 'alternates').exists():
                raise IsolationUnavailable('Git alternates are forbidden')
            config = git(repository, 'config', '--local', '--list').lower()
            forbidden = ('credential.', 'include.path=', 'includeif.', 'remote.',
                         'url.', 'core.sshcommand=', 'extensions.partialclone=',
                         'worktreeconfig=')
            if any(entry in config for entry in forbidden):
                raise IsolationUnavailable('private Git config contains an external reference')
            if any(path.is_symlink() for path in metadata.rglob('*')):
                raise IsolationUnavailable('private Git metadata contains a symlink')
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        if isinstance(exc, IsolationUnavailable):
            raise
        raise IsolationUnavailable(str(exc)[:200]) from exc
    return {'workspace': str(workspace), 'private_git': str(private_git),
            'git_common_dir': str((workspace / '.git').resolve(strict=True))}


def _wrapped_command(argv, policy):
    if not isinstance(argv, (list, tuple)) or not argv or any(not isinstance(a, str) or not a for a in argv):
        raise ValueError('worker command must be a non-empty argv array')
    executable = shutil.which(argv[0]) if not os.path.isabs(argv[0]) else argv[0]
    if not executable or not os.path.isfile(executable) or not os.access(executable, os.X_OK):
        raise IsolationUnavailable('worker executable unavailable')
    if policy['backend'] == 'macos':
        if not policy['command']:
            raise IsolationUnavailable('sandbox-exec unavailable')
        return [policy['command'], '-p', policy['text'], '--', executable, *argv[1:]]
    if policy['backend'] == 'linux':
        bwrap = policy['command']
        if not bwrap:
            raise IsolationUnavailable('bubblewrap unavailable')
        command = [bwrap, '--die-with-parent', '--new-session', '--unshare-all',
                   '--clearenv', '--setenv', 'PATH', '/usr/bin:/bin', '--setenv', 'HOME', '/nonexistent',
                   '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp']
        for root in ('/usr', '/bin', '/sbin', '/lib', '/lib64'):
            if os.path.exists(root):
                command.extend(('--ro-bind', root, root))
        for key in ('workspace', 'private_git'):
            root = policy[key]
            command.extend(('--bind', root, root))
        command.extend(('--ro-bind', policy['channels'], policy['channels']))
        command.extend(('--chdir', policy['workspace'], '--', executable, *argv[1:]))
        return command
    raise IsolationUnavailable('host isolation backend unsupported')


_PROTECTED_RESOURCE_KEYS = {
    'controller_db', 'controller_socket', 'board_storage', 'shared_git_metadata',
    'host_credentials', 'ssh_agent', 'keychain',
}


def _protected_resource_paths(resources):
    """Validate the trusted map without opening or reading any protected target."""
    if not isinstance(resources, dict) or set(resources) != _PROTECTED_RESOURCE_KEYS:
        raise IsolationUnavailable('complete protected-resource map is required')
    paths = {}
    for key, value in resources.items():
        values = value if key in ('host_credentials', 'keychain') else [value]
        if not isinstance(values, (list, tuple)) or not values:
            raise IsolationUnavailable('protected-resource map is incomplete: ' + key)
        validated = []
        for raw in values:
            if not isinstance(raw, str) or not raw or not os.path.isabs(raw):
                raise IsolationUnavailable('protected-resource path is invalid: ' + key)
            path = Path(raw)
            try:
                info = path.lstat()
                if path.is_symlink() or path.resolve(strict=True) != path:
                    raise ValueError('path is not canonical')
            except (OSError, ValueError) as exc:
                raise IsolationUnavailable('protected-resource path is unavailable: ' + key) from exc
            if key in ('controller_socket', 'ssh_agent') and not stat.S_ISSOCK(info.st_mode):
                raise IsolationUnavailable('protected-resource socket is unavailable: ' + key)
            if key in ('board_storage', 'shared_git_metadata') and not stat.S_ISDIR(info.st_mode):
                raise IsolationUnavailable('protected-resource directory is unavailable: ' + key)
            if key in ('controller_db',) and not stat.S_ISREG(info.st_mode):
                raise IsolationUnavailable('protected-resource file is unavailable: ' + key)
            if key == 'host_credentials' and not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise IsolationUnavailable('protected credential path is unavailable')
            if key == 'keychain' and not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)
                                           or stat.S_ISSOCK(info.st_mode)):
                raise IsolationUnavailable('protected keychain path is unavailable')
            validated.append(str(path))
        paths[key] = validated
    return paths


def probe_capabilities(policy, *, inference_socket=None, inference_attempt_id=None,
                       inference_capability=None, protected_resources=None):
    """Require real positive and negative checks for every worker boundary."""
    expected = ('workspace_read', 'workspace_write', 'controller_db', 'controller_socket',
                'board_storage', 'shared_git_metadata', 'host_credentials', 'ssh_agent',
                'keychain', 'symlink_escape', 'loopback_network', 'publication',
                'forged_human_control', 'inference_channel', 'channel_write')
    checks = {name: False for name in expected}
    try:
        protected = _protected_resource_paths(protected_resources)
    except IsolationUnavailable as exc:
        return {'available': False, 'backend': policy.get('backend', 'unsupported'),
                'reason': str(exc), 'checks': checks}
    if not policy.get('command'):
        return {'available': False, 'backend': policy['backend'], 'reason': 'isolation executable unavailable',
                'checks': checks}
    probe_root = None
    listener = tcp_listener = None
    owns_inference_socket = False
    accepted = []
    workspace_probe_paths = []
    try:
        if not shutil.which('nc'):
            raise IsolationUnavailable('netcat unavailable for local boundary probes')
        scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
        probe_root = Path(tempfile.mkdtemp(prefix='fb-probe-', dir=scratch_parent))
        probe_root.chmod(0o700)
        probe_name = secrets.token_hex(8)
        control_path = Path(protected['controller_socket'][0])
        agent_path = Path(protected['ssh_agent'][0])
        inference_path = Path(inference_socket or (Path(policy['channels']) / 'inference.sock'))
        forged_control_path = None
        forged_response_path = None
        if inference_attempt_id is not None and inference_capability is not None:
            forged_control_path = Path(policy['workspace']) / ('.isolation-probe-forged-' + probe_name)
            workspace_probe_paths.append(forged_control_path)
            forged_control_path.write_bytes(_forged_control_frame(
                inference_attempt_id, inference_capability))
            forged_control_path.chmod(0o600)
            forged_response_path = Path(policy['workspace']) / ('.isolation-probe-forged-response-' + probe_name)
            workspace_probe_paths.append(forged_response_path)
            forged_response_path.write_bytes(_forged_control_rejection_frame())
            forged_response_path.chmod(0o600)
        if not inference_path.exists():
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(inference_path))
            listener.listen(1)
            listener.settimeout(3)
            owns_inference_socket = True
        elif not stat.S_ISSOCK(inference_path.lstat().st_mode):
            raise IsolationUnavailable('inference channel path is not a socket')
        tcp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp_listener.bind(('127.0.0.1', 0))
        tcp_listener.listen(1)
        escape = Path(policy['workspace']) / ('.isolation-probe-escape-' + probe_name)
        escape.symlink_to(protected['controller_db'][0])
        own_read = Path(policy['workspace']) / ('.isolation-probe-readable-' + probe_name)
        own_read.write_text('ok', encoding='utf-8')
        workspace_probe_paths.extend((escape, own_read))
        publication = probe_root / ('publication-' + probe_name + '.out')
        nc = shutil.which('nc')
        lines = [
            'if test -r {0}; then workspace_read=pass; fi'.format(shlex.quote(str(own_read))),
            'if printf ok > {0}; then workspace_write=pass; fi'.format(shlex.quote(str(Path(policy['workspace']) / ('.isolation-probe-write-' + probe_name)))),
        ]
        for name in ('controller_db', 'board_storage', 'shared_git_metadata'):
            target = shlex.quote(protected[name][0])
            lines.append('if ! test -r {0} && ! test -w {0}; then {1}=pass; fi'.format(target, name))
        lines.append('if ! {0} -z -U -w 1 {1} >/dev/null 2>&1; then controller_socket=pass; fi'.format(nc, shlex.quote(str(control_path))))
        lines.append('if ! {0} -z -U -w 1 {1} >/dev/null 2>&1; then ssh_agent=pass; fi'.format(nc, shlex.quote(str(agent_path))))
        for name in ('host_credentials', 'keychain'):
            tests = []
            for path in protected[name]:
                if Path(path).is_socket():
                    tests.append('! {0} -z -U -w 1 {1} >/dev/null 2>&1'.format(nc, shlex.quote(path)))
                else:
                    tests.append('! test -r {0} && ! test -w {0}'.format(shlex.quote(path)))
            lines.append('if {0}; then {1}=pass; fi'.format(' && '.join(tests), name))
        lines.extend([
            'if ! test -r {0}; then symlink_escape=pass; fi'.format(shlex.quote(str(escape))),
            'if ! printf x > {0} 2>/dev/null; then publication=pass; fi'.format(shlex.quote(str(publication))),
            'if {0} -z -w 1 127.0.0.1 {1} >/dev/null 2>&1; then loopback_network=fail; else loopback_network=pass; fi'.format(nc, tcp_listener.getsockname()[1]),
            'if printf probe | {0} -U -w 1 {1} >/dev/null 2>&1; then inference_channel=pass; else inference_channel=fail; fi'.format(nc, shlex.quote(str(inference_path))),
            'if ! printf x > {0} 2>/dev/null; then channel_write=pass; fi'.format(
                shlex.quote(str(Path(policy['channels']) / ('.isolation-probe-write-' + probe_name)))),
            'printf "workspace_read=%s\\nworkspace_write=%s\\ncontroller_db=%s\\ncontroller_socket=%s\\nboard_storage=%s\\nshared_git_metadata=%s\\nhost_credentials=%s\\nssh_agent=%s\\nkeychain=%s\\nsymlink_escape=%s\\nloopback_network=%s\\npublication=%s\\nforged_human_control=%s\\ninference_channel=%s\\nchannel_write=%s\\n" "$workspace_read" "$workspace_write" "$controller_db" "$controller_socket" "$board_storage" "$shared_git_metadata" "$host_credentials" "$ssh_agent" "$keychain" "$symlink_escape" "$loopback_network" "$publication" "$forged_human_control" "$inference_channel" "$channel_write"',
        ])
        if forged_control_path is not None:
            lines.insert(-1, 'if {0} -U -w 1 {1} < {2} > {3} 2>/dev/null; then if cmp -s {3} {4}; then forged_human_control=pass; fi; fi'.format(
                nc, shlex.quote(str(inference_path)), shlex.quote(str(forged_control_path)),
                shlex.quote(str(Path(policy['workspace']) /
                                  ('.isolation-probe-forged-received-' + probe_name))),
                shlex.quote(str(forged_response_path))))
        script = '\n'.join(lines) + '\n'
        script_path = Path(policy['workspace']) / ('.isolation-probe-' + probe_name + '.sh')
        script_path.write_text(script, encoding='utf-8')
        script_path.chmod(0o700)
        workspace_probe_paths.extend((script_path, Path(policy['workspace']) /
                                      ('.isolation-probe-write-' + probe_name),
                                      Path(policy['channels']) /
                                      ('.isolation-probe-write-' + probe_name)))
        if forged_control_path is not None:
            workspace_probe_paths.append(Path(policy['workspace']) /
                                         ('.isolation-probe-forged-received-' + probe_name))
        completed = subprocess.run(_wrapped_command(['/bin/sh', str(script_path)], policy),
                                   cwd=policy['workspace'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=5, check=False, env={'PATH': '/usr/bin:/bin'})
        output = completed.stdout.decode('utf-8', 'replace')
        for line in output.splitlines():
            if '=' in line:
                name, value = line.split('=', 1)
                if name in checks:
                    checks[name] = value == 'pass'
        if listener is not None:
            try:
                connection, _ = listener.accept()
                accepted.append(connection)
                checks['inference_channel'] = checks['inference_channel'] and connection.recv(16) == b'probe'
            except (OSError, socket.timeout):
                checks['inference_channel'] = False
        if completed.returncode != 0:
            return {'available': False, 'backend': policy['backend'],
                    'reason': 'boundary probe failed (exit {})'.format(completed.returncode), 'checks': checks}
        missing = [name for name, passed in checks.items() if not passed]
        if missing:
            return {'available': False, 'backend': policy['backend'],
                    'reason': 'boundary probe failed: ' + ', '.join(missing), 'checks': checks}
        return {'available': True, 'backend': policy['backend'], 'reason': None, 'checks': checks}
    except (OSError, subprocess.SubprocessError, IsolationUnavailable, ValueError) as exc:
        return {'available': False, 'backend': policy['backend'], 'reason': str(exc)[:200],
                'checks': checks}
    finally:
        for connection in accepted:
            try:
                connection.close()
            except OSError:
                pass
        for sock in (listener, tcp_listener):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        if owns_inference_socket:
            try:
                Path(inference_path).unlink()
            except (OSError, UnboundLocalError):
                pass
        if probe_root is not None:
            shutil.rmtree(probe_root, ignore_errors=True)
        for path in workspace_probe_paths:
            try:
                path.unlink()
            except OSError:
                pass


def run_isolated(argv, policy, *, capability=None, cwd=None, timeout=300, input_data=None,
                 cancel_event=None,
                 stdout_limit=1048576, stderr_limit=65536):
    capability = capability or probe_capabilities(policy)
    if not capability.get('available'):
        raise IsolationUnavailable(capability.get('reason') or 'host isolation unavailable')
    if (type(timeout) not in (int, float) or timeout <= 0
            or type(stdout_limit) is not int or stdout_limit < 1
            or type(stderr_limit) is not int or stderr_limit < 1
            or (input_data is not None and not isinstance(input_data, bytes))
            or not isinstance(cancel_event, threading.Event)):
        raise ValueError('invalid isolated process bounds')
    process = None
    selector = selectors.DefaultSelector()
    captured = {}
    try:
        process = subprocess.Popen(
            _wrapped_command(argv, policy), cwd=cwd or policy['workspace'],
            stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True,
            start_new_session=True,
            env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent'},
        )
        captured = {process.stdout: bytearray(), process.stderr: bytearray()}
        limits = {process.stdout: stdout_limit, process.stderr: stderr_limit}
        for stream in captured:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        offset = 0
        if process.stdin is not None:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE)
        deadline = time.monotonic() + timeout
        while selector.get_map() or process.poll() is None:
            if cancel_event.is_set():
                raise IsolationUnavailable('isolated worker cancelled')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise IsolationUnavailable('isolated worker deadline exceeded')
            for key, _ in selector.select(min(.05, remaining)):
                if process.stdin is not None and key.fileobj is process.stdin:
                    data = input_data or b''
                    if offset < len(data):
                        offset += os.write(key.fd, data[offset:offset + 65536])
                    if offset >= len(data):
                        selector.unregister(key.fileobj)
                        process.stdin.close()
                    continue
                chunk = os.read(key.fd, min(65536, limits[key.fileobj] + 1 - len(captured[key.fileobj])))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                captured[key.fileobj].extend(chunk)
                if len(captured[key.fileobj]) > limits[key.fileobj]:
                    raise IsolationUnavailable('isolated worker output exceeded limit')
        return subprocess.CompletedProcess(
            process.args, process.returncode,
            bytes(captured[process.stdout]), bytes(captured[process.stderr]),
        )
    except (OSError, subprocess.SubprocessError) as exc:
        _terminate_process_group(process)
        raise IsolationUnavailable(str(exc)[:200]) from exc
    except BaseException:
        _terminate_process_group(process)
        raise
    finally:
        selector.close()
        if process is not None and process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        for stream in captured:
            try:
                stream.close()
            except OSError:
                pass


def _terminate_process_group(process):
    """Stop the owned worker group even when bootstrap or selector I/O fails."""
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        process.wait(timeout=.3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, 0)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return
        # Permission and other probe failures do not prove the group is gone.
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
