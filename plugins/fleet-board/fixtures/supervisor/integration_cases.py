"""Offline contracts for the serialized, recoverable repository integration lane."""
import concurrent.futures
import sys
import threading
import unittest
from pathlib import Path

from supervisor.store import Store
from supervisor.effects import Effect
from supervisor.scheduler import IntegrationLane

ROOT = Path(sys.argv.pop()).resolve()


class Authority:
    def __init__(self):
        self.state = 'in_review'
        self.head = 'a' * 40

    def validate(self, job, preconditions, intent):
        if self.state == 'human_qa':
            return False, 'Human QA holds this card'
        if intent.get('kind') == 'integration_merge' and self.head != intent.get('head_sha'):
            return False, 'PR head changed'
        return True, None


class Adapter:
    def __init__(self):
        self.external = {}
        self.merges = []
        self.verifications = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self.block = False

    def inspect(self, intent):
        return self.external.get(intent['operation_key'])

    def apply(self, intent):
        key = intent['operation_key']
        if intent['kind'] == 'integration_merge':
            self.merges.append((intent['card'], intent['head_sha']))
            self.entered.set()
            if self.block:
                self.release.wait(3)
            result = {'operation_key': key, 'merged': True, 'head_sha': intent['head_sha']}
        else:
            self.verifications.append(intent['card'])
            result = {'operation_key': key, 'commit': 'b' * 40,
                      'ok': intent.get('result_ok', True), 'results': []}
        self.external[key] = result
        return result


