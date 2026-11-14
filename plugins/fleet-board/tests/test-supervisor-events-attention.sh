#!/bin/bash
# The supervisor shows its events and attention (card 257): the snapshot's events and per-card attention, a merger
# attention comment, `supervisor status`, the event log, the status strip's real values.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-events.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import io
import json
import sys
import threading
import unittest
from pathlib import Path

PLUGIN, BASE = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(PLUGIN) / 'fixtures' / 'supervisor'))
sys.argv = [sys.argv[0], BASE]
import driver_cases as dc  # noqa: E402
import loop_cases as lc  # noqa: E402
import merging_cases as mc  # noqa: E402
from supervisor import cli, service, state, webproxy  # noqa: E402

REASON = 'merge refused again after a retry: base branch policy'


class Events(unittest.TestCase):
    def test_a_state_snapshot_events_holds_at_most_50_entries_newest_last(self):
        st = state.State('run-1')
        for i in range(120):
            st.event('warning', message='m%d' % i)
        events = st.snapshot().get('events')
        self.assertIsNotNone(events, 'the snapshot has no events')
        self.assertEqual(len(events), 50)
        self.assertEqual([e['sequence'] for e in events], list(range(71, 121)))
        self.assertEqual(events[-1]['payload'], {'message': 'm119'})


class MergerAttention(mc.MergerFlow):
    def test_a_merger_reporting_attention_sets_the_card_attention_and_adds_one_comment_naming_the_reason(self):
        self.merger('refused', self.refused(), 'merger-refusal-attention')
        reason = self.b.note(12)['merger']['reason']
        self.assertTrue(reason)
        attention = self.b.state.snapshot().get('attention', {})
        self.assertIn('12', attention)
        self.assertIn(reason, json.dumps(attention['12']))
        comments = [c for c in self.b.comments(12) if c.startswith('Merger needs attention')]
        self.assertEqual(len(comments), 1, comments)
        self.assertIn(reason, comments[0])


class Cli(unittest.TestCase):
    def test_supervisor_status_prints_the_attention_card_and_the_unhealthy_provider_with_reasons(self):
        status = {'schema_version': 2, 'mode': 'running', 'pid': 1, 'root': '/r', 'active': [],
                  'attention': {'12': {'reason': REASON, 'at': 1.0}},
                  'provider_health': {'codex': {'reason': 'OPENAI_API_KEY is unset', 'failures': 1}}}
        out, err = io.StringIO(), io.StringIO()
        rc = cli.main(['status'], env={}, stdout=out, stderr=err, transport=lambda request: status)
        self.assertEqual(rc, 0, err.getvalue())
        text = out.getvalue()
        self.assertRegex(text, r'(?m)^.*attention.*\b12\b.*' + 'base branch policy')
        self.assertIn('unhealthy provider codex: OPENAI_API_KEY is unset', text)


class Loop(lc.LoopCase):
    concurrency = 20

    def test_each_event_is_appended_as_one_json_line_to_supervisor_log(self):
        log = self.dir / 'supervisor.log'
        self.b.state.event_log = str(log)
        self.b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 6})
        self.start()
        self.until(lambda: any(e['type'] == 'admitted' for e in list(self.b.state.events)), what='card 12 admitted')
        lines = log.read_text().splitlines() if log.exists() else []
        self.assertTrue(lines, 'nothing was written to supervisor.log')
        entries = [json.loads(line) for line in lines]
        for entry in entries:
            self.assertEqual(sorted(entry), ['at', 'payload', 'sequence', 'type'])
        sequences = [e['sequence'] for e in entries]
        self.assertEqual(sequences, sorted(set(sequences)))
        admitted = [e for e in entries if e['type'] == 'admitted']
        self.assertEqual([e['payload']['card'] for e in admitted], [12])

    def hold_second_cycle(self, rows):
        gate = threading.Event()
        self.addCleanup(gate.set)

        def feed():
            if self.fetches > 1:
                gate.wait(20)
            return rows()
        self.rows = feed

    def test_a_cycle_with_one_card_admitted_and_one_held_by_a_scope_overlap_shows_queue_ready_and_waiting(self):
        self.add_card(13)
        self.b.plans({'report': 'implementor-ok', 'post': False, 'sleep': 6})
        self.hold_second_cycle(lambda: [dc.candidate('start', number=n, branch=lc.BRANCH[n], worktree=self.b.worktree,
                                                     state='ready', declared_paths=['shared']) for n in (12, 13)])
        self.start()
        self.until(lambda: self.b.state.snapshot().get('queue', {}).get('waiting') is not None, what='the queue')
        queue = self.b.state.snapshot()['queue']
        self.assertEqual(queue['ready'], len(self.sup.last_cycle['admitted']))
        self.assertEqual((queue['ready'], queue['waiting']), (1, 1))

    def test_a_running_supervisor_with_limits_concurrency_20_has_capacity_global_cap_20(self):
        self.hold_second_cycle(lambda: [])
        self.start()
        self.until(lambda: self.sup.last_cycle, what='the first cycle')
        svc = service.Service(self.b.root, self.b.state, lambda request: {}, run_lock_path=str(self.dir / 'run.lock'))
        status = webproxy.ui_status(svc.status_view())
        self.assertEqual(status['capacity']['global_cap'], 20)


def suite():
    names = unittest.TestSuite()
    names.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Events))
    names.addTest(MergerAttention('test_a_merger_reporting_attention_sets_the_card_attention_and_adds_one_comment_naming_the_reason'))
    names.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Cli))
    names.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Loop))
    return names


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=1).run(suite())
    sys.exit(0 if result.wasSuccessful() else 1)
PY
