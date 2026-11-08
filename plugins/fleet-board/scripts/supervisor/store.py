"""Private, transactional state for one supervisor domain.

All mutations go through this interface. A caller cannot acquire the connection.
"""
import hashlib
import json
import math
import os
import re
import secrets
import sqlite3
import stat
import subprocess
import sys
import time
from pathlib import Path

from .models import NeverExecutedEvidence, RetryEvidence, StopEvidence, canonical_json
from .processes import _boot_id

SCHEMA_VERSION = 1


SCHEMA = '''
                    CREATE TABLE domain (id TEXT PRIMARY KEY, identity TEXT NOT NULL, desired_mode TEXT NOT NULL, phase TEXT NOT NULL, revision INTEGER NOT NULL, config_hash TEXT, service_version TEXT);
                    CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL, deadline REAL NOT NULL, known_spend REAL NOT NULL, unknown_spend INTEGER NOT NULL, budget_stop TEXT);
                    CREATE TABLE jobs (id TEXT PRIMARY KEY, logical_key TEXT UNIQUE NOT NULL, card TEXT NOT NULL, generation INTEGER NOT NULL, input_sha TEXT NOT NULL, role TEXT NOT NULL, stage TEXT NOT NULL, state TEXT NOT NULL, retries_used INTEGER NOT NULL, data TEXT NOT NULL);
                    CREATE TABLE attempts (id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), nonce TEXT UNIQUE NOT NULL, provider TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL);
                    CREATE TABLE claims (attempt_id TEXT PRIMARY KEY REFERENCES attempts(id), card TEXT NOT NULL, provider TEXT NOT NULL, paths TEXT NOT NULL, merge_lane INTEGER NOT NULL, reservation_revision INTEGER NOT NULL);
                    CREATE TABLE effects (operation_key TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), card TEXT NOT NULL, generation INTEGER NOT NULL, preconditions TEXT NOT NULL, intent TEXT NOT NULL, observation TEXT, status TEXT NOT NULL);
                    CREATE TABLE results (attempt_id TEXT PRIMARY KEY REFERENCES attempts(id), envelope TEXT NOT NULL, disposition TEXT NOT NULL);
                    CREATE TABLE commands (id TEXT PRIMARY KEY, request TEXT NOT NULL, outcome TEXT NOT NULL);
                    CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL);
                    PRAGMA user_version=1;'''

def _filesystem(path):
    """Classify filesystems conservatively: unknown types are not safe for WAL."""
    if sys.platform == 'darwin':
        try:
            mounts = subprocess.check_output(['/sbin/mount'], text=True)
            best = ('', False)
            for line in mounts.splitlines():
                if ' on ' not in line or ' (' not in line or not line.endswith(')'):
                    continue
                mount, options = line.rsplit(' on ', 1)[1].rsplit(' (', 1)
                options = options[:-1].split(', ')
                if (str(path) == mount or str(path).startswith(mount.rstrip('/') + '/')) and len(mount) > len(best[0]):
                    best = (mount, options[0] in ('apfs', 'hfs', 'ufs') and 'local' in options)
            return 'local' if best[1] else 'unknown'
        except (OSError, subprocess.CalledProcessError):
            return 'unknown'
    if sys.platform.startswith('linux'):
        try:
            best = ('', '')
            with open('/proc/self/mountinfo', encoding='utf-8') as mounts:
                for line in mounts:
                    left, right = line.rstrip().split(' - ', 1)
                    mount = left.split()[4].replace('\\040', ' ').replace('\\134', '\\')
                    kind = right.split()[0]
                    if (str(path) == mount or str(path).startswith(mount.rstrip('/') + '/')) and len(mount) > len(best[0]):
                        best = (mount, kind)
            return 'local' if best[1] in ('ext2', 'ext3', 'ext4', 'xfs', 'btrfs', 'tmpfs', 'overlay', 'zfs') else 'unknown'
        except (OSError, ValueError, IndexError):
            return 'unknown'
    return 'unknown'


def _capture_timing(data, now, timeout_seconds, session_deadline):
    if type(timeout_seconds) not in (int, float) or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError('invalid attempt timeout')
    if ('started_at' in data) != ('deadline' in data):
        raise ValueError('incomplete captured timing')
    if 'started_at' not in data:
        deadline = min(now + timeout_seconds, session_deadline)
        if not math.isfinite(deadline) or deadline <= now:
            raise ValueError('attempt deadline expired')
        data.update({'started_at': now, 'deadline': deadline})
    elif (type(data['started_at']) not in (int, float) or type(data['deadline']) not in (int, float)
          or not math.isfinite(data['started_at']) or not math.isfinite(data['deadline'])
          or data['deadline'] <= now or data['deadline'] > session_deadline):
        raise ValueError('invalid captured timing')


def _scope_key(path):
    """Compare ASCII case-insensitively; uncertain Unicode reserves the repo.

    Filesystems differ in Unicode equivalence. Treating non-ASCII paths as
    repository-wide is conservative across hosts, including for paths that do
    not exist yet. Persisted claims retain the original path for publication.
    """
    return path.lower() if path.isascii() else ''


def _sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_private_json(path, limit):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit:
            raise ValueError('unsafe or oversized evidence')
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('oversized evidence')
    return json.loads(raw)


def _private_directory(path):
    path = Path(path).absolute()
    # Refuse symlinks at every existing component, including ancestors.
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('symlink in runtime path')
    missing = []
    cursor = path
    while not cursor.exists():
        missing.append(cursor)
        cursor = cursor.parent
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError('unsafe runtime directory')
        _sync_directory(directory)
        _sync_directory(directory.parent)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('runtime directory must be private and owned by user')
    return path


