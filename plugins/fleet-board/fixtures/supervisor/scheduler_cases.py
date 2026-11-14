"""Deterministic admission scheduler contract tests."""
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from supervisor.scheduler import Scheduler


def candidate(number, action='start', provider='claude', paths=None, priority='normal', eligible_since=0):
    return {'number': number, 'action': action, 'provider': provider, 'declared_paths': paths if paths is not None else [f'card/{number}'],
            'actual_paths': [], 'scope_complete': True, 'priority': priority,
            'eligible_since': eligible_since, 'preconditions': {'state': 'ready', 'head_sha': None}}


class ManualTimers:
    def __init__(self):
        self.now = 0
        self.events = []

    def call_at(self, when, callback):
        event = {'when': when, 'callback': callback, 'cancelled': False}
        self.events.append(event)
        return event

    def advance(self, when):
        self.now = when
        due, self.events = ([e for e in self.events if not e['cancelled'] and e['when'] <= when],
                            [e for e in self.events if e['cancelled'] or e['when'] > when])
        for event in due:
            event['callback']()


def run():
    scheduler = Scheduler(clock=lambda: 0)
    # A stays live while B can complete and independent C is admitted.
    a = candidate(1); b = candidate(2, 'review'); c = candidate(3, paths=['src/c.py'])
    result = scheduler.admit([a, b, c], active=[{'number': 1, 'provider': 'claude', 'paths':['src/a.py']}],
                             limits={'global': 2, 'providers': {'claude': 2}, 'per_card': 1})
    assert [x['number'] for x in result['admitted']] == [2]
    next_result = scheduler.admit([c], active=[{'number': 1, 'provider': 'claude', 'paths':['src/a.py']}],
                                  limits={'global': 2, 'providers': {'claude': 2}, 'per_card': 1})
    assert [x['number'] for x in next_result['admitted']] == [3]
    # Two simultaneous requests share capacity through the serialized admission lock.
    assert scheduler.admit([candidate(4)], active=next_result['active'], limits={'global':2,'providers':{'claude':2},'per_card':1})['admitted'] == []
    # Provider and card caps, and lowered global cap, are enforced from active claims.
    assert scheduler.admit([candidate(5,'review','openai')], active=[{'number':9,'provider':'claude','paths':[]}],
                           limits={'global':1,'providers':{'openai':1},'per_card':1})['admitted'] == []
    provider_limited = scheduler.admit([candidate(51,'review','openai')], active=[{'number':9,'provider':'openai','paths':['x']}],
        limits={'global':3,'providers':{'openai':1},'per_card':1})
    assert provider_limited['waits'][0]['reason'] == 'provider capacity'
    lowered = scheduler.admit([candidate(52)], active=[{'number':8,'provider':'claude','paths':['a']}, {'number':9,'provider':'claude','paths':['b']}],
        limits={'global':1,'providers':{'claude':2},'per_card':1})
    assert not lowered['admitted'] and lowered['waits'][0]['reason'] == 'global capacity'
    # Disjoint candidates may pass a conflicting candidate; the blocked card claims no scope.
    choices = scheduler.admit([candidate(6, paths=['src/a']), candidate(7, paths=['docs/b'])],
        active=[{'number':8,'provider':'claude','paths':['src/a/file']}],
        limits={'global':2,'providers':{'claude':2},'per_card':1})
    assert [x['number'] for x in choices['admitted']] == [7]
    # Racing requests still rely on atomic durable preparation; only one may claim the last slot.
    claim_lock = threading.Lock()
    claims = []
    race = Scheduler()
    barrier = threading.Barrier(3)
    results = []
    def contender(number):
        def prepare(c):
            with claim_lock:
                if claims:
                    raise ValueError('capacity exhausted')
                claims.append(number)
                return {'number': number, 'provider': 'claude', 'paths': c['declared_paths']}
        barrier.wait()
        results.append(race.admit([candidate(number)], limits={'global':1,'providers':{'claude':1},'per_card':1}, prepare=prepare))
    threads = [threading.Thread(target=contender, args=(n,)) for n in (61, 62)]
    for thread in threads: thread.start()
    barrier.wait()
    for thread in threads: thread.join(2)
    assert len(claims) == 1 and sum(len(result['admitted']) for result in results) == 1
    # Priority ties age monotonically and survive scheduler recreation via exported state.
    scheduler = Scheduler(clock=lambda: 100, state={'eligible_since': {'10': 0}})
    selected = scheduler.admit([candidate(11, priority='high', eligible_since=100), candidate(10, priority='low')],
        limits={'global':1,'providers':{'claude':1},'per_card':1,'aging_seconds':10})
    assert selected['admitted'][0]['number'] == 10
    assert Scheduler(clock=lambda:100,state=selected['state']).state == selected['state']
    # New high-priority reviews do not starve a continuously eligible old start.
    aged = Scheduler(clock=lambda: 0)
    for now in range(0, 101, 10):
        wave = [candidate(30, priority='low', eligible_since=0)] + [candidate(100 + now + i, 'review', priority='high', eligible_since=now) for i in range(3)]
        winner = aged.admit(wave, limits={'global':1,'providers':{'claude':1},'per_card':1,'aging_seconds':10}, now=now)
        if now < 80:
            assert winner['admitted'][0]['number'] != 30
        else:
            assert winner['admitted'][0]['number'] == 30
    # Launch spacing survives a process restart through the scheduler state.
    restarted = Scheduler(clock=lambda: 11, state={'eligible_since': {}, 'last_launch_at': 10})
    spaced = restarted.admit([candidate(33)], limits={'global':1,'providers':{'claude':1},'per_card':1,'min_launch_gap':5})
    assert spaced['waits'][0]['reason'] == 'launch spacing'
    # Slow planning coalesces many triggers into one pending snapshot; timers remain directly readable.
    gate, rerun = threading.Event(), threading.Event()
    count = {'plans': 0}
    async_scheduler = Scheduler(max_workers=1, max_control_workers=1)
    def planner():
        count['plans'] += 1
        if count['plans'] == 1:
            gate.wait(2)
        else:
            rerun.set()
        return {'revision': count['plans']}
    first = async_scheduler.request_cycle(planner)
    assert async_scheduler.request_cycle(planner) is first
    assert async_scheduler.request_cycle(planner) is first
    assert async_scheduler.due_timers([{'attempt_id':'x','deadline':1}, {'attempt_id':'y','cancel_grace_deadline':2}], now=2) == [
        {'attempt_id':'x','kind':'deadline'}, {'attempt_id':'y','kind':'cancel_grace'}]
    gate.set()
    assert first.result(timeout=2) == {'revision': 1} and rerun.wait(2) and count['plans'] == 2
    async_scheduler.close()
    # A full normal-control pool must not lose snapshot delivery or a coalesced rerun.
    overflow_scheduler = Scheduler(max_workers=1, max_control_workers=1, control_queue_limit=0)
    planner_release, control_release = threading.Event(), threading.Event()
    control_entered, second_plan, snapshots_done, snapshots = threading.Event(), threading.Event(), threading.Event(), {'count': 0}
    cycle_count = {'count': 0}
    def overflow_planner():
        cycle_count['count'] += 1
        if cycle_count['count'] == 1:
            planner_release.wait(3)
        else:
            second_plan.set()
        return {'revision': cycle_count['count']}
    def occupy_normal_control():
        control_entered.set()
        return control_release.wait(3)
    def receive_snapshot(snapshot):
        snapshots['count'] += 1
        if snapshots['count'] == 2:
            snapshots_done.set()
    normal_blocker = overflow_scheduler.control_async(occupy_normal_control)
    assert control_entered.wait(2)
    cycle = overflow_scheduler.request_cycle(overflow_planner, receive_snapshot)
    overflow_scheduler.request_cycle(overflow_planner, receive_snapshot)
    planner_release.set()
    assert cycle.result(timeout=2) == {'revision': 1}
    assert second_plan.wait(2) and snapshots_done.wait(2)
    control_release.set()
    normal_blocker.result(timeout=2)
    overflow_scheduler.close()
    # Deadline and cancel-grace callbacks fire from the timer driver while planning is blocked.
    timers = ManualTimers()
    timer_scheduler = Scheduler(clock=lambda: timers.now, timer_scheduler=timers)
    planner_gate = threading.Event()
    blocked_plan = timer_scheduler.plan_async(lambda: planner_gate.wait(3))
    deadline_seen, cancel_seen = threading.Event(), threading.Event()
    timer_scheduler.watch_attempt({'attempt_id': 'timed', 'deadline': 10, 'cancel_grace_deadline': 15},
        on_deadline=lambda attempt: deadline_seen.set(), on_cancel_grace=lambda attempt: cancel_seen.set())
    timers.advance(10)
    assert deadline_seen.wait(2)
    timers.advance(15)
    assert cancel_seen.wait(2) and not blocked_plan.done()
    planner_gate.set()
    blocked_plan.result(timeout=2)
    timer_scheduler.close()
    # Planning and ordinary controls reject excess queued work; urgent controls stay responsive.
    saturated = Scheduler(max_workers=1, plan_queue_limit=1, max_control_workers=1,
                          control_queue_limit=1, priority_workers=2)
    plan_gate, normal_entered, control_gate = threading.Event(), threading.Event(), threading.Event()
    running_plan = saturated.plan_async(lambda: plan_gate.wait(3))
    queued_plan = saturated.plan_async(lambda: 'queued')
    try:
        saturated.plan_async(lambda: 'overflow')
        raise AssertionError('planning queue accepted excess work')
    except RuntimeError:
        pass
    running_control = saturated.control_async(lambda: (normal_entered.set(), control_gate.wait(3)), kind='normal')
    assert normal_entered.wait(2)
    queued_control = saturated.control_async(lambda: 'queued', kind='normal')
    try:
        saturated.control_async(lambda: 'overflow', kind='normal')
        raise AssertionError('control queue accepted excess work')
    except RuntimeError:
        pass
    status = saturated.control_async(lambda: 'status', kind='status')
    cancel = saturated.control_async(lambda: 'cancel', kind='cancel')
    assert status.result(timeout=2) == 'status' and cancel.result(timeout=2) == 'cancel'
    plan_gate.set(); control_gate.set()
    assert running_plan.result(timeout=2) is True and queued_plan.result(timeout=2) == 'queued'
    running_control.result(timeout=2); assert queued_control.result(timeout=2) == 'queued'
    saturated.close()
    # Unknown workflow state never normalizes or admits and reports attention; active claims remain.
    unknown = scheduler.admit([candidate(12, action='unknown_state')], active=[{'number':12,'provider':'claude','paths':[]}],
        limits={'global':2,'providers':{'claude':2},'per_card':1})
    assert not unknown['admitted'] and unknown['attention'][0]['number'] == 12 and unknown['active'][0]['number'] == 12
    # Fake-time guards: retry/backoff, launch spacing, rate wait, deadline, invalid reload.
    clock = {'now': 10}
    timed = Scheduler(clock=lambda: clock['now'])
    wait = timed.admit([candidate(20)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'retry_at':{'20':15},'min_launch_gap':3,'last_launch_at':9,'rate_limit_wait':100,'max_rate_wait':8})
    assert not wait['admitted'] and wait['waits']
    assert wait['waits'][0]['reason'] == 'retry backoff' and wait['waits'][0]['until'] == 15
    rate = timed.admit([candidate(22)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'rate_limit_wait':{'claude':100},'max_rate_wait':8})
    assert rate['waits'][0]['reason'] == 'provider rate limit' and rate['waits'][0]['until'] == 18
    capped = timed.admit([candidate(23)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'rate_limit_wait':{'claude':100},'max_rate_wait':8}, now=18)
    assert not capped['admitted'] and (capped['stop_reason'] == 'provider rate-limit wait cap reached'
        or any(item['reason'] == 'provider rate-limit wait cap reached' for item in capped['attention']))
    assert timed.reload({'global':0}) is False
    assert timed.admit([candidate(26)])['stop_reason'] == 'invalid limits'
    test_every_planned_action_is_classified()
    test_skip_and_wait_are_ignored_not_attention()
    test_wait_with_a_new_dependency_list_is_admitted()
    test_provider_cap_applies_per_resolved_provider()
    test_merge_waits_for_the_lane()
    test_unknown_scope_serialises_starts()
    test_aging_promotes_a_starved_start()
    test_removed_limits_are_ignored()
    test_an_unscoped_role_does_not_block_another_cards_finish()
    test_script_actions_ignore_rate_limit_and_global_cap()
    test_script_action_still_waits_for_its_own_active_card()
    test_update_branch_skips_scope_but_takes_capacity()
    test_read_only_actions_ignore_other_cards_scope()
    test_a_read_only_claim_does_not_block_a_writer()
    test_a_read_only_action_still_waits_for_capacity_and_its_own_card()
    test_has_work_tolerates_mixed_dependency_types()
    test_scope_ignore_drops_version_manifests()
    test_scope_ignore_validated_in_limits()
    test_scope_ignore_one_side_wholly_ignored()
    test_scope_ignore_cleans_the_path_side()
    test_glob_segments_and_jq_parity()
    print('scheduler cases passed')


