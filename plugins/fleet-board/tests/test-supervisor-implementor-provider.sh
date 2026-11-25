#!/bin/bash
# implementor.provider in the supervisor (card 527): no runner yet, so a provider other than claude is an
# attention and never a Claude session; the keys and the provider cap follow the card's own repo.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-implementor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import os
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc
from supervisor import loop, resolver, roles, scheduler

base = sys.argv[2]
PROVIDER = {'provider': 'codex', 'model': 'gpt-5'}


def provider_board(sub, implementor=PROVIDER, card_state='ready'):
    b = dc.board_for(sub, card_state, config=dict(dc.CONFIG, implementor=dict(implementor)))
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
    return b


def assert_held(b, started, number=12):
    assert started.kind == 'done' and started.action.session is None, 'an implementor session was started'
    assert b.fake_calls() == [], b.fake_calls()
    assert number not in b.state.active
    reason = b.state.attention[str(number)]['reason']
    assert 'implementor.provider' in reason and 'codex' in reason, reason
    guard = b.note()['role_guard']
    assert guard['status'] == 'attention' and guard['reason'] == reason, guard
    assert [e for e in b.state.events if e['type'] == 'attention'], list(b.state.events)


def case_a_start_with_a_provider_implementor_raises_attention_and_starts_no_session(sub):
    b = provider_board(sub)
    assert_held(b, dc.begin(b, 'start'))


def case_a_continue_with_a_provider_implementor_raises_attention_and_starts_no_session(sub):
    b = provider_board(sub, card_state='in_progress')
    assert_held(b, dc.begin(b, 'continue_implementor', state='in_progress'))


def case_a_claude_implementor_provider_still_starts_the_claude_session(sub):
    b = provider_board(sub, {'provider': 'claude', 'model': None})
    started = dc.begin(b, 'start')
    assert started.kind == 'session' and started.action.provider == 'claude', started
    dc.wait_for(started)
    argv = b.fake_calls()[0]['argv']
    assert argv[argv.index('--agent') + 1] == 'fleet-board:implementor', argv
    assert argv[argv.index('--model') + 1] == 'sonnet', argv


def case_the_resolver_never_gives_a_provider_implementor_the_claude_runner(sub):
    config = dict(dc.CONFIG, implementor=PROVIDER)
    for action in ('start', 'continue_implementor'):
        d = resolver.resolve(config, dc.candidate(action))
        assert d.runner != 'claude' and d.agent is None, d
        assert d.provider == 'codex' and d.model == 'gpt-5', d
    fix = resolver.resolve(config, dc.candidate('fix'))
    assert fix.runner == 'claude' and fix.provider == 'claude', fix


def case_the_role_command_refuses_a_provider_implementor(sub):
    config = dict(dc.CONFIG, implementor=PROVIDER)
    d = resolver.resolve(config, dc.candidate('start'))
    try:
        argv = roles.command(d, 'prompt', config, sys.argv[1])
    except ValueError as exc:
        assert 'implementor.provider' in str(exc), exc
        return
    raise AssertionError('built a command: %r' % (argv,))


def two_repo_board(sub, home, other):
    """A home board listing acme/other, whose own .fleet-board.yml sets the implementor keys."""
    checkout = dc.Path(tempfile.mkdtemp(dir=sub)).resolve()
    dc.subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
    dc.subprocess.run(['git', '-C', str(checkout), 'remote', 'add', 'origin', 'https://github.com/acme/other.git'],
                      check=True)
    text = 'board:\n  repo: acme/other\n'
    if other != 'claude':
        text += ('implementor: { provider: %s, model: gpt-5 }\n'
                 'providers:\n  %s:\n    implement_command: "my-cli -C {dir} -m {model}"\n' % (other, other))
    (checkout / '.fleet-board.yml').write_text(text)
    config = dict(dc.CONFIG, board={'repo': 'acme/toy', 'repos': [{'repo': 'acme/other', 'path': str(checkout)}]},
                  implementor={'provider': home, 'model': 'home-model' if home != 'claude' else None},
                  supervisor={'provider_concurrency': {'codex': 1}})
    b = dc.board_for(tempfile.mkdtemp(dir=sub), config=config)
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
    return b


def case_a_card_of_another_repo_takes_the_provider_from_that_repo(sub):
    b = two_repo_board(sub, 'claude', 'codex')
    started = dc.begin(b, 'start', repo='acme/other')
    assert_held(b, started)
    assert started.action.provider == 'codex', started.action


def case_a_card_of_another_repo_ignores_the_home_provider(sub):
    b = two_repo_board(sub, 'codex', 'claude')
    started = dc.begin(b, 'start', repo='acme/other')
    assert started.kind == 'session' and started.action.provider == 'claude', (started, b.state.attention)
    dc.wait_for(started)
    assert len(b.fake_calls()) == 1


def admit(b, rows):
    sup = loop.Supervisor(b.root, config_loader=lambda: b.config, state=b.state, driver=b.driver,
                          scheduler=scheduler.Scheduler(), run=b.run)
    prepared, _ = sup._prepare(rows, b.config, 1000.0)
    try:
        result = sup.scheduler.admit(prepared, active=[], limits=sup._limits(b.config), now=1000.0)
    finally:
        sup.scheduler.close()
    return prepared, result


def case_provider_concurrency_counts_the_implementor_under_its_repos_provider(sub):
    b = two_repo_board(sub, 'claude', 'codex')
    b.seed(13)
    b.seed(14)
    rows = [dc.candidate('start', repo='acme/other', declared_paths=['a']),
            dc.candidate('start', number=13, repo='acme/other', declared_paths=['b']),
            dc.candidate('start', number=14, declared_paths=['c'])]
    prepared, result = admit(b, rows)
    assert [r['provider'] for r in prepared] == ['codex', 'codex', 'claude'], prepared
    assert sorted(r['number'] for r in result['admitted']) == [12, 14], result
    assert [(w['number'], w['reason']) for w in result['waits']] == [(13, 'provider capacity')], result


def case_provider_concurrency_counts_a_home_card_under_the_home_provider(sub):
    b = two_repo_board(sub, 'codex', 'claude')
    b.seed(13)
    rows = [dc.candidate('start', declared_paths=['a']),
            dc.candidate('start', number=13, repo='acme/other', declared_paths=['b'])]
    prepared, _ = admit(b, rows)
    assert [r['provider'] for r in prepared] == ['codex', 'claude'], prepared


only = os.environ.get('FLEET_TEST_ONLY')
names = sorted(n for n in dict(globals()) if n.startswith('case_') and (not only or n == only))
if only:
    sys.stderr.write('FLEET_TEST_ONLY=%s: %d test(s) selected\n' % (only, len(names)))
    if not names:
        sys.exit(5)
failed = 0
for name in names:
    try:
        globals()[name](tempfile.mkdtemp(dir=base))
        print('  ok   ' + name)
    except Exception as exc:  # noqa: BLE001
        failed += 1
        print('  FAIL %s: %r' % (name, exc))
print('passed: %d   failed: %d' % (len(names) - failed, failed))
sys.exit(1 if failed else 0)
PY
