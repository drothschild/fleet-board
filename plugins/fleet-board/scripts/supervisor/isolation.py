"""Host-enforced worker isolation policies. Unsupported hosts fail closed."""
import os
import json
import os
from pathlib import Path
import selectors
import signal
import shutil
import shlex
import secrets
import socket
import subprocess
import tempfile
import time


class IsolationUnavailable(RuntimeError):
    pass


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
        allow_work = ' '.join('(subpath ' + json.dumps(p) + ')' for p in roots)
        inference_socket = os.path.join(channels, 'inference.sock')
        text = ('(version 1)\n(deny default)\n(allow process-fork)\n(allow process-exec)\n(allow sysctl-read)\n'
                '(allow file-read* ' + allow_reads + ')\n'
                '(allow file-write* ' + allow_work + ')\n'
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
        for key in ('workspace', 'private_git', 'channels'):
            root = policy[key]
            command.extend(('--bind', root, root))
        command.extend(('--chdir', policy['workspace'], '--', executable, *argv[1:]))
        return command
    raise IsolationUnavailable('host isolation backend unsupported')


def probe_capabilities(policy, *, inference_socket=None):
    """Require real positive and negative checks for every worker boundary."""
    expected = ('workspace_read', 'workspace_write', 'controller_db', 'controller_socket',
                'board_storage', 'shared_git_metadata', 'host_credentials', 'ssh_agent',
                'keychain', 'symlink_escape', 'loopback_network', 'publication',
                'forged_human_control', 'inference_channel')
    checks = {name: False for name in expected}
    if not policy.get('command'):
        return {'available': False, 'backend': policy['backend'], 'reason': 'isolation executable unavailable',
                'checks': checks}
    probe_root = None
    listener = tcp_listener = None
    owns_inference_socket = False
    control_listener = agent_listener = None
    accepted = []
    workspace_probe_paths = []
    try:
        if not shutil.which('nc'):
            raise IsolationUnavailable('netcat unavailable for local boundary probes')
        scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
        probe_root = Path(tempfile.mkdtemp(prefix='fb-probe-', dir=scratch_parent))
        probe_root.chmod(0o700)
        targets = {}
        probe_name = secrets.token_hex(8)
        for name in ('controller_db', 'board_storage', 'shared_git_metadata',
                     'host_credentials', 'keychain'):
            path = probe_root / (name + '.sentinel')
            path.write_text(name, encoding='utf-8')
            path.chmod(0o644)
            targets[name] = path
        control_path = probe_root / 'controller.sock'
        agent_path = probe_root / 'agent.sock'
        control_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        control_listener.bind(str(control_path))
        control_listener.listen(1)
        agent_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        agent_listener.bind(str(agent_path))
        agent_listener.listen(1)
        inference_path = Path(inference_socket or (Path(policy['channels']) / 'inference.sock'))
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
        escape.symlink_to(targets['controller_db'])
        own_read = Path(policy['workspace']) / ('.isolation-probe-readable-' + probe_name)
        own_read.write_text('ok', encoding='utf-8')
        workspace_probe_paths.extend((escape, own_read))
        publication = probe_root / ('publication-' + probe_name + '.out')
        nc = shutil.which('nc')
        lines = [
            'if test -r {0}; then workspace_read=pass; fi'.format(shlex.quote(str(own_read))),
            'if printf ok > {0}; then workspace_write=pass; fi'.format(shlex.quote(str(Path(policy['workspace']) / ('.isolation-probe-write-' + probe_name)))),
        ]
        for name in ('controller_db', 'board_storage', 'shared_git_metadata', 'host_credentials', 'keychain'):
            lines.append('if ! test -r {0}; then {1}=pass; fi'.format(shlex.quote(str(targets[name])), name))
        lines.extend([
            'if ! test -r {0}; then symlink_escape=pass; fi'.format(shlex.quote(str(escape))),
            'if ! printf x > {0} 2>/dev/null; then publication=pass; fi'.format(shlex.quote(str(publication))),
            'if {0} -z -w 1 127.0.0.1 {1} >/dev/null 2>&1; then loopback_network=fail; else loopback_network=pass; fi'.format(nc, tcp_listener.getsockname()[1]),
            'if printf control | {0} -U -w 1 {1} >/dev/null 2>&1; then controller_socket=fail; forged_human_control=fail; else controller_socket=pass; forged_human_control=pass; fi'.format(nc, shlex.quote(str(control_path))),
            'if printf agent | {0} -U -w 1 {1} >/dev/null 2>&1; then ssh_agent=fail; else ssh_agent=pass; fi'.format(nc, shlex.quote(str(agent_path))),
            'if printf probe | {0} -U -w 1 {1} >/dev/null 2>&1; then inference_channel=pass; else inference_channel=fail; fi'.format(nc, shlex.quote(str(inference_path))),
            'printf "workspace_read=%s\\nworkspace_write=%s\\ncontroller_db=%s\\ncontroller_socket=%s\\nboard_storage=%s\\nshared_git_metadata=%s\\nhost_credentials=%s\\nssh_agent=%s\\nkeychain=%s\\nsymlink_escape=%s\\nloopback_network=%s\\npublication=%s\\nforged_human_control=%s\\ninference_channel=%s\\n" "$workspace_read" "$workspace_write" "$controller_db" "$controller_socket" "$board_storage" "$shared_git_metadata" "$host_credentials" "$ssh_agent" "$keychain" "$symlink_escape" "$loopback_network" "$publication" "$forged_human_control" "$inference_channel"',
        ])
        script = '\n'.join(lines) + '\n'
        script_path = Path(policy['workspace']) / ('.isolation-probe-' + probe_name + '.sh')
        script_path.write_text(script, encoding='utf-8')
        script_path.chmod(0o700)
        workspace_probe_paths.extend((script_path, Path(policy['workspace']) /
                                      ('.isolation-probe-write-' + probe_name)))
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
        try:
            if control_listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN):
                control_listener.settimeout(.05)
                connection, _ = control_listener.accept()
                accepted.append(connection)
                checks['controller_socket'] = checks['forged_human_control'] = False
        except (OSError, socket.timeout):
            pass
        try:
            agent_listener.settimeout(.05)
            connection, _ = agent_listener.accept()
            accepted.append(connection)
            checks['ssh_agent'] = False
        except (OSError, socket.timeout):
            pass
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
        for sock in (listener, tcp_listener, control_listener, agent_listener):
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
                 stdout_limit=1048576, stderr_limit=65536):
    capability = capability or probe_capabilities(policy)
    if not capability.get('available'):
        raise IsolationUnavailable(capability.get('reason') or 'host isolation unavailable')
    if (type(timeout) not in (int, float) or timeout <= 0
            or type(stdout_limit) is not int or stdout_limit < 1
            or type(stderr_limit) is not int or stderr_limit < 1
            or (input_data is not None and not isinstance(input_data, bytes))):
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
        raise IsolationUnavailable(str(exc)[:200]) from exc
    except BaseException:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=.3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
        raise
    finally:
        selector.close()
        for stream in captured:
            try:
                stream.close()
            except OSError:
                pass
