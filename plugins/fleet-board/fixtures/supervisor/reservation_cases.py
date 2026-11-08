"""Offline scope reservation ownership and release contract tests."""
import concurrent.futures
import sys
import unittest
from pathlib import Path

ROOT = Path(sys.argv.pop()).resolve()
from supervisor.store import Store


class Reservations(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit('.', 1)[-1]
        self.root.mkdir(mode=0o700)
        self.domain = {"common_dir": str(self.root), "board_backend": "local",
                       "board_identity": "reservations", "runtime_root": str(self.root / "runtime")}
        self.store = Store.open(self.domain, filesystem_inspector=lambda _path: "local")
        self.addCleanup(self.store.close)

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
        snap = self.store.snapshot()
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-1", "human", "done", snap["domain"]["revision"])
        result = self.store.release_scope("12", "release-2", "human", "verified abandonment",
                                          self.store.snapshot()["domain"]["revision"])
        self.assertEqual(result["released_paths"], ["src/a"])
        self.assertEqual(self.store.snapshot()["events"][-1]["payload"]["actor"], "human")
        with self.assertRaises(ValueError):
            self.store.release_scope("12", "release-3", "human", "stale", snap["domain"]["revision"])

    def test_resume_waits_for_scope_refreshes_and_invalidates_evidence_without_moving_qa(self):
        self.reserve("12", ["src/a"])
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
