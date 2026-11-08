"""Copy untrusted worker artifacts into attempt-owned durable storage."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
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


class TrustedAttemptResultHandler:
    """Controller-only result adapter that owns artifacts and calls Store.record_result."""
    def __init__(self, store, binding, scratch):
        fields = {'domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage'}
        if (not isinstance(binding, dict) or set(binding) != fields
                or not isinstance(binding.get('domain_id'), str) or not binding['domain_id']
                or not isinstance(binding.get('job_id'), str) or not binding['job_id']
                or not isinstance(binding.get('attempt_id'), str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', binding['attempt_id'])
                or type(binding.get('generation')) is not int or binding['generation'] < 0
                or not isinstance(binding.get('input_sha'), str)
                or not re.fullmatch(r'[0-9a-f]{64}', binding['input_sha'])
                or not isinstance(binding.get('role'), str)
                or (binding.get('stage') is not None and not isinstance(binding['stage'], str))):
            raise ValueError('invalid trusted result binding')
        if (not callable(getattr(store, 'record_result', None))
                or not isinstance(getattr(store, 'directory', None), (str, os.PathLike))):
            raise ValueError('trusted result handler requires a supervisor store')
        if getattr(store, 'domain_id', None) != binding['domain_id']:
            raise ValueError('trusted result store does not match attempt domain')
        scratch = Path(scratch)
        if (not scratch.is_absolute() or scratch.is_symlink()
                or scratch.resolve(strict=True) != scratch
                or not scratch.is_dir() or scratch.stat().st_uid != os.getuid()
                or scratch.stat().st_mode & 0o077):
            raise ValueError('trusted result scratch must be a private canonical directory')
        self.store = store
        self.binding = dict(binding)
        self.scratch = scratch
        self.store_directory = Path(store.directory)
        if (not self.store_directory.is_absolute() or self.store_directory.is_symlink()
                or self.store_directory.resolve(strict=True) != self.store_directory
                or not self.store_directory.is_dir()
                or self.store_directory.stat().st_uid != os.getuid()
                or self.store_directory.stat().st_mode & 0o077):
            raise ValueError('trusted result store directory is unsafe')
        try:
            shared_root = os.path.commonpath((str(self.store_directory), str(self.scratch)))
        except ValueError as exc:
            raise ValueError('trusted result store and scratch are on incompatible roots') from exc
        if shared_root in (str(self.store_directory), str(self.scratch)):
            raise ValueError('worker scratch must be isolated from the result store')
        self.parser = Path(__file__).resolve().parents[1] / 'parse-report.sh'
        if not self.parser.is_file() or not os.access(str(self.parser), os.X_OK):
            raise ValueError('role report parser is unavailable')

    @staticmethod
    def _names_and_hashes(payload):
        hashes = payload.get('artifact_hashes')
        if not isinstance(hashes, dict) or not hashes or len(hashes) > 128:
            raise ValueError('invalid result artifact list')
        for name, digest in hashes.items():
            if (not isinstance(name, str) or not name or name in ('.', '..')
                    or '/' in name or '\\' in name or len(name) > 255
                    or any(ord(char) < 32 or ord(char) == 127 for char in name)
                    or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest)):
                raise ValueError('invalid result artifact entry')
        report_name = payload.get('report_path')
        if not isinstance(report_name, str) or report_name not in hashes:
            raise ValueError('result report must name an attempt artifact')
        return dict(hashes), report_name

    def _ingest(self, names, expected_hashes, destination):
        artifacts_root = destination.parent
        if artifacts_root.is_symlink():
            raise ValueError('unsafe attempt artifact root')
        artifacts_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if (artifacts_root.resolve(strict=True) != artifacts_root
                or artifacts_root.stat().st_uid != os.getuid()
                or artifacts_root.stat().st_mode & 0o077):
            raise ValueError('unsafe attempt artifact root')
        if not destination.exists() and not destination.is_symlink():
            actual = ingest_artifacts(self.scratch, destination, names)
            if actual != expected_hashes:
                if destination.is_dir() and not destination.is_symlink():
                    shutil.rmtree(destination)
                raise ValueError('result artifact hash mismatch')
            return actual
        if (destination.is_symlink() or not destination.is_dir()
                or destination.resolve(strict=True) != destination
                or destination.stat().st_uid != os.getuid()
                or destination.stat().st_mode & 0o077):
            raise ValueError('unsafe existing attempt artifacts')
        manifest_path = destination / '.manifest.json'
        fd = os.open(str(manifest_path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536:
                raise ValueError('unsafe artifact manifest')
            manifest = json.loads(stream.read(65537))
        if manifest != expected_hashes or set(manifest) != set(names):
            raise ValueError('conflicting attempt artifact replay')
        for name, digest in manifest.items():
            path = destination / name
            fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1048576:
                    raise ValueError('unsafe durable artifact')
                actual = hashlib.sha256(stream.read(1048577)).hexdigest()
            if actual != digest:
                raise ValueError('durable artifact hash mismatch')
        return manifest

    def __call__(self, payload):
        identity = {'schema_version', 'domain_id', 'job_id', 'attempt_id',
                    'generation', 'input_sha', 'role', 'stage'}
        required = identity | {'request_id', 'outcome', 'report_path', 'artifact_hashes', 'usage', 'exit_code'}
        if (not isinstance(payload, dict) or set(payload) != required
                or type(payload.get('schema_version')) is not int or payload['schema_version'] != 1
                or type(payload.get('generation')) is not int
                or any(payload.get(key) != self.binding[key] for key in identity - {'schema_version'})):
            raise ValueError('result envelope does not match attempt')
        if (not isinstance(payload.get('request_id'), str) or not payload['request_id']
                or payload['outcome'] not in ('success', 'failure', 'cancelled')
                or type(payload['exit_code']) is not int):
            raise ValueError('invalid attempt result')
        usage = payload['usage']
        if usage is not None and (not isinstance(usage, dict) or set(usage) != {'cost_usd'}
                                  or type(usage['cost_usd']) not in (int, float)
                                  or not math.isfinite(usage['cost_usd']) or usage['cost_usd'] < 0):
            raise ValueError('invalid attempt usage')
        hashes, report_name = self._names_and_hashes(payload)
        destination = self.store_directory / 'artifacts' / self.binding['attempt_id']
        actual = self._ingest(list(hashes), hashes, destination)
        report_path = destination / report_name
        parsed = subprocess.run(
            [str(self.parser), '--role', self.binding['role'], str(report_path)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=30, close_fds=True,
            env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C'},
        )
        if parsed.returncode != 0:
            raise ValueError('attempt role report is invalid')
        try:
            report = json.loads(parsed.stdout.decode('utf-8'))
        except (UnicodeDecodeError, ValueError) as exc:
            raise ValueError('attempt role report parser returned invalid output') from exc
        if not isinstance(report, dict) or not isinstance(report.get('status'), str):
            raise ValueError('attempt role report parser returned invalid output')
        envelope = {key: self.binding[key] for key in
                    ('domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage')}
        envelope.update(schema_version=1, outcome=payload['outcome'], report_path=str(report_path),
                        artifact_hashes={str(destination / name): digest for name, digest in actual.items()},
                        usage=usage, exit_code=payload['exit_code'])
        return self.store.record_result(envelope)


def build_attempt_result_handler(store, binding, scratch):
    """Build the only supported production result callback for an attempt."""
    return TrustedAttemptResultHandler(store, binding, scratch)


def build_attempt_operation_handlers(store, card, *, binding, scratch, heartbeat,
                                     checkpoint, release_slot):
    """Create trusted controller callbacks for one worker's restricted IPC surface.

    The returned functions stay in the controller. The worker receives only the
    authenticated channel capability and operation names; Store access is never
    serialized into bootstrap data.
    """
    if not isinstance(card, str) or not card or not callable(getattr(store, 'expand_scope', None)):
        raise ValueError('attempt operation handlers require a card and reservation store')
    if any(not callable(callback) for callback in (heartbeat, checkpoint, release_slot)):
        raise ValueError('attempt operation handlers require trusted callbacks')
    result_handler = build_attempt_result_handler(store, binding, scratch)

    def expand_scope(payload):
        return request_scope_expansion(
            store, card, payload['paths'], payload['expected_revision'], checkpoint, release_slot,
        )

    return {'heartbeat': heartbeat, 'result': result_handler, 'scope_request': expand_scope}
