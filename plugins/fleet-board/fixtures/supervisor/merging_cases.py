"""The merge lane inside the supervisor loop: a real child process per merge (a stub standing in for
merge-reviewed.sh --no-finish), real board scripts, a scripted candidate feed and a stubbed --inspect."""
import json
import os
import signal
import subprocess
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
from supervisor import candidates, driver, loop, merging, scripts, state  # noqa: E402

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
ABSENT = {'status': 'absent', 'state': 'OPEN', 'planned_head': 'abc1234', 'observed_head': 'abc1234', 'pr': 34}
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

    def test_merged_card_runs_the_real_merger_and_finishes(self):
        self.b.config = dict(self.b.config, merge={'persona_append': 'extra'})
        del self.b.driver.begin_merger           # the driver's own merger flow
        self.b.plans({'report': 'merger-after-merge-done', 'post': False})
        self.start()
        self.until(lambda: 12 not in self.b.state.active and self.b.card(12)['state'] == 'done',
                   what='the merger to finish the card')
        note = self.b.note(12)
        self.assertEqual(note['merger'], {'mode': 'after_merge', 'status': 'done', 'head': 'abc1234'})
        self.assertEqual(note['state'], 'done')
        self.assertEqual(self.mode(), 'running')

    def test_a_deferred_merger_runs_after_a_restart(self):
        self.b.config = dict(self.b.config, merge={'persona_append': 'extra'})
        del self.b.driver.begin_merger
        self.hold.write_text('')
        self.start()
        self.spawned(1)
        self.sup.on_signal(signal.SIGINT)
        self.hold.unlink()
        self.assertEqual(self.finished(), 0)
        self.assertTrue(any(e['type'] == 'merger_deferred' for e in self.b.state.events))
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertNotIn('merger', self.b.note(12))
        # A fresh supervisor over the same board: the planner plans after_merge (no merger result yet)
        self.b.state = state.State('run-2')
        self.b.driver = driver.CardDriver(self.b.root, lambda: self.b.config, self.b.state, run=self.b.run,
                                          gh=self.b.gh, git=self.b.git, env=self.b.env, log_dir=self.dir / 'logs2')
        self.b.plans({'report': 'merger-after-merge-done', 'post': False})

        def planned():
            done = (self.b.note(12).get('merger') or {}).get('status') == 'done'
            return [dc.candidate('skip' if done else 'after_merge', number=12, state=self.b.card(12)['state'],
                                 pr=34, head_sha='abc1234', declared_paths=['p12'])]
        self.rows = planned
        self.sched = lc.SpyScheduler(clock=self.clock)
        self.sup = loop.Supervisor(self.b.root, config_loader=self.load, state=self.b.state, driver=self.b.driver,
                                   scheduler=self.sched, fetch=self.fetch, clock=self.clock, mono=self.mono,
                                   run=self.b.run, merge_lane=merging.MergeLane(
                                       self.b.root, self.b.state, run=self.b.run, spawn=self.spawn, clock=self.clock))
        self.start()
        self.until(lambda: self.b.card(12)['state'] == 'done', what='the merger after the restart')
        self.assertEqual(self.count(), 1)

    def test_a_merge_retry_is_held_until_its_time(self):
        self.merge_cards = []
        later = {'at': self.clock() + 3600}

        def feed():
            if self.spawns():
                return [r for r in self.plan() if r['number'] != 12]
            return [dc.candidate('merge', number=12, state='in_review', declared_paths=['p12'], head_sha='abc1234',
                                 pr=34, retry_after=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(later['at'])))]
        self.rows = feed
        self.start()
        self.cycles_done(2)
        self.assertEqual(self.spawns(), [])
        reasons = [w['reason'] for w in self.sup.last_cycle['waits'] if w['number'] == 12]
        self.assertTrue(reasons and reasons[0].startswith('merge retry at '), self.sup.last_cycle)
        later['at'] = self.clock() - 5
        self.spawned(1)

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

    def test_the_merge_child_owns_the_active_marker_until_it_ends(self):
        self.hold.write_text('')
        self.start()
        pid = int(self.spawned(1)[0][0])
        path = self.b.root / '.fleet-board' / 'active' / '12'
        marker = self.until(lambda: path.exists() and json.loads(path.read_text()), what='the merge marker')
        self.assertEqual(marker['pgid'], pid)
        self.assertEqual(marker['supervisor_pid'], os.getpid())
        self.hold.unlink()
        self.until(lambda: self.b.state.lane is None, what='the lane to free')
        self.assertFalse(path.exists(), 'the merge left its marker')

    def test_a_merge_that_ends_while_paused_defers_the_merger(self):
        self.hold.write_text('')
        self.start()
        self.spawned(1)
        self.sup.handle({'command': 'pause'})
        self.until(lambda: self.mode() == 'paused', what='the pause')
        self.hold.unlink()
        self.until(lambda: any(e['type'] == 'merger_deferred' for e in self.b.state.events), what='the deferral')
        deferred = [e['payload'] for e in self.b.state.events if e['type'] == 'merger_deferred']
        self.assertEqual(deferred[0]['message'], 'paused')
        self.assertEqual(self.mergers, [], 'no merger session starts while the board is paused')
        self.assertEqual(self.b.card(12)['state'], 'merging')

    def test_a_planner_skip_is_not_attempted_and_never_pauses(self):
        self.inspect = dict(ABSENT)
        self.start()
        self.until(lambda: any(e['type'] == 'merge_not_attempted' for e in self.b.state.events),
                   what='the not-attempted event')
        event = [e for e in self.b.state.events if e['type'] == 'merge_not_attempted'][0]
        self.assertEqual(event['payload']['reason'], 'merge not attempted: planner skipped')
        self.cycles_done(2)
        self.assertEqual(self.mode(), 'running')
        self.assertEqual(self.mergers, [])
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertIsNone(self.b.state.lane)

    def test_a_failing_note_write_for_ignored_checks_never_ends_the_supervisor(self):
        self.ignored = [LINT]

        def note(*args):
            if args[0] == 'merge' and 'ignored_checks' in Path(str(args[2])).read_text():
                return dc.fail_with('note.sh: cannot write the note')
            return scripts.run(self.b.root, 'note.sh', *args, env=self.b.env)
        self.b.stubs['note.sh'] = note
        self.start()
        self.until(lambda: self.mergers, what='the merger after a failed ignored-checks write')
        self.assertEqual(self.mergers[0][:2], (12, 'merged'))
        events = [e for e in self.b.state.events if e['type'] == 'ignored_checks_failed']
        self.assertEqual(len(events), 1, list(self.b.state.events))
        self.assertIn('cannot write the note', events[0]['payload']['message'])
        self.cycles_done(2)
        self.assertTrue(self.thread.is_alive(), 'the supervisor exited')
        self.assertEqual(self.mode(), 'running')

    def test_planner_warnings_are_recorded_once(self):
        self.merge_cards = []
        self.warnings = ['merge.ignore_checks entry x expired 2026-11-10']
        self.start()
        self.cycles_done(4)
        found = [e for e in self.b.state.events if e['type'] == 'planner_warning']
        self.assertEqual([e['payload']['message'] for e in found], self.warnings)


