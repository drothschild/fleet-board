#!/bin/bash
# The merge lane's required-check lookup passes the card's repo to `gh pr checks`, not the home repo.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 -I - "$plugin_dir" <<'PY'
import json, sys, unittest
sys.path.insert(0, sys.argv[1] + '/scripts')
from supervisor import merging, scripts


class Done:
    def __init__(self, out):
        self.stdout, self.stderr, self.rc, self.timed_out = out, '', 1, False


class RequiredCheckRepo(unittest.TestCase):
    def lookup(self, candidate, home='acme/toy'):
        calls = []

        def gh(root, *args):
            calls.append(args)
            return Done(json.dumps([{'name': 'build', 'bucket': 'fail'}]))

        lane = merging.MergeLane('/tmp', None, gh=gh, repo=home)
        return lane._required_check(candidate), calls

    def test_required_check_lookup_uses_the_cards_repo(self):
        name, calls = self.lookup({'pr': 34, 'repo': 'other/repo'})
        self.assertEqual(name, 'build')
        self.assertEqual(calls[0][3:5], ('--repo', 'other/repo'))

    def test_required_check_lookup_falls_back_to_the_home_repo_without_a_card_repo(self):
        name, calls = self.lookup({'pr': 34})
        self.assertEqual(name, 'build')
        self.assertEqual(calls[0][3:5], ('--repo', 'acme/toy'))


unittest.main(argv=['x'], verbosity=1)
PY
