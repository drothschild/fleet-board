"""The usage ledger (Task 3.1): append, read, totals, drill-down, the driver's one line per completed action,
the `usage` command and the token limits. Tokens only: no test here knows a price."""
import io
import json
import os
import stat
import sys
import unittest
from pathlib import Path
from unittest import mock

PLUGIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PLUGIN / 'fixtures' / 'supervisor'))
import loop_cases as lc  # noqa: E402  (pops the base directory from argv)
import driver_cases as dc  # noqa: E402
from supervisor import cli, usage  # noqa: E402

BASE = lc.BASE
KEYS = ('run_id', 'card', 'kind', 'column', 'action', 'role', 'provider', 'model', 'input', 'output',
        'cache_write', 'cache_read', 'started_at', 'ended_at', 'log')
FULL = {'input_tokens': 60, 'output_tokens': 40, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}


def line(**kw):
    base = {'run_id': 'r1', 'card': 12, 'kind': 'card', 'column': 'ready', 'action': 'start',
            'role': 'implementor', 'provider': 'claude', 'model': 'sonnet', 'input': 10, 'output': 5,
            'cache_write': 2, 'cache_read': 1, 'started_at': '2026-11-11T10:00:00Z',
            'ended_at': '2026-11-11T10:01:00Z', 'log': '/logs/x.jsonl'}
    base.update(kw)
    return base


