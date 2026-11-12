"""The supervisor loop on a fixture board: real fake-role child processes, real board scripts, a scripted
candidate feed (tick-plan.sh itself needs gh and is covered by the candidates suite)."""
import json
import os
import signal
import socket
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

BASE = Path(sys.argv.pop()).resolve()
PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'fixtures' / 'supervisor'))
import driver_cases as dc  # noqa: E402
from supervisor import candidates, errors, loop, scheduler, service  # noqa: E402

BRANCH = {12: 'fleet/12-add-subtract', 13: 'fleet/13-add-subtract', 14: 'fleet/14-add-subtract'}
SUP = {'reconcile_interval_seconds': 1, 'shutdown_grace_seconds': 2, 'retry_backoff_seconds': 1,
       'aging_seconds': 900, 'provider_concurrency': {}}


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class SpyScheduler(scheduler.Scheduler):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.calls = []

    def admit(self, candidates, **kw):
        self.calls.append((list(candidates), dict(kw)))
        return super().admit(candidates, **kw)


class LoopCase(unittest.TestCase):
    concurrency = 2
    max_hours = 8

    def setUp(self):
        self.dir = BASE / self.id().rsplit('.', 1)[-1]
        self.dir.mkdir()
        config = dict(dc.CONFIG, supervisor=dict(SUP),
                      limits={'concurrency': self.concurrency, 'rate_limit_margin': 0, 'rate_limit_max_wait': 3600,
                              'max_hours': self.max_hours})
        self.b = dc.Board(self.dir, config)
        self.b.seed(12)
        self.cards = [12]
        self.skew = 0.0
        self.mono_skew = 0.0
        self.bad_config = None
        self.rate = None
        self.fetches = 0
        self.fetch_gate = None
        self.fetch_raises = None
        self.rows = None
        self.thread = None
        self.rc = None
        self.crash = None
        dc.worktree_ok(self.b)
        self.b.stubs['review-stages.sh'] = dc.ok('[]\n')
        self.sched = SpyScheduler(clock=self.clock)
        self.sup = loop.Supervisor(self.b.root, config_loader=self.load, state=self.b.state, driver=self.b.driver,
                                   scheduler=self.sched, fetch=self.fetch, clock=self.clock, mono=self.mono,
                                   run=self.b.run)
        self.addCleanup(self.shutdown)

    # -- injected seams ------------------------------------------------------------------------------
    def clock(self):
        return time.time() + self.skew

    def mono(self):
        return time.monotonic() + self.mono_skew

    def load(self):
        if self.bad_config:
            raise ValueError(self.bad_config)
        return self.b.config

    def fetch(self, root, run=None, now=None):
        self.fetches += 1
        if self.fetch_gate is not None:
            self.fetch_gate.wait(20)
        if self.fetch_raises is not None:
            raise self.fetch_raises
        if self.rate is not None:
            return candidates.Batch([], self.rate, None)
        return candidates.Batch(self.rows() if self.rows else self.plan(), None, None)

    def plan(self):
        """The default feed: one ready -> implement -> review pass per seeded card."""
        rows = []
        for n in self.cards:
            note, state = self.b.note(n), self.b.card(n)['state']
            kw = dict(number=n, branch=BRANCH[n], worktree=self.b.worktree, state=state, declared_paths=['p%d' % n],
                      pr=note.get('pr') or 34)
            if note.get('pr') and state == 'in_progress' and not note.get('last_review'):
                rows.append(dc.candidate('start_review', **kw))
            elif note.get('last_review'):
                rows.append(dc.candidate('skip', **kw))
            elif state == 'in_review':
                rows.append(dc.candidate('review', round=1, **kw))
            elif state == 'in_progress':
                rows.append(dc.candidate('continue_implementor', **kw))
            else:
                rows.append(dc.candidate('start', **kw))
        return rows

    def implement_plan(self):
        """Implementation only: a card with a PR is done."""
        rows = []
        for n in self.cards:
            note, state = self.b.note(n), self.b.card(n)['state']
            kw = dict(number=n, branch=BRANCH[n], worktree=self.b.worktree, state=state, declared_paths=['p%d' % n])
            action = 'skip' if note.get('pr') else 'continue_implementor' if state == 'in_progress' else 'start'
            rows.append(dc.candidate(action, **kw))
        return rows

    # -- helpers -------------------------------------------------------------------------------------
    def add_card(self, number, state='ready'):
        self.b.seed(number, state)
        self.cards.append(number)

    def in_progress(self, number):
        """A card whose implementor already started once (what tick-plan plans continue_implementor for)."""
        self.b.seed(number, 'in_progress')
        self.b.put_note({'implementor_attempts': 1, 'branch': BRANCH[number], 'worktree': self.b.worktree,
                         'round': 0}, number)
        if number not in self.cards:
            self.cards.append(number)

    def in_review(self, number):
        self.b.seed(number, 'in_review')
        self.b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH[number],
                         'worktree': self.b.worktree}, number)
        if number not in self.cards:
            self.cards.append(number)

    def start(self):
        def target():
            try:
                self.rc = self.sup.run()
            except BaseException as exc:  # noqa: BLE001
                self.crash = exc
        self.thread = threading.Thread(target=target, daemon=True)
        self.thread.start()

    def until(self, check, timeout=20, what='condition'):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            value = check()
            if value:
                return value
            time.sleep(0.05)
        events = [(e['type'], e['payload']) for e in list(self.b.state.events)[-8:]]
        self.fail('timed out waiting for %s; mode %s, cycle %s, events %s' % (
            what, self.mode(), self.sup.last_cycle, events))

    def finished(self, timeout=20):
        self.thread.join(timeout)
        self.assertFalse(self.thread.is_alive(), 'the supervisor did not exit')
        self.assertIsNone(self.crash)
        return self.rc

    def count(self):
        path = self.b.fake / 'count'
        return int(path.read_text()) if path.exists() else 0

    def shutdown(self):
        if self.thread is not None and self.thread.is_alive():
            self.sup.request_stop('cancel', force=True)
            self.thread.join(15)
        for line in self.b.fake_calls():
            self.assertFalse(alive(line['pid']), 'a role session outlived the supervisor')

    def mode(self):
        return self.b.state.snapshot()['mode']

    def cycles_done(self, more=2):
        """Wait for `more` further cycles (the scheduler is called once per cycle that reaches admission)."""
        target = len(self.sched.calls) + more
        self.until(lambda: len(self.sched.calls) >= target, what='%d more cycles' % more)


