"""Private, transactional state for one supervisor domain.

All mutations go through this interface. A caller cannot acquire the connection.
"""
import hashlib
import json
import os
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
            kind = subprocess.check_output(['/usr/bin/stat', '-f', '%T', str(path)], text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            return 'unknown'
        return 'local' if kind in ('apfs', 'hfs', 'ufs') else 'unknown'
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
            version = conn.execute('PRAGMA user_version').fetchone()[0]
            if version not in (0, SCHEMA_VERSION):
                raise ValueError('unsupported supervisor schema')
            if version == 0:
                if conn.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]:
                    raise ValueError('unversioned supervisor database is not empty')
                conn.executescript('''BEGIN IMMEDIATE;
                    CREATE TABLE domain (id TEXT PRIMARY KEY, identity TEXT NOT NULL, desired_mode TEXT NOT NULL, phase TEXT NOT NULL, revision INTEGER NOT NULL, config_hash TEXT, service_version TEXT);
                    CREATE TABLE commands (id TEXT PRIMARY KEY, request TEXT NOT NULL, outcome TEXT NOT NULL);
                    CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL);
                    PRAGMA user_version=1;
                    COMMIT;''')
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

    def _event(self, kind, payload):
        self.__connection.execute('INSERT INTO events(timestamp,type,payload) VALUES(?,?,?)', (time.time(), kind, canonical_json(payload)))
        self.__connection.execute('UPDATE domain SET revision=revision+1')

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
            connection.execute('COMMIT')
            return {'domain': domain, 'events': events, 'commands': commands}
        except Exception:
            connection.execute('ROLLBACK')
            raise
