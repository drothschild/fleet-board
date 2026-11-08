"""Copy untrusted worker artifacts into attempt-owned durable storage."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import shutil


def ingest_artifacts(scratch, destination, names):
    scratch, destination = Path(scratch), Path(destination)
    if not isinstance(names, list) or not names or len(names) > 128 or len(set(names)) != len(names):
        raise ValueError('invalid artifact set')
    if scratch.is_symlink() or scratch.resolve(strict=True) != scratch.absolute():
        raise ValueError('unsafe scratch directory')
    parent = destination.parent
    if parent.is_symlink() or parent.resolve(strict=True) != parent.absolute() or parent.stat().st_uid != os.getuid():
        raise ValueError('unsafe destination directory')
    if destination.exists() or destination.is_symlink():
        raise ValueError('artifact destination already exists')
    final_destination = destination
    destination = Path(tempfile.mkdtemp(prefix='.ingest-', dir=str(parent)))
    root_fd = os.open(str(scratch), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    hashes = {}
    total = 0
    try:
        for name in names:
            if not isinstance(name, str) or not name or '/' in name or name in ('.', '..', '.manifest.json'):
                raise ValueError('invalid artifact name')
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
            except OSError as exc:
                raise ValueError('invalid artifact') from exc
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > 1048576:
                    raise ValueError('invalid artifact')
                total += before.st_size
                if total > 16 * 1048576:
                    raise ValueError('artifact set too large')
                digest = hashlib.sha256()
                target = destination / name
                out = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                copied = 0
                with os.fdopen(out, 'wb') as stream:
                    while True:
                        chunk = os.read(fd, 65536)
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > before.st_size or copied > 1048576:
                            raise ValueError('artifact changed during ingestion')
                        digest.update(chunk)
                        stream.write(chunk)
                    stream.flush()
                    os.fsync(stream.fileno())
                after = os.fstat(fd)
                path_stat = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
                signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
                if signature(before) != signature(after) or signature(after) != signature(path_stat):
                    raise ValueError('artifact changed during ingestion')
                hashes[name] = digest.hexdigest()
            finally:
                os.close(fd)
        manifest_fd = os.open(str(destination / '.manifest.json'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(manifest_fd, 'w', encoding='utf-8') as manifest:
            json.dump(hashes, manifest, sort_keys=True)
            manifest.flush()
            os.fsync(manifest.fileno())
        fd = os.open(str(destination), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rename(destination, final_destination)
        fd = os.open(str(final_destination.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return hashes
    finally:
        os.close(root_fd)
        if destination.exists():
            shutil.rmtree(destination)


def verify_worker_scope(store, card, changed_paths):
    """Quarantine undeclared changes from publication through the store audit."""
    result = store.verify_scope_changes(str(card), changed_paths)
    if not result['authorized']:
        return {'publication_hold': True, 'quarantined': True, **result}
    return {'publication_hold': False, 'quarantined': False, **result}


def request_scope_expansion(store, card, paths, expected_revision, checkpoint, release_slot):
    """Checkpoint a denied writer, then release capacity without retry penalty."""
    try:
        reservation = store.expand_scope(str(card), paths, expected_revision)
        return {'granted': True, 'reservation': reservation}
    except ValueError as exc:
        if not str(exc).startswith('scope conflict with #'):
            raise
        if not callable(checkpoint):
            raise ValueError('scope expansion requires a checkpoint callback')
        if not callable(release_slot):
            raise ValueError('scope expansion requires a slot-release callback')
        checkpoint()
        release_slot()
        return {'granted': False, 'waiting_on': str(exc).split('#', 1)[1],
                'checkpointed': True, 'worker_slot_released': True,
                'retry_penalty': False, 'attempt_should_exit': True}
