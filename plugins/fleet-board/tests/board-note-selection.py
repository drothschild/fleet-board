import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('board_web', Path(__file__).parent / '../scripts/board-web.py')
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'cards').mkdir()
    marker = web.MARKER + '\n'
    cases = [
        ([{'id': 1, 'author': 'tester', 'body': marker + 'first'},
          {'id': 2, 'author': 'tester', 'body': marker + 'last'},
          {'id': 3, 'author': 'other', 'body': marker + 'untrusted'}], 2, 'last'),
        ([{'id': 4, 'author': 'other', 'body': marker + 'untrusted'}], None, None),
        ([], None, None),
    ]
    for comments, expected_id, expected_body in cases:
        (root / 'cards/4.json').write_text(json.dumps({'number': 4, 'comments': comments}))
        with patch.dict(os.environ, {'FLEET_BOARD_USER': 'tester'}), patch.object(web, 'ctx', return_value=({'board': {'repo': 'acme/toy'}}, root)), patch.object(web, 'run_alive', return_value=False):
            status, detail = web.get_card({'n': 4}, None)
        assert status == 200
        assert detail['manager_note_id'] == expected_id, detail
        assert detail['manager_note'] == expected_body, detail
print('PASS card GET selects last local marker and returns null without a trusted marker')