class Flow(LoopCase):
    def test_two_cards_progress_concurrently(self):
        self.in_progress(12)
        self.in_review(13)
        self.b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 6},
                     {'report': 'reviewer-ok', 'post': False})
        self.start()
        self.until(lambda: self.b.note(13).get('last_review'), what="card 13's review")
        self.assertIn(12, self.b.state.snapshot()['active'], "card 12's slow implementor must still be running")
        self.assertIsNone(self.b.note(12).get('pr'))
        self.until(lambda: self.b.note(12).get('pr') == 12, what="card 12's implementor")
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_ready_to_clean_review_with_fake_roles(self):
        self.b.plans({'report': 'implementor-ok'}, {'report': 'reviewer-ok'})
        self.start()
        review = self.until(lambda: self.b.note().get('last_review'), what='the clean review')
        self.assertEqual((review['critical'], review['important'], review['findings']), (0, 0, []))
        self.assertEqual(self.b.card()['state'], 'in_review')
        self.assertEqual(self.b.note()['pr'], 12)
        self.until(lambda: not self.b.state.snapshot()['active'], what='the card to settle')
        roles = [c['argv'][c['argv'].index('--agent') + 1] for c in self.b.fake_calls(2)]
        self.assertEqual(roles, ['fleet-board:implementor', 'fleet-board:reviewer'])
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_candidates_are_annotated_and_merge_is_ignored(self):
        self.b.seed(13, 'in_review')
        self.b.seed(14, 'ready')
        self.b.put_note({'deps_commented': ['acme/toy#5']}, 14)
        self.rows = lambda: [
            dc.candidate('merge', number=13, state='in_review', declared_paths=['m']),
            dc.candidate('wait', number=14, state='ready', waiting_on=['acme/toy#5'], declared_paths=['w'])]
        self.start()
        self.cycles_done(1)
        rows, kw = self.sched.calls[-1]
        by = {r['number']: r for r in rows}
        self.assertNotIn(13, by, 'a merge row is never offered to the scheduler')
        self.assertEqual(by[14]['provider'], 'scripts')
        self.assertEqual(by[14]['deps_commented'], ['acme/toy#5'])
        self.assertIs(kw['lane_free'], False)
        ignored = {i['number']: i['reason'] for i in self.sup.last_cycle['ignored']}
        self.assertEqual(ignored[13], 'merging arrives in phase 4')
        self.assertEqual(self.b.comments(14), [], 'an unchanged dependency list is not commented again')
        self.assertEqual(self.b.card(13)['state'], 'in_review')
        self.assertEqual(self.b.state.snapshot()['active'], {})

    def test_a_fetch_error_keeps_running(self):
        self.rows = lambda: None
        original = self.fetch
        self.fetch = lambda root, run=None, now=None: candidates.Batch([], None, 'tick-plan.sh timed out')
        self.sup.fetch = self.fetch
        self.start()
        self.until(lambda: any(e['type'] == 'fetch_failed' for e in self.b.state.events), what='the fetch event')
        self.assertEqual(self.mode(), 'running')
        self.sup.fetch = original
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)


