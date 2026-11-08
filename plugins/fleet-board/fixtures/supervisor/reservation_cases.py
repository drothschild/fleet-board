"""Offline scope reservation ownership and release contract tests."""
import concurrent.futures
import sys
import unittest
from pathlib import Path

ROOT = Path(sys.argv.pop()).resolve()
from supervisor.store import Store
from supervisor.workers import verify_worker_scope, request_scope_expansion
from supervisor.scheduler import Scheduler
from supervisor.models import StopEvidence


class Reservations(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {"common_dir": str(self.root), "board_backend": "local",
                       "board_identity": "reservations", "runtime_root": str(self.root / "runtime")}
        self.store = Store.open(self.domain, filesystem_inspector=lambda _path: "local",
                                stop_evidence_verifier=lambda _evidence: True)
        self.addCleanup(self.store.close)
        self.store.start_session({"id": "default", "started_at": 1, "deadline": 100,
                                  "known_spend": 0, "unknown_spend": False, "budget_stop": None})

    def reserve(self, card, paths, enforceable=True):
        revision = self.store.snapshot()["domain"]["revision"]
        return self.store.reserve_scope(card, paths, revision, enforceable=enforceable)

    def test_scope_union_persists_across_review_qa_retry_pause_and_restart(self):
        self.reserve("12", ["src/core"])
        self.reserve("12", ["src/core/fix.py", "docs/qa.md"])
        other = Store.open(self.domain, filesystem_inspector=lambda _path: "local")
        try:
            record = next(x for x in other.snapshot()["reservations"] if x["card"] == "12")
            self.assertEqual(record["paths"], ["docs/qa.md", "src/core", "src/core/fix.py"])
            self.assertEqual(other.scope_conflict("13", ["src/core/nested"]), "12")
            self.assertIsNone(other.scope_conflict("13", ["src/core2"]))
        finally:
            other.close()

    def test_scope_rejects_traversal_and_symlink_escape(self):
        (self.root / "outside").mkdir()
        (self.root / "link").symlink_to(self.root / "outside", target_is_directory=True)
        for path in ("../outside", "src/../../outside", "link/file"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.reserve("12", [path])

    def test_unauthorized_changes_hold_publication(self):
        self.reserve("12", ["src/a"])
        result = verify_worker_scope(self.store, "12", ["src/a/file.py", "docs/secret.md"])
        self.assertTrue(result["publication_hold"])
        self.assertTrue(result["quarantined"])
        self.assertEqual(result["paths"], ["docs/secret.md"])

    def test_scheduler_observes_persistent_reservations(self):
        scheduler = Scheduler(clock=lambda: 0, state_writer=lambda _state: None)
        try:
            result = scheduler.admit([{"number": 13, "action": "start", "provider": "p",
                                       "declared_paths": ["src/a/file.py"], "actual_paths": [],
                                       "scope_complete": True}], active=[], reservations=[{"card": "12", "paths": ["src/a"]}],
                                   limits={"global": 2, "providers": {"p": 2}, "per_card": 1})
            self.assertEqual(result["waits"][0]["reason"], "scope reserved by #12")
        finally:
            scheduler.close()

    def test_denied_expansion_checkpoints_without_retry_penalty(self):
        self.reserve("12", ["src/a"])
        self.reserve("13", ["docs/b"])
        checkpoints = []
        result = request_scope_expansion(self.store, "12", ["docs/b/file"],
                                         self.store.snapshot()["domain"]["revision"],
                                         lambda: checkpoints.append("saved"))
        self.assertFalse(result["granted"])
        self.assertTrue(result["checkpointed"])
        self.assertFalse(result["retry_penalty"])
        self.assertEqual(checkpoints, ["saved"])
        self.assertEqual(next(x for x in self.store.snapshot()["reservations"] if x["card"] == "12")["paths"], ["src/a"])

    def test_competing_expansions_are_atomic(self):
        self.reserve("12", ["src/a"])
        revision = self.store.snapshot()["domain"]["revision"]
        def expand(card):
            store = Store.open(self.domain, filesystem_inspector=lambda _path: "local")
            try:
                store.expand_scope(card, ["shared/tree"], revision)
                return True
            except ValueError:
                return False
            finally:
                store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(expand, ("12", "13")))
        self.assertEqual(sum(results), 1)
        snapshot = self.store.snapshot()
        self.assertEqual(len([x for x in snapshot["reservations"] if "shared/tree" in x["paths"]]), 1)

    def test_non_enforceable_provider_gets_repository_wide_reservation(self):
        result = self.reserve("12", ["src/a"], enforceable=False)
        self.assertEqual(result["paths"], [""])
        self.assertEqual(self.store.scope_conflict("13", ["docs/readme.md"]), "12")

    def test_release_requires_no_writer_or_pending_effect_and_audits_human(self):
        self.reserve("12", ["src/a"])
        self.store.record_command({"id": "pause-card", "expected_revision": self.store.snapshot()["domain"]["revision"],
                                   "actor": "human", "command": "pause", "payload": {"card": "12"}})
        snap = self.store.snapshot()
        result = self.store.release_scope("12", "release-1", "human", "verified abandonment",
                                          snap["domain"]["revision"], reservation_revision=1)
        self.assertEqual(result["released_paths"], ["src/a"])
        self.assertEqual(self.store.snapshot()["events"][-1]["payload"]["actor"], "human")
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-2", "human", "stale", snap["domain"]["revision"])

    def test_release_rejects_live_writer(self):
        self.reserve("12", ["src/a"])
        job = {"id": "job12", "card": "12", "action": "start", "role": "implementor", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "fixture", "model": "fixture", "nonce": "attempt12", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src/a"]})
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-live", "human", "blocked", self.store.snapshot()["domain"]["revision"])

    def test_release_rejects_unpaused_card(self):
        self.reserve("12", ["src/a"])
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-running", "human", "blocked", self.store.snapshot()["domain"]["revision"])

    def test_release_rejects_pending_effect_after_writer_stops(self):
        self.reserve("12", ["src/a"])
        job = {"id": "job12", "card": "12", "action": "start", "role": "implementor", "stage": "code",
               "round": 1, "input_sha": "abc", "input_version": "v1", "generation": 1,
               "provider": "fixture", "model": "fixture", "nonce": "attempt12", "session_id": "default"}
        self.store.prepare_attempt(job, self.store.snapshot()["domain"]["revision"],
                                   {"global_cap": 1, "provider_cap": 1, "paths": ["src/a"]})
        identity = {"boot_id": "boot", "pid": 123, "started_at": "stamp", "nonce": "attempt12"}
        revision = self.store.snapshot()["domain"]["revision"]
        self.store.update_attempt("attempt12", {"state": "interrupted", "boot_id": "boot", "process_identity": identity}, revision)
        evidence = StopEvidence(self.store.domain_id, "job12", "attempt12", 1, "boot", 123,
                                "stamp", "attempt12", "fixture_complete_tree", True)
        self.store.record_execution_stopped("attempt12", evidence, self.store.snapshot()["domain"]["revision"])
        self.store.record_effect({"operation_key": "publish-1", "job_id": "job12", "generation": 1,
                                  "preconditions": {}, "intent": {"kind": "publish"}})
        self.store.record_command({"id": "pause-card", "expected_revision": self.store.snapshot()["domain"]["revision"],
                                   "actor": "human", "command": "pause", "payload": {"card": "12"}})
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-effect", "human", "blocked", self.store.snapshot()["domain"]["revision"])

    def test_cyclic_expansion_waits_are_visible_as_attention(self):
        self.reserve("12", ["src/a"])
        self.reserve("13", ["docs/b"])
        for card, path in (("12", "docs/b/file"), ("13", "src/a/file")):
            with self.assertRaises(ValueError):
                self.reserve(card, [path])
        self.assertEqual(self.store.snapshot()["attention"], [{"type": "scope_cycle", "cards": ["12", "13"]}])

    def test_resume_waits_for_scope_refreshes_and_invalidates_evidence_without_moving_qa(self):
        self.reserve("12", ["src/a"])
        self.reserve("13", ["docs/new"])
        calls = []
        result = self.store.resume_scope("12", ["src/a", "docs/new"], "human_qa",
                                         lambda: calls.append("refresh"), expected_revision=self.store.snapshot()["domain"]["revision"])
        self.assertEqual(result["state"], "scope_wait")
        result = self.store.resume_scope("12", ["src/a"], "human_qa", lambda: calls.append("refresh"),
                                         expected_revision=self.store.snapshot()["domain"]["revision"])
        self.assertEqual(calls, ["refresh"])
        self.assertEqual(result["state"], "ready")
        self.assertTrue(result["evidence_invalidated"])
        self.assertEqual(result["workflow_state"], "human_qa")


if __name__ == "__main__":
    unittest.main(verbosity=2)
