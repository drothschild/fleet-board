"""Drift guard: dump the status and card-execution payloads a REAL Service produces.

tests/supervisor-ui.js feeds this JSON into the DOM harness, so the UI can never again
agree with an invented fixture while the service serves something else.

Usage: PYTHONPATH=<plugin>/scripts python3 dump_real_shapes.py <output.json>

Scenarios (all for card 4):
  paused       a held reservation, the card paused, no attempt at all (no writer)
  writer       a prepared attempt whose execution is not released (a live writer)
  quarantined  an attempt quarantined as uncertain (still a writer)
"""
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from supervisor.service import Service

NOW = datetime(2026, 11, 10, 18, 0, 0, tzinfo=timezone.utc).timestamp()
CARD = "4"


def build_service(base, name):
    root = Path(base) / name
    repo = root / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / ".fleet-board.yml").write_text(
        "board:\n  repo: acme/toy\nsupervisor:\n  enabled: true\nlimits:\n  concurrency: 3\n",
        encoding="utf-8")
    domain = {"common_dir": str(repo / ".git"), "board_backend": "local",
              "board_identity": str(repo), "runtime_root": str(root / "runtime")}
    service = Service.open(domain, clock=lambda: NOW, host_boot_id="boot-real",
                           peer_resolver=lambda _peer: "fixture-human",
                           run_lock_path=str(root / "run.lock"), board_repo=str(repo),
                           execution_enabled=True)
    store = service.store
    store.start_session({"id": "s1", "started_at": NOW - 600, "deadline": NOW + 3600,
                         "known_spend": 1.25, "unknown_spend": False, "budget_stop": None})
    return service


def revision(service):
    return service.snapshot()["domain"]["revision"]


def prepare(service, nonce):
    job = {"id": "job-" + nonce, "card": CARD, "action": "implement", "role": "implementor",
           "stage": "build", "round": 1, "input_sha": "a" * 64, "input_version": "v1",
           "generation": 1, "provider": "fixture", "model": "fixture", "nonce": nonce,
           "session_id": "s1"}
    service.store.prepare_attempt(job, revision(service),
                                  {"global_cap": 3, "provider_cap": 3, "paths": ["src/card-4"]})
    return job


def scenario_paused(service):
    store = service.store
    store.reserve_scope(CARD, ["src/card-4"], revision(service))
    service.card_pause(CARD, mode="drain", request_id="pause-4", expected_revision=revision(service))


def scenario_writer(service):
    prepare(service, "attempt-live")
    service.store.update_attempt("attempt-live", {"state": "running", "started_at": NOW - 120,
                                                  "deadline": NOW + 1800, "heartbeat": NOW - 8,
                                                  "progress": {"at": NOW - 13, "sequence": 1,
                                                               "kind": "checkpoint"}},
                                 revision(service))


def scenario_quarantined(service):
    prepare(service, "attempt-quarantined")
    service.store.quarantine_attempt("attempt-quarantined", "writer state uncertain",
                                     revision(service))


SCENARIOS = {"paused": scenario_paused, "writer": scenario_writer,
             "quarantined": scenario_quarantined}


def main(out_path):
    base = os.path.realpath(tempfile.mkdtemp(prefix="fb-real-shapes-"))
    result = {}
    try:
        for name, build in SCENARIOS.items():
            service = build_service(base, name)
            try:
                build(service)
                # Exactly what board-web serves: the status view plus its reachability flag.
                result[name] = {"status": dict(service.status_view(), unreachable=False),
                                "execution": service.card_execution(CARD)}
            finally:
                service.close()
        Path(out_path).write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: dump_real_shapes.py <output.json>", file=sys.stderr)
        raise SystemExit(2)
    main(sys.argv[1])
