#!/bin/bash
# Persona resolution: roles.resolve_persona(root, config) -> Persona(text, warnings).
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" <<'PY'
import sys, tempfile, os
from pathlib import Path
from supervisor import roles

plugin_dir = Path(sys.argv[1])
default = (plugin_dir / 'scripts/supervisor/defaults/merger-persona.md').read_text()
failed = 0


def check(name, cond, detail=''):
    global failed
    if cond:
        print('ok - ' + name)
    else:
        failed += 1
        print('not ok - ' + name + ' ' + detail)


def repo(files):
    root = Path(tempfile.mkdtemp())
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return root


def resolve(root, merge=None):
    return roles.resolve_persona(root, {'merge': merge or {}})


r = resolve(repo({}), {'persona': None, 'persona_append': None})
check('with neither key set and no .fleet-board/merger.md, the resolver returns the shipped default',
      r.text == default and r.warnings == [], repr(r)[:200])

r = resolve(repo({'.fleet-board/merger.md': 'LOCAL TEXT\n'}))
check('with no key set but a .fleet-board/merger.md, it returns that file text and nothing from the default',
      r.text == 'LOCAL TEXT\n' and default.strip().splitlines()[0] not in r.text, repr(r)[:200])

r = resolve(repo({'my/persona.md': 'CONFIGURED\n', '.fleet-board/merger.md': 'LOCAL\n'}),
            {'persona': 'my/persona.md'})
check('with merge.persona set, it returns that file text and nothing from the default',
      r.text == 'CONFIGURED\n' and r.warnings == [], repr(r)[:200])

r = resolve(repo({'extra.md': 'APPENDED\n'}), {'persona_append': 'extra.md'})
check('with merge.persona_append set, it returns the base persona followed by that file text',
      r.text.startswith(default) and r.text.endswith('APPENDED\n') and r.text.index('APPENDED') > len(default.rstrip()),
      repr(r)[:200])

r = resolve(repo({'p.md': 'REPLACEMENT\n', 'extra.md': 'APPENDED\n'}),
            {'persona': 'p.md', 'persona_append': 'extra.md'})
check('with both set, it returns the replacement followed by the appended text',
      r.text.startswith('REPLACEMENT') and r.text.index('APPENDED') > r.text.index('REPLACEMENT')
      and default.strip().splitlines()[0] not in r.text, repr(r)[:200])

r = resolve(repo({}), {'persona': 'nope/missing.md'})
check('a configured file that does not exist falls back to the default and returns a warning naming the path',
      r.text == default and len(r.warnings) == 1 and 'nope/missing.md' in r.warnings[0], repr(r)[:200])

sys.exit(1 if failed else 0)
PY
