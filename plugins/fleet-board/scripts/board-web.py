#!/usr/bin/env python3
"""board-web.py - serves the local fleet-board board over a localhost API.

Usage: python3 board-web.py --root <abs repo root> --port <int> --scripts <abs scripts dir>

Reads come straight from the card files under <root>/<board.dir>/cards/; every
write runs the script an agent would run (board-create.sh, board-move.sh,
board-comment.sh, adapters/local/edit.sh) with cwd = the repo root. The server
never writes a card file itself. Binds 127.0.0.1 only; the first stdout line is
`listening on http://127.0.0.1:<port>`; requests are logged to stderr.

Environment: FLEET_BOARD_LOG_DIR (parent of the runtime data, default ~/.fleet-board),
FLEET_BOARD_CLAUDE (the claude binary the
import session runs, default `claude`), FLEET_BOARD_PLUGIN_DIR (when set, the import
session gets `--plugin-dir <value>`), FLEET_BOARD_TEST_IMPORT_ID (tests only: used as
the import id instead of a generated one).
"""
from __future__ import annotations

import argparse
import copy
import errno
import getpass
import json
import os
import re
import secrets
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.parse import parse_qs

# The module is also imported directly by offline board-web tests, where the
# scripts directory is not necessarily already on sys.path.
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
from supervisor import launcher as supervisor_launcher
from supervisor import paths as supervisor_paths
from supervisor import roles as supervisor_roles
from supervisor import stuck as supervisor_stuck
from supervisor import usage as supervisor_usage
from supervisor import webproxy

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


def reviewer_info(cfg: dict) -> dict:
    """{provider, model} for models.reviewer: a string is a Claude model (default opus)."""
    r = (cfg.get("models") or {}).get("reviewer")
    if isinstance(r, dict):
        return {"provider": r.get("provider"), "model": r.get("model")}
    return {"provider": "claude", "model": r if isinstance(r, str) and r else "opus"}


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
            entry = {"key": k, "name": name}
            if k == "in_review":
                entry["reviewer"] = reviewer_info(cfg)
            result.append(entry)
    _STATES_CACHE[cache_key] = result
    return result


def resolve_persona(root: str, cfg: dict):
    """(text, warning): the planner.persona file under root when it exists, else
    the shipped default persona. warning names a configured path that is missing."""
    default = Path(__file__).resolve().parent.parent / "skills" / "planner" / "references" / "persona.md"
    configured = (cfg.get("planner") or {}).get("persona")
    warning = None
    if configured:
        path = Path(configured)
        if not path.is_absolute():
            path = Path(root) / path
        try:
            return path.read_text(encoding="utf-8"), None
        except OSError:
            warning = "planner.persona file not found: %s; using the shipped default persona" % configured
    return default.read_text(encoding="utf-8"), warning


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
    path = Path(dir) / "cards" / ("%d.json" % n)
    try:
        card = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ApiError(404, "card #%d not found" % n)
    except (OSError, ValueError) as exc:
        raise ApiError(500, "cannot read %s: %s" % (path, exc))
    if not isinstance(card, dict):
        raise ApiError(500, "cannot read %s: not a JSON object" % path)
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


