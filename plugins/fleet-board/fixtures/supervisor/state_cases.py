"""In-memory supervisor state and scope contract tests."""
import sys
import tempfile
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from supervisor import scopes
from supervisor.state import Action, State


def action(card, kind='role', column='Ready', paths=None):
    return Action(card=card, action='start', column=column, role='implementor', provider='claude',
                  paths=paths or [], started_at=1.0, started_mono=2.0, session=None, kind=kind)


class Scopes(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name).resolve()

    def test_normalize_cleans_separators_and_dedupes(self):
        self.assertEqual(scopes.normalize(['./src\\a/', 'src/a', 'docs'], self.root), ['docs', 'src/a'])

    def test_normalize_empty_means_whole_repo(self):
        self.assertEqual(scopes.normalize([''], self.root), [''])
        self.assertEqual(scopes.normalize(['./'], self.root), [''])
        self.assertEqual(scopes.normalize([], self.root), [''])

    def test_normalize_rejects_dotdot(self):
        for bad in ('../x', 'a/../b', 'a//b', 'a/./b', '/abs/path'):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(ValueError, 'invalid scope path'):
                    scopes.normalize([bad], self.root)

    def test_normalize_rejects_the_filesystem_root(self):
        for bad in ('/', '//', '/src/'):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(ValueError, 'invalid scope path'):
                    scopes.normalize([bad], self.root)

    def test_normalize_rejects_symlink_component(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / 'escape').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink in scope'):
            scopes.normalize(['escape/file'], self.root)

    def test_normalize_rejects_non_list_of_strings(self):
        with self.assertRaisesRegex(ValueError, 'invalid scope'):
            scopes.normalize('src', self.root)
        with self.assertRaisesRegex(ValueError, 'invalid scope'):
            scopes.normalize([1], self.root)

    def test_empty_scope_overlaps_everything(self):
        self.assertTrue(scopes.overlap([], ['src']))
        self.assertTrue(scopes.overlap(['src'], []))
        self.assertTrue(scopes.overlap([''], ['src']))
        self.assertTrue(scopes.overlap(['src'], ['']))

    def test_prefix_overlap_is_component_wise(self):
        self.assertFalse(scopes.overlap(['src/a'], ['src/ab']))
        self.assertTrue(scopes.overlap(['src'], ['src/a']))
        self.assertTrue(scopes.overlap(['src/a/b'], ['src/a']))
        self.assertTrue(scopes.overlap(['src/a'], ['src/a']))

    def test_overlap_is_case_insensitive_and_non_ascii_is_conservative(self):
        self.assertTrue(scopes.overlap(['SRC/File.py'], ['src']))
        self.assertTrue(scopes.overlap(['Café'], ['other']))


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.state = State('run1', clock=lambda: self.now)

    def test_initial_shape(self):
        s = self.state
        self.assertEqual((s.mode, s.pause_reason, s.revision, s.lane), ('running', None, 0, None))
        self.assertEqual((s.active, s.reservations, s.provider_health, s.run_tokens),
                         ({}, {}, {}, {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0, 'total': 0,
                                        'unknown': 0, 'partial': False}))

    def test_the_snapshot_carries_the_budget_without_cache_reads(self):
        self.assertEqual(self.state.snapshot()['run_budget'],
                         {'tokens': 0, 'partial': False, 'cap': None, 'label': 'counted toward limits.max_tokens'})
        self.state.add_tokens({'input': 5, 'output': 4, 'cache_write': 3, 'cache_read': None}, 1)
        budget = self.state.snapshot()['run_budget']
        self.assertEqual((budget['tokens'], budget['partial']), (12, False), 'an unknown cache read is not partial')
        self.state.add_tokens({'input': None, 'output': 1, 'cache_write': 0, 'cache_read': 0}, 1)
        budget = self.state.snapshot()['run_budget']
        self.assertEqual((budget['tokens'], budget['partial']), (13, True))
        rev = self.state.revision
        self.state.set_budget_cap(100)
        self.assertEqual((self.state.snapshot()['run_budget']['cap'], self.state.revision), (100, rev + 1))
        self.state.set_budget_cap(100)
        self.assertEqual(self.state.revision, rev + 1, 'an unchanged cap does not bump the revision')

    def test_begin_refuses_a_second_action_for_a_card(self):
        self.state.begin(action(1))
        with self.assertRaises(ValueError):
            self.state.begin(action(1, kind='script'))
        self.assertEqual(self.state.end(1).card, 1)
        self.state.begin(action(1))

    def test_lane_holds_one_merge(self):
        self.state.begin(action(1, kind='merge'))
        self.assertEqual(self.state.lane.card, 1)
        with self.assertRaises(ValueError):
            self.state.begin(action(2, kind='merge'))
        self.assertNotIn(2, self.state.active)
        self.state.begin(action(3))
        self.state.end(1)
        self.assertIsNone(self.state.lane)
        self.state.begin(action(2, kind='merge'))

    def test_end_unknown_card_raises(self):
        with self.assertRaises(KeyError):
            self.state.end(9)

    def test_pause_records_reason_and_bumps_revision(self):
        before = self.state.revision
        self.state.pause('budget')
        self.assertEqual((self.state.mode, self.state.pause_reason), ('paused', 'budget'))
        self.assertGreater(self.state.revision, before)
        mid = self.state.revision
        self.state.resume()
        self.assertEqual((self.state.mode, self.state.pause_reason), ('running', None))
        self.assertGreater(self.state.revision, mid)

    def test_stop_is_terminal_and_bumps_revision(self):
        before = self.state.revision
        self.state.stop()
        self.assertEqual(self.state.mode, 'stopping')
        self.assertGreater(self.state.revision, before)
        settled = self.state.revision
        self.state.pause('late')
        self.state.resume()
        self.state.stop()
        self.assertEqual((self.state.mode, self.state.revision), ('stopping', settled))

    def test_snapshot_is_a_deep_copy(self):
        self.state.begin(action(1, paths=['a']))
        self.state.run_tokens['claude'] = {'in': 1}
        self.state.provider_health['claude'] = {'until': 5.0}
        snap = self.state.snapshot()
        self.state.active[1].paths.append('b')
        self.state.run_tokens['claude']['in'] = 99
        self.state.provider_health['claude']['until'] = 9.0
        self.assertEqual(snap['active'][1]['paths'], ['a'])
        self.assertEqual(snap['run_tokens']['claude'], {'in': 1})
        self.assertEqual(snap['provider_health']['claude']['until'], 5.0)

    def test_every_mutation_bumps_revision(self):
        s = self.state
        for mutate in (lambda: s.begin(action(1)), lambda: s.reserve(1, ['a']),
                       lambda: s.release(1), lambda: s.end(1), lambda: s.event('x')):
            before = s.revision
            mutate()
            self.assertGreater(s.revision, before)

    def test_reserve_returns_conflicting_card_or_records(self):
        s = self.state
        self.assertIsNone(s.reserve(1, ['src/core']))
        self.assertEqual(s.reserve(2, ['src/core/x']), 1)
        self.assertNotIn(2, s.reservations)
        self.assertIsNone(s.reserve(2, ['src/core2']))
        self.assertIsNone(s.reserve(1, ['src/core', 'docs']))  # own card never conflicts
        self.assertEqual(s.reservations[1], ['docs', 'src/core'])
        s.release(1)
        self.assertNotIn(1, s.reservations)
        self.assertIsNone(s.reserve(3, ['src/core']))
        s.release(99)  # releasing an absent card is a no-op

    def test_reserve_exempt_owners_are_not_overlap_checked(self):
        s = self.state
        self.assertIsNone(s.reserve(11, ['src/a']))
        self.assertIsNone(s.reserve(20, ['src/b']))
        self.assertIsNone(s.reserve(12, ['src/a/x'], exempt=(11,)))
        self.assertEqual(s.reservations[12], ['src/a/x'])
        self.assertEqual(s.reserve(13, ['src/b/x'], exempt=(11,)), 20)
        self.assertNotIn(13, s.reservations)

    def test_reserve_succeeds_when_the_only_overlapping_owner_is_stacked_on_the_card(self):
        s = self.state
        self.assertIsNone(s.reserve(12, ['src/a'], ancestors=(11,)))
        self.assertIsNone(s.reserve(11, ['src/a/x']))
        self.assertEqual(s.reservations[11], ['src/a/x'])

    def test_reserve_succeeds_past_a_grandchild_stacked_on_the_card(self):
        s = self.state
        self.assertIsNone(s.reserve(13, ['src/a'], ancestors=(12, 11)))
        self.assertIsNone(s.reserve(11, ['src/a']))

    def test_reserve_still_refuses_a_sibling_or_an_unrelated_card(self):
        s = self.state
        self.assertIsNone(s.reserve(12, ['src/a'], ancestors=(10,)))
        self.assertEqual(s.reserve(13, ['src/a'], ancestors=(10,)), 12)
        self.assertEqual(s.reserve(14, ['src/a']), 12)
        self.assertEqual(s.reserve(10, ['src/a'], ancestors=(9,)), None)

    def test_reserve_drops_scope_ignore_paths_on_both_sides(self):
        s = self.state
        ignore = ['plugins/*/.claude-plugin/plugin.json']
        manifest = 'plugins/fleet-board/.claude-plugin/plugin.json'
        self.assertIsNone(s.reserve(1, ['src/a', manifest], ignore=ignore))
        self.assertIsNone(s.reserve(2, ['src/b', manifest], ignore=ignore))
        # Without the setting the manifest overlaps, as before.
        self.assertEqual(s.reserve(3, ['src/c', manifest]), 1)
        # A wholly-ignored scope is kept, but it no longer meets the others' manifests.
        self.assertIsNone(s.reserve(4, [manifest], ignore=ignore))
        self.assertEqual(s.reserve(5, ['src/a/x'], ignore=ignore), 1)
        # The mirror needs the own-side filter: card 4 holds only the manifest.
        self.assertIsNone(s.reserve(6, ['src/z', manifest], ignore=ignore))

    def test_reserve_unions_with_the_held_scope(self):
        s = self.state
        self.assertIsNone(s.reserve(1, ['a']))
        self.assertIsNone(s.reserve(1, ['b']))
        self.assertEqual(s.reservations[1], ['a', 'b'])
        self.assertEqual(s.reserve(2, ['a/x']), 1)

    def test_held_whole_repo_scope_stays_whole_repo(self):
        s = self.state
        s.reserve(1, [''])
        s.reserve(1, ['b'])
        self.assertEqual(s.reservations[1], [''])
        self.assertEqual(s.reserve(2, ['x']), 1)
        s.release(1)
        s.reserve(3, ['a'])
        s.reserve(3, [''])
        self.assertEqual(s.reservations[3], [''])

    def test_reserve_reads_a_missing_repo_as_the_home_repo(self):
        s = self.state
        self.assertIsNone(s.reserve(1, ['src/a.py']))   # no repo: the home repo
        self.assertEqual(s.reserve(2, ['src/a.py'], repo='acme/toy', home_repo='acme/toy'), 1)
        self.assertIsNone(s.reserve(3, ['src/a.py'], repo='acme/other', home_repo='acme/toy'))
        # unknown home repo: a missing repo still matches every repo
        self.assertEqual(s.reserve(4, ['src/a.py'], repo='acme/zed'), 1)

    def test_begin_rejects_an_unknown_kind(self):
        with self.assertRaises(ValueError):
            self.state.begin(action(1, kind='bogus'))
        self.assertEqual(self.state.active, {})
        for kind in ('role', 'script', 'merge'):
            self.state.begin(action(hash(kind) % 1000, kind=kind))
            self.state.end(hash(kind) % 1000)

    def test_events_ring_keeps_the_last_500(self):
        seqs = [self.state.event('tick', n=i) for i in range(600)]
        self.assertEqual(seqs, sorted(seqs))
        self.assertEqual(len(self.state.events), 500)
        self.assertEqual(self.state.events[-1]['payload']['n'], 599)
        self.assertEqual(self.state.events[0]['payload']['n'], 100)
        self.assertEqual(self.state.events[-1]['sequence'], seqs[-1])
        self.assertEqual(self.state.events[-1]['type'], 'tick')

    def test_the_review_and_a_stage_review_of_one_card_are_active_together(self):
        s = self.state
        evidence = Action(card=7, action='review', column='in_review', role='reviewer', provider='claude',
                          paths=[], started_at=1.0, started_mono=2.0)
        stage = Action(card=7, action='review_stage', column='in_review', role='stage-reviewer', provider='claude',
                       paths=[], started_at=1.0, started_mono=2.0)
        s.begin(evidence)
        s.begin(stage)
        self.assertEqual(sorted(a.action for a in s.actions_for(7)), ['review', 'review_stage'])
        snap = s.snapshot()
        listed = [snap['active'][7]['action']] + [a['action'] for a in snap['active'][7]['also']]
        self.assertEqual(sorted(listed), ['review', 'review_stage'])
        self.assertIs(s.end(7, stage), stage)
        self.assertEqual([a.action for a in s.actions_for(7)], ['review'])
        self.assertIs(s.end(7, evidence), evidence)
        self.assertEqual(s.actions_for(7), [])
        self.assertNotIn(7, s.active)

    def test_only_reviewer_actions_share_a_card(self):
        s = self.state
        s.begin(Action(card=7, action='review', column='in_review', role='reviewer', provider='claude',
                       paths=[], started_at=1.0, started_mono=2.0))
        for name in ('fix', 'update_branch', 'start', 'merge'):
            with self.assertRaisesRegex(ValueError, 'card already active'):
                s.begin(Action(card=7, action=name, column='in_review', role='fixer', provider='claude',
                               paths=[], started_at=1.0, started_mono=2.0))
        s.end(7)
        s.begin(Action(card=7, action='fix', column='in_review', role='fixer', provider='claude',
                       paths=[], started_at=1.0, started_mono=2.0))
        with self.assertRaisesRegex(ValueError, 'card already active'):
            s.begin(Action(card=7, action='review', column='in_review', role='reviewer', provider='claude',
                           paths=[], started_at=1.0, started_mono=2.0))

    def test_the_marker_stays_until_the_last_reviewer_ends(self):
        from supervisor import markers
        s = self.state
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__('shutil').rmtree(root, ignore_errors=True))
        acts = []
        for name, pgid in (('review', 4242), ('review_stage', 4343)):
            a = Action(card=7, action=name, column='in_review', role='reviewer', provider='claude',
                       paths=[], started_at=1.0, started_mono=2.0)
            s.begin(a)
            a.marker = markers.write(root, None, 7, pgid)   # the later write names the later session's group
            a.pgid = pgid
            acts.append(a)
        marker = markers.path(root, None, 7)
        s.end(7, acts[1])
        self.assertTrue(marker.exists(), 'a reviewer still runs, so the marker stays')
        s.end(7, acts[0])
        self.assertFalse(marker.exists(), 'the last reviewer ended, so the marker is removed')

    def test_snapshot_shape(self):
        self.state.begin(action(1, kind='merge', paths=['a']))
        self.state.provider_health['claude'] = {'until': 5.0, 'reason': 'limit', 'failures': 1}
        self.state.run_tokens['claude'] = {'in': 1}
        snap = self.state.snapshot()
        self.assertEqual(set(snap), {'run_id', 'mode', 'pause_reason', 'revision', 'active',
                                     'lane', 'provider_health', 'holds', 'run_tokens', 'run_budget',
                                     'events', 'attention', 'queue', 'limits', 'last_plan',
                                     'followups_auto_ready', 'premise'})
        self.assertEqual(snap['run_id'], 'run1')
        self.assertEqual(snap['active'][1]['card'], 1)
        self.assertEqual(snap['lane']['card'], 1)
        self.assertNotIn('session', snap['active'][1])
        import json
        json.dumps(snap)

    def test_the_snapshot_counts_premise_verdicts_for_the_run(self):
        zero = {'checked': 0, 'go': 0, 'needs': 0, 'built': 0, 'stale': 0, 'drafted': 0, 'failed': 0}
        self.assertEqual(self.state.snapshot()['premise'], zero)
        for key in ('checked', 'go', 'checked', 'built', 'failed', 'drafted', 'drafted'):
            self.state.count_premise(key)
        self.assertEqual(self.state.snapshot()['premise'],
                         dict(zero, checked=2, go=1, built=1, failed=1, drafted=2))
        self.assertEqual(State('run2').snapshot()['premise'], zero)

    def test_take_auto_ready_counts_up_to_the_cap_and_the_snapshot_shows_it(self):
        self.assertEqual(self.state.followups_auto_ready, 0)
        self.assertEqual(State('run2').followups_auto_ready, 0)
        self.assertEqual([self.state.take_auto_ready(2) for _ in range(3)], [True, True, False])
        self.assertEqual(self.state.followups_auto_ready, 2)
        self.assertEqual(self.state.snapshot()['followups_auto_ready'], {'count': 2, 'cap': 2})

    def test_take_auto_ready_with_a_cap_of_zero_never_admits(self):
        self.assertFalse(self.state.take_auto_ready(0))
        self.assertEqual(self.state.followups_auto_ready, 0)

    def test_a_new_state_starts_the_auto_ready_count_at_zero(self):
        self.state.take_auto_ready(5)
        fresh = State('run2')
        self.assertEqual(fresh.followups_auto_ready, 0)
        self.assertEqual(fresh.snapshot()['followups_auto_ready']['count'], 0)

    def test_a_running_role_action_in_the_status_reply_has_a_log_field_holding_the_session_jsonl_path(self):
        act = action(1)
        act.session = types.SimpleNamespace(log_path='/logs/card-1-start.jsonl')
        self.state.begin(act)
        snap = self.state.snapshot()
        self.assertEqual(snap['active'][1]['log'], '/logs/card-1-start.jsonl')
        self.assertNotIn('session', snap['active'][1])

    def test_an_action_that_runs_only_a_script_with_no_session_has_log_null_in_the_status_reply(self):
        self.state.begin(action(2, kind='script'))
        self.assertIn('log', self.state.snapshot()['active'][2])
        self.assertIsNone(self.state.snapshot()['active'][2]['log'])


if __name__ == '__main__':
    sys.argv = sys.argv[:1]
    unittest.main()
