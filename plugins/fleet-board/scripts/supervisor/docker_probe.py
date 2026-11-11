"""Run the opt-in, offline Docker Desktop boundary qualification probe."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

from .isolation import build_policy, probe_docker_capabilities


def _socket_file(path):
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    listener.listen(1)
    return listener


def main():
    image = os.environ.get('FLEET_BOARD_DOCKER_PROBE_IMAGE', '')
    if not isinstance(image, str) or len(image) != 71 or not image.startswith('sha256:'):
        print(json.dumps({'available': False, 'reason':
                          'FLEET_BOARD_DOCKER_PROBE_IMAGE must be a cached immutable image ID'}))
        return 1
    if any(char not in '0123456789abcdef' for char in image[7:]):
        print(json.dumps({'available': False, 'reason':
                          'FLEET_BOARD_DOCKER_PROBE_IMAGE must be a cached immutable image ID'}))
        return 1
    scratch_parent = '/private/tmp' if Path('/private/tmp').is_dir() else None
    root = Path(tempfile.mkdtemp(prefix='fb-docker-host-', dir=scratch_parent))
    root.chmod(0o700)
    listeners = []
    try:
        workspace = root / 'workspace'
        private_git = root / 'private-git'
        channels = root / 'channels'
        controller_db = root / 'controller.db'
        controller_db.write_text('probe sentinel', encoding='utf-8')
        board = root / 'board-storage'
        shared_git = root / 'shared-git'
        credential = root / 'credential'
        keychain = root / 'keychain'
        board.mkdir(mode=0o700)
        shared_git.mkdir(mode=0o700)
        credential.write_text('probe sentinel', encoding='utf-8')
        keychain.write_text('probe sentinel', encoding='utf-8')
        controller_socket = _socket_file(root / 'controller.sock')
        ssh_socket = _socket_file(root / 'ssh-agent.sock')
        listeners.extend((controller_socket, ssh_socket))
        workspace.mkdir(mode=0o700)
        private_git.mkdir(mode=0o700)
        channels.mkdir(mode=0o700)

        credentials = [str(credential)]
        for path in (Path.home() / '.aws/credentials',
                     Path.home() / '.config/gcloud/application_default_credentials.json'):
            if path.exists() and not path.is_symlink():
                credentials.append(str(path))
        ssh_path_string = str(root / 'ssh-agent.sock')
        keychains = [str(keychain)]
        actual_keychain = Path.home() / 'Library/Keychains/login.keychain-db'
        if actual_keychain.exists() and not actual_keychain.is_symlink():
            keychains.append(str(actual_keychain))
        protected = {
            'controller_db': str(controller_db),
            'controller_socket': str(root / 'controller.sock'),
            'board_storage': str(board),
            'shared_git_metadata': str(shared_git),
            'host_credentials': credentials,
            'ssh_agent': ssh_path_string,
            'keychain': keychains,
        }
        policy = build_policy(workspace, private_git, channels, backend='docker',
                              docker_image=image)
        policy['_docker_probe_host_paths'] = {
            'ssh_agent': ([os.environ['SSH_AUTH_SOCK']]
                          if os.path.isabs(os.environ.get('SSH_AUTH_SOCK', '')) else []),
            'docker_socket': ['/var/run/docker.sock',
                              str(Path.home() / '.docker/run/docker.sock')],
        }
        result = probe_docker_capabilities(policy, protected_resources=protected)
        print(json.dumps(result, sort_keys=True))
        return 0 if result.get('available') is True else 1
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({'available': False, 'reason': str(exc)[:200]}))
        return 1
    finally:
        for listener in listeners:
            try:
                listener.close()
            except OSError:
                pass
        shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
