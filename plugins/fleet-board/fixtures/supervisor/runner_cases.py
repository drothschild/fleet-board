import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from supervisor.processes import ProcessIdentity, identity_for, inspect_identity
from supervisor.runner import Runner


def test_identity():
    identity = identity_for(os.getpid(), 'testnonce')
    assert identity.nonce == 'testnonce'
    assert inspect_identity(identity) == 'alive'
    assert inspect_identity(ProcessIdentity(identity.boot_id, identity.pid, 'wrong', identity.nonce)) == 'unknown'
    assert inspect_identity(ProcessIdentity('wrong', identity.pid, identity.started_at, identity.nonce)) == 'unknown'


def test_production_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            Runner(pathlib.Path(tmp)).launch({'attempt_id': 'attempt', 'nonce': 'nonce'})
        except (ValueError, NotImplementedError):
            pass
        else:
            raise AssertionError('production launch must fail closed')


test_identity()
test_production_fails_closed()
print('runner identity tests passed')


def test_detached_unique_invocation():
    fixture = pathlib.Path(__file__).with_name('fake_worker.py')
    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        counter = directory / 'counter'
        runner = Runner(directory, fixture_command=[sys.executable, str(fixture), str(counter), '0.4'])
        attempt = {'attempt_id': 'a', 'nonce': 'n'}
        first = runner.launch(attempt)
        second = runner.launch(attempt)
        first.wait(timeout=10)
        second.wait(timeout=10)
        assert counter.read_text().splitlines() == ['invoked']
        third = runner.launch(attempt)
        third.wait(timeout=10)
        assert counter.read_text().splitlines() == ['invoked']
        assert (directory / 'attempts' / 'a' / 'receipt.json').exists()


test_detached_unique_invocation()


def test_artifact_ingestion():
    import hashlib
    from supervisor.workers import ingest_artifacts
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('report content')
        target = root / 'durable'
        hashes = ingest_artifacts(scratch, target, ['report'])
        assert hashes == {'report': hashlib.sha256(b'report content').hexdigest()}
        (scratch / 'report').unlink()
        assert (target / 'report').read_text() == 'report content'
        (scratch / 'bad').symlink_to(target / 'report')
        try:
            ingest_artifacts(scratch, root / 'retry', ['bad'])
        except ValueError:
            pass
        (scratch / 'bad').unlink()
        (scratch / 'bad').write_text('fixed')
        ingest_artifacts(scratch, root / 'retry', ['bad'])
        assert (root / 'retry' / 'bad').read_text() == 'fixed'
        (scratch / 'link').symlink_to(target / 'report')
        try:
            ingest_artifacts(scratch, root / 'other', ['link'])
        except ValueError:
            pass
        else:
            raise AssertionError('symlink accepted')
        try:
            ingest_artifacts(scratch, root / 'other2', ['../durable/report'])
        except ValueError:
            pass
        else:
            raise AssertionError('traversal accepted')


test_artifact_ingestion()


def test_result_publication():
    from supervisor.runner import read_result
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        attempt = root / 'attempt'
        attempt.mkdir()
        (attempt / 'result.json.tmp').write_text('{"schema_version":')
        assert read_result(attempt) is None


test_result_publication()


def test_published_result_survives_scratch_deletion():
    import json
    from supervisor.runner import read_result
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        attempt = {'domain_id': 'domain', 'job_id': 'job', 'attempt_id': 'attempt',
                   'nonce': 'nonce', 'generation': 1, 'input_sha': 'abc',
                   'role': 'reviewer', 'stage': None, 'scratch': str(scratch)}
        runner = Runner(root, fixture_command=[sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')", str(scratch / 'ready.json')])
        process = runner.launch(attempt)
        process.wait(timeout=10)
        envelope = read_result(root / 'attempts' / 'attempt')
        assert envelope['attempt_id'] == 'attempt'
        assert envelope['usage'] is None
        report = pathlib.Path(envelope['report_path'])
        (scratch / 'report').unlink()
        assert report.read_text() == '{"status":"clean"}'
        assert (root / 'attempts' / 'attempt' / 'completion.json').exists()


test_published_result_survives_scratch_deletion()


def test_heartbeat_and_bounded_logs():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        runner = Runner(root, fixture_command=[sys.executable, '-c',
                        "import sys,time; sys.stdout.write('x'*200000); sys.stdout.flush(); time.sleep(1)"])
        process = runner.launch({'attempt_id': 'logs', 'nonce': 'n'})
        attempt = root / 'attempts' / 'logs'
        deadline = time.monotonic() + 8
        while not (attempt / 'heartbeat.json').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert (attempt / 'heartbeat.json').exists()
        assert not (attempt / 'progress.json').exists()
        process.wait(timeout=10)
        assert (attempt / 'stdout.log').stat().st_size <= 65536


test_heartbeat_and_bounded_logs()


def test_cancel_preserves_uncertainty():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        runner = Runner(root, fixture_command=[sys.executable, '-c', 'import time; time.sleep(30)'])
        process = runner.launch({'attempt_id': 'cancel', 'nonce': 'n'})
        receipt = root / 'attempts' / 'cancel' / 'receipt.json'
        deadline = time.monotonic() + 8
        while not receipt.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        identity = ProcessIdentity(**json.loads(receipt.read_text())['identity'])
        foreign = ProcessIdentity(identity.boot_id, identity.pid, identity.started_at, 'foreign')
        assert runner.inspect(foreign) == 'unknown'
        assert runner.cancel(foreign, time.monotonic() + 0.1) == 'unknown'
        assert process.poll() is None
        assert runner.cancel(identity, time.monotonic() + 2) == 'unknown'
        process.wait(timeout=10)
        assert runner.inspect(identity) == 'unknown'


test_cancel_preserves_uncertainty()


def test_result_precedes_exit_without_freeing_slot():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        marker = scratch / 'ready.json'
        command = [sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')", str(marker)]
        attempt = {'domain_id': 'd', 'job_id': 'j', 'attempt_id': 'n', 'nonce': 'n',
                   'generation': 1, 'input_sha': 'abc', 'role': 'reviewer', 'stage': None, 'scratch': str(scratch)}
        barrier = root / 'release'
        runner = Runner(root, fixture_command=command, fixture_finish_barrier=barrier)
        process = runner.launch(attempt)
        result = root / 'attempts' / 'n' / 'result.json'
        deadline = time.monotonic() + 5
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert result.exists() and process.poll() is None
        assert not (result.parent / 'completion.json').exists()
        barrier.touch()
        process.wait(timeout=10)
        assert (result.parent / 'completion.json').exists()


test_result_precedes_exit_without_freeing_slot()
