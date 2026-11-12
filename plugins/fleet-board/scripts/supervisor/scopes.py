"""Path-scope normalisation and overlap, shared by reservations and admission."""
from pathlib import Path


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
        while path.startswith('./'):
            path = path[2:]
        path = path.rstrip('/')
        if path == '':
            normalized.add('')
            continue
        parts = path.split('/')
        if path.startswith('/') or any(part in ('', '.', '..') for part in parts):
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
