#!/bin/bash
# A merger session's input carries the saved refusal (refusal mode) and a hash of the persona resolved for it.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/merger-persona-hash.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import hashlib
import sys
import unittest

plugin_dir, base = sys.argv[1], sys.argv[2]
sys.argv = [sys.argv[0], base]
sys.path.insert(0, plugin_dir + '/fixtures/supervisor')
import merging_cases as mc  # noqa: E402


class PersonaHash(mc.MergerFlow):
    def persona_and_hash(self, prompt):
        text = prompt.split('## Persona\n', 1)[1].split('\n\n## Persona hash\n', 1)
        return text[0], (text[1].split('\n', 1)[0] if len(text) > 1 else None)

    def test_a_merger_session_input_includes_a_hash_of_the_resolved_persona_after_merge(self):
        self.merger('merged', mc.MERGED, 'merger-after-merge-done')
        persona, shown = self.persona_and_hash(self.b.prompt(1))
        self.assertEqual(shown, hashlib.sha256(persona.encode()).hexdigest())

    def test_a_merger_session_input_includes_a_hash_of_the_resolved_persona_in_refusal_mode(self):
        self.merger('refused', self.refused(), 'merger-refusal-attention')
        persona, shown = self.persona_and_hash(self.b.prompt(1))
        self.assertEqual(shown, hashlib.sha256(persona.encode()).hexdigest())

    def test_a_merger_session_input_includes_the_saved_refusal_in_refusal_mode(self):
        self.merger('refused', self.refused(required_check='build'), 'merger-refusal-attention')
        prompt = self.b.prompt(1)
        self.assertIn('## Mode\nrefusal', prompt)
        self.assertIn('## Refusal\n', prompt)
        self.assertIn('"required_check": "build"', prompt)


suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(PersonaHash))
suite = unittest.TestSuite(t for t in suite if t.id().rsplit('.', 1)[-1] in {
    'test_a_merger_session_input_includes_a_hash_of_the_resolved_persona_after_merge',
    'test_a_merger_session_input_includes_a_hash_of_the_resolved_persona_in_refusal_mode',
    'test_a_merger_session_input_includes_the_saved_refusal_in_refusal_mode'})
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
