"""Offline contract cases for the transactional supervisor store."""
import os
import concurrent.futures
import hashlib
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
        self.addCleanup(self.store.close)
        self.store.start_session({"id": "default", "started_at": 1, "deadline": 100,
                                  "known_spend": 0, "unknown_spend": False, "budget_stop": None})

    def test_reopen_retains_domain_state_and_events(self):
        before = self.store.snapshot()
        self.store.record_command({"id": "pause-1", "expected_revision": before["domain"]["revision"],
                                   "actor": "fixture", "command": "pause", "payload": {}})
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        reopened = other.snapshot()
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

    def test_default_inspector_accepts_real_local_scratch(self):
        other = Store.open(self.domain)
        other.close()

    def test_concurrent_first_open_creates_one_store(self):
        domain = dict(self.domain, board_identity="new-concurrent-domain")
        def open_store(_):
            store = Store.open(domain, filesystem_inspector=lambda path: "local")
            try:
                return store.snapshot()["domain"]["id"]
            finally:
                store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            ids = list(executor.map(open_store, range(8)))
        self.assertEqual(len(set(ids)), 1)

    def test_session_budget_survives_reopen(self):
        self.store.start_session({"id": "s1", "started_at": 1, "deadline": 100,
                                  "known_spend": 2.5, "unknown_spend": True,
                                  "budget_stop": "unknown"})
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        restored = other.snapshot()
        self.assertEqual(next(x for x in restored["sessions"] if x["id"] == "s1")["known_spend"], 2.5)
        self.assertTrue(next(x for x in restored["sessions"] if x["id"] == "s1")["unknown_spend"])
        self.assertEqual(next(x for x in restored["sessions"] if x["id"] == "s1")["budget_stop"], "unknown")

    def test_concurrent_same_card_admission_is_atomic(self):
        revision = self.store.snapshot()["domain"]["revision"]
        def admit(index):
            store = Store.open(self.domain, filesystem_inspector=lambda path: "local")
            job = {"id": "j" + str(index), "card": "1", "action": "review", "role": "reviewer",
                   "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
                   "generation": 1, "provider": "p" + str(index), "model": "m", "nonce": "n" + str(index), "session_id": "default"}
            try:
                store.prepare_attempt(job, revision, {"global_cap": 2, "provider_cap": 2, "paths": ["src"]})
                return True
            except ValueError:
                return False
            finally:
                store.close()
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
               "generation": 1, "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        revision = self.store.snapshot()["domain"]["revision"]
        self.store.prepare_attempt(job, revision, {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.prepare_attempt(dict(job, id="j2", card="2", nonce="n2"), before["domain"]["revision"],
                                       {"global_cap": 1, "provider_cap": 1, "paths": ["elsewhere"]})
        self.assertEqual(self.store.snapshot(), before)

    def test_result_replay_and_unknown_usage(self):
        self.store.start_session({"id": "s1", "started_at": 1, "deadline": 100,
                                  "known_spend": 0, "unknown_spend": False, "budget_stop": None})
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer",
               "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
               "generation": 1, "provider": "p", "model": "m", "nonce": "n1", "session_id": "s1"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        artifacts = self.store.directory / "artifacts" / "n1"
        artifacts.mkdir(parents=True, mode=0o700)
        report = artifacts / "report.json"
        report.write_text("{}")
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(report), "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                    "usage": None, "exit_code": 0}
        result = self.store.record_result(envelope)
        after = self.store.snapshot()
        self.assertTrue(next(x for x in after["sessions"] if x["id"] == "s1")["unknown_spend"])
        self.assertEqual(next(x for x in after["sessions"] if x["id"] == "s1")["known_spend"], 0)
        self.assertEqual(len(after["claims"]), 1)
        self.assertEqual(self.store.record_result(envelope), result)
        self.assertEqual(self.store.snapshot(), after)
        with self.assertRaises(ValueError):
            self.store.record_result(dict(envelope, outcome="failure"))
        self.assertEqual(self.store.snapshot(), after)

    def test_rejects_invalid_result_and_preserves_accounting(self):
        self.store.start_session({"id": "s1", "started_at": 1, "deadline": 100,
                                  "known_spend": 0, "unknown_spend": False, "budget_stop": None})
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "s1"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        artifacts = self.store.directory / "artifacts" / "n1"
        artifacts.mkdir(parents=True, mode=0o700)
        report = artifacts / "report.json"
        report.write_text("{}")
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(report), "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                    "usage": {"cost_usd": 1.5}, "exit_code": 0}
        before = self.store.snapshot()
        invalid = [dict(envelope, usage={"cost_usd": value}) for value in (True, -1, float("nan"), float("inf"))]
        invalid += [dict(envelope, domain_id="foreign"), dict(envelope, attempt_id="other"),
                    dict(envelope, generation=2), dict(envelope, input_sha="foreign"),
                    dict(envelope, artifact_hashes={str(report): "0" * 64})]
        link = artifacts / "escape"
        link.symlink_to(report)
        invalid.append(dict(envelope, report_path=str(link), artifact_hashes={str(link): hashlib.sha256(b"{}").hexdigest()}))
        invalid.append(dict(envelope, report_path=str(artifacts / ".." / "n1" / "report.json")))
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                self.store.record_result(item)
            self.assertEqual(self.store.snapshot(), before)
        self.store.record_result(envelope)
        self.assertEqual(next(x for x in self.store.snapshot()["sessions"] if x["id"] == "s1")["known_spend"], 1.5)
        self.store.record_result(envelope)
        self.assertEqual(next(x for x in self.store.snapshot()["sessions"] if x["id"] == "s1")["known_spend"], 1.5)

    def test_result_rejects_symlinked_artifact_root_and_spend_overflow(self):
        self.store.start_session({"id": "large", "started_at": 1, "deadline": 100,
                                  "known_spend": 1e308, "unknown_spend": False, "budget_stop": None})
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "large"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        report = outside / "report.json"
        report.write_text("{}")
        artifact_parent = self.store.directory / "artifacts"
        artifact_parent.mkdir(mode=0o700)
        (artifact_parent / "n1").symlink_to(outside, target_is_directory=True)
        artifact = artifact_parent / "n1" / "report.json"
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(artifact), "artifact_hashes": {str(artifact): hashlib.sha256(b"{}").hexdigest()},
                    "usage": {"cost_usd": 1e308}, "exit_code": 0}
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.record_result(envelope)
        (artifact_parent / "n1").unlink()
        (artifact_parent / "n1").mkdir(mode=0o700)
        artifact.write_text("{}")
        with self.assertRaises(ValueError):
            self.store.record_result(envelope)
        self.assertEqual(self.store.snapshot(), before)

    def test_admission_rejects_missing_session_and_unsafe_nonce(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        before = self.store.snapshot()
        for candidate in (dict(job, session_id="missing"), dict(job, nonce="../escape")):
            with self.assertRaises(ValueError):
                self.store.prepare_attempt(candidate, before["domain"]["revision"],
                                           {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
            self.assertEqual(self.store.snapshot(), before)

    def test_conflicts_are_checked_after_revision_refresh(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p1", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 4, "provider_cap": 4, "paths": ["src/a"], "merge_lane": True})
        for candidate, claims in [
            (dict(job, id="j2", nonce="n2", provider="p2"), {"global_cap": 4, "provider_cap": 4, "paths": ["else"]}),
            (dict(job, id="j2", nonce="n2", card="2"), {"global_cap": 4, "provider_cap": 4, "paths": ["else"], "merge_lane": True}),
            (dict(job, id="j2", nonce="n2", card="2"), {"global_cap": 4, "provider_cap": 4, "paths": ["src/a/b"]}),
        ]:
            before = self.store.snapshot()
            with self.assertRaises(ValueError):
                self.store.prepare_attempt(candidate, before["domain"]["revision"], claims)
            self.assertEqual(self.store.snapshot(), before)

    def test_retry_tombstone_and_effect_intent_reopen(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 2, "provider_cap": 2, "paths": ["src"]})
        self.store.increment_retry("j1", self.store.snapshot()["domain"]["revision"])
        self.store.record_effect({"operation_key": "op1", "job_id": "j1", "generation": 1,
                                  "preconditions": {"head": "abc"}, "intent": {"kind": "merge"}})
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        snapshot = other.snapshot()
        self.assertEqual(snapshot["jobs"][0]["retries_used"], 1)
        self.assertEqual(snapshot["effects"][0]["operation_key"], "op1")
        with self.assertRaises(ValueError):
            other.increment_retry("j1", snapshot["domain"]["revision"])
        with self.assertRaises(ValueError):
            other.record_effect({"operation_key": "op1", "job_id": "j1", "generation": 1,
                                 "preconditions": {}, "intent": {"kind": "other"}})
        self.assertEqual(other.snapshot(), snapshot)

    def test_backup_includes_uncheckpointed_commits(self):
        self.store.append_event({"type": "fixture", "payload": {"value": 7}})
        destination = self.root / "backup.sqlite3"
        self.store.backup(destination)
        import sqlite3
        backup = sqlite3.connect(str(destination))
        try:
            self.assertEqual(backup.execute("SELECT type FROM events ORDER BY sequence DESC LIMIT 1").fetchone()[0], "fixture")
        finally:
            backup.close()
        with self.assertRaises(ValueError):
            self.store.backup(self.store.directory / "store.sqlite3")

    def test_rejects_nonlocal_storage(self):
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "remote")


if __name__ == "__main__":
    unittest.main()
