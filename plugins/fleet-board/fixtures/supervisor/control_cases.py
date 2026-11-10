"""Offline service-side status, event, card-control and resolution contracts."""
import os
import sys
import unittest
from pathlib import Path
from unittest import mock
import hashlib

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

    def make_attempt(self, card="12", job_id="job-12", attempt_id="attempt-12", session_id="s1"):
        store = self.service.store
        if not any(item["id"] == session_id for item in store.snapshot()["sessions"]):
            store.start_session({"id": session_id, "started_at": 1, "deadline": 1000,
                                 "known_spend": 0, "unknown_spend": False, "budget_stop": None})
        job = {"id": job_id, "card": str(card), "action": "review", "role": "reviewer",
               "stage": "code", "round": 1, "input_sha": "a" * 64, "input_version": "v1",
               "generation": 1, "provider": "fixture", "model": "fixture", "nonce": attempt_id,
               "session_id": session_id}
        store.prepare_attempt(job, store.snapshot()["domain"]["revision"],
                              {"global_cap": 4, "provider_cap": 4, "paths": ["src/card-" + str(card)]})
        return job

    def result_envelope(self, job, attempt_id, usage=None):
        artifacts = self.service.store.directory / "artifacts" / attempt_id
        artifacts.mkdir(parents=True, mode=0o700)
        report = artifacts / "report.json"
        report.write_text("{}", encoding="utf-8")
        return {"schema_version": 1, "domain_id": self.service.store.domain_id,
                "job_id": job["id"], "attempt_id": attempt_id, "generation": 1,
                "input_sha": job["input_sha"], "role": job["role"], "stage": job["stage"],
                "outcome": "failure", "report_path": str(report),
                "artifact_hashes": {str(report): hashlib.sha256(b"{}").hexdigest()},
                "usage": usage, "exit_code": 1}

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
        job = self.make_attempt()
        store = self.service.store
        store.quarantine_attempt("attempt-12", "writer state uncertain", store.snapshot()["domain"]["revision"])
        before = store.snapshot()
        self.assertEqual(before["attempts"][0]["state"], "quarantined")
        self.assertEqual(len(before["claims"]), 1)
        with self.assertRaisesRegex(Exception, "writer|effect|uncertain"):
            resolve(12, action="retry", request_id="manual-retry-1", reason="inspect",
                    evidence=[], expected_revision=self.service.get_status()["revision"])
        from supervisor.models import StopEvidence
        # Trusted evidence is created in-process after the fixture has established
        # the concrete attempt identity; Store accepts it through its verifier hook.
        evidence = StopEvidence(store.domain_id, job["id"], "attempt-12", 1, "boot-test", 42,
                                "start", "attempt-12", "fixture_complete_tree", True)
        self.service.store.retry_evidence_verifier = lambda candidate: candidate == evidence
        safe = resolve(12, action="retry", request_id="manual-retry-2", reason="verified safe",
                       evidence=evidence, expected_revision=self.service.get_status()["revision"])
        self.assertTrue(safe.get("applied"), "retry reports applied only after durable state change")
        after = store.snapshot()
        self.assertEqual(len(after["attempts"]), 1, "manual authorization must not dispatch an attempt")
        self.assertEqual(after["jobs"][0]["retries_used"], before["jobs"][0]["retries_used"])
        self.assertEqual(next(x for x in after["sessions"] if x["id"] == "s1")["known_spend"], 0)
        with self.assertRaisesRegex(Exception, "request|command|audit|retry"):
            resolve(12, action="retry", request_id="manual-retry-3", reason="again",
                    evidence=evidence, expected_revision=self.service.get_status()["revision"])

    def test_usage_resolution_requires_evidence_retains_unknown_event_and_cannot_clear_budget_stop(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_result(self.result_envelope(job, "attempt-12", usage=None))
        session = next(x for x in store.snapshot()["sessions"] if x["id"] == "s1")
        store.start_session({"id": "s2", "started_at": 2, "deadline": 1000,
                             "known_spend": session["known_spend"], "unknown_spend": True,
                             "budget_stop": "unknown usage"})
        with self.assertRaisesRegex(Exception, "evidence"):
            resolve(12, action="record_usage", request_id="usage-no-proof", reason="observed",
                    attempt_id="attempt-12", usage={"cost_usd": 0}, evidence=[],
                    expected_revision=self.service.get_status()["revision"])
        self.service.usage_evidence_verifier = lambda evidence: (
            isinstance(evidence, dict) and evidence.get("kind") == "provider_receipt"
            and evidence.get("attempt_id") == "attempt-12" and evidence.get("cost_usd") == 1.25)
        result = resolve(12, action="record_usage", request_id="usage-proof", reason="provider receipt",
                         attempt_id="attempt-12", usage={"cost_usd": 1.25},
                         evidence={"kind": "provider_receipt", "attempt_id": "attempt-12", "cost_usd": 1.25},
                         expected_revision=self.service.get_status()["revision"])
        self.assertTrue(result.get("applied"))
        snapshot = store.snapshot()
        resolved_session = next(x for x in snapshot["sessions"] if x["id"] == "s1")
        self.assertEqual(resolved_session["known_spend"], 1.25)
        self.assertTrue(resolved_session["unknown_spend"], "historical unknown usage remains auditable")
        self.assertTrue(any(x["type"] == "result_recorded" for x in snapshot["events"]))
        self.assertTrue(resolved_session["unknown_spend"])
        self.assertEqual(next(x for x in snapshot["sessions"] if x["id"] == "s2")["budget_stop"],
                         "unknown usage", "usage recording cannot clear a budget stop")

    def test_effect_confirmation_uses_verifier_and_abandon_retains_artifacts(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_effect({"operation_key": "external-op-12", "job_id": job["id"], "generation": 1,
                             "preconditions": {"card": "12"},
                             "intent": {"kind": "pr_create", "card": "12", "marker": "external-op-12"}})
        store.observe_effect("external-op-12", {"status": "unknown"}, store.snapshot()["domain"]["revision"])
        artifacts = store.directory / "artifacts" / "attempt-12"
        artifacts.mkdir(parents=True, mode=0o700)
        artifact = artifacts / "worker.log"
        artifact.write_text("retained evidence", encoding="utf-8")
        observations = {"accepted": {"operation_key": "external-op-12", "external_id": "pr-91"},
                        "rejected": None}
        class EffectVerifier:
            def __init__(self, value): self.value = value
            def verify(self, effect, evidence):
                return bool(self.value and effect["operation_key"] == evidence.get("operation_key")
                            and self.value.get("operation_key") == effect["operation_key"])
        self.service.effect_verifier = EffectVerifier(observations["accepted"])
        with self.assertRaisesRegex(Exception, "verif|evidence|effect"):
            resolve(12, action="confirm_effect", request_id="resolve-human-text", reason="human note",
                    effect_id="external-op-12", evidence="I saw it", expected_revision=self.service.get_status()["revision"])
        self.service.effect_verifier = EffectVerifier(observations["rejected"])
        with self.assertRaisesRegex(Exception, "verif|evidence|effect"):
            resolve(12, action="confirm_effect", request_id="resolve-reject", reason="provider check",
                    effect_id="external-op-12", evidence={"operation_key": "external-op-12"},
                    expected_revision=self.service.get_status()["revision"])
        self.service.effect_verifier = EffectVerifier(observations["accepted"])
        accepted = resolve(12, action="confirm_effect", request_id="resolve-verified", reason="provider check",
                           effect_id="external-op-12", evidence={"operation_key": "external-op-12"},
                           expected_revision=self.service.get_status()["revision"])
        self.assertTrue(accepted.get("applied"))
        self.service.effect_verifier = EffectVerifier(None)
        abandoned = resolve(12, action="abandon", request_id="resolve-abandon", reason="retain for inspection",
                            effect_id="external-op-12", artifact_paths=[str(artifact)],
                            expected_revision=self.service.get_status()["revision"])
        self.assertTrue(abandoned.get("artifacts_preserved"))
        self.assertTrue(artifact.exists())
        self.assertEqual(abandoned.get("released_claims"), 1)
        self.assertFalse(store.snapshot()["claims"])

    def test_unknown_state_is_quarantined_and_reservations_are_retained(self):
        reconcile = self.require_api("reconcile_card")
        reservation = self.service.store.reserve_scope("12", ["src/card-12"],
                                                       self.service.store.snapshot()["domain"]["revision"])
        revision = reservation["reservation_revision"]
        before = self.service.store.snapshot()
        result = reconcile(12, known=False)
        self.assertEqual(result.get("state"), "needs_attention")
        self.assertTrue(result.get("quarantined"))
        self.assertTrue(result.get("reservation_retained"))
        self.assertFalse(result.get("dispatchable"), "unknown cards are never dispatched")
        after = self.service.store.snapshot()
        exact = next(x for x in after["reservations"] if x["card"] == "12")
        self.assertEqual(exact["paths"], before["reservations"][0]["paths"])
        self.assertEqual(exact["reservation_revision"], revision)
        self.assertEqual(after["reservations"], before["reservations"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
