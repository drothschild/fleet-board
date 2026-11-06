#!/usr/bin/env python3
"""board-web.py - serves the local fleet-board board over a localhost API.

Usage: python3 board-web.py --root <abs repo root> --port <int> --scripts <abs scripts dir>

Reads come straight from the card files under <root>/<board.dir>/cards/; every
write runs the script an agent would run (board-create.sh, board-move.sh,
board-comment.sh, adapters/local/edit.sh) with cwd = the repo root. The server
never writes a card file itself. Binds 127.0.0.1 only; the first stdout line is
`listening on http://127.0.0.1:<port>`; requests are logged to stderr.

Environment: FLEET_BOARD_LOG_DIR (parent of the runtime data, default ~/.fleet-board),
FLEET_BOARD_RUN (headless wrapper override), FLEET_BOARD_CLAUDE (the claude binary the
import session runs, default `claude`), FLEET_BOARD_PLUGIN_DIR (when set, the import
session gets `--plugin-dir <value>`), FLEET_BOARD_TEST_IMPORT_ID (tests only: used as
the import id instead of a generated one).
"""
from __future__ import annotations

import argparse
import errno
import getpass
import json
import os
import re
import secrets
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKER = "<!-- fleet-board:manager-note -->"
NOTE_FIELDS = ("round", "pr", "models", "stage", "action_failures")
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
}

# Set by main(): root (str), scripts (str), port (int), static (Path).
APP: dict = {}


class ApiError(Exception):
    """An error with an HTTP status, returned to the client as {"error": msg}."""

    def __init__(self, code: int, msg: str, extra: dict = None):
        super().__init__(msg)
        self.code = code
        self.msg = msg
        self.extra = extra or {}


# --- config and store readers -------------------------------------------------

_CONFIG_CACHE: dict = {}
_STATES_CACHE: dict = {}


def config_path(root: str) -> Path:
    env = os.environ.get("FLEET_BOARD_CONFIG")
    return Path(env) if env else Path(root) / ".fleet-board.yml"


def load_config(root: str, scripts: str) -> dict:
    """The merged config from config.sh, cached by the config file's mtime."""
    try:
        mtime = config_path(root).stat().st_mtime_ns
    except OSError:
        mtime = None
    key = (root, scripts)
    hit = _CONFIG_CACHE.get(key)
    if hit is not None and mtime is not None and hit[0] == mtime:
        return hit[1]
    rc, out, err = run_script(root, ["bash", os.path.join(scripts, "config.sh"), "--dir", root])
    if rc != 0:
        raise ApiError(500, err.rstrip("\n") or "config.sh exited %d" % rc)
    cfg = json.loads(out)
    _CONFIG_CACHE[key] = (mtime, cfg)
    return cfg


def states(cfg: dict) -> list:
    """[{key, name}] in FB_STATES order, from one bash call into board-lib.sh."""
    cache_key = json.dumps(cfg, sort_keys=True)
    hit = _STATES_CACHE.get(cache_key)
    if hit is not None:
        return hit
    prog = (
        '. "$1/board-lib.sh" && fb_load_config || exit $?; '
        'for s in $FB_STATES; do printf "%s\\t%s\\n" "$s" "$(fb_state_name "$s")"; done'
    )
    rc, out, err = run_script(APP["root"], ["bash", "-c", prog, "states", APP["scripts"]])
    if rc != 0:
        raise ApiError(500, err.rstrip("\n") or "cannot list the board states")
    result = []
    for line in out.splitlines():
        if "\t" in line:
            k, name = line.split("\t", 1)
            result.append({"key": k, "name": name})
    _STATES_CACHE[cache_key] = result
    return result


def store_dir(root: str, cfg: dict) -> Path:
    return Path(root) / ((cfg.get("board") or {}).get("dir") or ".fleet-board")


def read_card_file(path: Path):
    """The card dict in <path>, or None when it is missing or not a JSON object."""
    try:
        card = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        sys.stderr.write("board-web: skipping %s: %s\n" % (path, exc))
        return None
    return card if isinstance(card, dict) else None


