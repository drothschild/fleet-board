"""Offline contract and isolation cases for production provider adapters."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from supervisor.inference_broker import (
    ContractError, InferenceBroker, ProviderRequest, run_provider,
    validate_result,
)
from supervisor.isolation import (
    IsolationUnavailable, build_policy, probe_capabilities, run_isolated,
)
from supervisor.runner import Runner
from supervisor.workers import request_scope_expansion


class ProviderCases(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="provider-case-")).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir(mode=0o700)
        self.request = ProviderRequest.create(
            attempt_id="attempt-1", generation=2, role="reviewer", stage=None,
            provider="fake", model="fake-v1", input_text="review this",
        )

    def tearDown(self):
        import shutil
        shutil.rmtree(self.root)

    def script(self, name, content):
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o700)
        return [str(path)]

    def test_versioned_contract_binds_exact_input_and_unknown_usage(self):
        self.assertEqual(self.request.schema_version, 1)
        self.assertEqual(self.request.input_sha,
                         hashlib.sha256(b"review this").hexdigest())
        command = self.script("reply.py", "#!/usr/bin/env python3\nimport json,sys\nr=json.load(sys.stdin)\nprint(json.dumps({'schema_version':1,'attempt_id':r['attempt_id'],'generation':r['generation'],'input_sha':r['input_sha'],'provider':r['provider'],'model':r['model'],'text':'clean','usage':None}))\n")
        result = run_provider(command, self.request, timeout=3)
        self.assertIsNone(result["usage"])
        self.assertEqual(result["input_sha"], self.request.input_sha)
        forged = dict(result, input_sha="0" * 64)
        with self.assertRaises(ContractError):
            validate_result(self.request, forged)

    def test_provider_selection_is_explicit_and_attempt_bound(self):
        broker = InferenceBroker({"fake": {"model": "fake-v1", "command": ["fake"]}})
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), provider=None))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), model="other"))
        with self.assertRaises(ContractError):
            broker.validate_request(dict(self.request.to_dict(), url="https://example.invalid"))

    def test_subprocess_stdout_stderr_are_bounded_and_missing_executable_fails(self):
        noisy = self.script("noisy.py", "#!/usr/bin/env python3\nimport sys\nsys.stdout.write('x'*4096)\nsys.stderr.write('y'*4096)\n")
        with self.assertRaises(ContractError):
            run_provider(noisy, self.request, timeout=3, stdout_limit=128, stderr_limit=128)
        with self.assertRaises(ContractError):
            run_provider([str(self.root / "missing")], self.request, timeout=1)

    def test_deadline_and_cancellation_stop_the_provider_process_group(self):
        slow = self.script("slow.py", "#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n")
        start = time.monotonic()
        with self.assertRaises(ContractError):
            run_provider(slow, self.request, timeout=0.1)
        self.assertLess(time.monotonic() - start, 3)
        with self.assertRaises(ContractError):
            run_provider(slow, self.request, timeout=5, cancel_after=0.1)

    def test_policy_limits_worker_paths_and_production_launch_fails_closed(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        self.assertIn("deny", policy["text"])
        self.assertTrue(policy["backend"] in ("macos", "linux"))
        escape = self.workspace / "escape"
        escape.symlink_to(self.root)
        with self.assertRaises(ValueError):
            build_policy(escape, self.root / "private-git", self.root / "channels")
        capability = probe_capabilities(policy)
        if not capability["available"]:
            with self.assertRaises(IsolationUnavailable):
                run_isolated(["/usr/bin/true"], policy, capability=capability)
            runner = Runner(self.root / "runner")
            with self.assertRaises(IsolationUnavailable):
                runner.launch_production({"attempt_id": "attempt-1"}, ["/usr/bin/true"], policy)

    def test_fixture_and_human_control_authority_are_not_worker_capabilities(self):
        policy = build_policy(self.workspace, self.root / "private-git",
                              self.root / "channels")
        for forbidden in ("controller.db", "board", "credentials", "ssh", "keychain", "publish", "human-control"):
            self.assertNotIn(forbidden, policy["channels"])

    def test_scope_expansion_conflict_checkpoints_and_releases_slot_without_retry(self):
        class Store:
            def expand_scope(self, card, paths, revision):
                raise ValueError("scope conflict with #23")
        calls = []
        result = request_scope_expansion(
            Store(), 22, ["src"], 4, lambda: calls.append("checkpoint"),
            lambda: calls.append("release"),
        )
        self.assertEqual(calls, ["checkpoint", "release"])
        self.assertTrue(result["attempt_should_exit"])
        self.assertFalse(result["retry_penalty"])
        self.assertEqual(result["waiting_on"], "23")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.argv.pop(1)  # shell harness supplies a private scratch directory
    unittest.main()
