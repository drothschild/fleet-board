import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from supervisor.processes import ProcessIdentity, identity_for, inspect_identity
from supervisor.runner import Runner


def test_identity():
    identity = identity_for(os.getpid(), 'testnonce')
    assert identity.nonce == 'testnonce'
    assert inspect_identity(identity) == 'alive'
    assert inspect_identity(ProcessIdentity(identity.boot_id, identity.pid, 'wrong', identity.nonce)) == 'unknown'
    assert inspect_identity(ProcessIdentity('wrong', identity.pid, identity.started_at, identity.nonce)) == 'unknown'


def test_production_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            Runner(pathlib.Path(tmp)).launch({'attempt_id': 'attempt', 'nonce': 'nonce'})
        except (ValueError, NotImplementedError):
            pass
        else:
            raise AssertionError('production launch must fail closed')


test_identity()
test_production_fails_closed()
print('runner identity tests passed')
