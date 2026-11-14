"""Offline control-surface contracts: the wire envelope, mutation binding and status v2.

The service has no store: it answers from the in-memory State and hands mutating commands to a
handler. Here the handler is the Phase 1 stub (status/pause/resume/stop on the State)."""
import inspect
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()

from supervisor import errors
from supervisor.service import Service
from stub_handler import StubHandler
from supervisor.state import Action, State


class FakeClock:
    def __init__(self, now=100):
        self.now = now

    def __call__(self):
        return self.now


class ControlContracts(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self.id().rsplit(".", 1)[-1]
        self.root.mkdir(mode=0o700)
        self.clock = FakeClock()
        self.state = State("run-test", self.clock)
        self.handler = StubHandler(self.state)
        self.service = Service(self.root, self.state, self.handler,
                               peer_resolver=lambda _peer: "fixture-human",
                               run_lock_path=str(self.root / "run.lock"))
        self.addCleanup(self.service.close)

    def call(self, request):
        return self.service.handle_request(request, peer=None)

    def envelope(self, request):
        return self.service.handle_request_envelope(request, peer=None)

    def revision(self):
        return self.call({"command": "status"})["revision"]

    def begin(self, card=12, kind="role"):
        self.state.begin(Action(card=card, action="review", column="in_review", role="reviewer",
                                provider="claude", paths=["src/a"], started_at=1.5, started_mono=2.5, kind=kind))

    # --- status v2 -------------------------------------------------------------------

    def test_status_shape_v2(self):
        status = self.call({"command": "status"})
        self.assertEqual(status["schema_version"], 2)
        self.assertIsInstance(status["pid"], int)
        self.assertEqual(status["root"], str(self.root))
        for key in ("run_id", "mode", "pause_reason", "revision", "active", "lane", "provider_health", "run_tokens", "queue"):
            self.assertIn(key, status)
        self.assertEqual(status["queue"], {"ready": None, "waiting": None})
        for gone in ("boot_registration", "session", "known_spend", "host_boot_id", "heartbeat", "capacity",
                     "config", "claims", "execution_available", "read_only", "phase", "desired_mode"):
            self.assertNotIn(gone, status, "removed status key %s is back" % gone)
        self.assertNotIn("known_spend", json.dumps(status))

    def test_status_active_is_a_list_of_action_objects_with_their_card(self):
        self.begin(12)
        self.begin(7)
        status = self.call({"command": "status"})
        self.assertIsInstance(status["active"], list)
        self.assertEqual(sorted(a["card"] for a in status["active"]), [7, 12])
        again = json.loads(json.dumps(status))
        self.assertEqual(again["active"], status["active"], "active must survive JSON unchanged (no int keys)")
        self.assertEqual(again["active"][0]["action"], "review")
        self.assertNotIn("session", again["active"][0])

    def test_status_tracks_the_state_mode_and_revision(self):
        self.assertEqual(self.call({"command": "status"})["mode"], "running")
        self.state.pause("provider down")
        status = self.call({"command": "status"})
        self.assertEqual((status["mode"], status["pause_reason"]), ("paused", "provider down"))
        self.assertEqual(status["revision"], self.state.revision)

    # --- mutation binding ------------------------------------------------------------

    def test_pause_and_resume_change_the_state_and_return_the_new_revision(self):
        paused = self.call({"command": "pause", "request_id": "p1", "expected_revision": self.revision()})
        self.assertEqual(self.state.mode, "paused")
        self.assertEqual(paused["mode"], "paused")
        self.assertEqual(paused["revision"], self.state.revision)
        resumed = self.call({"command": "resume", "request_id": "r1", "expected_revision": self.revision()})
        self.assertEqual(self.state.mode, "running")
        self.assertEqual(resumed["mode"], "running")

    def test_mutating_request_boundary_requires_request_id_and_expected_revision(self):
        for command, extra in (("pause", {}), ("resume", {}), ("stop", {"mode": "drain"})):
            for field in ("request_id", "expected_revision"):
                with self.subTest(command=command, missing=field):
                    before = self.state.revision
                    request = dict(extra, command=command, request_id="b-" + command,
                                   expected_revision=self.revision())
                    request.pop(field)
                    reply = self.envelope(request)
                    self.assertEqual(reply["error"]["code"], "invalid")
                    self.assertEqual(self.state.revision, before)
                    self.assertFalse(self.handler.stop_requested.is_set())
        bad = self.envelope({"command": "pause", "request_id": "x", "expected_revision": "7"})
        self.assertEqual(bad["error"]["code"], "invalid")

    def test_stale_revision_returns_current(self):
        self.state.pause("x")
        stale = self.envelope({"command": "resume", "request_id": "s1", "expected_revision": self.state.revision - 1})
        self.assertFalse(stale["ok"])
        self.assertEqual(stale["error"]["code"], "stale_revision")
        self.assertEqual(stale["error"]["current"]["revision"], self.state.revision)
        self.assertEqual(stale["error"]["current"]["schema_version"], 2)
        self.assertEqual(self.state.mode, "paused", "a stale request must change nothing")

    def test_a_replayed_request_id_returns_the_original_outcome_without_reapplying(self):
        request = {"command": "pause", "request_id": "same", "expected_revision": self.revision()}
        first = self.call(request)
        revision = self.state.revision
        second = self.call(request)
        self.assertEqual(first, second)
        self.assertEqual(self.state.revision, revision, "a replay bumped the revision")

    def test_a_reused_request_id_with_a_different_request_is_refused(self):
        revision = self.revision()
        self.call({"command": "pause", "request_id": "X", "expected_revision": revision})
        after = self.state.revision
        reply = self.envelope({"command": "stop", "mode": "drain", "request_id": "X", "expected_revision": revision})
        self.assertEqual(reply["error"]["code"], "invalid")
        self.assertIn("already used", reply["error"]["message"])
        self.assertFalse(self.handler.stop_requested.is_set(), "the stop was applied or answered with the pause outcome")
        self.assertEqual(self.state.revision, after)
        again = self.envelope({"command": "pause", "request_id": "X", "expected_revision": revision})
        self.assertTrue(again["ok"], "the identical request is still a replay")

    def test_stop_modes(self):
        for mode in ("drain", "cancel"):
            with self.subTest(mode=mode):
                state = State("run", self.clock)
                handler = StubHandler(state)
                service = Service(self.root, state, handler, peer_resolver=lambda _p: "u",
                                  run_lock_path=str(self.root / "stop.lock"))
                result = service.handle_request({"command": "stop", "mode": mode, "request_id": "st-" + mode,
                                                 "expected_revision": state.revision}, peer=None)
                self.assertEqual(result, {"stopping": True, "mode": mode})
                self.assertTrue(handler.stop_requested.is_set())
                self.assertEqual(handler.stop_mode, mode)
        for bad in (None, "", "bogus", 3):
            with self.subTest(bad=bad):
                reply = self.envelope({"command": "stop", "mode": bad, "request_id": "bad", "expected_revision": self.revision()})
                self.assertEqual(reply["error"]["code"], "invalid")

    def test_removed_commands_are_unsupported(self):
        for command in ("events", "reconcile", "resolve", "card_execution", "card_log", "card_pause", "card_resume",
                        "release_reservations", "start", "nonsense", None):
            with self.subTest(command=command):
                reply = self.envelope({"command": command, "request_id": "r", "expected_revision": self.revision()})
                self.assertEqual(reply["error"]["code"], "invalid")

    def test_an_actor_in_the_body_is_rejected_and_an_unauthenticated_peer_is_refused(self):
        reply = self.envelope({"command": "pause", "actor": "forged", "request_id": "a", "expected_revision": self.revision()})
        self.assertEqual(reply["error"]["code"], "invalid")
        self.service.peer_resolver = lambda _peer: (_ for _ in ()).throw(PermissionError("peer credentials unavailable"))
        self.assertEqual(self.envelope({"command": "status"})["error"]["code"], "unauthenticated")

    def test_oversized_request_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "size"):
            self.call({"command": "status", "padding": "x" * (1024 * 1024 + 1)})

    # --- the one classifier ----------------------------------------------------------

    def test_socket_error_envelope_has_structured_code(self):
        reply = self.envelope({"command": "pause"})
        self.assertFalse(reply["ok"])
        self.assertIsInstance(reply["error"], dict)
        self.assertEqual(reply["error"]["code"], "invalid")

    def test_one_classifier_maps_typed_exceptions_and_never_message_text(self):
        cases = [(errors.StaleRevision("anything"), "stale_revision"),
                 (errors.Unauthenticated("anything"), "unauthenticated"),
                 (errors.Invalid("anything"), "invalid"),
                 (errors.Unavailable("anything"), "unavailable"),
                 (errors.UnsafeSocketDir("anything"), "unsafe_socket_dir"),
                 (PermissionError("peer credentials unavailable"), "unauthenticated"),
                 (TimeoutError("controller request timed out"), "unavailable"),
                 # text a substring classifier would key on must not matter
                 (ValueError("revision mismatch"), "invalid"),
                 (ValueError("evidence unavailable"), "invalid"),
                 (TypeError("stale state revision"), "invalid"),
                 (RuntimeError("revision database is corrupt"), "internal"),
                 (KeyError("x"), "internal")]
        for exc, code in cases:
            with self.subTest(exc=repr(exc)):
                self.assertEqual(errors.classify(exc)["code"], code)
        self.assertTrue(issubclass(errors.StaleRevision, ValueError))
        self.assertTrue(issubclass(errors.Unauthenticated, PermissionError))
        for gone in ("Disabled", "UncertainWriter"):
            self.assertFalse(hasattr(errors, gone), gone + " is dead with the store")

    def test_internal_errors_are_redacted_for_the_browser_and_logged_server_side(self):
        detail = "boom at /Users/someone/.fleet-board/runs/supervisor/secret"
        with mock.patch.object(self.service, "_handle_request", side_effect=RuntimeError(detail)):
            with self.assertLogs("supervisor", level="ERROR") as logs:
                reply = self.service.handle_request_envelope({"command": "status"}, peer=None)
        self.assertEqual(reply["error"]["code"], "internal")
        self.assertNotIn("/Users", json.dumps(reply))
        self.assertIn(detail, "\n".join(logs.output), "the detail must reach the server log")

    def test_service_errors_carry_their_code_through_the_envelope(self):
        revision = self.revision()
        with mock.patch.object(self.service, "_handle_request", side_effect=ValueError("revision unavailable")):
            self.assertEqual(self.envelope({"command": "status"})["error"]["code"], "invalid")
        stale = self.envelope({"command": "pause", "request_id": "r-stale", "expected_revision": revision - 1})
        self.assertEqual(stale["error"]["code"], "stale_revision")
        self.assertIn("current", stale["error"])

    def test_socket_handler_and_envelope_share_one_classifier(self):
        source = inspect.getsource(Service)
        for text in ('"revision mismatch" in', '"stale state revision" in', '"unavailable" in message',
                     '"timed out" in message'):
            self.assertNotIn(text, source, "message-text classification is in the service")
        self.assertGreaterEqual(source.count("error_envelope("), 2, "both entry points must use the one classifier")

    def test_the_service_has_no_store_or_removed_machinery(self):
        import supervisor.service as module
        source = inspect.getsource(module)
        for text in ("Store", "recovery", "boot_registration", "host_boot_id", "UncertainWriter", "Disabled",
                     "known_spend", "execution_enabled", "worker_socket"):
            self.assertNotIn(text, source, text + " survives in service.py")


if __name__ == "__main__":
    unittest.main(verbosity=2)
