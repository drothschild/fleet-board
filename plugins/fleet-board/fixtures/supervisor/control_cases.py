"""Offline service-side status, event, card-control and resolution contracts."""
import os
import sys
import json
import unittest
from pathlib import Path
from unittest import mock
import hashlib
import shutil
import tempfile

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
        # Short real directory: AF_UNIX paths are length-limited and the base is never replaced.
        self.socket_tmp = Path(tempfile.mkdtemp(prefix="fbc-", dir=os.path.realpath("/tmp")))
        self.addCleanup(shutil.rmtree, str(self.socket_tmp), True)
        self.config = self.root / "enabled.yml"
        self.config.write_text("board:\n  repo: acme/toy\nsupervisor:\n  enabled: true\n", encoding="utf-8")
        self.domain = {"common_dir": str(self.root), "board_backend": "local",
                       "board_identity": "control-fixture", "runtime_root": str(self.root / "runtime")}
        self.clock = FakeClock()
        env = {"FLEET_BOARD_SOCKET_DIR": str(self.socket_tmp), "FLEET_BOARD_LOG_DIR": str(self.root / "logs"),
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

    def test_card_execution_serves_the_ui_facing_fields_computed_from_real_state(self):
        execution = self.require_api("card_execution")
        store = self.service.store
        idle = execution(12)
        self.assertEqual((idle["paused"], idle["writer"], idle["reservation_state"], idle["retry_count"],
                          idle["attempt_history"], idle["wait_reason"] is None),
                         (False, False, "none", 0, [], True))
        # A live writer: running, with real heartbeat and progress observations.
        self.make_attempt()
        store.update_attempt("attempt-12", {"state": "running", "started_at": 40, "deadline": 500,
                                            "heartbeat": 92, "progress": {"at": 87, "sequence": 1, "kind": "checkpoint"}},
                             store.snapshot()["domain"]["revision"])
        store._Store__connection.execute("UPDATE jobs SET retries_used=2 WHERE id='job-12'")
        live = execution(12)
        self.assertEqual((live["activity"], live["elapsed_seconds"], live["heartbeat_age_seconds"],
                          live["progress_age_seconds"], live["retry_count"], live["writer"], live["paused"],
                          live["reservation_state"]),
                         ("running", 60, 8, 13, 2, True, False, "held"))
        # the pre-existing keys keep their meaning and now carry the real ages
        self.assertEqual((live["heartbeat_age"], live["progress_age"], live["retries"]["automatic"]), (8, 13, 2))
        self.assertEqual(live["reservation_revision"],
                         next(x for x in self.service.snapshot()["reservations"] if x["card"] == "12")["reservation_revision"])
        self.assertEqual([(x["id"], x["state"], x["provider"]) for x in live["attempt_history"]],
                         [("attempt-12", "running", "fixture")])
        # Quarantined: still a writer (uncertain) and says so.
        store.quarantine_attempt("attempt-12", "writer state uncertain", store.snapshot()["domain"]["revision"])
        quarantined = execution(12)
        self.assertEqual((quarantined["activity"], quarantined["writer"]), ("quarantined", True))
        self.assertEqual(quarantined["attempt_history"][0]["state"], "quarantined")
        self.assertEqual(quarantined["attempt_history"][0]["quarantine_reason"], "writer state uncertain")

    def test_card_execution_paused_card_with_held_then_released_reservation(self):
        execution = self.require_api("card_execution")
        store = self.service.store
        reservation = store.reserve_scope("12", ["src/card-12"], store.snapshot()["domain"]["revision"])
        self.service.card_pause(12, mode="drain", request_id="pause-exec-shape",
                                expected_revision=store.snapshot()["domain"]["revision"])
        held = execution(12)
        self.assertEqual((held["paused"], held["writer"], held["reservation_state"], held["reservation_revision"]),
                         (True, False, "held", reservation["reservation_revision"]))
        self.assertTrue(held["wait_reason"], "a paused card must say why it is not progressing")
        self.service.release_reservations(12, reason="reviewed", expected_revision=store.snapshot()["domain"]["revision"],
                                          expected_reservation_revision=held["reservation_revision"])
        released = execution(12)
        self.assertEqual((released["paused"], released["reservation_state"]), (True, "released"))

    def test_card_execution_names_the_card_a_scope_wait_is_blocked_on(self):
        execution = self.require_api("card_execution")
        store = self.service.store
        store.reserve_scope("13", ["src/shared"], store.snapshot()["domain"]["revision"])
        with self.assertRaises(ValueError):
            store.reserve_scope("12", ["src/shared"], store.snapshot()["domain"]["revision"])
        waiting = execution(12)
        self.assertEqual(waiting["blocking_card"], "13")
        self.assertIn("scope", waiting["wait_reason"])
        self.assertIn("13", waiting["wait_reason"])

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

    def test_resume_claims_only_what_it_did(self):
        resume = self.require_api("card_resume")
        store = self.service.store
        revision = lambda: store.snapshot()["domain"]["revision"]
        # A card that is not paused: nothing changes, so nothing is applied or refreshed.
        idle = resume(12, request_id="resume-idle", expected_revision=revision())
        self.assertEqual((idle["applied"], idle["refreshed"]), (False, False))
        self.assertNotIn("preserved_budget_stop", idle, "resume never checked the budget stop")
        # A paused card really flips lifecycle: applied is true, refresh still is not claimed.
        self.service.card_pause(12, mode="drain", request_id="pause-for-resume", expected_revision=revision())
        self.assertEqual(store._card_lifecycles()["12"], "paused")
        resume_revision = revision()
        resumed = resume(12, request_id="resume-paused", expected_revision=resume_revision)
        self.assertEqual((resumed["applied"], resumed["refreshed"]), (True, False))
        self.assertNotEqual(store._card_lifecycles()["12"], "paused")
        self.assertNotIn("preserved_budget_stop", resumed)
        replay = resume(12, request_id="resume-paused", expected_revision=resume_revision)
        self.assertEqual((replay["applied"], replay["refreshed"]), (False, False), "a replay applies nothing")

    def test_resume_of_a_human_qa_card_changes_nothing_and_still_validates_the_binding(self):
        resume = self.require_api("card_resume")
        store = self.service.store
        store.set_card_lifecycle("12", "human_qa", store.snapshot()["domain"]["revision"])
        before = store.snapshot()
        revision = before["domain"]["revision"]
        result = resume(12, request_id="resume-qa", expected_revision=revision)
        self.assertEqual((result["applied"], result["refreshed"], result["preserved_human_qa"]), (False, False, True))
        self.assertEqual(store._card_lifecycles()["12"], "human_qa")
        for bad in ({"request_id": "", "expected_revision": revision},
                    {"request_id": None, "expected_revision": revision},
                    {"request_id": "r", "expected_revision": None},
                    {"request_id": "r", "expected_revision": str(revision)}):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(ValueError, "request_id|expected_revision"):
                    resume(12, **bad)
        from supervisor import errors
        with self.assertRaises(errors.StaleRevision):
            resume(12, request_id="resume-qa-stale", expected_revision=revision - 1)
        self.assertEqual(store.snapshot(), before, "a refused resume must not write")

    def test_unresolved_shutdown_gates_card_resume_release_and_reconcile(self):
        store = self.service.store
        store.reserve_scope("12", ["src/card-12"], store.snapshot()["domain"]["revision"])
        self.service.card_pause(12, mode="drain", request_id="pause-gate", expected_revision=store.snapshot()["domain"]["revision"])
        self.service.writer_uncertain = True
        before = store.snapshot()
        revision = before["domain"]["revision"]
        from supervisor import errors
        with self.assertRaises(errors.UncertainWriter):
            self.service.card_resume(12, request_id="resume-gated", expected_revision=revision)
        with self.assertRaises(errors.UncertainWriter):
            self.service.release_reservations(12, reason="x", expected_revision=revision,
                                              expected_reservation_revision=1)
        with self.assertRaises(errors.UncertainWriter):
            self.service.reconcile_card(12, known=True)
        for request in ({"command": "card_resume", "card": 12, "request_id": "resume-gated-2", "expected_revision": revision},
                        {"command": "release_reservations", "card": 12, "reason": "x", "request_id": "rel-gated",
                         "expected_revision": revision, "expected_reservation_revision": 1}):
            reply = self.service.handle_request_envelope(request, peer=None)
            self.assertEqual(reply["error"]["code"], "uncertain_writer", request["command"])
        self.assertEqual(store.snapshot(), before)
        self.assertEqual(store._card_lifecycles()["12"], "paused", "an unresolved shutdown flipped a card")

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

    def test_one_classifier_maps_typed_exceptions_and_never_message_text(self):
        from supervisor import errors
        cases = [(errors.StaleRevision("anything"), "stale_revision"),
                 (errors.UncertainWriter("anything"), "uncertain_writer"),
                 (errors.Disabled("anything"), "disabled"),
                 (errors.Unauthenticated("anything"), "unauthenticated"),
                 (errors.Invalid("anything"), "invalid"),
                 (errors.Unavailable("anything"), "unavailable"),
                 (PermissionError("peer credentials unavailable"), "unauthenticated"),
                 (TimeoutError("controller request timed out"), "unavailable"),
                 # text that the old substring classifier keyed on must not matter
                 (ValueError("revision mismatch"), "invalid"),
                 (ValueError("evidence unavailable"), "invalid"),
                 (ValueError("uncertain writer"), "invalid"),
                 (TypeError("stale state revision"), "invalid"),
                 (RuntimeError("revision database is corrupt"), "internal"),
                 (RuntimeError("supervisor.enabled: false"), "internal"),
                 (KeyError("x"), "internal")]
        for exc, code in cases:
            with self.subTest(exc=repr(exc)):
                self.assertEqual(errors.classify(exc)["code"], code)
        self.assertTrue(issubclass(errors.StaleRevision, ValueError))
        self.assertTrue(issubclass(errors.Unauthenticated, PermissionError))

    def test_internal_errors_are_redacted_for_the_browser_and_logged_server_side(self):
        detail = "sqlite3 failed at /Users/someone/.fleet-board/runs/supervisor/store.sqlite3"
        with mock.patch.object(self.service, "_handle_request", side_effect=RuntimeError(detail)):
            with self.assertLogs("supervisor", level="ERROR") as logs:
                reply = self.service.handle_request_envelope({"command": "status"}, peer=None)
        self.assertEqual(reply["error"]["code"], "internal")
        self.assertNotIn("sqlite", reply["error"]["message"])
        self.assertNotIn("/Users", json.dumps(reply))
        self.assertIn(detail, "\n".join(logs.output), "the detail must reach the server log")

    def test_service_errors_carry_their_code_through_the_envelope(self):
        revision = self.service.get_status()["revision"]
        service = self.service
        def code(request, **kw):
            reply = service.handle_request_envelope(request, peer=None)
            self.assertFalse(reply["ok"], request)
            return reply["error"]
        stale = code({"command": "pause", "request_id": "r-stale", "expected_revision": revision - 1})
        self.assertEqual(stale["code"], "stale_revision"); self.assertIn("current", stale)
        release = code({"command": "release_reservations", "card": 12, "reason": "x", "request_id": "r-rel",
                        "expected_revision": revision - 1, "expected_reservation_revision": 0})
        self.assertEqual(release["code"], "stale_revision")
        self.assertEqual(code({"command": "pause"})["code"], "invalid")
        self.assertEqual(code({"command": "pause", "actor": "x", "request_id": "r", "expected_revision": revision})["code"], "invalid")
        service.peer_resolver = lambda _peer: (_ for _ in ()).throw(PermissionError("peer credentials unavailable"))
        self.assertEqual(code({"command": "status"})["code"], "unauthenticated")
        service.peer_resolver = lambda _peer: "fixture-human"
        service.execution_enabled = False
        disabled = code({"command": "start", "request_id": "r-start", "expected_revision": revision})
        self.assertEqual(disabled["code"], "disabled")
        self.assertIn("supervisor.enabled", disabled["message"])
        service.execution_enabled = True
        service.writer_uncertain = True
        self.assertEqual(code({"command": "pause", "request_id": "r-u", "expected_revision": revision})["code"], "uncertain_writer")
        service.writer_uncertain = False
        with mock.patch.object(service, "_handle_request", side_effect=ValueError("revision unavailable")):
            self.assertEqual(code({"command": "status"})["code"], "invalid")

    def test_socket_handler_and_envelope_share_one_classifier(self):
        import inspect
        source = inspect.getsource(Service)
        for text in ('"revision mismatch" in', '"stale state revision" in', '"unavailable" in message',
                     '"uncertain writer" in message', '"timed out" in message'):
            self.assertNotIn(text, source, "message-text classification is still in the service")
        self.assertGreaterEqual(source.count("error_envelope("), 2, "both entry points must use the one classifier")

    def test_default_shutdown_observer_fails_closed_on_live_or_uncertain_attempts(self):
        store = self.service.store
        self.assertEqual(self.service.shutdown_observer(), "stopped", "nothing in the store: nothing to wait for")
        self.make_attempt()
        self.assertEqual(self.service.shutdown_observer(), "stopped", "a prepared attempt never launched a writer")
        revision = lambda: store.snapshot()["domain"]["revision"]
        for state in ("launching", "running", "result_ready"):
            with self.subTest(state=state):
                store.update_attempt("attempt-12", {"state": state}, revision())
                self.assertEqual(self.service.shutdown_observer(), "unknown")
        store.update_attempt("attempt-12", {"state": "running"}, revision())
        store.quarantine_attempt("attempt-12", "writer state uncertain", revision())
        self.assertEqual(self.service.shutdown_observer(), "unknown", "a quarantined attempt is an uncertain writer")
        # Released execution is a stopped writer again.
        data = json.loads(next(x for x in store.snapshot()["attempts"] if x["id"] == "attempt-12")["data"])
        data["execution_released"] = True
        store._Store__connection.execute("UPDATE attempts SET data=? WHERE id='attempt-12'", (json.dumps(data),))
        self.assertEqual(self.service.shutdown_observer(), "stopped")

    def test_queue_ready_is_unknown_until_a_scheduler_knows_the_board(self):
        # The service does not read board cards, so a 0 would be a false statement.
        queue = self.service.get_status()["queue"]
        self.assertIsNone(queue["ready"], "queue.ready must be unknown (null), never a made-up 0")
        self.assertIsNone(self.service.status_view()["queue"]["ready"])

    def test_cancel_requested_attempt_is_still_a_possible_writer_for_the_default_observer(self):
        # `stop --mode cancel` puts every live attempt in cancel_requested BEFORE stop_serving():
        # a requested cancellation is not a stopped writer until the runner confirms it.
        store = self.service.store
        self.make_attempt()
        revision = lambda: store.snapshot()["domain"]["revision"]
        store.update_attempt("attempt-12", {"state": "running"}, revision())
        store.request_cancellation("attempt-12", "cancel-1", "supervisor stop requested", revision(), now=self.clock())
        state = next(x for x in store.snapshot()["attempts"] if x["id"] == "attempt-12")["state"]
        self.assertEqual(state, "cancel_requested")
        self.assertEqual(self.service.shutdown_observer(), "unknown")

    def test_stop_with_a_live_attempt_and_no_injected_observer_is_unresolved_not_terminated(self):
        store = self.service.store
        self.make_attempt()
        store.update_attempt("attempt-12", {"state": "running"}, store.snapshot()["domain"]["revision"])
        result = self.service.stop(mode="drain", request_id="stop-live", expected_revision=store.snapshot()["domain"]["revision"],
                                   actor="fixture-human")
        self.assertEqual((result["status"], result["terminated"]), ("unresolved_shutdown", False))
        self.assertTrue(self.service.writer_uncertain)
        self.assertEqual(self.service.status()["shutdown"], "unresolved")

    def test_concurrent_reconcile_requests_are_serialized_and_use_their_own_store_handle(self):
        import threading, time
        service = self.service
        owner_store = service.store
        state = {"inflight": 0, "max": 0, "wrong": 0}
        guard = threading.Lock()
        def reconcile(now):
            with guard:
                state["inflight"] += 1
                state["max"] = max(state["max"], state["inflight"])
            if service.recovery.store is not service._store():
                state["wrong"] += 1  # another thread's (possibly closed) handle
            time.sleep(0.02)
            with guard:
                state["inflight"] -= 1
        errors = []
        def request():
            try:
                service._handle_request({"command": "reconcile"}, peer=None)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
            finally:
                service._close_thread_store()  # what the connection handler does
        with mock.patch.object(service.recovery, "reconcile", side_effect=reconcile):
            threads = [threading.Thread(target=request) for _ in range(6)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(10)
        self.assertEqual(errors, [])
        self.assertEqual((state["max"], state["wrong"]), (1, 0), state)
        self.assertIs(service.recovery.store, owner_store,
                      "the shared Recovery must go back to the owner's handle, never keep a finished thread's")


if __name__ == "__main__":
    unittest.main(verbosity=2)
