"""Offline service-side status, event, card-control and resolution contracts."""
import os
import sys
import json
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

    def test_status_observation_heartbeat_and_boot_registration_are_authoritative(self):
        store = self.service.store
        store.record_command({"id": "status-start", "expected_revision": store.snapshot()["domain"]["revision"],
                             "actor": "fixture-human", "command": "start", "payload": {}})
        acknowledged_at = self.service.get_status()["heartbeat"]["at"]
        store.append_event({"type": "unrelated", "payload": {}})
        latest_sequence = store.snapshot()["events"][-1]["sequence"]
        store._Store__connection.execute("UPDATE events SET timestamp=? WHERE sequence=?",
                                          (acknowledged_at + 50, latest_sequence))
        status = self.require_api("get_status")()
        self.assertEqual(status["heartbeat"]["at"], acknowledged_at,
                            "an arbitrary event must not refresh supervisor heartbeat")
        self.assertEqual(status["phase"], "running")
        self.service.writer_uncertain = True
        status = self.service.get_status()
        self.assertIn(status["phase"], ("stopped", "unreachable"))
        self.assertEqual(status["boot_registration"], "missing")

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

    def test_compacted_event_history_requires_snapshot_for_old_cursor(self):
        store = self.service.store
        for index in range(4):
            store.append_event({"type": "fixture_event", "payload": {"index": index}})
        # Model compaction at the store boundary while retaining the later sequence IDs.
        connection = store._Store__connection
        connection.execute("DELETE FROM events WHERE sequence < (SELECT MAX(sequence)-1 FROM events)")
        expired = self.require_api("events")(after=1, limit=10)
        self.assertTrue(expired.get("snapshot_required"), "cursor before retained history needs snapshot")

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

    def test_card_pause_closes_admissions_persists_pause_and_cancels_only_target_card(self):
        pause = self.require_api("card_pause")
        self.service.admissions_open = True
        first = self.make_attempt(card="12", job_id="job-12", attempt_id="attempt-12")
        second = self.make_attempt(card="13", job_id="job-13", attempt_id="attempt-13", session_id="s2")
        before = self.service.get_status()["revision"]
        ack = pause(12, mode="cancel", request_id="pause-target", expected_revision=before)
        self.assertEqual((self.service.store._card_lifecycles().get("12"), self.service.admissions_open,
                          "attempt-13" in self.service.cancellation_requests,
                          "attempt-12" in self.service.cancellation_requests,
                          "command_id" in ack, "state_revision" in ack, "completed" in ack),
                         ("paused", False, False, True, True, True, False))

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

    def test_release_requires_reservation_attempt_proof_and_deduplicates_audited_request(self):
        release = self.require_api("release_reservations")
        store = self.service.store
        job = self.make_attempt()  # admission requires an unpaused card: build it first
        reservation = store.reserve_scope("12", ["src/card-12"], store.snapshot()["domain"]["revision"])
        store.set_card_lifecycle("12", "paused", store.snapshot()["domain"]["revision"])
        before = store.snapshot()
        with self.assertRaisesRegex(Exception, "attempt|writer|proof|evidence"):
            release(12, reason="reconcile", expected_revision=before["domain"]["revision"],
                    expected_reservation_revision=reservation["reservation_revision"])
        # Even a present attempt needs execution release evidence before its reservation is safe.
        before = store.snapshot()
        with self.assertRaisesRegex(Exception, "writer|evidence|release"):
            release(12, reason="reconcile", expected_revision=before["domain"]["revision"],
                    expected_reservation_revision=reservation["reservation_revision"])
        self.assertEqual(job["card"], "12")

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
            resolve(12, action="retry", attempt_id="attempt-12", request_id="manual-retry-1", reason="inspect",
                    evidence=[], expected_revision=self.service.get_status()["revision"])
        from supervisor.models import StopEvidence
        # Trusted evidence is created in-process after the fixture has established
        # the concrete attempt identity; Store accepts it through its verifier hook.
        evidence = StopEvidence(store.domain_id, job["id"], "attempt-12", 1, "boot-test", 42,
                                "start", "attempt-12", "fixture_complete_tree", True)
        self.service.store.retry_evidence_verifier = lambda candidate: candidate == evidence
        safe = resolve(12, action="retry", attempt_id="attempt-12", request_id="manual-retry-2", reason="verified safe",
                       evidence=evidence, expected_revision=self.service.get_status()["revision"])
        self.assertTrue(safe.get("applied"), "retry reports applied only after durable state change")
        replay = resolve(12, action="retry", attempt_id="attempt-12", request_id="manual-retry-2", reason="verified safe",
                         evidence=evidence, expected_revision=before["domain"]["revision"])
        self.assertFalse(replay.get("applied", replay.get("replayed", False)),
                         "request replay must return the prior outcome without reapplying")
        after = store.snapshot()
        self.assertEqual(len(after["attempts"]), 1, "manual authorization must not dispatch an attempt")
        self.assertEqual(after["jobs"][0]["retries_used"], before["jobs"][0]["retries_used"])
        self.assertEqual(next(x for x in after["sessions"] if x["id"] == "s1")["known_spend"], 0)
        with self.assertRaisesRegex(Exception, "request|command|audit|retry"):
            resolve(12, action="retry", attempt_id="attempt-12", request_id="manual-retry-3", reason="again",
                    evidence=evidence, expected_revision=self.service.get_status()["revision"])

    def test_retry_rejects_uncontained_attempt_states_and_requires_attempt_identity(self):
        resolve = self.require_api("resolve")
        self.make_attempt()
        store = self.service.store
        for index, attempt_state in enumerate(("prepared", "running", "result_ready", "failed")):
            data = json.loads(next(row for row in store.snapshot()["attempts"] if row["id"] == "attempt-12")["data"])
            if attempt_state == "failed":
                data.pop("execution_released", None)
            store._Store__connection.execute("UPDATE attempts SET state=?,data=? WHERE id=?",
                (attempt_state, json.dumps(data, sort_keys=True, separators=(",", ":")), "attempt-12"))
            revision = self.service.get_status()["revision"]
            with self.subTest(state=attempt_state):
                with self.assertRaisesRegex(Exception, "attempt|contain|writer|evidence|retry"):
                    resolve(12, action="retry", request_id="retry-state-%d" % index, reason="retry",
                            attempt_id="attempt-12", expected_revision=revision)
        with self.assertRaisesRegex(Exception, "attempt|contain|writer|evidence|retry"):
            resolve(12, action="retry", attempt_id="attempt-12", request_id="retry-no-attempt", reason="retry",
                    expected_revision=self.service.get_status()["revision"])

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
        usage_revision = store.snapshot()["domain"]["revision"]
        result = resolve(12, action="record_usage", request_id="usage-proof", reason="provider receipt",
                         attempt_id="attempt-12", usage={"cost_usd": 1.25},
                         evidence={"kind": "provider_receipt", "attempt_id": "attempt-12", "cost_usd": 1.25},
                         expected_revision=self.service.get_status()["revision"])
        self.assertTrue(result.get("applied"))
        replay = resolve(12, action="record_usage", request_id="usage-proof", reason="provider receipt",
                         attempt_id="attempt-12", usage={"cost_usd": 1.25},
                         evidence={"kind": "provider_receipt", "attempt_id": "attempt-12", "cost_usd": 1.25},
                         expected_revision=usage_revision)
        self.assertFalse(replay.get("applied", replay.get("replayed", False)),
                         "usage replay must not claim a second application")
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
        # An observation exists, but it is explicitly ambiguous and cannot authorize abandonment.
        with self.assertRaisesRegex(Exception, "unresolved|effect|resolved"):
            resolve(12, action="abandon", request_id="resolve-ambiguous", reason="retain",
                    effect_id="external-op-12", artifact_paths=[str(artifact)],
                    expected_revision=self.service.get_status()["revision"])
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
        confirmed_again = resolve(12, action="confirm_effect", request_id="resolve-verified", reason="provider check",
                                  effect_id="external-op-12", evidence={"operation_key": "external-op-12"},
                                  expected_revision=self.service.get_status()["revision"])
        self.assertFalse(confirmed_again.get("applied", confirmed_again.get("replayed", False)))
        self.service.effect_verifier = EffectVerifier(None)
        abandoned = resolve(12, action="abandon", request_id="resolve-abandon", reason="retain for inspection",
                            effect_id="external-op-12", artifact_paths=[str(artifact)],
                            expected_revision=self.service.get_status()["revision"])
        self.assertTrue(abandoned.get("artifacts_preserved"))
        self.assertTrue(artifact.exists())
        self.assertEqual(abandoned.get("released_claims"), 1)
        self.assertFalse(store.snapshot()["claims"])

    def test_abandon_requires_nonempty_attempt_artifact_list(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_effect({"operation_key": "abandon-op", "job_id": job["id"], "generation": 1,
                             "preconditions": {}, "intent": {"kind": "publish", "card": "12"}})
        store.confirm_effect("abandon-op", {"status": "applied"}, store.snapshot()["domain"]["revision"])
        with self.assertRaisesRegex(Exception, "artifact|path|attempt|preserv"):
            resolve(12, action="abandon", request_id="abandon-empty", reason="retain",
                    effect_id="abandon-op", artifact_paths=[],
                    expected_revision=self.service.get_status()["revision"])

    def test_abandon_rejects_artifact_from_another_attempt(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_effect({"operation_key": "foreign-artifact-op", "job_id": job["id"], "generation": 1,
                             "preconditions": {}, "intent": {"kind": "publish", "card": "12"}})
        store.confirm_effect("foreign-artifact-op", {"status": "applied"}, store.snapshot()["domain"]["revision"])
        foreign = store.directory / "artifacts" / "other-card" / "report.json"
        foreign.parent.mkdir(parents=True, mode=0o700)
        foreign.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(Exception, "artifact|path|attempt|preserv"):
            resolve(12, action="abandon", request_id="abandon-foreign", reason="retain",
                    effect_id="foreign-artifact-op", artifact_paths=[str(foreign)],
                    expected_revision=self.service.get_status()["revision"])

    def test_abandon_rejects_path_traversal_artifact(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_effect({"operation_key": "traversal-artifact-op", "job_id": job["id"], "generation": 1,
                             "preconditions": {}, "intent": {"kind": "publish", "card": "12"}})
        store.confirm_effect("traversal-artifact-op", {"status": "applied"}, store.snapshot()["domain"]["revision"])
        outside = store.directory / "outside"
        outside.write_text("{}", encoding="utf-8")
        traversal = store.directory / "artifacts" / "attempt-12" / ".." / ".." / "outside"
        with self.assertRaisesRegex(Exception, "artifact|path|attempt|preserv"):
            resolve(12, action="abandon", request_id="abandon-traversal", reason="retain",
                    effect_id="traversal-artifact-op", artifact_paths=[str(traversal)],
                    expected_revision=self.service.get_status()["revision"])

    def test_abandon_after_resolved_effect_preserves_card_attempt_artifact_and_replays(self):
        resolve = self.require_api("resolve")
        job = self.make_attempt()
        store = self.service.store
        store.record_effect({"operation_key": "resolved-abandon-op", "job_id": job["id"], "generation": 1,
                             "preconditions": {}, "intent": {"kind": "publish", "card": "12"}})
        store.confirm_effect("resolved-abandon-op", {"status": "applied"}, store.snapshot()["domain"]["revision"])
        artifact = store.directory / "artifacts" / "attempt-12" / "report.json"
        artifact.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        artifact.write_text("retained", encoding="utf-8")
        revision = store.snapshot()["domain"]["revision"]
        args = {"action": "abandon", "request_id": "resolved-abandon-request", "reason": "retain",
                "effect_id": "resolved-abandon-op", "artifact_paths": [str(artifact)],
                "expected_revision": revision}
        first = resolve(12, **args)
        self.assertTrue(first.get("artifacts_preserved"))
        self.assertTrue(artifact.exists())
        self.assertFalse(store.snapshot()["claims"])
        try:
            replay = resolve(12, **args)
        except Exception as exc:
            self.fail("abandon request replay must return its prior outcome: %s" % exc)
        self.assertFalse(replay.get("applied", replay.get("replayed", False)))

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

    def test_writer_uncertain_rejects_mutations_without_writing(self):
        reservation = self.service.store.reserve_scope("12", ["src/card-12"], self.service.snapshot()["domain"]["revision"])
        self.service.store.set_card_lifecycle("12", "paused", self.service.snapshot()["domain"]["revision"])
        self.service.writer_uncertain = True
        before = self.service.snapshot()
        with self.assertRaisesRegex(Exception, "uncertain|writer"):
            self.service.handle_request({"command": "release_reservations", "card": 12, "reason": "x",
                                         "expected_revision": before["domain"]["revision"],
                                         "expected_reservation_revision": reservation["reservation_revision"]}, peer=None)
        with self.assertRaisesRegex(Exception, "uncertain|writer"):
            self.service.reconcile_card(12, known=False)
        for command in ("resolve", "start", "pause", "resume"):
            with self.assertRaisesRegex(Exception, "uncertain|writer"):
                self.service.handle_request({"command": command, "request_id": "uncertain-" + command,
                                             "expected_revision": before["domain"]["revision"]}, peer=None)
        self.assertEqual(self.service.snapshot(), before)

    def test_mutating_request_boundary_requires_request_id_and_expected_revision(self):
        job = self.make_attempt()
        self.service.store.record_effect({"operation_key": "boundary-effect", "job_id": job["id"], "generation": 1,
                                          "preconditions": {}, "intent": {"kind": "publish", "card": "12"}})
        self.service.effect_verifier = lambda effect, evidence: True
        requests = [
            {"command": "resolve", "action": "confirm_effect", "reason": "x", "effect_id": "boundary-effect",
             "evidence": {"operation_key": "boundary-effect"}},
            {"command": "card_pause", "card": 12},
            {"command": "release_reservations", "card": 12, "reason": "x"},
            {"command": "card_resume", "card": 12},
        ]
        for request in requests:
            with self.subTest(command=request["command"]):
                before = self.service.snapshot()
                if request["command"] == "release_reservations":
                    reservation = self.service.store.reserve_scope("12", ["src/card-12"], before["domain"]["revision"])
                    self.service.store.set_card_lifecycle("12", "paused", self.service.snapshot()["domain"]["revision"])
                    before = self.service.snapshot()
                    request["expected_reservation_revision"] = reservation["reservation_revision"]
                elif request["command"] == "card_resume":
                    self.service.store.set_card_lifecycle("12", "paused", before["domain"]["revision"])
                    before = self.service.snapshot()
                for field in ("request_id", "expected_revision"):
                    candidate = dict(request, request_id="boundary-test",
                                     expected_revision=before["domain"]["revision"])
                    candidate.pop(field)
                    with self.assertRaises(Exception):
                        self.service.handle_request(candidate, peer=None)
                self.assertEqual(self.service.snapshot(), before)

    def test_writer_uncertain_rejects_reconcile_without_writing(self):
        self.service.writer_uncertain = True
        before = self.service.snapshot()
        with self.assertRaisesRegex(Exception, "uncertain|writer"):
            self.service.reconcile_card(12, known=False)
        self.assertEqual(self.service.snapshot(), before)

    def test_writer_uncertain_rejects_resolve_and_lifecycle_commands_without_writing(self):
        self.service.writer_uncertain = True
        before = self.service.snapshot()
        with self.assertRaisesRegex(Exception, "uncertain|writer"):
            self.service.resolve(12, action="confirm_effect", request_id="uncertain-resolve", reason="x",
                                 effect_id="missing", expected_revision=before["domain"]["revision"])
        for command in ("start", "pause", "resume"):
            with self.subTest(command=command):
                with self.assertRaisesRegex(Exception, "uncertain|writer"):
                    self.service.handle_request({"command": command, "request_id": "uncertain-" + command,
                                                 "expected_revision": before["domain"]["revision"]}, peer=None)
                self.assertEqual(self.service.snapshot(), before)

    def test_socket_error_envelope_has_structured_code(self):
        """Web clients classify service failures by code, never by prose."""
        before = self.service.snapshot()
        self.service.writer_uncertain = True
        reply = self.service.handle_request_envelope({"command": "pause", "request_id": "coded-error",
                                                      "expected_revision": before["domain"]["revision"]}, peer=None)
        self.assertFalse(reply.get("ok"), "invalid lifecycle command unexpectedly succeeded")
        error = reply.get("error")
        self.assertIsInstance(error, dict, "socket error must be a structured object")
        self.assertIn(error.get("code"), ("stale_revision", "invalid", "unavailable", "uncertain_writer"))
        self.assertEqual(self.service.snapshot(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