def read_cards(dir: Path) -> list:
    """Every card under <dir>/cards, sorted by number."""
    cards = []
    for path in sorted((Path(dir) / "cards").glob("*.json")):
        if not path.stem.isdigit():
            continue
        card = read_card_file(path)
        if card is not None:
            cards.append(card)
    cards.sort(key=lambda c: c.get("number") if isinstance(c.get("number"), int) else 0)
    return cards


def read_card(dir: Path, n: int) -> dict:
    card = read_card_file(Path(dir) / "cards" / ("%d.json" % n))
    if card is None:
        raise ApiError(404, "card #%d not found" % n)
    return card


def local_user() -> str:
    """FLEET_BOARD_USER, else USER, else the login name (fb_login's order); raises when empty."""
    user = os.environ.get("FLEET_BOARD_USER") or os.environ.get("USER")
    if not user:
        try:
            user = getpass.getuser()
        except Exception:  # noqa: BLE001 - no passwd entry, no LOGNAME
            user = ""
    if not user:
        raise ApiError(500, "cannot determine the local user: set FLEET_BOARD_USER")
    return user


def note_comment(card: dict):
    """The last marker comment by the local identity, or None."""
    me = local_user()
    for c in reversed(card.get("comments") or []):
        if not isinstance(c, dict):
            continue
        body = c.get("body")
        if isinstance(body, str) and body.startswith(MARKER) and c.get("author") == me:
            return c
    return None


def note_body(card: dict):
    """The manager note's body without its marker line, or None."""
    c = note_comment(card)
    if c is None:
        return None
    return c["body"].split("\n", 1)[1] if "\n" in c["body"] else ""


def parse_note(card: dict):
    """The note's fenced JSON object, or None (no note, bad fence, invalid JSON)."""
    body = note_body(card)
    if body is None:
        return None
    block, on = [], False
    for line in body.split("\n"):
        if not on:
            if line == "```json":
                on = True
            continue
        if line == "```":
            try:
                note = json.loads("\n".join(block))
            except ValueError:
                return None
            return note if isinstance(note, dict) else None
        block.append(line)
    return None


def is_active(dir: Path, n, alive: bool) -> bool:
    return alive and (Path(dir) / "active" / str(n)).exists()


# --- run state ----------------------------------------------------------------

STOP_FILE = ".fleet-board.stop"
STOPPED_RE = re.compile(
    r"^fleet-board-run: stopped: (.+?) after \d+ ticks, ([0-9.]+) h, cost_estimate_usd (\S+)",
    re.M,
)
LOG_RE = re.compile(r"^fleet-board-run: log: (.+)$", re.M)
TICK_RE = re.compile(r"^=== tick (\d+)\b")
LOG_TAIL_LINES = 200

# proc: the Popen this server spawned (kept so it is reaped); alive: the last
# observed liveness (None before the first look); holder: the live wrapper's pid.
_RUN: dict = {"proc": None, "alive": None, "holder": None}
_RUN_LOCK = threading.RLock()


