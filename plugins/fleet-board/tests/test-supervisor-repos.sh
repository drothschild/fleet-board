#!/bin/bash
# The supervisor resolves each card's checkout and that checkout's config.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - <<'PY'
import subprocess, sys, tempfile, os
from supervisor import repos

failed = []

def check(name, ok, detail=''):
    print(('ok   ' if ok else 'FAIL ') + name + ('' if ok else ' ' + str(detail)))
    if not ok:
        failed.append(name)

def checkout(origin, with_config=True):
    d = tempfile.mkdtemp()
    subprocess.run(['git', '-C', d, 'init', '-q'], check=True)
    if origin:
        subprocess.run(['git', '-C', d, 'remote', 'add', 'origin', origin], check=True)
    if with_config:
        open(os.path.join(d, '.fleet-board.yml'), 'w').write('x: 1\n')
    return d

home = tempfile.mkdtemp()
home_cfg = {'name': 'home', 'board': {'repo': 'acme/home', 'repos': []}}
good = checkout('https://github.com/acme/widgets.git')
noconf = checkout('git@github.com:acme/noconf.git', with_config=False)
wrong = checkout('https://github.com/acme/other.git')
cfg = {'board': {'repo': 'acme/home', 'repos': [
    {'repo': 'acme/widgets', 'path': good},
    {'repo': 'acme/noconf', 'path': noconf},
    {'repo': 'acme/mismatch', 'path': wrong}]}}
loaded = []
def loader(root):
    loaded.append(root)
    return {'name': 'cfg-of-' + root}

r = repos.resolve(home, cfg, None, loader)
check('A card with repo: null resolves to the home root and the home config',
      r.error is None and r.root == home and r.config is cfg, vars(r))

r = repos.resolve(home, cfg, 'acme/widgets', loader)
check('A card with a listed repo resolves to its path and that checkout\'s .fleet-board.yml',
      r.error is None and r.root == good and r.config == {'name': 'cfg-of-' + good}, vars(r))

r = repos.resolve(home, cfg, 'acme/noconf', loader)
check('A listed repo whose path has no .fleet-board.yml returns an error naming the path',
      r.error is not None and noconf in r.error, vars(r))

r = repos.resolve(home, cfg, 'acme/mismatch', loader)
check('A listed repo whose checkout origin is not that repo returns an error',
      r.error is not None and 'acme/mismatch' in r.error, vars(r))
sys.exit(1 if failed else 0)
PY
