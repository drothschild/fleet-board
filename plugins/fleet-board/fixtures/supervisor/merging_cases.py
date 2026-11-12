"""The merge lane inside the supervisor loop: a real child process per merge (a stub standing in for
merge-reviewed.sh --no-finish), real board scripts, a scripted candidate feed and a stubbed --inspect."""
import json
import os
import signal
import sys
import time
import unittest
from pathlib import Path

BASE = Path(sys.argv.pop())
PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'fixtures' / 'supervisor'))
sys.argv.append(str(BASE))        # loop_cases pops the base directory too
import driver_cases as dc  # noqa: E402
import loop_cases as lc  # noqa: E402
from supervisor import candidates, merging, scripts  # noqa: E402

BASE = lc.BASE
STUB = '''#!/bin/bash
d="$MERGE_STUB_DIR"
echo "$$ $*" >> "$d/spawns"
while [ -e "$d/hold" ]; do sleep 0.05; done
cat "$d/stderr" >&2 2>/dev/null
exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
'''
OBSERVED = {'status': 'observed', 'state': 'MERGED', 'planned_head': 'abc1234', 'observed_head': 'abc1234',
            'main_check': {'commit': 'c0ffee1', 'ok': True, 'results': []}}
OPEN = dict(OBSERVED, state='OPEN', main_check=None)
LINT = {'name': 'lint-docs', 'reason': 'flaky', 'until': '2026-12-31'}


class MergeCase(lc.LoopCase):
    def setUp(self):
        super().setUp()
        self.stub_dir = self.dir / 'stub'
        self.stub_dir.mkdir()
        (self.stub_dir / 'merge.sh').write_text(STUB)
        self.hold = self.stub_dir / 'hold'
        self.addCleanup(lambda: self.hold.exists() and self.hold.unlink())
        self.inspect = dict(OBSERVED)
        self.inspected = []
        self.mergers = []
        self.warnings = []
        self.ignored = []
        self.merge_cards = [12]
        self.b.stubs['merge-reviewed.sh'] = self.do_inspect
        self.b.driver.begin_merger = lambda card, mode, detail: self.mergers.append((card, mode, detail))
        self.lane = merging.MergeLane(self.b.root, self.b.state, run=self.b.run, spawn=self.spawn, clock=self.clock)
        self.sup.merge_lane = self.lane
        self.in_review(12)
        self.b.put_note({'last_review': dc.LAST_REVIEW}, 12)
        self.rows = self.feed

    def spawn(self, root, name, *args, env=None):
        assert name == 'merge-reviewed.sh', name
        return scripts.spawn_argv(root, ['bash', str(self.stub_dir / 'merge.sh')] + [str(a) for a in args],
                                  env={'MERGE_STUB_DIR': str(self.stub_dir)})

    def do_inspect(self, *args):
        self.inspected.append(args)
        return dc.ok(json.dumps(self.inspect))

    def fetch(self, root, run=None, now=None):
        return super().fetch(root, run, now)._replace(warnings=list(self.warnings))

    def spawns(self):
        path = self.stub_dir / 'spawns'
        return [line.split(' ', 1) for line in path.read_text().splitlines()] if path.exists() else []

    def feed(self):
        spawned = ' '.join(args for _, args in self.spawns())
        rows = []
        for n in self.merge_cards:
            if ('--card %d ' % n) not in spawned + ' ' or n in self.b.state.active:
                rows.append(dc.candidate('merge', number=n, state='in_review', declared_paths=['p%d' % n],
                                         head_sha='abc1234', pr=34, ignored_checks=self.ignored))
        return rows + [r for r in self.plan() if r['number'] not in self.merge_cards]

    def stderr(self, text, rc):
        (self.stub_dir / 'stderr').write_text(text)
        (self.stub_dir / 'rc').write_text(str(rc))

    def spawned(self, count=1):
        return self.until(lambda: len(self.spawns()) >= count and self.spawns(), what='%d merge child(ren)' % count)