class Controls(LoopCase):
    def test_pause_admits_nothing_and_resume_continues(self):
        self.rows = lambda: []
        self.b.plans({'report': 'implementor-ok'})
        self.start()
        self.cycles_done(1)
        reply = self.sup.handle({'command': 'pause', 'reason': 'by test'})
        self.assertEqual(reply['mode'], 'paused')
        self.assertEqual(self.b.state.snapshot()['pause_reason'], 'by test')
        self.rows = None
        self.sup.wake('test')
        time.sleep(1.5)
        self.assertEqual(self.count(), 0, 'a paused supervisor admitted a card')
        self.assertEqual(self.b.card()['state'], 'ready')
        reply = self.sup.handle({'command': 'resume'})
        self.assertEqual(reply['mode'], 'running')
        self.until(lambda: self.b.note().get('pr') == 12, what='the card to progress after resume')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_a_pause_during_a_slow_begin_launches_nothing_more(self):
        self.add_card(13)
        gate, entered, original = threading.Event(), threading.Event(), self.b.driver.begin
        calls = []

        def slow_begin(row):
            calls.append(row['number'])
            if len(calls) == 1:
                entered.set()
                gate.wait(20)
            return original(row)

        self.b.driver.begin = slow_begin
        self.b.plans({'report': 'implementor-ok', 'sleep': 1})
        self.start()
        self.assertTrue(entered.wait(20), 'the first begin never started')
        reply = self.sup.handle({'command': 'pause'})
        self.assertTrue(reply.get('queued'), reply)
        gate.set()
        self.until(lambda: self.mode() == 'paused', what='the queued pause to apply')
        time.sleep(1.0)
        self.assertEqual(len(calls), 1, 'a row was begun after the pause was acknowledged')
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.b.card(13)['state'], 'ready')

    def test_stop_drain_waits(self):
        self.add_card(13)
        self.b.plans({'report': 'implementor-ok', 'sleep': 3})
        self.rows = lambda: [dc.candidate('start', number=12, branch=BRANCH[12], worktree=self.b.worktree,
                                          declared_paths=['a'])] if self.b.card(12)['state'] == 'ready' else []
        self.start()
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='the implementor to start')
        before = self.b.state.revision
        reply = self.sup.handle({'command': 'stop', 'mode': 'drain'})
        self.assertEqual(reply, {'stopping': True, 'mode': 'drain'})
        self.assertEqual(self.mode(), 'stopping', 'stop must show at once')
        self.assertGreater(self.b.state.revision, before)
        self.rows = None
        self.sup.wake('test')
        time.sleep(1.0)
        self.assertTrue(self.thread.is_alive(), 'a drain must wait for the running session')
        self.assertEqual(self.finished(), 0)
        self.assertEqual(self.b.note(12).get('pr'), 12, 'the drained session was reconciled')
        self.assertEqual(self.b.card(13)['state'], 'ready', 'nothing new was admitted while draining')
        self.assertEqual(self.count(), 1)

    def test_resume_during_a_drain_does_not_reopen_admissions(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 3})
        self.start()
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='the implementor to start')
        self.sup.handle({'command': 'stop', 'mode': 'drain'})
        with self.assertRaises(errors.Invalid):
            self.sup.handle({'command': 'resume'})
        self.assertEqual(self.mode(), 'stopping')
        self.assertEqual(self.sup.handle({'command': 'pause'})['mode'], 'stopping')
        self.assertEqual(self.mode(), 'stopping')
        self.assertEqual(self.finished(), 0)

    def test_stop_and_status_do_not_wait_for_a_busy_loop(self):
        self.fetch_gate = threading.Event()
        self.start()
        self.until(lambda: self.fetches >= 1, what='the loop to block in fetch')
        began = time.monotonic()
        reply = self.sup.handle({'command': 'pause'})
        self.assertLess(time.monotonic() - began, 3, 'the service thread waited on a busy loop')
        self.assertTrue(reply.get('queued'), reply)
        began = time.monotonic()
        self.b.state.snapshot()
        self.assertEqual(self.sup.handle({'command': 'stop', 'mode': 'cancel'})['mode'], 'cancel')
        self.assertLess(time.monotonic() - began, 1)
        self.assertEqual(self.mode(), 'stopping', 'stop applies at once even while the loop is busy')
        self.fetch_gate.set()
        self.assertEqual(self.finished(), 0)
        self.assertEqual(self.mode(), 'stopping', 'the queued pause must not overwrite stopping')

    def test_stop_cancel_returns_cards_to_their_column(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 30})
        self.start()
        self.until(lambda: self.b.fake_calls(1), what='the implementor to launch')
        self.assertEqual(self.b.card()['state'], 'in_progress')
        self.assertEqual(self.sup.handle({'command': 'stop', 'mode': 'cancel'})['mode'], 'cancel')
        began = time.monotonic()
        self.assertEqual(self.finished(), 0)
        self.assertLess(time.monotonic() - began, 15)
        self.assertEqual(self.b.card()['state'], 'ready')
        note = self.b.note()
        self.assertEqual(note['cancelled']['action'], 'start')
        self.assertIn('at', note['cancelled'])
        self.assertIsNone(note.get('pr'))
        self.assertEqual(note['action_failures'], 0)
        self.assertEqual(self.b.state.snapshot()['active'], {})

    def test_sigint_twice_forces(self):
        self.b.config['supervisor']['shutdown_grace_seconds'] = 30
        self.b.config['supervisor']['attempt_timeout_seconds'] = 7200
        self.b.plans({'report': 'implementor-ok', 'sleep': 60, 'ignore_term': True})
        self.start()
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='the implementor to start')
        self.until(lambda: self.b.fake_calls(1), what='the fake role to launch')
        self.sup.on_signal(signal.SIGINT)
        self.assertEqual(self.mode(), 'stopping')
        time.sleep(1.0)
        self.assertTrue(self.thread.is_alive(), 'the first SIGINT waits out the grace for a TERM-ignoring role')
        began = time.monotonic()
        self.sup.on_signal(signal.SIGINT)
        self.assertEqual(self.finished(15), 0)
        self.assertLess(time.monotonic() - began, 12, 'the second SIGINT must skip the grace')

    def test_sigterm_and_sighup_cancel(self):
        for number in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=number):
                self.sup._stop_mode = None
                self.b.state.mode = 'running'
                self.sup.on_signal(number)
                self.assertEqual((self.sup._stop_mode, self.mode()), ('cancel', 'stopping'))

    def test_max_hours_drains(self):
        self.rows = lambda: []
        self.start()
        self.cycles_done(1)
        self.mono_skew = 8 * 3600 + 5
        self.sup.wake('test')
        self.assertEqual(self.finished(), 0)
        self.assertEqual(self.mode(), 'stopping')

    def test_service_wiring(self):
        svc = service.Service(self.b.root, self.b.state, self.sup.handle, peer_resolver=lambda _peer: 'me',
                              run_lock_path=str(self.dir / 'run.lock'))
        self.rows = lambda: []
        self.start()
        self.cycles_done(1)

        def ask(**request):
            reply = svc.handle_request_envelope(request, peer=object())
            self.assertTrue(reply['ok'], reply)
            return reply['result']

        status = ask(command='status')
        pause = ask(command='pause', request_id='r1', expected_revision=status['revision'])
        self.assertEqual(pause['mode'], 'paused')
        status = ask(command='status')
        self.assertEqual((status['mode'], pause['revision']), ('paused', status['revision']))
        stop = ask(command='stop', mode='drain', request_id='r2', expected_revision=status['revision'])
        self.assertEqual(stop, {'stopping': True, 'mode': 'drain'})
        self.assertEqual(ask(command='status')['mode'], 'stopping')
        self.assertEqual(self.finished(), 0)


