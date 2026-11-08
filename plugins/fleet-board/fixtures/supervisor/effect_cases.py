"""Offline contract cases for journaled supervisor effects."""
import json
import hashlib
import sys
import unittest
from pathlib import Path

from supervisor.store import Store

try:
    from supervisor.effects import BoundedScriptAdapter, Effect
except ModuleNotFoundError as exc:
    if exc.name != 'supervisor.effects':
        raise
    BoundedScriptAdapter = None
    Effect = None

ROOT = Path(sys.argv.pop()).resolve()
KINDS = ('worktree_prepare', 'branch_refresh', 'commit_publication', 'pr_create',
         'pr_update', 'report_post', 'note_update', 'card_move', 'followup_file', 'cleanup')
NON_IDEMPOTENT = {'branch_refresh', 'commit_publication', 'pr_create', 'report_post', 'followup_file'}


class FakeAdapter:
    def __init__(self, kind, fail=None):
        self.kind = kind
        self.fail = fail
        self.calls = []
        self.inspected = []
        self.applied = []
        self.external = {}

    def inspect(self, intent):
        self.inspected.append(dict(intent))
        return self.external.get(intent['operation_key'])

    def apply(self, intent):
        self.calls.append(intent['operation_key'])
        self.applied.append(dict(intent))
        if self.fail == 'before':
            raise OSError('injected before mutation')
        observation = {'operation_key': intent['operation_key'], 'kind': self.kind,
                       'external_id': 'ext-' + intent['operation_key'],
                       'input_revision': intent.get('input_revision')}
        if self.kind == 'branch_refresh':
            observation['input_evidence'] = intent.get('input_evidence')
            observation['invalidated_evidence'] = intent.get('invalidated_evidence')
        self.external[intent['operation_key']] = observation
        if self.fail == 'after':
            raise TimeoutError('injected after mutation')
        return observation


