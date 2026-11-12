"""Card driver contract tests: every script-only action on a local fixture board.

Board scripts (board-move, board-comment, note, board-read) run for real against a seeded local store; the
scripts that need a remote or a worktree (worktree, update-branch, verify-main, ...) are stubbed and recorded.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'scripts'))
from supervisor import driver, scripts, state  # noqa: E402

FAKE_ROLE = PLUGIN / 'fixtures' / 'supervisor' / 'fake_role.py'
BRANCH = 'fleet/12-add-subtract'
CONFIG = {'board': {'repo': 'acme/toy'}, 'review': {'stages': [{'name': 'security'}, {'name': 'perf'}]},
          'commands': {}}


def ok(stdout=''):
    return scripts.ScriptResult(0, stdout, '', False)


def fail_with(stderr, rc=1):
    return scripts.ScriptResult(rc, '', stderr, False)


class Board:
    def __init__(self, base, config=None):
        self.root = Path(base).resolve() / 'repo'
        self.root.mkdir()
        subprocess.run(['git', '-C', str(self.root), 'init', '-q'], check=True)
        (self.root / '.fleet-board.yml').write_text(
            'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nreview:\n  stages:\n'
            '    - name: security\n      agent: sec-reviewer\n      model: opus\n'
            '    - name: perf\n      agent: perf-reviewer\n      model: sonnet\n')
        (self.root / '.fleet-board' / 'cards').mkdir(parents=True)
        (self.root / '.fleet-board' / 'next').write_text('100\n')
        self.fake = Path(base).resolve() / 'fake'
        self.fake.mkdir()
        os.environ['FLEET_BOARD_CLAUDE'] = str(FAKE_ROLE)
        self.env = {'FLEET_BOARD_USER': 'fleet-bot', 'FAKE_ROLE_DIR': str(self.fake), 'FAKE_ROLE_CARD': '12',
                    'FAKE_ROLE_ROLE': '', 'FAKE_STAGE_DIR': str(self.fake)}
        self.worktree = str(self.root / '.fw' / '12-add-subtract')
        self.config = config or CONFIG
        self.calls = []
        self.gh_calls = []
        self.stubs = {}
        self.gh_result = ok()
        self.git_calls = []
        self.git_result = ok('abc1234\n')
        self.state = state.State('run-1')
        self.driver = driver.CardDriver(self.root, lambda: self.config, self.state, run=self.run, gh=self.gh,
                                        git=self.git, env=self.env, log_dir=Path(base).resolve() / 'logs')

    def plans(self, *plans):
        for i, plan in enumerate(plans, 1):
            (self.fake / ('%d.json' % i)).write_text(json.dumps(plan))

    def fake_calls(self, at_least=0):
        path = self.fake / 'log.jsonl'
        end = time.monotonic() + 15
        while True:
            calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
            if len(calls) >= at_least or time.monotonic() > end:
                return calls
            time.sleep(0.05)

    def prompt(self, n=1):
        argv = self.fake_calls(n)[n - 1]['argv']
        return argv[argv.index('-p') + 1]

    def git(self, cwd, *args):
        self.git_calls.append((str(cwd),) + tuple(str(a) for a in args))
        r = self.git_result
        return r(*args) if callable(r) else r

    def run(self, root, name, *args, **kw):
        self.calls.append((name,) + tuple(str(a) for a in args))
        if name in self.stubs:
            stub = self.stubs[name]
            return stub(*args) if callable(stub) else stub
        return scripts.run(root, name, *args, env=self.env, **kw)

    def gh(self, root, *args):
        self.gh_calls.append(tuple(args))
        r = self.gh_result
        return r(*args) if callable(r) else r

    def scripts_called(self):
        """Script names in call order, without the note reads and merges."""
        return [c[0] for c in self.calls if c[0] != 'note.sh']

    def seed(self, number, card_state='ready', body='', acceptance=('does it',)):
        card = {'number': number, 'title': 'Add subtract', 'body': body, 'state': card_state, 'labels': [],
                'acceptance': list(acceptance), 'blocked_by': [], 'next_comment_id': 1, 'comments': [],
                'created_at': '2026-01-01T00:00:00Z'}
        (self.root / '.fleet-board' / 'cards' / ('%d.json' % number)).write_text(json.dumps(card))

    def card(self, number=12):
        return json.loads((self.root / '.fleet-board' / 'cards' / ('%d.json' % number)).read_text())

    def note(self, number=12):
        r = scripts.run(self.root, 'note.sh', 'get', number, env=self.env)
        assert r.rc == 0, r
        return json.loads(r.stdout)

    def put_note(self, patch, number=12):
        path = self.root / 'patch.json'
        path.write_text(json.dumps(patch))
        r = scripts.run(self.root, 'note.sh', 'merge', number, str(path), env=self.env)
        assert r.rc == 0, r

    def comments(self, number=12):
        return [c['body'] for c in self.card(number)['comments'] if 'fleet-board:manager-note' not in c['body']]


def candidate(action, **kw):
    row = {'number': 12, 'action': action, 'reason': 'because', 'state': 'ready', 'branch': BRANCH,
           'worktree': None, 'pr': 34, 'models': {'implementor': 'sonnet', 'reviewer': 'opus', 'fixer': 'sonnet'},
           'escalated': False, 'findings': None, 'waiting_on': None, 'comment_needed': None, 'lint': None,
           'lint_marker': None, 'head_sha': 'abc1234', 'round': None, 'stage': None}
    row.update(kw)
    return row


def board_for(base, card_state='ready', **kw):
    b = Board(base, kw.pop('config', None))
    b.seed(12, card_state, **kw)
    return b


def wait_for(started, limit=30):
    session = started.action.session
    end = time.monotonic() + limit
    while time.monotonic() < end:
        result = session.poll()
        if result is not None:
            return result
        time.sleep(0.05)
    raise AssertionError('role session did not finish')


def run_role(b, started):
    """Wait for the session and hand its result to finish()."""
    return b.driver.finish(started.action, wait_for(started))


def worktree_ok(b):
    b.stubs['worktree.sh'] = lambda *a: ok(json.dumps({'path': b.worktree, 'copy': None, 'sha': 'abc1234',
                                                       'base': 'bace000'})
                                           if a[0] == 'review' else b.worktree + '\n')


LAST_REVIEW = {'round': 1, 'sha': 'abc1234', 'critical': 0, 'important': 1, 'stage': None, 'agent': None,
               'model': None, 'provider': None, 'findings': [{'severity': 'Important', 'text': 'no test'}]}


def begin(b, action, **kw):
    kw.setdefault('worktree', b.worktree)
    return b.driver.begin(candidate(action, **kw))


def test_start_runs_setup_and_returns_a_session(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    assert started.kind == 'session' and started.action.action == 'start'
    assert started.action.card == 12 and started.action.role == 'implementor'
    assert b.scripts_called() == ['worktree.sh', 'board-move.sh', 'board-read.sh'], b.calls
    assert b.calls[0] == ('worktree.sh', 'create', '12', BRANCH, b.worktree)
    assert b.calls[1] == ('board-move.sh', '12', 'in_progress')
    assert b.card()['state'] == 'in_progress'
    note = b.note()
    assert note['branch'] == BRANCH and note['worktree'] == b.worktree and note['round'] == 0, note
    assert note['implementor_attempts'] == 1 and note['models']['implementor'] == 'sonnet', note
    assert note['state'] == 'in_progress'
    assert b.state.active[12] is started.action and started.action.session is not None
    wait_for(started)
    assert b.fake_calls()[0]['argv'][b.fake_calls()[0]['argv'].index('--agent') + 1] == 'fleet-board:implementor'


def test_failed_step_counts_once_and_stops(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = fail_with('fleet-board: boom\nsecond line\n')
    started = begin(b, 'start')
    assert started.kind == 'done' and 12 not in b.state.active
    assert b.scripts_called() == ['worktree.sh'], b.calls
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'fleet-board: boom', note
    assert b.card()['state'] == 'ready'
    begin(b, 'start')
    assert b.note()['action_failures'] == 2
    assert [e for e in b.state.events if e['type'] == 'action_failed'], list(b.state.events)


def test_timed_out_step_counts_a_failure(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = scripts.ScriptResult(124, '', '', True)
    begin(b, 'start')
    assert b.note()['last_action_error'] == 'worktree.sh timed out'


def test_start_review_routes_moves_and_notes(base):
    b = board_for(base, 'in_progress')
    b.stubs['review-stages.sh'] = ok('["security"]\n')
    b.stubs['worktree.sh'] = ok(json.dumps({'path': b.worktree, 'copy': None, 'sha': 'abc1234', 'base': 'bace000'}))
    started = begin(b, 'start_review', state='in_progress')
    assert started.kind == 'session' and started.action.role == 'reviewer' and started.action.session
    assert b.scripts_called() == ['review-stages.sh', 'board-move.sh', 'board-read.sh', 'worktree.sh'], b.calls
    assert b.calls[-1] == ('worktree.sh', 'review', '12', '34'), b.calls
    assert b.calls[0] == ('review-stages.sh', 'route', '12', '34')
    assert b.calls[1] == ('board-move.sh', '12', 'in_review')
    assert b.card()['state'] == 'in_review'
    note = b.note()
    assert note['round'] == 1 and note['pr'] == 34 and note['state'] == 'in_review', note


def test_start_review_route_failure_moves_nothing(base):
    b = board_for(base, 'in_progress')
    b.stubs['review-stages.sh'] = fail_with('route broke\n')
    assert begin(b, 'start_review', state='in_progress').kind == 'done'
    assert b.card()['state'] == 'in_progress'
    assert b.scripts_called() == ['review-stages.sh']
    note = b.note()
    assert note['action_failures'] == 1 and note['pr'] is None and note['last_action_error'] == 'route broke'


def test_advance_stage_moves_and_records_the_stage(base):
    b = board_for(base, 'in_review')
    started = begin(b, 'advance_stage', state='in_review', stage={'name': 'security', 'agent': 'x'})
    assert started.kind == 'done' and 12 not in b.state.active
    assert b.calls[-3] == ('board-move.sh', '12', 'review_security') or \
        ('board-move.sh', '12', 'review_security') in b.calls, b.calls
    assert b.card()['state'] == 'review_security'
    note = b.note()
    assert note['stage'] == 'security' and note['round'] == 1 and note['reviewed_stages'] == [], note
    assert note['state'] == 'review_security' and note['action_failures'] == 0
    b.put_note({'last_action_error': 'old', 'action_failures': 1})
    begin(b, 'advance_stage', state='review_security', stage={'name': 'perf'})
    note = b.note()
    assert b.card()['state'] == 'review_perf' and note['stage'] == 'perf', note
    assert note['reviewed_stages'] == ['security'] and note['action_failures'] == 0, note
    assert note['last_action_error'] is None


def test_advance_stage_rejects_an_unknown_stage(base):
    b = board_for(base, 'in_review')
    assert begin(b, 'advance_stage', state='in_review', stage={'name': 'nosuch'}).kind == 'done'
    assert 'board-move.sh' not in b.scripts_called()
    assert b.note()['last_action_error'] == 'invalid state: review_nosuch'


def test_update_branch_runs_worktree_then_script(base):
    b = board_for(base, 'in_review')
    b.put_note({'action_failures': 2, 'last_action_error': 'older'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    b.stubs['update-branch.sh'] = ok()
    assert begin(b, 'update_branch', state='in_review').kind == 'done'
    assert b.scripts_called() == ['worktree.sh', 'update-branch.sh'], b.calls
    assert ('update-branch.sh', '12', '34', BRANCH, b.worktree) in b.calls
    note = b.note()
    assert note['action_failures'] == 0 and note['last_action_error'] is None
    assert b.card()['state'] == 'in_review'


def test_update_branch_conflict_counts_once_and_never_blocks(base):
    b = board_for(base, 'in_review')
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    b.stubs['update-branch.sh'] = fail_with('merge of origin/main into fleet/12 conflicts\n')
    assert begin(b, 'update_branch', state='in_review').kind == 'done'
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'].startswith('merge of origin/main')
    assert b.card()['state'] == 'in_review' and 'board-move.sh' not in b.scripts_called()


LAST = {'round': 1, 'sha': 'abc', 'critical': 1, 'important': 1,
        'findings': [{'severity': 'Critical', 'text': 'crashes'}, {'severity': 'Minor', 'text': 'nit'},
                     {'severity': 'Important', 'text': 'leaks'}]}


def test_block_lists_surviving_findings(base):
    b = board_for(base, 'in_review')
    b.put_note({'last_review': LAST})
    assert begin(b, 'block', state='in_review', reason='2 findings survive round 3 of 3').kind == 'done'
    assert b.card()['state'] == 'blocked'
    note = b.note()
    assert note['blocked_from'] == 'in_review' and note['state'] == 'blocked', note
    assert note['blocked_findings'] == [{'severity': 'Critical', 'text': 'crashes'},
                                        {'severity': 'Important', 'text': 'leaks'}], note
    (comment,) = b.comments()
    assert '[Critical] crashes' in comment and '[Important] leaks' in comment and 'nit' not in comment, comment
    assert b.scripts_called() == ['board-move.sh', 'board-comment.sh'], b.calls


def test_block_without_findings_uses_the_plan_reason(base):
    b = board_for(base, 'in_progress')
    begin(b, 'block', state='in_progress', reason='implementor produced no PR after 3 attempts')
    note = b.note()
    assert note['blocked_from'] == 'in_progress'
    assert note['blocked_findings'] == [{'severity': 'Important', 'text': 'implementor produced no PR after 3 attempts'}]
    assert 'implementor produced no PR after 3 attempts' in b.comments()[0]


def test_block_for_action_failures_clears_blocking_pr_first(base):
    b = board_for(base, 'review_security')
    b.put_note({'action_failures': 3, 'last_action_error': 'worktree is busy', 'blocking_pr': 9, 'last_review': LAST})
    reason = 'no progress after 3 attempts: worktree is busy'
    assert begin(b, 'block', state='review_security', reason=reason).kind == 'done'
    merges = [c for c in b.calls if c[0] in ('note.sh', 'board-move.sh', 'board-comment.sh')
              and (c[0] != 'note.sh' or c[1] == 'merge')]
    assert [c[0] for c in merges] == ['note.sh', 'board-move.sh', 'note.sh', 'board-comment.sh'], b.calls
    note = b.note()
    assert note['blocking_pr'] is None and note['blocked_from'] == 'review_security', note
    assert note['blocked_findings'] == [{'severity': 'Important', 'text': reason}], note
    assert note['action_failures'] == 0 and note['last_action_error'] is None and note['state'] == 'blocked'
    comment = b.comments()[0]
    assert 'worktree is busy' in comment and '3' in comment and 'move the card back' in comment, comment


def test_block_for_action_failures_stops_when_the_first_merge_fails(base):
    b = board_for(base, 'in_progress')
    b.put_note({'action_failures': 3})
    real = b.run

    def run(root, name, *args, **kw):
        if name == 'note.sh' and args[0] == 'merge' and 'blocking_pr' in Path(args[2]).read_text():
            b.calls.append((name,) + tuple(str(a) for a in args))
            return fail_with('refusing to merge into the invalid manager note\n')
        return real(root, name, *args, **kw)
    b.driver.run = run
    begin(b, 'block', state='in_progress', reason='no progress after 3 attempts: x')
    assert b.card()['state'] == 'in_progress' and 'board-move.sh' not in b.scripts_called()
    assert b.note()['action_failures'] == 4


def test_to_human_qa_moves_before_the_handoff_and_passes_the_summary(base):
    cfg = {'board': {'repo': 'acme/toy'}, 'commands': {'qa_build': 'echo building; exit 3'}}
    b = board_for(base, 'in_review', config=cfg)
    seen = {}

    def handoff(*args):
        assert b.card()['state'] == 'human_qa', 'the move must come first'
        seen['args'] = tuple(str(a) for a in args)
        seen['summary'] = Path(str(args[1])).read_text()
        return ok()
    b.stubs['human-qa-handoff.sh'] = handoff
    Path(b.worktree).mkdir(parents=True)
    assert begin(b, 'to_human_qa', state='in_review').kind == 'done'
    assert seen['args'][0] == '--qa-summary' and seen['args'][2:] == ('12', '34'), seen
    assert 'exit 3' in seen['summary'] and 'building' in seen['summary'] and '```' in seen['summary'], seen
    note = b.note()
    assert note['state'] == 'human_qa' and note['action_failures'] == 0, note


def test_to_human_qa_without_qa_build_and_failed_handoff_still_progresses(base):
    b = board_for(base, 'in_review')
    b.stubs['human-qa-handoff.sh'] = fail_with('cannot post\n')
    assert begin(b, 'to_human_qa', state='in_review').kind == 'done'
    assert b.calls[0] == ('board-move.sh', '12', 'human_qa')
    assert [c for c in b.calls if c[0] == 'human-qa-handoff.sh'][0][-2:] == ('12', '34'), b.calls
    assert b.card()['state'] == 'human_qa' and b.note()['action_failures'] == 0
    assert [e for e in b.state.events if e['type'] == 'warning']


def test_to_human_qa_failed_move_counts_and_posts_nothing(base):
    b = board_for(base, 'in_review')
    b.stubs['board-move.sh'] = fail_with('cannot move\n')
    begin(b, 'to_human_qa', state='in_review')
    assert 'human-qa-handoff.sh' not in b.scripts_called()
    assert b.note()['last_action_error'] == 'cannot move'


def test_mark_ready_runs_gh_and_counts_failures(base):
    b = board_for(base, 'in_review')
    assert begin(b, 'mark_ready', state='in_review').kind == 'done'
    assert b.gh_calls == [('pr', 'ready', '34', '--repo', 'acme/toy')], b.gh_calls
    b.gh_result = fail_with('GraphQL: not allowed\nmore\n')
    begin(b, 'mark_ready', state='in_review')
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'GraphQL: not allowed'


GOOD = {'commit': 'abc1234', 'ok': True, 'results': []}


def test_verify_main_records_main_check(base):
    b = board_for(base, 'in_review')
    b.stubs['verify-main.sh'] = ok(json.dumps(GOOD))
    assert begin(b, 'verify_main', state='in_review').kind == 'done'
    assert b.calls[0] == ('verify-main.sh', '12', '34')
    assert b.note()['main_check'] == GOOD and b.note()['action_failures'] == 0
    assert b.state.mode == 'running'


def test_verify_main_failure_pauses_the_board(base):
    red = {'commit': 'bad1', 'ok': False, 'results': [], 'p0_card': 77}
    cases = [
        (ok(json.dumps(red)), 'bad1'),
        (fail_with('could not verify\n'), 'could not verify'),
        (ok('not json'), 'malformed'),
        (ok(json.dumps({'commit': '', 'ok': True, 'results': []})), 'malformed'),
        (ok(json.dumps({'commit': 'a', 'ok': 'yes', 'results': []})), 'malformed'),
        (ok(json.dumps({'commit': 'a', 'ok': True, 'results': {}})), 'malformed'),
    ]
    for i, (result, fragment) in enumerate(cases):
        sub = Path(base) / str(i)
        sub.mkdir()
        b = board_for(sub, 'in_review')
        b.stubs['verify-main.sh'] = result
        assert begin(b, 'verify_main', state='in_review').kind == 'done'
        assert b.state.mode == 'paused', i
        assert b.state.pause_reason.startswith('main verification failed for #12: '), b.state.pause_reason
        assert fragment in b.state.pause_reason, (i, b.state.pause_reason)
        assert b.card()['state'] == 'in_review'
        assert b.note()['action_failures'] == 1, i
        if i == 0:
            assert b.note()['main_check'] == red and '#77' in b.state.pause_reason, b.state.pause_reason


def test_finish_without_after_merge_marks_done(base):
    b = board_for(base, 'in_review', body='plain body')
    assert begin(b, 'finish', state='in_review').kind == 'done'
    assert b.scripts_called() == ['board-read.sh', 'board-move.sh'], b.calls
    assert b.card()['state'] == 'done'
    note = b.note()
    assert note['state'] == 'done' and note['action_failures'] == 0


def test_finish_runs_after_merge_and_records_results(base):
    b = board_for(base, 'in_review', body='intro\n\n## After merge\n\n- `make deploy`\n')
    captured = {}

    def after(*args):
        captured['args'] = args[0]
        captured['body'] = Path(str(args[1])).read_text()
        return ok(json.dumps({'outcome': 'done', 'results': [{'command': 'make deploy', 'status': 'ok', 'exit': 0}],
                              'note': ['make deploy: exit 0'], 'comment': ''}))
    b.stubs['after-merge.sh'] = after
    begin(b, 'finish', state='in_review')
    assert captured['args'] == 'run' and captured['body'].startswith('intro')
    assert b.card()['state'] == 'done'
    assert b.note()['after_merge_results'] == [{'command': 'make deploy', 'exit': 0}]


def test_finish_blocked_after_merge_posts_the_comment(base):
    b = board_for(base, 'in_review', body='## After merge\n\n- `rm -rf x`\n')
    b.stubs['after-merge.sh'] = ok(json.dumps({'outcome': 'blocked', 'results': [
        {'command': 'rm -rf x', 'status': 'refused', 'exit': 126}], 'note': ['x'],
        'comment': 'after-merge: rm is not on the allowlist'}))
    begin(b, 'finish', state='in_review')
    assert b.card()['state'] == 'blocked' and b.note()['blocked_from'] == 'in_review'
    assert b.comments() == ['after-merge: rm is not on the allowlist']


def test_finish_of_a_merging_card_blocks_from_merging(base):
    b = board_for(base, 'merging', body='## After merge\n\n- `rm -rf x`\n')
    b.stubs['after-merge.sh'] = ok(json.dumps({'outcome': 'blocked', 'results': [
        {'command': 'rm -rf x', 'status': 'refused', 'exit': 126}], 'note': ['x'],
        'comment': 'after-merge: rm is not on the allowlist'}))
    begin(b, 'finish', state='merging')
    assert b.card()['state'] == 'blocked' and b.note()['blocked_from'] == 'merging', b.note()


def test_finish_after_the_merger_ran_does_not_rerun_after_merge(base):
    b = board_for(base, 'merging', body='## After merge\n\n- `make deploy`\n')
    b.put_note({'merger': {'mode': 'after_merge', 'status': 'done', 'head': 'abc1234'}})
    b.stubs['after-merge.sh'] = lambda *a: (_ for _ in ()).throw(AssertionError('after-merge.sh ran twice'))
    begin(b, 'finish', state='merging')
    assert b.card()['state'] == 'done', b.calls
    assert 'after-merge.sh' not in b.scripts_called()


def test_unblock_resets_the_blocking_fields(base):
    b = board_for(base, 'blocked')
    b.put_note({'blocking_pr': 9, 'blocked_from': 'in_review',
                'blocked_findings': [{'severity': 'Important', 'text': 'x'}],
                'action_failures': 1, 'last_action_error': 'e'})
    assert begin(b, 'unblock', state='blocked').kind == 'done'
    assert b.card()['state'] == 'ready'
    note = b.note()
    assert note['blocking_pr'] is None and note['blocked_from'] is None and note['blocked_findings'] is None, note
    assert note['action_failures'] == 0 and note['last_action_error'] is None and note['state'] == 'ready'


PENDING = {'out_of_scope': [{'title': 'Docs', 'detail': 'd'}, {'title': 'Cache', 'detail': 'c'}],
           'bugs': [{'title': 'Crash', 'repro': 'r', 'expected': 'e', 'observed': 'o'}], 'pr': None}


def test_file_pending_success_clears_pending(base):
    b = board_for(base, 'in_review')
    b.put_note({'pending_followups': PENDING, 'pr': 35})
    filed = {}

    def files(*args):
        filed['args'] = tuple(str(a) for a in args[:2])
        filed['json'] = json.loads(Path(str(args[2])).read_text())
        return ok(json.dumps({'out_of_scope_created': [{'title': 'Docs', 'number': 5, 'existing': False},
                                                       {'title': 'Cache', 'number': 6, 'existing': False}],
                              'bugs_filed': [{'title': 'Crash', 'number': 7, 'existing': False}]}))
    b.stubs['file-followups.sh'] = files
    assert begin(b, 'file_pending', state='in_review').kind == 'done'
    assert filed['args'] == ('12', '35'), filed
    assert filed['json']['bugs'][0]['title'] == 'Crash'
    note = b.note()
    assert note['pending_followups'] is None and [x['number'] for x in note['out_of_scope_created']] == [5, 6]
    assert [x['number'] for x in note['bugs_filed']] == [7] and note['action_failures'] == 0, note


def test_file_pending_partial_keeps_the_rest_and_counts(base):
    b = board_for(base, 'in_review')
    b.put_note({'pending_followups': PENDING, 'pr': 35})
    b.stubs['file-followups.sh'] = scripts.ScriptResult(1, json.dumps(
        {'out_of_scope_created': [{'title': 'docs', 'number': 5, 'existing': False}], 'bugs_filed': []}),
        'one failed\n', False)
    begin(b, 'file_pending', state='in_review')
    note = b.note()
    assert [x['title'] for x in note['pending_followups']['out_of_scope']] == ['Cache'], note
    assert note['pending_followups']['bugs'][0]['title'] == 'Crash' and note['pending_followups']['pr'] == 35
    assert note['out_of_scope_created'][0]['number'] == 5
    assert note['action_failures'] == 1 and note['last_action_error'] == 'one failed'


def test_file_pending_total_failure_counts_only(base):
    b = board_for(base, 'in_review')
    b.put_note({'pending_followups': PENDING, 'pr': 35})
    b.stubs['file-followups.sh'] = fail_with('nothing filed\n')
    begin(b, 'file_pending', state='in_review')
    note = b.note()
    assert note['pending_followups']['out_of_scope'] == PENDING['out_of_scope'] and note['action_failures'] == 1


def test_file_pending_without_any_pr_runs_nothing(base):
    b = board_for(base, 'in_review')
    b.put_note({'pending_followups': PENDING})
    assert begin(b, 'file_pending', state='in_review', pr=None).kind == 'done'
    assert 'file-followups.sh' not in b.scripts_called()
    assert b.note()['action_failures'] == 0


def test_skip_no_acceptance_comments_only_when_needed(base):
    b = board_for(base, 'ready', acceptance=())
    assert begin(b, 'skip_no_acceptance', comment_needed=False).kind == 'done'
    assert b.comments() == []
    begin(b, 'skip_no_acceptance', comment_needed=True)
    (comment,) = b.comments()
    assert comment.startswith('<!-- fleet-board:skip-no-acceptance -->') and 'acceptance' in comment, comment


def test_skip_card_lint_uses_the_marker_and_lists_the_lines(base):
    b = board_for(base, 'ready')
    marker = '<!-- fleet-board:card-lint:abc123 -->'
    lint = ['acceptance-vague: item 1 has no verb', 'title-long: 90 characters']
    begin(b, 'skip_card_lint', comment_needed=True, lint=lint, lint_marker=marker)
    (comment,) = b.comments()
    assert comment.startswith(marker + '\n') and all(line in comment for line in lint), comment
    assert 'Ready' in comment
    begin(b, 'skip_card_lint', comment_needed=False, lint=lint, lint_marker=marker)
    assert len(b.comments()) == 1


def test_wait_comments_once_per_dependency_list(base):
    b = board_for(base, 'ready')
    deps = ['acme/toy#3', 'acme/toy#4']
    assert begin(b, 'wait', waiting_on=deps).kind == 'done'
    assert b.comments() == ['Waiting for acme/toy#3, acme/toy#4']
    assert b.note()['deps_commented'] == deps and b.note()['action_failures'] == 0
    begin(b, 'wait', waiting_on=deps)
    assert len(b.comments()) == 1
    begin(b, 'wait', waiting_on=['acme/toy#4'])
    assert b.comments()[-1] == 'Waiting for acme/toy#4' and len(b.comments()) == 2
    sub = Path(base) / 'other'
    sub.mkdir()
    c = board_for(sub, 'in_review')
    begin(c, 'wait', state='in_review', waiting_on=None)
    assert c.comments() == [] and c.scripts_called() == []


def test_skip_does_nothing(base):
    b = board_for(base)
    assert begin(b, 'skip').kind == 'done' and b.calls == [] and b.gh_calls == []


def test_invalid_values_never_reach_a_script(base):
    bad = [('branch', {'branch': 'main'}), ('branch', {'branch': 'fleet/12-x; rm -rf'}),
           ('branch', {'branch': '-fleet/1-x'}), ('worktree', {'worktree': 'relative/path'}),
           ('worktree', {'worktree': '-/abs'}), ('pr', {'pr': 0}), ('pr', {'pr': '34'}), ('pr', {'pr': True})]
    for i, (field, kw) in enumerate(bad):
        sub = Path(base) / ('c%d' % i)
        sub.mkdir()
        b = board_for(sub, 'in_progress')
        b.stubs['worktree.sh'] = ok()
        b.stubs['review-stages.sh'] = ok('[]')
        row = candidate('update_branch', state='in_progress', worktree=b.worktree)
        row.update(kw)
        assert b.driver.begin(row).kind == 'done'
        note = b.note()
        assert note['last_action_error'].startswith('invalid %s: ' % field), (kw, note)
        assert note['action_failures'] == 1
        assert b.scripts_called() == [], (kw, b.calls)
    sub = Path(base) / 'state'
    sub.mkdir()
    b = board_for(sub, 'in_review')
    begin(b, 'block', state='bogus', reason='r')
    assert b.note()['last_action_error'] == 'invalid state: bogus'
    assert 'board-move.sh' not in b.scripts_called()
    sub = Path(base) / 'pr'
    sub.mkdir()
    b = board_for(sub, 'in_review')
    begin(b, 'mark_ready', state='in_review', pr=-4)
    assert b.gh_calls == [] and b.note()['last_action_error'] == 'invalid pr: -4'
    sub = Path(base) / 'number'
    sub.mkdir()
    b = board_for(sub, 'in_review')
    row = candidate('mark_ready', number=0, worktree=b.worktree)
    assert b.driver.begin(row).kind == 'done' and b.gh_calls == [] and b.calls == []


def test_begin_refuses_merge_and_unknown_actions(base):
    b = board_for(base)
    for action, message in (('merge', 'merge is handled by the merge lane'), ('rm_rf', None), (None, None)):
        try:
            begin(b, action)
        except ValueError as exc:
            if message:
                assert str(exc) == message, exc
            continue
        raise AssertionError('begin accepted ' + repr(action))
    assert b.calls == [] and 12 not in b.state.active
    assert 'skip' in driver.SCRIPT_ACTIONS and 'merge' not in driver.SCRIPT_ACTIONS
    assert driver.SCRIPT_ACTIONS.isdisjoint(driver.ROLE_ACTIONS)
    assert {'start', 'start_review', 'fix', 'review', 'after_merge', 'merge_refusal'} <= set(driver.ROLE_ACTIONS)


def test_a_busy_card_is_refused(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = ok()
    begin(b, 'start')
    try:
        begin(b, 'skip')
    except ValueError:
        return
    raise AssertionError('a card with an active action must be refused')


# --- role dispatch and reconciliation (task 2.7) -------------------------------------------------------

def started_implementor(b, report='implementor-ok', **kw):
    b.plans({'report': report}, *kw.get('more', ()))
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    assert started.kind == 'session' and started.action.session is not None
    return started


def test_implementor_done_records_pr(base):
    b = board_for(base)
    started = started_implementor(b)
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, True, False, None), outcome
    assert 12 not in b.state.active
    note = b.note()
    assert note['pr'] == 12 and note['last_verified'] == "VERIFIED: `node --test test/calc.test.js` -> 3 passing tests"
    assert note['action_failures'] == 0 and note['last_action_error'] is None, note
    call = b.fake_calls()[0]
    assert call['cwd'] == str(b.root) and '--model' in call['argv'] and 'sonnet' in call['argv'], call
    prompt = b.prompt()
    for want in ('Add subtract', 'does it', b.worktree, BRANCH, '12'):
        assert want in prompt, (want, prompt)
    assert any('## Status' in c for c in b.comments()), 'the fake role posted its report'


def test_continue_implementor_counts_the_attempt_first(base):
    b = board_for(base, 'in_progress')
    b.put_note({'implementor_attempts': 1, 'branch': BRANCH, 'worktree': b.worktree, 'round': 0})
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'continue_implementor', state='in_progress')
    assert started.kind == 'session' and started.action.role == 'implementor'
    assert b.note()['implementor_attempts'] == 2
    assert b.scripts_called() == ['worktree.sh', 'board-read.sh'], b.calls
    assert [c[:2] for c in b.calls if c[0] == 'note.sh'][:2] == [('note.sh', 'get'), ('note.sh', 'merge')], b.calls
    assert [i for i, c in enumerate(b.calls) if c[:2] == ('note.sh', 'merge')][0] < b.calls.index(
        [c for c in b.calls if c[0] == 'worktree.sh'][0]), 'the attempt is counted before worktree.sh create'
    assert '"implementor_attempts": 2' in b.prompt(), b.prompt()
    assert run_role(b, started).progressed is True


def test_reviewer_findings_record_last_review(base):
    b = board_for(base, 'in_review')
    b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree})
    worktree_ok(b)
    b.gh_result = ok('diff --git a/x b/x\n+line\n')
    b.plans({'report': 'reviewer-findings'})
    started = begin(b, 'review', state='in_review', round=1)
    assert started.kind == 'session' and started.action.role == 'reviewer'
    assert ('worktree.sh', 'review', '12', '34') in b.calls
    assert b.gh_calls[0][:3] == ('pr', 'diff', '34') and '--repo' in b.gh_calls[0], b.gh_calls
    prompt = b.prompt()
    assert '+line' in prompt and 'bace000' in prompt and b.worktree in prompt, prompt
    outcome = run_role(b, started)
    assert outcome.progressed is True and outcome.redispatch is False, outcome
    review = b.note()['last_review']
    assert review == {'round': 1, 'sha': 'abc1234', 'critical': 0, 'important': 1, 'stage': None, 'agent': None,
                      'model': None, 'provider': None,
                      'findings': [{'severity': 'Important', 'text': 'subtract(2, 5) returns -3 is unmapped'}]}, review
    assert b.note()['last_verified'].startswith('VERIFIED:')


def test_reviewer_round_one_uses_the_base_even_after_an_earlier_review(base):
    # Retargeted from the manager agent's review row (test-weakened-test-scope.sh, test-weakened-test-examples.sh):
    # in round 1 prev_sha is the base from worktree.sh review, never note.last_review.sha.
    b = board_for(base, 'in_review')
    b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree,
                'last_review': dict(LAST_REVIEW, sha='feed123')})
    worktree_ok(b)
    b.gh_result = ok('diff --git a/x b/x\n+line\n')
    b.plans({'report': 'reviewer-ok'})
    begin(b, 'review', state='in_review', round=1)
    prompt = b.prompt()
    assert 'bace000' in prompt and 'feed123' not in prompt, prompt


def test_reviewer_round_two_gets_prev_sha_and_findings_and_a_long_diff_goes_to_a_file(base):
    b = board_for(base, 'in_review')
    b.put_note({'round': 2, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree,
                'last_review': dict(LAST_REVIEW, sha='feed123')})
    worktree_ok(b)
    b.gh_result = ok('\n'.join('+row %d' % i for i in range(1600)) + '\n')
    b.plans({'report': 'reviewer-ok'})
    started = begin(b, 'review', state='in_review', round=2)
    prompt = b.prompt()
    assert 'feed123' in prompt and 'bace000' not in prompt, prompt
    assert '- [Important] no test' in prompt, prompt
    assert '+row 1599' not in prompt and '+row 0' not in prompt, 'a long diff is passed as a path'
    path = [w for w in prompt.split() if w.endswith('.diff')]
    assert path, prompt
    assert run_role(b, started).progressed is True
    assert b.note()['last_review']['round'] == 2 and b.note()['last_review']['important'] == 0


def test_role_prompt_sections_and_diff_file(base):
    text = driver.role_prompt('reviewer', {'number': 12, 'body': 'B', 'diff': 'a\nb', 'round': 1, 'config': {'a': 1}})
    assert '## Card number\n12' in text and '## PR diff\na\nb' in text and '"a": 1' in text, text
    long_diff = '\n'.join('x%d' % i for i in range(1501))
    text = driver.role_prompt('reviewer', {'number': 1, 'diff': long_diff}, tmp=base)
    assert 'x1500' not in text and base in text, text
    try:
        driver.role_prompt('manager', {})
    except ValueError:
        return
    raise AssertionError('an unknown role must be refused')


def test_rejected_report_redispatches_once_with_the_rule_text(base):
    b = board_for(base)
    started = started_implementor(b, 'no-verified', more=[{'report': 'implementor-ok'}])
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, False, True, None), outcome
    assert b.state.active[12] is started.action and started.action.session is not None
    assert b.note()['pr'] is None and b.note()['action_failures'] == 0
    run_role(b, started)
    prompt = b.prompt(2)
    assert prompt.startswith(b.prompt(1)), 'same inputs'
    assert 'Your previous report was rejected by the manager: parse-report: expected exactly one VERIFIED: line, ' \
           'found 0' in prompt, prompt
    assert 'There is exactly one `VERIFIED:` line.' in prompt, prompt
    assert 'The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of ' \
           'the form VERIFIED:' in prompt, prompt
    assert [c['argv'][c['argv'].index('--agent') + 1] for c in b.fake_calls()] == ['fleet-board:implementor'] * 2


def test_redispatch_is_declined_when_the_caller_says_so(base):
    b = board_for(base)
    started = started_implementor(b, 'no-verified')
    outcome = b.driver.finish(started.action, wait_for(started), allow_redispatch=False)
    assert outcome.redispatch is False and outcome.progressed is False and 12 not in b.state.active
    assert b.note()['action_failures'] == 1 and 'rejected' in b.note()['last_action_error']


def test_rules_match_the_reporting_skill_table_cell_for_cell(base):
    # The driver's _RULES are the re-dispatch source (the retired manager agent's rule table is gone). Each row
    # of the reporting skill's rejection table is a (message, rule) pair in _RULES, in the same order, with the
    # same text. Only the rows below differ on purpose: the driver words their rules more briefly, so for them
    # only the message is compared.
    import re
    briefer = {'role <role> requires ## <section>', 'out of scope entry needs <title> :: <detail>: <entry>'}
    # A rule the driver adds after the table: parse-report.sh emits it, the skill's table does not list it.
    driver_only = ['status not_reproducible needs no commits since the reviewed head, found <n>']
    lines = (PLUGIN / 'skills' / 'reporting' / 'SKILL.md').read_text().splitlines()
    start = [i for i, l in enumerate(lines) if l.startswith('| Rejection message')][0]
    rows = []
    for line in lines[start + 2:]:
        if not line.startswith('|'):
            break
        cells = [c.strip().replace('\\|', '|') for c in re.split(r'(?<!\\)\|', line)[1:-1]]
        rows.append((cells[0][1:-1] if cells[0].startswith('`') and cells[0].endswith('`') else cells[0], cells[1]))
    ours = list(driver._RULES)
    assert [m for m, _ in ours[len(rows):]] == driver_only, 'driver-only rows drifted: %r' % ours[len(rows):]
    ours = ours[:len(rows)]
    assert rows and len(ours) == len(rows), 'row count drifted: skill %d, driver %d' % (len(rows), len(ours))
    assert briefer <= {m for m, _ in rows}, 'an exception row is gone from the skill: %r' % briefer
    for (message, rule), (our_message, our_rule) in zip(rows, ours):
        assert our_message == message, 'message drifted: %r != %r' % (our_message, message)
        if message in briefer:
            assert our_rule and our_rule != rule, 'exception row now matches; drop it from the list: %r' % message
        else:
            assert our_rule == rule, 'rule text drifted for %r:\n driver %r\n skill  %r' % (message, our_rule, rule)
    text = driver.rejection_text(['parse-report: expected exactly one VERIFIED: line, found 2'])
    assert '..' not in text.replace('...', ''), text
    assert 'found 2\nThere is exactly one `VERIFIED:` line.\nThe rule: every report' in text, text


def test_second_rejection_without_redispatch_budget_still_records_report_errors(base):
    b = board_for(base)
    started = started_implementor(b, 'no-verified', more=[{'report': 'no-verified'}])
    assert run_role(b, started).redispatch is True
    outcome = b.driver.finish(started.action, wait_for(started), allow_redispatch=False)
    assert outcome == driver.Outcome(12, False, False, None), outcome
    note = b.note()
    assert len(note['report_errors']) == 1 and note['report_errors'][0]['role'] == 'implementor', note
    assert note['last_action_error'] == ('implementor report rejected twice: '
                                         'parse-report: expected exactly one VERIFIED: line, found 0'), note
    assert note['action_failures'] == 1
    assert len([e for e in b.state.events if e['type'] == 'action_failed']) == 1, list(b.state.events)


def test_declined_redispatch_logs_one_failure(base):
    b = board_for(base)
    started = started_implementor(b, 'no-verified')
    b.driver.finish(started.action, wait_for(started), allow_redispatch=False)
    assert len([e for e in b.state.events if e['type'] == 'action_failed']) == 1, list(b.state.events)


def test_second_rejection_records_report_errors(base):
    b = board_for(base)
    started = started_implementor(b, 'no-verified', more=[{'report': 'no-verified'}])
    assert run_role(b, started).redispatch is True
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, False, False, None), outcome
    assert 12 not in b.state.active and len(b.fake_calls()) == 2
    note = b.note()
    assert len(note['report_errors']) == 1, note
    entry = note['report_errors'][0]
    assert entry['role'] == 'implementor' and entry['round'] == 0 and entry['at'], entry
    assert entry['errors'] == ['parse-report: expected exactly one VERIFIED: line, found 0'], entry
    assert note['action_failures'] == 1
    assert note['last_action_error'] == ('implementor report rejected twice: '
                                         'parse-report: expected exactly one VERIFIED: line, found 0'), note
    assert note['pr'] is None and note['last_verified'] is None


def seed_fix(b, **note):
    b.put_note(dict({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree,
                     'last_review': LAST_REVIEW}, **note))
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')


def test_fix_done_increments_round(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.plans({'report': 'fixer-ok'})
    started = begin(b, 'fix', state='in_review', escalated=True, round=1)
    assert started.kind == 'session' and started.action.role == 'fixer'
    assert b.note()['branch'] == BRANCH and ('worktree.sh', 'create') == [c for c in b.calls
                                                                          if c[0] == 'worktree.sh'][-1][:2], b.calls
    assert b.calls[0][:2] == ('note.sh', 'merge'), 'branch and worktree are noted before worktree.sh create'
    assert '- [Important] no test' in b.prompt()
    assert run_role(b, started) == driver.Outcome(12, True, False, None)
    note = b.note()
    assert note['round'] == 2 and note['escalated'] is True and note['escalated_at_round'] == 2, note
    assert note['models']['fixer'] == 'sonnet' and note['action_failures'] == 0, note
    assert note['last_review']['sha'] == 'abc1234', 'review is preserved for the next round'
    assert note['last_verified'].startswith('VERIFIED:')


def test_fix_blocked_with_blocked_by_moves_to_blocked(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.plans({'report': 'fixer-blocked-by'})
    started = begin(b, 'fix', state='in_review')
    outcome = run_role(b, started)
    assert outcome.progressed is True
    note = b.note()
    assert b.card()['state'] == 'blocked' and note['state'] == 'blocked', note
    assert note['blocking_pr'] == 41 and note['blocked_from'] == 'in_review' and note['round'] == 1, note


def test_fix_blocked_without_blocked_by_lists_the_findings(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.plans({'report': 'fixer-blocked-by'})
    report = (PLUGIN / 'fixtures' / 'reports' / 'fixer-blocked-by.md').read_text().replace('Blocked by: #41\n', '')
    b.plans({'report': report})
    outcome = run_role(b, begin(b, 'fix', state='in_review'))
    assert outcome.progressed is True
    note = b.note()
    assert b.card()['state'] == 'blocked' and note['blocking_pr'] is None, note
    assert [f['severity'] for f in note['blocked_findings']] == ['Important'], note
    assert any('Blocked' in c for c in b.comments())


def conflict_board(base, state_name='in_review'):
    b = board_for(base, state_name)
    b.put_note({'round': 2, 'pr': 34, 'state': state_name, 'branch': BRANCH, 'worktree': b.worktree,
                'conflicted_files': ['a.py'], 'last_review': LAST_REVIEW, 'stage': 'security',
                'reviewed_stages': ['perf'], 'action_failures': 1, 'last_action_error': 'old'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    b.stubs['review-stages.sh'] = ok('[]')
    b.gh_result = ok('abc1234\n')
    return b


def test_conflict_fix_resets_review(base):
    b = conflict_board(base)
    b.plans({'report': 'fixer-ok'})
    findings = [{'severity': 'Important', 'text': 'merge conflict in a.py'}]
    started = begin(b, 'fix', state='in_review', findings=findings)
    assert '- [Important] merge conflict in a.py' in b.prompt()
    assert 'no test' not in b.prompt(), 'stale review findings are not passed to a conflict fixer'
    assert run_role(b, started) == driver.Outcome(12, True, False, None)
    assert [c[:2] for c in b.calls if c[0] in ('review-stages.sh', 'board-move.sh')] == \
        [('review-stages.sh', 'route'), ('board-move.sh', '12')], b.calls
    assert b.gh_calls[-1][:3] == ('pr', 'view', '34') and 'headRefOid' in b.gh_calls[-1]
    note = b.note()
    assert note['conflicted_files'] is None and note['last_review'] is None and note['round'] == 1, note
    assert note['stage'] is None and note['reviewed_stages'] == [] and note['state'] == 'in_review', note
    assert note['blocking_pr'] is None and note['blocked_from'] is None and note['blocked_findings'] == []
    assert note['action_failures'] == 0 and note['last_action_error'] is None, note
    assert b.card()['state'] == 'in_review'


def test_conflict_fix_refuses_an_unpushed_resolution(base):
    b = conflict_board(base)
    b.gh_result = ok('9999999\n')
    b.plans({'report': 'fixer-ok'})
    outcome = run_role(b, begin(b, 'fix', state='in_review',
                                findings=[{'severity': 'Important', 'text': 'merge conflict in a.py'}]))
    assert outcome.progressed is False
    note = b.note()
    assert note['conflicted_files'] == ['a.py'] and note['round'] == 2, note
    assert note['action_failures'] == 2 and 'push' in note['last_action_error'], note
    assert 'review-stages.sh' not in [c[0] for c in b.calls]


def test_conflict_fix_blocked_keeps_the_files_and_notes_before_the_move(base):
    b = conflict_board(base)
    b.plans({'report': 'fixer-blocked-by'})
    findings = [{'severity': 'Important', 'text': 'merge conflict in a.py'}]
    assert run_role(b, begin(b, 'fix', state='in_review', findings=findings)).progressed is True
    note = b.note()
    assert note['conflicted_files'] == ['a.py'] and b.card()['state'] == 'blocked', note
    assert note['blocked_from'] == 'in_review' and note['blocked_findings'] == findings, note
    assert note['blocking_pr'] == 41 and note['state'] == 'blocked' and note['action_failures'] == 0, note
    assert any('a.py' in c for c in b.comments())


def test_not_reproducible_records_last_fix(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.git_result = ok('0\n')
    b.plans({'report': 'fixer-not-reproducible'})
    outcome = run_role(b, begin(b, 'fix', state='in_review'))
    assert outcome.progressed is True
    note = b.note()
    assert note['last_fix'] == {'status': 'not_reproducible', 'round': 1}, note
    assert note['round'] == 1, 'no round increment'
    assert any('rev-list' in ' '.join(c) for c in b.git_calls), b.git_calls


def test_not_reproducible_is_rejected_when_the_fixer_committed(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.git_result = ok('3\n')
    b.plans({'report': 'fixer-not-reproducible'}, {'report': 'fixer-ok'})
    outcome = run_role(b, begin(b, 'fix', state='in_review'))
    assert outcome.redispatch is True and b.note().get('last_fix') is None


def test_provider_failure_does_not_charge_the_card(base):
    b = board_for(base)
    b.plans({'report': '', 'post': False, 'exit': 1, 'is_error': True, 'stderr': 'rate limit exceeded (429)'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, False, False, 'claude'), outcome
    note = b.note()
    assert note['action_failures'] == 0 and note['last_action_error'] is None, note
    assert 12 not in b.state.active
    assert b.card()['state'] == 'in_progress'


def test_card_failure_counts_no_progress_with_the_reason(base):
    b = board_for(base)
    b.plans({'report': 'implementor-ok', 'post': False, 'exit': 1})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, False, False, None), outcome
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'exit 1', note
    assert note['pr'] is None


def test_permission_mode_mismatch_counts_the_card(base):
    b = board_for(base)
    b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 30, 'permission_mode': 'default'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    result = wait_for(started)
    assert result.cancelled is False and result.reason == 'permission-mode-mismatch', result
    outcome = b.driver.finish(started.action, result)
    assert outcome == driver.Outcome(12, False, False, None), outcome
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'permission-mode-mismatch', note
    assert 12 not in b.state.active


def test_provider_failure_gives_back_the_implementor_attempt_on_start(base):
    b = board_for(base)
    b.plans({'report': '', 'post': False, 'exit': 1, 'is_error': True, 'stderr': 'rate limit exceeded (429)'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    assert b.note()['implementor_attempts'] == 1
    outcome = run_role(b, started)
    assert outcome.provider_failure == 'claude', outcome
    assert b.note()['implementor_attempts'] == 0, b.note()


def test_provider_failure_gives_back_the_implementor_attempt_on_continue(base):
    b = board_for(base, 'in_progress')
    b.put_note({'implementor_attempts': 2, 'branch': BRANCH, 'worktree': b.worktree, 'round': 0})
    b.plans({'report': '', 'post': False, 'exit': 1, 'is_error': True, 'stderr': 'rate limit exceeded (429)'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'continue_implementor', state='in_progress')
    assert b.note()['implementor_attempts'] == 3
    outcome = run_role(b, started)
    assert outcome.provider_failure == 'claude', outcome
    assert b.note()['implementor_attempts'] == 2, b.note()


def test_a_card_failure_keeps_the_implementor_attempt(base):
    b = board_for(base)
    b.plans({'report': 'implementor-ok', 'post': False, 'exit': 1})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    run_role(b, begin(b, 'start'))
    assert b.note()['implementor_attempts'] == 1 and b.note()['action_failures'] == 1, b.note()


def test_a_launch_that_raises_gives_back_the_implementor_attempt(base):
    import types
    b = board_for(base)
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')

    def boom(*a, **kw):
        raise RuntimeError('no session')
    b.driver.roles = types.SimpleNamespace(command=driver._roles.command, launch=boom, DEFAULT_KILL_GRACE=5.0)
    try:
        begin(b, 'start')
        raise AssertionError('begin should have raised')
    except RuntimeError:
        pass
    assert b.note()['implementor_attempts'] == 0, b.note()
    assert 12 not in b.state.active


def test_a_failing_tempdir_ends_the_action(base):
    b = board_for(base)
    original = driver.tempfile.mkdtemp

    def boom(*a, **kw):
        raise OSError('no space')
    driver.tempfile.mkdtemp = boom
    try:
        begin(b, 'start')
    except OSError:
        pass
    finally:
        driver.tempfile.mkdtemp = original
    assert 12 not in b.state.active, 'the action must end when the temp dir cannot be made'


def test_a_cancelled_session_counts_nothing(base):
    b = board_for(base)
    b.plans({'report': 'implementor-ok', 'sleep': 30})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    started.action.session.cancel(0.2)
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, False, False, None), outcome
    assert b.note()['action_failures'] == 0 and 12 not in b.state.active


def test_followups_are_filed(base):
    b = board_for(base)
    seen = {}

    def file_followups(*args):
        seen['args'] = tuple(str(a) for a in args)
        seen['file'] = json.loads(Path(str(args[2])).read_text())
        return ok(json.dumps({'out_of_scope_created': [{'title': 'Add multiply', 'number': 101, 'existing': False}],
                              'bugs_filed': [{'title': 'add drops a third argument', 'number': 102,
                                              'existing': False}]}))
    b.stubs['file-followups.sh'] = file_followups
    b.put_note({'pr': 34})
    started = started_implementor(b, 'with-oos-and-bugs')
    assert run_role(b, started).progressed is True
    assert seen['args'][:2] == ('12', '34'), seen
    assert [i['title'] for i in seen['file']['out_of_scope']] == ['Add multiply'], seen
    assert [i['title'] for i in seen['file']['bugs']] == ['add drops a third argument'], seen
    note = b.note()
    assert [e['number'] for e in note['out_of_scope_created']] == [101], note
    assert [e['number'] for e in note['bugs_filed']] == [102] and note['pending_followups'] is None, note


def test_followups_partly_filed_stay_pending_and_progress_stands(base):
    b = board_for(base)
    b.stubs['file-followups.sh'] = lambda *a: scripts.ScriptResult(
        1, json.dumps({'out_of_scope_created': [{'title': 'Add multiply', 'number': 101, 'existing': False}],
                       'bugs_filed': []}), 'boom\n', False)
    b.put_note({'pr': 34, 'pending_followups': {'out_of_scope': [{'title': 'Earlier', 'detail': 'd'}],
                                                'bugs': [], 'pr': 34}})
    started = started_implementor(b, 'with-oos-and-bugs')
    assert run_role(b, started).progressed is True
    note = b.note()
    assert [e['number'] for e in note['out_of_scope_created']] == [101], note
    pending = note['pending_followups']
    assert [i['title'] for i in pending['out_of_scope']] == ['Earlier'], pending
    assert [i['title'] for i in pending['bugs']] == ['add drops a third argument'] and pending['pr'] == 34
    assert [e for e in b.state.events if e['type'] == 'warning']


def fake_plugin(b, exit_code, stdout, stderr=''):
    plugin = Path(b.root).parent / 'plugin'
    (plugin / 'scripts').mkdir(parents=True, exist_ok=True)
    script = ('#!/bin/bash\nprintf \'%s\\n\' "$@" > "$FAKE_STAGE_DIR/args.txt"\nprev=""\n'
              'for a in "$@"; do [ "$prev" = --impl-report ] && cp "$a" "$FAKE_STAGE_DIR/impl.txt"; '
              'prev=$a; done\ncat "$FAKE_STAGE_DIR/stdout.json"\n'
              '[ -f "$FAKE_STAGE_DIR/stderr.txt" ] && cat "$FAKE_STAGE_DIR/stderr.txt" >&2\n'
              'exit "$(cat "$FAKE_STAGE_DIR/exit")"\n')
    for name in ('evidence-review.sh', 'stage-review.sh'):
        (plugin / 'scripts' / name).write_text(script)
    (b.fake / 'exit').write_text('%d\n' % exit_code)
    (b.fake / 'stdout.json').write_text(stdout)
    (b.fake / 'stderr.txt').write_text(stderr)
    b.driver.plugin_dir = plugin


def report_file(b, name):
    path = b.fake / 'report.md'
    path.write_text((PLUGIN / 'fixtures' / 'reports' / (name + '.md')).read_text())
    return str(path)


EVIDENCE_CONFIG = {'board': {'repo': 'acme/toy'}, 'commands': {},
                   'models': {'reviewer': {'provider': 'codex', 'model': 'gpt-5', 'timeout': 600}}}


def test_evidence_reviewer_path(base):
    b = board_for(base, 'in_review', config=EVIDENCE_CONFIG)
    b.put_note({'round': 2, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree,
                'last_review': dict(LAST_REVIEW, sha='feed123')})
    fake_plugin(b, 0, json.dumps({'status': 'posted', 'report_file': report_file(b, 'reviewer-ok'),
                                  'parsed': {}, 'provider': 'codex', 'model': 'gpt-5', 'sha': 'deadbee',
                                  'input_tokens': None, 'output_tokens': None, 'cost_usd': 0, 'attempts': 1}))
    started = begin(b, 'review', state='in_review', round=2)
    assert started.kind == 'session' and started.action.role == 'reviewer' and started.action.provider == 'codex'
    assert 'worktree.sh' not in b.scripts_called(), 'the evidence runner makes its own review worktree'
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, True, False, None), outcome
    args = (b.fake / 'args.txt').read_text().split('\n')
    assert args[:5] == ['12', '34', '--round', '2', '--impl-report'], args
    assert '--prev-sha' in args and args[args.index('--prev-sha') + 1] == 'feed123', args
    assert '--findings' in args, args
    review = b.note()['last_review']
    assert review['sha'] == 'deadbee' and review['provider'] == 'codex' and review['model'] == 'gpt-5', review
    assert review['stage'] is None and review['agent'] is None and review['important'] == 0, review
    assert b.note()['models']['reviewer'] == 'opus', b.note()
    assert b.fake_calls() == [], 'no claude session'


def test_evidence_reviewer_exit_6_appends_report_errors_without_a_rerun(base):
    b = board_for(base, 'in_review', config=EVIDENCE_CONFIG)
    b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree})
    fake_plugin(b, 6, '', 'parse-report: missing section: ## Status\nevidence-review: rejected twice\n')
    outcome = run_role(b, begin(b, 'review', state='in_review', round=1))
    assert outcome == driver.Outcome(12, False, False, None), outcome
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'evidence-review: rejected twice', note
    assert note['report_errors'][0]['role'] == 'reviewer' and note['report_errors'][0]['round'] == 1
    assert note['report_errors'][0]['errors'] == ['parse-report: missing section: ## Status',
                                                  'evidence-review: rejected twice'], note
    assert (b.fake / 'args.txt').exists() and 12 not in b.state.active


def provider_stage_board(base, exit_code, stdout, stderr=''):
    stage = {'name': 'security', 'provider': 'codex', 'model': 'gpt-5', 'agent': None}
    b = board_for(base, 'review_security')
    b.put_note({'round': 1, 'pr': 34, 'state': 'review_security', 'stage': 'security', 'branch': BRANCH,
                'worktree': b.worktree, 'last_review': LAST_REVIEW})
    b.gh_result = ok('abc1234\n')
    fake_plugin(b, exit_code, stdout, stderr)
    return b, stage


def test_provider_stage_exit_7_blocks(base):
    b, stage = provider_stage_board(base, 7, '', 'stage-review: diff exceeds max_diff_bytes\n')
    started = begin(b, 'review_stage', state='review_security', stage=stage, round=1)
    assert started.kind == 'session' and started.action.provider == 'codex'
    assert b.gh_calls[0][:3] == ('pr', 'view', '34') and 'headRefOid' in b.gh_calls[0], b.gh_calls
    outcome = run_role(b, started)
    assert outcome == driver.Outcome(12, True, False, None), outcome
    note = b.note()
    assert b.card()['state'] == 'blocked' and note['blocked_from'] == 'review_security', note
    assert note['blocked_findings'] == [{'severity': 'Important',
                                         'text': 'stage-review: diff exceeds max_diff_bytes'}], note
    assert any('max_diff_bytes' in c for c in b.comments())
    args = (b.fake / 'args.txt').read_text().split('\n')
    assert args[:8] == ['12', '34', '--stage', 'security', '--round', '1', '--prev-sha', 'abc1234'], args
    assert '--impl-report' in args


def test_provider_stage_done_records_the_stage_review(base):
    out = {'status': 'posted', 'report_file': None, 'parsed': {}, 'provider': 'codex', 'model': 'gpt-5',
           'input_tokens': 5, 'output_tokens': 6, 'cost_usd': 0, 'attempts': 1}
    b, stage = provider_stage_board(base, 0, '')
    out['report_file'] = report_file(b, 'stage-reviewer-findings')
    fake_plugin(b, 0, json.dumps(out))
    outcome = run_role(b, begin(b, 'review_stage', state='review_security', stage=stage, round=1))
    assert outcome == driver.Outcome(12, True, False, None), outcome
    review = b.note()['last_review']
    assert review['stage'] == 'security' and review['agent'] is None and review['provider'] == 'codex', review
    assert review['model'] == 'gpt-5' and review['sha'] == 'abc1234' and review['important'] == 1, review


def _stage_ledger_line(base, **tokens):
    from supervisor import usage
    out = {'status': 'posted', 'report_file': None, 'parsed': {}, 'provider': 'codex', 'model': 'gpt-5',
           'cost_usd': 0, 'attempts': 1}
    out.update(tokens)
    b, stage = provider_stage_board(base, 0, '')
    out['report_file'] = report_file(b, 'stage-reviewer-findings')
    fake_plugin(b, 0, json.dumps(out))
    run_role(b, begin(b, 'review_stage', state='review_security', stage=stage, round=1))
    lines, skipped = usage.read(b.root)
    assert len(lines) == 1 and skipped == 0, lines
    return b, lines[0]


def test_stage_review_tokens_reach_the_ledger(base):
    b, line = _stage_ledger_line(base, input_tokens=1200, output_tokens=300)
    assert (line['input'], line['output'], line['cache_write'], line['cache_read']) == (1200, 300, None, None), line
    assert (line['provider'], line['model'], line['role']) == ('codex', 'gpt-5', 'stage-reviewer'), line
    assert line['action'] == 'review_security', line   # spec section 8: review_<stage name>, not the candidate name
    run = b.state.run_tokens
    assert run['input'] == 1200 and run['output'] == 300, run


def test_null_provider_tokens_are_unknown(base):
    b, line = _stage_ledger_line(base, input_tokens=None, output_tokens=None)
    assert [line[k] for k in ('input', 'output', 'cache_write', 'cache_read')] == [None] * 4, line
    assert line['provider'] == 'codex' and line['model'] == 'gpt-5', line
    run = b.state.run_tokens
    assert run['partial'] is True and run['unknown'] == 1 and run['total'] == 0, run


def test_provider_stage_exit_3_is_a_provider_failure(base):
    b, stage = provider_stage_board(base, 3, '', 'first line\nstage-review: KEY is not set\n')
    outcome = run_role(b, begin(b, 'review_stage', state='review_security', stage=stage, round=1))
    assert outcome.progressed is False and outcome.redispatch is False
    assert outcome.provider_failure == 'codex', outcome
    assert b.note()['action_failures'] == 0, 'a provider failure does not charge the card'


def test_provider_stage_exit_1_counts_with_the_last_stderr_line(base):
    b, stage = provider_stage_board(base, 1, '', 'warming up\nstage-review: empty reply\n')
    outcome = run_role(b, begin(b, 'review_stage', state='review_security', stage=stage, round=1))
    assert outcome == driver.Outcome(12, False, False, None), outcome
    note = b.note()
    assert note['action_failures'] == 1 and note['last_action_error'] == 'stage-review: empty reply', note
    assert b.card()['state'] == 'review_security' and note['report_errors'] == []


def test_agent_stage_dispatches_the_stage_agent_with_its_brief(base):
    b = board_for(base, 'review_security')
    stage = {'name': 'security', 'agent': 'sec-reviewer', 'model': 'opus', 'brief': 'Look for token leaks.',
             'provider': None}
    b.put_note({'round': 1, 'pr': 34, 'state': 'review_security', 'stage': 'security', 'branch': BRANCH,
                'worktree': b.worktree, 'last_review': LAST_REVIEW})
    worktree_ok(b)
    b.env['FAKE_ROLE_ROLE'] = 'stage-reviewer'
    b.plans({'report': 'stage-reviewer-ok'})
    started = begin(b, 'review_stage', state='review_security', stage=stage, round=1)
    prompt = b.prompt()
    assert 'Look for token leaks.' in prompt and 'security' in prompt and 'abc1234' in prompt, prompt
    assert 'parse-report.sh --role stage-reviewer' in prompt and 'board-comment.sh' in prompt, prompt
    argv = b.fake_calls()[0]['argv']
    assert argv[argv.index('--agent') + 1] == 'sec-reviewer' and argv[argv.index('--model') + 1] == 'opus'
    assert run_role(b, started).progressed is True
    review = b.note()['last_review']
    assert review['stage'] == 'security' and review['agent'] == 'sec-reviewer' and review['provider'] is None
    assert review['model'] == 'opus' and review['sha'] == 'abc1234', review


def test_exit_2_from_the_checker_pauses_the_supervisor(base):
    b = board_for(base)
    started = started_implementor(b)
    wait_for(started)
    b.stubs['parse-report.sh'] = fail_with('parse-report: cannot read file: x\n', rc=2)
    outcome = b.driver.finish(started.action, started.action.session.poll())
    assert outcome.progressed is False and outcome.redispatch is False
    assert b.state.mode == 'paused' and b.state.pause_reason.startswith('driver bug: '), b.state.pause_reason
    assert b.note()['action_failures'] == 0 and 12 not in b.state.active


# --- findings carried from the 2.6 review ---------------------------------------------------------------

def test_to_human_qa_without_a_qa_build_says_so_in_the_summary(base):
    b = board_for(base, 'in_review')
    seen = {}

    def handoff(*args):
        seen['args'] = tuple(str(a) for a in args)
        seen['summary'] = Path(str(args[1])).read_text()
        return ok()
    b.stubs['human-qa-handoff.sh'] = handoff
    begin(b, 'to_human_qa', state='in_review')
    assert seen['args'][0] == '--qa-summary' and seen['args'][2:] == ('12', '34'), seen
    assert seen['summary'].strip() == 'No QA build is configured.', seen


def test_a_failed_note_read_does_not_write_an_unknown_counter(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = fail_with('boom\n')
    b.put_note({'action_failures': 2, 'last_action_error': 'older'})

    def note_stub(*args):
        if args[0] == 'get':
            return fail_with('cannot read\n')
        return scripts.run(b.root, 'note.sh', *args, env=b.env)
    b.stubs['note.sh'] = note_stub
    assert begin(b, 'start').kind == 'done'
    note = b.note()
    assert note['action_failures'] == 2 and note['last_action_error'] == 'older', note
    messages = [e['payload'].get('message', '') for e in b.state.events]
    assert [m for m in messages if 'cannot read' in m], list(b.state.events)


def test_validation_errors_are_one_line_and_the_repo_regex_is_tight(base):
    cfg = {'board': {'repo': 'acme/toy\nsecond line'}, 'commands': {}}
    b = board_for(base, 'in_review', config=cfg)
    begin(b, 'mark_ready', state='in_review')
    assert b.note()['last_action_error'] == 'invalid repo: acme/toy', b.note()
    for repo in ('acme/to;y', 'ac me/toy', 'a/b/c', '-x/y'):
        sub = Path(base) / ('r%d' % abs(hash(repo)))
        sub.mkdir()
        b = board_for(sub, 'in_review', config={'board': {'repo': repo}, 'commands': {}})
        begin(b, 'mark_ready', state='in_review')
        assert b.gh_calls == [] and b.note()['last_action_error'].startswith('invalid repo: '), repo


def test_record_ignored_checks_appends_to_the_note_with_a_timestamp(base):
    b = board_for(base, 'merging')
    b.driver.clock = lambda: 1794398400  # 2026-11-11T12:00:00Z
    first = {'name': 'lint-docs', 'reason': 'docs lint is flaky', 'until': '2026-12-31'}
    b.driver.record_ignored_checks(12, [first])
    at = '2026-11-11T12:00:00Z'
    assert b.note()['ignored_checks'] == [dict(first, at=at)], b.note()
    second = {'name': 'ci/legacy-lint', 'reason': 'legacy', 'until': '2026-11-11'}
    b.driver.record_ignored_checks(12, [second])
    assert b.note()['ignored_checks'] == [dict(first, at=at), dict(second, at=at)], b.note()
    b.driver.record_ignored_checks(12, [])
    assert len(b.note()['ignored_checks']) == 2, b.note()


def test_record_ignored_checks_refuses_a_malformed_entry(base):
    b = board_for(base, 'merging')
    for bad in ([{'name': 'x'}], [{'name': '', 'reason': 'r', 'until': '2026-12-31'}], ['lint'],
                [{'name': 'x', 'reason': 'r', 'until': 'soon'}]):
        try:
            b.driver.record_ignored_checks(12, bad)
        except ValueError:
            continue
        raise AssertionError('accepted %r' % (bad,))
    assert 'ignored_checks' not in b.note() or b.note()['ignored_checks'] in (None, []), b.note()


def test_states_include_merging_and_leaving_it_clears_the_merge_records(base):
    b = board_for(base, 'merging')
    b.put_note({'last_review': LAST, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'abc1234'},
                'merge_refusal': {'pr': 34, 'head': 'abc1234', 'reason': 'r', 'at': '2026-11-11T00:00:00Z'},
                'merge_retry': {'pr': 34, 'head': 'abc1234', 'after': '2026-11-11T00:01:00Z'}})
    assert begin(b, 'block', state='merging', reason='merge refused for good').kind == 'done'
    assert b.card()['state'] == 'blocked', b.card()
    note = b.note()
    assert note['blocked_from'] == 'merging' and note['pending_merge'] is None and note['merge_refusal'] is None, note
    assert note['merge_retry'] is None, note


def test_a_block_from_review_leaves_the_merge_records_alone(base):
    b = board_for(base, 'in_review')
    b.put_note({'last_review': LAST})
    begin(b, 'block', state='in_review', reason='r')
    assert 'pending_merge' not in b.note() and 'merge_refusal' not in b.note(), b.note()


def _marking_tree(b, out=None):
    """A worktree.sh stub that, like the real `create`, leaves an empty active marker (fb_mark_active)."""
    def tree(*a):
        if a[0] == 'create':
            active = b.root / '.fleet-board' / 'active'
            active.mkdir(parents=True, exist_ok=True)
            with open(str(active / str(a[1])), 'a'):
                pass
        return ok(out if out is not None else b.worktree + '\n')
    return tree


def _nothing_stuck(b):
    from unittest import mock
    from supervisor import stuck
    with mock.patch.dict(os.environ, {'FLEET_BOARD_USER': 'fleet-bot'}):
        found = stuck.find(b.root)
    assert found == [], found
    assert not (b.root / '.fleet-board' / 'active' / '12').exists()


def test_update_branch_leaves_no_empty_marker(base):
    b = board_for(base, 'in_review')
    b.stubs['worktree.sh'] = _marking_tree(b)
    b.stubs['update-branch.sh'] = ok()
    assert begin(b, 'update_branch', state='in_review').kind == 'done'
    _nothing_stuck(b)


def test_a_failed_update_branch_leaves_no_empty_marker(base):
    b = board_for(base, 'in_review')
    b.stubs['worktree.sh'] = _marking_tree(b)
    b.stubs['update-branch.sh'] = fail_with('merge of origin/main into fleet/12 conflicts\n')
    begin(b, 'update_branch', state='in_review')
    _nothing_stuck(b)


def test_a_launch_that_raises_leaves_no_empty_marker(base):
    import types
    b = board_for(base, 'in_review')
    b.put_note({'round': 1, 'pr': 34, 'branch': BRANCH, 'worktree': b.worktree})
    b.stubs['worktree.sh'] = _marking_tree(b)
    b.stubs['review-stages.sh'] = ok('[]\n')

    def boom(*a, **kw):
        raise RuntimeError('no session')
    b.driver.roles = types.SimpleNamespace(command=driver._roles.command, launch=boom, DEFAULT_KILL_GRACE=5.0)
    b.seed(12, 'in_progress')
    b.put_note({'implementor_attempts': 1, 'round': 0})
    try:
        begin(b, 'continue_implementor', state='in_progress')
        raise AssertionError('begin should have raised')
    except RuntimeError:
        pass
    assert 12 not in b.state.active
    assert not (b.root / '.fleet-board' / 'active' / '12').exists(), 'the launch failure left an empty marker'


def test_ending_an_action_keeps_a_marker_naming_another_group_and_drops_an_empty_one(base):
    from supervisor import markers
    b = board_for(base)
    path = b.root / '.fleet-board' / 'active' / '12'
    for content, kept in ((json.dumps({'pgid': 4242, 'supervisor_pid': 1}), True), ('', False), ('junk', False)):
        action = state.Action(card=12, action='update_branch', column='in_review', role=None, provider='scripts',
                              paths=[], started_at=0, started_mono=0, kind='script',
                              marker=markers.path(b.root, None, 12))
        b.state.begin(action)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        b.state.end(12)
        assert path.exists() is kept, (content, kept)
        if path.exists():
            path.unlink()


def ledger_column(b):
    """The column of the one ledger line the finished session wrote."""
    from supervisor import usage
    lines, skipped = usage.read(b.root)
    assert len(lines) == 1 and skipped == 0, lines
    return lines[0]['action'], lines[0]['column']


def test_ledger_column_of_start_is_in_progress_not_ready(base):
    b = board_for(base)
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    run_role(b, begin(b, 'start'))
    assert ledger_column(b) == ('start', 'in_progress')


def test_ledger_column_of_continue_implementor_is_in_progress(base):
    b = board_for(base, 'in_progress')
    b.put_note({'implementor_attempts': 1, 'branch': BRANCH, 'worktree': b.worktree, 'round': 0})
    b.plans({'report': 'implementor-ok'})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    run_role(b, begin(b, 'continue_implementor', state='in_progress'))
    assert ledger_column(b) == ('continue_implementor', 'in_progress')


def test_ledger_column_of_start_review_is_in_review_not_in_progress(base):
    b = board_for(base, 'in_progress')
    b.stubs['review-stages.sh'] = ok('["security"]\n')
    worktree_ok(b)
    b.gh_result = ok('diff --git a/x b/x\n+line\n')
    b.plans({'report': 'reviewer-ok'})
    run_role(b, begin(b, 'start_review', state='in_progress'))
    assert ledger_column(b) == ('start_review', 'in_review')


def test_ledger_column_of_review_is_in_review(base):
    b = board_for(base, 'in_review')
    b.put_note({'round': 1, 'pr': 34, 'state': 'in_review', 'branch': BRANCH, 'worktree': b.worktree})
    worktree_ok(b)
    b.gh_result = ok('diff --git a/x b/x\n+line\n')
    b.plans({'report': 'reviewer-findings'})
    run_role(b, begin(b, 'review', state='in_review', round=1))
    assert ledger_column(b) == ('review', 'in_review')


def test_ledger_column_of_review_stage_is_the_stage_column(base):
    b = board_for(base, 'review_security')
    stage = {'name': 'security', 'agent': 'sec-reviewer', 'model': 'opus', 'brief': 'Look.', 'provider': None}
    b.put_note({'round': 1, 'pr': 34, 'state': 'review_security', 'stage': 'security', 'branch': BRANCH,
                'worktree': b.worktree, 'last_review': LAST_REVIEW})
    worktree_ok(b)
    b.env['FAKE_ROLE_ROLE'] = 'stage-reviewer'
    b.plans({'report': 'stage-reviewer-ok'})
    run_role(b, begin(b, 'review_stage', state='review_security', stage=stage, round=1))
    assert ledger_column(b) == ('review_security', 'review_security')


def test_ledger_column_of_fix_is_the_column_the_card_is_in(base):
    b = board_for(base, 'in_review')
    seed_fix(b)
    b.plans({'report': 'fixer-ok'})
    run_role(b, begin(b, 'fix', state='in_review', round=1))
    assert ledger_column(b) == ('fix', 'in_review')


def test_the_launch_column_stays_ready_while_the_ledger_column_is_in_progress(base):
    """`Action.column` keeps the launch-time column, which loop._note_cancelled restores on a cancel
    (loop_cases covers the restore itself); the ledger reads `work_column`."""
    b = board_for(base)
    b.plans({'report': 'implementor-ok', 'sleep': 30})
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    try:
        assert started.action.column == 'ready', started.action.column
        assert state.ledger_column(started.action) == 'in_progress', state.ledger_column(started.action)
    finally:
        started.action.session.cancel(0)
        wait_for(started)


if __name__ == '__main__':
    base = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp()
    names = sorted(n for n in dict(globals()) if n.startswith('test_'))
    failed = 0
    for name in names:
        sub = tempfile.mkdtemp(dir=base)
        try:
            globals()[name](sub)
            print('  ok   ' + name)
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print('  FAIL %s: %r' % (name, exc))
    sys.exit(1 if failed else 0)
