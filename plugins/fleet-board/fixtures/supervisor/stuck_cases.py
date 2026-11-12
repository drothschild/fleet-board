"""The startup check: cards a dead supervisor left half done, on a real fixture board (real board scripts)."""
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

BASE = Path(sys.argv.pop()).resolve()
PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'fixtures' / 'supervisor'))
import driver_cases as dc  # noqa: E402
from supervisor import candidates, cli, loop, scheduler, state, stuck  # noqa: E402


def dead_pid():
    proc = subprocess.Popen(['true'])
    proc.wait()
    return proc.pid


class StuckCase(unittest.TestCase):
    def setUp(self):
        self.dir = BASE / self.id().rsplit('.', 1)[-1]
        self.dir.mkdir()
        patcher = mock.patch.dict(os.environ, {'FLEET_BOARD_USER': 'fleet-bot'})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.b = dc.Board(self.dir)
        self.root = self.b.root
        (self.root / '.fw').mkdir()
        self.active = self.root / '.fleet-board' / 'active'
        self.locks = self.root / '.fw' / '.locks'

    # -- helpers -------------------------------------------------------------------------------------
    def kinds(self, **kw):
        return sorted((s.card, s.kind) for s in stuck.find(self.root, **kw))

    def marker(self, n):
        self.active.mkdir(exist_ok=True)
        (self.active / str(n)).write_text('')

    def lock(self, n, pid=None, age=0):
        d = self.locks / ('card-%d.lock' % n)
        d.mkdir(parents=True)
        if pid is not None:
            (d / 'pid').write_text('%d\n' % pid)
        if age:
            old = time.time() - age
            os.utime(str(d), (old, old))
        return d

    def worktree(self, n, dirty=False):
        path = self.root / '.fw' / ('%d-add-subtract' % n)
        path.mkdir()
        subprocess.run(['git', '-C', str(path), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(path), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q',
                        '--allow-empty', '-m', 'work'], check=True)
        if dirty:
            (path / 'wip.txt').write_text('uncommitted')
        return path

    def head(self, path):
        return subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'], capture_output=True, text=True,
                              check=True).stdout.strip()

    def snapshot(self):
        out = {}
        for p in sorted(self.root.rglob('*')):
            if '.git' in p.parts[len(self.root.parts):]:
                continue
            out[str(p)] = p.read_bytes() if p.is_file() else None
        return out


