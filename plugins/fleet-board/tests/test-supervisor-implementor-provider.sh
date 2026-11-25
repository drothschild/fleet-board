#!/bin/bash
# implementor.provider in the supervisor (cards 527 and 530): a provider other than claude runs
# implementor-run.sh and never a Claude session; the keys and the provider cap follow the card's own repo.
# The runner cases use the real implementor-run.sh and guard, with a fake provider command and a local origin.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-implementor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
unset FLEET_BOARD_HOME FB_CFG_FOR FLEET_CFG FLEET_ROOT GH_REPO GH_HOST
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import os
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc
from supervisor import loop, resolver, roles, scheduler, usage

base = sys.argv[2]
PROVIDER = {'provider': 'codex', 'model': 'gpt-5'}


def provider_board(sub, implementor=PROVIDER, card_state='ready'):
    b = dc.board_for(sub, card_state, config=dict(dc.CONFIG, implementor=dict(implementor)))
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
    return b


def git(cwd, *args):
    dc.subprocess.run(['git', '-C', str(cwd)] + [str(a) for a in args], check=True, stdout=dc.subprocess.DEVNULL)


FAKE_PROVIDER = '''#!/bin/bash
# fake-provider <dir> <model>
printf '%s\\n' "$2" >> "$PROVIDER_DIR/models"
cat > "$PROVIDER_DIR/prompt"
REPORT="$(awk '/^## Report file$/ { getline; print; exit }' "$PROVIDER_DIR/prompt")"
. "$PROVIDER_DIR/actions"
'''
GOOD = 'cp "$PROVIDER_DIR/report.md" "$REPORT"; echo finished\n'


def runner_board(sub, actions=GOOD, card_state='ready', models=None, timeout=60, supervisor=None):
    '''A board whose card has a real worktree and origin, so the real implementor-run.sh runs behind the real guard.'''
    base = dc.Path(sub).resolve()
    provider = {'implement_command': 'fake-provider {dir} {model}'}
    if models is not None:
        provider['models'] = models
    config = dict(dc.CONFIG, implementor=dict(PROVIDER), providers={'codex': provider},
                  supervisor=dict(supervisor or {}))
    b = dc.board_for(sub, card_state, config=config)
    extra = ''
    if models is not None:
        extra = '    models: [%s]\n' % ', '.join(models)
    with open(str(b.root / '.fleet-board.yml'), 'a') as f:
        f.write('implementor:\n  provider: codex\n  model: gpt-5\n  timeout: %d\n'
                'providers:\n  codex:\n    implement_command: "fake-provider {dir} {model}"\n%s' % (timeout, extra))
    (b.root / '.gitignore').write_text('.fleet-board/\n.fleet-board.yml\n.fw/\n')
    origin = base / 'origin.git'
    git(base, 'init', '-q', '--bare', origin)
    git(b.root, 'add', '.gitignore')
    git(b.root, 'commit', '-q', '-m', 'init')
    git(b.root, 'remote', 'add', 'origin', origin)
    git(b.root, 'push', '-q', 'origin', 'HEAD:main')
    git(b.root, 'worktree', 'add', '-q', '-b', dc.BRANCH, b.worktree)
    bin_dir = base / 'bin'
    bin_dir.mkdir()
    for name, text in (('gh', '#!/bin/bash\nexit 0\n'), ('fake-provider', FAKE_PROVIDER)):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    fake = base / 'provider'
    fake.mkdir()
    (fake / 'actions').write_text(actions)
    (fake / 'report.md').write_text((dc.PLUGIN / 'fixtures' / 'reports' / 'implementor-ok.md').read_text())
    b.provider_dir = fake
    b.env.update(PATH='%s:%s' % (bin_dir, os.environ['PATH']), PROVIDER_DIR=str(fake),
                 FLEET_BOARD_LOG_DIR=str(base / 'log'))
    b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
    return b


def models_run(b):
    path = b.provider_dir / 'models'
    return path.read_text().split() if path.exists() else []


def events(b, kind):
    return [e for e in b.state.events if e['type'] == kind]


def ledger(b):
    lines, skipped = usage.read(b.root)
    assert skipped == 0, skipped
    return lines


def finish(b, started):
    assert started.kind == 'session', (started, list(b.state.events), b.state.attention)
    result = dc.wait_for(started)
    err = dc.Path(result.log_path).with_suffix('.err').read_text()
    return result, b.driver.finish(started.action, result), err


