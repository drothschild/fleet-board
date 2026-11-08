"""Offline contract cases for journaled supervisor effects."""
import json
import sys
import unittest
from pathlib import Path

from supervisor.store import Store

try:
    from supervisor.effects import Effect
except ModuleNotFoundError as exc:
    if exc.name != 'supervisor.effects':
        raise
    Effect = None

ROOT = Path(sys.argv.pop()).resolve()
KINDS = ('worktree_prepare', 'branch_refresh', 'commit_publication', 'pr_create',
         'pr_update', 'report_post', 'note_update', 'card_move', 'followup_file', 'cleanup')
NON_IDEMPOTENT = {'commit_publication', 'pr_create', 'report_post', 'followup_file'}


class FakeAdapter:
    def __init__(self, kind, fail=None):
        self.kind = kind
        self.fail = fail
        self.calls = []
        self.external = {}

    def inspect(self, intent):
        return self.external.get(intent['operation_key'])

    def apply(self, intent):
        self.calls.append(intent['operation_key'])
        if self.fail == 'before':
            raise OSError('injected before mutation')
        observation = {'kind': self.kind, 'external_id': 'ext-' + intent['operation_key'],
                       'input_revision': intent.get('input_revision')}
        self.external[intent['operation_key']] = observation
        if self.fail == 'after':
            raise TimeoutError('injected after mutation')
        return observation


class Authority:
    def __init__(self, state='ready', generation=1):
        self.state, self.generation, self.checks = state, generation, []

    def validate(self, job, preconditions, intent):
        self.checks.append((job['id'], preconditions['generation'], intent['kind']))
        if job['generation'] != preconditions['generation'] or self.generation != preconditions['generation']:
            return False, 'stale generation'
        if self.state in ('deleted', 'human_qa'):
            return False, self.state
        if preconditions.get('card_state') not in (None, self.state):
            return False, 'card changed'
        if preconditions.get('head') != intent.get('head', preconditions.get('head')):
            return False, 'PR head changed'
        if preconditions.get('note_valid') is False:
            return False, 'invalid note'
        return True, None


class EffectContract(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(Effect, 'journaled effects are not implemented')
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {'common_dir': str(self.root), 'board_backend': 'local',
                       'board_identity': 'fixture', 'runtime_root': str(self.root / 'runtime')}
        self.store = Store.open(self.domain, filesystem_inspector=lambda _: 'local')
        self.addCleanup(self.store.close)
        self.store.start_session({'id': 's', 'started_at': 1, 'deadline': 1000,
                                  'known_spend': 0, 'unknown_spend': False, 'budget_stop': None})
        job = {'id': 'job-1', 'card': '17', 'action': 'review', 'role': 'reviewer',
               'stage': 'code', 'round': 1, 'input_sha': 'sha-1', 'input_version': 'v1',
               'generation': 1, 'provider': 'fixture', 'model': 'fixture', 'nonce': 'attempt-1',
               'session_id': 's'}
        self.store.prepare_attempt(job, self.store.snapshot()['domain']['revision'],
                                   {'global_cap': 1, 'provider_cap': 1, 'paths': ['src']})
        self.authority = Authority()

    def prepare(self, key, kind, adapter=None, authority=None, **fields):
        adapter = adapter or FakeAdapter(kind)
        authority = authority or self.authority
        effect = Effect(self.store, adapter, authority.validate)
        preconditions = {'card': '17', 'generation': 1, 'card_state': 'ready',
                         'head': 'head-1', 'note_valid': True}
        effect.prepare(key, preconditions, {'kind': kind, **fields})
        return effect, adapter, preconditions

    def test_supported_effects_are_explicit_and_use_controller_keys(self):
        for index, kind in enumerate(KINDS):
            with self.subTest(kind=kind):
                key = 'controller-op-' + str(index)
                effect, _, _ = self.prepare(key, kind, operation_key=key,
                                            report_text='untrusted report marker')
                row = next(row for row in self.store.snapshot()['effects'] if row['operation_key'] == key)
                self.assertEqual((row['job_id'], row['generation'], row['status']), ('job-1', 1, 'intent'))
                self.assertNotEqual(key, 'untrusted report marker')

    def test_mutation_revalidates_card_generation_head_and_note(self):
        for state, generation, overrides, message in (
            ('deleted', 1, {}, 'deleted'), ('human_qa', 1, {}, 'human_qa'),
            ('ready', 2, {}, 'stale generation'), ('ready', 1, {'note_valid': False}, 'invalid note'),
            ('ready', 1, {'head': 'head-2'}, 'PR head changed')):
            with self.subTest(state=state, generation=generation, overrides=overrides):
                self.authority.state, self.authority.generation = state, generation
                effect, adapter, preconditions = self.prepare(
                    'op-' + message.replace(' ', '-'), 'card_move')
                preconditions.update(overrides)
                result = effect.apply()
                self.assertEqual(result['status'], 'attention')
                self.assertEqual(adapter.calls, [])
                self.assertIn(message, result['reason'])
        self.authority.state, self.authority.generation = 'ready', 1

    def test_uncertain_non_idempotent_effect_enters_attention_without_replay(self):
        for kind in sorted(NON_IDEMPOTENT):
            with self.subTest(kind=kind):
                adapter = FakeAdapter(kind, fail='after')
                effect, _, _ = self.prepare('uncertain-' + kind, kind, adapter)
                self.assertEqual(effect.apply()['status'], 'attention')
                self.assertEqual(effect.reconcile()['status'], 'attention')
                self.assertEqual(adapter.calls, ['uncertain-' + kind])

    def test_duplicate_idempotent_response_reconciles_from_fresh_state(self):
        adapter = FakeAdapter('note_update', fail='after')
        effect, _, _ = self.prepare('note-op', 'note_update', adapter)
        self.assertEqual(effect.apply()['status'], 'pending')
        self.assertEqual(effect.reconcile()['status'], 'observed')
        self.assertEqual(adapter.calls, ['note-op'])
        observation = json.loads(self.store.snapshot()['effects'][0]['observation'])
        self.assertEqual(observation['external_id'], 'ext-note-op')

    def test_before_mutation_failure_revalidates_before_retry(self):
        adapter = FakeAdapter('note_update', fail='before')
        effect, _, _ = self.prepare('note-op', 'note_update', adapter)
        self.assertEqual(effect.apply()['status'], 'pending')
        self.assertEqual(effect.reconcile()['status'], 'ready')
        adapter.fail = None
        self.assertEqual(effect.apply()['status'], 'observed')
        self.assertEqual(adapter.calls, ['note-op', 'note-op'])
        self.assertGreaterEqual(len(self.authority.checks), 2)

    def test_observation_commit_failure_does_not_repeat_external_mutation(self):
        adapter = FakeAdapter('note_update')
        effect, _, _ = self.prepare('note-op', 'note_update', adapter)
        effect.inject_failure('before_observation_commit')
        self.assertEqual(effect.apply()['status'], 'pending')
        self.assertEqual(adapter.calls, ['note-op'])
        self.assertEqual(effect.reconcile()['status'], 'observed')
        self.assertEqual(adapter.calls, ['note-op'])

    def test_branch_refresh_revisions_evidence_without_spending_retry(self):
        effect, _, _ = self.prepare('refresh-op', 'branch_refresh', input_revision='validated-v2',
                                    changed_paths=['src/reviewed.py'])
        result = effect.apply()
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['input_revision'], 'validated-v2')
        self.assertEqual(result['invalidated_evidence'], ['review', 'test'])
        self.assertEqual(self.store.snapshot()['jobs'][0]['retries_used'], 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
