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
from supervisor import candidates, cli, loop, scheduler, service, state, stuck  # noqa: E402


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
        patcher = mock.patch.object(stuck, '_head', lambda *a: None)   # no network: the PR head is unknown
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
        (path / 'wip.txt').write_text('committed')
        subprocess.run(['git', '-C', str(path), 'add', 'wip.txt'], check=True)
        subprocess.run(['git', '-C', str(path), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q',
                        '-m', 'tracked'], check=True)
        if dirty:   # an uncommitted change to a tracked file (untracked files are not work in progress)
            (path / 'wip.txt').write_text('uncommitted')
        return path

    def group(self):
        """A live process group (its own session), stopped at cleanup; returns its pgid."""
        proc = subprocess.Popen(['sleep', '60'], start_new_session=True)

        def stop():
            try:
                os.killpg(proc.pid, 9)
            except OSError:
                pass
            proc.wait()
        self.addCleanup(stop)
        return proc.pid

    def owned_marker(self, n, pgid):
        self.active.mkdir(exist_ok=True)
        (self.active / str(n)).write_text(json.dumps({'pgid': pgid, 'supervisor_pid': dead_pid()}))

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

    def test_an_unreadable_note_is_its_own_finding_and_does_not_fail_the_check(self):
        self.b.seed(12, 'in_progress')
        self.b.seed(13, 'ready')

        def run(root, name, *args, **kw):
            if name == 'note.sh' and args[:2] == ('get', 13):
                return dc.fail_with('fleet-board: broken note')
            return stuck.scripts.run(root, name, *args, **kw)
        found = stuck.find(self.root, run=run)
        self.assertEqual(sorted((s.card, s.kind) for s in found), [(12, 'in_flight'), (13, 'unreadable_note')])

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
        self.assertEqual(stuck.find(self.root), [], 'releasing a dirty_worktree finding resolves it')
        self.assertEqual(self.b.note(12)['stuck_released']['kind'], 'dirty_worktree')

    def test_release_with_a_target_moves_there_and_clears_the_leftovers(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'stuck': {'kind': 'marker', 'detail': 'd', 'at': 't'}})
        self.marker(12)
        dead = self.lock(12, dead_pid())
        stuck.release(self.root, 12, force=True, target='backlog')
        self.assertEqual(self.b.card(12)['state'], 'backlog')
        self.assertFalse((self.active / '12').exists())
        self.assertFalse(dead.exists())
        self.assertIsNone(self.b.note(12).get('stuck'))

    def test_release_with_a_target_refuses_an_unrecorded_pending_merge(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a' * 40}})
        self.marker(12)
        with self.assertRaisesRegex(ValueError, r'fleet-board supervisor stuck --release 12'):
            stuck.release(self.root, 12, gh=self.gh_state('OPEN'), force=True, target='in_review')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertTrue((self.active / '12').exists(), 'a refused release changes nothing')

    def test_release_with_a_target_refuses_a_live_orphan(self):
        self.b.seed(12, 'in_progress')
        self.owned_marker(12, self.group())
        with self.assertRaisesRegex(ValueError, r'live process group'):
            stuck.release(self.root, 12, force=True, target='ready')
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

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

    def test_a_released_merged_card_is_no_longer_in_flight(self):
        self.b.seed(12, 'merging')
        pending = {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'}
        self.b.put_note({'pr': 34, 'pending_merge': pending})
        self.assertEqual(self.kinds(), [(12, 'in_flight')])
        stuck.release(self.root, 12, gh=self.gh_state('MERGED'))
        note = self.b.note(12)
        self.assertEqual(note['merge_operation'], pending)
        self.assertEqual(note['merged_pr'], 34)
        self.assertEqual(stuck.find(self.root), [], 'the planner can now plan verify_main / after_merge')

    def test_a_pending_merge_for_an_earlier_head_is_not_in_flight(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'old'}})
        with mock.patch.object(stuck, '_head', lambda *a: 'new'):
            self.assertEqual(self.kinds(), [])
        with mock.patch.object(stuck, '_head', lambda *a: 'old'):
            self.assertEqual(self.kinds(), [(12, 'in_flight')])

    def test_the_driver_clears_stuck_released_when_it_next_acts_on_the_card(self):
        self.b.seed(12, 'in_progress')
        path = self.worktree(12, dirty=True)
        self.b.put_note({'worktree': str(path)})
        stuck.release(self.root, 12)
        self.assertIn('stuck_released', self.b.note(12))
        self.b.driver.begin(dc.candidate('wait', state='ready', waiting_on=['acme/toy#3']))
        self.assertIsNone(self.b.note(12).get('stuck_released'))

    def test_release_of_an_open_merging_card_clears_the_merge_records_and_goes_to_in_review(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a'},
                         'merge_refusal': {'pr': 34, 'head': 'a', 'reason': 'r'}, 'merge_retry': {'at': 'x'},
                         'merger': {'mode': 'refusal', 'status': 'attention'}, 'branch': dc.BRANCH})
        # merge_refusal records how the merge ended: nothing is in flight, so this release needs --force
        stuck.release(self.root, 12, gh=self.gh_state('OPEN'), force=True)
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