class Merging(MergeCase):
    def test_merged_card_goes_to_after_merge(self):
        self.ignored = [LINT]
        self.start()
        self.until(lambda: self.mergers, what='the merged hook')
        card, mode, detail = self.mergers[0]
        self.assertEqual((card, mode), (12, 'merged'))
        self.assertEqual(self.spawns()[0][1], '--no-finish --card 12 --operation-key run-1-12-1 --pr 34 --head abc1234')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual(self.b.note(12)['state'], 'merging')
        self.assertEqual([e['name'] for e in self.b.note(12)['ignored_checks']], ['lint-docs'])
        self.until(lambda: self.b.state.lane is None, what='the lane to free')
        self.assertEqual(self.inspected[0][:2], ('--inspect', '--card'))

    def test_an_unwritable_ignored_check_is_an_event_and_never_crashes_the_lane(self):
        self.ignored = [dict(LINT, name='bad\x01name')]
        self.start()
        self.until(lambda: self.mergers, what='the merged hook')
        events = [e for e in self.b.state.events if e['type'] == 'ignored_checks_failed']
        self.assertEqual(len(events), 1, list(self.b.state.events))
        self.assertEqual(self.mode(), 'running')
        self.assertNotIn('ignored_checks', self.b.note(12))

    def test_merger_hook_not_built_leaves_the_card_in_merging(self):
        del self.b.driver.begin_merger          # the real hook raises NotImplementedError until task 4.5
        self.start()
        self.until(lambda: any(e['type'] == 'merger_pending' for e in self.b.state.events), what='the event')
        event = [e for e in self.b.state.events if e['type'] == 'merger_pending'][0]
        self.assertEqual(event['payload']['message'], 'merger arrives in task 4.5')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual(self.mode(), 'running')

    def test_refusal_affects_only_its_card(self):
        self.add_card(13, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': lc.BRANCH[13],
                         'worktree': self.b.worktree}, 13)
        self.b.plans({'report': 'reviewer-ok', 'post': False})
        self.inspect = dict(OPEN)
        self.stderr('gh: merge not allowed: base branch policy\n', 1)
        self.start()
        self.until(lambda: self.b.note(13).get('last_review') and self.mergers, what='13 reviewed and 12 refused')
        card, mode, detail = self.mergers[0]
        self.assertEqual((card, mode), (12, 'refused'))
        self.assertIn('base branch policy', detail['reason'])
        refusal = self.b.note(12)['merge_refusal']
        self.assertEqual((refusal['pr'], refusal['head']), (34, 'abc1234'))
        self.assertIn('base branch policy', refusal['reason'])
        self.assertTrue(refusal['at'].endswith('Z'))
        self.assertEqual(self.mode(), 'running')
        self.assertIsNone(self.b.state.lane)

    def test_unclear_result_pauses_the_board(self):
        self.inspect = {'status': 'unmatched'}
        self.stderr('boom\n', 1)
        self.start()
        self.until(lambda: self.mode() == 'paused', what='the pause')
        self.assertIn('#12', self.b.state.snapshot()['pause_reason'])
        self.assertEqual(self.mergers, [])
        self.assertIsNone(self.b.state.lane)

    def test_failed_verification_pauses_the_board(self):
        self.inspect = dict(OBSERVED, main_check={'commit': 'c0ffee1', 'ok': False, 'results': []})
        self.stderr('main is red\n', 3)
        self.start()
        self.until(lambda: self.mode() == 'paused', what='the pause')
        reason = self.b.state.snapshot()['pause_reason']
        self.assertIn('#12', reason)
        self.assertIn('verification', reason)
        self.assertEqual(self.mergers, [])

    def test_one_merge_at_a_time(self):
        for n in (13,):
            self.add_card(n, 'in_review')
            self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': lc.BRANCH[n],
                             'worktree': self.b.worktree}, n)
        self.merge_cards = [12, 13]
        self.hold.write_text('')
        self.start()
        self.spawned(1)
        self.cycles_done(3)
        self.assertEqual(len(self.spawns()), 1, 'a second merge started while one was in flight')
        waits = {w['number']: w['reason'] for w in self.sup.last_cycle['waits']}
        self.assertIn('merge lane busy', list(waits.values()))
        self.hold.unlink()
        self.spawned(2)
        keys = sorted(args.split('--operation-key ')[1].split(' ')[0] for _, args in self.spawns())
        self.assertEqual([k.rsplit('-', 1)[1] for k in keys], ['1', '2'])
        self.until(lambda: len(self.mergers) == 2, what='both merges classified')

    def test_cancel_waits_for_an_in_flight_merge(self):
        self.hold.write_text('')
        self.start()
        pid = int(self.spawned(1)[0][0])
        self.sup.on_signal(signal.SIGINT)
        self.sup.on_signal(signal.SIGINT)           # a second Ctrl-C still does not kill the merge
        time.sleep(1.5)
        self.assertTrue(self.thread.is_alive(), 'the supervisor exited with a merge in flight')
        self.assertTrue(lc.alive(pid), 'the merge child was killed')
        self.assertEqual(self.mode(), 'stopping')
        self.hold.unlink()
        self.assertEqual(self.finished(), 0)
        self.assertFalse(lc.alive(pid))
        self.assertIsNone(self.b.state.lane)
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual(self.mergers, [], 'no merger session starts while stopping')

    def test_planner_warnings_are_recorded_once(self):
        self.merge_cards = []
        self.warnings = ['merge.ignore_checks entry x expired 2026-11-10']
        self.start()
        self.cycles_done(4)
        found = [e for e in self.b.state.events if e['type'] == 'planner_warning']
        self.assertEqual([e['payload']['message'] for e in found], self.warnings)


class Lane(MergeCase):
    def test_refusal_names_a_failing_required_check(self):
        calls = []

        def gh(root, *args):
            calls.append(args)
            return dc.ok(json.dumps([{'name': 'lint', 'bucket': 'pass'}, {'name': 'build', 'bucket': 'fail'}]))

        lane = merging.MergeLane(self.b.root, self.b.state, run=self.b.run, spawn=self.spawn, clock=self.clock,
                                 gh=gh, repo='acme/toy')
        self.inspect = dict(OPEN)
        self.stderr('refused\n', 1)
        lane.start(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
        end = time.monotonic() + 20
        outcome = None
        while outcome is None and time.monotonic() < end:
            outcome = lane.poll()
            time.sleep(0.05)
        self.assertEqual(outcome.kind, 'refused')
        self.assertEqual(outcome.detail['required_check'], 'build')
        self.assertEqual(calls[0][:4], ('pr', 'checks', '34', '--repo'))

    def test_a_malformed_candidate_never_spawns(self):
        for bad in (dict(head_sha='not-hex!'), dict(pr=0), dict(pr=None), dict(head_sha=None)):
            with self.assertRaises(ValueError):
                self.lane.start(dc.candidate('merge', number=12, state='in_review', **dict({'head_sha': 'abc1234'},
                                                                                         **bad)))
        self.assertEqual(self.spawns(), [])
        self.assertIsNone(self.b.state.lane)


if __name__ == '__main__':
    unittest.main()
