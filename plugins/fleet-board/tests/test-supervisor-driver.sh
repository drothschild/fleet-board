#!/bin/bash
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-driver.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 "$plugin_dir/fixtures/supervisor/driver_cases.py" "$tmp"

# Worktree cleanup after done (card 149): cases that use the driver_cases fixtures.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + '/fixtures/supervisor')
import driver_cases as dc

base = sys.argv[2]


def cleanup_board(sub, rc=0, stderr='', state='in_review'):
    b = dc.board_for(sub, state, body='plain body')
    b.stubs['cleanup-done.sh'] = (dc.ok() if rc == 0 else dc.fail_with(stderr, rc))
    return b


def case_cleanup_runs_once_after_the_done_move(sub):
    b = cleanup_board(sub)
    assert dc.begin(b, 'finish', state='in_review').kind == 'done'
    names = [c[0] for c in b.calls]
    assert names.count('cleanup-done.sh') == 1, b.calls
    assert names.index('cleanup-done.sh') > names.index('board-move.sh'), b.calls
    assert b.card()['state'] == 'done'


def case_cleanup_failure_is_a_warning_and_never_fails_the_action(sub):
    b = cleanup_board(sub, 1, 'boom')
    assert dc.begin(b, 'finish', state='in_review').kind == 'done'
    assert [c[0] for c in b.calls].count('cleanup-done.sh') == 1, b.calls
    assert b.card()['state'] == 'done' and b.note()['action_failures'] == 0
    kinds = [e['type'] for e in b.state.events]
    assert 'action_failed' not in kinds, b.state.events
    warns = [e for e in b.state.events if e['type'] == 'warning' and 'cleanup-done.sh' in e['payload']['message']]
    assert warns, b.state.events


def case_human_qa_does_not_run_cleanup(sub):
    b = cleanup_board(sub)
    dc.Path(b.worktree).mkdir(parents=True)
    assert dc.begin(b, 'to_human_qa', state='in_review').kind == 'done'
    assert b.card()['state'] == 'human_qa'
    assert 'cleanup-done.sh' not in [c[0] for c in b.calls], b.calls


def case_file_pending_files_a_blocked_card_with_an_empty_pr(sub):
    b = dc.board_for(sub, 'blocked', body='plain body')
    b.put_note({'pending_followups': dc.PENDING})
    seen = {}

    def files(*args):
        seen['pr'] = str(args[1])
        return dc.ok(dc.json.dumps({'out_of_scope_created': [{'title': 'Docs', 'number': 5, 'existing': False},
                                                             {'title': 'Cache', 'number': 6, 'existing': False}],
                                    'bugs_filed': [{'title': 'Crash', 'number': 7, 'existing': False}]}))
    b.stubs['file-followups.sh'] = files
    assert dc.begin(b, 'file_pending', state='blocked', pr=None).kind == 'done'
    assert seen.get('pr') == '', seen
    assert b.note()['pending_followups'] is None, b.note()


def case_file_pending_still_holds_a_non_blocked_card_with_no_pr(sub):
    b = dc.board_for(sub, 'in_review', body='plain body')
    b.put_note({'pending_followups': dc.PENDING})
    assert dc.begin(b, 'file_pending', state='in_review', pr=None).kind == 'done'
    assert 'file-followups.sh' not in b.scripts_called()
    assert b.note()['pending_followups'] is not None


# No merger session when there are no after-merge steps (card 366)
def merger_board(sub, body='plain body', config=None, persona_file=False):
    b = dc.board_for(sub, 'merging', body=body, config=dict(dc.CONFIG, **(config or {})))
    b.put_note({'merged_pr': 34, 'pr': 34, 'state': 'merging'})
    b.plans({'report': 'merger-after-merge-done', 'post': False})
    b.stubs['after-merge.sh'] = dc.ok(dc.json.dumps({'outcome': 'done', 'results': [], 'note': [], 'comment': ''}))
    b.gh_result = dc.ok(dc.json.dumps({'files': [], 'mergeCommit': {'oid': 'f' * 40}}))
    if persona_file:
        (b.root / '.fleet-board' / 'merger.md').write_text('# Persona\nNo steps.\n')
    return b