class CliEnv(StuckCase):
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


class Start(CliEnv):
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

    def test_start_reports_every_config_error_not_only_the_last(self):
        cfg = self.root / '.fleet-board.yml'
        cfg.write_text(cfg.read_text() + 'limits:\n  max_cost_usd: 5\n  tick_interval: 30\n'
                       'models:\n  manager: opus\n')
        rc, out, err = self.invoke('start')
        if rc == 1 and 'cannot bind' in err:
            self.skipTest('sandbox denies the supervisor socket')
        self.assertNotEqual(rc, 0, err)
        self.assertEqual(out, '')
        for key in ('limits.max_cost_usd', 'limits.tick_interval', 'models.manager'):
            self.assertIn(key + ' is no longer a setting', err)

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

    def test_stuck_with_a_running_supervisor_reads_the_board_itself(self):
        self.b.seed(12, 'in_progress')
        self.b.seed(13, 'in_progress')
        requests = []

        def transport(request):
            requests.append(request['command'])
            if request['command'] != 'status':
                raise AssertionError('stuck must not depend on a slow socket reply')
            return {'active': [{'card': 13}]}
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--json'], env=os.environ, stdout=out, stderr=err, transport=transport)
        self.assertEqual(rc, 0, err.getvalue())
        self.assertEqual([r['card'] for r in json.loads(out.getvalue())], [12])
        self.assertEqual(requests, ['status'])
        rc = cli.main(['stuck', '--release', '13'], env=os.environ, stdout=out, stderr=err, transport=transport)
        self.assertEqual(rc, 1)
        self.assertEqual(self.b.card(13)['state'], 'in_progress')

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


class Record(StuckCase):
    def test_a_fresh_dead_lock_does_not_stall_the_note_write(self):
        self.b.seed(12, 'in_progress')
        self.lock(12, dead_pid())
        found = stuck.find(self.root)
        started = time.time()
        failed = stuck.record(self.root, found)
        self.assertLess(time.time() - started, 15, 'record waited on the dead lock')
        # PR #252: a lock whose holder is dead is taken over at once, so the note write succeeds
        self.assertEqual(failed, [], 'the note write takes over the dead lock')
        self.assertIn('stuck', self.b.note(12))

    def test_notes_are_written_for_cards_without_a_lock(self):
        self.b.seed(12, 'in_progress')
        self.assertEqual(stuck.record(self.root, stuck.find(self.root)), [])
        self.assertEqual(self.b.note(12)['stuck']['kind'], 'in_flight')


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
        sup._cycle()
        self.assertEqual([r['number'] for r in self.spy[0]], [12])
        self.assertEqual(sup.ignored, {})

    def test_an_ignored_card_stays_ignored_while_its_finding_stands_even_without_a_note(self):
        self.b.seed(12, 'in_progress')          # no stuck note: the note write may have failed
        sup = self.make({12: 'in_progress'})
        sup._cycle()
        self.assertEqual(sup.ignored, {12: 'in_progress'})
        self.assertEqual(self.spy, [[]])

    def test_an_ignored_card_that_a_person_moved_is_offered_again(self):
        self.b.seed(12, 'in_progress')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup = self.make({12: 'in_progress'})
        self.b.seed(12, 'ready')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        sup._cycle()
        self.assertEqual(sup.ignored, {})


