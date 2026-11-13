"""Path-scope normalisation and overlap, shared by reservations and admission."""
from fnmatch import fnmatchcase
from pathlib import Path


def _clean(path):
    """The textual part of normalize(): `\\` to `/`, no leading `./`, no trailing `/`."""
    path = path.replace('\\', '/')
    while path.startswith('./'):
        path = path[2:]
    return path.rstrip('/')


def drop_ignored(paths, patterns):
    """Drop the paths matching a `supervisor.scope_ignore` glob (shell-style, case-sensitive).

    Both sides are cleaned like normalize() first. A scope whose every path is ignored is
    returned unchanged: an empty scope means the whole repository, which would reserve more.
    """
    paths = list(paths or [])
    if not patterns or not paths:
        return paths
    globs = [_clean(g) for g in patterns]
    kept = [p for p in paths if not (isinstance(p, str) and any(fnmatchcase(_clean(p), g) for g in globs))]
    return kept or paths


def normalize(paths, root):
    """Return the sorted, de-duplicated repo-relative scope for `paths`.

    `""` means the whole repository. Absolute paths, empty/`.`/`..` components and
    symlink components under `root` are refused.
    """
    if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
        raise ValueError('invalid scope')
    root = Path(root)
    normalized = set()
    for raw in paths:
        path = raw.replace('\\', '/')
        if path.startswith('/'):
            raise ValueError('invalid scope path')
        while path.startswith('./'):
            path = path[2:]
        path = path.rstrip('/')
        if path == '':
            normalized.add('')
            continue
        parts = path.split('/')
        if any(part in ('', '.', '..') for part in parts):
            raise ValueError('invalid scope path')
        cursor = root
        for part in parts:
            cursor = cursor / part
            if cursor.is_symlink():
                raise ValueError('symlink in scope')
        normalized.add('/'.join(parts))
    return sorted(normalized) or ['']


def _key(path):
    """ASCII-lowercase; non-ASCII is uncertain across filesystems, so reserve the repo."""
    return path.lower() if path.isascii() else ''


def overlap(a, b):
    """True if either scope is empty or whole-repo, or two paths nest (component-wise)."""
    if not a or not b:
        return True
    for left in a:
        x = _key(left)
        for right in b:
            y = _key(right)
            if not x or not y or x == y or x.startswith(y + '/') or y.startswith(x + '/'):
                return True
    return False