# --- runtime state -------------------------------------------------------------

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
    """The supervisor's repository run lock, <FLEET_BOARD_LOG_DIR or ~/.fleet-board/runs>/<owner>-<name>.lock
    (supervisor/service.py's default_run_lock_path)."""
    base = os.environ.get("FLEET_BOARD_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".fleet-board", "runs")
    repo = (cfg.get("board") or {}).get("repo") or os.path.basename(APP["root"])
    return Path(os.path.abspath(base)) / (repo.replace("/", "-") + ".lock")


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
    """Whether pid is a live process with the recorded start time (an import session this server started)."""
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


_UNSET = object()  # "the caller did not read the supervisor status"


def run_alive(status=_UNSET) -> bool:
    """Whether a supervisor answers for this board and is running (not paused or stopping)."""
    status = supervisor_status() if status is _UNSET else status
    return status is not None and status.get("phase") in ("running", "ready") and status.get("desired_mode") == "running"


def run_status(status=_UNSET) -> dict:
    """The board's `run` field: the supervisor's projected state, else idle (no supervisor answers)."""
    status = supervisor_status() if status is _UNSET else status
    if status is not None:
        return supervisor_run_status(status)
    return {"state": "idle", "supervisor": None}


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
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
    except BaseException:
        os.unlink(path)
        raise
    return path


# --- import -------------------------------------------------------------------

CREATED_RE = re.compile(r"^Created #(\d+):", re.M)

# id -> the Popen this server spawned for the import session (kept so it is reaped).
_IMPORTS: dict = {}
_IMPORT_LOCK = threading.RLock()  # guards _IMPORTS, _IMPORT_LOCKS and import creation
_IMPORT_LOCKS: dict = {}  # id -> the lock that serialises that import's create


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


def write_private_atomic(path: Path, text: str):
    """write_private through a temp file and rename: a reader sees the old or the new file, never a partial one."""
    tmp = path.with_name(path.name + ".tmp")
    write_private(tmp, text)
    os.replace(str(tmp), str(path))


def import_lock(id: str):
    with _IMPORT_LOCK:
        return _IMPORT_LOCKS.setdefault(id, threading.RLock())


def new_import_id() -> str:
    return os.environ.get("FLEET_BOARD_TEST_IMPORT_ID") or (
        "%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(2)))


def draft_planner(id: str) -> str:
    """Writes the conversation as a plan and starts the import preview; returns the import id."""
    pdir = planner_dir(id)
    with _PLANNER_LOCK:
        turns = read_turns(pdir)
        if id in _PLANNER_BUSY:
            raise ApiError(409, "conversation %s is still replying" % id)
    if not any(t.get("role") == "user" and str(t.get("text", "")).strip() for t in turns if isinstance(t, dict)):
        raise ApiError(409, "conversation %s has no user turns to draft from" % id)
    parts = ["# Plan drafted from the planner conversation\n"]
    for t in turns:
        if isinstance(t, dict) and t.get("role") in ("user", "assistant"):
            parts.append("## %s\n\n%s\n" % ("User" if t["role"] == "user" else "Planner", t.get("text", "")))
    return start_import("\n".join(parts), "backlog")


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
        write_private_atomic(idir / "meta.json", json.dumps({
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
        write_private_atomic(idir / "meta.json", json.dumps(meta))
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


def record_import_usage(idir: Path):
    """Record a finished import-preview session's usage once: the first caller to create the marker wins. A
    failed ledger append removes the marker so the next poll retries. Recording happens only when someone polls
    the import after it ends (import_status): a finished import nobody polls is never recorded."""
    stream = idir / "session.jsonl"
    if not stream.exists():
        return
    marker = idir / "usage.recorded"
    try:
        fd = os.open(str(marker), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    except OSError as exc:
        print("warning: planner usage not recorded: %s" % exc, file=sys.stderr)
        return
    os.close(fd)
    meta = read_json_file(idir / "meta.json") or {}
    created = meta.get("created_at")
    try:
        ended = datetime.fromtimestamp(stream.stat().st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        ended = None
    if not record_planner_usage("import_preview", stream, ended_at=ended,
                                started_at=created if isinstance(created, str) else None):
        try:
            marker.unlink()
        except OSError:
            pass


def import_status(id: str) -> dict:
    """running while the session lives; ready when cards.json parses; failed otherwise."""
    idir = import_dir(id)
    if (read_json_file(idir / "meta.json") or {}).get("cancelled"):
        return {"state": "cancelled", "elapsed_s": import_elapsed(idir, False),
                "last_text": last_session_text(idir / "session.jsonl"),
                "cards": None, "table": None, "error": None}
    with _IMPORT_LOCK:
        proc = _IMPORTS.get(id)
        if proc is not None:
            running = proc.poll() is None
        else:  # not our child (server restarted): the recorded pid, same start time
            meta = read_json_file(idir / "meta.json") or {}
            pid = meta.get("pid")
            running = isinstance(pid, int) and pid > 0 and pid_alive(pid, meta.get("pid_start") or "")
        rc = proc.returncode if proc is not None else None
    meta = read_json_file(idir / "meta.json") or {}
    created = meta.get("created_numbers") if meta.get("created") else None
    status = {"state": "running", "elapsed_s": import_elapsed(idir, running),
              "last_text": last_session_text(idir / "session.jsonl"),
              "cards": None, "table": None, "error": None, "created": created}
    if running:
        return status
    record_import_usage(idir)
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


def cancel_import(id: str) -> dict:
    """TERMs the session's process group (KILL after 5 s) and marks the import cancelled."""
    idir = import_dir(id)
    with _IMPORT_LOCK:
        state = import_status(id)["state"]
        if state != "running":
            raise ApiError(409, "import %s is %s, not running" % (id, state))
        meta = read_json_file(idir / "meta.json") or {}
        pid = meta.get("pid")
        meta["cancelled"] = True
        write_private(idir / "meta.json", json.dumps(meta))
        proc = _IMPORTS.get(id)
    if isinstance(pid, int) and pid > 1:
        def gone():
            if proc is not None:
                return proc.poll() is not None
            return not pid_alive(pid, meta.get("pid_start") or "")
        errors = []
        for sig, wait in ((signal.SIGTERM, 5.0), (signal.SIGKILL, 2.0)):
            try:
                os.killpg(pid, sig)
            except OSError as exc:
                # No such group (or refused): signal the session leader itself.
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
                except OSError as exc2:
                    errors.append("%s: %s / %s" % (sig.name, exc.strerror, exc2.strerror))
            deadline = time.time() + wait
            while not gone() and time.time() < deadline:
                time.sleep(0.05)
            if gone():
                break
        if not gone():
            raise ApiError(500, "import %s session pid %d did not stop%s"
                           % (id, pid, (" (" + "; ".join(errors) + ")") if errors else ""))
    return {"state": "cancelled"}


def create_import(id: str, embed: bool, status: str | None = None) -> dict:
    """Creates the previewed cards through import-plan.sh, in the status column; once per import."""
    idir = import_dir(id)
    with import_lock(id):
        meta = read_json_file(idir / "meta.json") or {}
        if meta.get("created"):
            raise ApiError(409, "import %s was already created" % id)
        state = import_status(id)
        if state["state"] != "ready":
            raise ApiError(409, "import %s is %s, not ready" % (id, state["state"]))
        argv = ["bash", script("import-plan.sh"), str(idir / "cards.json")]
        if (status or meta.get("status")) == "ready":
            argv += ["--status", "ready"]
        rc, out, err = run_script(APP["root"], argv, stdin="y\n" + ("e\n" if embed else "m\n"))
        created = [int(n) for n in CREATED_RE.findall(out)]
        if created:  # even a partial create is final: a retry would duplicate these cards
            meta["created"] = True
            meta["created_numbers"] = created
            write_private_atomic(idir / "meta.json", json.dumps(meta))
        if rc != 0:
            raise ApiError(409, err.rstrip("\n") or "import-plan.sh exited %d" % rc,
                           {"created": created} if created else None)
        if not created:
            raise ApiError(409, "import-plan.sh created nothing: %s" % (out.strip() or err.strip()))
    return {"created": created, "output": out}


EDITABLE_FIELDS = {"title": "str", "why": "str", "labels": "list", "scope": "list",
                   "acceptance": "list", "depends_on": "list"}


def edit_import_card(id: str, key: str, body: dict) -> dict:
    """Applies a partial edit to one previewed card, keeps it only when the dry run passes."""
    idir = import_dir(id)
    edits = {}
    for field, kind in EDITABLE_FIELDS.items():
        if field not in body:
            continue
        v = body[field]
        if kind == "str" and not isinstance(v, str):
            raise ApiError(400, "%s must be a string" % field)
        if kind == "list" and not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
            raise ApiError(400, "%s must be a list of strings" % field)
        edits[field] = v
    if not edits:
        raise ApiError(400, "no editable field given (%s)" % ", ".join(EDITABLE_FIELDS))
    with import_lock(id):
        meta = read_json_file(idir / "meta.json") or {}
        if meta.get("created"):
            raise ApiError(409, "import %s was already created" % id)
        plan = read_json_file(idir / "cards.json")
        if not isinstance(plan, dict) or not isinstance(plan.get("cards"), list):
            raise ApiError(409, "import %s is not ready" % id)
        card = next((c for c in plan["cards"] if isinstance(c, dict) and c.get("key") == key), None)
        if card is None:
            raise ApiError(404, "unknown card key %s in import %s" % (key, id))
        card.update(edits)
        trial = idir / "cards.edit.json"
        write_private_atomic(trial, json.dumps(plan))
        try:
            drc, table, derr = run_script(APP["root"], ["bash", script("import-plan.sh"), str(trial), "--dry-run"])
            if drc != 0:
                raise ApiError(422, derr.rstrip("\n") or "import-plan.sh --dry-run exited %d" % drc)
            os.replace(str(trial), str(idir / "cards.json"))
        finally:
            try:
                trial.unlink()
            except OSError:
                pass
    return {"state": "ready", "cards": plan, "table": table}


# --- controllers: (params, body) -> (status, payload) -------------------------

# --- planner chat ---------------------------------------------------------------

_PLANNER_LOCK = threading.RLock()  # guards _PLANNER_BUSY and conversation creation
_PLANNER_BUSY: set = set()  # ids with a reply in progress
PLANNER_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def planner_dir(id: str) -> Path:
    cfg, _ = ctx()
    path = state_dir(APP["root"], cfg) / "planner" / id
    if not PLANNER_ID_RE.match(id) or not path.is_dir():
        raise ApiError(404, "conversation %s not found" % id)
    return path


def read_turns(pdir: Path) -> list:
    turns = read_json_file(pdir / "transcript.json")
    return turns if isinstance(turns, list) else []


def start_planner() -> str:
    cfg, _ = ctx()
    id = os.environ.get("FLEET_BOARD_TEST_PLANNER_ID") or (
        "%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(2)))
    pdir = state_dir(APP["root"], cfg) / "planner" / id
    with _PLANNER_LOCK:
        if pdir.exists():
            raise ApiError(409, "conversation %s already exists" % id)
        pdir.mkdir(parents=True, mode=0o700)
        os.chmod(str(pdir), 0o700)
        write_private_atomic(pdir / "transcript.json", "[]")
    return id


def session_id_of(path: Path) -> str:
    found = ""
    for line in read_text(path).splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and isinstance(ev.get("session_id"), str) and ev["session_id"]:
            found = ev["session_id"]
    return found


def record_planner_usage(action: str, stream_path: Path, ended_at: str = None, started_at: str = None) -> bool:
    """One planner-kind ledger line for a finished planner or import-preview session. Tokens come from the
    session's result event (unreadable counts stay unknown). A ledger failure is logged, never raised; the return
    value says whether the line was appended."""
    try:
        cfg, _ = ctx()
        _text, use, _err, _sub, _sid, _mode = supervisor_roles.parse_stream(stream_path)
        supervisor_usage.append(APP["root"], {
            "run_id": None, "card": None, "kind": "planner", "column": None, "action": action, "role": None,
            "provider": "claude", "model": use.model, "input": use.input, "output": use.output,
            "cache_write": use.cache_write, "cache_read": use.cache_read, "started_at": started_at,
            "ended_at": ended_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "log": str(stream_path),
        }, (cfg.get("board") or {}).get("dir") or supervisor_usage.DEFAULT_DIR)
        return True
    except Exception as exc:  # noqa: BLE001 - usage accounting must never break a planner reply
        print("warning: planner usage not recorded: %s" % exc, file=sys.stderr)
        return False


def finish_planner_turn(id: str, pdir: Path, proc, out_path: Path, err_path: Path, started_at: str = None):
    rc = proc.wait()
    reply = last_session_text(out_path)
    if rc != 0 and not reply:
        lines = [l for l in read_text(err_path).splitlines() if l.strip()]
        reply = "[error] " + (lines[-1] if lines else "claude exited %s" % rc)
    with _PLANNER_LOCK:
        turns = read_turns(pdir)
        turns.append({"role": "assistant", "text": reply})
        write_private_atomic(pdir / "transcript.json", json.dumps(turns))
        sid = session_id_of(out_path)
        if sid:
            meta = read_json_file(pdir / "meta.json") or {}
            meta["session_id"] = sid
            write_private_atomic(pdir / "meta.json", json.dumps(meta))
        _PLANNER_BUSY.discard(id)
    # last: a ledger append that blocks (a stuck lock) must never leave the conversation "still replying"
    record_planner_usage("planner", out_path, started_at=started_at)


def send_planner_message(id: str, text: str):
    cfg, _ = ctx()
    pdir = planner_dir(id)
    with _PLANNER_LOCK:
        if id in _PLANNER_BUSY:
            raise ApiError(409, "conversation %s is still replying" % id)
        persona, _warn = resolve_persona(APP["root"], cfg)
        prompt = "Board context (JSON):\n%s\n\nUser:\n%s" % (json.dumps(board_context()), text)
        meta = read_json_file(pdir / "meta.json") or {}
        argv = [
            os.environ.get("FLEET_BOARD_CLAUDE") or "claude", "-p",
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", str((cfg.get("headless") or {}).get("permission_mode") or "auto"),
            "--max-turns", str((cfg.get("limits") or {}).get("max_turns") or 200),
            "--append-system-prompt", persona,
        ]
        if meta.get("session_id"):
            argv += ["--resume", meta["session_id"]]
        plugin_dir = os.environ.get("FLEET_BOARD_PLUGIN_DIR")
        if plugin_dir:
            argv += ["--plugin-dir", plugin_dir]
        argv.append(prompt)
        n = len(read_turns(pdir))
        out_path, err_path = pdir / ("reply-%d.jsonl" % n), pdir / ("reply-%d.err" % n)
        started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        try:
            ofd = os.open(str(out_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            efd = os.open(str(err_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(ofd, "wb") as out, os.fdopen(efd, "wb") as err:
                proc = subprocess.Popen(argv, cwd=APP["root"], stdin=subprocess.DEVNULL,
                                        stdout=out, stderr=err, start_new_session=True)
        except OSError as exc:
            raise ApiError(500, "cannot start %s: %s" % (argv[0], exc))
        turns = read_turns(pdir)
        turns.append({"role": "user", "text": text})
        write_private_atomic(pdir / "transcript.json", json.dumps(turns))
        _PLANNER_BUSY.add(id)
        threading.Thread(target=finish_planner_turn, args=(id, pdir, proc, out_path, err_path, started_at),
                         daemon=True).start()


def planner_status(id: str) -> dict:
    pdir = planner_dir(id)
    with _PLANNER_LOCK:
        return {"id": id, "turns": read_turns(pdir), "running": id in _PLANNER_BUSY}


def ctx():
    cfg = load_config(APP["root"], APP["scripts"])
    return cfg, store_dir(APP["root"], cfg)


def is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def card_blocked_by(card: dict) -> list:
    return [b for b in (card.get("blocked_by") or []) if is_int(b)]


def card_acceptance(card: dict) -> list:
    return [a for a in (card.get("acceptance") or []) if isinstance(a, str)]


def pr_url_ok(cfg: dict, v) -> bool:
    """True for exactly https://github.com/<board.repo>/pull/<positive int>
    (owner/name compared case-insensitively)."""
    repo = (cfg.get("board") or {}).get("repo") or ""
    m = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+)/pull/([1-9][0-9]*)", v) if isinstance(v, str) else None
    return bool(m and repo and m.group(1).lower() == repo.lower())


def card_pr_url(cfg: dict, card: dict, note):
    """The card's pr_url field when it passes pr_url_ok (a hand-edited or
    imported value that does not reads as None, so no unchecked URL leaves the
    server); a card written before the field existed falls back to the note's
    pr on board.repo."""
    if "pr_url" in card:
        v = card.get("pr_url")
        return v if pr_url_ok(cfg, v) else None
    pr = note.get("pr") if note else None
    repo = (cfg.get("board") or {}).get("repo")
    return "https://github.com/%s/pull/%d" % (repo, pr) if is_int(pr) and repo else None


def card_summary(cfg: dict, dir: Path, card: dict, alive: bool, state_of: dict, known_states=None) -> dict:
    """state_of: number -> state for every card read in this request, so
    `blocked` (any blocker missing or not done) costs no extra read."""
    note = parse_note(card)
    blk = card_blocked_by(card)
    return {
        "number": card.get("number"),
        "title": card.get("title"),
        "state": card.get("state"),
        "known": known_states is None or card.get("state") in known_states,
        "labels": card.get("labels") or [],
        "updated_at": card.get("updated_at"),
        "active": is_active(dir, card.get("number"), alive),
        "note": None if note is None else {k: note.get(k) for k in NOTE_FIELDS},
        "pr_url": card_pr_url(cfg, card, note),
        "acceptance_count": len(card_acceptance(card)),
        "blocked_by": blk,
        "blocked": any(state_of.get(b) != "done" for b in blk),
    }


def card_detail(cfg: dict, dir: Path, n: int) -> dict:
    alive = run_alive()
    card = read_card(dir, n)
    note = parse_note(card)
    out = dict(card)
    out["body"] = card.get("body") if isinstance(card.get("body"), str) else ""
    out["acceptance"] = card_acceptance(card)
    out["blocked_by"] = card_blocked_by(card)
    out["active"] = is_active(dir, n, alive)
    out["manager_note"] = note_body(card)
    out["pr_url"] = card_pr_url(cfg, card, note)
    return out


DEPENDS_HEADING_RE = re.compile(r"^#{1,6}\s*depends on\s*$", re.I)
DEPENDS_BULLET_RE = re.compile(r"^\s*[-*]\s*#(\d+)\b")
PR_STATES = ("open", "draft", "merged", "closed")


def depends_on(body) -> list:
    """Card numbers listed as "#n" bullets under a "## Depends on" heading."""
    nums, on = [], False
    for line in (body if isinstance(body, str) else "").split("\n"):
        if re.match(r"^#{1,6}\s", line):
            on = bool(DEPENDS_HEADING_RE.match(line))
            continue
        m = on and DEPENDS_BULLET_RE.match(line)
        if m and int(m.group(1)) not in nums:
            nums.append(int(m.group(1)))
    return nums


def live_pr_states(repo) -> dict:
    """PR number -> open/draft/merged/closed from one `gh pr list`; {} when unavailable."""
    if not repo:
        return {}
    try:
        rc, out, _ = run_script(APP["root"], ["gh", "pr", "list", "--repo", repo, "--state", "all",
                                              "--limit", "1000", "--json", "number,state,isDraft"])
        items = json.loads(out) if rc == 0 else []
    except (OSError, ValueError):
        return {}
    states_ = {}
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict) or not isinstance(it.get("number"), int):
            continue
        st = str(it.get("state", "")).upper()
        if st == "MERGED":
            states_[it["number"]] = "merged"
        elif st == "CLOSED":
            states_[it["number"]] = "closed"
        elif st == "OPEN":
            states_[it["number"]] = "draft" if it.get("isDraft") else "open"
    return states_


def board_context(cache: dict = None) -> list:
    """The planner's snapshot: every card with state, labels, depends_on, PR and review round.

    One board-list.sh process lists every state; a PR's state comes from its card's manager note
    (pr_state) when recorded, otherwise from one gh pr list; card details come from the store.
    Pass the same dict as `cache` to reuse one snapshot for a planner turn.
    """
    if cache is not None and "snapshot" in cache:
        return cache["snapshot"]
    cfg, dir = ctx()
    rc, out, err = run_script(APP["root"], ["bash", script("board-list.sh"), "--all"])
    if rc != 0:
        raise ApiError(500, err.rstrip("\n") or "board-list exited %d" % rc)
    listed = set()
    for line in out.splitlines():
        try:
            items = json.loads(line)
        except ValueError:
            continue
        for item in items if isinstance(items, list) else []:
            if isinstance(item, dict) and isinstance(item.get("number"), int):
                listed.add(item["number"])
    rows = []
    for card in read_cards(dir):
        n = card.get("number")
        if listed and n not in listed:
            continue
        note = parse_note(card) or {}
        pr = note.get("pr")
        has_pr = isinstance(pr, int) and not isinstance(pr, bool)
        rows.append((card, note, pr, has_pr))
    # Ask GitHub only when some PR's state is not already recorded in its card's manager note,
    # so a board whose notes carry every pr_state builds its snapshot without the network.
    need_live = any(has_pr and note.get("pr_state") not in PR_STATES for _, note, _, has_pr in rows)
    live = live_pr_states((cfg.get("board") or {}).get("repo")) if need_live else {}
    snapshot = []
    for card, note, pr, has_pr in rows:
        n = card.get("number")
        pr_state = note.get("pr_state") if has_pr else None
        if has_pr and pr_state not in PR_STATES:
            pr_state = live.get(pr)
        snapshot.append({
            "number": n,
            "title": card.get("title"),
            "state": card.get("state"),
            "labels": card.get("labels") or [],
            # the card's blocked_by field, then any "## Depends on" bullets a
            # card written before the field still carries in its body
            "depends_on": list(dict.fromkeys(card_blocked_by(card) + depends_on(card.get("body")))),
            "pr": {"number": pr, "state": pr_state if pr_state in PR_STATES else None} if has_pr else None,
            "round": note.get("round"),
        })
    if cache is not None:
        cache["snapshot"] = snapshot
    return snapshot


def get_board(params, body):
    cfg, dir = ctx()
    status = supervisor_status()  # read once: liveness, run state, activity and stuck all agree
    alive = run_alive(status)
    cards = read_cards(dir)
    state_of = {c.get("number"): c.get("state") for c in cards if is_int(c.get("number"))}
    sts = states(cfg)
    keys = [s["key"] for s in sts]
    run = run_status(status)
    stuck_of, activity = board_extras(status, run, refresh=wants_stuck_refresh(params))
    return 200, {
        "states": sts,
        "cards": [dict(card_summary(cfg, dir, c, alive, state_of, keys),
                       stuck=stuck_of.get(c.get("number")), activity=activity.get(c.get("number")))
                  for c in cards],
        "run": run,
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
    # the body is prose and may be empty (the criteria travel as acceptance)
    text = body.get("body")
    if not isinstance(text, str):
        raise ApiError(400, "body must be a string")
    labels = require_labels(body) or []
    cfg, dir = ctx()
    acceptance = require_acceptance(body)
    blocked_by = require_blocked_by(dir, None, body)
    state = require_str(body, "state", required=False)
    if state is not None:
        if state not in [s["key"] for s in states(cfg)]:
            raise ApiError(400, "invalid state: %s" % state)
    paths = [temp_text(text)]
    try:
        argv = ["bash", script("board-create.sh"), title, paths[0]]
        for label in labels:
            argv += ["--label", label]
        if acceptance is not None:
            paths.append(temp_text("".join(a + "\n" for a in acceptance)))
            argv += ["--acceptance-file", paths[-1]]
        for b in blocked_by or []:
            argv += ["--blocked-by", str(b)]
        # always created in backlog, then moved: board-move.sh applies the Ready rule
        created = json.loads(board_write(argv))
    finally:
        for path in paths:
            os.unlink(path)
    if state not in (None, "backlog"):
        try:
            board_write(["bash", script("board-move.sh"), str(created["number"]), state])
        except ApiError as exc:
            raise ApiError(409, "created card #%s in backlog, but the move to %s failed: %s"
                           % (created["number"], state, exc.msg))
    return 200, created


FENCE_RE = re.compile(r"^ {0,3}(```|~~~)")
ACC_HEAD_RE = re.compile(r"^##[ \t]+Acceptance([ \t].*)?$")
DEP_HEAD_RE = re.compile(r"^##[ \t]+depends[ \t]+on[ \t]*$", re.I)


def body_sections(text: str) -> tuple:
    """(has an Acceptance section, has a Depends on section) outside code
    fences, by fl_split_body's heading rules."""
    acc = dep = fence = False
    for line in text.split("\n"):
        if FENCE_RE.match(line):
            fence = not fence
        elif not fence:
            acc = acc or bool(ACC_HEAD_RE.match(line))
            dep = dep or bool(DEP_HEAD_RE.match(line))
    return acc, dep


def require_acceptance(body: dict):
    v = body.get("acceptance")
    if v is None:
        return None
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ApiError(400, "acceptance must be a list of strings")
    if any("\n" in x or "\r" in x for x in v):
        raise ApiError(400, "acceptance items must be single lines")
    return v


def require_blocked_by(dir: Path, n: int, body: dict, stored: list = ()):
    """The blocked_by list, or None when absent. Refs already in <stored> are
    kept unchecked (edit.sh's rule): a stale one never blocks a save."""
    v = body.get("blocked_by")
    if v is None:
        return None
    if not isinstance(v, list) or not all(is_int(x) and x > 0 for x in v):
        raise ApiError(400, "blocked_by must be a list of card numbers")
    for b in v:
        if b in stored:
            continue
        if b == n:
            raise ApiError(400, "blocked_by names #%d, the card itself" % b)
        if not (Path(dir) / "cards" / ("%d.json" % b)).is_file():
            raise ApiError(400, "blocked_by names #%d, which is not on this board" % b)
    return v


def require_pr_url(cfg: dict, body: dict):
    """None when absent, "" to clear (null), else a pull URL on board.repo."""
    if "pr_url" not in body:
        return None
    v = body["pr_url"]
    if v is None:
        return ""
    if not pr_url_ok(cfg, v):
        repo = (cfg.get("board") or {}).get("repo") or "<board.repo>"
        raise ApiError(400, "pr_url must be https://github.com/%s/pull/<number>, or null" % repo)
    return v


def edit_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    card = read_card(dir, n)
    title = require_str(body, "title", required=False)
    text = require_str(body, "body", required=False)
    labels = require_labels(body)
    acceptance = require_acceptance(body)
    blocked_by = require_blocked_by(dir, n, body, card_blocked_by(card))
    pr_url = require_pr_url(cfg, body)
    if text is not None:
        # edit.sh treats a body as the whole truth about its sections: a prose
        # body would clear the fields. Keep them unless the body carries one.
        has_acc, has_dep = body_sections(text)
        if acceptance is None and not has_acc:
            acceptance = card_acceptance(card)
        if blocked_by is None and not has_dep:
            blocked_by = card_blocked_by(card)
    paths = []
    try:
        args = ["bash", script("adapters/local/edit.sh"), str(n)]
        for flag, value in (("--title-file", title), ("--body-file", text),
                            ("--acceptance-file", None if acceptance is None else "".join(a + "\n" for a in acceptance))):
            if value is not None:
                paths.append(temp_text(value))
                args += [flag, paths[-1]]
        if labels is not None:
            args += ["--labels-json", json.dumps(labels)]
        if blocked_by is not None:
            args += ["--blocked-by-json", json.dumps(blocked_by)]
        if pr_url is not None:
            args += ["--pr-url", pr_url]
        board_write(args)
    finally:
        for path in paths:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    return 200, card_detail(cfg, dir, n)


def move_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    state = require_str(body, "state")
    read_card(dir, n)
    status = supervisor_status()
    if run_alive(status) and is_active(dir, n, True):
        stuck_of, _ = board_extras(status, {}, refresh=False)
        if n not in stuck_of:
            raise ApiError(409, "an agent is working on card #%s; it cannot be moved until the agent is done "
                                "(or the card is stuck)" % n)
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


SUPERVISOR_PROBE_TIMEOUT = 1.0


def supervisor_running():
    """True when this board's supervisor socket answers `status` within a second (an error reply
    from the service counts: it is alive).

    There is no configuration switch: a supervisor someone started (`supervisor start`) is the
    only thing that makes the board supervisor-capable. Nothing is created or launched here."""
    domain_id = supervisor_domain_id()
    if domain_id is None and not os.environ.get("FLEET_BOARD_SUPERVISOR_SOCKET"):
        return False
    try:
        path = webproxy.socket_path(domain_id)
    except (OSError, ValueError, RuntimeError):
        return False
    box = {}

    def ask():
        try:
            box["answered"] = isinstance(webproxy.request(path, {"command": "status"}), dict)
        except RuntimeError:
            box["answered"] = True  # the service replied with an error envelope: it is alive
        except Exception:
            box["answered"] = False

    thread = threading.Thread(target=ask, daemon=True)
    thread.start()
    thread.join(SUPERVISOR_PROBE_TIMEOUT)
    return box.get("answered") is True


def supervisor_status():
    """The page-shaped status of the supervisor that answers for this board, else None (also when it
    exits between the liveness probe and the status read)."""
    if not supervisor_running():
        return None
    try:
        return proxy_call("status")
    except ApiError as exc:
        if exc.code != 503:
            raise
        return None


def supervisor_stopping(status):
    """True when a status reply says the supervisor is on its way out."""
    return isinstance(status, dict) and (status.get("mode") == "stopping" or status.get("phase") == "stopping")


def supervisor_domain_id():
    """The supervisor domain id for this board, derived from the same identity inputs the
    store uses. Pure: no database is opened and no file is created, so a GET can never touch
    supervisor state. None when it cannot be derived (the panel then reads unreachable)."""
    cached = APP.get("supervisor_domain_id")
    if cached:
        return cached
    try:
        value = supervisor_paths.domain_id_for_root(APP["root"])
    except (OSError, ValueError, KeyError):
        return None
    APP["supervisor_domain_id"] = value
    return value


# One status per service error code (the service classifies by exception type, never by text).
SUPERVISOR_ERROR_STATUS = {"invalid": 400,
                           "unauthenticated": 403, "unavailable": 503, "internal": 500}


def proxy_call(command, body=None, **extra):
    domain_id = supervisor_domain_id()
    request = dict(body or {})
    if "actor" in request:
        raise ApiError(400, "actor must come from authenticated peer")
    request.update(extra)
    request["command"] = command
    if domain_id is None and not os.environ.get("FLEET_BOARD_SUPERVISOR_SOCKET"):
        raise ApiError(503, "supervisor unavailable: cannot derive the supervisor identity")
    try:
        result = webproxy.request(webproxy.socket_path(domain_id), request)
    except (OSError, TimeoutError, ValueError, RuntimeError) as exc:
        try:
            detail = json.loads(str(exc))
        except (ValueError, TypeError):
            detail = {}
        code = detail.get("code") if isinstance(detail, dict) else None
        msg = detail.get("message", str(exc)) if isinstance(detail, dict) else str(exc)
        if code == "stale_revision":
            current = detail.get("current")
            if current is None:
                try:
                    current = webproxy.request(webproxy.socket_path(domain_id), {"command": "status"})
                except Exception:
                    current = None
            current = webproxy.ui_status(current)
            raise ApiError(409, msg, {"current": current, "code": code})
        if code in SUPERVISOR_ERROR_STATUS:
            # Internal detail never reaches the browser: the service already redacted it.
            raise ApiError(SUPERVISOR_ERROR_STATUS[code],
                           "internal error" if code == "internal" else msg, {"code": code})
        raise ApiError(503, "supervisor unavailable: " + msg, {"code": "unavailable"})
    if command == "status":
        result = webproxy.ui_status(result)
    return result


_LAUNCH_LOCK = threading.Lock()


START_STOP_WAIT = 5.0  # how long Start waits for a stopping supervisor to go away


def ensure_service():
    """Make sure a live, not-stopping supervisor answers for this board; True when this call
    launched one.

    A supervisor whose status says it is stopping counts as not running: Start waits (bounded)
    for it to go away and then launches a new one through the shared launcher, so a Start right
    after a Stop never reports an exiting supervisor as running. A failure is a 503 with a
    reason and leaves nothing half-started."""
    def read():
        try:
            return proxy_call("status")
        except ApiError as exc:
            if exc.code != 503:
                raise
            return None

    def live():
        status = read()
        return status is not None and not supervisor_stopping(status)

    if live():
        return False
    with _LAUNCH_LOCK:
        if live():  # another request launched it while we waited for the lock
            return False
        if supervisor_stopping(read()) and not supervisor_launcher.wait_until(
                lambda: read() is None, timeout=START_STOP_WAIT):
            raise ApiError(503, "supervisor is still stopping; try Start again in a moment",
                           {"code": "unavailable"})
        try:
            supervisor_launcher.launch_detached(APP["root"], supervisor_paths.log_dir() / "supervisor.log")
        except (supervisor_launcher.LaunchError, OSError, ValueError) as exc:
            # A CLI start won the run lock between the probe and the launch: that one runs. Its socket may
            # take a moment to answer after our child lost the lock (exit 1), so wait briefly for it.
            if live() or (getattr(exc, "exit_code", None) == 1 and supervisor_launcher.wait_until(live, timeout=2.0)):
                return False
            raise ApiError(503, "supervisor could not be started: %s" % str(exc)[:300], {"code": "launch_failed"})
        if not supervisor_launcher.wait_until(live, timeout=5.0):
            raise ApiError(503, "supervisor could not be started: it reported ready but did not answer",
                           {"code": "launch_failed"})
    return True


def proxy_control(command, body):
    if "actor" in body:
        raise ApiError(400, "actor must come from authenticated peer")
    if not isinstance(body.get("request_id"), str) or not body.get("request_id") or type(body.get("expected_revision")) is not int:
        raise ApiError(400, "request_id and integer expected_revision are required")
    if command == "stop":
        body.setdefault("mode", "drain")
    if command == "start":
        # Start means "a supervisor is running": launch it when nothing answers. The running
        # supervisor has no start command, so a Start never changes its state.
        launched = ensure_service()
        status = proxy_call("status")
        resumed = False
        if not launched and status.get("mode") == "paused":
            # Start on a paused supervisor is a resume, bound exactly like the Resume button.
            proxy_call("resume", {"request_id": body["request_id"], "expected_revision": body["expected_revision"]})
            status, resumed = proxy_call("status"), True
        result = {"command_id": body["request_id"], "state_revision": status.get("revision"),
                  "desired_mode": status.get("desired_mode"), "phase": status.get("phase")}
        if resumed:
            result["resumed"] = True
        return 202, (dict(result, launched=True) if launched else result)
    return 202, proxy_call(command, body)


def supervisor_run_status(status):
    phase = status.get("phase", "unknown")
    ready = status.get("ready") is True
    desired = status.get("desired_mode")
    # Never infer running from intent: only the service's own ready acknowledgement
    # plus an observed running phase counts. Intent without readiness is starting.
    state = ("running" if ready and phase == "running" and desired == "running" else
             "stopping" if phase in ("draining", "cancelling", "stopping") else
             "starting" if desired == "running" and not ready else
             "stopped" if phase in ("stopped", "idle") else phase)
    return {"state": state, "supervisor": status}


_USAGE_CACHE = {}  # (root, board dir, run_id, card) -> (ledger stat, view): an unchanged ledger is not reparsed
_USAGE_LOCK = threading.Lock()


def usage_view(run_id=None, card=None):
    """The usage ledger's answer (read here, never through the supervisor); tokens only. Cached on the
    ledger's (size, mtime), so a poll of an unchanged ledger does not reparse it."""
    cfg, _ = ctx()
    board_dir = (cfg.get("board") or {}).get("dir") or supervisor_usage.DEFAULT_DIR
    try:
        info = os.stat(str(supervisor_usage.ledger_path(APP["root"], board_dir)))
        stat_key = (info.st_size, info.st_mtime_ns, info.st_ino)
    except OSError:
        stat_key = None
    key = (APP["root"], board_dir, run_id, card)
    with _USAGE_LOCK:
        hit = _USAGE_CACHE.get(key)
    if hit is not None and stat_key is not None and hit[0] == stat_key:
        return copy.deepcopy(hit[1])
    try:
        result = supervisor_usage.view(APP["root"], board_dir, card=card, run_id=run_id)
    except ValueError as exc:
        raise ApiError(400, str(exc)[:200])
    except OSError as exc:
        raise ApiError(500, "usage ledger unreadable: %s" % str(exc)[:200])
    if stat_key is not None:
        with _USAGE_LOCK:
            if len(_USAGE_CACHE) >= 64:
                _USAGE_CACHE.clear()
            _USAGE_CACHE[key] = (stat_key, copy.deepcopy(result))
    return result


def get_supervisor(params, body):
    status = supervisor_status()
    if status is None:
        try:
            return 200, dict(usage_view(), running=False)
        except ApiError as exc:  # an unreadable ledger is unknown, never 0
            return 200, {"running": False, "run": None, "all_time": None, "planner": None, "error": exc.msg}
    return 200, dict(status, running=True)


def supervisor_command(params, body):
    action = params["action"]
    if "actor" in body:
        raise ApiError(400, "actor must come from authenticated peer")
    if action != "start" and not supervisor_running():
        raise ApiError(409, "no supervisor is running", {"code": "not_running"})
    return proxy_control(action, body)


def get_usage(params, body):
    status = supervisor_status()
    return 200, usage_view(run_id=status.get("run_id") if status else None)


def get_card_usage(params, body):
    return 200, usage_view(card=params["n"])


STUCK_MIN_INTERVAL = 30.0  # seconds: a stuck scan of a large board takes seconds and shells out per card
_STUCK = {"at": None, "mono": 0.0, "found": None, "error": None, "running": False, "duration": 0.0, "stamp": None}
_STUCK_LOCK = threading.Lock()


def stuck_interval():
    """How long a stuck result is reused: the longer of 30 s and twice the last scan's duration."""
    return max(STUCK_MIN_INTERVAL, 2.0 * _STUCK["duration"])


def _mtime_ns(path):
    try:
        return os.stat(str(path)).st_mtime_ns
    except OSError:
        return None


def stuck_stamp(board_dir):
    """(cards dir mtime, active markers dir mtime): a card moved, created or released changes it."""
    if board_dir is None:
        return None
    return (_mtime_ns(Path(board_dir) / "cards"), _mtime_ns(Path(board_dir) / "active"))


def _refresh_stuck(stamp):
    """The one background refresher: runs stuck.find (read-only) and writes the cache."""
    began = time.monotonic()
    try:
        try:
            found, error = [dict(card=x.card, kind=x.kind, detail=x.detail)
                            for x in supervisor_stuck.find(APP["root"])], None
        except Exception as exc:  # noqa: BLE001 - a failed check is recorded and shown, never hidden
            found, error = None, str(exc)[:300] or exc.__class__.__name__
        with _STUCK_LOCK:
            if found is None:
                found = _STUCK["found"]  # keep the last good result (None while there is none)
            _STUCK.update(at=time.time(), mono=time.monotonic(), found=found, error=error,
                          duration=time.monotonic() - began, stamp=stamp)
    finally:
        with _STUCK_LOCK:
            _STUCK["running"] = False  # whatever happened, a later request may start another refresher


def stuck_state(board_dir, refresh=True):
    """{findings, checked_at, error, checking, known} with no supervisor running, answered at once from the cache.

    Never computes on the calling thread. A refresh starts only when a caller asks for one (a poll from a
    visible tab), no page-initiated launch is in flight, no refresher runs, and the result is due: none yet,
    older than stuck_interval(), or the cards or active markers directory changed since it was taken.
    findings is None (known false) until a check has succeeded."""
    stamp = stuck_stamp(board_dir)
    with _STUCK_LOCK:
        due = (_STUCK["at"] is None or (stamp is not None and stamp != _STUCK["stamp"])
               or time.monotonic() - _STUCK["mono"] >= stuck_interval())
        if refresh and due and not _STUCK["running"] and not _LAUNCH_LOCK.locked():
            _STUCK["running"] = True
            try:
                threading.Thread(target=_refresh_stuck, args=(stamp,), daemon=True).start()
            except BaseException:
                _STUCK["running"] = False  # the thread never ran: nothing would ever clear the flag
                raise
        found = _STUCK["found"]
        return {"findings": None if found is None else [dict(i) for i in found],
                "checked_at": _STUCK["at"], "error": _STUCK["error"],
                "checking": _STUCK["running"] or _STUCK["at"] is None, "known": found is not None}


def stuck_suppressed(status):
    """A notice when a live process holds the repository run lock without answering here as the supervisor (a
    supervisor of another checkout of this repository, or one behind another socket directory): its live work
    would read as stuck (matches the CLI's notice), so stuck is suppressed. None otherwise."""
    if status is not None:
        return None
    cfg, _ = ctx()
    holder = supervisor_stuck.run_lock_holder(run_lock_path(cfg))
    return ("a supervisor of another checkout holds the repository run lock (pid %d)" % holder
            if holder is not None else None)


def stuck_view(status, refresh=True):
    """The /api/stuck answer for a supervisor status (None: none answers).

    While a supervisor answers, the board never runs find(): the loop's own `stuck` command computes find()
    on demand rather than returning a cached list, so there is no cheap, current answer to show, and cards
    that wait for a slot, a reconcile or a resume are healthy. No card is stuck then."""
    if status is not None:
        return {"findings": [], "checked_at": None, "error": None, "checking": False, "known": True,
                "suppressed": None}
    notice = stuck_suppressed(status)
    if notice is not None:
        return {"findings": [], "checked_at": None, "error": None, "checking": False, "known": False,
                "suppressed": notice}
    _, board_dir = ctx()
    return dict(stuck_state(board_dir, refresh=refresh), suppressed=None)


def wants_stuck_refresh(params):
    """False when the page asks for no stuck refresh (a hidden tab polls with refresh_stuck=0)."""
    values = (params.get("query") or {}).get("refresh_stuck") or []
    return not values or values[-1] != "0"


def get_stuck(params, body):
    return 200, stuck_view(supervisor_status(), refresh=wants_stuck_refresh(params))


def board_extras(status, run, refresh=True):
    """({card: {kind, detail}}, {card: {action, elapsed_seconds}}) for /api/board; also adds stuck_checked_at,
    stuck_error, stuck_checking, stuck_known and stuck_suppressed to `run`. Stuck is null for every card while
    a supervisor runs, no result exists, a check failed before any result, or a run holds the lock without
    answering."""
    view = stuck_view(status, refresh=refresh)
    run.update(stuck_checked_at=view["checked_at"], stuck_error=view["error"], stuck_checking=view["checking"],
               stuck_known=view["known"], stuck_suppressed=view["suppressed"])
    stuck_of = {}
    for item in view["findings"] or []:
        stuck_of.setdefault(item["card"], {"kind": item["kind"], "detail": item["detail"]})
    activity = {}
    now = time.time()
    for a in (status.get("active") if isinstance(status, dict) else None) or []:
        if isinstance(a, dict) and is_int(a.get("card")):
            began = a.get("started_at")
            activity[a["card"]] = {"action": a.get("action"), "elapsed_seconds": (
                max(0, int(now - began)) if isinstance(began, (int, float)) and not isinstance(began, bool) else None)}
    return stuck_of, activity


def post_planner(params, body):
    return 200, {"id": start_planner()}


def post_planner_message(params, body):
    send_planner_message(params["id"], require_str(body, "text"))
    return 200, {"running": True}


def get_planner(params, body):
    return 200, planner_status(params["id"])


def post_planner_draft(params, body):
    return 200, {"import_id": draft_planner(params["id"])}


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
    status = body.get("status")
    if status is not None and status not in ("backlog", "ready"):
        raise ApiError(400, "status must be backlog or ready")
    return 200, create_import(params["id"], embed, status)


def edit_import_card_route(params, body):
    return 200, edit_import_card(params["id"], params["key"], body)


def cancel_import_session(params, body):
    return 200, cancel_import(params["id"])


# --- handler and route dispatch -----------------------------------------------

# (method, path regex, controller); the n group becomes an int, id stays a string.
ROUTES = [
    ("GET", r"/api/board", get_board),
    ("POST", r"/api/cards", create_card),
    ("GET", r"/api/cards/(?P<n>\d+)", get_card),
    ("PATCH", r"/api/cards/(?P<n>\d+)", edit_card),
    ("POST", r"/api/cards/(?P<n>\d+)/move", move_card),
    ("POST", r"/api/cards/(?P<n>\d+)/comments", comment_card),
    ("GET", r"/api/supervisor", get_supervisor),
    ("GET", r"/api/usage", get_usage),
    ("GET", r"/api/stuck", get_stuck),
    ("GET", r"/api/cards/(?P<n>\d+)/usage", get_card_usage),
    ("POST", r"/api/supervisor/(?P<action>start|pause|resume|stop)", supervisor_command),
    ("POST", r"/api/planner", post_planner),
    ("POST", r"/api/planner/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/messages", post_planner_message),
    ("POST", r"/api/planner/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/draft", post_planner_draft),
    ("GET", r"/api/planner/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)", get_planner),
    ("POST", r"/api/import", post_import),
    ("GET", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)", get_import),
    ("POST", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/create", create_import_cards),
    ("POST", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/cancel", cancel_import_session),
    ("PATCH", r"/api/import/(?P<id>[A-Za-z0-9][A-Za-z0-9._-]*)/cards/(?P<key>[A-Za-z0-9][A-Za-z0-9._-]*)", edit_import_card_route),
]
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


MAX_BODY = 1024 * 1024
REQUEST_TIMEOUT = 30  # seconds a handler waits on a silent client


def read_json_body(handler) -> dict:
    try:
        length = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        raise ApiError(400, "bad Content-Length")
    if length <= 0:
        raise ApiError(400, "a JSON object body is required")
    if length > MAX_BODY:
        handler.close_connection = True  # the unread body must not be parsed as the next request
        raise ApiError(413, "request body too large (limit %d bytes)" % MAX_BODY)
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
    timeout = REQUEST_TIMEOUT

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
                params["query"] = parse_qs(urlsplit(self.path).query)
                if method in ("POST", "PATCH"):
                    body = read_json_body(self)
                else:
                    body = {}
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
    os.environ["FLEET_BOARD_PORT"] = str(APP["port"])  # fl_url names the port this server listens on
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
