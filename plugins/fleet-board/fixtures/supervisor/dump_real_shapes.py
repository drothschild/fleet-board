"""Drift guard: dump the status payloads a REAL Service produces, as board-web serves them.

tests/supervisor-ui.js feeds this JSON into the DOM harness, so the UI can never again
agree with an invented fixture while the supervisor serves something else.

Usage: PYTHONPATH=<plugin>/scripts python3 dump_real_shapes.py <output.json>

Scenarios:
  idle    running, nothing active
  paused  paused with a reason
  active  running with two actions in flight (cards 4 and 9, different providers)
"""
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from supervisor import webproxy
from supervisor.service import Service
from stub_handler import StubHandler
from supervisor.state import Action, State

NOW = datetime(2026, 11, 10, 18, 0, 0, tzinfo=timezone.utc).timestamp()


def build_service(base, name):
    root = Path(base) / name
    root.mkdir(parents=True)
    state = State("run-" + name, lambda: NOW)
    return Service(root, state, StubHandler(state), run_lock_path=str(root / "run.lock")), state


def action(card, provider, role):
    return Action(card=card, action="review", column="in_review", role=role, provider=provider,
                  paths=["src/card-%d" % card], started_at=NOW - 90, started_mono=1000.0)


def scenario_idle(state):
    pass


def scenario_paused(state):
    state.pause("provider claude is unhealthy")


def scenario_active(state):
    state.begin(action(4, "claude", "reviewer"))
    state.begin(action(9, "codex", "implementor"))


SCENARIOS = {"idle": scenario_idle, "paused": scenario_paused, "active": scenario_active}


def main(out_path):
    base = os.path.realpath(tempfile.mkdtemp(prefix="fb-real-shapes-"))
    result = {}
    try:
        for name, build in SCENARIOS.items():
            service, state = build_service(base, name)
            try:
                build(state)
                # Exactly what board-web serves: the UI projection of the status plus its reachability flag.
                result[name] = {"status": dict(webproxy.ui_status(service.status_view()), unreachable=False)}
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
