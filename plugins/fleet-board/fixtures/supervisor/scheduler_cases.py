"""Deterministic admission scheduler contract tests."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from supervisor.scheduler import Scheduler


def candidate(number, action='start', provider='claude', paths=None, priority='normal', eligible_since=0):
    return {'number': number, 'action': action, 'provider': provider, 'declared_paths': paths or [],
            'actual_paths': [], 'scope_complete': True, 'priority': priority,
            'eligible_since': eligible_since, 'preconditions': {'state': 'ready', 'head_sha': None}}


def run():
    scheduler = Scheduler(clock=lambda: 0)
    # A stays live while B can complete and independent C is admitted.
    a = candidate(1); b = candidate(2, 'review'); c = candidate(3, paths=['src/c.py'])
    result = scheduler.admit([a, b, c], active=[{'number': 1, 'provider': 'claude', 'paths':['src/a.py']}],
                             limits={'global': 2, 'providers': {'claude': 2}, 'per_card': 1})
    assert [x['number'] for x in result['admitted']] == [2, 3]
    # Two simultaneous requests share capacity through the serialized admission lock.
    assert scheduler.admit([candidate(4)], active=result['active'], limits={'global':2,'providers':{'claude':2},'per_card':1})['admitted'] == []
    # Provider and card caps, and lowered global cap, are enforced from active claims.
    assert scheduler.admit([candidate(5,'review','openai')], active=[{'number':9,'provider':'claude','paths':[]}],
                           limits={'global':1,'providers':{'openai':1},'per_card':1})['admitted'] == []
    # Disjoint candidates may pass a conflicting candidate; the blocked card claims no scope.
    choices = scheduler.admit([candidate(6, paths=['src/a']), candidate(7, paths=['docs/b'])],
        active=[{'number':8,'provider':'claude','paths':['src/a/file']}],
        limits={'global':2,'providers':{'claude':2},'per_card':1})
    assert [x['number'] for x in choices['admitted']] == [7]
    # Priority ties age monotonically and survive scheduler recreation via exported state.
    scheduler = Scheduler(clock=lambda: 100, state={'eligible_since': {'10': 0}})
    selected = scheduler.admit([candidate(11, priority='high', eligible_since=100), candidate(10, priority='low')],
        limits={'global':1,'providers':{'claude':1},'per_card':1,'aging_seconds':10})
    assert selected['admitted'][0]['number'] == 10
    assert Scheduler(clock=lambda:100,state=selected['state']).state == selected['state']
    # Unknown workflow state never normalizes or admits and reports attention; active claims remain.
    unknown = scheduler.admit([candidate(12, action='unknown_state')], active=[{'number':12,'provider':'claude','paths':[]}],
        limits={'global':2,'providers':{'claude':2},'per_card':1})
    assert not unknown['admitted'] and unknown['attention'][0]['number'] == 12 and unknown['active'][0]['number'] == 12
    # Fake-time guards: retry/backoff, launch spacing, rate wait, deadline/cost, unknown spend, invalid reload.
    clock = {'now': 10}
    timed = Scheduler(clock=lambda: clock['now'])
    wait = timed.admit([candidate(20)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'retry_at':{'20':15},'min_launch_gap':3,'last_launch_at':9,'rate_limit_wait':100,'max_rate_wait':8,
        'session_deadline':20,'max_cost':1,'known_spend':1,'unknown_spend':False})
    assert not wait['admitted'] and wait['waits']
    blocked = timed.admit([candidate(21)], limits={'global':2,'providers':{'claude':2},'per_card':1,
        'session_deadline':9,'max_cost':2,'known_spend':0,'unknown_spend':True})
    assert not blocked['admitted'] and blocked['stop_reason']
    assert timed.reload({'global':0}) is False
    print('scheduler cases passed')


if __name__ == '__main__':
    run()