class Ledger(unittest.TestCase):
    def setUp(self):
        self.root = BASE / self.id().rsplit('.', 1)[-1]
        (self.root / '.fleet-board').mkdir(parents=True)

    def path(self):
        return usage.ledger_path(self.root)

    def test_ledger_path_follows_board_dir(self):
        self.assertEqual(usage.ledger_path(self.root), self.root / '.fleet-board' / 'usage.jsonl')
        self.assertEqual(usage.ledger_path(self.root, 'state'), self.root / 'state' / 'usage.jsonl')

    def test_append_is_one_line_0600(self):
        writes = []
        real = os.write

        def spy(fd, data):
            writes.append(data)
            return real(fd, data)

        with mock.patch.object(usage.os, 'write', spy):
            usage.append(self.root, line())
        self.assertEqual(len(writes), 1, 'one os.write per line')
        self.assertTrue(writes[0].endswith(b'\n') and writes[0].count(b'\n') == 1)
        self.assertEqual(stat.S_IMODE(os.stat(self.path()).st_mode), 0o600)
        usage.append(self.root, line(card=13))
        rows = self.path().read_text().splitlines()
        self.assertEqual(len(rows), 2)
        self.assertEqual(sorted(json.loads(rows[0])), sorted(KEYS))
        self.assertTrue((self.root / '.fleet-board' / 'usage.jsonl.lock').exists())

    def test_append_refuses_wrong_keys(self):
        for bad in (dict(line(), extra=1), {k: v for k, v in line().items() if k != 'log'},
                    line(input='ten'), line(output=True), line(input=-1), line(kind='other')):
            with self.assertRaises(ValueError, msg=bad):
                usage.append(self.root, bad)
        self.assertFalse(self.path().exists() and self.path().read_text())

    def test_unknown_is_never_zero(self):
        usage.append(self.root, line(input=None, output=None, cache_write=None, cache_read=None, model=None))
        usage.append(self.root, line(input=7, output=3, cache_write=0, cache_read=0))
        lines, skipped = usage.read(self.root)
        self.assertEqual(skipped, 0)
        self.assertIsNone(lines[0]['input'], 'unknown stays null on disk, never 0')
        t = usage.totals(lines)
        self.assertEqual((t['input'], t['output'], t['total'], t['unknown'], t['partial']), (7, 3, 10, 1, True))
        only = usage.totals(lines[:1])
        self.assertEqual((only['total'], only['unknown'], only['partial']), (0, 1, True))
        self.assertEqual(usage.totals(lines[1:])['partial'], False)
        some = usage.totals([line(input=5, output=None)])
        self.assertEqual((some['input'], some['output'], some['total'], some['unknown']), (5, 0, 5, 1))

    def test_malformed_lines_are_skipped_and_reported(self):
        usage.append(self.root, line(input=10, output=0, cache_write=0, cache_read=0))
        with open(self.path(), 'ab') as f:
            f.write(b'this is not json\n')
            f.write(b'{"run_id": "r1", "card": 1\n')            # torn
            f.write(b'[1, 2]\n')
            f.write(json.dumps(dict(line(), extra=1)).encode() + b'\n')   # wrong shape
            f.write(b'\n')                                       # blank lines are not damage
        usage.append(self.root, line(input=5, output=0, cache_write=0, cache_read=0))
        warned = []
        lines, skipped = usage.read(self.root, warn=warned.append)
        self.assertEqual(skipped, 4)
        self.assertEqual(len(warned), 1, 'one warning, not one per line')
        self.assertIn('4', warned[0])
        t = usage.totals(lines, skipped=skipped)
        self.assertEqual(t['total'], 15)
        self.assertTrue(t['partial'], 'a total over a damaged ledger is marked partial')
        self.assertFalse(usage.totals(lines)['partial'])

    def test_a_torn_tail_does_not_swallow_the_next_line(self):
        usage.append(self.root, line(input=10))
        with open(self.path(), 'ab') as f:
            f.write(b'{"run_id": "r1", "ca')                    # crashed mid-write, no newline
        usage.append(self.root, line(input=5))
        lines, skipped = usage.read(self.root)
        self.assertEqual((len(lines), skipped), (2, 1))
        self.assertEqual([l['input'] for l in lines], [10, 5])

    def test_read_of_a_missing_ledger_is_empty(self):
        self.assertEqual(usage.read(self.root / 'nowhere'), ([], 0))

    def test_totals_by_run_card_kind(self):
        lines = [line(run_id='a', card=12, input=1, output=1, cache_write=0, cache_read=0),
                 line(run_id='a', card=13, input=2, output=2, cache_write=0, cache_read=0),
                 line(run_id='b', card=12, input=4, output=4, cache_write=1, cache_read=1),
                 line(run_id='b', card=None, kind='planner', column=None, action='planner', role='planner',
                      input=8, output=8, cache_write=0, cache_read=0)]
        self.assertEqual(usage.totals(lines)['total'], 2 + 4 + 10 + 16)
        self.assertEqual(usage.totals(lines, run_id='a')['total'], 6)
        self.assertEqual(usage.totals(lines, card=12)['total'], 2 + 10)
        self.assertEqual(usage.totals(lines, kind='planner')['total'], 16)
        self.assertEqual(usage.totals(lines, run_id='b', card=12)['cache_write'], 1)
        self.assertEqual(usage.totals(lines, run_id='zzz'),
                         {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0, 'total': 0,
                          'unknown': 0, 'partial': False})
        self.assertEqual(sorted(usage.totals(lines)), sorted(
            ['input', 'output', 'cache_write', 'cache_read', 'total', 'unknown', 'partial']))

    def test_drilldown_orders_columns(self):
        lines = [line(card=12, column='in_progress', action='start', input=1),
                 line(card=13, column='ready', action='start', input=100),
                 line(card=12, column='in_review', action='review', input=2),
                 line(card=12, column='in_progress', action='fix', input=3)]
        d = usage.drilldown(lines, 12)
        self.assertEqual(d['card'], 12)
        self.assertEqual([c['column'] for c in d['columns']], ['in_progress', 'in_review'])
        first = d['columns'][0]
        self.assertEqual([a['action'] for a in first['actions']], ['start', 'fix'])
        self.assertEqual(first['totals']['input'], 4)
        self.assertEqual(d['totals']['input'], 6)
        self.assertEqual(usage.drilldown(lines, 99), {'card': 99, 'totals': usage.totals([]), 'columns': []})


