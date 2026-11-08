"""Host-enforced worker isolation policies. Unsupported hosts fail closed."""
import os
import json
import os
from pathlib import Path
import selectors
import signal
import shutil
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


def probe_capabilities(policy):
    """Apply and test both an allowed write and a denied read on this host."""
    if not policy.get('command'):
        return {'available': False, 'backend': policy['backend'], 'reason': 'isolation executable unavailable'}
    allowed = Path(policy['workspace']) / '.isolation-probe'
    probe_root = None
    try:
        probe_root = Path(tempfile.mkdtemp(prefix='.isolation-probe-',
                                           dir=str(Path(policy['workspace']).parent)))
        denied_path = probe_root / 'denied'
        denied_path.write_text('denied', encoding='utf-8')
        denied_path.chmod(0o644)
        command = ['/bin/sh', '-c', 'test ! -r "$1" && printf ok > "$2"',
                   'probe', str(denied_path), str(allowed)]
        wrapped = _wrapped_command(command, policy)
        completed = subprocess.run(wrapped, cwd=policy['workspace'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=3, check=False, env={'PATH': '/usr/bin:/bin'})
        if completed.returncode != 0 or not allowed.is_file() or allowed.read_text() != 'ok':
            detail = completed.stderr.decode('utf-8', 'replace')[:160].strip()
            return {'available': False, 'backend': policy['backend'],
                    'reason': detail or 'policy probe failed (exit {}, allowed_write={})'.format(
                        completed.returncode, allowed.is_file())}
        allowed.unlink()
        return {'available': True, 'backend': policy['backend'], 'reason': None}
    except (OSError, subprocess.SubprocessError, IsolationUnavailable, ValueError) as exc:
        return {'available': False, 'backend': policy['backend'], 'reason': str(exc)[:200]}
    finally:
        try:
            allowed.unlink()
        except OSError:
            pass
        if probe_root is not None:
            shutil.rmtree(probe_root, ignore_errors=True)


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
