"""Private, transactional state for one supervisor domain.

All mutations go through this interface. A caller cannot acquire the connection.
"""
import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import subprocess
import sys
import time
from pathlib import Path

from .models import canonical_json

SCHEMA_VERSION = 1


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


def _private_directory(path):
    path = Path(path).absolute()
    # Refuse symlinks at every existing component, including ancestors.
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError('symlink in runtime path')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('runtime directory must be private and owned by user')
    return path


class Store:
    @classmethod
    def open(cls, domain, filesystem_inspector=None):
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
                schema = '''
                    CREATE TABLE domain (id TEXT PRIMARY KEY, identity TEXT NOT NULL, desired_mode TEXT NOT NULL, phase TEXT NOT NULL, revision INTEGER NOT NULL, config_hash TEXT, service_version TEXT);
                    CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL, deadline REAL NOT NULL, known_spend REAL NOT NULL, unknown_spend INTEGER NOT NULL, budget_stop TEXT);
                    CREATE TABLE jobs (id TEXT PRIMARY KEY, logical_key TEXT UNIQUE NOT NULL, card TEXT NOT NULL, generation INTEGER NOT NULL, input_sha TEXT NOT NULL, role TEXT NOT NULL, stage TEXT NOT NULL, state TEXT NOT NULL, retries_used INTEGER NOT NULL, data TEXT NOT NULL);
                    CREATE TABLE attempts (id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), nonce TEXT UNIQUE NOT NULL, provider TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL);
                    CREATE TABLE claims (attempt_id TEXT PRIMARY KEY REFERENCES attempts(id), card TEXT NOT NULL, provider TEXT NOT NULL, paths TEXT NOT NULL, merge_lane INTEGER NOT NULL, reservation_revision INTEGER NOT NULL);
                    CREATE TABLE effects (operation_key TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), generation INTEGER NOT NULL, preconditions TEXT NOT NULL, intent TEXT NOT NULL, observation TEXT, status TEXT NOT NULL);
                    CREATE TABLE results (attempt_id TEXT PRIMARY KEY REFERENCES attempts(id), envelope TEXT NOT NULL, disposition TEXT NOT NULL);
                    CREATE TABLE commands (id TEXT PRIMARY KEY, request TEXT NOT NULL, outcome TEXT NOT NULL);
                    CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL);
                    PRAGMA user_version=1;'''
                for statement in schema.split(';'):
                    if statement.strip():
                        conn.execute(statement)
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
        return cls(conn, directory, domain_id)

    def __init__(self, connection, directory, domain_id):
        self.__connection = connection
        self.directory = directory
        self.domain_id = domain_id

    def close(self):
        self.__connection.close()

    def _event(self, kind, payload):
        self.__connection.execute('INSERT INTO events(timestamp,type,payload) VALUES(?,?,?)', (time.time(), kind, canonical_json(payload)))
        self.__connection.execute('UPDATE domain SET revision=revision+1')

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
        paths = sorted(set(paths)) or ['']
        lane = claims.get('merge_lane', False)
        if type(lane) is not bool:
            raise ValueError('invalid merge claim')
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            if c.execute('SELECT 1 FROM sessions WHERE id=?', (job['session_id'],)).fetchone() is None:
                raise ValueError('unknown session')
            active = list(c.execute('SELECT * FROM claims'))
            if len(active) >= claims['global_cap'] or sum(x['provider'] == job['provider'] for x in active) >= claims['provider_cap']:
                raise ValueError('capacity exhausted')
            for existing in active:
                if existing['card'] == job['card'] or (lane and existing['merge_lane']):
                    raise ValueError('claim conflict')
                for a in paths:
                    for b in json.loads(existing['paths']):
                        if not a or not b or a == b or a.startswith(b + '/') or b.startswith(a + '/'):
                            raise ValueError('scope conflict')
            logical = canonical_json([job[k] for k in ('card', 'action', 'role', 'stage', 'round', 'input_sha', 'input_version')])
            c.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?,?,?)', (job['id'], logical, job['card'], job['generation'], job['input_sha'], job['role'], job['stage'], 'active', 0, canonical_json(job)))
            c.execute('INSERT INTO attempts VALUES(?,?,?,?,?,?)', (job['nonce'], job['id'], job['nonce'], job['provider'], 'prepared', canonical_json(job)))
            c.execute('INSERT INTO claims VALUES(?,?,?,?,?,?)', (job['nonce'], job['card'], job['provider'], canonical_json(paths), lane, expected_revision + 1))
            self._event('attempt_prepared', {'job_id': job['id'], 'attempt_id': job['nonce']})
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
        allowed = {'state', 'boot_id', 'process_identity', 'worktree', 'started_at', 'deadline', 'heartbeat', 'progress', 'cancel_reason'}
        states = {'prepared', 'launching', 'running', 'result_ready', 'reconciled', 'cancel_requested', 'interrupted', 'failed', 'quarantined'}
        if not isinstance(details, dict) or not details or not set(details) <= allowed or ('state' in details and details['state'] not in states):
            raise ValueError('invalid attempt details')
        canonical_json(details)
        c = self.__connection
        c.execute('BEGIN IMMEDIATE')
        try:
            if type(expected_revision) is not int or c.execute('SELECT revision FROM domain').fetchone()[0] != expected_revision:
                raise ValueError('revision mismatch')
            row = c.execute('SELECT state,data FROM attempts WHERE id=?', (attempt_id,)).fetchone()
            if row is None:
                raise ValueError('unknown attempt')
            data = json.loads(row['data'])
            data.update(details)
            c.execute('UPDATE attempts SET state=?,data=? WHERE id=?', (details.get('state', row['state']), canonical_json(data), attempt_id))
            self._event('attempt_updated', {'attempt_id': attempt_id, 'fields': sorted(details)})
            c.execute('COMMIT')
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
            job = c.execute('SELECT generation FROM jobs WHERE id=?', (effect['job_id'],)).fetchone()
            if job is None or job['generation'] != effect['generation']:
                raise ValueError('unknown or stale effect job')
            row = c.execute('SELECT * FROM effects WHERE operation_key=?', (effect['operation_key'],)).fetchone()
            if row:
                if (row['job_id'], row['generation'], row['preconditions'], row['intent']) != (effect['job_id'], effect['generation'], preconditions, intent):
                    raise ValueError('conflicting effect')
            else:
                c.execute('INSERT INTO effects VALUES(?,?,?,?,?,NULL,?)', (effect['operation_key'], effect['job_id'], effect['generation'], preconditions, intent, 'intent'))
                self._event('effect_intent', {'operation_key': effect['operation_key']})
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
                disposition = 'current' if attempt['current_generation'] == envelope['generation'] else 'stale'
                c.execute('INSERT INTO results VALUES(?,?,?)', (attempt_id, encoded, disposition))
                if usage is None:
                    c.execute('UPDATE sessions SET unknown_spend=1 WHERE id=?', (session,))
                else:
                    current_spend = c.execute('SELECT known_spend FROM sessions WHERE id=?', (session,)).fetchone()[0]
                    if not math.isfinite(current_spend + usage['cost_usd']):
                        raise ValueError('usage total overflow')
                    c.execute('UPDATE sessions SET known_spend=known_spend+? WHERE id=?', (usage['cost_usd'], session))
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
            connection.execute('COMMIT')
            return {'domain': domain, 'events': events, 'commands': commands, **records}
        except Exception:
            connection.execute('ROLLBACK')
            raise