class CliUsage(unittest.TestCase):
    def setUp(self):
        self.root = BASE / self.id().rsplit('.', 1)[-1]
        (self.root / '.fleet-board').mkdir(parents=True)
        usage.append(self.root, line(run_id='old', card=12, input=100, output=0, cache_write=0, cache_read=0))
        usage.append(self.root, line(run_id='old', card=None, kind='planner', column=None, action='planner',
                                     role='planner', input=7, output=0, cache_write=0, cache_read=0))
        self.env = {'FLEET_BOARD_DOMAIN': str(self.root), 'FLEET_BOARD_SUPERVISOR_SOCKET': str(self.root / 's')}

    def run_cli(self, *argv, transport=None):
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(list(argv), env=self.env, stdout=out, stderr=err, transport=transport)
        return rc, out.getvalue(), err.getvalue()

    def test_usage_without_a_supervisor_reads_the_ledger(self):
        rc, out, err = self.run_cli('usage', '--json')
        self.assertEqual(rc, 0, err)
        data = json.loads(out)
        self.assertIsNone(data['run'], 'no supervisor, no run total')
        self.assertEqual(data['all_time']['total'], 100)
        self.assertEqual(data['planner']['total'], 7)
        rc, out, _ = self.run_cli('usage')
        self.assertIn('100', out)
        self.assertNotIn('$', out)

    def test_usage_card_drilldown(self):
        rc, out, err = self.run_cli('usage', '--card', '12', '--json')
        self.assertEqual(rc, 0, err)
        data = json.loads(out)
        self.assertEqual(data['card'], 12)
        self.assertEqual(data['columns'][0]['column'], 'ready')
        rc, out, _ = self.run_cli('usage', '--card', '12')
        self.assertIn('ready', out)
        self.assertIn('start', out)

    def test_usage_asks_a_running_supervisor_when_it_answers(self):
        reply = {'run': {'input': 1, 'output': 1, 'cache_write': 0, 'cache_read': 0, 'total': 2, 'unknown': 0,
                         'partial': False},
                 'all_time': usage.totals([]), 'planner': usage.totals([]), 'skipped': 0}
        seen = []

        def transport(request):
            seen.append(request)
            return reply

        rc, out, err = self.run_cli('usage', '--json', transport=transport)
        self.assertEqual(rc, 0, err)
        self.assertEqual(seen, [{'command': 'usage'}])
        self.assertEqual(json.loads(out)['run']['total'], 2)

    def test_usage_rejects_a_bad_card(self):
        rc, _, err = self.run_cli('usage', '--card', 'x')
        self.assertEqual(rc, 2)


class DriverLine(unittest.TestCase):
    def board(self):
        d = BASE / self.id().rsplit('.', 1)[-1]
        d.mkdir()
        return dc.board_for(d)

    def test_one_line_per_completed_role_action(self):
        b = self.board()
        b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
        b.plans({'report': 'implementor-ok', 'usage': dict(FULL, cache_creation_input_tokens=3,
                                                           cache_read_input_tokens=9)})
        started = dc.begin(b, 'start')
        result = dc.wait_for(started)
        b.driver.finish(started.action, result)
        lines, skipped = usage.read(b.root)
        self.assertEqual((len(lines), skipped), (1, 0))
        got = lines[0]
        self.assertEqual(got['run_id'], 'run-1')
        self.assertEqual((got['card'], got['kind'], got['column'], got['action'], got['role']),
                         (12, 'card', 'ready', 'start', 'implementor'))
        self.assertEqual((got['input'], got['output'], got['cache_write'], got['cache_read']), (60, 40, 3, 9))
        self.assertEqual(got['provider'], 'claude')
        self.assertEqual(got['log'], result.log_path)
        self.assertTrue(got['started_at'].endswith('Z') and got['ended_at'].endswith('Z'))
        run = b.state.run_tokens
        self.assertEqual((run['total'], run['unknown'], run['partial']), (112, 0, False))

    def test_unreadable_usage_is_recorded_unknown(self):
        b = self.board()
        b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
        b.plans({'report': 'implementor-ok', 'usage': None})
        started = dc.begin(b, 'start')
        b.driver.finish(started.action, dc.wait_for(started))
        got = usage.read(b.root)[0][0]
        self.assertEqual([got[k] for k in ('input', 'output', 'cache_write', 'cache_read')], [None] * 4)
        self.assertEqual((b.state.run_tokens['total'], b.state.run_tokens['unknown'],
                          b.state.run_tokens['partial']), (0, 1, True))

    def test_script_only_actions_write_no_line(self):
        b = self.board()
        dc.begin(b, 'wait', state='ready')
        dc.begin(b, 'skip', state='ready')
        self.assertFalse(usage.ledger_path(b.root).exists())

    def test_a_ledger_write_failure_is_a_warning_not_a_failed_action(self):
        b = self.board()
        b.stubs['worktree.sh'] = dc.ok(b.worktree + '\n')
        b.plans({'report': 'implementor-ok', 'usage': FULL})
        started = dc.begin(b, 'start')
        result = dc.wait_for(started)
        with mock.patch.object(usage, 'append', side_effect=OSError('disk full')):
            outcome = b.driver.finish(started.action, result)
        self.assertTrue(outcome.progressed)
        self.assertTrue([e for e in b.state.events if e['type'] == 'warning'])