LIMITS = {'global': 8, 'providers': {'*': 8}, 'per_card': 1}


def admit_one(scheduler, row, **kw):
    limits = kw.pop('limits', LIMITS)
    return scheduler.admit([row], limits=limits, **kw)


def test_every_planned_action_is_classified():
    from supervisor.scheduler import _ACTION_CLASS
    expected = {0: ['continue_implementor', 'fix', 'review', 'review_stage'],
                1: ['start_review', 'unblock', 'update_branch', 'advance_stage', 'to_human_qa', 'mark_ready',
                    'verify_main', 'finish', 'block', 'file_pending', 'merge', 'after_merge', 'merge_refusal'],
                2: ['start']}
    for klass, actions in expected.items():
        for action in actions:
            assert _ACTION_CLASS.get(action) == klass, action
    assert len(_ACTION_CLASS) == 18
    for number, action in enumerate(expected[0] + expected[1] + expected[2], 1):
        result = admit_one(Scheduler(clock=lambda: 0), candidate(number, action), lane_free=True)
        assert [x['number'] for x in result['admitted']] == [number], action
        assert not result['attention'], action


def test_skip_and_wait_are_ignored_not_attention():
    scheduler = Scheduler(clock=lambda: 0)
    rows = [dict(candidate(n, a), reason='r' + str(n)) for n, a in
            enumerate(['skip', 'skip_no_acceptance', 'skip_card_lint', 'wait'], 1)]
    result = scheduler.admit(rows, limits=LIMITS)
    assert result['admitted'] == [] and result['attention'] == [] and result['waits'] == []
    assert result['ignored'] == [{'number': n, 'action': a, 'reason': 'r' + str(n)} for n, a in
                                 enumerate(['skip', 'skip_no_acceptance', 'skip_card_lint', 'wait'], 1)]
    # With work to do, the skip_* rows are class 1; plain skip never is.
    rows = [dict(candidate(1, 'skip_no_acceptance'), comment_needed=True),
            dict(candidate(2, 'skip_card_lint'), comment_needed=True),
            dict(candidate(3, 'skip'), comment_needed=True)]
    result = scheduler.admit(rows, limits=LIMITS)
    assert sorted(x['number'] for x in result['admitted']) == [1, 2]
    assert [x['number'] for x in result['ignored']] == [3] and result['attention'] == []
    assert 'ignored' in scheduler.admit([], limits={'global': 0})  # invalid limits keep the shape


