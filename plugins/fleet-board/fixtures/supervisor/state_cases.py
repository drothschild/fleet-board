"""In-memory supervisor state and scope contract tests."""
import sys
import tempfile
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
        self.assertEqual((s.active, s.reservations, s.provider_health, s.run_tokens), ({}, {}, {}, {}))

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
        self.assertEqual(snap['run_tokens'], {'claude': {'in': 1}})
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

    def test_snapshot_shape(self):
        self.state.begin(action(1, kind='merge', paths=['a']))
        self.state.provider_health['claude'] = {'until': 5.0, 'reason': 'limit', 'failures': 1}
        self.state.run_tokens['claude'] = {'in': 1}
        snap = self.state.snapshot()
        self.assertEqual(set(snap), {'run_id', 'mode', 'pause_reason', 'revision', 'active',
                                     'lane', 'provider_health', 'run_tokens'})
        self.assertEqual(snap['run_id'], 'run1')
        self.assertEqual(snap['active'][1]['card'], 1)
        self.assertEqual(snap['lane']['card'], 1)
        self.assertNotIn('session', snap['active'][1])
        import json
        json.dumps(snap)


if __name__ == '__main__':
    sys.argv = sys.argv[:1]
    unittest.main()
