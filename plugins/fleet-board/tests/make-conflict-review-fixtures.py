"""Create real merge commits for a reviewer contract exercise in a scratch repo."""
import json
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=False)
def git(*args, check=True):
    return subprocess.run(['git', '-C', str(root), *args], text=True, capture_output=True, check=check)
def commit(message):
    git('add', '.')
    git('commit', '-qm', message)
    return git('rev-parse', 'HEAD').stdout.strip()
git('init', '-q', '-b', 'fixture-base')
git('config', 'user.name', 'Fixture')
git('config', 'user.email', 'fixture@example.invalid')
(root / 'calc.py').write_text('def value(x):\n    return x\n')
base_test = 'from calc import value\nassert value(0) == 0\n\n\n\n\n\n\n\n\nassert value(9) == 9\n'
(root / 'test_calc.py').write_text(base_test)
base = commit('Fixture base')
git('checkout', '-qb', 'left')
(root / 'test_calc.py').write_text(base_test.replace('assert value(0) == 0', 'assert value(0) == 0\nassert value(1) == 1'))
left = commit('Left adds assertion')
git('checkout', '-qb', 'right', base)
(root / 'test_calc.py').write_text(base_test.replace('assert value(0) == 0', 'assert value(0) == 0\nassert value(2) == 2'))
right = commit('Right adds assertion')
valid = base_test.replace('assert value(0) == 0', 'assert value(0) == 0\nassert value(1) == 1\nassert value(2) == 2')
variants = [valid, valid.replace('assert value(2) == 2\n', ''), valid.replace('assert value(9) == 9\n', '')]
cases = []
for index, text in enumerate(variants):
    name = 'candidate_' + str(index + 1)
    git('checkout', '-qb', name, left)
    result = git('merge', '--no-commit', right, check=False)
    assert result.returncode == 1
    assert '<<<<<<<' in (root / 'test_calc.py').read_text()
    (root / 'test_calc.py').write_text(text)
    head = commit('Resolve fixture merge')
    cases.append({'name': name, 'head': head, 'reference_sha': left, 'parents': [left, right],
                  'latest_report_role': 'fixer', 'test_command': 'python3 test_calc.py',
                  'mutation_enabled': True})
(root / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
print(root)
