"""Host-enforced worker isolation policies. Unsupported hosts fail closed."""
import os
import errno
import json
import math
import re
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
import sys
import tempfile
import threading
import time


class IsolationUnavailable(RuntimeError):
    pass


def verify_docker_desktop_identity(docker, expected=None, *, timeout=None,
                                   cancel_event=None):
    """Return the verified local Docker Desktop Linux VM identity or fail closed."""
    if os.environ.get('DOCKER_HOST') or os.environ.get('DOCKER_CONTEXT'):
        raise IsolationUnavailable('Docker daemon overrides are not allowed')
    if not isinstance(docker, str) or not os.path.isabs(docker):
        raise IsolationUnavailable('Docker executable unavailable')

    if timeout is not None and (type(timeout) not in (int, float)
                                or not math.isfinite(timeout) or timeout <= 0
                                or timeout > 86400):
        raise IsolationUnavailable('Docker Desktop identity check deadline exceeded')
    deadline = time.monotonic() + timeout if timeout is not None else None

    def run(arguments):
        if cancel_event is not None and cancel_event.is_set():
            raise IsolationUnavailable('Docker Desktop identity check cancelled')
        if timeout is None and cancel_event is None:
            try:
                result = subprocess.run([docker, *arguments], stdin=subprocess.DEVNULL,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=5, check=False, close_fds=True)
            except (OSError, subprocess.SubprocessError) as exc:
                raise IsolationUnavailable('Docker Desktop identity check failed') from exc
            if result.returncode != 0:
                raise IsolationUnavailable('Docker Desktop identity check failed')
            output = result.stdout
            if isinstance(output, bytes):
                output = output.decode('utf-8', 'replace')
            return str(output).strip()
        remaining = deadline - time.monotonic() if deadline is not None else 5.0
        if remaining <= 0:
            raise IsolationUnavailable('Docker Desktop identity check deadline exceeded')
        try:
            process = subprocess.Popen([docker, *arguments], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       close_fds=True, start_new_session=True)
        except OSError as exc:
            raise IsolationUnavailable('Docker Desktop identity check failed') from exc
        try:
            while True:
                if cancel_event is not None and cancel_event.is_set():
                    raise IsolationUnavailable('Docker Desktop identity check cancelled')
                remaining = deadline - time.monotonic() if deadline is not None else 5.0
                if remaining <= 0:
                    raise IsolationUnavailable('Docker Desktop identity check deadline exceeded')
                try:
                    stdout, stderr = process.communicate(timeout=min(.05, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
        except IsolationUnavailable:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                process.kill()
            try:
                process.communicate(timeout=.2)
            except subprocess.SubprocessError:
                pass
            raise
        except (OSError, subprocess.SubprocessError) as exc:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                process.kill()
            raise IsolationUnavailable('Docker Desktop identity check failed') from exc
        result = subprocess.CompletedProcess([docker, *arguments], process.returncode,
                                             stdout, stderr)
        if result.returncode != 0:
            raise IsolationUnavailable('Docker Desktop identity check failed')
        output = result.stdout
        if isinstance(output, bytes):
            output = output.decode('utf-8', 'replace')
        return str(output).strip()

    context = run(['context', 'show'])
    if context != 'desktop-linux':
        raise IsolationUnavailable('Docker context is not desktop-linux')
    try:
        inspected = json.loads(run(['context', 'inspect', 'desktop-linux',
                                    '--format={{json .Endpoints.docker}}']))
        info = json.loads(run(['info', '--format={{json .}}']))
    except (TypeError, ValueError) as exc:
        raise IsolationUnavailable('Docker Desktop identity response was invalid') from exc
    if isinstance(inspected, list):
        inspected = inspected[0] if len(inspected) == 1 else None
        if isinstance(inspected, dict) and 'Endpoints' in inspected:
            inspected = inspected.get('Endpoints', {}).get('docker')
    elif isinstance(inspected, dict) and 'Endpoints' in inspected:
        inspected = inspected.get('Endpoints', {}).get('docker')
    endpoint = inspected.get('Host') if isinstance(inspected, dict) else None
    expected_endpoint = 'unix://' + str(Path.home() / '.docker/run/docker.sock')
    if endpoint != expected_endpoint:
        raise IsolationUnavailable('Docker endpoint is not the local Docker Desktop socket')
    if (not isinstance(info, dict) or info.get('Name') != 'docker-desktop'
            or info.get('OSType') != 'linux'
            or info.get('OperatingSystem') != 'Docker Desktop'):
        raise IsolationUnavailable('Docker daemon is not the Docker Desktop Linux VM')
    identity = {'context': context, 'endpoint': endpoint, 'name': info['Name'],
                'os_type': info['OSType'], 'operating_system': info['OperatingSystem']}
    if expected is not None and identity != expected:
        raise IsolationUnavailable('Docker Desktop daemon identity changed')
    return identity


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


def _create_probe_symlink(path, target, cleanup_paths):
    """Register a probe path before creating it so partial setup is cleanable."""
    cleanup_paths.append(path)
    path.symlink_to(target)


def _bind_probe_listener(listener, path, ownership):
    """Record pathname ownership immediately after bind, before later setup fails."""
    listener.bind(str(path))
    ownership.append(True)
    listener.listen(1)


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


def build_policy(workspace, private_git, channels, *, backend=None, docker_image=None):
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
    if backend == 'docker':
        if (not isinstance(docker_image, str)
                or not re.fullmatch(r'sha256:[0-9a-f]{64}', docker_image)):
            raise ValueError('Docker backend requires an immutable sha256 image ID')
        if any(',' in path or any(ord(char) < 32 for char in path)
               for path in (workspace, private_git, channels)):
            raise ValueError('Docker mount path contains an unsupported delimiter')
        guest_package = str(Path(__file__).resolve(strict=True).parent)
        docker = shutil.which('docker')
        daemon_identity = verify_docker_desktop_identity(docker)
        return {**common, 'backend': 'docker', 'docker_image': docker_image,
                'guest_package': guest_package, 'command': docker,
                'daemon_identity': daemon_identity,
                'uid': os.getuid(), 'gid': os.getgid(),
                'text': 'Docker Desktop offline worker; no host broker socket is mounted'}
    if backend is not None:
        raise ValueError('unknown isolation backend')
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


def docker_run_argv(argv, policy, cidfile):
    """Build a deterministic offline Docker command without host control mounts."""
    if (not isinstance(argv, (list, tuple)) or not argv
            or any(not isinstance(arg, str) or not arg or '\x00' in arg for arg in argv)):
        raise ValueError('worker command must be a non-empty argv array')
    if not isinstance(policy, dict) or policy.get('backend') != 'docker':
        raise IsolationUnavailable('Docker policy required')
    image = policy.get('docker_image')
    if (not isinstance(image, str)
            or not re.fullmatch(r'sha256:[0-9a-f]{64}', image)):
        raise IsolationUnavailable('immutable Docker image ID required')
    docker = policy.get('command')
    if not isinstance(docker, str) or not os.path.isabs(docker):
        raise IsolationUnavailable('Docker executable unavailable')
    uid, gid = policy.get('uid'), policy.get('gid')
    if type(uid) is not int or uid <= 0 or type(gid) is not int or gid < 0:
        raise IsolationUnavailable('non-root Docker worker identity required')

    def canonical_directory(key):
        raw = policy.get(key)
        if not isinstance(raw, str) or not os.path.isabs(raw):
            raise IsolationUnavailable('Docker ' + key + ' path is invalid')
        path = Path(raw)
        if path.is_symlink() or not path.is_dir() or path.resolve(strict=True) != path:
            raise IsolationUnavailable('Docker ' + key + ' path is not canonical')
        if ',' in raw or any(ord(char) < 32 for char in raw):
            raise IsolationUnavailable('Docker mount path contains an unsupported delimiter')
        return raw

    workspace = canonical_directory('workspace')
    private_git = canonical_directory('private_git')
    guest = canonical_directory('guest_package')
    cidfile = os.path.abspath(cidfile) if isinstance(cidfile, str) and cidfile else None
    if (cidfile is None or ',' in cidfile or any(ord(char) < 32 for char in cidfile)
            or not os.path.isdir(os.path.dirname(cidfile))):
        raise ValueError('Docker cidfile path must have a safe existing parent')
    for key, value in (('workspace', workspace), ('private Git', private_git)):
        if os.path.commonpath((value, guest)) in (value, guest):
            raise IsolationUnavailable('Docker ' + key + ' overlaps guest transport')
    if os.path.commonpath((workspace, private_git)) in (workspace, private_git):
        raise IsolationUnavailable('Docker writable roots overlap')
    mounts = ('type=bind,src=' + workspace + ',dst=/workspace',
              'type=bind,src=' + private_git + ',dst=/private-git',
              'type=bind,src=' + guest + ',dst=/guest/supervisor,readonly')
    command = [docker, 'run', '--rm', '-i', '--pull=never', '--network=none',
               '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
               '--pids-limit=64', '--memory=2g', '--cpus=2',
               '--user={}:{}'.format(uid, gid), '--workdir=/workspace',
               '--env=PYTHONPATH=/guest', '--tmpfs=/tmp:rw,noexec,nosuid,size=64m,mode=1777',
               '--cidfile=' + cidfile]
    for mount in mounts:
        command.extend(('--mount', mount))
    command.extend(('--entrypoint=' + argv[0], image, *argv[1:]))
    return command


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


_DOCKER_PROBE_CHECKS = (
    'docker_daemon', 'image_present', 'workspace_read', 'workspace_write',
    'private_git_read', 'private_git_write', 'controller_db_absent',
    'controller_socket_absent', 'board_storage_absent', 'shared_git_metadata_absent',
    'host_credentials_absent', 'ssh_agent_absent', 'keychain_absent',
    'host_home_absent', 'docker_socket_absent', 'guest_package_write_denied',
    'no_public_egress',
    'no_host_publication', 'symlink_escape_denied', 'inference_relay',
    'forged_human_control_denied', 'channel_path_write_denied', 'timeout_cleanup',
    'cancellation_cleanup',
)


def probe_docker_capabilities(policy, *, protected_resources=None):
    """Qualify the concrete Docker boundary with a no-cost local fake provider."""
    checks = {name: False for name in _DOCKER_PROBE_CHECKS}
    identity = None

    def result(available, reason):
        return {'available': available, 'backend': 'docker', 'reason': reason,
                'checks': dict(checks), 'daemon_identity': identity}

    try:
        protected = _protected_resource_paths(protected_resources)
    except IsolationUnavailable as exc:
        return result(False, str(exc))
    docker = policy.get('command') if isinstance(policy, dict) else None
    image = policy.get('docker_image') if isinstance(policy, dict) else None
    if not isinstance(docker, str) or not os.path.isabs(docker):
        return result(False, 'Docker executable unavailable')
    try:
        identity = verify_docker_desktop_identity(docker, policy.get('daemon_identity'))
    except IsolationUnavailable as exc:
        return result(False, str(exc))
    checks['docker_daemon'] = True
    if not isinstance(image, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        return result(False, 'immutable Docker image ID required')
    try:
        inspected = subprocess.run([docker, 'image', 'inspect', '--format={{.Id}}', image],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=5, check=False, close_fds=True)
    except (OSError, subprocess.SubprocessError) as exc:
        return result(False, 'cached Docker image unavailable: ' + str(exc)[:120])
    checks['image_present'] = (inspected.returncode == 0
                               and inspected.stdout.decode('ascii', 'replace').strip() == image)
    if not checks['image_present']:
        return result(False, 'Docker worker image is not present locally')

    workspace = Path(policy.get('workspace', ''))
    private_git = Path(policy.get('private_git', ''))
    channels = Path(policy.get('channels', ''))
    probe_name = '.docker-isolation-probe-' + secrets.token_hex(8)
    workspace_read = workspace / (probe_name + '-workspace-read')
    private_read = private_git / (probe_name + '-private-read')
    workspace_write = workspace / (probe_name + '-workspace-write')
    private_write = private_git / (probe_name + '-private-write')
    report_path = workspace / (probe_name + '-report.json')
    escape = workspace / (probe_name + '-escape')
    channel_path = channels / (probe_name + '-host-channel')
    guest_write_host = Path(policy.get('guest_package', '')) / (probe_name + '-guest-write')
    timeout_marker = workspace / (probe_name + '-timeout-started')
    cancellation_marker = workspace / (probe_name + '-cancellation-started')
    scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else None
    probe_root = None
    listeners = []
    channel = None
    transport = None
    timeout_transport = None
    try:
        supplemental = policy.get('_docker_probe_host_paths', {})
        if not isinstance(supplemental, dict):
            raise IsolationUnavailable('invalid Docker host probe paths')
        for key in ('ssh_agent', 'docker_socket'):
            extra = supplemental.get(key, [])
            if (not isinstance(extra, (list, tuple))
                    or any(not isinstance(path, str) or not os.path.isabs(path) for path in extra)):
                raise IsolationUnavailable('invalid supplemental Docker probe paths')
        protected['ssh_agent'].extend(supplemental.get('ssh_agent', []))
        for key, root in (('workspace', workspace), ('private Git', private_git),
                          ('channel', channels)):
            if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
                raise IsolationUnavailable('Docker ' + key + ' root is not canonical')
            if ',' in str(root) or any(ord(char) < 32 for char in str(root)):
                raise IsolationUnavailable('Docker mount root contains an unsupported delimiter')
        workspace_read.write_text('workspace-probe', encoding='utf-8')
        private_read.write_text('private-git-probe', encoding='utf-8')
        controller_db = protected['controller_db'][0]
        _create_probe_symlink(escape, controller_db, [])

        probe_root = Path(tempfile.mkdtemp(prefix='fb-docker-probe-', dir=scratch_parent))
        probe_root.chmod(0o700)
        provider = probe_root / 'provider.py'
        provider.write_text(
            '#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\n'
            'print(json.dumps({"schema_version":1,"attempt_id":r["attempt_id"],'
            '"generation":r["generation"],"input_sha":r["input_sha"],'
            '"provider":r["provider"],"model":r["model"],'
            '"text":"docker-probe-ok","usage":None}))\n', encoding='utf-8')
        provider.chmod(0o700)
        from .inference_broker import InferenceBroker, InferenceChannel, ProviderRequest
        from .docker_transport import DockerWorkerTransport

        attempt_id = 'docker-probe-' + secrets.token_hex(8)
        request = ProviderRequest.create(attempt_id=attempt_id, generation=0,
                                         role='reviewer', stage=None,
                                         provider='docker-probe', model='offline-v1',
                                         input_text='Docker boundary qualification')
        binding = {'generation': 0, 'role': 'reviewer', 'stage': None,
                   'provider': 'docker-probe', 'model': 'offline-v1',
                   'input_sha': request.input_sha}
        broker = InferenceBroker(
            {'docker-probe': {'command': [sys.executable, str(provider)],
                              'model': 'offline-v1', 'credential_env': None}},
            attempts={attempt_id: binding})
        channel_dir = probe_root / 'channel'
        channel_dir.mkdir(mode=0o700)
        channel = InferenceChannel(broker, channel_dir, (attempt_id,),
                                   request_timeout=8, frame_timeout=3)
        channel_capability = channel.capability_for(attempt_id)
        docker_dir = probe_root / 'docker'
        docker_dir.mkdir(mode=0o700)
        transport = DockerWorkerTransport()
        bootstrap = {'schema_version': 1,
                     'attempt': {'attempt_id': attempt_id, 'generation': 0,
                                 'input_sha': request.input_sha, 'role': 'reviewer',
                                 'stage': None, 'provider': 'docker-probe', 'model': 'offline-v1'},
                     'provider_request': request.to_dict(),
                     'inference': {'schema_version': 1, 'socket_path': str(channel.socket_path),
                                   'attempt_id': attempt_id,
                                   'capability': channel_capability},
                     'docker_probe': {
                         'workspace_read': '/workspace/' + workspace_read.name,
                         'private_git_read': '/private-git/' + private_read.name,
                         'workspace_write': '/workspace/' + workspace_write.name,
                         'private_git_write': '/private-git/' + private_write.name,
                         'report': '/workspace/' + report_path.name,
                         'escape': '/workspace/' + escape.name,
                         'guest_package_write': '/guest/supervisor/' + guest_write_host.name,
                         'channel_path': str(channel_path),
                         'protected': protected,
                         'host_home': str(Path.home()),
                         'docker_sockets': list(supplemental.get('docker_socket', [])) or
                             ['/var/run/docker.sock',
                              str(Path.home() / '.docker/run/docker.sock')],
                         'provider_request': request.to_dict(),
                     }}
        worker = r'''import json,os,socket,sys
from pathlib import Path
from supervisor.inference_broker import ContractError,InferenceClient
b=json.load(sys.stdin); p=b['docker_probe']; c={}
for key,expected in (('workspace_read','workspace-probe'),('private_git_read','private-git-probe')):
    try: c[key]=Path(p[key]).read_text()==expected
    except OSError: c[key]=False
for key in ('workspace_write','private_git_write'):
    try: Path(p[key]).write_text('written'); c[key]=True
    except OSError: c[key]=False
for key,paths in p['protected'].items():
    c[key+'_absent']=all(not os.path.lexists(path) for path in paths)
c['host_home_absent']=not os.path.lexists(p['host_home'])
c['docker_socket_absent']=all(not os.path.lexists(path) for path in p['docker_sockets'])
try:
    with open(p['escape'],'rb') as f: f.read(1)
    c['symlink_escape_denied']=False
except OSError: c['symlink_escape_denied']=True
try:
    with open(p['channel_path'],'wb') as f: f.write(b'x')
    c['channel_path_write_denied']=False
except OSError: c['channel_path_write_denied']=True
try:
    with open(p['guest_package_write'],'wb') as f: f.write(b'x')
    c['guest_package_write_denied']=False
except OSError: c['guest_package_write_denied']=True
try:
    socket.create_connection(('1.1.1.1',80),timeout=.5).close()
    c['no_public_egress']=False
except OSError: c['no_public_egress']=True
try:
    i=b['inference']; client=InferenceClient(i['socket_path'],i['attempt_id'],i['capability'],timeout=6)
    c['inference_relay']=client.infer(p['provider_request'])['text']=='docker-probe-ok'
except Exception: c['inference_relay']=False
try:
    client.request({'attempt_id':b['inference']['attempt_id']},operation='human_control')
    c['forged_human_control_denied']=False
except ContractError: c['forged_human_control_denied']=True
Path(p['report']).write_text(json.dumps(c,sort_keys=True))
'''
        with channel:
            completed = transport.run(
                ['python3', '-c', worker], policy, bootstrap=bootstrap, channel=channel,
                attempt_id=attempt_id, capability=channel_capability,
                timeout=20, cancel_event=threading.Event())
        if completed.returncode != 0 or not report_path.is_file():
            detail = completed.stderr.decode('utf-8', 'replace').strip()
            raise IsolationUnavailable('Docker boundary worker did not complete (exit {}): {}'.format(
                completed.returncode, detail[-140:]))
        observed = json.loads(report_path.read_text(encoding='utf-8'))
        for name in ('workspace_read', 'workspace_write', 'private_git_read',
                     'private_git_write'):
            checks[name] = observed.get(name) is True
        for name in ('controller_db', 'controller_socket', 'board_storage',
                     'shared_git_metadata', 'host_credentials', 'ssh_agent', 'keychain'):
            checks[name + '_absent'] = observed.get(name + '_absent') is True
        for name in ('host_home_absent', 'docker_socket_absent', 'no_public_egress',
                     'guest_package_write_denied', 'symlink_escape_denied', 'inference_relay',
                     'forged_human_control_denied', 'channel_path_write_denied'):
            checks[name] = observed.get(name) is True
        command = docker_run_argv(['python3', '-m', 'supervisor.docker_agent'], policy,
                                  str(probe_root / 'argv.cid'))
        checks['no_host_publication'] = ('--network=none' in command
                                         and not any(arg in ('-p', '--publish')
                                                     or arg.startswith('--publish=')
                                                     for arg in command))

        timeout_code = ('from pathlib import Path; import time; '
                        'Path("/workspace/' + timeout_marker.name + '").write_text("started"); '
                        'time.sleep(30)')
        timeout_worker = ['python3', '-c', timeout_code]
        timeout_transport = DockerWorkerTransport()
        timeout_error = []

        def run_timeout_probe():
            try:
                timeout_transport.run(timeout_worker, policy, bootstrap=bootstrap,
                                      channel=channel, attempt_id=attempt_id,
                                      capability=channel_capability,
                                      timeout=5, cancel_event=threading.Event())
            except Exception as exc:
                timeout_error.append(exc)

        timeout_thread = threading.Thread(target=run_timeout_probe, daemon=True)
        timeout_thread.start()
        start_deadline = time.monotonic() + 8
        while not timeout_marker.exists() and timeout_thread.is_alive() and time.monotonic() < start_deadline:
            time.sleep(.05)
        worker_started = timeout_marker.is_file()
        timeout_thread.join(timeout=6)
        container_id = timeout_transport.last_container_id
        label = 'org.fleet-board.supervisor.attempt-id=' + attempt_id
        remaining = subprocess.run(
            [docker, 'container', 'ls', '--all', '--quiet', '--filter', 'label=' + label],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=5, check=False, close_fds=True)
        deadline_hit = (len(timeout_error) == 1 and isinstance(timeout_error[0], RuntimeError)
                        and 'deadline exceeded' in str(timeout_error[0]))
        checks['timeout_cleanup'] = (worker_started and deadline_hit
                                     and timeout_thread.is_alive() is False
                                     and remaining.returncode == 0
                                     and not remaining.stdout.strip())

        cancellation_attempt_id = attempt_id + '-cancel'
        cancellation_bootstrap = dict(bootstrap)
        cancellation_bootstrap['inference'] = dict(bootstrap['inference'])
        cancellation_bootstrap['inference']['attempt_id'] = cancellation_attempt_id
        cancellation_code = ('from pathlib import Path; import time; '
                             'Path("/workspace/' + cancellation_marker.name + '").write_text("started"); '
                             'time.sleep(30)')
        cancellation_transport = DockerWorkerTransport()
        cancellation_event = threading.Event()
        cancellation_error = []

        def run_cancellation_probe():
            try:
                cancellation_transport.run(
                    ['python3', '-c', cancellation_code], policy,
                    bootstrap=cancellation_bootstrap, channel=channel,
                    attempt_id=cancellation_attempt_id, capability=channel_capability,
                    timeout=20, cancel_event=cancellation_event)
            except Exception as exc:
                cancellation_error.append(exc)

        cancellation_thread = threading.Thread(target=run_cancellation_probe, daemon=True)
        cancellation_thread.start()
        cancellation_start_deadline = time.monotonic() + 8
        while (not cancellation_marker.exists() and cancellation_thread.is_alive()
               and time.monotonic() < cancellation_start_deadline):
            time.sleep(.05)
        cancellation_worker_started = cancellation_marker.is_file()
        cancellation_event.set()
        cancellation_thread.join(timeout=6)
        cancellation_label = ('org.fleet-board.supervisor.attempt-id='
                              + cancellation_attempt_id)
        cancellation_remaining = subprocess.run(
            [docker, 'container', 'ls', '--all', '--quiet', '--filter',
             'label=' + cancellation_label],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=5, check=False, close_fds=True)
        cancellation_seen = (len(cancellation_error) == 1
                             and 'cancelled' in str(cancellation_error[0]).lower())
        checks['cancellation_cleanup'] = (
            cancellation_worker_started and cancellation_seen
            and cancellation_thread.is_alive() is False
            and cancellation_remaining.returncode == 0
            and not cancellation_remaining.stdout.strip())

        missing = [name for name, passed in checks.items() if not passed]
        if missing:
            reason = 'Docker boundary checks failed: ' + ', '.join(missing)
            if 'timeout_cleanup' in missing:
                reason += (' (worker did not reach its timeout marker)' if not worker_started else
                           ' (timed-out container remains or timeout did not fire)')
                if timeout_error:
                    reason += ': ' + str(timeout_error[0])[:120]
            if 'cancellation_cleanup' in missing and cancellation_error:
                reason += ' (cancellation cleanup: ' + str(cancellation_error[0])[:120] + ')'
            return result(False, reason)
        return result(True, None)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError,
            RuntimeError) as exc:
        return result(False, str(exc)[:200])
    finally:
        if channel is not None and getattr(channel, '_listener', None) is not None:
            channel.stop()
        for sock in listeners:
            try:
                sock.close()
            except OSError:
                pass
        for path in (workspace_read, private_read, workspace_write, private_write,
                     report_path, escape, channel_path, timeout_marker,
                     cancellation_marker, guest_write_host):
            try:
                path.unlink()
            except OSError:
                pass
        if probe_root is not None:
            shutil.rmtree(probe_root, ignore_errors=True)


def probe_capabilities(policy, *, inference_socket=None, inference_attempt_id=None,
                       inference_capability=None, protected_resources=None):
    """Require real positive and negative checks for every worker boundary."""
    if isinstance(policy, dict) and policy.get('backend') == 'docker':
        return probe_docker_capabilities(policy, protected_resources=protected_resources)
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
    owns_inference_socket = []
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
            _bind_probe_listener(listener, inference_path, owns_inference_socket)
            listener.settimeout(3)
        elif not stat.S_ISSOCK(inference_path.lstat().st_mode):
            raise IsolationUnavailable('inference channel path is not a socket')
        tcp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp_listener.bind(('127.0.0.1', 0))
        tcp_listener.listen(1)
        escape = Path(policy['workspace']) / ('.isolation-probe-escape-' + probe_name)
        _create_probe_symlink(escape, protected['controller_db'][0], workspace_probe_paths)
        own_read = Path(policy['workspace']) / ('.isolation-probe-readable-' + probe_name)
        workspace_probe_paths.append(own_read)
        own_read.write_text('ok', encoding='utf-8')
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
        workspace_probe_paths.extend((script_path, Path(policy['workspace']) /
                                      ('.isolation-probe-write-' + probe_name),
                                      Path(policy['channels']) /
                                      ('.isolation-probe-write-' + probe_name)))
        if forged_control_path is not None:
            workspace_probe_paths.append(Path(policy['workspace']) /
                                         ('.isolation-probe-forged-received-' + probe_name))
        script_path.write_text(script, encoding='utf-8')
        script_path.chmod(0o700)
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