def test_wait_with_a_new_dependency_list_is_admitted():
    scheduler = Scheduler(clock=lambda: 0)
    changed = dict(candidate(1, 'wait'), waiting_on=[5, 6], deps_commented=[5])
    missing = dict(candidate(2, 'wait'), waiting_on=[5])
    same = dict(candidate(3, 'wait'), waiting_on=[5], deps_commented=[5])
    empty = dict(candidate(4, 'wait'), waiting_on=[])
    comment = dict(candidate(5, 'wait'), waiting_on=[], comment_needed=True)
    result = scheduler.admit([changed, missing, same, empty, comment], limits=LIMITS)
    assert sorted(x['number'] for x in result['admitted']) == [1, 2, 5]
    assert sorted(x['number'] for x in result['ignored']) == [3, 4]


def test_provider_cap_applies_per_resolved_provider():
    limits = {'global': 8, 'providers': {'codex': 1, '*': 8}, 'per_card': 1}
    result = Scheduler(clock=lambda: 0).admit(
        [candidate(1, 'review', 'codex'), candidate(2, 'review', 'codex'), candidate(3, 'review', 'claude')],
        limits=limits)
    assert sorted(x['number'] for x in result['admitted']) == [1, 3]
    assert result['waits'] == [{'number': 2, 'reason': 'provider capacity'}]
    # No provider key counts as "default" (falls back to '*'); "scripts" is never capped.
    row = candidate(4, 'review'); del row['provider']
    row7 = candidate(7, 'finish'); del row7['provider']
    limits = {'global': 8, 'providers': {'*': 1, 'scripts': 1}, 'per_card': 1}
    result = Scheduler(clock=lambda: 0).admit(
        [row, candidate(5, 'finish', 'scripts'), candidate(6, 'finish', 'scripts'), row7], limits=limits)
    assert sorted(x['number'] for x in result['admitted']) == [4, 5, 6]
    assert result['waits'] == [{'number': 7, 'reason': 'provider capacity'}]
    # Scripts do not count against global.
    result = Scheduler(clock=lambda: 0).admit(
        [candidate(8, 'finish', 'scripts'), candidate(9, 'finish', 'scripts')],
        limits={'global': 1, 'providers': {'*': 1}, 'per_card': 1})
    assert [x['number'] for x in result['admitted']] == [8, 9]
    assert result['active'] == []