class Wave5Fixes(StuckCase):
    """Phase 5 review fixes: live orphans, the run lock, release rules, worktree checks."""

    def gh_state(self, value):
        return lambda root, pr, repo: value

    # live_orphan --------------------------------------------------------------------------------------
    def test_live_orphan_is_a_kind(self):
        self.assertIn('live_orphan', stuck.KINDS)
        self.assertIn('unreadable_worktree', stuck.KINDS)

    def test_a_marker_naming_a_live_process_group_is_a_live_orphan_and_release_refuses(self):
        self.b.seed(13, 'in_review')
        pgid = self.group()
        self.owned_marker(13, pgid)
        found = stuck.find(self.root)
        self.assertEqual([(s.card, s.kind) for s in found], [(13, 'live_orphan')])
        self.assertIn(str(pgid), found[0].detail)
        with self.assertRaises(ValueError) as caught:
            stuck.release(self.root, 13)
        self.assertIn('stop', str(caught.exception))
        self.assertIn(str(pgid), str(caught.exception))
        self.assertTrue((self.active / '13').exists(), 'a live orphan keeps its marker')
        with self.assertRaises(ValueError):
            stuck.release(self.root, 13, force=True)
        self.assertTrue((self.active / '13').exists())

    def test_an_in_flight_card_whose_marker_group_is_alive_also_reports_live_orphan(self):
        self.b.seed(12, 'in_progress')
        self.owned_marker(12, self.group())
        self.assertEqual(self.kinds(), [(12, 'in_flight'), (12, 'live_orphan')])
        with self.assertRaises(ValueError):
            stuck.release(self.root, 12)
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_a_marker_naming_a_dead_process_group_is_a_plain_marker_and_release_clears_it(self):
        self.b.seed(13, 'in_review')
        self.owned_marker(13, dead_pid())
        self.assertEqual(self.kinds(), [(13, 'marker')])
        stuck.release(self.root, 13)
        self.assertFalse((self.active / '13').exists())
        self.assertEqual(stuck.find(self.root), [])

    def test_a_marker_with_an_unusable_pgid_is_a_plain_marker(self):
        self.b.seed(13, 'in_review')
        self.active.mkdir()
        for text in ('', 'garbage', '{"pgid": 0}', '{"pgid": 1}', '{"pgid": "7"}'):
            (self.active / '13').write_text(text)
            self.assertEqual(self.kinds(), [(13, 'marker')], text)

    def test_fb_mark_active_keeps_an_existing_marker_and_creates_an_empty_one(self):
        script = ('. "%s/scripts/board-lib.sh"; fb_load_config; fb_mark_active "$1"; '
                  'printf "%%s" "$FB_ACTIVE_FILE"' % PLUGIN)
        self.owned_marker(12, 4242)
        done = subprocess.run(['bash', '-c', script, 'x', '12'], cwd=str(self.root), capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads((self.active / '12').read_text())['pgid'], 4242,
                         'fb_mark_active must not truncate the supervisor-owned marker')
        done = subprocess.run(['bash', '-c', script, 'x', '14'], cwd=str(self.root), capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.active / '14').read_text(), '')
        self.assertTrue(done.stdout.endswith('/active/14'), done.stdout)

    # release rules ------------------------------------------------------------------------------------
    def test_release_refuses_a_card_with_no_current_finding_unless_forced(self):
        self.b.seed(13, 'in_review')
        self.b.put_note({'stuck': {'kind': 'marker', 'detail': 'old', 'at': 't'}}, 13)
        with self.assertRaises(ValueError) as caught:
            stuck.release(self.root, 13)
        self.assertIn('force', str(caught.exception))
        self.assertEqual(self.b.note(13)['stuck']['detail'], 'old', 'a refused release changes nothing')
        stuck.release(self.root, 13, force=True)
        self.assertIsNone(self.b.note(13).get('stuck'))
        self.assertEqual(self.b.card(13)['state'], 'in_review')

    def test_release_of_an_in_flight_merging_card_with_an_open_pr_needs_no_force(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a'}})
        self.assertEqual(self.kinds(), [(12, 'in_flight')])
        stuck.release(self.root, 12, gh=self.gh_state('OPEN'))
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        self.assertIsNone(self.b.note(12).get('pending_merge'))
        self.assertEqual(stuck.find(self.root), [])

    def test_release_of_a_merging_card_whose_pr_is_closed_is_treated_like_open(self):
        self.b.seed(12, 'merging')
        self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a'}})
        stuck.release(self.root, 12, gh=self.gh_state('CLOSED'))
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        self.assertIsNone(self.b.note(12).get('pending_merge'))

    def test_release_honours_the_lock_grace_for_a_lock_without_a_pid(self):
        self.b.seed(12, 'in_progress')
        fresh = self.lock(12, None)          # its holder is between mkdir and writing its pid
        with self.assertRaises(ValueError):
            stuck.release(self.root, 12)
        self.assertTrue(fresh.exists())
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_release_removes_an_old_lock_without_a_pid(self):
        self.b.seed(12, 'in_progress')
        old = self.lock(12, None, age=3600)  # its creator crashed between mkdir and writing its pid
        stuck.release(self.root, 12)
        self.assertFalse(old.exists())
        self.assertEqual(sorted(p.name for p in self.locks.iterdir()), [], 'no renamed copy is left behind')

    def test_release_leaves_a_pidless_lock_whose_slow_holder_records_its_pid_during_release(self):
        # Card #254: the holder was only slow. Its pid lands after release judged the lock dead (here, at
        # release's last check before removing it). Release must not remove a lock that now has a live owner.
        self.b.seed(12, 'in_progress')
        slow = self.lock(12, None, age=3600)
        real = stuck._live_claim

        def late_pid(path):
            if not (Path(path) / 'pid').exists():
                (Path(path) / 'pid').write_text('%d\n' % os.getpid())
            return real(path)
        stuck._live_claim = late_pid
        try:
            with self.assertRaises(ValueError):
                stuck.release(self.root, 12)
        finally:
            stuck._live_claim = real
        self.assertEqual((slow / 'pid').read_text().strip(), str(os.getpid()), 'the slow holder keeps its lock')
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_lock_grace_honours_the_shared_override(self):
        d = self.lock(12, None, age=5)
        os.environ['FLEET_BOARD_LOCK_PIDLESS_GRACE'] = '2'
        try:
            self.assertTrue(stuck._lock_dead(d))
            os.environ['FLEET_BOARD_LOCK_PIDLESS_GRACE'] = '60'
            self.assertFalse(stuck._lock_dead(d))
        finally:
            del os.environ['FLEET_BOARD_LOCK_PIDLESS_GRACE']

    def test_release_leaves_a_dead_lock_that_a_running_taker_has_claimed(self):
        self.b.seed(12, 'in_progress')
        claimed = self.lock(12, dead_pid())
        os.symlink(str(os.getpid()), str(claimed / 'claim.1'))   # a live taker is mid-takeover
        with self.assertRaises(ValueError):
            stuck.release(self.root, 12)
        self.assertTrue(claimed.exists())
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_release_removes_a_dead_lock_with_a_dead_takers_claim_by_rename(self):
        self.b.seed(12, 'in_progress')
        dead = self.lock(12, dead_pid())
        os.symlink(str(dead_pid()), str(dead / 'claim.1'))
        stuck.release(self.root, 12)
        self.assertFalse(dead.exists())
        self.assertEqual(sorted(p.name for p in self.locks.iterdir()), [], 'no renamed copy is left behind')
        self.assertEqual(self.b.card(12)['state'], 'ready')

    def test_a_lock_that_cannot_be_removed_is_a_value_error(self):
        self.b.seed(12, 'in_progress')
        dead = self.lock(12, dead_pid())
        (dead / 'nested').mkdir()            # unlink() of a directory fails with an OSError
        with self.assertRaises(ValueError) as caught:
            stuck.release(self.root, 12)
        self.assertIn('lock', str(caught.exception))
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    # what find checks ---------------------------------------------------------------------------------
    def test_a_card_in_a_review_stage_has_its_worktree_checked(self):
        self.b.seed(14, 'review_security')
        self.b.put_note({'worktree': str(self.worktree(14, dirty=True))}, 14)
        self.assertEqual(self.kinds(), [(14, 'dirty_worktree')])
        self.assertIn('review_security', stuck.checked_states(dc.CONFIG))
        for state_name in ('backlog', 'done', 'wont_do'):
            self.assertNotIn(state_name, stuck.checked_states(dc.CONFIG))

    def test_untracked_files_alone_are_not_a_dirty_worktree(self):
        self.b.seed(14, 'in_review')
        path = self.worktree(14)
        (path / 'scratch.txt').write_text('untracked')
        self.b.put_note({'worktree': str(path)}, 14)
        self.assertEqual(self.kinds(), [])

    def test_a_failed_or_timed_out_git_status_is_unreadable_never_clean(self):
        self.b.seed(14, 'in_review')
        self.b.put_note({'worktree': str(self.worktree(14))}, 14)
        argvs = []
        for result in (dc.fail_with('fatal: index locked', 128), stuck.scripts.ScriptResult(124, '', '', True)):
            def run_argv(root, argv, **kw):
                argvs.append(argv)
                return result
            found = stuck.find(self.root, run_argv=run_argv)
            self.assertEqual([(s.card, s.kind) for s in found], [(14, 'unreadable_worktree')], result)
        self.assertIn('--untracked-files=no', argvs[0])
        self.assertIn('--no-optional-locks', argvs[0])

    def test_the_driver_clears_a_stale_stuck_note_when_it_next_acts_on_the_card(self):
        self.b.seed(12, 'ready')
        self.b.put_note({'stuck': {'kind': 'in_flight', 'detail': 'd', 'at': 't'}})
        self.b.driver.begin(dc.candidate('wait', state='ready', waiting_on=['acme/toy#3']))
        self.assertIsNone(self.b.note(12).get('stuck'))


class RunLock(CliEnv):
    """`stuck --release` never trusts the socket alone: a live run lock without a supervisor reply refuses."""

    def hold_lock(self, pid):
        started = stuck.process_start(pid)
        if not started:
            self.skipTest('sandbox denies the ps call the run lock needs')
        path = Path(service.default_run_lock_path(self.root))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('%d\n%s\n' % (pid, started))
        return path

    def no_supervisor(self, request):
        raise FileNotFoundError

    def test_release_refuses_while_another_run_holds_the_lock(self):
        self.b.seed(12, 'in_progress')
        self.hold_lock(os.getpid())
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--release', '12'], env=os.environ, stdout=out, stderr=err,
                      transport=self.no_supervisor)
        self.assertEqual(rc, 1, out.getvalue())
        self.assertIn('a supervisor of another checkout holds the repository run lock (pid %d); stop it before '
                      'releasing' % os.getpid(), err.getvalue())
        self.assertEqual(self.b.card(12)['state'], 'in_progress')

    def test_listing_warns_that_a_running_run_may_own_listed_cards(self):
        self.b.seed(12, 'in_progress')
        self.hold_lock(os.getpid())
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck'], env=os.environ, stdout=out, stderr=err, transport=self.no_supervisor)
        self.assertEqual(rc, 0, err.getvalue())
        lines = out.getvalue().splitlines()
        self.assertIn('pid %d' % os.getpid(), lines[0])
        self.assertTrue(lines[0].startswith('note: a supervisor of another checkout holds the repository run lock '
                                            '(pid %d)' % os.getpid()), lines[0])
        self.assertIn('#12 in_flight: ', out.getvalue())
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--json'], env=os.environ, stdout=out, stderr=err, transport=self.no_supervisor)
        self.assertEqual(rc, 0, err.getvalue())
        self.assertEqual([r['card'] for r in json.loads(out.getvalue())], [12], 'json stays parseable')
        self.assertIn('pid %d' % os.getpid(), err.getvalue())

    def test_release_proceeds_when_the_lock_holder_is_the_supervisor_that_answered(self):
        self.b.seed(12, 'in_progress')
        self.hold_lock(os.getpid())
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--release', '12'], env=os.environ, stdout=out, stderr=err,
                      transport=lambda request: {'active': [], 'pid': os.getpid()})
        self.assertEqual(rc, 0, err.getvalue())
        self.assertEqual(self.b.card(12)['state'], 'ready')

    def test_a_lock_naming_a_dead_process_does_not_block_release(self):
        self.b.seed(12, 'in_progress')
        path = Path(service.default_run_lock_path(self.root))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('%d\nThu Jan  1 00:00:00 1970\n' % dead_pid())
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--release', '12'], env=os.environ, stdout=out, stderr=err,
                      transport=self.no_supervisor)
        self.assertEqual(rc, 0, err.getvalue())

    def test_the_cli_force_flag_releases_a_card_without_a_finding(self):
        self.b.seed(13, 'in_review')
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['stuck', '--release', '13'], env=os.environ, stdout=out, stderr=err,
                      transport=self.no_supervisor)
        self.assertEqual(rc, 1)
        self.assertIn('--force', err.getvalue())
        rc = cli.main(['stuck', '--release', '13', '--force'], env=os.environ, stdout=out, stderr=err,
                      transport=self.no_supervisor)
        self.assertEqual(rc, 0, err.getvalue())


if __name__ == '__main__':
    unittest.main()
