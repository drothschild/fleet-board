"""Versioned, bounded, attempt-bound provider request and result transport."""
import hashlib
import hmac
import json
import math
import os
import fcntl
from pathlib import Path, PurePosixPath
import selectors
import secrets
import signal
import socket
import stat
import struct
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass


class ContractError(RuntimeError):
    pass


class _AnyCancellation:
    def __init__(self, *events):
        self.events = events

    def is_set(self):
        return any(event.is_set() for event in self.events)


@dataclass(frozen=True)
class ProviderRequest:
    attempt_id: str
    generation: int
    role: str
    stage: str
    provider: str
    model: str
    input_text: str
    input_sha: str
    schema_version: int = 1
    request_id: str = ''

    @classmethod
    def create(cls, *, attempt_id, generation, role, stage, provider, model, input_text,
               request_id=None):
        if not isinstance(input_text, str):
            raise ContractError('provider input must be text')
        return cls(attempt_id, generation, role, stage, provider, model, input_text,
                   hashlib.sha256(input_text.encode('utf-8')).hexdigest(), 1,
                   request_id or secrets.token_urlsafe(24))

    def to_dict(self):
        return {'schema_version': self.schema_version, 'attempt_id': self.attempt_id,
                'generation': self.generation, 'role': self.role, 'stage': self.stage,
                'provider': self.provider, 'model': self.model,
                'input_text': self.input_text, 'input_sha': self.input_sha,
                'request_id': self.request_id}


def _valid_request(request):
    if not isinstance(request, ProviderRequest) or request.schema_version != 1:
        raise ContractError('unsupported provider request schema')
    if (not request.attempt_id or not isinstance(request.attempt_id, str)
            or type(request.generation) is not int or request.generation < 0
            or not request.role or not request.provider or not request.model
            or not isinstance(request.request_id, str) or not request.request_id
            or len(request.request_id) > 128
            or request.role not in ('implementor', 'reviewer', 'fixer', 'stage-reviewer')
            or not isinstance(request.input_text, str)
            or len(request.input_text.encode('utf-8')) > 4 * 1048576):
        raise ContractError('invalid provider request')
    digest = hashlib.sha256(request.input_text.encode('utf-8')).hexdigest()
    if request.input_sha != digest:
        raise ContractError('provider input SHA mismatch')
    return request


def validate_result(request, result):
    _valid_request(request)
    required = {'schema_version', 'attempt_id', 'generation', 'input_sha', 'provider', 'model', 'text', 'usage'}
    if not isinstance(result, dict) or set(result) != required:
        raise ContractError('invalid provider result fields')
    if any(result[key] != getattr(request, key) for key in ('attempt_id', 'generation', 'input_sha', 'provider', 'model')):
        raise ContractError('provider result does not match attempt input')
    if type(result['generation']) is not int:
        raise ContractError('provider result generation must be an integer')
    if type(result['schema_version']) is not int or result['schema_version'] != 1:
        raise ContractError('unsupported provider result schema')
    if not isinstance(result['text'], str) or not result['text'] or len(result['text'].encode('utf-8')) > 1048576:
        raise ContractError('provider returned no text')
    usage = result['usage']
    if usage is not None and (not isinstance(usage, dict) or set(usage) != {'input_tokens', 'output_tokens'}
                              or any(type(usage[k]) is not int or usage[k] < 0 for k in usage)):
        raise ContractError('invalid provider usage')
    return result