def assert_runs_the_runner(b, started):
    assert started.kind == 'session', (started, list(b.state.events), b.state.attention)
    argv = started.action.session.argv
    assert argv[0] == 'bash' and argv[1].endswith('/scripts/implementor-run.sh'), argv
    assert argv[2:] == ['12', b.worktree, dc.BRANCH], argv
    result, outcome, err = finish(b, started)
    assert outcome == dc.driver.Outcome(12, True, False, None), (outcome, result, err, list(b.state.events))
    assert b.fake_calls() == [], 'a claude session was started: %r' % b.fake_calls()
    assert models_run(b) == ['gpt-5'], models_run(b)
    assert b.note()['last_verified'] and b.note()['action_failures'] == 0, b.note()
    assert [c for c in b.comments() if c.startswith('## Status')], b.comments()
    assert 12 not in b.state.active


def case_a_ready_card_with_a_provider_implementor_runs_implementor_run_and_no_claude_session(sub):
    b = runner_board(sub)
    assert_runs_the_runner(b, dc.begin(b, 'start'))


def case_a_continued_card_with_a_provider_implementor_runs_implementor_run(sub):
    b = runner_board(sub, card_state='in_progress')
    assert_runs_the_runner(b, dc.begin(b, 'continue_implementor', state='in_progress'))


def case_a_runner_provider_failure_is_a_provider_failure_event_and_charges_nothing(sub):
    b = runner_board(sub, 'echo "authentication failed" >&2; exit 9\n', card_state='in_progress')
    b.put_note({'implementor_attempts': 2})
    result, outcome, err = finish(b, dc.begin(b, 'continue_implementor', state='in_progress'))
    assert result.exit_code == 4 and result.failure == 'provider', (result, err)
    assert outcome == dc.driver.Outcome(12, False, False, 'codex'), outcome
    (event,) = events(b, 'provider_failure')
    assert event['payload']['card'] == 12 and event['payload']['provider'] == 'codex', event
    assert 'provider failure' in event['payload']['reason'] and not roles.AUTH_RE.search(result.reason), result.reason
    note = b.note()
    assert note['action_failures'] == 0 and note['implementor_attempts'] == 2, note
    assert not events(b, 'action_failed') and b.state.attention == {}, list(b.state.events)


def case_a_runner_timeout_is_a_provider_failure_even_at_the_attempt_timeout(sub):
    b = runner_board(sub, 'sleep 30\n', timeout=1, supervisor={'attempt_timeout_seconds': 1})
    result, outcome, err = finish(b, dc.begin(b, 'start'))
    assert outcome.provider_failure == 'codex' and not result.timed_out, (outcome, result, err)
    assert b.note()['implementor_attempts'] == 0 and b.note()['action_failures'] == 0, b.note()


def case_a_card_with_a_provider_failure_is_retried_after_retry_backoff_seconds(sub):
    b = runner_board(sub, 'exit 9\n', supervisor={'retry_backoff_seconds': 45})
    now = [1000.0]
    sup = loop.Supervisor(b.root, config_loader=lambda: b.config, state=b.state, driver=b.driver,
                          scheduler=scheduler.Scheduler(), run=b.run, clock=lambda: now[0])
    sup.config = b.config
    sup._plan_card = lambda card: None
    started = dc.begin(b, 'start')
    assert started.kind == 'session', (started, b.state.attention)
    sup._ended(started.action, dc.wait_for(started))
    assert b.state.provider_health['codex']['until'] == 1045.0, b.state.provider_health
    rows, _ = sup._prepare([dc.candidate('continue_implementor', state='in_progress', declared_paths=['a'])],
                           b.config, now[0])

    def admit(at):
        return sup.scheduler.admit(rows, active=[], limits=sup._limits(b.config), now=at)

    try:
        early = admit(1044.0)
        assert early['admitted'] == [] and early['waits'][0]['reason'] == 'provider rate limit', early
        assert [r['number'] for r in admit(1045.0)['admitted']] == [12]
    finally:
        sup.scheduler.close()


def case_the_ledger_records_the_providers_model_with_unknown_tokens(sub):
    b = runner_board(sub)
    finish(b, dc.begin(b, 'start'))
    (line,) = ledger(b)
    assert (line['role'], line['provider'], line['model']) == ('implementor', 'codex', 'gpt-5'), line
    assert line['input'] is None and line['output'] is None, line


