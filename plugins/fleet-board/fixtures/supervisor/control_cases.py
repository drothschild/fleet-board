"""Offline service-side status, event, card-control and resolution contracts."""
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()
try:
    from supervisor.service import Service
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.service"):
        raise
    Service = None


class FakeClock:
    def __init__(self, now=100):
        self.now = now

    def __call__(self):
        return self.now


class ControlContracts(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(Service, "persistent supervisor service is not implemented")
        self.root = ROOT / self.id().rsplit(".", 1)[-1]
        self.root.mkdir(mode=0o700)
        self.socket_tmp = self.root / "sockets"
        self.socket_tmp.mkdir(mode=0o700)
        self.config = self.root / "enabled.yml"
        self.config.write_text("board:\n  repo: acme/toy\nsupervisor:\n  enabled: true\n", encoding="utf-8")
        self.domain = {"common_dir": str(self.root), "board_backend": "local",
                       "board_identity": "control-fixture", "runtime_root": str(self.root / "runtime")}
        self.clock = FakeClock()
        env = {"TMPDIR": str(self.socket_tmp), "FLEET_BOARD_LOG_DIR": str(self.root / "logs"),
               "FLEET_BOARD_CONFIG": str(self.config)}
        with mock.patch.dict(os.environ, env):
            self.service = Service.open(self.domain, clock=self.clock, host_boot_id="boot-test",
                                        peer_resolver=lambda _peer: "fixture-human")
        self.addCleanup(self.service.close)

    def require_api(self, name):
        api = getattr(self.service, name, None)
        self.assertTrue(callable(api), "service API %s is not implemented" % name)
        return api

    def test_status_exposes_complete_authoritative_contract_and_disabled_is_read_only(self):
        result = self.require_api("get_status")()
        for key in ("schema_version", "revision", "desired_mode", "phase", "heartbeat",
                    "session", "capacity", "queue", "config", "boot_registration", "last_error"):
            self.assertIn(key, result, "status missing %s" % key)
        self.assertIn(result["phase"], ("starting", "recovering", "running", "draining",
                                        "cancelling", "stopped", "unreachable", "error"))
        self.assertEqual(result["boot_registration"], "missing")
        self.assertNotIn("reboot_recovery", result.get("claims", {}))
        snapshot = self.service.snapshot()
        config = self.root / "disabled.yml"
        config.write_text("supervisor:\n  enabled: false\n", encoding="utf-8")
        with mock.patch.dict(os.environ, {"FLEET_BOARD_CONFIG": str(config)}):
            disabled = Service.open(self.domain, clock=self.clock, host_boot_id="boot-test")
        self.addCleanup(disabled.close)
        before = disabled.snapshot()
        self.assertTrue(disabled.get_status()["read_only"])
        self.assertEqual(disabled.snapshot(), before)
        self.assertEqual(self.service.snapshot(), snapshot)

    def test_events_are_bounded_replayable_and_expired_cursor_requires_snapshot(self):
        events = self.require_api("events")
        first = events(after=0, limit=1)
        self.assertIn("events", first)
        self.assertIn("next_cursor", first)
        bounded = events(after=0, limit=1)
        self.assertEqual(first, bounded)
        self.assertLessEqual(len(first["events"]), 1)
        expired = events(after=-1000, limit=1)
        self.assertTrue(expired.get("snapshot_required"), "expired cursor must require a snapshot")
        self.assertIn("snapshot", expired)

    def test_card_execution_contains_attempt_wait_claim_and_safe_log_data(self):
        result = self.require_api("card_execution")(12)
        for key in ("job", "attempts", "progress_age", "heartbeat_age", "deadlines",
                    "retries", "waiting_reason", "claims", "reservation_revision", "logs"):
            self.assertIn(key, result, "card execution missing %s" % key)
        for item in result.get("logs", []):
            self.assertRegex(item, r"^[A-Za-z0-9_-]+$", "log references must be opaque IDs")
            self.assertNotIn("/", item)

    def test_card_pause_is_revision_bound_deduplicated_and_acknowledges_async_state(self):
        pause = self.require_api("card_pause")
        initial = self.service.get_status()
        command = {"request_id": "pause-card-12", "expected_revision": initial["revision"]}
        accepted = pause(12, mode="drain", **command)
        for key in ("command_id", "state_revision", "desired_mode", "phase"):
            self.assertIn(key, accepted)
        self.assertEqual(pause(12, mode="drain", **command), accepted)
        with self.assertRaisesRegex(Exception, "revision"):
            pause(12, mode="cancel", request_id="stale-pause", expected_revision=0)

    def test_reservation_release_checks_safety_revision_and_audits_authenticated_actor(self):
        release = self.require_api("release_reservations")
        with self.assertRaisesRegex(Exception, "paused"):
            release(12, reason="reconcile", expected_revision=self.service.get_status()["revision"],
                    expected_reservation_revision=0)
        with self.assertRaisesRegex(Exception, "reservation"):
            release(12, reason="reconcile", expected_revision=-1,
                    expected_reservation_revision=999)
        self.assertTrue(callable(getattr(self.service, "authenticated_actor", None)),
                        "release actor must be derived from authenticated peer")

    def test_resume_refreshes_before_dispatch_and_preserves_qa_and_budget_stop(self):
        resume = self.require_api("card_resume")
        result = resume(12, request_id="resume-12", expected_revision=self.service.get_status()["revision"])
        self.assertTrue(result.get("refreshed"), "resume must refresh eligibility before dispatch")
        self.assertTrue(result.get("preserved_human_qa"), "resume must preserve Human QA")
        self.assertTrue(result.get("preserved_budget_stop"), "resume must preserve budget stop")

    def test_retry_resolution_requires_safe_writer_state_and_preserves_retry_budget(self):
        resolve = self.require_api("resolve")
        with self.assertRaisesRegex(Exception, "writer|effect|uncertain"):
            resolve(12, action="retry", request_id="manual-retry-1", reason="inspect",
                    evidence=[], expected_revision=self.service.get_status()["revision"])
        safe = resolve(12, action="retry", request_id="manual-retry-2", reason="verified safe",
                       evidence=["attempt-log"], expected_revision=self.service.get_status()["revision"])
        self.assertTrue(safe.get("applied"), "retry reports applied only after durable state change")
        self.assertNotEqual(resolve(12, action="retry", request_id="manual-retry-3", reason="again",
                                    evidence=["attempt-log"], expected_revision=safe["revision"]), safe,
                            "each manual retry requires a distinct audited command")

    def test_usage_resolution_requires_evidence_retains_unknown_event_and_cannot_clear_budget_stop(self):
        resolve = self.require_api("resolve")
        with self.assertRaisesRegex(Exception, "evidence"):
            resolve(12, action="record_usage", request_id="usage-no-proof", reason="observed",
                    attempt_id="attempt-1", usage={"input_tokens": 0, "output_tokens": 0}, evidence=[],
                    expected_revision=self.service.get_status()["revision"])
        result = resolve(12, action="record_usage", request_id="usage-proof", reason="provider receipt",
                         attempt_id="attempt-1", usage={"input_tokens": 2, "output_tokens": 3},
                         evidence=["receipt-1"], expected_revision=self.service.get_status()["revision"])
        self.assertTrue(result.get("applied"))
        status = self.service.get_status()
        self.assertTrue(status["session"]["unknown_spend"])
        self.assertTrue(status["session"].get("budget_stop"), "usage recording cannot clear a budget stop")

    def test_effect_confirmation_uses_verifier_and_abandon_retains_artifacts(self):
        resolve = self.require_api("resolve")
        verifier = getattr(self.service, "effect_verifier", None)
        self.assertTrue(callable(verifier), "confirm_effect requires an injected external-state verifier")
        self.assertTrue(callable(getattr(self.service, "resolve", None)), "resolution API missing")
        for action in ("confirm_effect", "abandon"):
            result = resolve(12, action=action, request_id="resolve-" + action, reason="human note",
                             evidence=["external-evidence"], expected_revision=self.service.get_status()["revision"])
            self.assertTrue(result.get("applied"))
            self.assertTrue(result.get("artifacts_preserved", True))

    def test_unknown_state_is_quarantined_and_reservations_are_retained(self):
        reconcile = self.require_api("reconcile_card")
        result = reconcile(12, known=False)
        self.assertEqual(result.get("state"), "needs_attention")
        self.assertTrue(result.get("quarantined"))
        self.assertTrue(result.get("reservation_retained"))
        self.assertFalse(result.get("dispatchable"), "unknown cards are never dispatched")


if __name__ == "__main__":
    unittest.main(verbosity=2)
