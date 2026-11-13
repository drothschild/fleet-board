"""Publish the supervisor that owns a repository's run lock, while holding an advisory lock on a stable inode.

The supervisor (supervisor/service.py) runs this at startup; nothing else takes the lock."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def start_time(pid):
    result = subprocess.run(
        ["ps", "-o", "lstart=", "-p", pid],
        capture_output=True,
        text=True,
        env=dict(os.environ, LC_ALL="C", TZ="UTC"),
    )
    return " ".join(result.stdout.split())


def claim(path, pid, kind="run"):
    # Never unlink the guard. Another process may already have opened its inode.
    with open(str(path) + ".guard", "a") as guard:
        try:
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"another run is claiming {path}") from None

        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except FileNotFoundError:
            lines = []
        if lines and re.fullmatch(r"[1-9][0-9]*", lines[0]):
            owner = lines[0]
            recorded = lines[1] if len(lines) > 1 else ""
            actual = start_time(owner)
            if actual and (not recorded or actual == recorded):
                raise RuntimeError(f"another run holds {path} (pid {owner})")

        started = start_time(pid)
        if not started:
            raise RuntimeError(f"cannot read start time for pid {pid}")
        fd, temp = tempfile.mkstemp(dir=path.parent)
        try:
            with os.fdopen(fd, "w") as out:
                out.write(f"{pid}\n{started}\n")
                if kind == "service":
                    out.write("service\n")
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("pid")
    parser.add_argument("--kind", choices=("service",), default="run")
    args = parser.parse_args()
    try:
        claim(Path(args.path), args.pid, args.kind)
    except (OSError, RuntimeError) as exc:
        sys.exit(f"claim-run-lock: {exc}")