class Limits(lc.LoopCase):
    def setUp(self):
        super().setUp()
        self.b.config['limits'].update(max_tokens=20000000)

    def test_token_limit_pauses(self):
        self.b.config['limits']['max_tokens'] = 100
        self.rows = self.implement_plan
        self.b.plans({'report': 'implementor-ok', 'usage': FULL}, {'report': 'reviewer-ok', 'usage': FULL})
        self.start()
        self.until(lambda: self.mode() == 'paused', what='the token limit pause')
        reason = self.b.state.snapshot()['pause_reason']
        self.assertTrue(reason.startswith('token limit reached'), reason)
        self.assertIn('max_tokens', reason)
        self.assertEqual(self.b.state.snapshot()['run_tokens']['total'], 100)
        self.assertEqual(self.count(), 1)
        self.sup.wake('test')
        self.cycles_done(2)
        self.assertEqual(self.mode(), 'paused', 'a paused run stays paused while the limit is reached')
        # Raising the limit and resuming carries on.
        self.b.config['limits']['max_tokens'] = 100000
        self.assertEqual(self.sup.handle({'command': 'resume'})['mode'], 'running')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_a_running_session_finishes_when_the_limit_is_reached(self):
        self.add_card(13)
        self.b.config['limits']['max_tokens'] = 100
        self.rows = self.implement_plan
        self.b.plans({'report': 'implementor-ok', 'usage': FULL, 'sleep': 0},
                     {'report': 'implementor-ok', 'usage': FULL, 'sleep': 2})
        self.start()
        self.until(lambda: self.mode() == 'paused', what='the pause')
        self.until(lambda: self.b.note(12).get('pr') == 12 or self.b.note(13).get('pr') == 13,
                   what='a running session to finish')
        self.until(lambda: not self.b.state.snapshot()['active'], what='all sessions to settle')
        self.assertEqual(self.b.state.snapshot()['run_tokens']['total'], 200)
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_per_card_limit_waits_only_that_card(self):
        self.add_card(13)
        self.b.config['limits']['max_tokens_per_card'] = 50
        usage.append(self.b.root, line(run_id='earlier', card=12, input=30, output=30, cache_write=0, cache_read=0))
        usage.append(self.b.root, line(run_id='earlier', card=13, input=5, output=5, cache_write=0, cache_read=0))
        self.rows = self.implement_plan
        self.b.plans({'report': 'implementor-ok', 'usage': FULL})
        self.start()
        self.until(lambda: self.b.note(13).get('pr') == 13, what="card 13's implementor")
        self.cycles_done(2)
        self.assertEqual(self.b.card(12)['state'], 'ready', 'a card at its cap is not admitted')
        self.assertEqual(self.count(), 1)
        waits = {w['number']: w['reason'] for w in self.sup.last_cycle['waits']}
        self.assertEqual(waits.get(12), 'card token limit reached')
        self.assertNotIn(12, [r['number'] for r in self.sched.calls[-1][0]], 'the scheduler never sees it')
        self.assertIn(13, [r['number'] for rows, _ in self.sched.calls for r in rows])
        self.assertEqual(self.mode(), 'running', 'a per-card limit never pauses the run')
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_a_card_over_its_cap_still_gets_script_only_actions(self):
        self.b.config['limits']['max_tokens_per_card'] = 1
        usage.append(self.b.root, line(card=12, input=30, output=30, cache_write=0, cache_read=0))
        self.rows = lambda: [dc.candidate('wait', number=12, state='ready', declared_paths=['a'])]
        self.start()
        self.cycles_done(1)
        waits = [w['reason'] for w in self.sup.last_cycle['waits'] if w['number'] == 12]
        self.assertNotIn('card token limit reached', waits)
        self.sup.request_stop('drain')
        self.assertEqual(self.finished(), 0)

    def test_a_duplicate_admission_does_not_charge_the_running_card(self):
        row = dc.candidate('start', number=12, branch=lc.BRANCH[12], worktree=self.b.worktree,
                           declared_paths=['p12'])
        self.b.driver.begin = mock.Mock(side_effect=ValueError('card already active'))
        self.sup._begin(row)
        self.assertEqual([c for c in self.b.calls if c[0] == 'note.sh'], [], 'no note was read or merged')
        events = [e for e in self.b.state.events if e['type'] == 'action_failed']
        self.assertEqual(len(events), 1)
        self.assertIn('card already active', events[0]['payload']['error'])
        self.assertNotIn('action_failures', self.b.note())

    def test_a_real_failure_is_still_counted(self):
        row = dc.candidate('start', number=12, branch=lc.BRANCH[12], worktree=self.b.worktree,
                           declared_paths=['p12'])
        self.b.driver.begin = mock.Mock(side_effect=ValueError('something else'))
        self.sup._begin(row)
        self.assertEqual(self.b.note()['action_failures'], 1)


if __name__ == '__main__':
    unittest.main()