class Kinds(StuckCase):
    def test_in_progress_card_without_a_live_session_is_in_flight(self):
        self.b.seed(12, 'in_progress')
        found = stuck.find(self.root)
        self.assertEqual([(s.card, s.kind) for s in found], [(12, 'in_flight')])
        self.assertTrue(found[0].detail)
        self.assertEqual(self.kinds(live_cards={12}), [], 'a card the running supervisor owns is not stuck')

    def test_a_clean_board_finds_nothing(self):
        self.b.seed(12, 'ready')
        self.b.seed(13, 'in_review')
        self.b.seed(14, 'done')
        self.assertEqual(stuck.find(self.root), [])

    def test_a_merging_card_is_in_flight_only_when_a_merge_was_in_flight(self):
        self.b.seed(12, 'merging')
        self.assertEqual(self.kinds(), [], 'waiting in merging for the planner is not stuck')
        pending = {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'}
        self.b.put_note({'pending_merge': pending})
        self.assertEqual(self.kinds(), [(12, 'in_flight')])
        self.assertEqual(self.kinds(live_cards={12}), [])
        self.b.put_note({'merge_operation': {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'}})
        self.assertEqual(self.kinds(), [], 'a recorded merge is not in flight')

    def test_a_merging_card_with_a_refusal_or_merger_record_is_not_stuck(self):
        pending = {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'}
        self.b.seed(12, 'merging')
        self.b.put_note({'pending_merge': pending, 'merge_refusal': {'pr': 34, 'head': 'abc1234', 'reason': 'r'}})
        self.b.seed(13, 'merging')
        self.b.put_note({'pending_merge': pending, 'merger': {'mode': 'after_merge', 'status': 'done'}}, 13)
        self.assertEqual(self.kinds(), [])

    def test_an_active_marker_is_stuck(self):
        self.b.seed(13, 'ready')
        self.marker(13)
        self.assertEqual(self.kinds(), [(13, 'marker')])
        self.assertEqual(self.kinds(live_cards={13}), [])

    def test_a_dirty_worktree_is_stuck_and_a_clean_one_is_not(self):
        self.b.seed(14, 'in_review')
        self.b.put_note({'worktree': str(self.worktree(14, dirty=True))}, 14)
        self.b.seed(15, 'in_review')
        self.b.put_note({'worktree': str(self.worktree(15))}, 15)
        found = stuck.find(self.root)
        self.assertEqual([(s.card, s.kind) for s in found], [(14, 'dirty_worktree')])
        self.assertIn('wip.txt', found[0].detail)
        self.assertEqual(self.kinds(live_cards={14}), [])

    def test_a_lock_whose_holder_is_gone_is_stuck(self):
        self.b.seed(16, 'ready')
        self.b.seed(17, 'ready')
        self.b.seed(18, 'ready')
        self.b.seed(19, 'ready')
        self.lock(16, dead_pid())
        self.lock(17, os.getpid())
        self.lock(18, None, age=60)      # no pid file, long enough that it is not being created
        self.lock(19, None)              # no pid file yet: a holder between mkdir and writing its pid
        self.assertEqual(self.kinds(), [(16, 'dead_lock'), (18, 'dead_lock')])
        self.assertEqual(self.kinds(live_cards={16, 18}), [])

    def test_a_card_can_be_stuck_in_more_than_one_way(self):
        self.b.seed(12, 'in_progress')
        self.marker(12)
        self.assertEqual(self.kinds(), [(12, 'in_flight'), (12, 'marker')])

    def test_a_missing_store_finds_no_cards(self):
        for p in (self.root / '.fleet-board' / 'cards').glob('*'):
            p.unlink()
        (self.root / '.fleet-board' / 'next').unlink()
        self.assertEqual(stuck.find(self.root), [])

    def test_find_is_read_only(self):
        self.b.seed(12, 'in_progress')
        self.b.seed(13, 'merging')
        self.b.put_note({'pending_merge': {'operation_key': 'k', 'pr': 3, 'head_sha': 'a'}}, 13)
        self.b.seed(14, 'in_review')
        self.b.put_note({'worktree': str(self.worktree(14, dirty=True))}, 14)
        self.marker(12)
        self.lock(15, dead_pid())
        before = self.snapshot()
        found = stuck.find(self.root)
        self.assertGreaterEqual(len(found), 5)
        self.assertEqual(self.snapshot(), before, 'find wrote to the board, a lock or a worktree')


class Release(StuckCase):
    def gh_state(self, value):
        calls = []

        def gh(root, pr, repo):
            calls.append((pr, repo))
            return value
        gh.calls = calls
        return gh

    def test_release_returns_to_the_stable_column_and_keeps_the_branch(self):
        self.b.seed(12, 'in_progress')
        path = self.worktree(12, dirty=True)
        head = self.head(path)
        self.b.put_note({'worktree': str(path), 'branch': dc.BRANCH, 'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        self.marker(12)
        dead = self.lock(12, dead_pid())
        stuck.release(self.root, 12)
        self.assertEqual(self.b.card(12)['state'], 'ready', 'no PR: back to ready')
        self.assertFalse((self.active / '12').exists())
        self.assertFalse(dead.exists())
        self.assertIsNone(self.b.note(12).get('stuck'))
        self.assertEqual(self.b.note(12)['branch'], dc.BRANCH)
        self.assertEqual(self.head(path), head)
        self.assertTrue((path / 'wip.txt').exists(), 'release never touches the worktree')
        self.assertEqual([s.kind for s in stuck.find(self.root)], ['dirty_worktree'],
                         'the card is resolved; its uncommitted work is still a person\'s to deal with')

    def test_release_of_an_in_progress_card_with_a_pr_goes_to_in_review(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'pr': 34})
        stuck.release(self.root, 12)
        self.assertEqual(self.b.card(12)['state'], 'in_review')

    def test_release_refuses_a_card_whose_lock_is_held_by_a_running_process(self):
        self.b.seed(12, 'in_progress')
        live = self.lock(12, os.getpid())
        with self.assertRaises(ValueError):
            stuck.release(self.root, 12)
        self.assertTrue(live.exists())
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_release_of_a_merged_merging_card_leaves_it_in_merging(self):
        self.b.seed(12, 'merging')
        pending = {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'}
        self.b.put_note({'pr': 34, 'pending_merge': pending, 'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        self.marker(12)
        gh = self.gh_state('MERGED')
        stuck.release(self.root, 12, gh=gh)
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual(self.b.note(12)['pending_merge'], pending)
        self.assertIsNone(self.b.note(12).get('stuck'))
        self.assertFalse((self.active / '12').exists())
        self.assertEqual(len(gh.calls), 1)
        self.assertEqual(gh.calls[0][0], 34)

    def test_release_of_an_open_merging_card_clears_the_merge_records_and_goes_to_in_review(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a'},
                         'merge_refusal': {'pr': 34, 'head': 'a', 'reason': 'r'}, 'merge_retry': {'at': 'x'},
                         'merger': {'mode': 'refusal', 'status': 'attention'}, 'branch': dc.BRANCH})
        stuck.release(self.root, 12, gh=self.gh_state('OPEN'))
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        note = self.b.note(12)
        for key in ('pending_merge', 'merge_refusal', 'merge_retry', 'merger'):
            self.assertIsNone(note.get(key), key)
        self.assertEqual(note['branch'], dc.BRANCH)

    def test_release_of_a_merging_card_whose_pr_state_is_unknown_changes_nothing(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a'}})
        self.marker(12)
        with self.assertRaises(ValueError):
            stuck.release(self.root, 12, gh=lambda *a: None)
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertTrue((self.active / '12').exists())
        self.assertIsNotNone(self.b.note(12).get('pending_merge'))

    def test_release_of_a_card_in_another_column_only_clears_markers_and_the_note(self):
        self.b.seed(13, 'in_review')
        self.b.put_note({'stuck': {'kind': 'marker', 'detail': 'd', 'at': 't'}}, 13)
        self.marker(13)
        stuck.release(self.root, 13)
        self.assertEqual(self.b.card(13)['state'], 'in_review')
        self.assertFalse((self.active / '13').exists())
        self.assertIsNone(self.b.note(13).get('stuck'))

    def test_release_of_an_unknown_card_is_an_error(self):
        with self.assertRaises(ValueError):
            stuck.release(self.root, 99)


class Start(StuckCase):
    def setUp(self):
        super().setUp()
        sock = tempfile.mkdtemp(prefix='fbs.', dir='/tmp')
        logs = self.dir / 'logs'
        logs.mkdir(mode=0o700)
        patcher = mock.patch.dict(os.environ, {'FLEET_BOARD_SOCKET_DIR': sock, 'FLEET_BOARD_LOG_DIR': str(logs),
                                               'FLEET_BOARD_DOMAIN': str(self.root)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(lambda: subprocess.run(['rm', '-rf', sock]))

    def invoke(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(list(argv), env=os.environ, stdout=out, stderr=err)
        return rc, out.getvalue(), err.getvalue()

    def test_start_refuses_with_stuck_cards_exit_4(self):
        self.b.seed(12, 'in_progress')
        self.marker(12)
        rc, out, err = self.invoke('start')
        if rc == 1 and 'cannot bind' in err:
            self.skipTest('sandbox denies the supervisor socket')
        self.assertEqual(rc, 4, err)
        self.assertEqual(out, '', 'no readiness acknowledgement when work is refused')
        self.assertIn('#12 in_flight: ', err)
        self.assertIn('#12 marker: ', err)
        note = self.b.note(12)['stuck']
        self.assertEqual(note['kind'], 'in_flight')
        self.assertTrue(note['detail'] and note['at'])
        self.assertEqual(self.b.card(12)['state'], 'in_progress', 'the supervisor never repairs work itself')
        self.assertTrue((self.active / '12').exists())

    def test_ignore_stuck_skips_them(self):
        self.b.seed(12, 'in_progress')
        captured = {}

        class FakeSupervisor:
            def __init__(self, root, **kw):
                captured['sup'] = self
                self.ignored = {}
                self.on_signal = lambda *a: None

            def handle(self, command):
                return {}

            def run(self):
                return 0

        class FakeService:
            def __init__(self, *a, **kw):
                pass

            def serve(self):
                return {'owner': True}

            def close(self):
                pass

        with mock.patch.object(cli.loop, 'Supervisor', FakeSupervisor), mock.patch.object(cli, 'Service', FakeService):
            rc, out, err = self.invoke('start', '--ignore-stuck')
        self.assertEqual(rc, 0, err)
        self.assertEqual(set(captured['sup'].ignored), {12})
        self.assertIn('#12 in_flight: ', err)
        self.assertEqual(self.b.note(12)['stuck']['kind'], 'in_flight')

    def test_start_on_a_clean_board_runs(self):
        self.b.seed(12, 'ready')
        captured = {}

        class FakeSupervisor:
            def __init__(self, root, **kw):
                captured['sup'] = self
                self.ignored = {}
                self.on_signal = lambda *a: None

            def handle(self, command):
                return {}

            def run(self):
                return 0

        class FakeService:
            def __init__(self, *a, **kw):
                pass

            def serve(self):
                return {'owner': True}

            def close(self):
                pass

        with mock.patch.object(cli.loop, 'Supervisor', FakeSupervisor), mock.patch.object(cli, 'Service', FakeService):
            rc, out, err = self.invoke('start')
        self.assertEqual(rc, 0, err)
        self.assertEqual(set(captured['sup'].ignored), set())

    def test_the_stuck_command_lists_and_releases_without_a_supervisor(self):
        self.b.seed(12, 'in_progress')
        rc, out, err = self.invoke('stuck', '--json')
        self.assertEqual(rc, 0, err)
        rows = json.loads(out)
        self.assertEqual([(r['card'], r['kind']) for r in rows], [(12, 'in_flight')])
        rc, out, err = self.invoke('stuck')
        self.assertIn('#12 in_flight: ', out)
        rc, out, err = self.invoke('stuck', '--release', '12')
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.b.card(12)['state'], 'ready')
        rc, out, err = self.invoke('stuck')
        self.assertEqual((rc, out.strip()), (0, 'no stuck cards'))


class Ignored(StuckCase):
    def make(self, ignored):
        self.spy = []
        board = self

        class Spy(scheduler.Scheduler):
            def admit(self, rows, **kw):
                board.spy.append(list(rows))
                return super().admit(rows, **kw)

        class Driver:
            began = []

            def begin(self, row):
                self.began.append(row)

        self.driver = Driver()
        row = dc.candidate('continue_implementor', number=12, state='in_progress', declared_paths=['p'])
        sup = loop.Supervisor(self.root, config_loader=lambda: dict(dc.CONFIG, supervisor={}, limits={}),
                              state=state.State('r'), driver=self.driver, scheduler=Spy(),
                              fetch=lambda *a: candidates.Batch([row], None, None), run=self.b.run,
                              ignored=ignored)
        return sup

    def test_an_ignored_card_is_never_offered_to_the_scheduler(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup = self.make({12: 'in_progress'})
        sup._cycle()
        self.assertEqual(self.spy, [[]])
        self.assertEqual(self.driver.began, [])

    def test_an_ignored_card_is_offered_again_once_released(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup = self.make({12: 'in_progress'})
        stuck.release(self.root, 12)
        self.b.seed(12, 'in_progress')       # the card is back in the column it was ignored in
        sup._cycle()
        self.assertEqual([r['number'] for r in self.spy[0]], [12])
        self.assertEqual(sup.ignored, {})

    def test_an_ignored_card_that_a_person_moved_is_offered_again(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup = self.make({12: 'in_progress'})
        self.b.seed(12, 'ready')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup._cycle()
        self.assertEqual(sup.ignored, {})


if __name__ == '__main__':
    unittest.main()
