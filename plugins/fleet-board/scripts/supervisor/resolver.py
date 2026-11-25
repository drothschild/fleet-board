"""Resolve one planned card action to the runner, agent, provider and model that execute it.

Pure function of (merged config, candidate row): no I/O, no subprocesses. Script-only
actions resolve to None and count as the uncapped provider "scripts".
"""
from collections import namedtuple

Dispatch = namedtuple('Dispatch', 'runner agent provider model escalated')

SCRIPTS = 'scripts'
CLAUDE = 'claude'
PROVIDER_IMPLEMENTOR = 'provider-implementor'   # no runner yet: the driver raises an attention instead
IMPLEMENT = ('start', 'continue_implementor')
_REVIEW = ('review', 'start_review')


def _claude(agent, model, escalated):
    return Dispatch('claude', agent, CLAUDE, model, escalated)


def resolve(config, candidate, card_config=None):
    """`card_config` is the config of the card's repo when it is not the home one: implementor.provider and
    implementor.model come from it."""
    action = candidate.get('action')
    models = candidate.get('models') or {}
    cfg_models = (config or {}).get('models') or {}
    escalated = bool(candidate.get('escalated'))
    if action in IMPLEMENT:
        implementor = ((card_config or config) or {}).get('implementor') or {}
        provider = implementor.get('provider', CLAUDE)
        if provider != CLAUDE:   # never a Claude session in its place
            return Dispatch(PROVIDER_IMPLEMENTOR, None, provider, implementor.get('model'), escalated)
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
    if action in ('merger', 'after_merge', 'merge_refusal'):
        return _claude('fleet-board:merger', cfg_models.get('merger') or 'sonnet', escalated)
    if action in ('check_premise', 'draft_followup'):
        return Dispatch('claude', None, CLAUDE, cfg_models.get('checker') or 'sonnet', False)
    return None


def provider_for(config, candidate, card_config=None):
    dispatch = resolve(config, candidate, card_config)
    return SCRIPTS if dispatch is None else dispatch.provider
