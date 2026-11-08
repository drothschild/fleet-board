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

    def test_quarantined_attempt_still_records_late_durable_result_as_evidence(self):
        from supervisor.runner import Runner, prepared_from_store
        scratch = self.root / 'scratch'
        scratch.mkdir()
        (scratch / 'report').write_text('{"status":"clean"}')
        command = [sys.executable, '-c',
                   "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('{\"exit_code\":0}')",
                   str(scratch / 'ready.json')]
        prepared = prepared_from_store(self.store, 'n', scratch)
        self.store.update_attempt('n', {'state': 'quarantined'}, self.store.snapshot()['domain']['revision'])
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
