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