class IntegrationContract(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {'common_dir': str(self.root), 'board_backend': 'local',
                       'board_identity': 'fixture', 'runtime_root': str(self.root / 'runtime')}
        self.store = Store.open(self.domain, filesystem_inspector=lambda _: 'local')
        self.addCleanup(self.store.close)
        self.store.start_session({'id': 's', 'started_at': 1, 'deadline': 1000,
                                  'known_spend': 0, 'unknown_spend': False, 'budget_stop': None})
        self.set_mode('start')
        self.authority = Authority()
        self.adapter = Adapter()
        self.closed = []
        self.lane = IntegrationLane(self.store, owner_id='controller-1',
                                     close_admissions=lambda reason: self.closed.append(reason))
        self.addCleanup(self.lane.close)

    def set_mode(self, command):
        state = self.store.snapshot()
        self.store.record_command({'id': 'mode-' + str(len(state['commands'])) + '-' + command,
                                   'expected_revision': state['domain']['revision'],
                                   'actor': 'fixture', 'command': command, 'payload': {}})

    def make_effect(self, card='17', key='merge-17', kind='integration_merge', **fields):
        job_id = 'job-' + card
        if not any(job['id'] == job_id for job in self.store.snapshot()['jobs']):
            job = {'id': job_id, 'card': card, 'action': 'review', 'role': 'reviewer',
                   'stage': 'code', 'round': 1, 'input_sha': 'sha-' + card,
                   'input_version': 'v1', 'generation': 1, 'provider': 'fixture',
                   'model': 'fixture', 'nonce': 'attempt-' + card, 'session_id': 's'}
            self.store.prepare_attempt(job, self.store.snapshot()['domain']['revision'],
                                       {'global_cap': 4, 'provider_cap': 4,
                                        'paths': ['src/' + card]})
        effect = Effect(self.store, self.adapter, self.authority.validate)
        intent = {'kind': kind, **fields}
        preconditions = {'card': card, 'generation': 1, 'head': fields.get('head_sha', 'a' * 40),
                         'card_state': fields.get('card_state', 'in_review')}
        effect.prepare(key, preconditions, intent)
        return effect

    def eligible_merge(self, **overrides):
        return {'head_sha': 'a' * 40, 'merge_policy': 'auto', 'card_state': 'in_review',
                'needs_human_qa': False, 'head_current': True, 'review_clean': True,
                'review_stages_complete': True, 'dependencies_ready': True, 'ci_green': True,
                **overrides}

    def test_unrelated_review_integration_finishes_while_worker_still_runs(self):
        worker_done = threading.Event()
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.addCleanup(executor.shutdown, wait=True)
        worker = executor.submit(lambda: (threading.Event().wait(0.2), worker_done.set()))
        effect = self.make_effect('18', 'merge-18', **self.eligible_merge())
        completed = self.lane.submit(effect, mode='running')
        self.assertEqual(completed.result(timeout=2)['status'], 'observed')
        self.assertTrue(worker.running())
        self.assertFalse(worker_done.is_set())

    def test_merge_and_verification_share_one_repository_lane(self):
        self.adapter.block = True
        first = self.make_effect('17', 'merge-17', **self.eligible_merge())
        second = self.make_effect('18', 'merge-18', **self.eligible_merge())
        one = self.lane.submit(first, mode='running')
        self.assertTrue(self.adapter.entered.wait(1))
        two = self.lane.submit(second, mode='running')
        self.adapter.release.set()
        self.assertEqual(one.result(timeout=2)['status'], 'observed')
        self.assertEqual(two.result(timeout=2)['status'], 'observed')
        self.assertEqual(len(self.adapter.merges), 2)
        self.assertEqual(self.store.integration_lane(), None)

    def test_crash_after_merge_recovers_without_a_second_merge(self):
        effect = self.make_effect('17', 'merge-17', **self.eligible_merge())
        effect.inject_failure('before_observation_commit')
        self.assertEqual(self.lane.submit(effect, mode='running').result(timeout=2)['status'], 'pending')
        self.assertEqual(len(self.adapter.merges), 1)
        self.set_mode('stop')
        recovered = IntegrationLane(self.store, owner_id='controller-2',
                                    close_admissions=lambda reason: self.closed.append(reason))
        self.addCleanup(recovered.close)
        same = self.make_effect('17', 'merge-17', **self.eligible_merge())
        self.assertEqual(recovered.recover(same, mode='stopped')['status'], 'observed')
        self.assertEqual(len(self.adapter.merges), 1)
        self.assertEqual(self.store.integration_lane(), None)

    def test_main_verification_failure_closes_new_admissions(self):
        for result in (False, None, 'true'):
            with self.subTest(result=result):
                key = 'verify-' + str(result)
                effect = self.make_effect('17', key, 'main_verification',
                                          pr='91', result_ok=result)
                self.lane.submit(effect, mode='paused').result(timeout=2)
        self.assertEqual(len(self.closed), 3)

    def test_paused_or_stopped_mode_allows_verification_but_forbids_new_merge(self):
        for mode in ('paused', 'stopped'):
            self.set_mode('pause' if mode == 'paused' else 'stop')
            effect = self.make_effect('17', 'verify-' + mode, 'main_verification', pr='91')
            self.assertEqual(self.lane.submit(effect, mode=mode).result(timeout=2)['status'], 'observed')
            merge = self.make_effect('18', 'merge-' + mode, **self.eligible_merge())
            with self.assertRaisesRegex(ValueError, 'new merge'):
                self.lane.submit(merge, mode=mode)

    def test_human_qa_human_merge_policy_and_stale_heads_forbid_mutation(self):
        cases = (self.eligible_merge(card_state='human_qa'),
                 self.eligible_merge(merge_policy='human'),
                 self.eligible_merge(head_current=False),
                 self.eligible_merge(review_clean=False),
                 self.eligible_merge(review_stages_complete=False),
                 self.eligible_merge(dependencies_ready=False),
                 self.eligible_merge(ci_green=False),
                 self.eligible_merge(needs_human_qa=True))
        for index, fields in enumerate(cases):
            with self.subTest(fields=fields):
                effect = self.make_effect(str(20 + index), 'blocked-' + str(index), **fields)
                with self.assertRaises(ValueError):
                    self.lane.submit(effect, mode='running')
        self.assertEqual(self.adapter.merges, [])

    def test_cleanup_waits_for_active_quarantined_or_human_qa_work(self):
        active = {'attempts': [{'state': 'running', 'data': '{}'}], 'effects': [],
                  'card_lifecycle': {'17': 'active'}}
        quarantined = {'attempts': [{'state': 'quarantined', 'data': '{}'}], 'effects': [],
                       'card_lifecycle': {'17': 'active'}}
        human_qa = {'attempts': [], 'effects': [], 'card_lifecycle': {'17': 'human_qa'}}
        self.assertFalse(IntegrationLane.cleanup_allowed(active, '17'))
        self.assertFalse(IntegrationLane.cleanup_allowed(quarantined, '17'))
        self.assertFalse(IntegrationLane.cleanup_allowed(human_qa, '17'))
        self.assertTrue(IntegrationLane.cleanup_allowed({'attempts': [], 'effects': [],
                                                         'card_lifecycle': {'17': 'complete'}}, '17'))


if __name__ == '__main__':
    unittest.main()
