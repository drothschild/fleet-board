"""Card driver contract tests: every script-only action on a local fixture board.

Board scripts (board-move, board-comment, note, board-read) run for real against a seeded local store; the
scripts that need a remote or a worktree (worktree, update-branch, verify-main, ...) are stubbed and recorded.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'scripts'))
from supervisor import driver, scripts, state  # noqa: E402

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
        self.env = {'FLEET_BOARD_USER': 'fleet-bot'}
        self.worktree = str(self.root / '.fw' / '12-add-subtract')
        self.config = config or CONFIG
        self.calls = []
        self.gh_calls = []
        self.stubs = {}
        self.gh_result = ok()
        self.state = state.State('run-1')
        self.driver = driver.CardDriver(self.root, lambda: self.config, self.state, run=self.run, gh=self.gh)

    def run(self, root, name, *args, **kw):
        self.calls.append((name,) + tuple(str(a) for a in args))
        if name in self.stubs:
            stub = self.stubs[name]
            return stub(*args) if callable(stub) else stub
        return scripts.run(root, name, *args, env=self.env, **kw)

    def gh(self, root, *args):
        self.gh_calls.append(tuple(args))
        return self.gh_result

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


def begin(b, action, **kw):
    kw.setdefault('worktree', b.worktree)
    return b.driver.begin(candidate(action, **kw))


def test_start_runs_setup_and_returns_a_session(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = ok(b.worktree + '\n')
    started = begin(b, 'start')
    assert started.kind == 'session' and started.action.action == 'start' and started.action.session is None
    assert started.action.card == 12 and started.action.role == 'implementor'
    assert b.scripts_called() == ['worktree.sh', 'board-move.sh'], b.calls
    assert b.calls[0] == ('worktree.sh', 'create', '12', BRANCH, b.worktree)
    assert b.calls[1] == ('board-move.sh', '12', 'in_progress')
    assert b.card()['state'] == 'in_progress'
    note = b.note()
    assert note['branch'] == BRANCH and note['worktree'] == b.worktree and note['round'] == 0, note
    assert note['implementor_attempts'] == 1 and note['models']['implementor'] == 'sonnet', note
    assert note['state'] == 'in_progress'
    assert b.state.active[12] is started.action
    try:
        b.driver._dispatch_role(started.action, candidate('start'))
    except NotImplementedError:
        return
    raise AssertionError('the role dispatch hook must raise NotImplementedError until task 2.7')


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
    started = begin(b, 'start_review', state='in_progress')
    assert started.kind == 'session' and started.action.role == 'reviewer'
    assert b.scripts_called() == ['review-stages.sh', 'board-move.sh'], b.calls
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
    assert ('human-qa-handoff.sh', '12', '34') in b.calls, b.calls
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
    assert {'start', 'start_review', 'fix', 'review'} <= set(driver.ROLE_ACTIONS)


def test_a_busy_card_is_refused(base):
    b = board_for(base)
    b.stubs['worktree.sh'] = ok()
    begin(b, 'start')
    try:
        begin(b, 'skip')
    except ValueError:
        return
    raise AssertionError('a card with an active action must be refused')


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
