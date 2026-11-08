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
        directory = pathlib.Path(tmp).resolve()
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
        conflicting = runner.launch({'attempt_id':'a','nonce':'different'})
        conflicting.wait(timeout=10)
        assert conflicting.returncode != 0
        reused = runner.launch({'attempt_id':'other','nonce':'n'})
        reused.wait(timeout=10)
        assert reused.returncode != 0
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
                   'nonce': 'attempt', 'session_id': 's', 'generation': 1, 'input_sha': 'abc',
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
        sibling = root / 'attempts' / 'incomplete'
        sibling.mkdir()
        assert runner.inspect(identity) == 'alive'
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
                   'generation': 1, 'input_sha': 'abc', 'role': 'reviewer', 'stage': None, 'session_id': 's', 'scratch': str(scratch)}
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


def test_launcher_exit_and_descriptor_closure():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        lock = root / 'controller.lock'
        marker = root / 'worker-acquired'
        worker = "import fcntl,os,sys,time; time.sleep(.5); f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB); fd=int(sys.argv[3]); expected=int(sys.argv[4]);\ntry: actual=os.fstat(fd).st_ino\nexcept OSError: actual=-1\nassert actual != expected; open(sys.argv[2],'w').write('ok')"
        launcher = "import fcntl,os,socket,sys; from supervisor.runner import Runner; f=open(sys.argv[2],'a'); fcntl.flock(f,fcntl.LOCK_EX); os.set_inheritable(f.fileno(),True); sock,peer=socket.socketpair(); os.set_inheritable(sock.fileno(),True); Runner(sys.argv[1],fixture_command=[sys.executable,'-c',sys.argv[4],sys.argv[2],sys.argv[3],str(sock.fileno()),str(os.fstat(sock.fileno()).st_ino)]).launch({'attempt_id':'child','nonce':'n'})"
        env = dict(os.environ, PYTHONPATH=str(ROOT / 'scripts'), PYTHONDONTWRITEBYTECODE='1')
        parent = subprocess.Popen([sys.executable, '-c', launcher, str(root), str(lock), str(marker), worker], env=env)
        parent.wait(timeout=10)
        assert parent.returncode == 0
        deadline = time.monotonic() + 8
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert marker.read_text() == 'ok'


test_launcher_exit_and_descriptor_closure()


def test_controller_killed_before_acknowledgement():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        marker = root / 'invocations'
        fixture = pathlib.Path(__file__).with_name('fake_worker.py')
        code = "import sys,time; from supervisor.runner import Runner; Runner(sys.argv[1],fixture_command=[sys.executable,sys.argv[2],sys.argv[3],'0.5']).launch({'attempt_id':'a','nonce':'n'}); print('launched',flush=True); time.sleep(30)"
        env = dict(os.environ, PYTHONPATH=str(ROOT / 'scripts'), PYTHONDONTWRITEBYTECODE='1')
        parent = subprocess.Popen([sys.executable, '-c', code, str(root), str(fixture), str(marker)], env=env, stdout=subprocess.PIPE, text=True)
        assert parent.stdout.readline().strip() == 'launched'
        parent.kill()
        parent.wait(timeout=5)
        deadline = time.monotonic() + 8
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert marker.read_text().splitlines() == ['invoked']
        duplicate = Runner(root, fixture_command=[sys.executable, str(fixture), str(marker), '0']).launch({'attempt_id':'a','nonce':'n'})
        duplicate.wait(timeout=10)
        assert marker.read_text().splitlines() == ['invoked']
        deadline = time.monotonic() + 8
        while not (root / 'attempts' / 'a' / 'stdout.log').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        time.sleep(.8)


test_controller_killed_before_acknowledgement()