def test_merge_waits_for_the_lane():
    merge = candidate(1, 'merge')
    busy = admit_one(Scheduler(clock=lambda: 0), merge)
    assert busy['admitted'] == [] and busy['waits'][0]['reason'] == 'merge lane busy'
    busy = admit_one(Scheduler(clock=lambda: 0), merge, lane_free=False)
    assert busy['admitted'] == []
    free = admit_one(Scheduler(clock=lambda: 0), merge, lane_free=True)
    assert [x['number'] for x in free['admitted']] == [1]
    # Only one merge per call; a merge counts against the global cap.
    two = Scheduler(clock=lambda: 0).admit([candidate(1, 'merge'), candidate(2, 'merge')], limits=LIMITS, lane_free=True)
    assert [x['number'] for x in two['admitted']] == [1]
    capped = Scheduler(clock=lambda: 0).admit([candidate(3, 'merge')], limits={'global': 1, 'providers': {'*': 1}, 'per_card': 1},
        active=[{'number': 9, 'provider': 'claude', 'paths': ['z']}], lane_free=True)
    assert capped['admitted'] == [] and capped['waits'][0]['reason'] == 'global capacity'


def test_unknown_scope_serialises_starts():
    unknown = dict(candidate(1), declared_paths=[], actual_paths=[])
    other = candidate(2, paths=['docs/x'])
    result = Scheduler(clock=lambda: 0).admit([unknown, other], limits=LIMITS)
    assert [x['number'] for x in result['admitted']] == [1]
    assert result['waits'][0]['number'] == 2
    result = Scheduler(clock=lambda: 0).admit([unknown], limits=LIMITS,
        active=[{'number': 9, 'provider': 'claude', 'paths': ['src/a']}])
    assert result['admitted'] == [] and result['waits'][0]['number'] == 1
    two = Scheduler(clock=lambda: 0).admit([unknown, dict(unknown, number=3)], limits=LIMITS)
    assert [x['number'] for x in two['admitted']] == [1]