class Cycle(LoopCase):
    def test_invalid_config_pauses(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 3})
        self.start()
        self.until(lambda: 12 in self.b.state.snapshot()['active'], what='the implementor to start')
        self.bad_config = 'limits.concurrency must be a positive integer'
        self.sup.wake('test')
        snap = self.until(lambda: self.b.state.snapshot() if self.mode() == 'paused' else None, what='the pause')
        self.assertIn('limits.concurrency must be a positive integer', snap['pause_reason'])
        self.assertIn(12, snap['active'], 'a running session continues under an invalid config')
        self.until(lambda: self.b.note().get('pr') == 12, what='the running session to finish while paused')
        self.bad_config = None
        self.sup.wake('test')
        self.until(lambda: self.mode() == 'running', what='the config pause to lift once the config is valid')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_rate_limit_holds_admissions_until_reset(self):
        self.b.config['limits']['rate_limit_margin'] = 5
        self.rate = self.clock() + 3600
        self.b.plans({'report': 'implementor-ok'})
        self.start()
        self.until(lambda: self.fetches >= 1, what='the first fetch')
        self.sup.wake('test')
        time.sleep(0.5)
        self.assertEqual(self.fetches, 1, 'no fetch while held')
        self.assertEqual(self.count(), 0)
        self.skew = 3602
        self.sup.wake('test')
        time.sleep(0.5)
        self.assertEqual((self.fetches, self.count()), (1, 0), 'the margin after the reset still holds')
        self.skew = 3606
        self.rate = None
        self.sup.wake('test')
        self.until(lambda: self.b.note().get('pr') == 12, what='the card to start after the reset')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_a_failing_action_does_not_recycle_before_the_timer(self):
        self.b.seed(12, 'in_review')
        self.b.gh_result = dc.fail_with('boom')
        self.rows = lambda: [dc.candidate('mark_ready', number=12, state='in_review', worktree=self.b.worktree,
                                          declared_paths=['a'])]
        self.start()
        self.until(lambda: any(e['type'] == 'action_failed' for e in self.b.state.events), what='the failure')
        time.sleep(0.6)
        self.assertFalse(self.sup._want_cycle, 'a no-progress action asked for an immediate re-cycle')
        self.assertLessEqual(self.fetches, 2, 'a no-progress action re-planned in a loop (%d fetches)' % self.fetches)
        self.until(lambda: self.fetches >= 2, what='the timer cycle')

    def test_a_scheduler_stop_reason_pauses_once_and_lifts_when_it_clears(self):
        self.rows = lambda: []
        self.b.config['limits']['concurrency'] = 0
        self.start()
        snap = self.until(lambda: self.b.state.snapshot() if self.mode() == 'paused' else None, what='the pause')
        self.assertEqual(snap['pause_reason'], 'invalid limits')
        self.cycles_done(2)
        after = self.b.state.snapshot()
        self.assertEqual((after['mode'], after['revision']), ('paused', snap['revision']),
                         'consecutive stop_reason cycles must not flip the mode or the revision')
        self.cycles_done(1)
        self.assertEqual(self.b.state.revision, snap['revision'])
        self.b.config['limits']['concurrency'] = 2
        self.sup.wake('test')
        self.until(lambda: self.mode() == 'running', what='the pause to lift once the scheduler is satisfied')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_rate_limit_beyond_the_cap_pauses(self):
        self.rate = self.clock() + 7200
        self.start()
        snap = self.until(lambda: self.b.state.snapshot() if self.mode() == 'paused' else None, what='the pause')
        self.assertIn('rate limit', snap['pause_reason'])
        self.assertEqual(self.count(), 0)

    def test_provider_failure_backs_off_and_retries(self):
        fail = {'report': '', 'post': False, 'exit': 1, 'is_error': True, 'stderr': 'rate limit exceeded (429)'}
        self.b.plans(fail, fail, {'report': 'implementor-ok'})
        self.start()
        health = self.until(lambda: self.b.state.snapshot()['provider_health'].get('claude'), what='the first failure')
        self.assertEqual(health['failures'], 1)
        self.assertLessEqual(health['until'] - self.clock(), 1.5)
        self.assertEqual(self.b.note().get('action_failures'), 0, 'a provider failure does not charge the card')
        time.sleep(0.4)
        self.assertEqual(self.count(), 1, 'no retry before the backoff ends')
        health = self.until(lambda: (self.b.state.snapshot()['provider_health'].get('claude') or {}).get('failures') == 2
                            and self.b.state.snapshot()['provider_health']['claude'], what='the second failure')
        self.assertGreater(health['until'] - self.clock(), 1.2, 'the backoff doubles')
        self.assertLessEqual(health['until'] - self.clock(), 2.5)
        self.until(lambda: self.b.note().get('pr') == 12, what='the retry to succeed')
        self.assertEqual(self.count(), 3)
        self.until(lambda: 'claude' not in self.b.state.snapshot()['provider_health'], what='health to clear')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_lowered_concurrency_cancels_nothing(self):
        for number in (12, 13):
            self.in_progress(number)
        self.add_card(14)
        self.rows = self.implement_plan
        self.b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 3},
                     {'report': 'implementor-ok', 'post': False, 'sleep': 9},
                     {'report': 'implementor-ok', 'post': False})
        self.start()
        self.until(lambda: len(self.b.state.snapshot()['active']) == 2, what='two running sessions')
        self.b.config['limits']['concurrency'] = 1
        self.sup.wake('test')
        self.cycles_done(1)
        self.assertEqual(len(self.b.state.snapshot()['active']), 2, 'lowering the cap cancelled a session')
        self.assertEqual(self.count(), 2, 'nothing new is admitted above the cap')
        self.until(lambda: len(self.b.state.snapshot()['active']) == 1, what='the first session to end')
        self.cycles_done(2)
        self.assertEqual(self.count(), 2, 'one running action fills a cap of one')
        self.until(lambda: self.count() == 3, what='card 14 once nothing runs')
        self.until(lambda: self.b.note(14).get('pr') == 12, what='card 14 to finish')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_no_session_outlives_the_supervisor(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 60, 'spawn_child': True, 'child_ignore_term': True})
        self.start()
        self.until(lambda: self.b.fake_calls(1) and (self.b.fake / '1.child').exists(), what='the role and its child')
        pid = self.b.fake_calls(1)[0]['pid']
        child = int((self.b.fake / '1.child').read_text())
        self.sup.request_stop('cancel')
        self.assertEqual(self.finished(), 0)
        self.assertFalse(alive(pid))
        self.assertFalse(alive(child), 'a child of the role survived the cancel')

    def test_a_crash_still_reaps_the_sessions(self):
        self.b.plans({'report': 'implementor-ok', 'sleep': 60, 'spawn_child': True})
        self.start()
        self.until(lambda: self.b.fake_calls(1) and (self.b.fake / '1.child').exists(), what='the role and its child')
        pid = self.b.fake_calls(1)[0]['pid']
        child = int((self.b.fake / '1.child').read_text())

        class Boom(BaseException):
            pass

        self.fetch_raises = Boom()
        self.sup.wake('test')
        self.thread.join(20)
        self.assertIsInstance(self.crash, Boom)
        self.crash = None
        self.assertFalse(alive(pid))
        self.assertFalse(alive(child))