def case_the_ledger_records_the_provider_model_of_a_failed_run(sub):
    b = runner_board(sub, 'exit 9\n')
    finish(b, dc.begin(b, 'start'))
    (line,) = ledger(b)
    assert (line['provider'], line['model']) == ('codex', 'gpt-5'), line
    assert line['input'] is None and line['output'] is None, line


def escalated_begin(b):
    return dc.begin(b, 'continue_implementor', state='in_progress', escalated=True,
                    models={'implementor': 'opus', 'reviewer': 'opus', 'fixer': 'opus'})


def case_escalation_runs_the_next_model_of_the_same_provider(sub):
    b = runner_board(sub, card_state='in_progress', models=['gpt-4', 'gpt-5', 'gpt-6', 'gpt-7'])
    started = escalated_begin(b)
    assert started.action.provider == 'codex', started.action
    result, outcome, err = finish(b, started)
    assert outcome.progressed, (outcome, err)
    assert models_run(b) == ['gpt-6'] and b.fake_calls() == [], (models_run(b), b.fake_calls())
    assert ledger(b)[0]['model'] == 'gpt-6', ledger(b)
    assert b.note()['models']['implementor'] == 'codex:gpt-6' and b.note()['escalated'] is True, b.note()


def assert_no_next_model(b):
    started = escalated_begin(b)
    assert started.kind == 'done' and started.action.session is None, 'a session was started'
    assert b.fake_calls() == [] and models_run(b) == [], (b.fake_calls(), models_run(b))
    reason = b.state.attention['12']['reason']
    assert 'gpt-5' in reason and 'providers.codex.models' in reason, reason
    guard = b.note()['role_guard']
    assert guard['status'] == 'attention' and guard['reason'] == reason, guard
    assert events(b, 'attention'), list(b.state.events)


def case_escalation_past_the_last_model_raises_attention(sub):
    assert_no_next_model(runner_board(sub, card_state='in_progress', models=['gpt-4', 'gpt-5']))


def case_escalation_without_a_model_list_raises_attention(sub):
    assert_no_next_model(runner_board(sub, card_state='in_progress'))


def case_escalation_from_a_model_outside_the_list_raises_attention(sub):
    assert_no_next_model(runner_board(sub, card_state='in_progress', models=['gpt-6', 'gpt-7']))


def case_a_running_provider_implementor_fills_its_provider_concurrency(sub):
    b = runner_board(sub, 'sleep 2\n' + GOOD, supervisor={'provider_concurrency': {'codex': 1}})
    b.seed(13)
    started = dc.begin(b, 'start')
    assert started.kind == 'session', (started, b.state.attention)
    sup = loop.Supervisor(b.root, config_loader=lambda: b.config, state=b.state, driver=b.driver,
                          scheduler=scheduler.Scheduler(), run=b.run)
    rows, _ = sup._prepare([dc.candidate('start', number=13, declared_paths=['c'])], b.config, 1000.0)
    try:
        result = sup.scheduler.admit(rows, active=sup._active_claims(), limits=sup._limits(b.config), now=1000.0)
    finally:
        sup.scheduler.close()
    assert [(w['number'], w['reason']) for w in result['waits']] == [(13, 'provider capacity')], result
    finish(b, started)


def status_line(b):
    got = dc.subprocess.run(['bash', str(dc.PLUGIN / 'scripts' / 'status.sh')], cwd=str(b.root), capture_output=True,
                            text=True, env=dict(os.environ, **b.env))   # not one of the supervisor's own scripts
    assert got.returncode == 0, got
    return [line for line in got.stdout.splitlines() if line.startswith('  #12 ')][0]


def case_status_lists_a_provider_implementors_provider(sub):
    b = runner_board(sub)
    started = dc.begin(b, 'start')
    assert started.kind == 'session', (started, b.state.attention)
    assert 'codex:gpt-5/opus' in status_line(b), status_line(b)
    finish(b, started)


