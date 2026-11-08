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
    assert async_scheduler.due_timers([{'attempt_id':'x','deadline':1}], now=2) == [{'attempt_id':'x','kind':'deadline'}]
    gate.set()
    assert first.result(timeout=2) == {'revision': 1} and rerun.wait(2) and count['plans'] == 2
    async_scheduler.close()
    # Unknown workflow state never normalizes or admits and reports attention; active claims remain.
    unknown = scheduler.admit([candidate(12, action='unknown_state')], active=[{'number':12,'provider':'claude','paths':[]}],
        limits={'global':2,'providers':{'claude':2},'per_card':1})
    assert not unknown['admitted'] and unknown['attention'][0]['number'] == 12 and unknown['active'][0]['number'] == 12
    # Fake-time guards: retry/backoff, launch spacing, rate wait, deadline/cost, unknown spend, invalid reload.
    clock = {'now': 10}
    timed = Scheduler(clock=lambda: clock['now'])
    wait = timed.admit([candidate(20)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'retry_at':{'20':15},'min_launch_gap':3,'last_launch_at':9,'rate_limit_wait':100,'max_rate_wait':8,
        'session_deadline':20,'max_cost':1,'known_spend':0.5,'unknown_spend':False})
    assert not wait['admitted'] and wait['waits']
    assert wait['waits'][0]['reason'] == 'retry backoff' and wait['waits'][0]['until'] == 15
    rate = timed.admit([candidate(22)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'rate_limit_wait':{'claude':100},'max_rate_wait':8,'session_deadline':20})
    assert rate['waits'][0]['reason'] == 'provider rate limit' and rate['waits'][0]['until'] == 18
    capped = timed.admit([candidate(23)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'rate_limit_wait':{'claude':100},'max_rate_wait':8,'session_deadline':20}, now=18)
    assert not capped['admitted'] and (capped['stop_reason'] == 'provider rate-limit wait cap reached'
        or any(item['reason'] == 'provider rate-limit wait cap reached' for item in capped['attention']))
    blocked = timed.admit([candidate(21)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'session_deadline':9,'max_cost':2,'known_spend':0,'unknown_spend':True})
    assert not blocked['admitted'] and blocked['stop_reason']
    assert timed.reload({'global':0}) is False
    print('scheduler cases passed')


if __name__ == '__main__':
    run()
