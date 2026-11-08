"""Recovery tests use a real store and injected process evidence."""
import sys
import unittest
from pathlib import Path
from supervisor.store import Store

try:
    from supervisor.recovery import Recovery
except ModuleNotFoundError as exc:
    if exc.name != 'supervisor.recovery':
        raise
    Recovery = None

ROOT = Path(sys.argv.pop()).resolve()


class RecoveryContract(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {'common_dir': str(self.root), 'board_backend': 'local',
                       'board_identity': 'fixture', 'runtime_root': str(self.root / 'runtime')}
        self.store = Store.open(self.domain, filesystem_inspector=lambda _: 'local')
        self.addCleanup(self.store.close)
        self.store.start_session({'id': 's', 'started_at': 1, 'deadline': 1000,
                                  'known_spend': 0, 'unknown_spend': False, 'budget_stop': None})
        job = {'id': 'j', 'card': '1', 'action': 'review', 'role': 'reviewer', 'stage': 'code',
               'round': 1, 'input_sha': 'abc', 'input_version': 'v1', 'generation': 1,
               'provider': 'p', 'model': 'm', 'nonce': 'n', 'session_id': 's'}
        self.store.prepare_attempt(job, self.store.snapshot()['domain']['revision'],
                                   {'global_cap': 1, 'provider_cap': 1, 'paths': ['src']})

    def test_unacknowledged_prepared_launch_is_quarantined_without_relaunch(self):
        self.assertIsNotNone(Recovery, 'recovery engine is not implemented')
        class Inspector:
            def inspect(self, attempt):
                return {'status': 'unknown'}
            def signal(self, *args):
                raise AssertionError('uncertain identity must not be signalled')
        recovery = Recovery(self.store, Inspector())
        recovery.reconcile(now=10)
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot['attempts'][0]['state'], 'quarantined')
        self.assertEqual(len(snapshot['attempts']), 1)
        self.assertEqual(len(snapshot['claims']), 1)
        self.assertEqual(snapshot['jobs'][0]['retries_used'], 0)


    def test_real_runner_publication_is_recovered_without_relaunch(self):
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        command = [sys.executable, '-c',
                   "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')",
                   str(scratch / 'ready.json')]
        process = Runner(self.store.directory, fixture_command=command).launch(
            prepared_from_store(self.store, 'n', scratch))
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 0)
        import inspect
        self.assertIsNot(inspect.signature(Recovery).parameters['inspector'].default, inspect.Parameter.empty,
                         'native recovery adapter is unavailable')
        Recovery(self.store).reconcile(now=10)
        snapshot = self.store.snapshot()
        self.assertEqual(len(snapshot['results']), 1)
        self.assertEqual(snapshot['results'][0]['disposition'], 'current')
        self.assertEqual(snapshot['attempts'][0]['state'], 'result_ready')
        self.assertEqual(len(snapshot['claims']), 1)
        self.assertEqual(len(snapshot['attempts']), 1)
        Recovery(self.store).reconcile(now=11)
        self.assertEqual(len(self.store.snapshot()['results']), 1)

    def test_result_ready_live_runner_still_respects_hard_deadline(self):
        import json
        import time
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        barrier = self.root / 'release'
        command = [sys.executable, '-c',
                   "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')",
                   str(scratch / 'ready.json')]
        process = Runner(self.store.directory, fixture_command=command, fixture_finish_barrier=barrier).launch(
            prepared_from_store(self.store, 'n', scratch))
        try:
            result = self.store.directory / 'attempts' / 'n' / 'result.json'
            limit = time.monotonic() + 8
            while not result.exists() and time.monotonic() < limit:
                time.sleep(.02)
            self.assertTrue(result.exists())
            self.store.update_attempt('n', {'state': 'running', 'deadline': 10}, self.store.snapshot()['domain']['revision'])
            Recovery(self.store).reconcile(now=10)
            snapshot = self.store.snapshot()
            self.assertEqual(len(snapshot['results']), 1)
            self.assertEqual(snapshot['attempts'][0]['state'], 'cancel_requested')
            self.assertEqual(snapshot['jobs'][0]['generation'], 2)
            control = json.loads((result.parent / 'control.json').read_text())
            self.assertEqual(control, {'nonce': 'n', 'signal': 'TERM'})
            self.assertEqual(len(snapshot['claims']), 1)
        finally:
            barrier.write_text('release')
            process.wait(timeout=5)

    def test_published_result_is_recorded_when_receipt_is_unavailable(self):
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        command = [sys.executable, '-c',
                   "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')",
                   str(scratch / 'ready.json')]
        process = Runner(self.store.directory, fixture_command=command).launch(
            prepared_from_store(self.store, 'n', scratch))
        process.wait(timeout=10)
        (self.store.directory / 'attempts' / 'n' / 'receipt.json').unlink()
        Recovery(self.store).reconcile(now=10)
        self.assertEqual(len(self.store.snapshot()['results']), 1)
        self.assertEqual(len(self.store.snapshot()['claims']), 1)

    def test_quarantined_attempt_still_records_late_durable_result_as_evidence(self):
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        command = [sys.executable, '-c',
                   "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')",
                   str(scratch / 'ready.json')]
        prepared = prepared_from_store(self.store, 'n', scratch)
        self.store.quarantine_attempt('n', 'uncertain', self.store.snapshot()['domain']['revision'])
        process = Runner(self.store.directory, fixture_command=command).launch(prepared)
        process.wait(timeout=10)
        Recovery(self.store).reconcile(now=10)
        snapshot = self.store.snapshot()
        self.assertEqual(len(snapshot['results']), 1)
        self.assertEqual(snapshot['results'][0]['disposition'], 'stale')
        self.assertEqual(snapshot['attempts'][0]['state'], 'quarantined')
        self.assertEqual(len(snapshot['claims']), 1)

    def test_native_inspector_rejects_receipt_bound_to_foreign_domain(self):
        import json
        import time
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        process = Runner(self.store.directory, fixture_command=[sys.executable, '-c', 'import time; time.sleep(1)']).launch(
            prepared_from_store(self.store, 'n', scratch))
        try:
            path = self.store.directory / 'attempts' / 'n'
            deadline = time.monotonic() + 8
            while not (path / 'receipt.json').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((path / 'receipt.json').exists())
            before = self.store.snapshot()
            Recovery(self.store).reconcile(now=10)
            self.assertEqual(self.store.snapshot(), before, 'matching live runner must be adopted')
            prepared = json.loads((path / 'prepared.json').read_text())
            prepared['domain_id'] = 'foreign'
            (path / 'prepared.json').write_text(json.dumps(prepared))
            Recovery(self.store).reconcile(now=10)
            self.assertEqual(self.store.snapshot()['attempts'][0]['state'], 'quarantined')
            self.assertEqual(len(self.store.snapshot()['claims']), 1)
        finally:
            process.wait(timeout=10)

    def test_native_inspection_does_not_wait_for_publication_lock(self):
        import fcntl
        import json
        import threading
        from supervisor.recovery import NativeInspector
        from supervisor.runner import prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        path = self.store.directory / 'attempts' / 'n'
        path.mkdir(parents=True)
        (path / 'prepared.json').write_text(json.dumps(prepared_from_store(self.store, 'n', scratch)))
        results = []
        with (path / 'publication.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            attempt = self.store.snapshot()['attempts'][0]
            worker = threading.Thread(target=lambda: results.append(NativeInspector(
                self.store.directory, self.store.domain_id).inspect(attempt)))
            worker.start()
            worker.join(timeout=.5)
            finished = not worker.is_alive()
            fcntl.flock(lock, fcntl.LOCK_UN)
            worker.join(timeout=5)
        self.assertTrue(finished, 'inspection blocked on publication lock')
        self.assertEqual(results[0]['status'], 'unknown')

    def test_native_boot_change_releases_old_execution_but_preserves_scope(self):
        import json
        import time
        from unittest import mock
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        process = Runner(self.store.directory, fixture_command=[sys.executable, '-c', 'import time; time.sleep(.3)']).launch(
            prepared_from_store(self.store, 'n', scratch))
        receipt = self.store.directory / 'attempts' / 'n' / 'receipt.json'
        limit = time.monotonic() + 8
        while not receipt.exists() and time.monotonic() < limit:
            time.sleep(.02)
        self.assertTrue(receipt.exists())
        identity = json.loads(receipt.read_text())['identity']
        process.wait(timeout=5)
        self.store.update_attempt('n', {'state': 'running', 'boot_id': identity['boot_id'], 'process_identity': identity},
                                  self.store.snapshot()['domain']['revision'])
        with mock.patch('supervisor.processes._boot_id', return_value='new-boot'), \
             mock.patch('supervisor.store._boot_id', return_value='new-boot'):
            Recovery(self.store).reconcile(now=10)
        snapshot = self.store.snapshot()
        self.assertTrue(json.loads(snapshot['attempts'][0]['data']).get('execution_released'))
        self.assertTrue(snapshot['sessions'][0]['unknown_spend'])
        self.assertEqual(snapshot['jobs'][0]['retries_used'], 0)
        self.assertEqual(len(snapshot['claims']), 1)

    def test_confirmed_fixture_stop_schedules_one_retry_across_restart(self):
        import json
        import time
        from supervisor.models import StopEvidence, RetryEvidence
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        process = Runner(self.store.directory, fixture_command=[sys.executable, '-c', 'import time; time.sleep(.3)']).launch(
            prepared_from_store(self.store, 'n', scratch))
        receipt = self.store.directory / 'attempts' / 'n' / 'receipt.json'
        limit = time.monotonic() + 8
        while not receipt.exists() and time.monotonic() < limit:
            time.sleep(.02)
        self.assertTrue(receipt.exists())
        identity = json.loads(receipt.read_text())['identity']
        process.wait(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.store.update_attempt('n', {'state': 'running', 'boot_id': identity['boot_id'], 'process_identity': identity},
                                  self.store.snapshot()['domain']['revision'])
        self.store.request_cancellation('n', 'infra', 'infrastructure', self.store.snapshot()['domain']['revision'], now=10)
        proof = StopEvidence(domain_id=self.store.domain_id, job_id='j', attempt_id='n', generation=1,
                             boot_id=identity['boot_id'], pid=identity['pid'], started_at=identity['started_at'],
                             nonce=identity['nonce'], kind='fixture_complete_tree', free_fixture=True)
        eligible = RetryEvidence(domain_id=self.store.domain_id, job_id='j', attempt_id='n', generation=1)
        trusted = Store.open(self.domain, filesystem_inspector=lambda _: 'local',
                             stop_evidence_verifier=lambda candidate: candidate == proof,
                             retry_evidence_verifier=lambda candidate: candidate == eligible)
        self.addCleanup(trusted.close)
        class Inspector:
            def inspect(self, attempt):
                return {'status': 'stopped', 'stop_evidence': proof, 'retry_evidence': eligible}
        Recovery(trusted, Inspector(), settings={'retry_backoff_seconds': 5}).reconcile(now=11)
        scheduled = trusted.snapshot()
        self.assertEqual(scheduled['jobs'][0]['state'], 'retry_wait')
        self.assertEqual(scheduled['jobs'][0]['retries_used'], 1)
        self.assertEqual(len(scheduled['claims']), 1)
        self.assertTrue(json.loads(scheduled['attempts'][0]['data'])['execution_released'])
        Recovery(trusted, Inspector(), settings={'retry_backoff_seconds': 5}).reconcile(now=12)
        self.assertEqual(trusted.snapshot(), scheduled)

    def test_real_managed_resistant_child_receives_kill_after_grace(self):
        import os
        import signal
        import time
        from supervisor.processes import identity_for
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        pidfile = scratch / 'child.pid'
        script = "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        process = Runner(self.store.directory, fixture_command=[sys.executable, '-c', script, str(pidfile)]).launch(
            prepared_from_store(self.store, 'n', scratch))
        child = None
        try:
            limit = time.monotonic() + 8
            while not pidfile.exists() and time.monotonic() < limit:
                time.sleep(.02)
            self.assertTrue(pidfile.exists())
            child = identity_for(int(pidfile.read_text()), 'fixture-child')
            self.store.update_attempt('n', {'state': 'running', 'deadline': 10},
                                      self.store.snapshot()['domain']['revision'])
            settings = {'shutdown_grace_seconds': 5}
            Recovery(self.store, settings=settings).reconcile(now=10)
            time.sleep(.4)
            self.assertIsNone(process.poll(), 'trusted monitor died before escalation')
            self.assertEqual(identity_for(child.pid, child.nonce), child)
            Recovery(self.store, settings=settings).reconcile(now=15)
            process.wait(timeout=5)
            with self.assertRaises(OSError):
                identity_for(child.pid, child.nonce)
        finally:
            if child is not None:
                try:
                    if identity_for(child.pid, child.nonce) == child:
                        os.kill(child.pid, signal.SIGKILL)
                except (OSError, ValueError):
                    pass
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)

    def test_real_term_resistant_child_keeps_uncertain_occupancy(self):
        import os
        import signal
        import time
        from supervisor.processes import identity_for
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        pidfile = scratch / 'child.pid'
        child_script = "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        script = "import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(30)"
        process = Runner(self.store.directory, fixture_command=[sys.executable, '-c', script, child_script, str(pidfile)]).launch(
            prepared_from_store(self.store, 'n', scratch))
        child = None
        try:
            limit = time.monotonic() + 8
            while not pidfile.exists() and time.monotonic() < limit:
                time.sleep(.02)
            self.assertTrue(pidfile.exists())
            child = identity_for(int(pidfile.read_text()), 'fixture-child')
            self.store.update_attempt('n', {'state': 'running', 'deadline': 10},
                                      self.store.snapshot()['domain']['revision'])
            Recovery(self.store).reconcile(now=10)
            process.wait(timeout=5)
            Recovery(self.store).reconcile(now=11)
            snapshot = self.store.snapshot()
            self.assertEqual(snapshot['attempts'][0]['state'], 'quarantined')
            self.assertEqual(snapshot['jobs'][0]['retries_used'], 0)
            self.assertEqual(len(snapshot['claims']), 1)
            self.assertEqual(identity_for(child.pid, child.nonce), child)
        finally:
            if child is not None:
                try:
                    if identity_for(child.pid, child.nonce) == child:
                        os.kill(child.pid, signal.SIGKILL)
                except (OSError, ValueError):
                    pass
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)

    def test_hard_deadline_fences_before_term_then_kills_after_persisted_grace(self):
        class Inspector:
            def __init__(self, store):
                self.store, self.signals = store, []
            def inspect(self, attempt):
                return {'status': 'alive'}
            def signal(self, attempt, kind):
                snapshot = self.store.snapshot()
                assert snapshot['jobs'][0]['generation'] == 2
                assert snapshot['attempts'][0]['state'] == 'cancel_requested'
                self.signals.append(kind)
        self.store.update_attempt('n', {'state': 'running', 'heartbeat': 10, 'progress': 10, 'deadline': 20},
                                  self.store.snapshot()['domain']['revision'])
        inspector = Inspector(self.store)
        Recovery(self.store, inspector, settings={'shutdown_grace_seconds': 5}).reconcile(now=20)
        self.assertEqual(inspector.signals, ['TERM'])
        self.assertEqual(self.store.snapshot()['jobs'][0]['retries_used'], 0)
        Recovery(self.store, inspector, settings={'shutdown_grace_seconds': 5}).reconcile(now=24)
        self.assertNotIn('KILL', inspector.signals)
        Recovery(self.store, inspector, settings={'shutdown_grace_seconds': 5}).reconcile(now=25)
        self.assertEqual(inspector.signals[-1], 'KILL')
        self.assertEqual(len(self.store.snapshot()['claims']), 1)

    def test_matching_live_runner_is_adopted_and_unknown_running_runner_is_quarantined(self):
        class Inspector:
            def __init__(self, status):
                self.status = status
            def inspect(self, attempt):
                return {'status': self.status}
        self.store.update_attempt('n', {'state': 'running', 'heartbeat': 9, 'progress': 9, 'deadline': 100},
                                  self.store.snapshot()['domain']['revision'])
        before = self.store.snapshot()
        Recovery(self.store, Inspector('alive')).reconcile(now=10)
        self.assertEqual(self.store.snapshot(), before)
        Recovery(self.store, Inspector('unknown')).reconcile(now=10)
        after = self.store.snapshot()
        self.assertEqual(after['attempts'][0]['state'], 'quarantined')
        self.assertEqual(len(after['claims']), 1)
        self.assertEqual(after['jobs'][0]['retries_used'], 0)



if __name__ == '__main__':
    unittest.main()