def test_aging_promotes_a_starved_start():
    limits = {'global': 1, 'providers': {'*': 1}, 'per_card': 1, 'aging_seconds': 10}
    scheduler = Scheduler(clock=lambda: 0)
    for now in range(0, 121, 10):
        wave = [candidate(30, 'start', priority='low', eligible_since=0)] + [
            candidate(100 + now + i, 'finish', priority='high', eligible_since=now) for i in range(2)]
        winner = scheduler.admit(wave, limits=limits, now=now)
        number = winner['admitted'][0]['number']
        if now < 50:
            assert number != 30, now
        if now >= 50:
            assert number == 30, now
            break


def test_removed_limits_are_ignored():
    # Cost and session deadline limits no longer exist; the loop enforces token limits.
    result = admit_one(Scheduler(clock=lambda: 50), candidate(1), limits=dict(LIMITS, session_deadline=10, max_cost=0))
    assert [x['number'] for x in result['admitted']] == [1] and result['stop_reason'] is None


def test_an_unscoped_role_does_not_block_another_cards_finish():
    unscoped = {'number': 1, 'provider': 'claude', 'paths': []}
    rows = [dict(candidate(n, a, 'scripts'), declared_paths=[]) for n, a in
            ((2, 'finish'), (3, 'block'), (4, 'to_human_qa'), (5, 'mark_ready'), (6, 'file_pending'))]
    result = Scheduler(clock=lambda: 0).admit(rows, active=[unscoped], limits=LIMITS,
        reservations=[{'card': 1, 'paths': ['']}])
    assert [x['number'] for x in result['admitted']] == [2, 3, 4, 5, 6] and result['waits'] == []
    assert result['active'] == [unscoped]
    # Nor do they block a later role start in the same call.
    both = Scheduler(clock=lambda: 0).admit([candidate(7, 'finish', 'scripts', paths=[]), candidate(8, 'start', paths=['a'])],
        limits=LIMITS)
    assert sorted(x['number'] for x in both['admitted']) == [7, 8]