def case_a_fixer_round_keeps_the_provider_implementor_in_the_note(sub):
    b = runner_board(sub, card_state='in_review')
    b.put_note({'state': 'in_review', 'round': 1, 'pr': 34, 'branch': dc.BRANCH, 'worktree': b.worktree,
                'models': {'implementor': 'codex:gpt-5', 'reviewer': 'opus', 'fixer': 'sonnet'},
                'last_review': dc.LAST_REVIEW})
    b.plans({'report': 'fixer-ok'})
    started = dc.begin(b, 'fix', state='in_review', round=1)
    result, outcome, err = finish(b, started)
    assert outcome.progressed and b.note()['round'] == 2, (outcome, result, b.note(), list(b.state.events))
    assert b.note()['models']['implementor'] == 'codex:gpt-5', b.note()['models']


def case_the_post_run_check_attention_reaches_the_board(sub):
    b = runner_board(sub)
    (b.provider_dir / 'actions').write_text('echo stray > "%s/stray.txt"\n%s' % (b.root, GOOD))
    result, outcome, err = finish(b, dc.begin(b, 'start'))
    assert result.exit_code == 3, (result, err)
    reason = b.state.attention['12']['reason']
    assert 'stray.txt changed outside the worktree' in reason, reason
    guard = b.note()['role_guard']
    assert guard == {'role': 'implementor', 'status': 'attention', 'reason': reason}, guard
    assert [c for c in b.comments() if 'stray.txt' in c], b.comments()
    assert not [c for c in b.comments() if c.startswith('## Status')], b.comments()
    assert events(b, 'attention') and b.note()['action_failures'] == 0, (list(b.state.events), b.note())
    assert not events(b, 'provider_failure') and 12 not in b.state.active


def case_the_post_run_check_attention_wins_over_a_failed_provider_run(sub):
    b = runner_board(sub)
    (b.provider_dir / 'actions').write_text('echo stray > "%s/stray.txt"; exit 9\n' % b.root)
    result, outcome, err = finish(b, dc.begin(b, 'start'))
    assert result.exit_code == 3 and outcome.provider_failure is None, (result, outcome, err)
    assert b.note()['role_guard']['status'] == 'attention', b.note()


def case_two_rejected_provider_reports_are_recorded_as_a_report_error(sub):
    b = runner_board(sub, 'printf "## Status\\nfinished\\n" > "$REPORT"; echo finished\n')
    result, outcome, err = finish(b, dc.begin(b, 'start'))
    assert result.exit_code == 6, (result, err)
    note = b.note()
    assert note['report_errors'][0]['role'] == 'implementor' and note['action_failures'] == 1, note


def case_a_runner_setup_failure_counts_against_the_card(sub):
    b = runner_board(sub)
    yml = b.root / '.fleet-board.yml'
    yml.write_text(yml.read_text().replace('  model: gpt-5\n', ''))
    result, outcome, err = finish(b, dc.begin(b, 'start'))
    assert result.exit_code == 1, (result, err)
    assert b.note()['action_failures'] == 1 and not events(b, 'provider_failure'), b.note()
    assert 'implementor.model' in b.note()['last_action_error'], b.note()


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


def case_the_role_command_for_a_provider_implementor_is_implementor_run(sub):
    config = dict(dc.CONFIG, implementor=PROVIDER)
    d = resolver.resolve(config, dc.candidate('start'))
    argv = roles.command(d, 'prompt', config, '/plugin', stage_args=[12, '/wt', dc.BRANCH])
    assert argv == ['bash', '/plugin/scripts/implementor-run.sh', '12', '/wt', dc.BRANCH], argv


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


def case_a_card_of_another_repo_runs_the_runner_in_that_repos_checkout(sub):
    b = two_repo_board(sub, 'claude', 'codex')
    dc.fake_plugin(b, 4, '')
    (b.driver.plugin_dir / 'scripts' / 'implementor-run.sh').write_text(
        '#!/bin/bash\n{ pwd -P; printf "%s\\n" "$FLEET_BOARD_HOME" "$@"; } > "$FAKE_STAGE_DIR/seen"\nexit 4\n')
    started = dc.begin(b, 'start', repo='acme/other')
    assert started.kind == 'session' and started.action.provider == 'codex', (started, b.state.attention)
    result = dc.wait_for(started)
    assert result.failure == 'provider', result
    seen = (b.fake / 'seen').read_text().splitlines()
    checkout = b.config['board']['repos'][0]['path']
    assert seen == [checkout, str(b.root), '12', b.worktree, dc.BRANCH], seen
    assert b.fake_calls() == []


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
