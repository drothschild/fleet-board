"""Resolver contract tests: which runner/agent/provider/model runs a planned action."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from supervisor import resolver
from supervisor.resolver import Dispatch

STRING_CFG = {'models': {'implementor': 'sonnet', 'reviewer': 'opus', 'fixer': 'sonnet'}}
OBJECT_CFG = {'models': {'implementor': 'sonnet', 'fixer': 'sonnet', 'escalation': 'opus',
                         'reviewer': {'provider': 'codex', 'model': 'gpt-5', 'timeout': 900, 'price': None}}}


def cand(action, models=None, escalated=False, stage=None):
    return {'number': 7, 'action': action, 'escalated': escalated, 'stage': stage,
            'models': models or {'implementor': 'sonnet', 'reviewer': 'opus', 'fixer': 'sonnet'}}


def test_start_and_continue_use_the_implementor_agent():
    for action in ('start', 'continue_implementor'):
        d = resolver.resolve(STRING_CFG, cand(action))
        assert d == Dispatch('claude', 'fleet-board:implementor', 'claude', 'sonnet', False), d


def test_fix_uses_the_fixer_agent_and_fixer_model():
    d = resolver.resolve(STRING_CFG, cand('fix', {'implementor': 'sonnet', 'reviewer': 'opus', 'fixer': 'haiku'}))
    assert d == Dispatch('claude', 'fleet-board:fixer', 'claude', 'haiku', False), d


def test_string_reviewer_dispatches_the_claude_reviewer():
    for action in ('review', 'start_review'):
        d = resolver.resolve(STRING_CFG, cand(action))
        assert d == Dispatch('claude', 'fleet-board:reviewer', 'claude', 'opus', False), d


def test_object_reviewer_dispatches_evidence_review():
    for action in ('review', 'start_review'):
        d = resolver.resolve(OBJECT_CFG, cand(action))
        assert d == Dispatch('evidence-review', None, 'codex', 'gpt-5', False), d


def test_agent_stage_runs_claude_with_the_stage_agent_and_model():
    stage = {'name': 'sec', 'agent': 'security-reviewer', 'provider': None, 'model': 'opus'}
    d = resolver.resolve(STRING_CFG, cand('review_stage', stage=stage))
    assert d == Dispatch('claude', 'security-reviewer', 'claude', 'opus', False), d


def test_provider_stage_runs_stage_review_with_stage_provider_and_model():
    stage = {'name': 'arch', 'agent': None, 'provider': 'openai', 'model': 'gpt-5-mini'}
    d = resolver.resolve(STRING_CFG, cand('review_stage', stage=stage))
    assert d == Dispatch('stage-review', None, 'openai', 'gpt-5-mini', False), d


def test_merger_defaults_to_sonnet_and_honours_models_merger():
    d = resolver.resolve(STRING_CFG, cand('merger'))
    assert d == Dispatch('claude', 'fleet-board:merger', 'claude', 'sonnet', False), d
    cfg = {'models': dict(STRING_CFG['models'], merger='opus')}
    assert resolver.resolve(cfg, cand('merger')).model == 'opus'


def test_escalated_round_uses_the_escalation_model():
    models = {'implementor': 'opus', 'reviewer': 'opus', 'fixer': 'opus'}
    d = resolver.resolve(STRING_CFG, cand('fix', models, escalated=True))
    assert d == Dispatch('claude', 'fleet-board:fixer', 'claude', 'opus', True), d


def test_script_actions_resolve_to_none():
    for action in ('block', 'merge', 'update_branch', 'to_human_qa', 'advance_stage', 'skip', 'wait',
                   'mark_ready', 'verify_main', 'finish', 'file_pending', 'unblock'):
        assert resolver.resolve(STRING_CFG, cand(action)) is None, action
        assert resolver.provider_for(STRING_CFG, cand(action)) == 'scripts', action


def test_provider_for_reports_the_dispatch_provider():
    assert resolver.provider_for(STRING_CFG, cand('start')) == 'claude'
    assert resolver.provider_for(OBJECT_CFG, cand('review')) == 'codex'


if __name__ == '__main__':
    names = sorted(n for n in dir() if n.startswith('test_'))
    for n in names:
        globals()[n]()
    print('ok - %d resolver cases' % len(names))