class Store:
    @classmethod
    def open(cls, domain, filesystem_inspector=None, fault_injector=None, stop_evidence_verifier=None, retry_evidence_verifier=None, launch_evidence_verifier=None, human_actor_verifier=None):
        identity = {key: domain[key] for key in ('common_dir', 'board_backend', 'board_identity')}
        if not all(isinstance(v, str) and v for v in identity.values()):
            raise ValueError('invalid domain identity')
        common = Path(identity['common_dir'])
        if not common.is_absolute() or not common.is_dir():
            raise ValueError('invalid git common directory')
        identity['common_dir'] = str(common.resolve(strict=True))
        domain_id = hashlib.sha256(canonical_json(identity).encode()).hexdigest()
        root = domain.get('runtime_root') or os.path.join(os.environ.get('FLEET_BOARD_LOG_DIR', os.path.expanduser('~/.fleet-board')), 'supervisor')
        root = _private_directory(root)
        if (filesystem_inspector or _filesystem)(root) != 'local':
            raise ValueError('supervisor store requires a known local filesystem')
        directory = _private_directory(root / domain_id)
        db = directory / 'store.sqlite3'
        if db.is_symlink() or (db.exists() and (not db.is_file() or db.stat().st_uid != os.getuid() or db.stat().st_mode & 0o077)):
            raise ValueError('unsafe database')
        # Exclusive create supplies restrictive mode without a process-global umask.
        if not db.exists():
            try:
                fd = os.open(str(db), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(fd)
                _sync_directory(directory)
            except FileExistsError:
                pass
        conn = sqlite3.connect(str(db), timeout=30, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute('PRAGMA foreign_keys=ON')
            conn.execute('BEGIN IMMEDIATE')
            version = conn.execute('PRAGMA user_version').fetchone()[0]
            if version not in (0, SCHEMA_VERSION):
                raise ValueError('unsupported supervisor schema')
            if version == 0:
                if conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]:
                    raise ValueError('unversioned supervisor database is not empty')
                for statement in SCHEMA.split(';'):
                    if statement.strip():
                        conn.execute(statement)
            # The stored table SQL includes primary, unique, foreign-key and
            # nullability constraints. Compare against SQLite's own rendering of
            # this version's trusted schema, rather than only column names.
            expected = sqlite3.connect(':memory:')
            try:
                for statement in SCHEMA.split(';'):
                    if statement.strip():
                        expected.execute(statement)
                query = "SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
                actual_tables = [tuple(row) for row in conn.execute(query)]
                expected_tables = list(expected.execute(query))
                if actual_tables != expected_tables:
                    raise ValueError('corrupt supervisor schema')
            finally:
                expected.close()
            if conn.execute('PRAGMA quick_check').fetchone()[0] != 'ok' or conn.execute('PRAGMA foreign_key_check').fetchone() is not None:
                raise ValueError('corrupt supervisor database')
            conn.execute('COMMIT')
            conn.execute('PRAGMA journal_mode=WAL')
            conn.execute('PRAGMA synchronous=FULL')
            conn.execute('BEGIN IMMEDIATE')
            row = conn.execute('SELECT id, identity FROM domain').fetchone()
            if row is None:
                conn.execute('INSERT INTO domain VALUES (?, ?, ?, ?, 0, NULL, NULL)', (domain_id, canonical_json(identity), 'stopped', 'stopped'))
            elif row['id'] != domain_id or row['identity'] != canonical_json(identity):
                raise ValueError('domain identity mismatch')
            conn.execute('COMMIT')
        except Exception:
            if conn.in_transaction:
                conn.execute('ROLLBACK')
            conn.close()
            raise
        return cls(conn, directory, domain_id, Path(identity['common_dir']), fault_injector, stop_evidence_verifier, retry_evidence_verifier, launch_evidence_verifier, human_actor_verifier)

    def __init__(self, connection, directory, domain_id, common_dir, fault_injector, stop_evidence_verifier, retry_evidence_verifier, launch_evidence_verifier, human_actor_verifier=None):
        self.__connection = connection
        self.__stop_evidence_verifier = stop_evidence_verifier
        self.__retry_evidence_verifier = retry_evidence_verifier
        self.__launch_evidence_verifier = launch_evidence_verifier
        # This callback is an injected trust boundary. It does not itself
        # provide or claim a real service authentication boundary.
        self.__human_actor_verifier = human_actor_verifier
        self.directory = directory
        self.domain_id = domain_id
        self.__scope_root = common_dir.parent if common_dir.name == ".git" else common_dir
        self.__fault_injector = fault_injector

    def close(self):
        self.__connection.close()

    def _event(self, kind, payload):
        self.__connection.execute('INSERT INTO events(timestamp,type,payload) VALUES(?,?,?)', (time.time(), kind, canonical_json(payload)))
        self.__connection.execute('UPDATE domain SET revision=revision+1')

    def _reservations(self):
        reservations = {}
        for event in self.__connection.execute("SELECT type,payload FROM events WHERE type LIKE 'scope_%' OR type='attempt_prepared' ORDER BY sequence"):
            payload = json.loads(event['payload'])
            if event['type'] == 'attempt_prepared':
                payload = payload.get('scope_reservation')
                if payload is None:
                    continue
            if event['type'] not in ('scope_reserved', 'scope_released', 'scope_wait', 'scope_wait_cleared', 'attempt_prepared'):
                continue
            card = payload['card']
            if event['type'] in ('scope_wait', 'scope_wait_cleared'):
                continue
            if event['type'] == 'scope_released':
                reservations.pop(card, None)
            else:
                item = reservations.setdefault(card, {'card': card, 'paths': [], 'revision': 0, 'enforceable': True})
                if event['type'] in ('scope_reserved', 'attempt_prepared'):
                    item['paths'] = sorted(set(item['paths']) | set(payload['paths']))
                    item['enforceable'] = item['enforceable'] and payload.get('enforceable', True)
                    if not item['enforceable']:
                        item['paths'] = ['']
                item['revision'] = payload.get('reservation_revision', item['revision'] + 1)
        return reservations

    def _normalize_scope(self, paths):
        if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
            raise ValueError('invalid scope')
        normalized = set()
        for raw in paths:
            if raw == '':
                normalized.add('')
                continue
            path = raw.replace('\\', '/')
            while path.startswith('./'):
                path = path[2:]
            path = path.rstrip('/')
            if path == '':
                normalized.add('')
                continue
            parts = path.split('/')
            if path.startswith('/') or any(part in ('', '.', '..') for part in parts):
                raise ValueError('invalid scope path')
            cursor = self.__scope_root
            for part in parts:
                cursor = cursor / part
                if cursor.is_symlink():
                    raise ValueError('symlink in scope')
            normalized.add('/'.join(parts))
        return sorted(normalized) or ['']

    def scope_conflict(self, card, paths):
        paths = self._normalize_scope(paths)
        for owner, reservation in self._reservations().items():
            if owner == str(card):
                continue
            for left in paths:
                for right in reservation['paths']:
                    a, b = _scope_key(left), _scope_key(right)
                    if not a or not b or a == b or a.startswith(b + '/') or b.startswith(a + '/'):
                        return owner
        return None

    def _scope_wait_cycles(self):
        waits = {}
        for row in self.__connection.execute("SELECT type,payload FROM events WHERE type IN ('scope_wait','scope_wait_cleared') ORDER BY sequence"):
            payload = json.loads(row['payload'])
            if row['type'] == 'scope_wait_cleared':
                waits.pop(payload['card'], None)
            else:
                waits[payload['card']] = payload['waiting_on']
        cycles, visited = [], set()
        for start in waits:
            path, positions, node = [], {}, start
            while node in waits:
                if node in positions:
                    cycle = path[positions[node]:]
                    canonical = tuple(sorted(cycle))
                    if canonical not in visited:
                        visited.add(canonical); cycles.append(list(canonical))
                    break
                positions[node] = len(path); path.append(node); node = waits[node]
        return cycles

    def _card_lifecycles(self):
        states = {}
        for row in self.__connection.execute("SELECT type,payload FROM events WHERE type IN ('card_lifecycle','scope_refresh_intent','scope_refresh_succeeded') ORDER BY sequence"):
            payload = json.loads(row['payload'])
            if row['type'] == 'card_lifecycle':
                states[payload['card']] = payload['state']
            elif row['type'] == 'scope_refresh_intent':
                states[payload['card']] = 'refresh_pending'
            else:
                states[payload['card']] = payload['workflow_state']
        return states

    def set_card_lifecycle(self, card, state, expected_revision):
        allowed = {'ready', 'active', 'review', 'ci_wait', 'human_qa', 'retry_wait', 'paused', 'blocked', 'complete', 'needs_attention'}
        if not isinstance(card, str) or not card or not isinstance(state, str) or state not in allowed:
            raise ValueError('invalid card lifecycle')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            revision = c.execute('SELECT revision FROM domain').fetchone()[0]
            if type(expected_revision) is not int or revision != expected_revision:
                raise ValueError('revision mismatch')
            self._event('card_lifecycle', {'card': card, 'state': state})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def reserve_scope(self, card, paths, expected_revision, *, enforceable=True):
        if not isinstance(card, str) or not card or type(enforceable) is not bool:
            raise ValueError('invalid reservation')
        paths = self._normalize_scope(paths)
        if not enforceable:
            paths = ['']
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        denied = None
        try:
            revision = c.execute('SELECT revision FROM domain').fetchone()[0]
            if type(expected_revision) is not int or revision != expected_revision:
                raise ValueError('revision mismatch')
            owner = self.scope_conflict(card, paths)
            if owner is not None:
                denied = owner
                self._event('scope_wait', {'card': card, 'waiting_on': owner})
                cycles = self._scope_wait_cycles()
                if cycles:
                    self._event('scope_cycle_attention', {'cycles': cycles})
                c.execute('COMMIT')
            else:
                current = self._reservations().get(card)
                combined = sorted(set((current or {}).get('paths', [])) | set(paths))
                if not enforceable:
                    combined = ['']
                next_revision = (current or {}).get('revision', 0) + 1
                payload = {'card': card, 'paths': combined, 'enforceable': enforceable, 'reservation_revision': next_revision}
                self._event('scope_wait_cleared', {'card': card})
                self._event('scope_reserved', payload)
                c.execute('COMMIT')
                return dict(payload)
        except Exception:
            c.execute('ROLLBACK')
            raise
        if denied is not None:
            raise ValueError('scope conflict with #' + denied)

    def expand_scope(self, card, paths, expected_revision):
        return self.reserve_scope(card, paths, expected_revision)

    def release_scope(self, card, command_id, actor, reason, expected_revision, *, reservation_revision=None, actor_capability=None):
        if any(not isinstance(x, str) or not x for x in (card, command_id, actor, reason)):
            raise ValueError('invalid release request')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            revision = c.execute('SELECT revision FROM domain').fetchone()[0]
            if type(expected_revision) is not int or expected_revision != revision:
                raise ValueError('revision mismatch')
            if type(reservation_revision) is not int:
                raise ValueError('reservation revision required')
            if self.__human_actor_verifier is None or self.__human_actor_verifier(actor, actor_capability) is not True:
                raise ValueError('authenticated human actor required')
            if self._card_lifecycles().get(card) != 'paused':
                raise ValueError('card must be paused before release')
            reservation = self._reservations().get(card)
            if reservation is None:
                raise ValueError('no reservation')
            if reservation['revision'] != reservation_revision:
                raise ValueError('reservation revision mismatch')
            if any(json.loads(row['data']).get('execution_released') is not True for row in c.execute("SELECT data FROM attempts WHERE job_id IN (SELECT id FROM jobs WHERE card=?)", (card,))):
                raise ValueError('live or uncertain writer')
            if c.execute("SELECT 1 FROM effects WHERE card=? AND status NOT IN ('applied','complete','reconciled')", (card,)).fetchone():
                raise ValueError('pending effect')
            payload = {'card': card, 'actor': actor, 'reason': reason, 'released_paths': reservation['paths'],
                       'reservation_revision': reservation['revision'], 'command_id': command_id}
            self._event('scope_released', payload)
            c.execute('INSERT INTO commands VALUES(?,?,?)', (command_id, canonical_json({'actor': actor, 'command': 'release_reservations', 'payload': {'card': card, 'reason': reason}, 'expected_revision': expected_revision}), canonical_json(payload)))
            c.execute('COMMIT')
            return payload
        except Exception:
            c.execute('ROLLBACK')
            raise

    def resume_scope(self, card, paths, workflow_state, refresh_branch, *, expected_revision):
        paths = self._normalize_scope(paths)
        if not isinstance(workflow_state, str) or not workflow_state:
            raise ValueError('invalid workflow state')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            revision = c.execute('SELECT revision FROM domain').fetchone()[0]
            if type(expected_revision) is not int or expected_revision != revision:
                raise ValueError('revision mismatch')
            owner = self.scope_conflict(card, paths)
            if owner is not None:
                self._event('scope_wait', {'card': card, 'waiting_on': owner})
                cycles = self._scope_wait_cycles()
                if cycles:
                    self._event('scope_cycle_attention', {'cycles': cycles})
                c.execute('COMMIT')
                return {'state': 'scope_wait', 'waiting_on': owner, 'workflow_state': workflow_state}
            prior = self._reservations().get(card)
            union = sorted(set((prior or {}).get('paths', [])) | set(paths))
            self._event('scope_reserved', {'card': card, 'paths': union, 'enforceable': True,
                                           'reservation_revision': (prior or {}).get('revision', 0) + 1})
            self._event('scope_wait_cleared', {'card': card})
            self._event('scope_refresh_intent', {'card': card, 'workflow_state': workflow_state})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise
        try:
            refresh_branch()
        except Exception as exc:
            self.append_event({'type': 'scope_refresh_failed', 'payload': {'card': card, 'reason': str(exc)[:300]}})
            return {'state': 'refresh_pending', 'attention': True, 'workflow_state': workflow_state}
        self.append_event({'type': 'scope_refresh_succeeded', 'payload': {'card': card, 'workflow_state': workflow_state,
                                                                          'evidence_invalidated': True}})
        return {'state': 'ready', 'workflow_state': workflow_state, 'evidence_invalidated': True}

    def verify_scope_changes(self, card, changed_paths):
        reservation = self._reservations().get(str(card))
        if reservation is None:
            paths = ([path for path in changed_paths if isinstance(path, str)][:128]
                     if isinstance(changed_paths, list) else ['<unknown>'])
            self._record_scope_violation(str(card), paths or ['<unknown>'], 'missing reservation')
            return {'authorized': False, 'publication_hold': True, 'reason': 'missing reservation'}
        try:
            changed = self._normalize_scope(changed_paths)
        except ValueError:
            changed = ['<invalid-scope>']
        if '' in reservation['paths']:
            return {'authorized': True, 'publication_hold': False}
        unauthorized = []
        for path in changed:
            if not any(path == owned or path.startswith(owned + '/') for owned in reservation['paths']):
                unauthorized.append(path)
        if unauthorized:
            self._record_scope_violation(str(card), unauthorized, 'unauthorized scope change')
            return {'authorized': False, 'publication_hold': True, 'paths': unauthorized}
        return {'authorized': True, 'publication_hold': False}

    def _record_scope_violation(self, card, paths, reason):
        """Persist quarantine and publication hold atomically, including legacy jobs."""
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            jobs = list(c.execute("SELECT id FROM jobs WHERE card=? AND state='active'", (card,)))
            for job in jobs:
                c.execute("UPDATE jobs SET state='needs_attention',generation=generation+1 WHERE id=?", (job['id'],))
                for row in list(c.execute('SELECT id,data FROM attempts WHERE job_id=?', (job['id'],))):
                    data = json.loads(row['data'])
                    data['quarantine_reason'] = reason
                    c.execute("UPDATE attempts SET state='quarantined',data=? WHERE id=?", (canonical_json(data), row['id']))
            c.execute("UPDATE effects SET status='blocked' WHERE card=? AND status NOT IN ('applied','complete','reconciled')", (card,))
            self._event('scope_violation', {'card': card, 'paths': paths, 'reason': reason})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def _publication_held(self, card):
        for row in self.__connection.execute("SELECT payload FROM events WHERE type='scope_violation'"):
            if json.loads(row['payload']).get('card') == str(card):
                return True
        return False

    def start_session(self, session):
        required = ('id', 'started_at', 'deadline', 'known_spend', 'unknown_spend', 'budget_stop')
        if any(k not in session for k in required) or not isinstance(session['id'], str) or not session['id']:
            raise ValueError('invalid session')
        for key in ('started_at', 'deadline', 'known_spend'):
            value = session[key]
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError('invalid session number')
        if type(session['unknown_spend']) is not bool or session['deadline'] < session['started_at']:
            raise ValueError('invalid session budget')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            c.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?)', tuple(session[k] for k in required))
            self._event('session_started', {'id': session['id']})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def prepare_attempt(self, job, expected_revision, claims):
        fields = ('id', 'card', 'action', 'role', 'stage', 'input_sha', 'input_version', 'provider', 'model', 'nonce', 'session_id')
        reserved = {'state', 'boot_id', 'process_identity', 'started_at', 'deadline', 'heartbeat', 'progress',
                    'cancel_reason', 'cancel_requested_at', 'cancel_grace_deadline', 'execution_released',
                    'stop_evidence', 'quarantine_reason', 'retry_at', 'retry_nonce', 'retry_prior', 'suspected_stuck'}
        if not isinstance(job, dict) or reserved.intersection(job):
            raise ValueError('reserved attempt lifecycle metadata')
        if any(not isinstance(job.get(k), str) or not job[k] for k in fields):
            raise ValueError('invalid job')
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', job['nonce']):
            raise ValueError('invalid nonce')
        if any(type(job.get(k)) is not int or job[k] < 0 for k in ('generation', 'round')):
            raise ValueError('invalid job version')
        for key in ('global_cap', 'provider_cap'):
            if type(claims.get(key)) is not int or claims[key] < 1:
                raise ValueError('invalid capacity')
        paths = claims.get('paths')
        if not isinstance(paths, list) or any(not isinstance(p, str) or not p or p.startswith('/') or any(x in ('', '.', '..') for x in p.split('/')) for p in paths):
            raise ValueError('invalid scope')
        for path in paths:
            candidate = self.__scope_root
            for component in path.split('/'):
                candidate = candidate / component
                if candidate.is_symlink():
                    raise ValueError('symlink in scope')
        paths = sorted(set(paths)) or ['']
        enforceable = claims.get('enforceable', True)
        if type(enforceable) is not bool:
            raise ValueError('invalid scope enforcement')
        if not enforceable:
            paths = ['']
        lane = claims.get('merge_lane', False)
        if type(lane) is not bool:
            raise ValueError('invalid merge claim')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            lifecycle = self._card_lifecycles().get(job['card'])
            if lifecycle == 'refresh_pending':
                raise ValueError('refresh pending; worker admission blocked')
            if lifecycle in ('paused', 'human_qa', 'complete', 'needs_attention'):
                raise ValueError('card lifecycle blocks worker admission')
            if c.execute('SELECT 1 FROM sessions WHERE id=?', (job['session_id'],)).fetchone() is None:
                raise ValueError('unknown session')
            active = list(c.execute('SELECT claims.*,attempts.data AS attempt_data FROM claims JOIN attempts ON attempts.id=claims.attempt_id'))
            occupied = [item for item in active if json.loads(item['attempt_data']).get('execution_released') is not True]
            if len(occupied) >= claims['global_cap'] or sum(x['provider'] == job['provider'] for x in occupied) >= claims['provider_cap']:
                raise ValueError('capacity exhausted')
            for existing in active:
                if existing['card'] == job['card'] or (lane and existing['merge_lane']):
                    raise ValueError('claim conflict')
                for a in paths:
                    for b in json.loads(existing['paths']):
                        a_key, b_key = _scope_key(a), _scope_key(b)
                        if not a_key or not b_key or a_key == b_key or a_key.startswith(b_key + '/') or b_key.startswith(a_key + '/'):
                            raise ValueError('scope conflict')
            owner = self.scope_conflict(job['card'], paths)
            if owner is not None:
                raise ValueError('scope conflict with #' + owner)
            prior_reservation = self._reservations().get(job['card'])
            reservation_paths = sorted(set((prior_reservation or {}).get('paths', [])) | set(paths))
            if not enforceable:
                reservation_paths = ['']
            reservation = {'card': job['card'], 'paths': reservation_paths,
                           'enforceable': enforceable,
                           'reservation_revision': (prior_reservation or {}).get('revision', 0) + 1}
            logical = canonical_json([job[k] for k in ('card', 'action', 'role', 'stage', 'round', 'input_sha', 'input_version')])
            c.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?)', (job['id'], logical, job['card'], job['generation'], job['input_sha'], job['role'], job['stage'], 'active', 0, canonical_json(job)))
            c.execute('INSERT INTO attempts VALUES(?,?,?,?,?,?)', (job['nonce'], job['id'], job['nonce'], job['provider'], 'prepared', canonical_json(job)))
            if self.__fault_injector is not None:
                self.__fault_injector('after_attempt')
            c.execute('INSERT INTO claims VALUES(?,?,?,?,?,?)', (job['nonce'], job['card'], job['provider'], canonical_json(paths), lane, expected_revision + 1))
            self._event('attempt_prepared', {'job_id': job['id'], 'attempt_id': job['nonce'],
                                             'scope_reservation': reservation})
            c.execute('COMMIT')
            return {'job_id': job['id'], 'attempt_id': job['nonce']}
        except sqlite3.IntegrityError as exc:
            c.execute('ROLLBACK')
            raise ValueError('duplicate job or attempt') from exc
        except Exception:
            c.execute('ROLLBACK')
            raise

    def configure_domain(self, config, expected_revision):
        if not isinstance(config, dict) or set(config) != {'config_hash', 'service_version'} or any(not isinstance(x, str) or not x for x in config.values()):
            raise ValueError('invalid domain config')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            c.execute('UPDATE domain SET config_hash=?,service_version=?', (config['config_hash'], config['service_version']))
            self._event('config_updated', config)
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def update_attempt(self, attempt_id, details, expected_revision):
        allowed = {'state', 'boot_id', 'process_identity', 'worktree', 'started_at', 'deadline', 'heartbeat', 'progress', 'cancel_reason', 'suspected_stuck'}
        states = {'prepared', 'launching', 'running', 'result_ready', 'reconciled', 'cancel_requested', 'interrupted', 'failed', 'quarantined'}
        if not isinstance(details, dict) or not details or not set(details) <= allowed or ('state' in details and details['state'] not in states - {'cancel_requested', 'quarantined'}):
            raise ValueError('invalid attempt details')
        if 'suspected_stuck' in details and type(details['suspected_stuck']) is not bool:
            raise ValueError('invalid stuck observation')
        canonical_json(details)
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            row = c.execute('SELECT state,data FROM attempts WHERE id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            if row['state'] in ('cancel_requested', 'interrupted', 'failed', 'quarantined', 'reconciled'):
                raise ValueError('attempt is no longer mutable')
            data = json.loads(row['data'])
            for field in ('boot_id', 'process_identity'):
                if field in details and field in data and data[field] != details[field]:
                    raise ValueError('registered process identity is immutable')
            for field in ('started_at', 'deadline'):
                if field in details:
                    value = details[field]
                    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                        raise ValueError('invalid attempt time')
                    if field in data and data[field] != value:
                        raise ValueError('attempt time is immutable')
            combined = dict(data, **details)
            if 'started_at' in combined and 'deadline' in combined and combined['deadline'] < combined['started_at']:
                raise ValueError('deadline precedes start')
            data.update(details)
            c.execute('UPDATE attempts SET state=?,data=? WHERE id=?', (details.get('state', row['state']), canonical_json(data), attempt_id))
            self._event('attempt_updated', {'attempt_id': attempt_id, 'fields': sorted(details)})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def adopt_receipt_identity(self, attempt_id, expected_revision):
        """Bind a verified old-boot launch receipt without changing attempt authority."""
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            domain = c.execute('SELECT revision FROM domain').fetchone()
            row = c.execute('SELECT * FROM attempts WHERE id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            if type(expected_revision) is not int or domain['revision'] != expected_revision:
                raise ValueError('revision mismatch')
            if row['state'] not in ('prepared', 'launching', 'running', 'result_ready',
                                    'cancel_requested', 'quarantined'):
                raise ValueError('attempt cannot adopt a launch receipt')
            data = json.loads(row['data'])
            has_boot = 'boot_id' in data
            has_identity = 'process_identity' in data
            if has_boot != has_identity:
                raise ValueError('partial process identity')

            attempts = self.directory / 'attempts'
            path = attempts / attempt_id
            if attempts.is_symlink() or path.is_symlink() or not path.is_dir():
                raise ValueError('unsafe attempt evidence path')
            prepared = _read_private_json(path / 'prepared.json', 65536)
            receipt = _read_private_json(path / 'receipt.json', 8192)
            bindings = {'domain_id': self.domain_id, 'job_id': row['job_id'], 'attempt_id': attempt_id,
                        'nonce': row['nonce'], 'generation': data['generation'], 'input_sha': data['input_sha'],
                        'role': data['role'], 'stage': data['stage'], 'session_id': data['session_id']}
            if (not isinstance(prepared, dict) or any(prepared.get(key) != value for key, value in bindings.items())
                    or type(data.get('started_at')) not in (int, float) or not math.isfinite(data['started_at'])
                    or type(data.get('deadline')) not in (int, float) or not math.isfinite(data['deadline'])
                    or data['deadline'] < data['started_at']
                    or prepared.get('started_at') != data['started_at'] or prepared.get('deadline') != data['deadline']):
                raise ValueError('prepared launch binding mismatch')
            if not isinstance(receipt, dict) or set(receipt) != {'state', 'identity'} or receipt['state'] != 'registered':
                raise ValueError('invalid launch receipt')
            identity = receipt['identity']
            if (not isinstance(identity, dict) or set(identity) != {'boot_id', 'pid', 'started_at', 'nonce'}
                    or not isinstance(identity['boot_id'], str) or not identity['boot_id']
                    or type(identity['pid']) is not int or identity['pid'] <= 0
                    or not isinstance(identity['started_at'], str) or not identity['started_at']
                    or identity['nonce'] != row['nonce']):
                raise ValueError('invalid receipt identity')
            try:
                if identity['boot_id'] == _boot_id():
                    raise ValueError('receipt is not from a prior boot')
            except OSError as exc:
                raise ValueError('boot identity unavailable') from exc
            if has_boot:
                if data['boot_id'] != identity['boot_id'] or data['process_identity'] != identity:
                    raise ValueError('registered process identity is immutable')
            else:
                data.update({'boot_id': identity['boot_id'], 'process_identity': identity})
                c.execute('UPDATE attempts SET data=? WHERE id=?', (canonical_json(data), attempt_id))
                self._event('receipt_identity_adopted', {'attempt_id': attempt_id})
            c.execute('COMMIT')
            return identity
        except Exception:
            c.execute('ROLLBACK')
            raise

    def begin_recovered_launch(self, attempt_id, evidence, *, now, limits, expected_revision, timeout_seconds=7200):
        """Commit same-attempt launch intent after trusted proof and fresh admission checks."""
        if (type(evidence) is not NeverExecutedEvidence or self.__launch_evidence_verifier is None
                or self.__launch_evidence_verifier(evidence) is not True
                or type(now) not in (int, float) or not math.isfinite(now) or now < 0
                or not isinstance(limits, dict) or set(limits) != {'global_cap', 'provider_cap', 'max_cost_usd'}
                or any(type(limits[k]) is not int or limits[k] < 1 for k in ('global_cap', 'provider_cap'))
                or type(limits['max_cost_usd']) not in (int, float) or not math.isfinite(limits['max_cost_usd']) or limits['max_cost_usd'] <= 0):
            raise ValueError('untrusted launch evidence or limits')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            domain = c.execute('SELECT revision,desired_mode FROM domain').fetchone()
            row = c.execute('SELECT attempts.*,jobs.generation AS current_generation,jobs.state AS job_state FROM attempts JOIN jobs ON jobs.id=attempts.job_id WHERE attempts.id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            data = json.loads(row['data'])
            session = c.execute('SELECT * FROM sessions WHERE id=?', (data['session_id'],)).fetchone()
            claim = c.execute('SELECT 1 FROM claims WHERE attempt_id=?', (attempt_id,)).fetchone()
            active = list(c.execute('SELECT claims.provider,attempts.data FROM claims JOIN attempts ON attempts.id=claims.attempt_id'))
            occupied = [item for item in active if json.loads(item['data']).get('execution_released') is not True]
            if (type(expected_revision) is not int or domain['revision'] != expected_revision or domain['desired_mode'] != 'running'
                    or evidence.domain_id != self.domain_id or evidence.attempt_id != attempt_id or evidence.job_id != row['job_id']
                    or type(evidence.generation) is not int or evidence.generation != data['generation']
                    or row['current_generation'] != data['generation'] or row['state'] != 'prepared' or row['job_state'] != 'active'
                    or session is None or now >= session['deadline'] or session['unknown_spend'] or session['budget_stop']
                    or session['known_spend'] >= limits['max_cost_usd'] or claim is None
                    or len(occupied) > limits['global_cap'] or sum(item['provider'] == row['provider'] for item in occupied) > limits['provider_cap']
                    or c.execute('SELECT 1 FROM effects WHERE job_id=?', (row['job_id'],)).fetchone()
                    or c.execute('SELECT 1 FROM results WHERE attempt_id=?', (attempt_id,)).fetchone()):
                raise ValueError('recovered launch admission blocked')
            _capture_timing(data, now, timeout_seconds, session['deadline'])
            data['state'] = 'launching'
            c.execute("UPDATE attempts SET state='launching',data=? WHERE id=?", (canonical_json(data), attempt_id))
            self._event('recovered_launch_started', {'attempt_id': attempt_id})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def _verify_retry_evidence(self, evidence, job_id, attempt):
        if (type(evidence) is not RetryEvidence or self.__retry_evidence_verifier is None
                or self.__retry_evidence_verifier(evidence) is not True or evidence.domain_id != self.domain_id
                or evidence.job_id != job_id or evidence.attempt_id != attempt['id']
                or type(evidence.generation) is not int or evidence.generation != json.loads(attempt['data'])['generation']):
            raise ValueError('untrusted retry evidence')

    def schedule_retry(self, job_id, prior_attempt_id, eligibility, retry_at, expected_revision):
        if type(retry_at) not in (int, float) or not math.isfinite(retry_at) or retry_at < 0:
            raise ValueError('invalid retry deadline')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            job = c.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
            prior = c.execute('SELECT * FROM attempts WHERE id=? AND job_id=?', (prior_attempt_id, job_id)).fetchone()
            if job is None or prior is None:
                raise ValueError('unknown retry job')
            self._verify_retry_evidence(eligibility, job_id, prior)
            data = json.loads(job['data'])
            prior_data = json.loads(prior['data'])
            if job['state'] == 'retry_wait' and data.get('retry_prior') == prior_attempt_id and data.get('retry_at') == retry_at:
                result = {'attempt_id': data['retry_nonce'], 'retry_at': retry_at}
            else:
                if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                    raise ValueError('revision mismatch')
                if (job['state'] != 'active' or job['retries_used'] != 0 or prior_data.get('execution_released') is not True
                        or prior_data.get('cancel_reason') != 'infrastructure' or job['generation'] != prior_data['generation'] + 1
                        or c.execute('SELECT 1 FROM effects WHERE job_id=?', (job_id,)).fetchone()
                        or c.execute('SELECT 1 FROM results WHERE attempt_id=?', (prior_attempt_id,)).fetchone()
                        or c.execute('SELECT 1 FROM claims WHERE attempt_id=?', (prior_attempt_id,)).fetchone() is None):
                    raise ValueError('retry is not safely eligible')
                nonce = secrets.token_hex(24)
                data.update({'retry_prior': prior_attempt_id, 'retry_at': retry_at, 'retry_nonce': nonce})
                c.execute("UPDATE jobs SET state='retry_wait',retries_used=1,data=? WHERE id=?", (canonical_json(data), job_id))
                self._event('retry_scheduled', {'job_id': job_id, 'attempt_id': nonce, 'retry_at': retry_at})
                result = {'attempt_id': nonce, 'retry_at': retry_at}
            c.execute('COMMIT')
            return result
        except Exception:
            c.execute('ROLLBACK')
            raise

    def prepare_retry(self, job_id, eligibility, *, now, limits, expected_revision):
        if (type(now) not in (int, float) or not math.isfinite(now) or now < 0 or not isinstance(limits, dict)
                or set(limits) != {'global_cap', 'provider_cap', 'max_cost_usd'}
                or any(type(limits[k]) is not int or limits[k] < 1 for k in ('global_cap', 'provider_cap'))
                or type(limits['max_cost_usd']) not in (int, float) or not math.isfinite(limits['max_cost_usd']) or limits['max_cost_usd'] <= 0):
            raise ValueError('invalid retry limits')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            job = c.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
            if job is None:
                raise ValueError('unknown retry job')
            data = json.loads(job['data'])
            prior = c.execute('SELECT * FROM attempts WHERE id=? AND job_id=?', (data.get('retry_prior'), job_id)).fetchone()
            if prior is None:
                raise ValueError('missing prior attempt')
            self._verify_retry_evidence(eligibility, job_id, prior)
            nonce = data['retry_nonce']
            domain = c.execute('SELECT desired_mode FROM domain').fetchone()
            session = c.execute('SELECT * FROM sessions WHERE id=?', (data['session_id'],)).fetchone()
            if (domain['desired_mode'] != 'running' or session is None or now >= session['deadline']
                    or session['unknown_spend'] or session['budget_stop'] or session['known_spend'] >= limits['max_cost_usd']):
                raise ValueError('retry admission is blocked')
            revision = c.execute('SELECT revision FROM domain').fetchone()[0]
            if type(expected_revision) is not int or revision != expected_revision:
                raise ValueError('revision mismatch')
            existing = c.execute('SELECT * FROM attempts WHERE id=? AND job_id=?', (nonce, job_id)).fetchone()
            prior_data = json.loads(prior['data'])
            if (now < data['retry_at'] or job['generation'] != prior_data['generation'] + 1
                    or prior_data.get('execution_released') is not True
                    or c.execute('SELECT 1 FROM effects WHERE job_id=?', (job_id,)).fetchone()
                    or c.execute('SELECT 1 FROM results WHERE attempt_id=?', (prior['id'],)).fetchone()):
                raise ValueError('retry admission is blocked')
            claim_id = nonce if existing else prior['id']
            claim = c.execute('SELECT * FROM claims WHERE attempt_id=?', (claim_id,)).fetchone()
            if claim is None:
                raise ValueError('missing reservation')
            active = list(c.execute('SELECT claims.attempt_id,claims.provider,attempts.data FROM claims JOIN attempts ON attempts.id=claims.attempt_id'))
            occupied = [item for item in active if item['attempt_id'] != nonce and json.loads(item['data']).get('execution_released') is not True]
            if len(occupied) >= limits['global_cap'] or sum(item['provider'] == prior['provider'] for item in occupied) >= limits['provider_cap']:
                raise ValueError('capacity exhausted')
            if existing:
                if (job['state'] != 'active' or existing['state'] != 'prepared'
                        or json.loads(existing['data']).get('generation') != job['generation']):
                    raise ValueError('retry is no longer prepared')
                result = {'attempt_id': nonce}
            else:
                if job['state'] != 'retry_wait':
                    raise ValueError('retry is not waiting')
                fresh = {key: value for key, value in data.items() if key not in ('retry_prior', 'retry_at', 'retry_nonce')}
                fresh.update({'nonce': nonce, 'generation': job['generation']})
                if 'worktree' in prior_data:
                    fresh['worktree'] = prior_data['worktree']
                c.execute('INSERT INTO attempts VALUES(?,?,?,?,?,?)', (nonce, job_id, nonce, prior['provider'], 'prepared', canonical_json(fresh)))
                c.execute('UPDATE claims SET attempt_id=?,reservation_revision=? WHERE attempt_id=?', (nonce, revision + 1, prior['id']))
                c.execute("UPDATE jobs SET state='active' WHERE id=?", (job_id,))
                self._event('retry_prepared', {'job_id': job_id, 'attempt_id': nonce})
                result = {'attempt_id': nonce}
            c.execute('COMMIT')
            return result
        except Exception:
            c.execute('ROLLBACK')
            raise

    def begin_retry_launch(self, job_id, eligibility, *, now, limits, expected_revision, timeout_seconds=7200):
        """Recheck current retry admission and commit launch intent atomically."""
        if (type(now) not in (int, float) or not math.isfinite(now) or now < 0 or not isinstance(limits, dict)
                or set(limits) != {'global_cap', 'provider_cap', 'max_cost_usd'}
                or any(type(limits[k]) is not int or limits[k] < 1 for k in ('global_cap', 'provider_cap'))
                or type(limits['max_cost_usd']) not in (int, float) or not math.isfinite(limits['max_cost_usd']) or limits['max_cost_usd'] <= 0):
            raise ValueError('invalid retry limits')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            domain = c.execute('SELECT * FROM domain').fetchone()
            job = c.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
            if job is None:
                raise ValueError('unknown retry job')
            data = json.loads(job['data'])
            prior = c.execute('SELECT * FROM attempts WHERE id=? AND job_id=?', (data.get('retry_prior'), job_id)).fetchone()
            current = c.execute('SELECT * FROM attempts WHERE id=? AND job_id=?', (data.get('retry_nonce'), job_id)).fetchone()
            if prior is None or current is None:
                raise ValueError('missing retry attempt')
            self._verify_retry_evidence(eligibility, job_id, prior)
            prior_data, current_data = json.loads(prior['data']), json.loads(current['data'])
            session = c.execute('SELECT * FROM sessions WHERE id=?', (data['session_id'],)).fetchone()
            claim = c.execute('SELECT 1 FROM claims WHERE attempt_id=?', (current['id'],)).fetchone()
            active = list(c.execute('SELECT claims.provider,attempts.data FROM claims JOIN attempts ON attempts.id=claims.attempt_id'))
            occupied = [item for item in active if json.loads(item['data']).get('execution_released') is not True]
            if (type(expected_revision) is not int or domain['revision'] != expected_revision or domain['desired_mode'] != 'running'
                    or now < data['retry_at'] or job['state'] != 'active' or current['state'] != 'prepared'
                    or job['generation'] != prior_data['generation'] + 1 or current_data['generation'] != job['generation']
                    or prior_data.get('execution_released') is not True or claim is None
                    or session is None or now >= session['deadline'] or session['unknown_spend'] or session['budget_stop']
                    or session['known_spend'] >= limits['max_cost_usd'] or len(occupied) > limits['global_cap']
                    or sum(item['provider'] == current['provider'] for item in occupied) > limits['provider_cap']
                    or c.execute('SELECT 1 FROM effects WHERE job_id=?', (job_id,)).fetchone()
                    or c.execute('SELECT 1 FROM results WHERE attempt_id=?', (prior['id'],)).fetchone()):
                raise ValueError('retry launch admission blocked')
            _capture_timing(current_data, now, timeout_seconds, session['deadline'])
            current_data['state'] = 'launching'
            c.execute("UPDATE attempts SET state='launching',data=? WHERE id=?", (canonical_json(current_data), current['id']))
            self._event('retry_launch_started', {'attempt_id': current['id']})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def record_execution_stopped(self, attempt_id, evidence, expected_revision):
        """Record only a trusted, exactly bound complete-tree observation."""
        if type(evidence) is not StopEvidence:
            raise ValueError('untrusted stop evidence')
        if evidence.kind == 'fixture_complete_tree':
            if self.__stop_evidence_verifier is None or self.__stop_evidence_verifier(evidence) is not True:
                raise ValueError('untrusted stop evidence')
        elif evidence.kind == 'boot_changed':
            try:
                if (evidence.free_fixture or not evidence.current_boot_id or evidence.current_boot_id == evidence.boot_id
                        or _boot_id() != evidence.current_boot_id):
                    raise ValueError('untrusted boot evidence')
            except OSError as exc:
                raise ValueError('boot identity unavailable') from exc
        else:
            raise ValueError('untrusted stop evidence')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            row = c.execute('SELECT * FROM attempts WHERE id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            data = json.loads(row['data'])
            identity = data.get('process_identity')
            expected = {'boot_id': evidence.boot_id, 'pid': evidence.pid, 'started_at': evidence.started_at, 'nonce': evidence.nonce}
            if (evidence.domain_id != self.domain_id or evidence.job_id != row['job_id'] or evidence.attempt_id != row['id']
                    or type(evidence.generation) is not int or evidence.generation != data['generation']
                    or type(evidence.pid) is not int or evidence.pid <= 0 or not evidence.boot_id or not evidence.started_at
                    or evidence.nonce != row['nonce'] or data.get('boot_id') != evidence.boot_id or identity != expected
                    or row['state'] not in ('cancel_requested', 'quarantined', 'interrupted', 'result_ready')):
                raise ValueError('stop evidence identity mismatch')
            if row['state'] == 'result_ready':
                result = c.execute('SELECT disposition FROM results WHERE attempt_id=?', (attempt_id,)).fetchone()
                generation = c.execute('SELECT generation FROM jobs WHERE id=?', (row['job_id'],)).fetchone()[0]
                if result is None or result['disposition'] != 'current' or generation != evidence.generation:
                    raise ValueError('result is no longer current')
            encoded = dict(evidence.__dict__)
            if data.get('execution_released') is True:
                if data.get('stop_evidence') != encoded:
                    raise ValueError('conflicting stop evidence')
            else:
                if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                    raise ValueError('revision mismatch')
                if type(evidence.free_fixture) is not bool:
                    raise ValueError('invalid usage evidence')
                if not evidence.free_fixture and c.execute('SELECT 1 FROM results WHERE attempt_id=?', (attempt_id,)).fetchone() is None:
                    if c.execute('UPDATE sessions SET unknown_spend=1 WHERE id=?', (data.get('session_id'),)).rowcount != 1:
                        raise ValueError('unknown session')
                data.update({'execution_released': True, 'stop_evidence': encoded})
                c.execute('UPDATE attempts SET data=? WHERE id=?', (canonical_json(data), attempt_id))
                if row['state'] == 'cancel_requested' and data.get('cancel_reason') != 'infrastructure':
                    state = 'cancelled' if data.get('cancel_reason') == 'stop' else 'needs_attention'
                    c.execute("UPDATE jobs SET state=? WHERE id=? AND generation=? AND state='active'",
                              (state, row['job_id'], data['generation'] + 1))
                self._event('execution_stopped', {'attempt_id': attempt_id})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def quarantine_attempt(self, attempt_id, reason, expected_revision):
        """Fence uncertain work while retaining its execution and scope claim."""
        if any(not isinstance(x, str) or not x for x in (attempt_id, reason)):
            raise ValueError('invalid quarantine')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            row = c.execute('SELECT attempts.*, jobs.generation AS current_generation FROM attempts JOIN jobs ON jobs.id=attempts.job_id WHERE attempts.id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            data = json.loads(row['data'])
            if row['state'] == 'quarantined':
                if data.get('quarantine_reason') != reason:
                    raise ValueError('conflicting quarantine')
            else:
                if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                    raise ValueError('revision mismatch')
                if row['state'] in ('reconciled', 'failed', 'interrupted'):
                    raise ValueError('attempt cannot be quarantined')
                if row['current_generation'] == data['generation']:
                    c.execute('UPDATE jobs SET generation=generation+1 WHERE id=?', (row['job_id'],))
                data.update({'state': 'quarantined', 'quarantine_reason': reason})
                c.execute("UPDATE attempts SET state='quarantined',data=? WHERE id=?", (canonical_json(data), attempt_id))
                c.execute("UPDATE jobs SET state='needs_attention' WHERE id=?", (row['job_id'],))
                self._event('attempt_quarantined', {'attempt_id': attempt_id, 'reason': reason})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def request_cancellation(self, attempt_id, request_id, reason, expected_revision, *, now=None, grace_seconds=30):
        """Persist cancellation and revoke authority in one transaction before signaling."""
        if any(not isinstance(x, str) or not x for x in (attempt_id, request_id, reason)):
            raise ValueError('invalid cancellation')
        if (now is not None and (type(now) not in (int, float) or not math.isfinite(now) or now < 0)) or type(grace_seconds) not in (int, float) or not math.isfinite(grace_seconds) or grace_seconds <= 0:
            raise ValueError('invalid cancellation deadline')
        request = canonical_json({'type': 'cancel_attempt', 'attempt_id': attempt_id,
                                  'id': request_id, 'reason': reason, 'expected_revision': expected_revision,
                                  'now': now, 'grace_seconds': grace_seconds})
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            prior = c.execute('SELECT request,outcome FROM commands WHERE id=?', (request_id,)).fetchone()
            if prior:
                if prior['request'] != request:
                    raise ValueError('command ID already used')
                result = json.loads(prior['outcome'])
            else:
                revision = c.execute('SELECT revision FROM domain').fetchone()[0]
                if type(expected_revision) is not int or expected_revision != revision:
                    raise ValueError('revision mismatch')
                row = c.execute('SELECT * FROM attempts WHERE id=?', (attempt_id,)).fetchone()
                if row is None or row['state'] in ('cancel_requested', 'interrupted', 'failed', 'quarantined', 'reconciled'):
                    raise ValueError('attempt cannot be cancelled')
                data = json.loads(row['data'])
                requested_at = time.time() if now is None else now
                data.update({'state': 'cancel_requested', 'cancel_reason': reason,
                             'cancel_requested_at': requested_at, 'cancel_grace_deadline': requested_at + grace_seconds})
                c.execute("UPDATE attempts SET state='cancel_requested',data=? WHERE id=?", (canonical_json(data), attempt_id))
                c.execute('UPDATE jobs SET generation=generation+1 WHERE id=? AND generation=?', (row['job_id'], data['generation']))
                result = {'attempt_id': attempt_id, 'revision': revision + 1}
                c.execute('INSERT INTO commands VALUES(?,?,?)', (request_id, request, canonical_json(result)))
                self._event('cancellation_requested', {'attempt_id': attempt_id, 'reason': reason})
            c.execute('COMMIT')
            return result
        except Exception:
            c.execute('ROLLBACK')
            raise

    def revoke_generation(self, job_id, expected_revision):
        """Fence old attempts without releasing claims or changing retry accounting."""
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            if c.execute('UPDATE jobs SET generation=generation+1 WHERE id=?', (job_id,)).rowcount != 1:
                raise ValueError('unknown job')
            self._event('generation_revoked', {'job_id': job_id})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def increment_retry(self, job_id, expected_revision):
        """Consume the single automatic retry; classification belongs to the caller."""
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            changed = c.execute('UPDATE jobs SET retries_used=retries_used+1 WHERE id=? AND retries_used=0', (job_id,)).rowcount
            if changed != 1:
                raise ValueError('unknown job or retry exhausted')
            self._event('retry_consumed', {'job_id': job_id})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def record_effect(self, effect):
        """Record intent only; external execution and reconciliation are separate."""
        required = {'operation_key', 'job_id', 'generation', 'preconditions', 'intent'}
        if not isinstance(effect, dict) or set(effect) != required or any(not isinstance(effect[k], str) or not effect[k] for k in ('operation_key', 'job_id')) or type(effect['generation']) is not int or not isinstance(effect['preconditions'], dict) or not isinstance(effect['intent'], dict):
            raise ValueError('invalid effect')
        preconditions = canonical_json(effect['preconditions'])
        intent = canonical_json(effect['intent'])
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            job = c.execute('SELECT generation,card FROM jobs WHERE id=?', (effect['job_id'],)).fetchone()
            publication = effect['intent'].get('kind') in ('publish', 'publication', 'commit_publication', 'pr_update', 'merge')
            if job is not None and publication and self._publication_held(job['card']):
                raise ValueError('publication held after unauthorized scope change')
            if job is None or job['generation'] != effect['generation']:
                raise ValueError('unknown or stale effect job')
            row = c.execute('SELECT * FROM effects WHERE operation_key=?', (effect['operation_key'],)).fetchone()
            if row:
                if (row['job_id'], row['generation'], row['preconditions'], row['intent']) != (effect['job_id'], effect['generation'], preconditions, intent):
                    raise ValueError('conflicting effect')
            else:
                c.execute('INSERT INTO effects VALUES(?,?,?,?,?,?,NULL,?)', (effect['operation_key'], effect['job_id'], job['card'], effect['generation'], preconditions, intent, 'intent'))
                self._event('effect_intent', {'operation_key': effect['operation_key']})
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def observe_effect(self, operation_key, observation, expected_revision):
        if not isinstance(observation, dict):
            raise ValueError('invalid effect observation')
        encoded = canonical_json(observation)
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            row = c.execute('SELECT observation,card,intent,job_id,generation FROM effects WHERE operation_key=?', (operation_key,)).fetchone()
            if row is None:
                raise ValueError('unknown effect')
            intent = json.loads(row['intent'])
            if intent.get('kind') in ('publish', 'publication', 'commit_publication', 'pr_update', 'merge') and self._publication_held(row['card']):
                raise ValueError('publication held after unauthorized scope change')
            if row['observation'] is not None:
                if row['observation'] != encoded:
                    raise ValueError('conflicting effect observation')
            else:
                if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                    raise ValueError('revision mismatch')
                event = {'operation_key': operation_key}
                if intent.get('kind') == 'branch_refresh':
                    job = c.execute('SELECT * FROM jobs WHERE id=?', (row['job_id'],)).fetchone()
                    evidence = observation.get('input_evidence')
                    revision = observation.get('input_revision')
                    invalidated = observation.get('invalidated_evidence')
                    required_evidence = {'job_id', 'generation', 'head_sha', 'input_sha', 'changed_paths'}
                    if (job is None or job['card'] != row['card'] or job['generation'] != row['generation']
                            or not isinstance(evidence, dict) or set(evidence) != required_evidence):
                        raise ValueError('stale or invalid branch refresh evidence')
                    if (evidence['job_id'] != row['job_id'] or evidence['generation'] != row['generation']
                            or not isinstance(evidence['head_sha'], str)
                            or not re.fullmatch(r'[0-9a-f]{40}(?:[0-9a-f]{24})?', evidence['head_sha'])
                            or not isinstance(evidence['input_sha'], str)
                            or not re.fullmatch(r'[0-9a-f]{64}', evidence['input_sha'])):
                        raise ValueError('invalid branch refresh evidence identity')
                    paths = evidence['changed_paths']
                    if (not isinstance(paths, list) or any(not isinstance(path, str) or not path
                            or path.startswith('/') or any(part in ('', '.', '..') for part in path.split('/'))
                            or any(ord(char) < 32 or ord(char) == 127 for char in path) for path in paths)
                            or paths != sorted(set(paths))
                            or paths != sorted(set(intent.get('changed_paths', [])))):
                        raise ValueError('invalid branch refresh changed paths')
                    expected_input_revision = hashlib.sha256(canonical_json(evidence).encode('utf-8')).hexdigest()
                    if not isinstance(revision, str) or revision != expected_input_revision:
                        raise ValueError('branch refresh input revision mismatch')
                    if not isinstance(invalidated, list) or any(item not in ('review', 'test') for item in invalidated) or len(invalidated) != len(set(invalidated)):
                        raise ValueError('invalid branch refresh evidence invalidation')
                    data = json.loads(job['data'])
                    if paths and revision == data.get('input_version'):
                        raise ValueError('branch refresh did not create a new input revision')
                    updated_data = dict(data)
                    updated_data.update({'input_sha': evidence['input_sha'],
                                         'input_version': revision,
                                         'input_revision': revision,
                                         'evidence_invalidated': {'input_revision': revision,
                                                                  'items': sorted(invalidated)}})
                    history = updated_data.get('evidence_invalidations', [])
                    if not isinstance(history, list):
                        raise ValueError('invalid stored evidence invalidations')
                    history = history + [{'input_revision': revision, 'items': sorted(invalidated)}]
                    updated_data['evidence_invalidations'] = history
                    round_number = updated_data.get('round')
                    if type(round_number) is not int or round_number < 0:
                        raise ValueError('invalid job round for refreshed identity')
                    logical_key = canonical_json([job['card'], updated_data['action'], job['role'],
                                                  job['stage'], round_number, evidence['input_sha'], revision])
                    collision = c.execute('SELECT 1 FROM jobs WHERE logical_key=? AND id<>?',
                                          (logical_key, row['job_id'])).fetchone()
                    if collision is not None:
                        raise ValueError('refreshed job identity already exists')
                    next_generation = row['generation'] + 1
                    changed = c.execute('UPDATE jobs SET logical_key=?,generation=?,input_sha=?,data=? WHERE id=? AND generation=?',
                                        (logical_key, next_generation, evidence['input_sha'],
                                         canonical_json(updated_data), row['job_id'], row['generation'])).rowcount
                    if changed != 1:
                        raise ValueError('branch refresh job changed before observation')
                    event.update({'job_id': row['job_id'], 'generation': next_generation,
                                  'input_revision': revision,
                                  'invalidated_evidence': sorted(invalidated)})
                c.execute("UPDATE effects SET observation=?,status='observed' WHERE operation_key=?", (encoded, operation_key))
                self._event('effect_observed', event)
            c.execute('COMMIT')
        except Exception:
            c.execute('ROLLBACK')
            raise

    def record_result(self, envelope):
        """Persist a trusted runner's prevalidated report and charge its original session.

        Semantic report parsing and ingestion are runner responsibilities. This layer
        verifies artifact containment and hashes and binds the envelope to the attempt.
        """
        if not isinstance(envelope, dict):
            raise ValueError('invalid result')
        required = ('schema_version', 'domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage', 'outcome', 'report_path', 'artifact_hashes', 'usage', 'exit_code')
        if set(envelope) != set(required) or type(envelope['schema_version']) is not int or envelope['schema_version'] != 1:
            raise ValueError('invalid result schema')
        if envelope['domain_id'] != self.domain_id or type(envelope['generation']) is not int or type(envelope['exit_code']) is not int:
            raise ValueError('invalid result identity')
        if envelope['outcome'] not in ('success', 'failure', 'cancelled'):
            raise ValueError('invalid outcome')
        usage = envelope['usage']
        if usage is not None:
            if not isinstance(usage, dict) or set(usage) != {'cost_usd'}:
                raise ValueError('invalid usage')
            cost = usage['cost_usd']
            if type(cost) not in (int, float) or not math.isfinite(cost) or cost < 0:
                raise ValueError('invalid usage')
        hashes = envelope['artifact_hashes']
        if not isinstance(hashes, dict) or envelope['report_path'] not in hashes or not hashes:
            raise ValueError('missing report hash')
        attempt_id = envelope['attempt_id']
        if not isinstance(attempt_id, str) or not attempt_id or '/' in attempt_id or attempt_id in ('.', '..'):
            raise ValueError('invalid attempt id')
        root = self.directory / 'artifacts' / attempt_id
        if len(hashes) > 128 or root.is_symlink() or not root.exists() or root.resolve(strict=True) != root:
            raise ValueError('unsafe artifact root')
        total_bytes = 0
        for name, digest in hashes.items():
            if not isinstance(name, str) or not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
                raise ValueError('invalid artifact hash')
            path = Path(name)
            if not path.is_absolute() or '..' in path.parts or path.is_symlink():
                raise ValueError('invalid artifact path')
            try:
                resolved = path.resolve(strict=True)
                resolved.relative_to(root.resolve(strict=True))
                if resolved != path or not resolved.is_file() or resolved.stat().st_size > 1048576:
                    raise ValueError('invalid artifact path')
                total_bytes += resolved.stat().st_size
                if total_bytes > 16 * 1048576:
                    raise ValueError('artifact set too large')
                if hashlib.sha256(resolved.read_bytes()).hexdigest() != digest:
                    raise ValueError('artifact hash mismatch')
            except (OSError, RuntimeError) as exc:
                raise ValueError('invalid artifact') from exc
        encoded = canonical_json(envelope)
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            attempt = c.execute('SELECT attempts.*, jobs.generation AS current_generation, jobs.input_sha, jobs.role, jobs.stage FROM attempts JOIN jobs ON jobs.id=attempts.job_id WHERE attempts.id=?', (attempt_id,)).fetchone()
            if attempt is None or attempt['job_id'] != envelope['job_id']:
                raise ValueError('unknown attempt')
            original = json.loads(attempt['data'])
            for field in ('generation', 'input_sha', 'role', 'stage'):
                if original[field] != envelope[field]:
                    raise ValueError('result identity mismatch')
            prior = c.execute('SELECT * FROM results WHERE attempt_id=?', (attempt_id,)).fetchone()
            if prior:
                if prior['envelope'] != encoded:
                    raise ValueError('conflicting result replay')
                result = {'disposition': prior['disposition']}
            else:
                session = original.get('session_id')
                if not isinstance(session, str) or c.execute('SELECT 1 FROM sessions WHERE id=?', (session,)).fetchone() is None:
                    raise ValueError('unknown session')
                disposition = 'current' if attempt['current_generation'] == envelope['generation'] and attempt['state'] not in ('cancel_requested', 'interrupted', 'failed', 'quarantined', 'reconciled') else 'stale'
                semantic_failure = disposition == 'current' and envelope['outcome'] != 'success'
                if semantic_failure:
                    disposition = 'stale'
                    c.execute("UPDATE jobs SET state='needs_attention',generation=generation+1 WHERE id=?", (attempt['job_id'],))
                    c.execute("UPDATE attempts SET state='failed' WHERE id=?", (attempt_id,))
                c.execute('INSERT INTO results VALUES(?,?,?)', (attempt_id, encoded, disposition))
                if usage is None:
                    c.execute('UPDATE sessions SET unknown_spend=1 WHERE id=?', (session,))
                else:
                    current_spend = c.execute('SELECT known_spend FROM sessions WHERE id=?', (session,)).fetchone()[0]
                    if not math.isfinite(current_spend + usage['cost_usd']):
                        raise ValueError('usage total overflow')
                    c.execute('UPDATE sessions SET known_spend=known_spend+? WHERE id=?', (usage['cost_usd'], session))
                if disposition == 'current' and attempt['state'] in ('prepared', 'launching', 'running', 'result_ready'):
                    c.execute("UPDATE attempts SET state='result_ready' WHERE id=?", (attempt_id,))
                self._event('result_recorded', {'attempt_id': attempt_id, 'disposition': disposition})
                result = {'disposition': disposition}
            c.execute('COMMIT')
            return result
        except Exception:
            c.execute('ROLLBACK')
            raise

    def backup(self, destination):
        destination = Path(destination)
        if not destination.is_absolute() or destination.is_symlink() or destination.exists():
            raise ValueError('backup destination must be a new absolute file')
        parent = _private_directory(destination.parent)
        if self.directory == parent and destination.name.startswith('store.sqlite3'):
            raise ValueError('backup aliases source')
        fd = os.open(str(destination), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        target = None
        try:
            target = sqlite3.connect(str(destination))
            self.__connection.backup(target)
            target.close()
        except Exception:
            if target is not None:
                target.close()
            destination.unlink()
            raise

    def record_command(self, request):
        encoded = canonical_json(request)
        if not all(isinstance(request.get(k), str) and request[k] for k in ('id', 'actor', 'command')) or not isinstance(request.get('payload'), dict):
            raise ValueError('invalid command')
        connection = self.__connection
        connection.execute('BEGIN IMMEDIATE')
        try:
            row = connection.execute('SELECT request,outcome FROM commands WHERE id=?', (request['id'],)).fetchone()
            if row:
                if row['request'] != encoded:
                    raise ValueError('command ID already used')
                result = json.loads(row['outcome'])
            else:
                revision = connection.execute('SELECT revision FROM domain').fetchone()[0]
                if type(request.get('expected_revision')) is not int or request['expected_revision'] != revision:
                    raise ValueError('revision mismatch')
                modes = {'start': 'running', 'resume': 'running', 'pause': 'paused', 'stop': 'stopped'}
                if request['command'] not in modes:
                    raise ValueError('unsupported command')
                mode = modes[request['command']]
                connection.execute('UPDATE domain SET desired_mode=?', (mode,))
                result = {'desired_mode': mode, 'revision': revision + 1}
                connection.execute('INSERT INTO commands VALUES(?,?,?)', (request['id'], encoded, canonical_json(result)))
                self._event('command', {'id': request['id'], 'actor': request['actor'], 'command': request['command']})
            connection.execute('COMMIT')
            return result
        except Exception:
            connection.execute('ROLLBACK')
            raise

    def append_event(self, event):
        if not isinstance(event, dict) or not isinstance(event.get('type'), str) or not event['type']:
            raise ValueError('invalid event')
        connection = self.__connection
        connection.execute('BEGIN IMMEDIATE')
        try:
            self._event(event['type'], event.get('payload', {}))
            connection.execute('COMMIT')
        except Exception:
            connection.execute('ROLLBACK')
            raise

    def snapshot(self):
        connection = self.__connection
        connection.execute('BEGIN')
        try:
            domain = dict(connection.execute('SELECT * FROM domain').fetchone())
            domain['identity'] = json.loads(domain['identity'])
            events = [dict(row) for row in connection.execute('SELECT * FROM events ORDER BY sequence')]
            for event in events:
                event['payload'] = json.loads(event['payload'])
            commands = [dict(row) for row in connection.execute('SELECT * FROM commands ORDER BY rowid')]
            records = {table: [dict(row) for row in connection.execute('SELECT * FROM ' + table + ' ORDER BY rowid')] for table in ('sessions', 'jobs', 'attempts', 'claims', 'results', 'effects')}
            for job in records['jobs']:
                data = json.loads(job['data'])
                for key in ('input_version', 'input_revision', 'evidence_invalidated', 'evidence_invalidations'):
                    if key in data:
                        job[key] = data[key]
            attention = [{'type': 'scope_cycle', 'cards': cycle} for cycle in self._scope_wait_cycles()]
            reservations = sorted(self._reservations().values(), key=lambda item: item['card'])
            card_lifecycle = self._card_lifecycles()
            attention_cards = sorted(card for card, state in card_lifecycle.items() if state in ('refresh_pending', 'needs_attention'))
            connection.execute('COMMIT')
            return {'domain': domain, 'events': events, 'commands': commands, 'attention': attention,
                    'reservations': reservations, 'card_lifecycle': card_lifecycle,
                    'attention_cards': attention_cards, **records}
        except Exception:
            connection.execute('ROLLBACK')
            raise