def state_dir(root: str, cfg: dict) -> Path:
    """<FLEET_BOARD_LOG_DIR or ~/.fleet-board>/web/<owner>-<name>/, created mode 700."""
    base = os.environ.get("FLEET_BOARD_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".fleet-board")
    repo = (cfg.get("board") or {}).get("repo") or os.path.basename(root)
    path = Path(base) / "web" / re.sub(r"[^A-Za-z0-9._-]", "-", repo)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(str(path), 0o700)
    return path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def run_lock_path(cfg: dict) -> Path:
    """The wrapper's run lock, <FLEET_BOARD_LOG_DIR or ~/.fleet-board/runs>/<owner>-<name>.lock."""
    base = os.environ.get("FLEET_BOARD_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".fleet-board", "runs")
    repo = (cfg.get("board") or {}).get("repo") or os.path.basename(APP["root"])
    return Path(os.path.abspath(base)) / (repo.replace("/", "-") + ".lock")


def read_pid_file(sdir: Path):
    """(pid or None, recorded start time or ""). run.pid: line 1 the pid, line 2 its ps lstart."""
    return read_pid_path(sdir / "run.pid")


def read_pid_path(path: Path):
    """(pid or None, start time or "") from a run.pid-shaped file (the page's, or the wrapper's lock)."""
    lines = read_text(path).split("\n")
    try:
        pid = int(lines[0].strip())
    except ValueError:
        return None, ""
    if pid <= 0:
        return None, ""
    return pid, (lines[1].strip() if len(lines) > 1 else "")


def read_pid(sdir: Path):
    return read_pid_file(sdir)[0]


def ps_start(pid: int):
    """The process start time from ps ('' when no such process), or None when ps is unusable."""
    try:
        proc = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                              capture_output=True, text=True, env=dict(os.environ, LC_ALL="C", TZ="UTC"))
    except OSError:
        return None
    if proc.returncode not in (0, 1):
        return None
    return " ".join(proc.stdout.split())


def pid_alive(pid: int, started: str = "") -> bool:
    """Whether pid is our wrapper: the server's own child, else a live pid with the recorded start time."""
    proc = _RUN["proc"]
    if proc is not None and proc.pid == pid:
        return proc.poll() is None
    if started:
        now = ps_start(pid)
        if now is not None and now != started:
            return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def clear_markers(dir: Path):
    try:
        entries = list((Path(dir) / "active").iterdir())
    except OSError:
        return
    for entry in entries:
        try:
            if entry.is_file() or entry.is_symlink():
                entry.unlink()
        except OSError:
            pass


def run_alive() -> bool:
    """Whether a wrapper is alive: the one this page started (run.pid), else any wrapper
    holding the repo's run lock (one started from a terminal or launchd). Sets
    _RUN["holder"] to the live wrapper's pid. The first look after it died clears the markers."""
    cfg, dir = ctx()
    with _RUN_LOCK:
        pid, started = read_pid_file(state_dir(APP["root"], cfg))
        alive = pid is not None and pid_alive(pid, started)
        if not alive:
            pid, started = read_pid_path(run_lock_path(cfg))
            alive = pid is not None and bool(started) and pid_alive(pid, started)
        if _RUN["alive"] and not alive:
            clear_markers(dir)
        _RUN["alive"] = alive
        _RUN["holder"] = pid if alive else None
        return alive


def scan_run_log(path: str):
    """(last tick number or None, last LOG_TAIL_LINES lines) of the run log."""
    tick, tail = None, deque(maxlen=LOG_TAIL_LINES)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                tail.append(line)
                m = TICK_RE.match(line)
                if m:
                    tick = int(m.group(1))
    except OSError:
        pass
    return tick, list(tail)


def to_float(s: str):
    try:
        return float(s)
    except ValueError:
        return None


def run_status(alive=None) -> dict:
    """The run status; pass alive when the caller already checked liveness this request."""
    cfg, _ = ctx()
    sdir = state_dir(APP["root"], cfg)
    if alive is None:
        alive = run_alive()
    pid = read_pid(sdir)
    out = read_text(sdir / "run.out")
    if alive:
        if _RUN["holder"] and _RUN["holder"] != pid:
            # a wrapper this page did not start: run.out describes an older run
            pid, out = _RUN["holder"], ""
        state = "stopping" if (Path(APP["root"]) / STOP_FILE).exists() else "running"
    elif pid is None:
        state = "idle"
    else:
        state = "stopped" if out.strip() else "idle"
    log = LOG_RE.search(out)
    log_path = log.group(1) if log else None
    stops = STOPPED_RE.findall(out)
    tick, tail = scan_run_log(log_path) if log_path else (None, [])
    return {
        "state": state,
        "pid": pid,
        "tick": tick,
        "stop_reason": stops[-1][0] if stops else None,
        "cost": to_float(stops[-1][2]) if stops else None,
        "hours": to_float(stops[-1][1]) if stops else None,
        "log_path": log_path,
        "log_tail": tail,
        "out_tail": out_tail(out) if state == "stopped" and not stops else None,
    }


OUT_TAIL_LINES = 20


def out_tail(out: str) -> list:
    """The first and last lines of run.out (at most OUT_TAIL_LINES): what a wrapper that
    exited before its stopped: line printed, such as a config or run-lock error."""
    lines = [line for line in out.split("\n") if line.strip()]
    if len(lines) <= OUT_TAIL_LINES:
        return lines
    half = OUT_TAIL_LINES // 2
    return lines[:half] + lines[-half:]


def board_run_status(alive: bool) -> dict:
    """run_status() without the log tail, for /api/board."""
    status = run_status(alive)
    del status["log_tail"]
    return status


# --- script runner ------------------------------------------------------------

def run_script(root: str, argv: list, stdin=None):
    """Runs argv with cwd = root; returns (rc, stdout, stderr)."""
    proc = subprocess.run(
        argv, cwd=root, input=stdin if stdin is not None else "",
        capture_output=True, text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def board_write(argv: list) -> str:
    """Runs a board-write script; a non-zero exit is a 409 with its stderr."""
    rc, out, err = run_script(APP["root"], argv)
    if rc != 0:
        raise ApiError(409, err.rstrip("\n") or "%s exited %d" % (os.path.basename(argv[1]), rc))
    return out


def script(name: str) -> str:
    return os.path.join(APP["scripts"], name)


def temp_text(text: str) -> str:
    fd, path = tempfile.mkstemp(prefix="board-web.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return path


# --- import -------------------------------------------------------------------

CREATED_RE = re.compile(r"^Created #(\d+):", re.M)

# id -> the Popen this server spawned for the import session (kept so it is reaped).
_IMPORTS: dict = {}
_IMPORT_LOCK = threading.RLock()


def import_dir(id: str) -> Path:
    cfg, _ = ctx()
    path = state_dir(APP["root"], cfg) / "imports" / id
    if not path.is_dir():
        raise ApiError(404, "import %s not found" % id)
    return path


def read_json_file(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_private(path: Path, text: str):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)


def new_import_id() -> str:
    return os.environ.get("FLEET_BOARD_TEST_IMPORT_ID") or (
        "%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(2)))


def start_import(plan_text: str, status: str) -> str:
    """Starts the headless preview session for a plan; returns the import id."""
    cfg, _ = ctx()
    id = new_import_id()
    idir = state_dir(APP["root"], cfg) / "imports" / id
    with _IMPORT_LOCK:
        if idir.exists():
            raise ApiError(409, "import %s already exists" % id)
        idir.mkdir(parents=True, mode=0o700)
        os.chmod(str(idir), 0o700)
        write_private(idir / "plan.md", plan_text)
        write_private(idir / "meta.json", json.dumps({
            "status": status,
            "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }))
        prompt = "/fleet-board:import-plan %s --preview %s" % (idir / "plan.md", idir / "cards.json")
        if status == "ready":
            prompt += " --status ready"
        argv = [
            os.environ.get("FLEET_BOARD_CLAUDE") or "claude", "-p",
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", str((cfg.get("headless") or {}).get("permission_mode") or "auto"),
            "--max-turns", str((cfg.get("limits") or {}).get("max_turns") or 200),
        ]
        plugin_dir = os.environ.get("FLEET_BOARD_PLUGIN_DIR")
        if plugin_dir:
            argv += ["--plugin-dir", plugin_dir]
        argv.append(prompt)
        try:
            ofd = os.open(str(idir / "session.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            efd = os.open(str(idir / "session.err"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(ofd, "wb") as out, os.fdopen(efd, "wb") as err:
                proc = _IMPORTS[id] = subprocess.Popen(
                    argv, cwd=APP["root"], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                    start_new_session=True,
                )
        except OSError as exc:
            raise ApiError(500, "cannot start %s: %s" % (argv[0], exc))
        meta = read_json_file(idir / "meta.json") or {}
        meta.update(pid=proc.pid, pid_start=ps_start(proc.pid) or "")
        write_private(idir / "meta.json", json.dumps(meta))
    return id


def last_session_text(path: Path) -> str:
    """The text of the last assistant event with a text block; partial lines are skipped."""
    last = ""
    for line in read_text(path).splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("type") != "assistant":
            continue
        content = (ev.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                last = block["text"]
    return last


def session_error(idir: Path, rc) -> str:
    """The last stderr line, else the last result text, else 'claude exited <rc>'."""
    lines = [l for l in read_text(idir / "session.err").splitlines() if l.strip()]
    if lines:
        return lines[-1]
    result = ""
    for line in read_text(idir / "session.jsonl").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("type") == "result" and isinstance(ev.get("result"), str) and ev["result"]:
            result = ev["result"]
    return result or "claude exited %s" % ("?" if rc is None else rc)


def import_elapsed(idir: Path, running: bool) -> int:
    meta = read_json_file(idir / "meta.json") or {}
    try:
        start = datetime.strptime(meta["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (KeyError, ValueError, TypeError):
        start = idir.stat().st_mtime
    try:
        end = time.time() if running else (idir / "session.jsonl").stat().st_mtime
    except OSError:
        end = time.time()
    return max(0, int(end - start))


def import_status(id: str) -> dict:
    """running while the session lives; ready when cards.json parses; failed otherwise."""
    idir = import_dir(id)
    with _IMPORT_LOCK:
        proc = _IMPORTS.get(id)
        if proc is not None:
            running = proc.poll() is None
        else:  # not our child (server restarted): the recorded pid, same start time
            meta = read_json_file(idir / "meta.json") or {}
            pid = meta.get("pid")
            running = isinstance(pid, int) and pid > 0 and pid_alive(pid, meta.get("pid_start") or "")
        rc = proc.returncode if proc is not None else None
    status = {"state": "running", "elapsed_s": import_elapsed(idir, running),
              "last_text": last_session_text(idir / "session.jsonl"),
              "cards": None, "table": None, "error": None}
    if running:
        return status
    cards = read_json_file(idir / "cards.json")
    if cards is None:
        status.update(state="failed", error=session_error(idir, rc))
        return status
    drc, table, derr = run_script(APP["root"], ["bash", script("import-plan.sh"), str(idir / "cards.json"), "--dry-run"])
    if drc != 0:
        status.update(state="failed", cards=cards,
                      error=derr.rstrip("\n") or "import-plan.sh --dry-run exited %d" % drc)
        return status
    status.update(state="ready", cards=cards, table=table)
    return status


def create_import(id: str, embed: bool) -> dict:
    """Creates the previewed cards through import-plan.sh; once per import."""
    idir = import_dir(id)
    with _IMPORT_LOCK:
        meta = read_json_file(idir / "meta.json") or {}
        if meta.get("created"):
            raise ApiError(409, "import %s was already created" % id)
        state = import_status(id)
        if state["state"] != "ready":
            raise ApiError(409, "import %s is %s, not ready" % (id, state["state"]))
        argv = ["bash", script("import-plan.sh"), str(idir / "cards.json")]
        if meta.get("status") == "ready":
            argv += ["--status", "ready"]
        rc, out, err = run_script(APP["root"], argv, stdin="y\n" + ("e\n" if embed else "m\n"))
        created = [int(n) for n in CREATED_RE.findall(out)]
        if created:  # even a partial create is final: a retry would duplicate these cards
            meta["created"] = True
            meta["created_numbers"] = created
            write_private(idir / "meta.json", json.dumps(meta))
        if rc != 0:
            raise ApiError(409, err.rstrip("\n") or "import-plan.sh exited %d" % rc,
                           {"created": created} if created else None)
        if not created:
            raise ApiError(409, "import-plan.sh created nothing: %s" % (out.strip() or err.strip()))
    return {"created": created, "output": out}


# --- controllers: (params, body) -> (status, payload) -------------------------

def ctx():
    cfg = load_config(APP["root"], APP["scripts"])
    return cfg, store_dir(APP["root"], cfg)


def card_summary(dir: Path, card: dict, alive: bool) -> dict:
    note = parse_note(card)
    return {
        "number": card.get("number"),
        "title": card.get("title"),
        "state": card.get("state"),
        "labels": card.get("labels") or [],
        "updated_at": card.get("updated_at"),
        "active": is_active(dir, card.get("number"), alive),
        "note": None if note is None else {k: note.get(k) for k in NOTE_FIELDS},
    }


def render_body(card: dict) -> str:
    """The body with the Acceptance and Depends on sections put back from the
    fields (mirrors fl_render_card_json; transitional, as there)."""
    body = card.get("body") if isinstance(card.get("body"), str) else ""
    acc = [a for a in (card.get("acceptance") or []) if isinstance(a, str)]
    blk = [b for b in (card.get("blocked_by") or []) if isinstance(b, int)]
    if not acc and not blk:
        return body
    parts = [body.rstrip("\n")] if body.rstrip("\n") else []
    if acc:
        parts.append("## Acceptance\n" + "\n".join("- " + a for a in acc))
    if blk:
        parts.append("## Depends on\n" + "\n".join("- #%d" % b for b in blk))
    return "\n\n".join(parts) + "\n"


def card_detail(cfg: dict, dir: Path, n: int) -> dict:
    alive = run_alive()
    card = read_card(dir, n)
    note = parse_note(card)
    pr = note.get("pr") if note else None
    repo = (cfg.get("board") or {}).get("repo")
    out = dict(card)
    out["body"] = render_body(card)
    out["active"] = is_active(dir, n, alive)
    out["manager_note"] = note_body(card)
    ok = isinstance(pr, int) and not isinstance(pr, bool) and repo
    out["pr_url"] = "https://github.com/%s/pull/%d" % (repo, pr) if ok else None
    return out


def get_board(params, body):
    cfg, dir = ctx()
    alive = run_alive()  # one liveness check per request
    return 200, {
        "states": states(cfg),
        "cards": [card_summary(dir, c, alive) for c in read_cards(dir)],
        "run": board_run_status(alive),
        "repo": (cfg.get("board") or {}).get("repo"),
    }


def get_card(params, body):
    cfg, dir = ctx()
    return 200, card_detail(cfg, dir, params["n"])


def require_str(body: dict, key: str, required: bool = True):
    v = body.get(key)
    if v is None and not required:
        return None
    if not isinstance(v, str) or (required and v == ""):
        raise ApiError(400, "%s must be a non-empty string" % key if required else "%s must be a string" % key)
    return v


def require_labels(body: dict):
    v = body.get("labels")
    if v is None:
        return None
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ApiError(400, "labels must be a list of strings")
    return v


def create_card(params, body):
    title = require_str(body, "title")
    text = require_str(body, "body")
    labels = require_labels(body) or []
    state = require_str(body, "state", required=False)
    if state is not None:
        cfg, _ = ctx()
        if state not in [s["key"] for s in states(cfg)]:
            raise ApiError(400, "invalid state: %s" % state)
    path = temp_text(text)
    try:
        argv = ["bash", script("board-create.sh"), title, path]
        for label in labels:
            argv += ["--label", label]
        # always created in backlog, then moved: board-move.sh applies the Ready rule
        created = json.loads(board_write(argv))
    finally:
        os.unlink(path)
    if state not in (None, "backlog"):
        try:
            board_write(["bash", script("board-move.sh"), str(created["number"]), state])
        except ApiError as exc:
            raise ApiError(409, "created card #%s in backlog, but the move to %s failed: %s"
                           % (created["number"], state, exc.msg))
    return 200, created


def edit_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    read_card(dir, n)
    title = require_str(body, "title", required=False)
    text = require_str(body, "body", required=False)
    labels = require_labels(body)
    tpath = bpath = ""
    try:
        if title is not None:
            tpath = temp_text(title)
        if text is not None:
            bpath = temp_text(text)
        args = ["bash", script("adapters/local/edit.sh"), str(n)]
        if tpath:
            args += ["--title-file", tpath]
        if bpath:
            args += ["--body-file", bpath]
        if labels is not None:
            args += ["--labels-json", json.dumps(labels)]
        board_write(args)
    finally:
        for path in (tpath, bpath):
            if path:
                os.unlink(path)
    return 200, card_detail(cfg, dir, n)


def move_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    state = require_str(body, "state")
    read_card(dir, n)
    board_write(["bash", script("board-move.sh"), str(n), state])
    return 200, card_detail(cfg, dir, n)


def comment_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    text = require_str(body, "body")
    read_card(dir, n)
    path = temp_text(text)
    try:
        board_write(["env", "FLEET_BOARD_ROLE_REPORT=0", "bash", script("board-comment.sh"), str(n), path])
    finally:
        os.unlink(path)
    return 200, card_detail(cfg, dir, n)


def get_run(params, body):
    return 200, run_status()


def start_run(params, body):
    cfg, dir = ctx()
    sdir = state_dir(APP["root"], cfg)
    wrapper = os.environ.get("FLEET_BOARD_RUN") or script("fleet-board-run.sh")
    with _RUN_LOCK:
        if run_alive():
            raise ApiError(409, "a run is already alive (pid %s)" % _RUN["holder"])
        try:
            os.remove(os.path.join(APP["root"], STOP_FILE))
        except FileNotFoundError:
            pass
        clear_markers(dir)
        fd = os.open(str(sdir / "run.out"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as out:
            proc = subprocess.Popen(
                ["bash", wrapper, "--repo", APP["root"]], cwd=APP["root"],
                stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        pfd = os.open(str(sdir / "run.pid"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(pfd, "w") as f:
            f.write("%d\n%s\n" % (proc.pid, ps_start(proc.pid) or ""))
        _RUN["proc"] = proc
        _RUN["alive"] = True
    return 200, {"pid": proc.pid}


def stop_run(params, body):
    with _RUN_LOCK:
        if not run_alive():
            raise ApiError(409, "no run is alive")
        Path(APP["root"], STOP_FILE).touch()
    return 200, {"state": "stopping"}


def post_import(params, body):
    plan = require_str(body, "plan")
    status = body.get("status", "backlog")
    if status not in ("backlog", "ready"):
        raise ApiError(400, "status must be backlog or ready")
    return 200, {"import_id": start_import(plan, status)}


def get_import(params, body):
    return 200, import_status(params["id"])


def create_import_cards(params, body):
    embed = body.get("embed_docs", False)
    if not isinstance(embed, bool):
        raise ApiError(400, "embed_docs must be a boolean")
    return 200, create_import(params["id"], embed)


# --- handler and route dispatch -----------------------------------------------

# (method, path regex, controller); the n group becomes an int, id stays a string.
ROUTES = [
    ("GET", r"/api/board", get_board),
    ("POST", r"/api/cards", create_card),
    ("GET", r"/api/cards/(?P<n>\d+)", get_card),
    ("PATCH", r"/api/cards/(?P<n>\d+)", edit_card),
    ("POST", r"/api/cards/(?P<n>\d+)/move", move_card),
    ("POST", r"/api/cards/(?P<n>\d+)/comments", comment_card),
    ("GET", r"/api/run", get_run),
    ("POST", r"/api/run/start", start_run),
    ("POST", r"/api/run/stop", stop_run),
    ("POST", r"/api/import", post_import),
    ("GET", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)", get_import),
    ("POST", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/create", create_import_cards),
]
NO_BODY = (start_run, stop_run)  # POST routes that take no JSON body
PAGE_ROUTES = [r"/", r"/cards/\d+"]


def match_route(method: str, path: str):
    """(controller, params) for an API route, or None."""
    for m, pattern, fn in ROUTES:
        hit = re.fullmatch(pattern, path)
        if hit and m == method:
            return fn, {k: (int(v) if k == "n" else v) for k, v in hit.groupdict().items()}
    return None


def json_error(handler, code: int, msg: str, extra: dict = None):
    send_json(handler, code, dict(extra or {}, error=msg))


def send_json(handler, code: int, payload):
    data = json.dumps(payload).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(data)


def csrf_ok(handler) -> bool:
    if handler.headers.get("X-Fleet-Board") != "1":
        return False
    origin = handler.headers.get("Origin")
    if origin is None:
        return True
    port = APP["port"]
    return origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)


def host_ok(handler) -> bool:
    """The Host header names this server (127.0.0.1 or localhost, the bound port), so a page
    on another name that resolves here (DNS rebinding) cannot read the board."""
    port = APP["port"]
    return handler.headers.get("Host") in ("127.0.0.1:%d" % port, "localhost:%d" % port)


def read_json_body(handler) -> dict:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        raise ApiError(400, "bad Content-Length")
    if length <= 0:
        raise ApiError(400, "a JSON object body is required")
    try:
        body = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise ApiError(400, "the body is not valid JSON")
    if not isinstance(body, dict):
        raise ApiError(400, "the body must be a JSON object")
    return body


def static_file(path: str):
    """The file under the static dir that <path> names, or None (never outside it)."""
    static = APP["static"]
    if any(re.fullmatch(p, path) for p in PAGE_ROUTES):
        return static / "index.html"
    if not path.startswith("/static/"):
        return None
    try:
        target = (static / unquote(path[len("/static/"):])).resolve()
        target.relative_to(static)
    except (OSError, ValueError):
        return None
    return target if target.is_file() else None


def send_static(handler, target: Path):
    data = target.read_bytes()
    handler.send_response(200)
    handler.send_header("Content-Type", CONTENT_TYPES.get(target.suffix, "application/octet-stream"))
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Handler(BaseHTTPRequestHandler):
    server_version = "fleet-board-web"

    def log_message(self, fmt, *args):
        sys.stderr.write("board-web: %s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def dispatch(self, method: str):
        path = urlsplit(self.path).path
        try:
            if not host_ok(self):
                raise ApiError(403, "foreign Host header")
            if method in ("POST", "PATCH") and not csrf_ok(self):
                raise ApiError(403, "missing X-Fleet-Board header or foreign Origin")
            route = match_route(method, path)
            if route is not None:
                fn, params = route
                body = read_json_body(self) if method in ("POST", "PATCH") and fn not in NO_BODY else {}
                code, payload = fn(params, body)
                send_json(self, code, payload)
                return
            target = static_file(path) if method == "GET" else None
            if target is None or not target.is_file():
                raise ApiError(404, "not found: %s %s" % (method, path))
            send_static(self, target)
        except ApiError as exc:
            json_error(self, exc.code, exc.msg, exc.extra)
        except Exception as exc:  # noqa: BLE001 - every failure becomes a JSON 500
            traceback.print_exc(file=sys.stderr)
            json_error(self, 500, str(exc) or exc.__class__.__name__)


# --- main ---------------------------------------------------------------------

class LoopbackServer(ThreadingHTTPServer):
    """ThreadingHTTPServer without the reverse DNS lookup of the bind address.

    HTTPServer.server_bind calls socket.getfqdn(host), which can block for
    seconds on hosts with no reverse record for 127.0.0.1 (GitHub's macOS
    runners among them). The name is only used in error pages, so set it
    to the literal address instead.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="board-web.py")
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--scripts", required=True)
    args = ap.parse_args(argv)
    APP["root"] = os.path.abspath(args.root)
    APP["scripts"] = os.path.abspath(args.scripts)
    APP["static"] = (Path(APP["scripts"]) / "board-web" / "static").resolve()
    try:
        server = LoopbackServer(("127.0.0.1", args.port), Handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            sys.stderr.write("board-web: port %d is in use\n" % args.port)
        else:
            sys.stderr.write("board-web: cannot listen on 127.0.0.1:%d: %s\n" % (args.port, exc.strerror or exc))
        return 1
    APP["port"] = server.server_address[1]
    sys.stdout.write("listening on http://127.0.0.1:%d\n" % APP["port"])
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
