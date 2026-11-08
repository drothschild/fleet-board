"""Offline contract cases for the transactional supervisor store."""
import os
import concurrent.futures
import hashlib
import json
import threading
import sys
import unittest
from unittest import mock
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

    def test_stale_result_is_evidence_and_charged_once(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.store.revoke_generation("j1", self.store.snapshot()["domain"]["revision"])
        root = self.store.directory / "artifacts" / "n1"
        root.mkdir(parents=True, mode=0o700)
        report = root / "report.json"
        report.write_text("{}")
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(report), "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                    "usage": {"cost_usd": 2}, "exit_code": 0}
        self.assertEqual(self.store.record_result(envelope)["disposition"], "stale")
        before = self.store.snapshot()
        self.assertEqual(before["jobs"][0]["generation"], 2)
        self.assertEqual(before["jobs"][0]["state"], "active")
        self.assertEqual(before["sessions"][0]["known_spend"], 2)
        self.store.record_result(envelope)
        self.assertEqual(self.store.snapshot(), before)

    def test_capacity_and_nonoverlap_across_connections(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 2, "provider_cap": 2, "paths": ["src/a"]})
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        candidate = dict(job, id="j2", nonce="n2", card="2")
        for caps in ({"global_cap": 1, "provider_cap": 2, "paths": ["src/ab"]},
                     {"global_cap": 2, "provider_cap": 1, "paths": ["src/ab"]}):
            before = other.snapshot()
            with self.assertRaises(ValueError):
                other.prepare_attempt(candidate, before["domain"]["revision"], caps)
            self.assertEqual(other.snapshot(), before)
        other.prepare_attempt(candidate, other.snapshot()["domain"]["revision"],
                              {"global_cap": 2, "provider_cap": 2, "paths": ["src/ab"]})
        self.assertEqual(len(self.store.snapshot()["claims"]), 2)

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

    def test_desired_modes_reopen_with_same_budget(self):
        for sequence, command, expected in ((1, "start", "running"), (2, "pause", "paused"), (3, "stop", "stopped")):
            self.store.record_command({"id": str(sequence), "expected_revision": self.store.snapshot()["domain"]["revision"],
                                       "actor": "fixture", "command": command, "payload": {}})
            other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
            try:
                snapshot = other.snapshot()
                self.assertEqual(snapshot["domain"]["desired_mode"], expected)
                self.assertEqual(snapshot["sessions"][0]["deadline"], 100)
            finally:
                other.close()

    def test_database_rejects_duplicate_job_keys_and_attempt_nonces(self):
        import sqlite3
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 2, "provider_cap": 2, "paths": ["src/a"]})
        before = self.store.snapshot()
        connection = sqlite3.connect(str(self.store.directory / "store.sqlite3"))
        try:
            connection.execute("PRAGMA foreign_keys=ON")
            statements = [
                ("INSERT INTO jobs SELECT ?,logical_key,card,generation,input_sha,role,stage,state,retries_used,data FROM jobs WHERE id=?", ("j2", "j1")),
                ("INSERT INTO jobs SELECT id,?,card,generation,input_sha,role,stage,state,retries_used,data FROM jobs WHERE id=?", ("new-key", "j1")),
                ("INSERT INTO attempts SELECT ?,job_id,nonce,provider,state,data FROM attempts WHERE id=?", ("n2", "n1")),
                ("INSERT INTO attempts SELECT id,job_id,?,provider,state,data FROM attempts WHERE id=?", ("new-nonce", "n1")),
            ]
            for sql, parameters in statements:
                with self.assertRaises(sqlite3.IntegrityError):
                    connection.execute(sql, parameters)
                connection.rollback()
                self.assertEqual(self.store.snapshot(), before)
        finally:
            connection.close()

    def test_scope_aliases_conflict_even_for_nonexistent_descendants(self):
        import json
        (self.root / "src").mkdir()
        (self.root / "src" / "file.py").write_text("fixture")
        pairs = [("src", "SRC/file.py"),
                 ("Missing/Tree", "missing/tree/new.py"),
                 ("Caf\u00e9", "CAFE\u0301/new.py")]
        for index, (first, alias) in enumerate(pairs):
            with self.subTest(first=first, alias=alias):
                domain = dict(self.domain, board_identity="alias-" + str(index))
                store = Store.open(domain, filesystem_inspector=lambda path: "local")
                try:
                    store.start_session({"id": "s", "started_at": 1, "deadline": 100,
                                         "known_spend": 0, "unknown_spend": False, "budget_stop": None})
                    job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
                           "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
                           "provider": "p", "model": "m", "nonce": "n1", "session_id": "s"}
                    store.prepare_attempt(job, store.snapshot()["domain"]["revision"],
                                          {"global_cap": 2, "provider_cap": 2, "paths": [first]})
                    before = store.snapshot()
                    self.assertEqual(json.loads(before["claims"][0]["paths"]), [first])
                    with self.assertRaises(ValueError):
                        store.prepare_attempt(dict(job, id="j2", card="2", nonce="n2"), before["domain"]["revision"],
                                              {"global_cap": 2, "provider_cap": 2, "paths": [alias]})
                    self.assertEqual(store.snapshot(), before)
                finally:
                    store.close()

    def test_duplicate_nonce_does_not_leave_partial_job(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 2, "provider_cap": 2, "paths": ["src/a"]})
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.prepare_attempt(dict(job, id="j2", card="2"), before["domain"]["revision"],
                                       {"global_cap": 2, "provider_cap": 2, "paths": ["src/b"]})
        self.assertEqual(self.store.snapshot(), before)

    def test_injected_failure_rolls_back_partial_admission(self):
        def fail(point):
            if point == "after_attempt":
                raise RuntimeError("injected failure")
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local", fault_injector=fail)
        self.addCleanup(other.close)
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        before = other.snapshot()
        with self.assertRaises(RuntimeError):
            other.prepare_attempt(job, before["domain"]["revision"],
                                  {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.assertEqual(other.snapshot(), before)

    def test_scope_rejects_symlink_escape(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "escape").symlink_to(outside, target_is_directory=True)
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.prepare_attempt(job, before["domain"]["revision"],
                                       {"global_cap": 1, "provider_cap": 1, "paths": ["escape/file"]})
        self.assertEqual(self.store.snapshot(), before)

    def test_effect_observation_is_durable_and_unique(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.store.record_effect({"operation_key": "op", "job_id": "j1", "generation": 1,
                                  "preconditions": {}, "intent": {"kind": "merge"}})
        self.store.observe_effect("op", {"result": "merged", "recovery_evidence": "commit"},
                                  self.store.snapshot()["domain"]["revision"])
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        import json
        effect = other.snapshot()["effects"][0]
        self.assertEqual(effect["status"], "observed")
        self.assertEqual(json.loads(effect["observation"])["recovery_evidence"], "commit")
        self.assertEqual(effect["card"], "1")

    def test_metadata_and_attempt_lifecycle_survive_reopen(self):
        self.store.configure_domain({"config_hash": "abc", "service_version": "1.2"},
                                    self.store.snapshot()["domain"]["revision"])
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default",
               "eligible_since": 123, "priority": 4, "input_revision": 7}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        details = {"state": "running", "boot_id": "boot", "process_identity": {"pid": 42},
                   "worktree": "/tmp/work", "started_at": 12, "deadline": 30,
                   "heartbeat": 13, "progress": {"step": 1}, "cancel_reason": None}
        self.store.update_attempt("n1", details, self.store.snapshot()["domain"]["revision"])
        other = Store.open(self.domain, filesystem_inspector=lambda path: "local")
        self.addCleanup(other.close)
        snapshot = other.snapshot()
        self.assertEqual(snapshot["domain"]["config_hash"], "abc")
        self.assertEqual(snapshot["domain"]["service_version"], "1.2")
        import json
        self.assertEqual(json.loads(snapshot["jobs"][0]["data"])["eligible_since"], 123)
        self.assertEqual(json.loads(snapshot["attempts"][0]["data"])["process_identity"], {"pid": 42})
        self.assertGreater(snapshot["claims"][0]["reservation_revision"], 0)

    def test_unsafe_runtime_directories_are_rejected(self):
        unsafe = self.root / "unsafe"
        unsafe.mkdir(mode=0o755)
        unsafe.chmod(0o755)
        with self.assertRaises(ValueError):
            Store.open(dict(self.domain, runtime_root=str(unsafe)), filesystem_inspector=lambda path: "local")
        link = self.root / "link"
        link.symlink_to(self.root / "runtime", target_is_directory=True)
        with self.assertRaises(ValueError):
            Store.open(dict(self.domain, runtime_root=str(link)), filesystem_inspector=lambda path: "local")
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "unknown")

    def test_populated_unversioned_store_fails_closed(self):
        import sqlite3
        database = self.store.directory / "store.sqlite3"
        self.store.close()
        connection = sqlite3.connect(str(database))
        connection.execute("PRAGMA user_version=0")
        connection.close()
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "local")
        connection = sqlite3.connect(str(database))
        try:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM domain").fetchone()[0], 1)
        finally:
            connection.close()

    def test_missing_schema_constraints_fail_closed_without_writes(self):
        import sqlite3
        definitions = [
            "id TEXT, job_id TEXT NOT NULL REFERENCES jobs(id), nonce TEXT UNIQUE NOT NULL, provider TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL",
            "id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), nonce TEXT NOT NULL, provider TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL",
            "id TEXT PRIMARY KEY, job_id TEXT NOT NULL, nonce TEXT UNIQUE NOT NULL, provider TEXT NOT NULL, state TEXT NOT NULL, data TEXT NOT NULL",
            "id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id), nonce TEXT UNIQUE NOT NULL, provider TEXT, state TEXT NOT NULL, data TEXT NOT NULL",
        ]
        for index, definition in enumerate(definitions):
            with self.subTest(constraint=index):
                domain = dict(self.domain, board_identity="tampered-" + str(index))
                store = Store.open(domain, filesystem_inspector=lambda path: "local")
                database = store.directory / "store.sqlite3"
                before = store.snapshot()
                store.close()
                connection = sqlite3.connect(str(database))
                connection.execute("DROP TABLE attempts")
                connection.execute("CREATE TABLE attempts (" + definition + ")")
                connection.commit()
                original = connection.execute("SELECT * FROM domain").fetchall()
                connection.close()
                with self.assertRaises(ValueError):
                    opened = Store.open(domain, filesystem_inspector=lambda path: "local")
                    opened.close()
                connection = sqlite3.connect(str(database))
                try:
                    self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
                    self.assertEqual(connection.execute("SELECT * FROM domain").fetchall(), original)
                    self.assertEqual(connection.execute("SELECT count(*) FROM events").fetchone()[0], len(before["events"]))
                finally:
                    connection.close()

    def test_corrupt_schema_fails_closed(self):
        import sqlite3
        database = self.store.directory / "store.sqlite3"
        self.store.close()
        connection = sqlite3.connect(str(database))
        connection.execute("DROP TABLE claims")
        connection.commit()
        connection.close()
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "local")

    def test_racing_capacity_rechecks_after_revision_change(self):
        for cap_type in ("global_cap", "provider_cap"):
            domain = dict(self.domain, board_identity=cap_type)
            initial = Store.open(domain, filesystem_inspector=lambda path: "local")
            initial.start_session({"id": "default", "started_at": 1, "deadline": 100,
                                   "known_spend": 0, "unknown_spend": False, "budget_stop": None})
            initial.close()
            barrier = threading.Barrier(2)
            def admit(index):
                store = Store.open(domain, filesystem_inspector=lambda path: "local")
                try:
                    job = {"id": "j" + str(index), "card": str(index), "action": "review", "role": "reviewer",
                           "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
                           "generation": 1, "provider": "p", "model": "m", "nonce": "n" + str(index), "session_id": "default"}
                    revision = store.snapshot()["domain"]["revision"]
                    claims = {"global_cap": 2, "provider_cap": 2, "paths": ["src/" + str(index)]}
                    claims[cap_type] = 1
                    barrier.wait()
                    try:
                        store.prepare_attempt(job, revision, claims)
                        return True
                    except ValueError:
                        try:
                            store.prepare_attempt(job, store.snapshot()["domain"]["revision"], claims)
                            return True
                        except ValueError:
                            return False
                finally:
                    store.close()
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                self.assertEqual(sum(executor.map(admit, (1, 2))), 1)

    def test_future_schema_fails_closed_without_modification(self):
        import sqlite3
        database = self.store.directory / "store.sqlite3"
        self.store.close()
        with sqlite3.connect(str(database)) as connection:
            connection.execute("PRAGMA user_version=999")
        with self.assertRaises(ValueError):
            Store.open(self.domain, filesystem_inspector=lambda path: "local")
        connection = sqlite3.connect(str(database))
        try:
            self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 999)
            self.assertEqual(connection.execute("SELECT count(*) FROM domain").fetchone()[0], 1)
        finally:
            connection.close()

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


    def test_new_runtime_directory_entries_are_synced_before_open_returns(self):
        import supervisor.store as store_module
        root = self.root / "nested" / "runtime"
        domain = dict(self.domain, runtime_root=str(root), board_identity="durability")
        opened = {}
        synced = []
        real_open, real_fsync = os.open, os.fsync
        def tracked_open(path, flags, *args, **kwargs):
            fd = real_open(path, flags, *args, **kwargs)
            opened[fd] = str(path)
            return fd
        def tracked_fsync(fd):
            if fd in opened:
                synced.append(opened[fd])
            return real_fsync(fd)
        with mock.patch.object(store_module.os, 'open', tracked_open), mock.patch.object(store_module.os, 'fsync', tracked_fsync):
            other = Store.open(domain, filesystem_inspector=lambda _: 'local')
            other.close()
        # Each new directory entry is flushed through its parent, including
        # the domain entry that contains the database.
        self.assertIn(str(self.root), synced)
        self.assertIn(str(self.root / "nested"), synced)
        self.assertIn(str(root), synced)

    def test_quarantined_result_is_never_current(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.store.quarantine_attempt("n1", "uncertain", self.store.snapshot()["domain"]["revision"])
        root = self.store.directory / "artifacts" / "n1"
        root.mkdir(parents=True, mode=0o700)
        report = root / "report.json"
        report.write_text("{}")
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(report), "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                    "usage": None, "exit_code": 0}
        self.assertEqual(self.store.record_result(envelope)["disposition"], "stale")
        self.assertEqual(self.store.snapshot()["attempts"][0]["state"], "quarantined")

    def test_late_result_after_cancellation_is_evidence_without_resurrection(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.store.request_cancellation("n1", "cancel-1", "stop", self.store.snapshot()["domain"]["revision"])
        root = self.store.directory / "artifacts" / "n1"
        root.mkdir(parents=True, mode=0o700)
        report = root / "report.json"
        report.write_text("{}")
        envelope = {"schema_version": 1, "domain_id": self.store.domain_id, "job_id": "j1", "attempt_id": "n1",
                    "generation": 1, "input_sha": "abc", "role": "reviewer", "stage": "code", "outcome": "success",
                    "report_path": str(report), "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                    "usage": {"cost_usd": 1.5}, "exit_code": 0}
        self.assertEqual(self.store.record_result(envelope)["disposition"], "stale")
        self.assertEqual(self.store.snapshot()["attempts"][0]["state"], "cancel_requested")
        self.store.record_result(envelope)
        self.assertEqual(self.store.snapshot()["sessions"][0]["known_spend"], 1.5)

    def test_cancellation_persists_grace_deadline_across_restart(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.assertIn('now', __import__('inspect').signature(self.store.request_cancellation).parameters,
                      'cancellation needs a clock-bound durable deadline')
        revision = self.store.snapshot()["domain"]["revision"]
        self.store.request_cancellation('n1', 'c', 'deadline', revision, now=10, grace_seconds=5)
        reopened = Store.open(self.domain, filesystem_inspector=lambda _: 'local')
        self.addCleanup(reopened.close)
        data = json.loads(reopened.snapshot()['attempts'][0]['data'])
        self.assertEqual(data['cancel_requested_at'], 10)
        self.assertEqual(data['cancel_grace_deadline'], 15)
        self.assertEqual(reopened.snapshot()['jobs'][0]['generation'], 2)

    def test_attempt_hard_deadline_is_set_once_and_survives_restart(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        self.store.update_attempt('n1', {'started_at': 10, 'deadline': 20}, self.store.snapshot()['domain']['revision'])
        other = Store.open(self.domain, filesystem_inspector=lambda _: 'local')
        self.addCleanup(other.close)
        before = other.snapshot()
        for update in ({'started_at': 11}, {'deadline': 21}, {'deadline': None}):
            with self.assertRaises(ValueError):
                other.update_attempt('n1', update, before['domain']['revision'])
            self.assertEqual(other.snapshot(), before)

    def test_one_retry_survives_restart_and_transfers_reservation(self):
        from supervisor import models
        self.assertTrue(hasattr(models, 'RetryEvidence'), 'trusted retry evidence is not implemented')
        self.assertTrue(hasattr(self.store, 'schedule_retry'), 'atomic retry scheduling is not implemented')
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        trusted = Store.open(self.domain, filesystem_inspector=lambda _: 'local',
                             stop_evidence_verifier=lambda _: True, retry_evidence_verifier=lambda _: True)
        self.addCleanup(trusted.close)
        trusted.record_command({'id': 'start', 'actor': 'fixture', 'command': 'start', 'payload': {},
                                'expected_revision': trusted.snapshot()['domain']['revision']})
        trusted.prepare_attempt(job, trusted.snapshot()['domain']['revision'],
                                {'global_cap': 1, 'provider_cap': 1, 'paths': ['src']})
        identity = {'boot_id': 'boot1', 'pid': 42, 'started_at': 'start', 'nonce': 'n1'}
        trusted.update_attempt('n1', {'state': 'running', 'boot_id': 'boot1', 'process_identity': identity},
                               trusted.snapshot()['domain']['revision'])
        trusted.request_cancellation('n1', 'cancel', 'infrastructure', trusted.snapshot()['domain']['revision'], now=10)
        proof = models.StopEvidence(domain_id=trusted.domain_id, job_id='j1', attempt_id='n1', generation=1,
                                    boot_id='boot1', pid=42, started_at='start', nonce='n1', kind='fixture_complete_tree', free_fixture=True)
        trusted.record_execution_stopped('n1', proof, trusted.snapshot()['domain']['revision'])
        eligibility = models.RetryEvidence(domain_id=trusted.domain_id, job_id='j1', attempt_id='n1', generation=1)
        trusted.schedule_retry('j1', 'n1', eligibility, retry_at=20, expected_revision=trusted.snapshot()['domain']['revision'])
        scheduled = trusted.snapshot()
        self.assertEqual(scheduled['jobs'][0]['retries_used'], 1)
        self.assertEqual(scheduled['jobs'][0]['state'], 'retry_wait')
        self.assertEqual(len(scheduled['claims']), 1)
        restarted = Store.open(self.domain, filesystem_inspector=lambda _: 'local', retry_evidence_verifier=lambda _: True)
        self.addCleanup(restarted.close)
        with self.assertRaises(ValueError):
            restarted.prepare_retry('j1', eligibility, now=19, limits={'global_cap': 1, 'provider_cap': 1, 'max_cost_usd': 10},
                                    expected_revision=restarted.snapshot()['domain']['revision'])
        retry = restarted.prepare_retry('j1', eligibility, now=20, limits={'global_cap': 1, 'provider_cap': 1, 'max_cost_usd': 10},
                                        expected_revision=restarted.snapshot()['domain']['revision'])
        snapshot = restarted.snapshot()
        self.assertEqual(len(snapshot['attempts']), 2)
        self.assertEqual(snapshot['claims'][0]['attempt_id'], retry['attempt_id'])
        fresh = next(x for x in snapshot['attempts'] if x['id'] == retry['attempt_id'])
        self.assertIsNot(json.loads(fresh['data']).get('execution_released'), True)
        restarted.record_command({'id': 'pause', 'actor': 'fixture', 'command': 'pause', 'payload': {},
                                  'expected_revision': snapshot['domain']['revision']})
        paused = restarted.snapshot()
        with self.assertRaises(ValueError):
            restarted.prepare_retry('j1', eligibility, now=21, limits={'global_cap': 1, 'provider_cap': 1, 'max_cost_usd': 10},
                                    expected_revision=paused['domain']['revision'])
        snapshot = paused
        with self.assertRaises(ValueError):
            restarted.schedule_retry('j1', retry['attempt_id'], eligibility, retry_at=30,
                                     expected_revision=snapshot['domain']['revision'])
        self.assertEqual(len(restarted.snapshot()['attempts']), 2)

    def test_stopped_attempt_without_usage_marks_original_session_unknown(self):
        from supervisor.models import StopEvidence
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        trusted = Store.open(self.domain, filesystem_inspector=lambda _: 'local', stop_evidence_verifier=lambda _: True)
        self.addCleanup(trusted.close)
        trusted.prepare_attempt(job, trusted.snapshot()['domain']['revision'],
                                {'global_cap': 1, 'provider_cap': 1, 'paths': ['src']})
        identity = {'boot_id': 'boot1', 'pid': 42, 'started_at': 'start', 'nonce': 'n1'}
        trusted.update_attempt('n1', {'state': 'running', 'boot_id': 'boot1', 'process_identity': identity},
                               trusted.snapshot()['domain']['revision'])
        trusted.request_cancellation('n1', 'cancel', 'infrastructure', trusted.snapshot()['domain']['revision'], now=10)
        proof = StopEvidence(domain_id=trusted.domain_id, job_id='j1', attempt_id='n1', generation=1,
                             boot_id='boot1', pid=42, started_at='start', nonce='n1', kind='fixture_complete_tree')
        trusted.record_execution_stopped('n1', proof, trusted.snapshot()['domain']['revision'])
        self.assertTrue(trusted.snapshot()['sessions'][0]['unknown_spend'])

    def test_fresh_attempt_rejects_preloaded_lifecycle_authority(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        before = self.store.snapshot()
        for field, value in [('execution_released', True), ('stop_evidence', {}), ('cancel_reason', 'stop'),
                             ('cancel_requested_at', 1), ('cancel_grace_deadline', 2), ('process_identity', {}),
                             ('boot_id', 'old'), ('state', 'running')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.store.prepare_attempt(dict(job, **{field: value}), before['domain']['revision'],
                                           {'global_cap': 1, 'provider_cap': 1, 'paths': ['src']})
            self.assertEqual(self.store.snapshot(), before)

    def test_execution_release_requires_bound_complete_tree_proof(self):
        from supervisor import models
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        identity = {'boot_id': 'boot1', 'pid': 42, 'started_at': 'start', 'nonce': 'n1'}
        self.store.update_attempt('n1', {'state': 'running', 'boot_id': 'boot1', 'process_identity': identity},
                                  self.store.snapshot()['domain']['revision'])
        self.assertTrue(hasattr(models, 'StopEvidence'), 'bound stop evidence is not implemented')
        self.assertTrue(hasattr(self.store, 'record_execution_stopped'), 'durable execution release is not implemented')
        self.store.request_cancellation('n1', 'c', 'infra', self.store.snapshot()['domain']['revision'])
        revision = self.store.snapshot()['domain']['revision']
        proof = models.StopEvidence(domain_id=self.store.domain_id, job_id='j1', attempt_id='n1', generation=1,
                                    boot_id='boot1', pid=42, started_at='start', nonce='n1', kind='fixture_complete_tree')
        with self.assertRaises(ValueError):
            self.store.record_execution_stopped('n1', dict(verified=True), revision)
        with self.assertRaises(ValueError):
            self.store.record_execution_stopped('n1', proof, revision)
        trusted = Store.open(self.domain, filesystem_inspector=lambda _: 'local',
                             stop_evidence_verifier=lambda candidate: candidate == proof)
        self.addCleanup(trusted.close)
        trusted.record_execution_stopped('n1', proof, revision)
        after = self.store.snapshot()
        self.assertTrue(json.loads(after['attempts'][0]['data'])['execution_released'])
        self.assertEqual(len(after['claims']), 1)
        self.store.prepare_attempt(dict(job, id='j2', card='2', nonce='n2', input_sha='def'),
                                   after['domain']['revision'], {'global_cap': 1, 'provider_cap': 1, 'paths': ['other']})
        self.assertEqual(len(self.store.snapshot()['claims']), 2)
        with self.assertRaises(ValueError):
            self.store.prepare_attempt(dict(job, id='j3', card='3', nonce='n3', input_sha='ghi'),
                                       self.store.snapshot()['domain']['revision'],
                                       {'global_cap': 2, 'provider_cap': 2, 'paths': ['src/sub']})

    def test_quarantine_fences_once_and_preserves_claim(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        before = self.store.snapshot()
        self.assertTrue(hasattr(self.store, 'quarantine_attempt'), 'atomic quarantine is not implemented')
        self.store.quarantine_attempt('n1', 'uncertain', before['domain']['revision'])
        after = self.store.snapshot()
        self.assertEqual(after['jobs'][0]['generation'], 2)
        self.assertEqual(after['attempts'][0]['state'], 'quarantined')
        self.assertEqual(len(after['claims']), 1)
        self.store.quarantine_attempt('n1', 'uncertain', after['domain']['revision'])
        self.assertEqual(self.store.snapshot(), after)

    def test_generic_update_cannot_request_cancellation_without_fencing(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        before = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.update_attempt("n1", {"state": "cancel_requested"}, before["domain"]["revision"])
        self.assertEqual(self.store.snapshot(), before)

    def test_cancellation_is_atomic_idempotent_and_cannot_be_resurrected(self):
        job = {"id": "j1", "card": "1", "action": "review", "role": "reviewer",
               "stage": "code", "round": 1, "input_sha": "abc", "input_version": "v1",
               "generation": 1, "provider": "p", "model": "m", "nonce": "n1", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src"]})
        before = self.store.snapshot()
        self.assertTrue(hasattr(self.store, "request_cancellation"), "atomic cancellation is not implemented")
        result = self.store.request_cancellation("n1", "cancel-1", "stop", before["domain"]["revision"])
        after = self.store.snapshot()
        self.assertEqual(after["jobs"][0]["generation"], 2)
        self.assertEqual(after["attempts"][0]["state"], "cancel_requested")
        self.assertEqual(len(after["claims"]), 1)
        self.assertEqual(self.store.request_cancellation("n1", "cancel-1", "stop", before["domain"]["revision"]), result)
        self.assertEqual(self.store.snapshot(), after)
        with self.assertRaises(ValueError):
            self.store.update_attempt("n1", {"state": "running", "heartbeat": 5}, after["domain"]["revision"])
        self.assertEqual(self.store.snapshot(), after)


if __name__ == "__main__":
    unittest.main()
