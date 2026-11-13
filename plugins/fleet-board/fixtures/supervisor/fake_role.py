#!/usr/bin/env python3
"""A fake `claude` for the supervisor's role-runner tests (used as FLEET_BOARD_CLAUDE).

Environment
  FAKE_ROLE_DIR      required; holds `count`, the plans and the logs
  FAKE_ROLE_ROLE     the role passed to `parse-report.sh --role` (default: the agent name after ':')
  FAKE_ROLE_CARD     the card number passed to `board-comment.sh` (default 1)
  FAKE_ROLE_SCRIPTS  scripts dir holding parse-report.sh and board-comment.sh (default: the plugin's)

Invocation N (1, 2, ...) increments FAKE_ROLE_DIR/count and reads FAKE_ROLE_DIR/N.json, falling back to
default.json, then {}:
  {"report": "<name of a fixtures/reports file, or literal text>",
   "usage": {"input_tokens": ..} | null, "exit": 0, "is_error": false, "subtype": "success",
   "stderr": "", "sleep": 0, "ignore_term": false, "spawn_child": false, "post": true,
   "no_result": false, "permission_mode": "<overrides the init event's permissionMode>",
   "pre_events": [<stream-json events printed before init>], "no_init": false, "child_ignore_term": false}

It prints a stream-json init event, then (when `post`) runs `parse-report.sh --role <role> <file>` and, only if
that exits 0, `board-comment.sh <N> <file>` as a real role would, appends one record
{n, argv, cwd, pid, parse_rc, comment_rc} to FAKE_ROLE_DIR/log.jsonl, sleeps, prints the result event (unless
no_result) and exits with `exit`. A spawned child sleeps in the same process group; its pid goes to N.child.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def emit(obj):
    sys.stdout.write(json.dumps(obj) + '\n')
    sys.stdout.flush()


def arg_after(flag, default=None):
    argv = sys.argv
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else default


def report_text(spec):
    for name in (spec, spec + '.md'):
        p = HERE.parent / 'reports' / name
        if '/' not in name and p.is_file():
            return p.read_text()
    return spec


def main():
    d = Path(os.environ['FAKE_ROLE_DIR'])
    count = d / 'count'
    n = int(count.read_text()) + 1 if count.exists() else 1
    count.write_text('%d\n' % n)
    plan = {}
    for name in ('%d.json' % n, 'default.json'):
        if (d / name).exists():
            plan = json.loads((d / name).read_text())
            break
    agent = arg_after('--agent', '')
    role = os.environ.get('FAKE_ROLE_ROLE') or agent.split(':')[-1]
    card = os.environ.get('FAKE_ROLE_CARD', '1')
    scripts = Path(os.environ.get('FAKE_ROLE_SCRIPTS') or HERE.parents[1] / 'scripts')

    if plan.get('spawn_child'):
        code = 'import time; time.sleep(300)'
        if plan.get('child_ignore_term'):
            code = 'import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); ' + code
        child = subprocess.Popen([sys.executable, '-c', code])
        (d / ('%d.child' % n)).write_text('%d\n' % child.pid)
    if plan.get('ignore_term'):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if plan.get('stderr'):
        sys.stderr.write(plan['stderr'] + '\n')
        sys.stderr.flush()

    mode = plan.get('permission_mode') or arg_after('--permission-mode')
    for ev in plan.get('pre_events', []):
        emit(ev)
    if not plan.get('no_init'):
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'fake-%d' % n, 'model': arg_after('--model'),
              'permissionMode': mode})

    text = report_text(plan.get('report', ''))
    parse_rc = comment_rc = None
    if plan.get('post', True):
        with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as f:
            f.write(text)
        try:
            parse_rc = subprocess.run(['bash', str(scripts / 'parse-report.sh'), '--role', role, f.name],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            if parse_rc == 0:
                comment_rc = subprocess.run(['bash', str(scripts / 'board-comment.sh'), card, f.name],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        finally:
            os.unlink(f.name)
    with open(str(d / 'log.jsonl'), 'a') as log:
        log.write(json.dumps({'n': n, 'argv': sys.argv[1:], 'cwd': os.getcwd(), 'pid': os.getpid(),
                              'parse_rc': parse_rc, 'comment_rc': comment_rc}) + '\n')

    end = time.monotonic() + float(plan.get('sleep', 0))
    while time.monotonic() < end:
        time.sleep(0.1)

    if not plan.get('no_result'):
        event = {'type': 'result', 'subtype': plan.get('subtype', 'success'),
                 'is_error': bool(plan.get('is_error', False)), 'result': text, 'session_id': 'fake-%d' % n}
        if plan.get('usage'):
            event['usage'] = plan['usage']
        emit(event)
    return int(plan.get('exit', 0))


if __name__ == '__main__':
    sys.exit(main())
