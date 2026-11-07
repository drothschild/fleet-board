"""Offline contract cases for the transactional supervisor store."""
import os
import concurrent.futures
import sys
import unittest
from pathlib import Path

ROOT = Path(sys.argv.pop()).resolve()

try:
    from supervisor.store import Store
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.store"):
        raise
    Store = None


class StoreContract(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(Store, "transactional supervisor store is not implemented")
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {
            "common_dir": str(self.root), "board_backend": "local",
            "board_identity": "fixture", "runtime_root": str(self.root / "runtime"),
        }
        self.store = Store.open(self.domain, filesystem_inspector=lambda path: "local")

    def test_reopen_retains_domain_state_and_events(self):
        before = self.store.snapshot()
        self.store.record_command({"id": "pause-1", "expected_revision": before["domain"]["revision"],
                                   "actor": "fixture", "command": "pause", "payload": {}})
        reopened = Store.open(self.domain, filesystem_inspector=lambda path: "local").snapshot()
        self.assertEqual(reopened["domain"]["desired_mode"], "paused")
        self.assertGreater(reopened["domain"]["revision"], before["domain"]["revision"])
        self.assertTrue(reopened["events"])

    def test_command_replay_does_not_advance_revision(self):
        revision = self.store.snapshot()["domain"]["revision"]
        request = {"id": "pause-1", "expected_revision": revision,
                   "actor": "fixture", "command": "pause", "payload": {}}
        outcome = self.store.record_command(request)
        after = self.store.snapshot()
        self.assertEqual(self.store.record_command(request), outcome)
        self.assertEqual(self.store.snapshot()["domain"]["revision"], after["domain"]["revision"])
        with self.assertRaises(ValueError):
            self.store.record_command(dict(request, command="stop"))

    def test_session_budget_survives_reopen(self):
        self.store.start_session({"id": "s1", "started_at": 1, "deadline": 100,
                                  "known_spend": 2.5, "unknown_spend": True,
                                  "budget_stop": "unknown"})
        restored = Store.open(self.domain, filesystem_inspector=lambda path: "local").snapshot()
        self.assertEqual(restored["sessions"][0]["known_spend"], 2.5)
        self.assertTrue(restored["sessions"][0]["unknown_spend"])
        self.assertEqual(restored["sessions"][0]["budget_stop"], "unknown")

    def test_concurrent_same_card_admission_is_atomic(self):
        revision = self.store.snapshot()["domain"]["revision"]
        def admit(index):
            store = Store.open(self.domain, filesystem_inspector=lambda path: "local")
            job = {"id": "j" + str(index), "card": "1", "action": "review", "role": "reviewer",
                   "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
                   "generation": 1, "provider": "p" + str(index), "model": "m", "nonce": "n" + str(index)}
            try:
                store.prepare_attempt(job, revision, {"global_cap": 2, "provider_cap": 2, "paths": ["src"]})
                return True
            except ValueError:
                return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(admit, (1, 2)))
        self.assertEqual(sum(outcomes), 1)
        snapshot = self.store.snapshot()
        self.assertEqual(len(snapshot["attempts"]), 1)
        self.assertEqual(len(snapshot["jobs"]), 1)
        self.assertEqual(len(snapshot["claims"]), 1)
        self.assertEqual(snapshot["domain"]["revision"], revision + 1)

    def test_admission_conflict_rolls_back_job_and_event(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer",
               "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
               "generation": 1, "provider": "p", "model": "m", "nonce": "n1"}
        revision = self.store.snapshot()["domain"]["revision"]
        self.store.prepare_attempt(job, revision, {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.prepare_attempt(dict(job, id="j2", card="2", nonce="n2"), before["domain"]["revision"],
                                       {"global_cap": 1, "provider_cap": 1, "paths": ["elsewhere"]})
        self.assertEqual(self.store.snapshot(), before)

    def test_rejects_nonlocal_storage(self):
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "remote")


if __name__ == "__main__":
    unittest.main()
