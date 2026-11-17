"""Resolve a card's checkout and that checkout's config.

One supervisor, the home repo's, runs every card. A card with no repo belongs to the home
checkout; a card naming a repo listed in board.repos belongs to that entry's path, whose own
.fleet-board.yml supplies test_paths, commands, merge and review.stages. Nothing here
writes a file.
"""
import re
import subprocess
from collections import namedtuple
from pathlib import Path

Resolution = namedtuple('Resolution', 'root config error')

_ORIGIN = re.compile(r'[:/]([^/:\s]+)/([^/\s]+?)(?:\.git)?/?$')


def origin_repo(path):
    """The owner/name of the checkout's origin remote, or None."""
    try:
        out = subprocess.run(['git', '-C', str(path), 'remote', 'get-url', 'origin'],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    m = _ORIGIN.search(out.stdout.strip())
    return '%s/%s' % (m.group(1), m.group(2)) if m else None


def resolve(home_root, home_config, repo, load_config):
    """Resolve `repo` (None for the home repo). `load_config(root)` returns the merged config
    of the checkout at root. Returns Resolution(root, config, error); error is None on success."""
    if repo is None:
        return Resolution(str(home_root), home_config, None)
    entries = (home_config.get('board') or {}).get('repos') or []
    entry = next((e for e in entries if str(e.get('repo', '')).lower() == str(repo).lower()), None)
    if entry is None:
        return Resolution(None, None, 'repo %s is not listed in board.repos' % repo)
    path = entry.get('path')
    if not path or not (Path(path) / '.fleet-board.yml').is_file():
        return Resolution(None, None, 'no .fleet-board.yml in %s (repo %s)' % (path, repo))
    actual = origin_repo(path)
    if actual is None or actual.lower() != str(repo).lower():
        return Resolution(None, None, 'checkout %s has origin %s, not %s' % (path, actual or 'none', repo))
    try:
        config = load_config(path)
    except Exception as exc:  # config.sh reports each problem; surface it with the path
        return Resolution(None, None, 'config of %s is invalid: %s' % (path, exc))
    return Resolution(path, config, None)