DONE_NOTE = {'state': 'merging', 'pr': 34, 'branch': lc.BRANCH[12], 'round': 1,
             'last_review': dict(dc.LAST_REVIEW, important=0, findings=[]), 'merged_pr': 34,
             'main_check': {'commit': 'c0ffee1', 'ok': True, 'results': []}}
REFUSAL = {'pr': 34, 'head': 'abc1234', 'reason': 'gh: merge not allowed: base branch policy', 'rc': 1}
MERGED = {'pr': 34, 'head': 'abc1234', 'reason': 'merged', 'rc': 0}
NOW = 1762862400.0   # 2025-11-11T12:00:00Z


class MergerFlow(unittest.TestCase):
    """CardDriver.begin_merger and finish for role merger, on a real local board with fake merger sessions."""

    def setUp(self):
        self.dir = BASE / self.id().rsplit('.', 1)[-1]
        self.dir.mkdir()
        # persona_append: with the plugin default persona alone no session starts (card 366); these cases need one
        self.b = dc.Board(self.dir, dict(dc.CONFIG, supervisor={'retry_backoff_seconds': 60},
                                         merge={'persona_append': 'Report any extra steps.'}))
        self.b.seed(12, 'merging', body='plain body')
        self.b.put_note(dict(DONE_NOTE, worktree=self.b.worktree))
        self.b.driver.clock = lambda: NOW
        self.ledger = []
        self.b.driver.ledger = lambda root, line, board_dir: self.ledger.append(line)
        self.tracked = set()
        self.ls_files = None
        self.pr_files = []
        self.gh_files = None
        self.b.git_result = self.git
        self.b.gh_result = self.gh

    def git(self, *args):
        if args[:1] == ('ls-files',):
            if self.ls_files is not None:
                return self.ls_files
            return dc.ok(args[-1] + '\n') if args[-1] in self.tracked else dc.fail_with(
                "error: pathspec '%s' did not match any file(s) known to git" % args[-1])
        return dc.ok('abc1234\n')

    def gh(self, *args):
        if args[:2] == ('pr', 'view') and 'files' in args:
            if self.gh_files is not None:
                return self.gh_files
            return dc.ok(json.dumps({'files': [{'path': p} for p in self.pr_files]}))
        return dc.ok('')

    def refused(self, **extra):
        refusal = dict(REFUSAL, **extra)
        self.b.put_note({'merged_pr': None, 'main_check': None,
                         'merge_refusal': {'pr': 34, 'head': 'abc1234', 'reason': refusal['reason'],
                                           'at': '2025-11-11T11:59:00Z'},
                         'pending_merge': {'operation_key': 'run-1-12-1', 'pr': 34, 'head_sha': 'abc1234'}})
        return refusal

    def merger(self, mode, detail, report):
        self.b.plans({'report': report, 'post': False, 'usage': {'input_tokens': 10, 'output_tokens': 5}})
        action = self.b.driver.begin_merger(12, mode, detail)
        self.assertIsNotNone(action.session, list(self.b.state.events))
        self.assertEqual((action.action, action.role), ('after_merge' if mode == 'merged' else 'merge_refusal',
                                                        'merger'))
        end = time.monotonic() + 30
        while time.monotonic() < end:
            result = action.session.poll()
            if result is not None:
                return self.b.driver.finish(action, result)
            time.sleep(0.05)
        self.fail('merger session did not finish')

    def no_session(self, mode, detail):
        action = self.b.driver.begin_merger(12, mode, detail)
        self.assertIsNone(action.session)
        self.assertNotIn(12, self.b.state.active)
        self.assertEqual(self.b.fake_calls(), [])

    def attention_events(self):
        return [e['payload'] for e in self.b.state.events if e['type'] == 'attention']

    # after_merge -------------------------------------------------------------------------------------
    def test_after_merge_done_moves_the_card_to_done(self):
        outcome = self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertTrue(outcome.progressed)
        self.assertEqual(self.b.card(12)['state'], 'done')
        note = self.b.note(12)
        self.assertEqual((note['state'], note['action_failures']), ('done', 0))
        self.assertEqual(note['merger'], {'mode': 'after_merge', 'status': 'done', 'head': 'abc1234'})
        self.assertNotIn(12, self.b.state.active)
        prompt = self.b.prompt(1)
        for part in ('## Card number\n12', '## Card title\nAdd subtract', '## PR number\n34', '## Mode\nafter_merge',
                     '## PR head (pr_head)\nabc1234', '## Merge commit (merge_commit)\n', '# Default merger persona', '## Config\n', '## Scripts dir\n'):
            self.assertIn(part, prompt)
        argv = self.b.fake_calls()[0]['argv']
        self.assertEqual(argv[argv.index('--agent') + 1], 'fleet-board:merger')
        self.assertEqual(argv[argv.index('--model') + 1], 'sonnet')
        self.assertEqual([(l['action'], l['role'], l['input']) for l in self.ledger], [('after_merge', 'merger', 10)])

    def test_after_merge_done_runs_cleanup_done_once_after_the_move(self):
        self.b.stubs['cleanup-done.sh'] = dc.ok()
        self.merger('merged', MERGED, 'merger-after-merge-done')
        names = [c[0] for c in self.b.calls]
        self.assertEqual(self.b.card(12)['state'], 'done')
        self.assertEqual(names.count('cleanup-done.sh'), 1, self.b.calls)
        self.assertGreater(names.index('cleanup-done.sh'), names.index('board-move.sh'))

    def test_after_merge_done_cleanup_failure_is_only_a_warning(self):
        self.b.stubs['cleanup-done.sh'] = dc.fail_with('boom', 1)
        outcome = self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertTrue(outcome.progressed)
        self.assertEqual(self.b.card(12)['state'], 'done')
        warns = [e for e in self.b.state.events if e['type'] == 'warning'
                 and 'cleanup-done.sh' in e['payload']['message']]
        self.assertTrue(warns, list(self.b.state.events))

    def test_after_merge_attention_does_not_run_cleanup_done(self):
        self.b.stubs['cleanup-done.sh'] = dc.ok()
        self.merger('merged', MERGED, 'merger-after-merge-attention')
        self.assertNotIn('cleanup-done.sh', [c[0] for c in self.b.calls])

    def test_after_merge_attention_keeps_the_card_in_merging(self):
        self.merger('merged', MERGED, 'merger-after-merge-attention')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        merger = self.b.note(12)['merger']
        self.assertEqual((merger['mode'], merger['status'], merger['head']), ('after_merge', 'attention', 'abc1234'))
        self.assertIn('deploy step failed', merger['reason'])
        self.assertEqual([e['card'] for e in self.attention_events()], [12])

    def test_after_merge_block_moves_to_blocked(self):
        self.b.seed(12, 'merging', body='## After merge\n\n- `rm -rf x`\n')
        self.b.stubs['after-merge.sh'] = dc.ok(json.dumps({'outcome': 'blocked', 'results': [
            {'command': 'rm -rf x', 'status': 'refused', 'exit': 126}], 'note': ['x'],
            'comment': 'after-merge: rm is not on the allowlist'}))
        self.no_session('merged', MERGED)
        self.assertEqual(self.b.card(12)['state'], 'blocked')
        note = self.b.note(12)
        self.assertEqual((note['blocked_from'], note['state']), ('merging', 'blocked'))
        self.assertEqual(self.b.comments(12), ['after-merge: rm is not on the allowlist'])

    def test_after_merge_steps_run_before_the_merger_session(self):
        self.b.seed(12, 'merging', body='## After merge\n\n- `make deploy`\n')
        self.b.stubs['after-merge.sh'] = dc.ok(json.dumps({'outcome': 'done', 'results': [
            {'command': 'make deploy', 'status': 'ok', 'exit': 0}], 'note': [], 'comment': ''}))
        self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertEqual(self.b.note(12)['after_merge_results'], [{'command': 'make deploy', 'exit': 0}])
        self.assertEqual(self.b.card(12)['state'], 'done')
        names = self.b.scripts_called()
        self.assertLess(names.index('after-merge.sh'), names.index('parse-report.sh'))

    def test_the_planner_after_merge_action_runs_the_same_flow(self):
        self.b.plans({'report': 'merger-after-merge-done', 'post': False})
        started = self.b.driver.begin(dc.candidate('after_merge', state='merging', head_sha='abc1234', pr=34))
        self.assertEqual(started.kind, 'session')
        dc.run_role(self.b, started)
        self.assertEqual(self.b.card(12)['state'], 'done')

    # refusal -----------------------------------------------------------------------------------------
    def test_refusal_retry_sets_one_retry_and_clears_the_pending_merge(self):
        detail = self.refused()
        self.merger('refused', detail, 'merger-refusal-retry')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        note = self.b.note(12)
        self.assertEqual(note['merge_retry'], {'pr': 34, 'head': 'abc1234', 'after': '2025-11-11T12:01:00Z'})
        self.assertIsNone(note['pending_merge'])
        self.assertIsNone(note['merge_refusal'])
        self.assertEqual(note['merger'], {'mode': 'refusal', 'status': 'retry', 'head': 'abc1234'})
        self.assertEqual([l['action'] for l in self.ledger], ['merge_refusal'])

    def test_the_merger_ledger_lines_are_recorded_under_merging(self):
        self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertEqual([(l['action'], l['column']) for l in self.ledger], [('after_merge', 'merging')])

    def test_the_refusal_merger_ledger_line_is_recorded_under_merging(self):
        self.merger('refused', self.refused(), 'merger-refusal-retry')
        self.assertEqual([(l['action'], l['column']) for l in self.ledger], [('merge_refusal', 'merging')])

    def test_second_refusal_after_retry_is_attention(self):
        self.merger('refused', self.refused(), 'merger-refusal-retry')
        self.b.fake.joinpath('count').unlink()
        self.b.fake.joinpath('log.jsonl').unlink()
        self.no_session('refused', self.refused())      # spec section 6: straight to attention, no session
        note = self.b.note(12)
        self.assertIsNone(note['pending_merge'])
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual((note['merger']['mode'], note['merger']['status']), ('refusal', 'attention'))
        self.assertIn('after a retry', note['merger']['reason'])
        self.assertEqual(note['merge_retry']['head'], 'abc1234')
        self.assertEqual(len(self.attention_events()), 1)

    def test_refusal_fix_for_a_conflict_goes_through_update_branch(self):
        dc.worktree_ok(self.b)

        def update(*args):
            self.b.put_note({'conflicted_files': ['src/a.py']})
            return dc.fail_with('update-branch: merge conflict in src/a.py')
        self.b.stubs['update-branch.sh'] = update
        detail = self.refused(reason='Pull request is not mergeable: merge conflict')
        self.merger('refused', detail, 'merger-refusal-fix')
        self.assertIn(('update-branch.sh', '12', '34', lc.BRANCH[12], self.b.worktree), self.b.calls)
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        note = self.b.note(12)
        self.assertEqual(note['conflicted_files'], ['src/a.py'])
        self.assertEqual((note['state'], note['merge_refusal'], note['pending_merge']), ('in_review', None, None))

    def test_refusal_fix_for_a_conflict_leaves_no_marker_behind(self):
        from unittest import mock
        from supervisor import stuck
        active = self.b.root / '.fleet-board' / 'active'

        def tree(*a):
            if a[0] == 'create':   # comment.sh already dropped the session marker; fb_mark_active makes a fresh one
                active.mkdir(parents=True, exist_ok=True)
                (active / '12').unlink() if (active / '12').exists() else None
                (active / '12').write_text('')
            return dc.ok(self.b.worktree + '\n')
        self.b.stubs['worktree.sh'] = tree

        def update(*args):
            self.b.put_note({'conflicted_files': ['src/a.py']})
            return dc.fail_with('update-branch: merge conflict in src/a.py')
        self.b.stubs['update-branch.sh'] = update
        self.merger('refused', self.refused(reason='Pull request is not mergeable: merge conflict'),
                    'merger-refusal-fix')
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        self.assertFalse((active / '12').exists(), 'the empty marker the refusal fix made outlived the action')
        with mock.patch.dict(os.environ, {'FLEET_BOARD_USER': 'fleet-bot'}):
            self.assertEqual(stuck.find(self.b.root), [])

    def test_refusal_fix_ignores_a_stale_conflict_list(self):
        dc.worktree_ok(self.b)
        self.b.put_note({'conflicted_files': ['old.py']})
        self.b.stubs['update-branch.sh'] = dc.fail_with('update-branch: git fetch failed')
        self.merger('refused', self.refused(reason='merge conflict'), 'merger-refusal-fix')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        note = self.b.note(12)
        self.assertEqual((note['action_failures'], note['last_action_error']), (1, 'update-branch: git fetch failed'))

    def test_refusal_fix_clears_the_merge_retry(self):
        self.merger('refused', self.refused(), 'merger-refusal-retry')
        self.b.fake.joinpath('count').unlink()
        self.b.fake.joinpath('log.jsonl').unlink()
        self.b.put_note({'merge_retry': {'pr': 34, 'head': 'def5678', 'after': '2025-11-11T12:01:00Z'}})
        self.merger('refused', self.refused(), 'merger-refusal-fix')
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        self.assertIsNone(self.b.note(12)['merge_retry'])

    def test_refusal_fix_sends_the_reason_to_the_fixer(self):
        detail = self.refused()
        self.merger('refused', detail, 'merger-refusal-fix')
        self.assertNotIn('update-branch.sh', self.b.scripts_called())
        self.assertEqual(self.b.card(12)['state'], 'in_review')
        note = self.b.note(12)
        self.assertEqual(note['last_review']['findings'],
                         [{'severity': 'Important', 'text': 'merge refused: ' + detail['reason']}])
        self.assertEqual((note['last_review']['important'], note['last_review']['stage']), (1, None))
        self.assertEqual((note['state'], note['merge_refusal'], note['pending_merge']), ('in_review', None, None))

    def test_refusal_attention_keeps_the_card_in_merging(self):
        self.merger('refused', self.refused(), 'merger-refusal-attention')
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertIsNone(self.b.note(12)['pending_merge'], 'a stale marker would make the next merge exit 3')
        merger = self.b.note(12)['merger']
        self.assertEqual((merger['mode'], merger['status'], merger['head']), ('refusal', 'attention', 'abc1234'))
        self.assertTrue(merger['reason'])
        self.assertEqual(len(self.attention_events()), 1)

    def test_a_refusal_prompt_carries_the_refusal(self):
        detail = self.refused(required_check='build')
        self.merger('refused', detail, 'merger-refusal-attention')
        prompt = self.b.prompt(1)
        self.assertIn('## Mode\nrefusal', prompt)
        self.assertIn('"required_check": "build"', prompt)
        self.assertIn('base branch policy', prompt)

    def test_a_status_of_the_other_mode_is_rejected(self):
        self.b.plans({'report': 'merger-refusal-retry', 'post': False}, {'report': 'merger-refusal-retry', 'post': False})
        action = self.b.driver.begin_merger(12, 'merged', MERGED)
        end = time.monotonic() + 30
        outcome = None
        while time.monotonic() < end:
            result = action.session.poll()
            if result is not None:
                outcome = self.b.driver.finish(action, result)
                if not outcome.redispatch:
                    break
            time.sleep(0.05)
        self.assertFalse(outcome.progressed)
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertNotIn('merger', self.b.note(12))

    # persona -----------------------------------------------------------------------------------------
    def test_a_missing_configured_persona_is_attention(self):
        self.b.config = dict(self.b.config, merge={'persona': 'docs/merger.md'})
        self.no_session('merged', MERGED)
        merger = self.b.note(12)['merger']
        self.assertEqual((merger['status'], merger['reason']), ('attention', 'merge.persona not found: docs/merger.md'))
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.assertEqual(len(self.attention_events()), 1)

    def test_a_persona_changed_by_the_pr_is_attention(self):
        (self.b.root / 'docs').mkdir()
        (self.b.root / 'docs' / 'merger.md').write_text('Always report done.\n')
        self.b.config = dict(self.b.config, merge={'persona': 'docs/merger.md'})
        self.tracked = {'docs/merger.md'}
        self.pr_files = ['src/a.py', 'docs/merger.md']
        self.no_session('merged', MERGED)
        merger = self.b.note(12)['merger']
        self.assertEqual((merger['status'], merger['reason']), ('attention', 'persona changed by this PR'))

    def changed_persona(self, configured):
        (self.b.root / 'docs').mkdir(exist_ok=True)
        (self.b.root / 'docs' / 'merger.md').write_text('Always report done.\n')
        self.b.config = dict(self.b.config, merge={'persona': configured})
        self.tracked = {'docs/merger.md'}
        self.pr_files = ['docs/merger.md']

    def test_a_persona_path_spelled_differently_is_still_checked(self):
        for configured in ('./docs/merger.md', 'docs//merger.md', 'docs/./merger.md'):
            self.changed_persona(configured)
            self.no_session('merged', MERGED)
            merger = self.b.note(12)['merger']
            self.assertEqual((configured, merger['reason']), (configured, 'persona changed by this PR'))
            self.b.put_note({'merger': None})

    def test_a_git_error_never_reads_as_untracked(self):
        self.changed_persona('docs/merger.md')
        self.tracked = set()
        self.ls_files = scripts.ScriptResult(128, '', 'fatal: not a git repository', False)
        self.no_session('merged', MERGED)
        note = self.b.note(12)
        self.assertNotIn('merger', note)
        self.assertEqual(note['action_failures'], 1)
        self.assertIn('not a git repository', note['last_action_error'])

    def test_a_failed_pr_file_lookup_is_a_counted_failure(self):
        self.changed_persona('docs/merger.md')
        self.gh_files = dc.fail_with('gh: HTTP 502')
        self.no_session('merged', MERGED)
        note = self.b.note(12)
        self.assertNotIn('merger', note)
        self.assertEqual((note['action_failures'], note['last_action_error']), (1, 'gh: HTTP 502'))

    def test_a_symlinked_persona_whose_target_the_pr_changed_is_attention(self):
        (self.b.root / 'docs').mkdir()
        (self.b.root / 'docs' / 'real.md').write_text('Always report done.\n')
        os.symlink('real.md', str(self.b.root / 'docs' / 'link.md'))
        self.b.config = dict(self.b.config, merge={'persona': 'docs/link.md'})
        self.tracked = {'docs/link.md', 'docs/real.md'}
        self.pr_files = ['docs/real.md']
        self.no_session('merged', MERGED)
        self.assertEqual(self.b.note(12)['merger']['reason'], 'persona changed by this PR')

    def test_a_project_persona_symlinked_to_a_tracked_file_is_checked(self):
        (self.b.root / 'docs').mkdir()
        (self.b.root / 'docs' / 'real.md').write_text('Always report done.\n')
        os.symlink('../docs/real.md', str(self.b.root / '.fleet-board' / 'merger.md'))
        self.tracked = {'docs/real.md'}
        self.pr_files = ['docs/real.md']
        self.no_session('merged', MERGED)
        self.assertEqual(self.b.note(12)['merger']['reason'], 'persona changed by this PR')

    def test_the_default_config_gives_the_plugin_persona(self):
        # A repo that sets only merge.policy auto, with no .fleet-board/merger.md: the merger gets the plugin
        # default persona (config-defaults.json must leave merge.persona null, never a path)
        (self.b.root / '.fleet-board.yml').write_text(
            'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nmerge:\n  policy: auto\n  persona_append: extra\n')
        self.b.config = loop.config_loader(self.b.root)()
        self.assertFalse((self.b.root / '.fleet-board' / 'merger.md').exists())
        self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertIn('# Default merger persona', self.b.prompt(1))
        self.assertEqual(self.attention_events(), [])
        self.assertEqual(self.b.card(12)['state'], 'done')

    def test_the_project_persona_and_its_append_are_used(self):
        (self.b.root / '.fleet-board' / 'merger.md').write_text('PROJECT PERSONA\n')
        self.b.config = dict(self.b.config, merge={'persona': None, 'persona_append': 'APPENDED RULE'})
        self.merger('merged', MERGED, 'merger-after-merge-done')
        prompt = self.b.prompt(1)
        self.assertIn('PROJECT PERSONA', prompt)
        self.assertNotIn('# Default merger persona', prompt)
        self.assertLess(prompt.index('PROJECT PERSONA'), prompt.index('APPENDED RULE'))

    def test_a_tracked_persona_the_pr_left_alone_is_used(self):
        (self.b.root / 'docs').mkdir()
        (self.b.root / 'docs' / 'merger.md').write_text('TRACKED PERSONA\n')
        self.b.config = dict(self.b.config, merge={'persona': 'docs/merger.md'})
        self.tracked = {'docs/merger.md'}
        self.pr_files = ['src/a.py']
        self.merger('merged', MERGED, 'merger-after-merge-done')
        self.assertIn('TRACKED PERSONA', self.b.prompt(1))


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

    def test_the_merge_lane_action_works_in_merging_even_from_in_review(self):
        # Consistency only: the merge lane writes no ledger line today, so this has no ledger effect yet.
        self.lane.start(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
        action = self.b.state.active[12]
        self.assertEqual((action.column, state.ledger_column(action)), ('in_review', 'merging'))

    def outcome_of(self, candidate):
        self.lane.start(candidate)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            outcome = self.lane.poll()
            if outcome is not None:
                return outcome
            time.sleep(0.05)
        self.fail('the merge did not end')

    def test_rc0_with_no_marker_and_the_pr_open_at_the_planned_head_is_not_attempted(self):
        self.inspect = dict(ABSENT)
        outcome = self.outcome_of(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
        self.assertEqual(outcome.kind, 'not_attempted')
        self.assertEqual(outcome.detail['reason'], 'merge not attempted: planner skipped')
        self.assertIsNone(self.b.note(12).get('merge_refusal'))

    def test_rc0_with_no_marker_is_unclear_unless_open_at_the_planned_head(self):
        for inspect in (dict(ABSENT, state='MERGED'), dict(ABSENT, observed_head='def5678'), {'status': 'unmatched'}):
            self.inspect = inspect
            outcome = self.outcome_of(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
            self.assertEqual(outcome.kind, 'unclear', inspect)

    def test_a_card_moved_out_of_merging_by_hand_drops_its_merge_records(self):
        self.b.put_note({'merge_refusal': {'pr': 34, 'head': 'abc1234', 'reason': 'refused', 'at': '2026-11-11T00:00:00Z'},
                         'merge_retry': {'pr': 34, 'head': 'abc1234', 'after': '2026-11-11T00:01:00Z'},
                         'pending_merge': {'operation_key': 'run-0-12-1', 'pr': 34, 'head_sha': 'abc1234'},
                         'merger': {'mode': 'refusal', 'status': 'attention', 'head': 'abc1234', 'reason': 'x'}})
        self.hold.write_text('')
        self.lane.start(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
        note = self.b.note(12)
        self.hold.unlink()
        for key in ('merge_refusal', 'merge_retry', 'pending_merge', 'merger'):
            self.assertIsNone(note.get(key), key)
        self.assertEqual((note['state'], self.b.card(12)['state']), ('merging', 'merging'))
        self.until(lambda: self.lane.poll() is not None or not self.lane.busy, what='the lane to free')

    def test_a_card_already_in_merging_keeps_its_merge_records(self):
        self.b.seed(12, 'merging')
        retry = {'pr': 34, 'head': 'abc1234', 'after': '2026-11-11T00:01:00Z'}
        self.b.put_note({'merge_retry': retry})
        self.hold.write_text('')
        self.lane.start(dc.candidate('merge', number=12, state='merging', head_sha='abc1234', pr=34))
        note = self.b.note(12)
        self.hold.unlink()
        self.assertEqual(note['merge_retry'], retry)
        self.until(lambda: self.lane.poll() is not None or not self.lane.busy, what='the lane to free')

    def test_merge_lane_start_moves_the_card_to_merging_before_merge_reviewed_runs(self):
        seen = []
        real = self.lane.spawn

        def spawn(root, name, *args, **kw):
            seen.append((name, self.b.card(12)['state'], self.b.note(12).get('state')))
            return real(root, name, *args, **kw)
        self.lane.spawn = spawn
        self.hold.write_text('')
        self.lane.start(dc.candidate('merge', number=12, state='in_review', head_sha='abc1234', pr=34))
        self.hold.unlink()
        self.assertEqual(seen, [('merge-reviewed.sh', 'merging', 'merging')])
        self.until(lambda: self.lane.poll() is not None or not self.lane.busy, what='the lane to free')

    def test_a_card_already_in_merging_is_not_moved_again(self):
        self.b.seed(12, 'merging')
        self.hold.write_text('')
        self.lane.start(dc.candidate('merge', number=12, state='merging', head_sha='abc1234', pr=34))
        self.hold.unlink()
        self.assertNotIn(('board-move.sh', '12', 'merging'), self.b.calls)
        self.assertEqual([c for c in self.b.calls if c[0] == 'board-move.sh'], [])
        self.assertEqual(self.b.card(12)['state'], 'merging')
        self.until(lambda: self.lane.poll() is not None or not self.lane.busy, what='the lane to free')

    def test_a_card_in_human_qa_is_not_moved(self):
        self.b.seed(12, 'human_qa')
        with self.assertRaises(ValueError):
            self.lane.start(dc.candidate('merge', number=12, state='human_qa', head_sha='abc1234', pr=34))
        self.assertEqual(self.b.card(12)['state'], 'human_qa')
        self.assertEqual([c for c in self.b.calls if c[0] == 'board-move.sh'], [])
        self.assertEqual(self.spawns(), [])
        self.assertFalse(self.lane.busy)

    def test_a_malformed_candidate_never_spawns(self):
        for bad in (dict(head_sha='not-hex!'), dict(pr=0), dict(pr=None), dict(head_sha=None)):
            with self.assertRaises(ValueError):
                self.lane.start(dc.candidate('merge', number=12, state='in_review', **dict({'head_sha': 'abc1234'},
                                                                                         **bad)))
        self.assertEqual(self.spawns(), [])
        self.assertIsNone(self.b.state.lane)


CHAIN_YML = ('board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nmerge:\n  policy: auto\nreview:\n  stages:\n'
             '    - name: security\n      agent: sec-reviewer\n      model: opus\n'
             '    - name: perf\n      agent: perf-reviewer\n      model: sonnet\n')
CHAIN_GH = r'''#!/bin/bash
d="$CHAIN_GH_DIR"
printf '%s\n' "$*" >> "$d/calls"
case "$1 $2" in
  "pr view")
    case "$*" in
      *files*) printf '{"files":[{"path":"src/calc.js"}],"changedFiles":1}\n' ;;
      *mergeable*) printf '{"mergeable":"MERGEABLE"}\n' ;;
      *title,body,commits*) cat "$d/closing.json" ;;
      *) cat "$d/pr.json" ;;
    esac ;;
  "pr list") printf '[]\n' ;;
  "pr checks") printf '[]\n' ;;
  "pr merge")
    jq -c '.state = "MERGED" | .mergedAt = "2026-11-11T00:00:00Z"' "$d/pr.json" > "$d/pr.tmp" && mv "$d/pr.tmp" "$d/pr.json" ;;
  *) printf 'chain gh: unexpected call: %s\n' "$*" >&2; exit 99 ;;
esac
'''
# the merge-time closing-keyword check (pr-closing-check.sh) reads title, body and commits
CHAIN_CLOSING = {'title': 'Add subtract', 'body': 'Local board card 12',
                 'commits': [{'oid': 'abc1234', 'messageHeadline': 'feat: subtract', 'messageBody': ''}]}
CHAIN_PR = {'isDraft': False, 'state': 'OPEN', 'mergedAt': None, 'headRefOid': 'abc1234',
            'statusCheckRollup': [{'name': 'build', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}]}


class Chained(unittest.TestCase):
    """The real chain: tick-plan.sh --candidates -> MergeLane -> merge-reviewed.sh --no-finish (keyed) ->
    --inspect, on a real local board with a fake gh. The card was routed to only the first of two stages."""

    def setUp(self):
        self.dir = BASE / ('chain-' + self.id().rsplit('.', 1)[-1])
        self.dir.mkdir()
        self.root = self.dir / 'repo'
        self.root.mkdir()
        subprocess.run(['git', '-C', str(self.root), 'init', '-q'], check=True)
        (self.root / '.fleet-board.yml').write_text(CHAIN_YML)
        (self.root / '.fleet-board' / 'cards').mkdir(parents=True)
        (self.root / '.fleet-board' / 'next').write_text('100\n')
        card = {'number': 12, 'title': 'Add subtract', 'body': 'plain body', 'state': 'review_security',
                'labels': ['needs-security-review'], 'acceptance': ['does it'], 'blocked_by': [],
                'next_comment_id': 1, 'comments': [], 'created_at': '2026-01-01T00:00:00Z'}
        (self.root / '.fleet-board' / 'cards' / '12.json').write_text(json.dumps(card))
        gh_dir = self.dir / 'gh'
        bin_dir = self.dir / 'bin'
        gh_dir.mkdir()
        bin_dir.mkdir()
        (bin_dir / 'gh').write_text(CHAIN_GH)
        (bin_dir / 'gh').chmod(0o755)
        (gh_dir / 'pr.json').write_text(json.dumps(CHAIN_PR))
        (gh_dir / 'closing.json').write_text(json.dumps(CHAIN_CLOSING))
        verify = self.dir / 'verify-main.sh'
        verify.write_text('#!/bin/bash\nprintf \'{"commit":"c0ffee1","ok":true,"results":[]}\\n\'\n')
        verify.chmod(0o755)
        self.gh_dir = gh_dir
        self.env = {'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'], 'CHAIN_GH_DIR': str(gh_dir),
                    'FLEET_BOARD_USER': 'fleet-bot', 'FLEET_BOARD_VERIFY_MAIN': str(verify)}
        self.put_note({'state': 'review_security', 'branch': lc.BRANCH[12], 'pr': 34, 'round': 1,
                       'stage': 'security', 'reviewed_stages': [],
                       'last_review': {'round': 1, 'sha': 'abc1234', 'stage': 'security', 'critical': 0,
                                       'important': 0, 'findings': []}})
        self.state = state.State('run-1')
        self.lane = merging.MergeLane(self.root, self.state, run=self.script, spawn=self.spawn)

    def script(self, root, name, *args, **kw):
        return scripts.run(root, name, *args, env=self.env, **kw)

    def spawn(self, root, name, *args):
        return scripts.spawn(root, name, *args, env=self.env)

    def put_note(self, patch):
        path = self.dir / 'patch.json'
        path.write_text(json.dumps(patch))
        done = self.script(self.root, 'note.sh', 'merge', 12, str(path))
        self.assertEqual(done.rc, 0, done)

    def note(self):
        done = self.script(self.root, 'note.sh', 'get', 12)
        self.assertEqual(done.rc, 0, done)
        return json.loads(done.stdout)

    def card(self):
        return json.loads((self.root / '.fleet-board' / 'cards' / '12.json').read_text())

    def candidate(self):
        batch = candidates.fetch(self.root, run=self.script)
        self.assertIsNone(batch.error, batch)
        rows = [r for r in batch.candidates if r.get('number') == 12]
        self.assertEqual([r['action'] for r in rows], ['merge'], batch.candidates)
        return rows[0]

    def ended(self, row):
        self.lane.start(row)
        end = time.monotonic() + 60
        while time.monotonic() < end:
            outcome = self.lane.poll()
            if outcome is not None:
                return outcome
            time.sleep(0.05)
        self.fail('merge-reviewed.sh did not end')

    def test_a_card_routed_to_only_the_first_of_two_stages_merges(self):
        row = self.candidate()
        self.assertEqual(row['state'], 'review_security')
        outcome = self.ended(row)
        self.assertEqual(outcome.kind, 'merged', outcome)
        self.assertEqual(self.card()['state'], 'merging')
        note = self.note()
        self.assertEqual((note['merged_pr'], note['main_check']['ok'], note['state']), (34, True, 'merging'))
        self.assertEqual(note['merge_operation']['operation_key'], 'run-1-12-1')
        calls = (self.gh_dir / 'calls').read_text()
        self.assertEqual(calls.count('pr merge 34 '), 1, calls)
        # merged and verified, no merger result yet: the planner hands the card to the merger
        after = [r for r in candidates.fetch(self.root, run=self.script).candidates if r.get('number') == 12]
        self.assertEqual([r['action'] for r in after], ['after_merge'])

    def test_a_closing_keyword_in_a_commit_message_is_refused_and_never_merged(self):
        # card numbers are not GitHub numbers: merge-reviewed.sh refuses after its keyed marker, so the lane
        # observes the open PR at the planned head and classifies the refusal (the merger decides)
        row = self.candidate()
        closing = {'title': 'Add subtract', 'body': 'Local board card 12',
                   'commits': [{'oid': 'abc1234', 'messageHeadline': 'feat: subtract', 'messageBody': 'Fixes #253'}]}
        (self.gh_dir / 'closing.json').write_text(json.dumps(closing))
        outcome = self.ended(row)
        self.assertEqual(outcome.kind, 'refused', outcome)
        self.assertIn('closing keyword before an issue reference', outcome.detail['reason'])
        self.assertNotIn('pr merge', (self.gh_dir / 'calls').read_text())
        self.assertEqual(self.note()['merge_refusal']['pr'], 34)

    def test_a_planner_skip_in_the_merge_is_not_attempted_and_never_pauses(self):
        row = self.candidate()
        red = dict(CHAIN_PR, statusCheckRollup=[{'name': 'build', 'status': 'COMPLETED', 'conclusion': 'FAILURE'}])
        (self.gh_dir / 'pr.json').write_text(json.dumps(red))   # the checks go red after the plan
        outcome = self.ended(row)
        self.assertEqual(outcome.kind, 'not_attempted', outcome)
        self.assertNotIn('pr merge', (self.gh_dir / 'calls').read_text())
        self.assertEqual(self.card()['state'], 'merging')
        self.assertIsNone(self.note().get('pending_merge'))
        mergers = []
        sup = loop.Supervisor(self.root, config_loader=lambda: {}, state=self.state,
                              driver=type('D', (), {'begin_merger': lambda s, *a: mergers.append(a)})(),
                              scheduler=None, run=self.script, merge_lane=self.lane)
        sup._merge_ended(outcome)
        self.assertNotEqual(self.state.mode, 'paused')
        self.assertEqual(mergers, [])
        self.assertIn('merge_not_attempted', [e['type'] for e in self.state.events])
        # the card stays in merging and is planned again (a skip while the checks are red)
        again = [r for r in candidates.fetch(self.root, run=self.script).candidates if r.get('number') == 12]
        self.assertNotIn('merge', [r['action'] for r in again])


if __name__ == '__main__':
    unittest.main()
