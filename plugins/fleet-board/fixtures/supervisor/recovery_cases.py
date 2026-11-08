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


if __name__ == '__main__':
    unittest.main()