def merger_started(b, mode='merged'):
    action = b.driver.begin_merger(12, mode, {'pr': 34, 'head': 'abc1234', 'reason': 'merged'})
    if action.session is not None:
        dc.wait_for(dc.driver.Started('session', action))
    return action


def case_default_persona_with_no_after_merge_steps_launches_no_merger_session(sub):
    b = merger_board(sub)
    action = merger_started(b)
    assert action.session is None, 'a merger session was launched'
    assert b.fake_calls() == [], b.fake_calls()
    assert 12 not in b.state.active
    assert b.note()['merger'] == {'mode': 'after_merge', 'status': 'done', 'head': 'abc1234'}, b.note()
    assert b.card()['state'] == 'merging'


def case_persona_append_still_starts_the_merger_session(sub):
    b = merger_board(sub, config={'merge': {'persona_append': 'Also tag the release.'}})
    assert merger_started(b).session is not None
    assert len(b.fake_calls()) == 1


def case_a_local_merger_persona_file_still_starts_the_merger_session(sub):
    b = merger_board(sub, persona_file=True)
    assert merger_started(b).session is not None
    assert len(b.fake_calls()) == 1


def case_an_after_merge_section_still_starts_the_merger_session(sub):
    b = merger_board(sub, body='intro\n\n## After merge\n\n- `make deploy`\n')
    assert merger_started(b).session is not None
    assert len(b.fake_calls()) == 1


def case_a_refused_merge_under_the_default_persona_starts_the_merger_in_refusal_mode(sub):
    b = merger_board(sub)
    b.plans({'report': 'merger-refusal-retry', 'post': False})
    b.put_note({'merge_refusal': {'pr': 34, 'head': 'abc1234', 'reason': 'policy', 'at': '2026-11-11T00:00:00Z'}})
    action = b.driver.begin_merger(12, 'refused', {'pr': 34, 'head': 'abc1234', 'reason': 'policy'})
    assert action.session is not None and action.action == 'merge_refusal', action
    dc.wait_for(dc.driver.Started('session', action))
    assert len(b.fake_calls()) == 1
    assert 'merger' not in b.note() or b.note()['merger']['mode'] != 'after_merge', b.note()


def version_commit_count(sub, text):
    g, repo, reviewed = dc._version_repo(sub)
    (repo / 'plugin.json').write_text(text)
    g('commit', '-q', '-am', 'version commit')
    return dc._count_since(repo, reviewed)


def case_version_commit_raising_semver_is_not_counted(sub):
    assert version_commit_count(sub, '{\n  "name": "x",\n  "version": "1.0.1"\n}\n') == '0'


def case_version_commit_lowering_the_version_is_counted(sub):
    g, repo, reviewed = dc._version_repo(sub)
    (repo / 'plugin.json').write_text('{\n  "name": "x",\n  "version": "0.9.0"\n}\n')
    g('commit', '-q', '-am', 'lower')
    assert dc._count_since(repo, reviewed) == '1', dc._count_since(repo, reviewed)


def case_version_commit_to_a_non_semver_value_is_counted(sub):
    assert version_commit_count(sub, '{\n  "name": "x",\n  "version": "latest"\n}\n') == '1'


def case_version_commit_on_a_nested_key_is_counted(sub):
    g, repo, reviewed = dc._version_repo(sub)
    (repo / 'plugin.json').write_text('{\n  "name": "x",\n  "version": "1.0.0",\n  "source": {\n    "version": "2.0.0"\n  }\n}\n')
    g('commit', '-q', '-am', 'add nested')
    base_count = dc._count_since(repo, reviewed)
    (repo / 'plugin.json').write_text('{\n  "name": "x",\n  "version": "1.0.0",\n  "source": {\n    "version": "2.0.1"\n  }\n}\n')
    g('commit', '-q', '-am', 'bump nested')
    assert dc._count_since(repo, reviewed) == str(int(base_count) + 1), dc._count_since(repo, reviewed)


failed = 0
for name, fn in sorted(globals().items()):
    if name.startswith('case_'):
        try:
            fn(tempfile.mkdtemp(dir=base))
            print('  ok   ' + name)
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print('  FAIL %s: %r' % (name, exc))
sys.exit(1 if failed else 0)
PY
