"""Resolve one planned card action to the runner, agent, provider and model that execute it.

Pure function of (merged config, candidate row): no I/O, no subprocesses. Script-only
actions resolve to None and count as the uncapped provider "scripts".
"""
from collections import namedtuple

Dispatch = namedtuple('Dispatch', 'runner agent provider model escalated')

SCRIPTS = 'scripts'
CLAUDE = 'claude'
_IMPLEMENT = ('start', 'continue_implementor')
_REVIEW = ('review', 'start_review')


def _claude(agent, model, escalated):
    return Dispatch('claude', agent, CLAUDE, model, escalated)


def resolve(config, candidate):
    action = candidate.get('action')
    models = candidate.get('models') or {}
    cfg_models = (config or {}).get('models') or {}
    escalated = bool(candidate.get('escalated'))
    if action in _IMPLEMENT:
        return _claude('fleet-board:implementor', models.get('implementor'), escalated)
    if action == 'fix':
        return _claude('fleet-board:fixer', models.get('fixer'), escalated)
    if action in _REVIEW:
        reviewer = cfg_models.get('reviewer')
        if isinstance(reviewer, dict):
            return Dispatch('evidence-review', None, reviewer.get('provider'), reviewer.get('model'), escalated)
        return _claude('fleet-board:reviewer', reviewer if reviewer is not None else models.get('reviewer'), escalated)
    if action == 'review_stage':
        stage = candidate.get('stage') or {}
        if stage.get('provider') is None:
            model = stage.get('model')
            if model is None and isinstance(cfg_models.get('reviewer'), str):
                model = cfg_models['reviewer']
            return _claude(stage.get('agent'), model, escalated)
        return Dispatch('stage-review', None, stage['provider'], stage.get('model'), escalated)
    if action == 'merger':
        return _claude('fleet-board:merger', cfg_models.get('merger') or 'sonnet', escalated)
    return None


def provider_for(config, candidate):
    dispatch = resolve(config, candidate)
    return SCRIPTS if dispatch is None else dispatch.provider