def test_script_actions_ignore_rate_limit_and_global_cap():
    limits = {'global': 1, 'providers': {'*': 1}, 'per_card': 1, 'rate_limit_wait': {'scripts': 100, 'claude': 100}}
    result = Scheduler(clock=lambda: 0).admit([candidate(1, 'finish', 'scripts'), candidate(2, 'start')],
        active=[{'number': 9, 'provider': 'claude', 'paths': ['z']}], limits=limits)
    assert [x['number'] for x in result['admitted']] == [1]
    assert result['waits'][0]['reason'] == 'provider rate limit'


def test_script_action_still_waits_for_its_own_active_card():
    result = Scheduler(clock=lambda: 0).admit([candidate(1, 'finish', 'scripts')],
        active=[{'number': 1, 'provider': 'claude', 'paths': ['z']}], limits=LIMITS)
    assert result['admitted'] == [] and result['waits'][0]['reason'] == 'card already has an active claim'


def test_update_branch_skips_scope_but_takes_capacity():
    row = dict(candidate(2, 'update_branch', 'scripts'), declared_paths=[])
    active = [{'number': 1, 'provider': 'claude', 'paths': ['src']}]
    result = Scheduler(clock=lambda: 0).admit([row], active=active, limits=LIMITS)
    assert [x['number'] for x in result['admitted']] == [2], 'a branch update writes only its own branch'
    capped = Scheduler(clock=lambda: 0).admit([candidate(3, 'update_branch', 'scripts', paths=['x'])],
        active=active, limits={'global': 1, 'providers': {'*': 1}, 'per_card': 1})
    assert capped['waits'][0]['reason'] == 'global capacity'
    ok = Scheduler(clock=lambda: 0).admit([candidate(3, 'update_branch', 'scripts', paths=['x'])], active=active, limits=LIMITS)
    assert [x['number'] for x in ok['admitted']] == [3] and len(ok['active']) == 2


def test_read_only_actions_ignore_other_cards_scope():
    writer = {'number': 1, 'provider': 'claude', 'paths': ['src/a.py'], 'action': 'fix'}
    held = [{'card': 1, 'paths': ['src/a.py']}]
    for action, provider in (('review', 'claude'), ('review_stage', 'claude'), ('update_branch', 'scripts')):
        result = Scheduler(clock=lambda: 0).admit([candidate(2, action, provider, paths=['src/a.py'])],
            active=[writer], reservations=held, limits=LIMITS)
        assert [x['number'] for x in result['admitted']] == [2], (action, result['waits'])
        assert [x['number'] for x in result['active']] == [1, 2], 'it still occupies a slot'
        assert result['active'][1]['action'] == action, 'its claim records the action'


def test_a_read_only_claim_does_not_block_a_writer():
    reader = {'number': 1, 'provider': 'claude', 'paths': ['src/a.py'], 'action': 'review'}
    result = Scheduler(clock=lambda: 0).admit([candidate(2, 'fix', paths=['src/a.py'])], active=[reader], limits=LIMITS)
    assert [x['number'] for x in result['admitted']] == [2], result['waits']
    # A review admitted earlier in the same call does not block a later writer either.
    both = Scheduler(clock=lambda: 0).admit([candidate(3, 'review', paths=['src/a.py']),
                                             candidate(4, 'fix', paths=['src/a.py'])], limits=LIMITS)
    assert [x['number'] for x in both['admitted']] == [3, 4], both['waits']
    # Two writers still exclude each other, and a claim with no action counts as a writer.
    for claim in (dict(reader, action='start'), {'number': 1, 'provider': 'claude', 'paths': ['src/a.py']}):
        writers = Scheduler(clock=lambda: 0).admit([candidate(5, 'fix', paths=['src/a.py'])], active=[claim],
                                                   limits=LIMITS)
        assert writers['admitted'] == [] and writers['waits'][0]['reason'] == 'scope or card conflict', claim
    # A writer still waits on another card's reservation.
    reserved = Scheduler(clock=lambda: 0).admit([candidate(6, 'fix', paths=['src/a.py'])],
        reservations=[{'card': 1, 'paths': ['src/a.py']}], limits=LIMITS)
    assert reserved['admitted'] == [] and reserved['waits'][0]['reason'] == 'scope reserved by #1'