class ServiceClose(unittest.TestCase):
    def test_close_waits_for_a_connection_accepted_just_before_shutdown(self):
        from supervisor.state import State
        base = BASE / 'close'
        base.mkdir()
        done = threading.Event()

        def handler(command):
            time.sleep(0.6)
            done.set()
            return {'ok': True}

        state = State('run-close')
        with mock.patch.dict(os.environ, {'FLEET_BOARD_LOG_DIR': str(base / 'logs')}):
            svc = service.Service(base, state, handler, peer_resolver=lambda _peer: 'me',
                                  run_lock_path=str(base / 'run.lock'))
            ack = svc.serve()
            if not ack.get('owner'):
                self.skipTest('sandbox denies the supervisor socket')
            self.addCleanup(svc.close)
            original = svc._track_thread

            def slow_track(thread):
                time.sleep(0.3)
                original(thread)

            svc._track_thread = slow_track
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(10)
            client.connect(svc.socket_path)
            client.sendall(json.dumps({'command': 'pause', 'request_id': 'x', 'expected_revision': 0}).encode())
            time.sleep(0.1)
            svc.close()
            self.assertTrue(done.is_set(), 'close() returned while a just-accepted connection was still being served')
            reply = json.loads(client.recv(65536))
            client.close()
            self.assertTrue(reply['ok'], reply)


if __name__ == '__main__':
    unittest.main()
