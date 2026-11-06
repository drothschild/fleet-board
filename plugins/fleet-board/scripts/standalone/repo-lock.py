#!/usr/bin/env python3
"""Hold a nonblocking per-repository advisory lock across controller exec."""
import fcntl
import os
import stat
import sys


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def checked_fd(fd, path):
    try:
        actual = os.fstat(fd)
        expected = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(actual.st_mode) or (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            fail("invalid standalone repository lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, ValueError):
        fail("another standalone tick holds the repository lock")


if len(sys.argv) < 3:
    fail("invalid standalone lock invocation")
mode, path = sys.argv[1:3]
if mode == "verify":
    try:
        fd = int(os.environ["FLEET_BOARD_REPO_LOCK_FD"])
    except (KeyError, ValueError):
        fail("invalid standalone repository lock")
    checked_fd(fd, path)
elif mode == "acquire" and len(sys.argv) >= 5:
    try:
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags, 0o600)
        checked_fd(fd, path)
        os.set_inheritable(fd, True)
        env = os.environ.copy()
        env["FLEET_BOARD_REPO_LOCK_FD"] = str(fd)
        os.execve("/bin/bash", ["bash", *sys.argv[3:]], env)
    except OSError as error:
        fail("cannot acquire standalone repository lock: " + str(error))
else:
    fail("invalid standalone lock invocation")