def test_a_read_only_action_still_waits_for_capacity_and_its_own_card():
    writer = {'number': 1, 'provider': 'claude', 'paths': ['src/a.py'], 'action': 'fix'}
    capped = Scheduler(clock=lambda: 0).admit([candidate(2, 'review', paths=['src/a.py'])], active=[writer],
        limits={'global': 1, 'providers': {'*': 1}, 'per_card': 1})
    assert capped['admitted'] == [] and capped['waits'][0]['reason'] == 'global capacity'
    own = Scheduler(clock=lambda: 0).admit([candidate(1, 'review', paths=['src/a.py'])], active=[writer], limits=LIMITS)
    assert own['admitted'] == [] and own['waits'][0]['reason'] == 'card already has an active claim'


def test_has_work_tolerates_mixed_dependency_types():
    row = dict(candidate(1, 'wait'), waiting_on=[5, 'org/repo#6'], deps_commented=['5', 'org/repo#6'])
    result = Scheduler(clock=lambda: 0).admit([row], limits=LIMITS)
    assert result['admitted'] == [] and len(result['ignored']) == 1
    result = Scheduler(clock=lambda: 0).admit([dict(row, deps_commented=[5])], limits=LIMITS)
    assert len(result['admitted']) == 1


MANIFESTS = ['.claude-plugin/marketplace.json', 'plugins/fleet-board/.claude-plugin/plugin.json']


def _pr_row(number, action, own, extra=()):
    return dict(candidate(number, action, paths=[own]), actual_paths=list(MANIFESTS) + list(extra))


def test_scope_ignore_drops_version_manifests():
    ignore = dict(LIMITS, scope_ignore=['.claude-plugin/marketplace.json', 'plugins/*/.claude-plugin/plugin.json'])
    rows = [_pr_row(1, 'fix', 'src/a.py'), _pr_row(2, 'fix', 'src/b.py')]
    # Both admitted when the only shared paths are ignored manifests.
    both = Scheduler(clock=lambda: 0).admit(rows, limits=ignore)
    assert sorted(x['number'] for x in both['admitted']) == [1, 2], both
    # Empty setting: they conflict as today.
    empty = Scheduler(clock=lambda: 0).admit(rows, limits=dict(LIMITS, scope_ignore=[]))
    assert [x['number'] for x in empty['admitted']] == [1] and empty['waits'][0]['reason'] == 'scope or card conflict'
    unset = Scheduler(clock=lambda: 0).admit(rows, limits=LIMITS)
    assert [x['number'] for x in unset['admitted']] == [1]
    # A shared path that is not ignored still conflicts.
    shared = [_pr_row(1, 'fix', 'src/a.py', ['src/shared.py']), _pr_row(2, 'fix', 'src/b.py', ['src/shared.py'])]
    still = Scheduler(clock=lambda: 0).admit(shared, limits=ignore)
    assert [x['number'] for x in still['admitted']] == [1] and still['waits'][0]['reason'] == 'scope or card conflict'
    # Active claims and reservations holding the manifests (normalised forms too) do not block.
    active = [{'number': 9, 'provider': 'claude', 'paths': ['src/z.py', './.claude-plugin/marketplace.json']}]
    reserved = [{'card': 8, 'paths': ['src/y.py', 'plugins/fleet-board/.claude-plugin/plugin.json']}]
    held = Scheduler(clock=lambda: 0).admit([_pr_row(3, 'fix', 'src/c.py')], active=active,
                                            reservations=reserved, limits=ignore)
    assert [x['number'] for x in held['admitted']] == [3], held
    assert held['active'][-1]['paths'] == ['src/c.py']
    blocked = Scheduler(clock=lambda: 0).admit([_pr_row(3, 'fix', 'src/c.py')], active=active,
                                               reservations=reserved, limits=LIMITS)
    assert blocked['admitted'] == [] and blocked['waits'][0]['reason'] == 'scope reserved by #8'
    # A card whose every path is ignored keeps its paths: it never turns into a whole-repo scope.
    only = dict(candidate(4, 'fix', paths=[]), actual_paths=list(MANIFESTS))
    other = candidate(5, 'fix', paths=['src/e.py'])
    kept = Scheduler(clock=lambda: 0).admit([only, other], limits=ignore)
    assert sorted(x['number'] for x in kept['admitted']) == [4, 5], kept