def refresh_fields(path='src/reviewed.py'):
    evidence = {'job_id': 'job-1', 'generation': 1, 'head_sha': 'a' * 40,
                'input_sha': 'b' * 64, 'changed_paths': [path]}
    revision = hashlib.sha256(json.dumps(evidence, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'input_revision': revision, 'input_evidence': evidence, 'changed_paths': [path],
            'invalidated_evidence': ['review']}


class Authority:
    def __init__(self, state='ready', generation=1):
        self.state, self.generation, self.checks = state, generation, []
        self.head = 'head-1'

    def validate(self, job, preconditions, intent):
        self.checks.append((job['id'], preconditions['generation'], intent['kind']))
        if job['generation'] != preconditions['generation'] or self.generation != preconditions['generation']:
            return False, 'stale generation'
        if self.state in ('deleted', 'human_qa'):
            return False, self.state
        if preconditions.get('card_state') not in (None, self.state):
            return False, 'card changed'
        if preconditions.get('head') != self.head:
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

    def prepare(self, key, kind, adapter=None, authority=None, precondition_overrides=None, **fields):
        adapter = adapter or FakeAdapter(kind)
        authority = authority or self.authority
        effect = Effect(self.store, adapter, authority.validate)
        preconditions = {'card': '17', 'generation': 1, 'card_state': 'ready',
                         'head': 'head-1', 'note_valid': True, **(precondition_overrides or {})}
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

    def test_effect_target_is_bound_before_journaling_or_helper_calls(self):
        before = self.store.snapshot()['effects']
        adapter = FakeAdapter('card_move')
        effect = Effect(self.store, adapter, self.authority.validate)
        with self.assertRaisesRegex(ValueError, 'card'):
            effect.prepare('wrong-card', {'card': '17', 'generation': 1},
                           {'kind': 'card_move', 'card': '18', 'state': 'ready'})
        self.assertEqual(self.store.snapshot()['effects'], before)
        self.assertEqual(adapter.calls, [])

        effect, adapter, _ = self.prepare('bound-card', 'card_move', state='ready')
        row = next(item for item in self.store.snapshot()['effects']
                   if item['operation_key'] == 'bound-card')
        self.assertEqual(json.loads(row['intent'])['card'], '17')
        self.assertEqual(effect.apply()['status'], 'observed')
        self.assertEqual(adapter.inspected[-1]['card'], '17')
        self.assertEqual(adapter.applied[-1]['card'], '17')

    def test_mutation_revalidates_card_generation_head_and_note(self):
        for state, generation, overrides, message in (
            ('deleted', 1, {}, 'deleted'), ('human_qa', 1, {}, 'human_qa'),
            ('ready', 2, {}, 'stale generation'), ('ready', 1, {'note_valid': False}, 'invalid note'),
            ('ready', 1, {'head': 'head-2'}, 'PR head changed')):
            with self.subTest(state=state, generation=generation, overrides=overrides):
                self.authority.state, self.authority.generation = state, generation
                effect, adapter, _ = self.prepare(
                    'op-' + message.replace(' ', '-'), 'card_move',
                    precondition_overrides=overrides)
                result = effect.apply()
                self.assertEqual(result['status'], 'attention')
                self.assertEqual(adapter.calls, [])
                self.assertIn(message, result['reason'])
        self.authority.state, self.authority.generation = 'ready', 1

    def test_human_qa_arriving_during_preflight_blocks_mutation(self):
        authority = Authority()
        class ArrivingQAAdapter(FakeAdapter):
            def inspect(self, intent):
                authority.state = 'human_qa'
                return super().inspect(intent)
        adapter = ArrivingQAAdapter('card_move')
        effect, _, _ = self.prepare('qa-race', 'card_move', adapter, authority)
        result = effect.apply()
        self.assertEqual(result['status'], 'attention')
        self.assertEqual(result['reason'], 'human_qa')
        self.assertEqual(adapter.calls, [])
        self.assertEqual(len(authority.checks), 2)

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

    def test_duplicate_report_and_create_responses_match_controller_marker(self):
        for kind in ('report_post', 'pr_create'):
            with self.subTest(kind=kind):
                key = 'duplicate-' + kind
                adapter = FakeAdapter(kind)
                adapter.external[key] = {'operation_key': key, 'kind': kind,
                                         'external_id': 'ext-' + key}
                effect, _, _ = self.prepare(key, kind, adapter)
                result = effect.apply()
                self.assertEqual(result['status'], 'observed')
                self.assertEqual(adapter.calls, [])

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

    def test_fault_boundaries_cover_every_external_mutation(self):
        ordered_kinds = [kind for kind in KINDS if kind != 'branch_refresh'] + ['branch_refresh']
        for index, kind in enumerate(ordered_kinds):
            with self.subTest(kind=kind):
                key = 'boundary-' + str(index)
                fields = refresh_fields('src/change.py') if kind == 'branch_refresh' else {}
                before, before_adapter, _ = self.prepare(key + '-before', kind, **fields)
                before.inject_failure('before_mutation')
                self.assertEqual(before.apply()['status'], 'pending')
                self.assertEqual(before_adapter.calls, [])

                after_adapter = FakeAdapter(kind)
                after, _, _ = self.prepare(key + '-after', kind, after_adapter, **fields)
                after.inject_failure('after_mutation')
                result = after.apply()
                self.assertEqual(result['status'], 'attention' if kind in NON_IDEMPOTENT else 'pending')
                self.assertEqual(after_adapter.calls, [key + '-after'])

                observe_adapter = FakeAdapter(kind)
                observe, _, _ = self.prepare(key + '-observe', kind, observe_adapter, **fields)
                observe.inject_failure('before_observation_commit')
                self.assertEqual(observe.apply()['status'], 'pending')
                self.assertEqual(observe_adapter.calls, [key + '-observe'])
                self.assertEqual(observe.reconcile()['status'], 'observed')
                self.assertEqual(observe_adapter.calls, [key + '-observe'])

    def test_branch_refresh_revisions_evidence_without_spending_retry(self):
        self.store.increment_retry('job-1', self.store.snapshot()['domain']['revision'])
        effect, adapter, preconditions = self.prepare('refresh-op', 'branch_refresh',
                                                       **refresh_fields())
        result = effect.apply()
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['input_revision'], refresh_fields()['input_revision'])
        self.assertEqual(result['invalidated_evidence'], ['review'])
        snapshot = self.store.snapshot()
        stored = json.loads(next(row for row in snapshot['effects']
                                 if row['operation_key'] == 'refresh-op')['observation'])
        self.assertEqual(stored['input_revision'], refresh_fields()['input_revision'])
        self.assertEqual(stored['invalidated_evidence'], ['review'])
        job = snapshot['jobs'][0]
        job_data = json.loads(job['data'])
        self.assertEqual(job['generation'], 2)
        self.assertEqual(job['input_sha'], refresh_fields()['input_evidence']['input_sha'])
        self.assertEqual(job_data['input_version'], refresh_fields()['input_revision'])
        self.assertEqual(job_data['evidence_invalidated'],
                         {'input_revision': refresh_fields()['input_revision'], 'items': ['review']})
        self.assertEqual(job['retries_used'], 1)
        resumed = Effect(self.store, adapter, self.authority.validate)
        resumed.prepare('refresh-op', preconditions,
                        {'kind': 'branch_refresh', **refresh_fields()})
        self.assertEqual(resumed.reconcile()['input_revision'], refresh_fields()['input_revision'])
        self.assertEqual(self.store.snapshot()['jobs'][0]['generation'], 2)
        self.assertEqual(self.store.snapshot()['jobs'][0]['retries_used'], 1)

    def test_branch_refresh_rejects_arbitrary_revision_string(self):
        fields = refresh_fields()
        fields['input_revision'] = 'trust-me-this-is-new'
        effect, _, _ = self.prepare('refresh-invalid', 'branch_refresh', **fields)
        self.assertEqual(effect.apply()['status'], 'pending')
        self.assertIsNone(self.store.snapshot()['effects'][0]['observation'])

    def test_bounded_script_adapter_marks_posts_and_cleans_temporary_reports(self):
        self.assertIsNotNone(BoundedScriptAdapter, 'bounded script adapter is not implemented')
        class Result:
            def __init__(self, returncode=0, stdout='', stderr=''):
                self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
        class Runner:
            def __init__(self):
                self.calls = []
                self.temporary = []
            def __call__(self, command, **kwargs):
                self.calls.append(command)
                if command[0].endswith('parse-report.sh'):
                    return Result(stdout='{"status":"clean","bugs":[],"out_of_scope":[]}')
                if command[0].endswith('board-comment.sh'):
                    path = Path(command[-1])
                    self.temporary.append(path)
                    self.assert_marker = b'fleet-board-effect-operation:report-op' in path.read_bytes()
                if command[0].endswith('file-followups.sh'):
                    path = Path(command[-1])
                    self.temporary.append(path)
                    self.assert_parsed = path.read_text() == '{"status":"clean","bugs":[],"out_of_scope":[]}'
                return Result(stdout='ok')
        runner = Runner()
        seen = []
        def observer(kind, intent):
            seen.append((kind, intent['operation_key']))
            return {'operation_key': intent['operation_key'], 'kind': kind, 'external_id': 'fresh'}
        adapter = BoundedScriptAdapter(Path(__file__).resolve().parents[2], observer, runner=runner)
        report = self.root / 'report.txt'
        report.write_text('## Status\\nclean\\n')
        posted = adapter.apply({'kind': 'report_post', 'operation_key': 'report-op',
                                'card': '17', 'report_file': str(report)})
        self.assertEqual(posted['operation_key'], 'report-op')
        self.assertTrue(runner.assert_marker)
        self.assertFalse(runner.temporary[-1].exists())
        filed = adapter.apply({'kind': 'followup_file', 'operation_key': 'followup-op',
                               'card': '17', 'pr': '23', 'role': 'reviewer',
                               'report_file': str(report)})
        self.assertEqual(filed['operation_key'], 'followup-op')
        self.assertTrue(runner.assert_parsed)
        self.assertFalse(runner.temporary[-1].exists())
        self.assertEqual(runner.calls[0][1:], ['17', str(runner.temporary[0])])
        self.assertIn('parse-report.sh', runner.calls[1][0])
        self.assertEqual(runner.calls[2][1:3], ['17', '23'])
        self.assertEqual(seen, [('report_post', 'report-op'), ('followup_file', 'followup-op')])

    def test_helper_command_vectors_are_allowlisted_and_bounded(self):
        self.assertIsNotNone(BoundedScriptAdapter, 'bounded script adapter is not implemented')
        class Result:
            returncode, stdout, stderr = 0, '{"status":"clean"}', ''
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            return Result()
        adapter = BoundedScriptAdapter(Path(__file__).resolve().parents[2],
                                       lambda kind, intent: None, runner=runner)
        worktree, patch, report = (self.root / name for name in ('wt', 'patch.json', 'report.txt'))
        patch.write_text('{}')
        report.write_text('fixture')
        cases = [
            ({'kind': 'worktree_prepare', 'card': '17', 'operation': 'create',
              'branch': 'fleet/17-fixture', 'worktree': str(worktree)},
             ['worktree.sh', 'create', '17', 'fleet/17-fixture', str(worktree)]),
            ({'kind': 'worktree_prepare', 'card': '17', 'operation': 'review', 'pr': '23'},
             ['worktree.sh', 'review', '17', '23']),
            ({'kind': 'branch_refresh', 'card': '17', 'pr': '23',
              'branch': 'fleet/17-fixture', 'worktree': str(worktree)},
             ['update-branch.sh', '17', '23', 'fleet/17-fixture', str(worktree)]),
            ({'kind': 'commit_publication', 'card': '17', 'branch': 'fleet/17-fixture',
              'worktree': str(worktree)}, ['git', 'push', '--set-upstream', 'origin', 'fleet/17-fixture']),
            ({'kind': 'pr_create', 'card': '17', 'title': 'Fixture', 'body': 'Body'},
             ['gh', 'pr', 'create', '--title', 'Fixture', '--body', 'BODY_MARKER',
              '--base', 'main']),
            ({'kind': 'pr_update', 'card': '17', 'pr': '23', 'title': 'Fixture', 'body': 'Body'},
             ['gh', 'pr', 'edit', '23', '--title', 'Fixture', '--body', 'Body', '--base', 'main']),
            ({'kind': 'note_update', 'card': '17', 'patch_file': str(patch)},
             ['note.sh', 'merge', '17', str(patch)]),
            ({'kind': 'card_move', 'card': '17', 'state': 'ready'},
             ['board-move.sh', '17', 'ready']),
            ({'kind': 'cleanup', 'card': '17', 'worktree': str(worktree)},
             ['worktree.sh', 'remove', '17', str(worktree)]),
        ]
        for index, (intent, expected_suffix) in enumerate(cases):
            intent['operation_key'] = 'op' if intent['kind'] == 'pr_create' else 'op-' + str(index)
            result = adapter._command(intent)
            command, temporary = result[0], result[2] if len(result) > 2 else None
            if intent['kind'] == 'pr_create':
                expected_suffix[6] = 'Body' + chr(10) + chr(10) + 'Controller-Operation: op'
            normalized = [Path(command[0]).name, *command[1:]]
            self.assertEqual(normalized[-len(expected_suffix):], expected_suffix)
            if temporary:
                Path(temporary).unlink()
        followup_result = adapter._command({'kind': 'followup_file', 'operation_key': 'followup-op',
                                            'card': '17', 'pr': '23', 'role': 'reviewer',
                                            'report_file': str(report)})
        followup, temporary = followup_result[0], followup_result[2]
        # follow-up preparation calls parse-report and writes private parsed JSON.
        self.assertEqual(followup[-3:-1], ['17', '23'])
        self.assertEqual(Path(temporary).read_text(), '{"status":"clean"}')
        Path(temporary).unlink()

    def test_review_card_move_routes_before_state_change_and_fails_closed(self):
        class Result:
            def __init__(self, returncode=0, stdout='', stderr=''):
                self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
        class Runner:
            def __init__(self, fail_route=False):
                self.calls, self.state, self.fail_route = [], 'ready', fail_route
            def __call__(self, command, **kwargs):
                self.calls.append(command)
                if command[0].endswith('review-stages.sh'):
                    if not self.fail_route:
                        self.state = 'routed'
                    return Result(returncode=1 if self.fail_route else 0)
                if command[0].endswith('board-move.sh'):
                    self.state = command[-1]
                return Result(stdout='ok')
        def run_case(fail_route):
            runner = Runner(fail_route)
            adapter = BoundedScriptAdapter(
                Path(__file__).resolve().parents[2],
                lambda kind, intent: ({'operation_key': intent['operation_key'], 'state': runner.state}
                                      if runner.state == 'in_review' else None),
                runner=runner)
            effect = Effect(self.store, adapter, self.authority.validate)
            effect.prepare('stage-move-' + str(fail_route),
                           {'card': '17', 'generation': 1, 'card_state': 'ready',
                            'head': 'head-1', 'note_valid': True},
                           {'kind': 'card_move', 'card': '17', 'state': 'in_review', 'pr': '23'})
            outcome = effect.apply()
            return runner, outcome
        ok_runner, ok_outcome = run_case(False)
        self.assertEqual(ok_outcome['status'], 'observed', ok_outcome)
        self.assertEqual([Path(call[0]).name for call in ok_runner.calls],
                         ['review-stages.sh', 'board-move.sh'])
        failed_runner, failed_outcome = run_case(True)
        self.assertIn(failed_outcome['status'], ('pending', 'attention'))
        self.assertNotIn('board-move.sh', [Path(call[0]).name for call in failed_runner.calls])
        self.assertEqual([Path(call[0]).name for call in failed_runner.calls], ['review-stages.sh'])
        self.assertEqual(failed_runner.state, 'ready')

    def test_crash_after_review_route_reconciles_and_retries_single_move(self):
        class Result:
            def __init__(self, returncode=0, stdout='', stderr=''):
                self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
        class Runner:
            def __init__(self):
                self.calls, self.state = [], 'ready'
            def __call__(self, command, **kwargs):
                name = Path(command[0]).name
                self.calls.append(name)
                if name == 'review-stages.sh':
                    self.state = 'routed'
                elif name == 'board-move.sh':
                    self.state = command[-1]
                return Result(stdout='ok')
        runner = Runner()
        adapter = BoundedScriptAdapter(
            Path(__file__).resolve().parents[2],
            lambda kind, intent: ({'operation_key': intent['operation_key'], 'state': runner.state}
                                  if runner.state == 'in_review' else None),
            runner=runner)
        effect = Effect(self.store, adapter, self.authority.validate)
        key = 'stage-move-after-route-crash'
        effect.prepare(key, {'card': '17', 'generation': 1, 'card_state': 'ready',
                             'head': 'head-1', 'note_valid': True},
                       {'kind': 'card_move', 'card': '17', 'state': 'in_review', 'pr': '23'})
        effect.inject_failure('after_review_route')

        interrupted = effect.apply()
        row = next(row for row in self.store.snapshot()['effects'] if row['operation_key'] == key)
        self.assertEqual(interrupted['status'], 'pending', interrupted)
        self.assertEqual((row['status'], row['observation']), ('intent', None))
        self.assertEqual(runner.state, 'routed')
        self.assertEqual(runner.calls, ['review-stages.sh'])

        self.assertEqual(effect.reconcile()['status'], 'ready')
        self.assertEqual(runner.state, 'routed')
        self.assertEqual(effect.apply()['status'], 'observed')
        self.assertEqual(runner.calls, ['review-stages.sh', 'review-stages.sh', 'board-move.sh'])
        self.assertEqual(runner.state, 'in_review')
        self.assertEqual(runner.calls.count('board-move.sh'), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