def test_store_integration_retains_claim():
    from supervisor.store import Store
    from supervisor.runner import prepared_from_store, read_result
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        domain = {'common_dir': str(root), 'board_backend': 'local', 'board_identity': 'fixture', 'runtime_root': str(root / 'runtime')}
        store = Store.open(domain, filesystem_inspector=lambda _: 'local')
        try:
            store.start_session({'id':'s','started_at':1,'deadline':100,'known_spend':0,'unknown_spend':False,'budget_stop':None})
            job = {'id':'j','card':'1','action':'review','role':'reviewer','stage':'code','round':1,'input_sha':'abc','input_version':'v1','generation':1,'provider':'p','model':'m','nonce':'n','session_id':'s'}
            store.prepare_attempt(job, store.snapshot()['domain']['revision'], {'global_cap':1,'provider_cap':1,'paths':['src']})
            scratch = root / 'scratch'
            scratch.mkdir()
            (scratch / 'report').write_text('{"status":"clean"}')
            command = [sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')", str(scratch / 'ready.json')]
            barrier = root / 'release'
            runner = Runner(store.directory, fixture_command=command, fixture_finish_barrier=barrier)
            process = runner.launch(prepared_from_store(store, 'n', scratch))
            attempt = store.directory / 'attempts' / 'n'
            deadline = time.monotonic() + 8
            while read_result(attempt) is None and time.monotonic() < deadline:
                time.sleep(.05)
            envelope = read_result(attempt)
            assert process.poll() is None
            store.record_result(envelope)
            assert len(store.snapshot()['claims']) == 1
            barrier.touch()
            process.wait(timeout=10)
        finally:
            store.close()


test_store_integration_retains_claim()


def test_reject_unsafe_launch_root():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        alias = root / 'alias'
        target = root / 'target'
        target.mkdir(mode=0o700)
        alias.symlink_to(target, target_is_directory=True)
        runner = Runner(alias, fixture_command=[sys.executable, '-c', 'pass'])
        try:
            runner.launch({'attempt_id':'a','nonce':'n'})
        except ValueError:
            pass
        else:
            raise AssertionError('symlinked launch root accepted')


test_reject_unsafe_launch_root()


def test_structured_progress_is_separate():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        marker = scratch / 'progress.json'
        code = "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('{\"sequence\":1,\"kind\":\"checkpoint\"}'); time.sleep(1)"
        runner = Runner(root, fixture_command=[sys.executable, '-c', code, str(marker)])
        process = runner.launch({'attempt_id':'a','nonce':'n','scratch':str(scratch)})
        progress = root / 'attempts' / 'a' / 'progress.json'
        deadline = time.monotonic() + 8
        while not progress.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert json.loads(progress.read_text()) == {'sequence':1,'kind':'checkpoint'}
        assert (progress.parent / 'heartbeat.json').exists()
        process.wait(timeout=10)


test_structured_progress_is_separate()


def test_corrupt_published_result_is_ignored():
    from supervisor.runner import read_result
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        attempt = root / 'attempt'
        attempt.mkdir()
        (attempt / 'result.json').write_text('{"schema_version":1}')
        assert read_result(attempt) is None
        (attempt / 'result.json').write_text('{')
        assert read_result(attempt) is None


test_corrupt_published_result_is_ignored()


def test_resume_publication_after_ingest_without_worker():
    from supervisor.runner import read_result
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        marker = scratch / 'ready.json'
        command = [sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')", str(marker)]
        barrier = root / 'publish'
        attempt = {'domain_id':'d','job_id':'j','attempt_id':'n','nonce':'n','generation':1,'input_sha':'abc','role':'reviewer','stage':None,'session_id':'s','scratch':str(scratch)}
        runner = Runner(root, fixture_command=command, fixture_publication_barrier=barrier)
        process = runner.launch(attempt)
        durable = root / 'artifacts' / 'n' / 'report'
        deadline = time.monotonic() + 8
        while not durable.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert durable.exists() and process.poll() is None
        process.kill()
        process.wait(timeout=5)
        (scratch / 'report').unlink()
        (scratch / 'ready.json').unlink()
        assert read_result(root / 'attempts' / 'n') is None
        (root / 'attempts' / 'n' / '.result.json-stale').write_text('{')
        exit_path = root / 'attempts' / 'n' / 'exit.json'
        saved_exit = exit_path.read_text()
        exit_path.unlink()
        try:
            runner.resume_publication('n')
        except (OSError, ValueError):
            pass
        else:
            raise AssertionError('missing exit receipt accepted')
        exit_path.write_text(saved_exit)
        runner.resume_publication('n')
        result = read_result(root / 'attempts' / 'n')
        assert result and result['exit_code'] == 0
        runner.resume_publication('n')
        assert read_result(root / 'attempts' / 'n') == result


test_resume_publication_after_ingest_without_worker()


def test_incomplete_binding_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        runner = Runner(pathlib.Path(tmp).resolve(), fixture_command=[sys.executable, '-c', 'pass'])
        try:
            runner.launch({'attempt_id':'a','nonce':'a','domain_id':'domain'})
        except ValueError:
            pass
        else:
            raise AssertionError('incomplete prepared binding accepted')


test_incomplete_binding_rejected()


def test_parent_directories_synced_before_execution_and_ingest():
    from unittest.mock import patch
    import supervisor.runner as runner_module
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        marker = scratch / 'ready.json'
        command = [sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')", str(marker)]
        prepared = {'domain_id':'d','job_id':'j','attempt_id':'n','nonce':'n','generation':1,'input_sha':'abc','role':'reviewer','stage':None,'session_id':'s','scratch':str(scratch)}
        config = {'directory':str(root), 'attempt_id':'n', 'nonce':'n', 'prepared':prepared,
                  'fixture_command':command, 'fixture_finish_barrier':None, 'fixture_publication_barrier':None}
        sync = runner_module._sync_directory
        popen = runner_module.subprocess.Popen
        ingest = runner_module.ingest_artifacts
        synced = []
        def record_sync(path):
            synced.append((pathlib.Path(path), (root / 'nonces').exists(), (root / 'attempts').exists(), (root / 'artifacts').exists()))
            sync(path)
        def launch(*args, **kwargs):
            assert (root, True, False, False) in synced, 'runner root not synced after nonce directory creation'
            assert (root, True, True, False) in synced, 'runner root not synced after attempt directory creation'
            return popen(*args, **kwargs)
        def copy(*args, **kwargs):
            assert (root, True, True, True) in synced, 'runner root not synced after artifact directory creation'
            return ingest(*args, **kwargs)
        with patch.object(runner_module, '_sync_directory', side_effect=record_sync), \
             patch.object(runner_module.subprocess, 'Popen', side_effect=launch), \
             patch.object(runner_module, 'ingest_artifacts', side_effect=copy):
            runner_module._run(config)
        assert runner_module.read_result(root / 'attempts' / 'n') is not None


test_parent_directories_synced_before_execution_and_ingest()


def test_fifo_ready_rejected_without_blocking():
    import json
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        os.mkfifo(scratch / 'ready.json')
        attempt = root / 'attempts' / 'n'
        attempt.mkdir(parents=True)
        prepared = {'domain_id':'d','job_id':'j','attempt_id':'n','nonce':'n','generation':1,'input_sha':'abc','role':'reviewer','stage':None,'session_id':'s','scratch':str(scratch)}
        (attempt / 'prepared.json').write_text(json.dumps(prepared))
        (attempt / 'exit.json').write_text('{"exit_code":0}')
        code = "import sys; from supervisor.runner import Runner; Runner(sys.argv[1]).resume_publication('n')"
        env = dict(os.environ, PYTHONPATH=str(ROOT / 'scripts'), PYTHONDONTWRITEBYTECODE='1')
        process = subprocess.Popen([sys.executable, '-c', code, str(root)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=3)
            assert process.returncode != 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


def test_fifo_progress_does_not_stop_heartbeat():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp).resolve()
        scratch = root / 'scratch'
        scratch.mkdir()
        os.mkfifo(scratch / 'progress.json')
        runner = Runner(root, fixture_command=[sys.executable, '-c', 'import time; time.sleep(2)'])
        process = runner.launch({'attempt_id':'a','nonce':'n','scratch':str(scratch)})
        try:
            heartbeat = root / 'attempts' / 'a' / 'heartbeat.json'
            deadline = time.monotonic() + 5
            while not heartbeat.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            assert heartbeat.exists(), 'FIFO progress blocked heartbeat'
            first = heartbeat.read_bytes()
            deadline = time.monotonic() + 1
            while heartbeat.read_bytes() == first and time.monotonic() < deadline:
                time.sleep(.05)
            assert heartbeat.read_bytes() != first, 'FIFO progress stopped heartbeat updates'
            process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


test_fifo_progress_does_not_stop_heartbeat()
test_fifo_ready_rejected_without_blocking()
