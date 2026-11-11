"""The one bounded runner through which the supervisor calls plugin scripts."""
import os
import signal
import subprocess
from collections import namedtuple
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent

ALLOWED = frozenset((
    'tick-plan.sh', 'board-read.sh', 'board-move.sh', 'board-comment.sh', 'note.sh', 'worktree.sh',
    'update-branch.sh', 'review-stages.sh', 'merge-reviewed.sh', 'verify-main.sh', 'after-merge.sh',
    'parse-report.sh', 'file-followups.sh', 'human-qa-handoff.sh', 'stage-review.sh',
    'evidence-review.sh', 'config.sh', 'deps.sh',
))

ScriptResult = namedtuple('ScriptResult', 'rc stdout stderr timed_out')


def run(root, name, *args, timeout=600, stdin=None, env=None):
    """Run `bash <scripts>/<name> args...` in `root`; a timeout kills the whole process group (rc 124)."""
    if name not in ALLOWED:
        raise ValueError('script not allowed: ' + repr(name))
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    proc = subprocess.Popen(['bash', str(SCRIPTS_DIR / name)] + [str(a) for a in args], cwd=str(root),
                            env=full_env, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    try:
        out, err = proc.communicate(stdin, timeout=timeout)
        return ScriptResult(proc.returncode, out or '', err or '', False)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, err = proc.communicate()
        return ScriptResult(124, out or '', err or '', True)