def test_scope_ignore_validated_in_limits():
    for bad in ('x', [''], [3], None, ['[z-a].json'], ['x/[b-a]']):
        result = Scheduler(clock=lambda: 0).admit([candidate(1)], limits=dict(LIMITS, scope_ignore=bad))
        assert result['stop_reason'] == 'invalid limits', bad



def test_scope_ignore_one_side_wholly_ignored():
    ignore = dict(LIMITS, scope_ignore=list(MANIFESTS))
    # A wholly-ignored candidate keeps its paths; a reservation holding a manifest plus other
    # paths is filtered, so the two do not overlap (needs the reservation-side filter).
    only = dict(candidate(4, 'fix', paths=[]), actual_paths=list(MANIFESTS))
    res = [{'card': 8, 'paths': ['src/y.py'] + list(MANIFESTS)}]
    r = Scheduler(clock=lambda: 0).admit([only], reservations=res, limits=ignore)
    assert [x['number'] for x in r['admitted']] == [4], r
    act = [{'number': 9, 'provider': 'claude', 'paths': ['src/y.py'] + list(MANIFESTS)}]
    r = Scheduler(clock=lambda: 0).admit([only], active=act, limits=ignore)
    assert [x['number'] for x in r['admitted']] == [4], r
    # The mirror case needs the candidate-side filter: a candidate with a manifest plus
    # other paths against a reservation that holds only manifests (kept whole).
    mixed = _pr_row(5, 'fix', 'src/e.py')
    res = [{'card': 8, 'paths': list(MANIFESTS)}]
    r = Scheduler(clock=lambda: 0).admit([mixed], reservations=res, limits=ignore)
    assert [x['number'] for x in r['admitted']] == [5], r
    act = [{'number': 9, 'provider': 'claude', 'paths': list(MANIFESTS)}]
    r = Scheduler(clock=lambda: 0).admit([mixed], active=act, limits=ignore)
    assert [x['number'] for x in r['admitted']] == [5], r


def test_scope_ignore_cleans_the_path_side():
    ignore = dict(LIMITS, scope_ignore=['.claude-plugin/marketplace.json'])
    rows = [dict(candidate(n, 'fix', paths=['src/%d.py' % n]), actual_paths=['./.claude-plugin/marketplace.json'])
            for n in (1, 2)]
    r = Scheduler(clock=lambda: 0).admit(rows, limits=ignore)
    assert sorted(x['number'] for x in r['admitted']) == [1, 2], r


def test_glob_segments_and_jq_parity():
    import json
    import subprocess
    from supervisor import scopes
    plugin = Path(__file__).resolve().parents[2]
    cases = json.loads((plugin / 'fixtures' / 'glob-cases.json').read_text())
    # `*` stays inside one segment; `**` spans any depth
    assert scopes.drop_ignored(['src/deep/a.py', 'src/a.py'], ['src/*']) == ['src/deep/a.py']
    assert scopes.drop_ignored(['a.json', 'dir/a.json'], ['*.json']) == ['dir/a.json']
    for pattern, path, want in cases:
        assert scopes.glob_match(pattern, path) is want, (pattern, path, want)
    lib = (plugin / 'scripts' / 'path-glob.jq').read_text()
    out = subprocess.run(['jq', '-c', lib + ' [.[] | . as $x | {r: ($x[0] | pg_regex), m: ($x[1] | pg_match([$x[0]]))}]'],
                         input=json.dumps([[p, x] for p, x, _ in cases]), capture_output=True, text=True, check=True)
    got = json.loads(out.stdout)
    for (pattern, path, want), row in zip(cases, got):
        assert row['r'] == scopes.glob_regex(pattern), (pattern, row['r'], scopes.glob_regex(pattern))
        assert row['m'] is want, ('jq', pattern, path, want)
    dropped = subprocess.run(['jq', '-c', lib + ' pg_drop(["*.json"])'], input='["a.json", "dir/a.json"]',
                             capture_output=True, text=True, check=True)
    assert json.loads(dropped.stdout) == ['dir/a.json']
    whole = subprocess.run(['jq', '-c', lib + ' pg_drop(["*.json"])'], input='["a.json"]',
                           capture_output=True, text=True, check=True)
    assert json.loads(whole.stdout) == ['a.json']


if __name__ == '__main__':
    run()
