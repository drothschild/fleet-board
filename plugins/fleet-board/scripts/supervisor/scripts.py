"""The one bounded runner through which the supervisor calls plugin scripts."""
import os
import signal
import subprocess
import tempfile
from collections import namedtuple
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent

ALLOWED = frozenset((
    'tick-plan.sh', 'board-read.sh', 'board-move.sh', 'board-comment.sh', 'note.sh', 'worktree.sh',
    'update-branch.sh', 'review-stages.sh', 'merge-reviewed.sh', 'verify-main.sh', 'after-merge.sh',
    'parse-report.sh', 'file-followups.sh', 'human-qa-handoff.sh', 'stage-review.sh',
    'evidence-review.sh', 'config.sh', 'deps.sh',
))

POST_KILL_WAIT = 5
OUTPUT_CAP = 65536   # bytes of a spawned child's stdout and stderr read back (the tail)

ScriptResult = namedtuple('ScriptResult', 'rc stdout stderr timed_out')


def run(root, name, *args, timeout=600, stdin=None, env=None):
    """Run `bash <scripts>/<name> args...` in `root`; a timeout kills the whole process group (rc 124)."""
    if name not in ALLOWED:
        raise ValueError('script not allowed: ' + repr(name))
    return run_argv(root, ['bash', str(SCRIPTS_DIR / name)] + [str(a) for a in args],
                    timeout=timeout, stdin=stdin, env=env)


def run_argv(root, argv, timeout=600, stdin=None, env=None):
    """Run a fixed argv in `root` under the same bounds as `run`. Not allowlisted: the caller passes only
    commands it owns (`gh`, the configured qa_build), never a value taken from the board."""
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    proc = subprocess.Popen(argv, cwd=str(root), env=full_env,
                            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    try:
        try:
            out, err = proc.communicate(stdin, timeout=timeout)
            return ScriptResult(proc.returncode, out or '', err or '', False)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            try:
                out, err = proc.communicate(timeout=POST_KILL_WAIT)
            except subprocess.TimeoutExpired:
                # A descendant outside the group still holds the pipes; do not wait for it.
                out = err = ''
                for pipe in (proc.stdin, proc.stdout, proc.stderr):
                    try:
                        if pipe is not None:
                            pipe.close()
                    except (OSError, ValueError):
                        pass
            return ScriptResult(124, out or '', err or '', True)
    finally:
        # Any exception (KeyboardInterrupt included) must not leave the child's group running.
        if proc.poll() is None:
            _kill_group(proc)
            try:
                proc.wait(timeout=POST_KILL_WAIT)
            except subprocess.TimeoutExpired:
                pass


def _kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


class Spawned:
    """A child that runs without blocking its caller: its own process group, output in anonymous temp files
    (so a chatty child never fills a pipe), read back capped when it ends. Nothing here ever kills it."""

    def __init__(self, proc, out, err):
        self.proc, self._out, self._err = proc, out, err

    @property
    def pid(self):
        return self.proc.pid

    def poll(self):
        rc = self.proc.poll()
        if rc is None:
            return None
        texts = []
        for handle in (self._out, self._err):
            try:
                size = handle.seek(0, os.SEEK_END)
                handle.seek(max(0, size - OUTPUT_CAP))
                texts.append(handle.read().decode('utf-8', 'replace'))
            except (OSError, ValueError):
                texts.append('')
            finally:
                handle.close()
        return ScriptResult(rc, texts[0], texts[1], False)


def spawn(root, name, *args, env=None):
    """Start `bash <scripts>/<name> args...` in `root` and return at once with a Spawned handle."""
    if name not in ALLOWED:
        raise ValueError('script not allowed: ' + repr(name))
    return spawn_argv(root, ['bash', str(SCRIPTS_DIR / name)] + [str(a) for a in args], env=env)


def spawn_argv(root, argv, env=None):
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    out, err = tempfile.TemporaryFile(), tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen(argv, cwd=str(root), env=full_env, stdin=subprocess.DEVNULL, stdout=out,
                                stderr=err, start_new_session=True)
    except BaseException:
        out.close()
        err.close()
        raise
    return Spawned(proc, out, err)