def _terminate_provider_group(process):
    """Terminate the whole provider group even when its leader exits first."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        process.wait(timeout=0.3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return
    except OSError:
        # Still try SIGKILL: the process group may exist but deny a signal-0 probe.
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def run_provider(argv, request, *, timeout=300, stdout_limit=1048576, stderr_limit=65536,
                 cancel_event=None, cancel_after=None, trusted_environment=None):
    """Run one explicit CLI with bounded pipes, a hard deadline and process-group cancel."""
    _valid_request(request)
    if (not isinstance(argv, (list, tuple)) or not argv or
            any(not isinstance(arg, str) or not arg for arg in argv)):
        raise ContractError('provider command must be argv')
    if (type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0
            or type(stdout_limit) is not int or type(stderr_limit) is not int
            or stdout_limit < 1 or stderr_limit < 1):
        raise ContractError('invalid provider bounds')
    try:
        env = {'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent'}
        for key, value in (trusted_environment or {}).items():
            if not isinstance(key, str) or not key.isidentifier() or key in env or not isinstance(value, str):
                raise ContractError('invalid trusted provider environment')
            env[key] = value
        process = subprocess.Popen(list(argv), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True,
                                   close_fds=True, env=env)
    except OSError as exc:
        raise ContractError('provider executable unavailable') from exc
    selector = selectors.DefaultSelector()
    output = {process.stdout: bytearray(), process.stderr: bytearray()}
    limits = {process.stdout: stdout_limit, process.stderr: stderr_limit}
    start = time.monotonic()
    cancel_at = start + cancel_after if cancel_after is not None else None
    try:
        payload = json.dumps(request.to_dict(), separators=(',', ':'), ensure_ascii=False).encode('utf-8')
        input_offset = 0
        os.set_blocking(process.stdin.fileno(), False)
        selector.register(process.stdin, selectors.EVENT_WRITE)
        for stream in output:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            if now >= start + timeout or (cancel_at is not None and now >= cancel_at) or (cancel_event is not None and cancel_event.is_set()):
                raise ContractError('provider cancelled or deadline exceeded')
            if process.poll() is not None and input_offset < len(payload):
                raise ContractError('provider closed request channel')
            for key, _ in selector.select(min(.05, max(.001, start + timeout - now))):
                if key.fileobj is process.stdin:
                    try:
                        input_offset += os.write(key.fd, payload[input_offset:input_offset + 65536])
                    except OSError as exc:
                        raise ContractError('provider closed request channel') from exc
                    if input_offset >= len(payload):
                        selector.unregister(key.fileobj)
                        process.stdin.close()
                    continue
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                target = output[key.fileobj]
                target.extend(chunk)
                if len(target) > limits[key.fileobj]:
                    raise ContractError('provider output exceeded limit')
        if process.returncode != 0:
            raise ContractError('provider command failed')
        try:
            response = json.loads(output[process.stdout].decode('utf-8'))
        except (UnicodeDecodeError, ValueError) as exc:
            raise ContractError('provider returned invalid JSON') from exc
        return validate_result(request, response)
    except BaseException:
        _terminate_provider_group(process)
        raise
    finally:
        selector.close()
        for stream in output:
            try:
                stream.close()
            except OSError:
                pass


class InferenceBroker:
    """Attempt-scoped broker with explicit provider/model allowlists."""
    def __init__(self, providers, *, attempts=None, trusted_environment=None,
                 max_invocations_per_attempt=8):
        self.providers = providers
        self.attempts = attempts or {}
        self.trusted_environment = trusted_environment or {}
        if type(max_invocations_per_attempt) is not int or max_invocations_per_attempt < 1:
            raise ValueError('invalid per-attempt provider invocation limit')
        self.max_invocations_per_attempt = max_invocations_per_attempt
        self._accounting = {}
        self._calls = {}
        self._call_lock = threading.Lock()

    def validate_request(self, raw):
        required = {'schema_version', 'attempt_id', 'generation', 'role', 'stage', 'provider', 'model', 'input_text', 'input_sha', 'request_id'}
        if not isinstance(raw, dict) or set(raw) != required:
            raise ContractError('invalid broker request fields')
        if any(key in raw for key in ('url', 'endpoint', 'headers', 'environment', 'credential')):
            raise ContractError('broker does not forward transport or credentials')
        config = self.providers.get(raw['provider']) if isinstance(raw.get('provider'), str) else None
        if not isinstance(config, dict) or raw['model'] != config.get('model'):
            raise ContractError('provider/model selection is not configured')
        binding = self.attempts.get(raw['attempt_id']) if isinstance(raw.get('attempt_id'), str) else None
        expected = ('generation', 'role', 'stage', 'provider', 'model', 'input_sha')
        if not isinstance(binding, dict) or any(binding.get(key) != raw.get(key) for key in expected):
            raise ContractError('request is not authorized for this attempt')
        if not isinstance(config.get('command'), (list, tuple)):
            raise ContractError('provider command is unavailable')
        credential_name = config.get('credential_env')
        if credential_name is not None:
            if (not isinstance(credential_name, str) or not credential_name.isidentifier()
                    or credential_name not in self.trusted_environment
                    or not isinstance(self.trusted_environment[credential_name], str)
                    or not self.trusted_environment[credential_name]
                    or any(ord(char) < 32 or ord(char) == 127 for char in self.trusted_environment[credential_name])):
                raise ContractError('provider credential unavailable')
        request = ProviderRequest(**raw)
        return _valid_request(request)

    def infer(self, raw, **bounds):
        request = self.validate_request(raw)
        key = (request.attempt_id, request.request_id)
        body_sha = hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(',', ':')).encode('utf-8')).hexdigest()
        with self._call_lock:
            previous = self._calls.get(key)
            if previous is not None:
                if previous['body_sha'] != body_sha:
                    raise ContractError('request id reused with a different body')
                if previous['state'] == 'complete':
                    return dict(previous['result'])
                if previous['state'] == 'failed':
                    raise ContractError(previous['error'])
                raise ContractError('request id is already in flight')
            history = self._accounting.setdefault(request.attempt_id, [])
            if len(history) >= self.max_invocations_per_attempt:
                raise ContractError('attempt provider invocation limit exceeded')
            record = {'request_id': request.request_id, 'provider': request.provider,
                      'model': request.model, 'body_sha': body_sha,
                      'outcome': 'in_flight', 'usage': None}
            history.append(record)
            self._calls[key] = {'body_sha': body_sha, 'state': 'in_flight'}
        credential_name = self.providers[request.provider].get('credential_env')
        provider_env = ({credential_name: self.trusted_environment[credential_name]}
                        if credential_name is not None else {})
        try:
            result = run_provider(self.providers[request.provider]['command'], request,
                                  trusted_environment=provider_env, **bounds)
        except Exception as exc:
            with self._call_lock:
                record['outcome'] = 'error'
                record['error'] = str(exc)[:200]
                self._calls[key] = {'body_sha': body_sha, 'state': 'failed', 'error': record['error']}
            raise
        with self._call_lock:
            record['outcome'] = 'success'
            record['usage'] = result['usage']
            self._calls[key] = {'body_sha': body_sha, 'state': 'complete', 'result': dict(result)}
        return result

    def accounting_for(self, attempt_id):
        with self._call_lock:
            return [dict(item) for item in self._accounting.get(attempt_id, [])]


class InferenceChannel:
    """Private local socket exposing only bounded, attempt-authenticated inference."""
    MAX_REQUEST_BYTES = 4 * 1048576
    MAX_RESPONSE_BYTES = 1049600
    MAX_REQUESTS = 32
    MAX_REQUESTS_PER_ATTEMPT = 8
    MAX_OPERATION_JOURNAL_BYTES = 16 * 1048576
    MAX_OPERATION_ENTRIES = 4096

    def __init__(self, broker, directory, attempt_ids, *, request_timeout=310, frame_timeout=5,
                 attempt_controls=None, operation_journal=None, terminal_attempt_checker=None,
                 controller_dispatcher=None):
        self.broker = broker
        self.directory = Path(directory)
        if (not self.directory.is_absolute() or self.directory.is_symlink()
                or self.directory.resolve(strict=True) != self.directory
                or not self.directory.is_dir() or self.directory.stat().st_uid != os.getuid()
                or self.directory.stat().st_mode & 0o077):
            raise ValueError('inference channel directory must be private')
        self.operation_journal = None
        self._operation_calls = {}
        self._journal_snapshot = None
        from .workers import OwnerThreadDispatcher, TrustedAttemptTerminalChecker
        if controller_dispatcher is not None and type(controller_dispatcher) is not OwnerThreadDispatcher:
            raise ValueError('controller dispatcher must be an owner-thread dispatcher')
        if (terminal_attempt_checker is not None
                and (type(terminal_attempt_checker) is not TrustedAttemptTerminalChecker
                     or terminal_attempt_checker.dispatcher is not controller_dispatcher)):
            raise ValueError('terminal attempt authority must use a trusted terminal checker')
        self.terminal_attempt_checker = terminal_attempt_checker
        self.controller_dispatcher = controller_dispatcher
        if operation_journal is not None:
            journal = Path(operation_journal)
            if not journal.is_absolute() or journal.is_symlink():
                raise ValueError('operation journal must be an absolute private file')
            parent = journal.parent
            if (parent.is_symlink() or parent.resolve(strict=True) != parent
                    or not parent.is_dir() or parent.stat().st_uid != os.getuid()
                    or parent.stat().st_mode & 0o077):
                raise ValueError('operation journal directory must be private')
            try:
                common = os.path.commonpath((str(journal), str(self.directory)))
            except ValueError as exc:
                raise ValueError('operation journal and channel paths are incompatible') from exc
            if common == str(self.directory):
                raise ValueError('operation journal cannot be inside the worker channel directory')
            if journal.exists():
                info = journal.lstat()
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_mode & 0o077 or info.st_nlink != 1
                        or info.st_size > self.MAX_OPERATION_JOURNAL_BYTES):
                    raise ValueError('unsafe operation journal')
                self._journal_snapshot = journal.read_bytes()
                self._operation_calls = self._load_operation_journal_bytes(self._journal_snapshot)
            self.operation_journal = journal
        self.socket_path = self.directory / 'inference.sock'
        if len(os.fsencode(self.socket_path)) >= 104:
            raise ValueError('inference channel socket path is too long')
        if self.socket_path.exists() or self.socket_path.is_symlink():
            raise ValueError('inference channel socket path already exists')
        if not isinstance(attempt_ids, (list, tuple, set)) or not attempt_ids:
            raise ValueError('inference channel requires attempt ids')
        self._capabilities = {}
        for attempt_id in attempt_ids:
            if not isinstance(attempt_id, str) or not attempt_id or attempt_id in self._capabilities:
                raise ValueError('invalid inference channel attempt')
            if attempt_id not in broker.attempts:
                raise ValueError('inference channel attempt is not broker-authorized')
            self._capabilities[attempt_id] = secrets.token_urlsafe(32)
        if (type(request_timeout) not in (int, float) or request_timeout <= 0
                or type(frame_timeout) not in (int, float) or frame_timeout <= 0):
            raise ValueError('invalid inference channel deadline')
        self.request_timeout = request_timeout
        self.frame_timeout = min(frame_timeout, request_timeout)
        self._listener = None
        self._thread = None
        self._stop = threading.Event()
        self._requests = 0
        self._request_slots = None
        self._attempt_requests = {attempt_id: 0 for attempt_id in self._capabilities}
        self._attempt_inflight = set()
        self._request_lock = threading.Lock()
        self._attempt_controls = {}
        self._attempt_bindings = {}
        self._operation_handlers = {}
        self._retired_attempts = set()
        self._retiring_attempts = set()
        self._operation_admissions = {}
        self._executor = None
        self._inode = None
        for attempt_id, control in (attempt_controls or {}).items():
            if not isinstance(control, dict) or set(control) != {'deadline', 'cancel_event'}:
                raise ValueError('invalid inference attempt control')
            self.bind_attempt_control(attempt_id, control['deadline'], control['cancel_event'])

    def bind_attempt_control(self, attempt_id, deadline, cancel_event):
        """Bind provider subprocess lifetime to one durable attempt's controls."""
        if (attempt_id not in self._capabilities
                or type(deadline) not in (int, float) or not math.isfinite(deadline)
                or deadline <= 0 or not isinstance(cancel_event, threading.Event)):
            raise ContractError('invalid inference attempt control')
        with self._request_lock:
            self._attempt_controls[attempt_id] = (deadline, cancel_event)

    def bind_attempt_operations(self, attempt_id, binding, handlers):
        """Bind trusted controller handlers to one worker attempt."""
        if self.operation_journal is None:
            raise ContractError('worker operation dispatch requires a durable controller journal')
        fields = {'domain_id', 'job_id', 'attempt_id', 'generation', 'input_sha', 'role', 'stage'}
        if (attempt_id not in self._capabilities or not isinstance(binding, dict)
                or set(binding) != fields or binding.get('attempt_id') != attempt_id
                or not isinstance(binding.get('domain_id'), str) or not binding['domain_id']
                or not isinstance(binding.get('job_id'), str) or not binding['job_id']
                or type(binding.get('generation')) is not int or binding['generation'] < 0
                or not isinstance(binding.get('input_sha'), str)
                or len(binding['input_sha']) != 64
                or any(char not in '0123456789abcdef' for char in binding['input_sha'])
                or not isinstance(binding.get('role'), str) or not binding['role']
                or (binding.get('stage') is not None
                    and (not isinstance(binding['stage'], str) or not binding['stage']))):
            raise ContractError('invalid worker operation binding')
        broker_binding = self.broker.attempts.get(attempt_id)
        if not isinstance(broker_binding, dict) or any(
                broker_binding.get(key) != binding[key]
                for key in ('generation', 'input_sha', 'role', 'stage')):
            raise ContractError('worker operations do not match broker attempt')
        allowed = {'heartbeat', 'result', 'scope_request'}
        if (not isinstance(handlers, dict) or set(handlers) != allowed
                or any(not callable(handlers[name]) for name in allowed)):
            raise ContractError('worker operations require trusted heartbeat, result, and scope handlers')
        from .workers import (OwnerThreadDispatcher, TrustedAttemptOperationHandlers,
                              TrustedAttemptResultHandler, TrustedAttemptTerminalChecker)
        if (type(self.controller_dispatcher) is not OwnerThreadDispatcher
                or type(handlers) is not TrustedAttemptOperationHandlers
                or handlers.dispatcher is not self.controller_dispatcher
                or handlers.binding != binding):
            raise ContractError('worker operations require factory handlers and an owner-thread dispatcher')
        if type(handlers['result']) is not TrustedAttemptResultHandler:
            raise ContractError('worker result handler must own artifact validation and durable publication')
        if (type(self.terminal_attempt_checker) is not TrustedAttemptTerminalChecker
                or self.terminal_attempt_checker.dispatcher is not self.controller_dispatcher
                or self.terminal_attempt_checker._store is not handlers._store
                or handlers['result'].store is not handlers._store):
            raise ContractError('worker operations require durable terminal-attempt authority')
        if handlers['result'].dispatcher is not self.controller_dispatcher:
            raise ContractError('worker result handler uses a different controller dispatcher')
        if attempt_id in self._retired_attempts:
            raise ContractError('attempt is terminal and cannot reconnect')
        try:
            terminal = self.controller_dispatcher.call(
                self.terminal_attempt_checker, attempt_id,
                binding['generation'], binding['input_sha'])
        except Exception as exc:
            raise ContractError('terminal attempt authority is unavailable') from exc
        if type(terminal) is not str or terminal not in ('active', 'revoked', 'terminal_released'):
            raise ContractError('terminal attempt authority returned an invalid result')
        if terminal == 'terminal_released':
            raise ContractError('attempt is terminal and cannot reconnect')
        if terminal != 'active':
            raise ContractError('attempt authority is revoked')
        with self._request_lock:
            if attempt_id in self._operation_handlers:
                raise ContractError('worker operations already bound for attempt')
            self._attempt_bindings[attempt_id] = dict(binding)
            self._operation_handlers[attempt_id] = dict(handlers)

    def retire_attempt_operations(self, attempt_id):
        """Compact a completed attempt only after durable terminal/released proof."""
        with self._request_lock:
            binding = self._attempt_bindings.get(attempt_id)
            if binding is None or self.terminal_attempt_checker is None:
                raise ContractError('attempt has no retirement authority')
            if attempt_id in self._retiring_attempts:
                raise ContractError('attempt retirement is already in progress')
            if self._operation_admissions.get(attempt_id, 0):
                raise ContractError('cannot retire while a worker operation is being admitted or handled')
            if any(key[0] == attempt_id and record['state'] == 'in_flight'
                   for key, record in self._operation_calls.items()):
                raise ContractError('cannot retire an in-flight worker operation')
            self._retiring_attempts.add(attempt_id)
        try:
            try:
                terminal = self.controller_dispatcher.call(
                    self.terminal_attempt_checker, attempt_id,
                    binding['generation'], binding['input_sha'])
            except Exception as exc:
                raise ContractError('terminal attempt authority is unavailable') from exc
            if terminal != 'terminal_released':
                raise ContractError('attempt is not terminal and execution-released')
            with self._request_lock:
                old_calls = self._operation_calls
                self._operation_calls = {key: record for key, record in old_calls.items()
                                         if key[0] != attempt_id}
                try:
                    self._persist_operation_journal()
                except Exception as exc:
                    self._operation_calls = old_calls
                    raise ContractError('attempt operation records could not be retired safely') from exc
                self._attempt_bindings.pop(attempt_id, None)
                self._operation_handlers.pop(attempt_id, None)
                self._attempt_controls.pop(attempt_id, None)
                self._capabilities.pop(attempt_id, None)
                self._attempt_requests.pop(attempt_id, None)
                self._retired_attempts.add(attempt_id)
                return True
        finally:
            with self._request_lock:
                if attempt_id not in self._retired_attempts:
                    self._retiring_attempts.discard(attempt_id)

    def operations_for(self, attempt_id):
        with self._request_lock:
            if attempt_id not in self._operation_handlers:
                return ()
            return ('heartbeat', 'result', 'scope_request')

    @staticmethod
    def _validate_operation_payload(operation, payload, binding):
        identity = {'schema_version', 'domain_id', 'job_id', 'attempt_id',
                    'generation', 'input_sha', 'role', 'stage'}
        if not isinstance(payload, dict):
            raise ContractError('invalid worker operation payload')
        if (type(payload.get('generation')) is not int
                or any(payload.get(key) != binding[key] for key in identity - {'schema_version'})):
            raise ContractError('worker operation does not match attempt')
        request_id = payload.get('request_id')
        if (not isinstance(request_id, str) or not request_id or len(request_id) > 128
                or any(ord(char) < 32 or ord(char) == 127 for char in request_id)):
            raise ContractError('invalid worker operation request id')
        if type(payload.get('schema_version')) is not int or payload['schema_version'] != 1:
            raise ContractError('unsupported worker operation schema')
        if operation == 'heartbeat':
            if set(payload) != identity | {'request_id', 'at'} or type(payload['at']) not in (int, float) or not math.isfinite(payload['at']) or payload['at'] <= 0 or payload['at'] > time.time() + 5:
                raise ContractError('invalid attempt heartbeat')
        elif operation == 'result':
            required = identity | {'request_id', 'outcome', 'report_path', 'artifact_hashes', 'usage', 'exit_code'}
            if set(payload) != required or payload['outcome'] not in ('success', 'failure', 'cancelled'):
                raise ContractError('invalid attempt result envelope')
            if (not isinstance(payload['report_path'], str) or not payload['report_path']
                    or '/' in payload['report_path'] or '\\' in payload['report_path']
                    or payload['report_path'] in ('.', '..')):
                raise ContractError('attempt result has no safe report name')
            hashes = payload['artifact_hashes']
            if (not isinstance(hashes, dict) or len(hashes) < 1 or len(hashes) > 128
                    or payload['report_path'] not in hashes
                    or any(not isinstance(path, str) or not path or '/' in path or '\\' in path
                           or path in ('.', '..') or not isinstance(digest, str)
                           or len(digest) != 64 or any(char not in '0123456789abcdef' for char in digest)
                           for path, digest in hashes.items())):
                raise ContractError('invalid attempt result artifacts')
            usage = payload['usage']
            if usage is not None and (not isinstance(usage, dict) or set(usage) != {'cost_usd'}
                                      or type(usage['cost_usd']) not in (int, float)
                                      or not math.isfinite(usage['cost_usd']) or usage['cost_usd'] < 0):
                raise ContractError('invalid attempt result usage')
            if type(payload['exit_code']) is not int:
                raise ContractError('invalid attempt result exit code')
        elif operation == 'scope_request':
            if set(payload) != identity | {'request_id', 'paths', 'expected_revision'}:
                raise ContractError('invalid scope request envelope')
            paths = payload['paths']
            if (not isinstance(paths, list) or not paths or len(paths) > 256
                    or any(not isinstance(path, str) or not path or len(path) > 4096
                           or '\\' in path or any(ord(char) < 32 or ord(char) == 127 for char in path)
                           or PurePosixPath(path).is_absolute() or PurePosixPath(path).as_posix() != path
                           or any(part in ('', '.', '..') for part in path.split('/'))
                           for path in paths)):
                raise ContractError('invalid scope expansion paths')
            if type(payload['expected_revision']) is not int or payload['expected_revision'] < 0:
                raise ContractError('invalid scope revision')
        else:
            raise ContractError('worker operation is not allowed')
        return payload

    def _dispatch_worker_operation(self, attempt_id, operation, payload):
        with self._request_lock:
            if (attempt_id in self._retired_attempts or attempt_id in self._retiring_attempts
                    or attempt_id not in self._attempt_bindings
                    or attempt_id not in self._operation_handlers):
                raise ContractError('worker operation is not authorized')
            self._operation_admissions[attempt_id] = self._operation_admissions.get(attempt_id, 0) + 1
        try:
            return self._dispatch_worker_operation_admitted(attempt_id, operation, payload)
        finally:
            with self._request_lock:
                remaining = self._operation_admissions[attempt_id] - 1
                if remaining:
                    self._operation_admissions[attempt_id] = remaining
                else:
                    del self._operation_admissions[attempt_id]

    def _dispatch_worker_operation_admitted(self, attempt_id, operation, payload):
        with self._request_lock:
            binding = self._attempt_bindings.get(attempt_id)
            handlers = self._operation_handlers.get(attempt_id)
        if binding is None or handlers is None or operation not in handlers:
            raise ContractError('worker operation is not authorized')
        validated = self._validate_operation_payload(operation, payload, binding)
        if operation in ('heartbeat', 'scope_request'):
            control = self._attempt_controls.get(attempt_id)
            if (self._stop.is_set() or (control is not None and
                    (control[1].is_set() or control[0] <= time.time()))):
                raise ContractError('attempt control authority has expired')
        request_id = validated['request_id']
        body_sha = hashlib.sha256(json.dumps(validated, sort_keys=True, separators=(',', ':'),
                                              allow_nan=False).encode('utf-8')).hexdigest()
        key = (attempt_id, operation, request_id)
        with self._request_lock:
            previous = self._operation_calls.get(key)
            if previous is not None:
                if previous['body_sha'] != body_sha:
                    raise ContractError('worker request id reused with a different body')
                if previous['state'] == 'complete':
                    return dict(previous['result'])
                raise ContractError('worker request id is already consumed')
            if len(self._operation_calls) >= self.MAX_OPERATION_ENTRIES:
                raise ContractError('worker operation journal capacity exceeded')
            self._operation_calls[key] = {'body_sha': body_sha, 'state': 'in_flight'}
            try:
                self._persist_operation_journal()
            except Exception as exc:
                del self._operation_calls[key]
                raise ContractError('worker operation could not be durably recorded') from exc
        try:
            result = handlers[operation](validated)
            if operation == 'scope_request':
                if (not isinstance(result, dict) or type(result.get('granted')) is not bool
                        or (result['granted'] and not isinstance(result.get('reservation'), dict))
                        or (not result['granted'] and (
                            result.get('retry_penalty') is not False
                            or result.get('attempt_should_exit') is not True
                            or result.get('worker_slot_released') is not True
                            or result.get('checkpointed') is not True
                            or not isinstance(result.get('waiting_on'), str)))):
                    raise ContractError('scope handler returned an unsafe result')
            if not isinstance(result, dict):
                raise ContractError('worker operation handler returned an invalid result')
            encoded = json.dumps(result, separators=(',', ':'), allow_nan=False).encode('utf-8')
            if not encoded or len(encoded) > self.MAX_RESPONSE_BYTES - 64:
                raise ContractError('worker operation result exceeded limit')
            with self._request_lock:
                self._operation_calls[key] = {'body_sha': body_sha, 'state': 'complete',
                                              'result': dict(result)}
                self._persist_operation_journal()
            return result
        except Exception as exc:
            with self._request_lock:
                self._operation_calls[key] = {'body_sha': body_sha, 'state': 'failed',
                                              'error': str(exc)[:200]}
                try:
                    self._persist_operation_journal()
                except Exception:
                    # The already-persisted in_flight record still prevents replay.
                    self._operation_calls[key] = {'body_sha': body_sha, 'state': 'in_flight'}
            if isinstance(exc, ContractError):
                raise
            raise ContractError('worker operation handler failed') from exc

    @classmethod
    def _load_operation_journal(cls, path):
        try:
            return cls._load_operation_journal_bytes(path.read_bytes())
        except Exception as exc:
            raise ValueError('invalid operation journal') from exc

    @classmethod
    def _load_operation_journal_bytes(cls, raw):
        try:
            if len(raw) > cls.MAX_OPERATION_JOURNAL_BYTES:
                raise ValueError('operation journal exceeded limit')
            value = json.loads(raw.decode('utf-8'))
        except Exception as exc:
            raise ValueError('invalid operation journal') from exc
        if not isinstance(value, dict) or set(value) != {'schema_version', 'operations'} or value['schema_version'] != 1:
            raise ValueError('invalid operation journal schema')
        operations = value['operations']
        if not isinstance(operations, list) or len(operations) > cls.MAX_OPERATION_ENTRIES:
            raise ValueError('invalid operation journal entries')
        calls = {}
        for item in operations:
            if not isinstance(item, dict):
                raise ValueError('invalid operation journal entry')
            state = item.get('state')
            fields = {'attempt_id', 'operation', 'request_id', 'body_sha', 'state'}
            if state == 'complete':
                fields.add('result')
            elif state == 'failed':
                fields.add('error')
            if set(item) != fields or state not in ('in_flight', 'complete', 'failed'):
                raise ValueError('invalid operation journal entry')
            attempt_id, operation, request_id, body_sha = (
                item.get('attempt_id'), item.get('operation'), item.get('request_id'), item.get('body_sha'))
            if (not isinstance(attempt_id, str) or not attempt_id
                    or operation not in ('heartbeat', 'result', 'scope_request')
                    or not isinstance(request_id, str) or not request_id
                    or not isinstance(body_sha, str) or len(body_sha) != 64
                    or any(char not in '0123456789abcdef' for char in body_sha)):
                raise ValueError('invalid operation journal key')
            key = (attempt_id, operation, request_id)
            if key in calls:
                raise ValueError('duplicate operation journal key')
            record = {'body_sha': body_sha, 'state': state}
            if state == 'complete':
                if not isinstance(item['result'], dict):
                    raise ValueError('invalid operation journal result')
                record['result'] = item['result']
            elif state == 'failed':
                if not isinstance(item['error'], str):
                    raise ValueError('invalid operation journal error')
                record['error'] = item['error']
            calls[key] = record
        return calls

    def _persist_operation_journal(self):
        if self.operation_journal is None:
            raise ContractError('worker operation dispatch requires a durable controller journal')
        entries = []
        for (attempt_id, operation, request_id), record in sorted(self._operation_calls.items()):
            item = {'attempt_id': attempt_id, 'operation': operation, 'request_id': request_id,
                    'body_sha': record['body_sha'], 'state': record['state']}
            if record['state'] == 'complete':
                item['result'] = record['result']
            elif record['state'] == 'failed':
                item['error'] = record['error']
            entries.append(item)
        data = json.dumps({'schema_version': 1, 'operations': entries}, sort_keys=True,
                          separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(data) > self.MAX_OPERATION_JOURNAL_BYTES:
            raise ContractError('worker operation journal exceeded limit')
        lock_path = self.operation_journal.with_name(self.operation_journal.name + '.lock')
        flags = os.O_RDWR | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
        lock_fd = os.open(str(lock_path), flags, 0o600)
        try:
            lock_info = os.fstat(lock_fd)
            if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid()
                    or lock_info.st_mode & 0o077 or lock_info.st_nlink != 1):
                raise ContractError('unsafe operation journal lock')
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                current = (self.operation_journal.read_bytes()
                           if self.operation_journal.exists() else None)
                if current != self._journal_snapshot:
                    raise ContractError('operation journal changed in another controller')
                temp = self.operation_journal.with_name('.' + self.operation_journal.name + '.' + secrets.token_hex(8))
                fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                try:
                    view = memoryview(data)
                    while view:
                        written = os.write(fd, view)
                        view = view[written:]
                    os.fsync(fd)
                finally:
                    os.close(fd)
                try:
                    os.replace(str(temp), str(self.operation_journal))
                    dir_fd = os.open(str(self.operation_journal.parent), os.O_RDONLY)
                    try:
                        os.fsync(dir_fd)
                    finally:
                        os.close(dir_fd)
                    self._journal_snapshot = data
                finally:
                    try:
                        temp.unlink()
                    except FileNotFoundError:
                        pass
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)

    def capability_for(self, attempt_id):
        """Return the one-attempt token for trusted launch code to pass over a private fd."""
        if attempt_id not in self._capabilities:
            raise ContractError('attempt has no inference channel')
        return self._capabilities[attempt_id]

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.stop()

    def start(self):
        if self._listener is not None:
            return self
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.socket_path))
            os.chmod(self.socket_path, 0o600)
            info = self.socket_path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('unsafe inference channel socket')
            self._inode = (info.st_dev, info.st_ino)
            listener.listen(8)
            listener.settimeout(0.1)
            self._listener = listener
            self._executor = ThreadPoolExecutor(max_workers=min(16, max(4, len(self._capabilities) * 4)),
                                                thread_name_prefix='inference-request')
            self._request_slots = threading.BoundedSemaphore(
                min(16, max(4, len(self._capabilities) * 4)))
            self._thread = threading.Thread(target=self._serve, name='inference-broker', daemon=True)
            self._thread.start()
            return self
        except BaseException:
            listener.close()
            self._unlink_socket()
            raise

    def stop(self):
        self._stop.set()
        if self._listener is not None:
            self._listener.close()
            self._listener = None
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None
        if self._executor is not None:
            self._executor.shutdown(wait=False, cancel_futures=True)
            self._executor = None
        self._unlink_socket()
        self._capabilities.clear()
        self._attempt_controls.clear()
        self._attempt_bindings.clear()
        self._operation_handlers.clear()
        self._operation_calls.clear()

    def _unlink_socket(self):
        try:
            info = self.socket_path.lstat()
            if (stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
                    and self._inode == (info.st_dev, info.st_ino)):
                self.socket_path.unlink()
        except OSError:
            pass

    @staticmethod
    def _read_exact(connection, count, deadline):
        chunks = bytearray()
        while len(chunks) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ContractError('inference channel deadline exceeded')
            connection.settimeout(min(remaining, 1.0))
            try:
                chunk = connection.recv(min(65536, count - len(chunks)))
            except socket.timeout:
                continue
            if not chunk:
                raise ContractError('incomplete inference channel frame')
            chunks.extend(chunk)
        return bytes(chunks)

    @staticmethod
    def _write_frame(connection, value, limit):
        data = json.dumps(value, separators=(',', ':'), ensure_ascii=False,
                          allow_nan=False).encode('utf-8')
        if not data or len(data) > limit:
            raise ContractError('inference channel response exceeded limit')
        connection.sendall(struct.pack('!I', len(data)) + data)

    def _serve_request(self, connection):
        deadline = time.monotonic() + self.frame_timeout
        header = self._read_exact(connection, 4, deadline)
        size = struct.unpack('!I', header)[0]
        if size < 1 or size > self.MAX_REQUEST_BYTES:
            raise ContractError('inference channel request exceeded limit')
        raw = json.loads(self._read_exact(connection, size, deadline).decode('utf-8'))
        if (not isinstance(raw, dict)
                or set(raw) != {'schema_version', 'operation', 'attempt_id', 'capability', 'request'}
                or type(raw['schema_version']) is not int or raw['schema_version'] != 1
                or not isinstance(raw['operation'], str)
                or not isinstance(raw['attempt_id'], str)
                or not isinstance(raw['capability'], str)
                or not isinstance(raw['request'], dict)):
            raise ContractError('inference channel operation rejected')
        expected = self._capabilities.get(raw['attempt_id'])
        if expected is None or not hmac.compare_digest(expected, raw['capability']):
            raise ContractError('inference channel authentication failed')
        if raw['request'].get('attempt_id') != raw['attempt_id']:
            raise ContractError('inference channel attempt mismatch')
        if raw['operation'] != 'infer':
            result = self._dispatch_worker_operation(raw['attempt_id'], raw['operation'], raw['request'])
            self._write_frame(connection, {'schema_version': 1, 'result': result}, self.MAX_RESPONSE_BYTES)
            return
        if not self._claim_attempt(raw['attempt_id']):
            raise ContractError('attempt inference quota or concurrency limit exceeded')
        if not self._claim_global_request():
            self._release_attempt(raw['attempt_id'])
            raise ContractError('inference channel quota exhausted')
        try:
            control = self._attempt_controls.get(raw['attempt_id'])
            cancel_event = self._stop
            timeout = self.request_timeout - 1
            if control is not None:
                durable_deadline, attempt_cancel = control
                remaining = durable_deadline - time.time()
                if remaining <= 0 or attempt_cancel.is_set():
                    raise ContractError('attempt cancelled or durable deadline exceeded')
                cancel_event = _AnyCancellation(self._stop, attempt_cancel)
                timeout = min(timeout, remaining)
            result = self.broker.infer(raw['request'], timeout=timeout,
                                       cancel_event=cancel_event)
            self._write_frame(connection, {'schema_version': 1, 'result': result}, self.MAX_RESPONSE_BYTES)
        finally:
            self._release_attempt(raw['attempt_id'])

    def _claim_attempt(self, attempt_id):
        with self._request_lock:
            if (attempt_id not in self._attempt_requests
                    or attempt_id in self._attempt_inflight
                    or self._attempt_requests[attempt_id] >= self.MAX_REQUESTS_PER_ATTEMPT):
                return False
            self._attempt_requests[attempt_id] += 1
            self._attempt_inflight.add(attempt_id)
            return True

    def _claim_global_request(self):
        with self._request_lock:
            if self._requests >= self.MAX_REQUESTS:
                return False
            self._requests += 1
            return True

    def _release_attempt(self, attempt_id):
        with self._request_lock:
            self._attempt_inflight.discard(attempt_id)

    def _serve_connection(self, connection):
        with connection:
            try:
                connection.settimeout(1.0)
                self._serve_request(connection)
            except (OSError, ValueError, TypeError, KeyError, ContractError, UnicodeDecodeError):
                try:
                    self._write_frame(connection, {'schema_version': 1, 'error': 'request rejected'}, 1024)
                except OSError:
                    pass
            except Exception:
                try:
                    self._write_frame(connection, {'schema_version': 1, 'error': 'request rejected'}, 1024)
                except OSError:
                    pass

    def _serve(self):
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self._request_slots.acquire(blocking=False):
                connection.close()
                continue
            try:
                future = self._executor.submit(self._serve_connection, connection)
                future.add_done_callback(lambda _future: self._request_slots.release())
            except BaseException:
                self._request_slots.release()
                connection.close()
                if self._stop.is_set():
                    break
                continue

    def request(self, attempt_id, capability, request, *, operation='infer', timeout=None):
        """Controller-side test/diagnostic client; workers use InferenceClient."""
        return InferenceClient(self.socket_path, attempt_id, capability, timeout=timeout or self.request_timeout).request(
            request, operation=operation)


