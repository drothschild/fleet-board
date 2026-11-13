"""Path-scope normalisation and overlap, shared by reservations and admission."""
import re
from pathlib import Path

# Path globs. scripts/path-glob.jq is the jq twin used by tick-plan.sh and
# update-branch.sh: it builds the same regex string (scheduler_cases.py checks the
# two agree on fixtures/glob-cases.json). Change both together.
_META = '\\.^$*+?()[]{}|'


def _clean(path):
    """The textual part of normalize(): `\\` to `/`, no leading `./`, no trailing `/`."""
    path = path.replace('\\', '/')
    while path.startswith('./'):
        path = path[2:]
    return path.rstrip('/')


def _seg_regex(seg):
    out, i, n = [], 0, len(seg)
    while i < n:
        ch = seg[i]
        if ch == '*':
            out.append('[^/]*')
        elif ch == '?':
            out.append('[^/]')
        elif ch == '[':
            s = i + 2 if i + 1 < n and seg[i + 1] == '!' else i + 1
            s2 = s + 1 if s < n and seg[s] == ']' else s
            e = seg.find(']', s2)
            if e < 0:
                out.append('\\[')
            else:
                body = ''.join('\\' + c if c in '\\[]^' else c for c in seg[s:e])
                out.append('[' + ('^/' if s == i + 2 else '') + body + ']')
                i = e
        elif ch in _META:
            out.append('\\' + ch)
        else:
            out.append(ch)
        i += 1
    return ''.join(out)


def glob_regex(pattern):
    """An unanchored regex for a repo-relative glob, matched one segment at a time:
    `*`, `?` and `[...]` stay inside a segment, a `**` segment spans zero or more."""
    segs = _clean(pattern).split('/')
    out, sep = '', False
    for k, seg in enumerate(segs):
        if seg == '**':
            if k == len(segs) - 1 and not sep:
                out += '.*'
            elif sep:
                out += '(?:/[^/]+)*'
            else:
                out += '(?:[^/]+/)*'
        else:
            if sep:
                out += '/'
            out += _seg_regex(seg)
            sep = True
    return out


def glob_match(pattern, path):
    return re.fullmatch(glob_regex(pattern), _clean(path)) is not None


def drop_ignored(paths, patterns):
    """Drop the paths matching a `supervisor.scope_ignore` glob (case-sensitive).

    Both sides are cleaned like normalize() first. A scope whose every path is ignored is
    returned unchanged: an empty scope means the whole repository, which would reserve more.
    """
    paths = list(paths or [])
    if not patterns or not paths:
        return paths
    rx = [re.compile(glob_regex(g)) for g in patterns]
    kept = [p for p in paths if not (isinstance(p, str) and any(r.fullmatch(_clean(p)) for r in rx))]
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