class InferenceClient:
    """Worker-side client configured only with its attempt socket and capability."""
    def __init__(self, socket_path, attempt_id, capability, *, timeout=310):
        self.socket_path = Path(socket_path)
        self.attempt_id = attempt_id
        self.capability = capability
        self.timeout = timeout

    def infer(self, request):
        return self.request(request, operation='infer')

    def request(self, request, *, operation='infer'):
        if (not isinstance(self.attempt_id, str) or not self.attempt_id
                or not isinstance(self.capability, str) or not self.capability
                or not isinstance(request, dict)):
            raise ContractError('invalid inference channel request')
        envelope = {'schema_version': 1, 'operation': operation, 'attempt_id': self.attempt_id,
                    'capability': self.capability, 'request': request}
        try:
            data = json.dumps(envelope, separators=(',', ':'), allow_nan=False).encode('utf-8')
        except (TypeError, ValueError) as exc:
            raise ContractError('invalid inference channel request') from exc
        if not data or len(data) > InferenceChannel.MAX_REQUEST_BYTES:
            raise ContractError('inference channel request exceeded limit')
        deadline = time.monotonic() + self.timeout
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(max(0.1, deadline - time.monotonic()))
                connection.connect(str(self.socket_path))
                connection.sendall(struct.pack('!I', len(data)) + data)
                size = struct.unpack('!I', InferenceChannel._read_exact(connection, 4, deadline))[0]
                if size < 1 or size > InferenceChannel.MAX_RESPONSE_BYTES:
                    raise ContractError('inference channel response exceeded limit')
                response = json.loads(InferenceChannel._read_exact(connection, size, deadline).decode('utf-8'))
        except (OSError, ValueError, TypeError, UnicodeDecodeError) as exc:
            raise ContractError('inference channel transport failed') from exc
        if (not isinstance(response, dict) or response.get('schema_version') != 1
                or set(response) not in ({'schema_version', 'result'}, {'schema_version', 'error'})):
            raise ContractError('invalid inference channel response')
        if 'error' in response:
            raise ContractError('inference channel request rejected')
        if operation != 'infer':
            if not isinstance(response['result'], dict):
                raise ContractError('invalid worker operation result')
            return response['result']
        try:
            return validate_result(ProviderRequest(**request), response['result'])
        except (TypeError, ValueError) as exc:
            raise ContractError('invalid inference channel result') from exc
