#!/usr/bin/env python3
"""board-web.py - serves the local fleet-board board over a localhost API.

Usage: python3 board-web.py --root <abs repo root> --port <int> --scripts <abs scripts dir>

Reads come straight from the card files under <root>/<board.dir>/cards/; every
write runs the script an agent would run (board-create.sh, board-move.sh,
board-comment.sh, adapters/local/edit.sh) with cwd = the repo root. The server
never writes a card file itself. Binds 127.0.0.1 only; the first stdout line is
`listening on http://127.0.0.1:<port>`; requests are logged to stderr.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import traceback
from collections import deque
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

    def __init__(self, code: int, msg: str):
        super().__init__(msg)
        self.code = code
        self.msg = msg


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
    return os.environ.get("FLEET_BOARD_USER") or os.environ.get("USER") or ""


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


def is_active(dir: Path, n) -> bool:
    return run_alive() and (Path(dir) / "active" / str(n)).exists()


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
# observed liveness (None before the first look).
_RUN: dict = {"proc": None, "alive": None}
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


def read_pid(sdir: Path):
    try:
        pid = int(read_text(sdir / "run.pid").strip())
    except ValueError:
        return None
    return pid if pid > 0 else None


def pid_alive(pid: int) -> bool:
    proc = _RUN["proc"]
    if proc is not None and proc.pid == pid:
        return proc.poll() is None
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
    """Whether the wrapper is alive; the first look after it died clears the markers."""
    cfg, dir = ctx()
    with _RUN_LOCK:
        pid = read_pid(state_dir(APP["root"], cfg))
        alive = pid is not None and pid_alive(pid)
        if _RUN["alive"] and not alive:
            clear_markers(dir)
        _RUN["alive"] = alive
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


def run_status() -> dict:
    cfg, _ = ctx()
    sdir = state_dir(APP["root"], cfg)
    alive = run_alive()
    pid = read_pid(sdir)
    out = read_text(sdir / "run.out")
    if pid is None:
        state = "idle"
    elif alive:
        state = "stopping" if (Path(APP["root"]) / STOP_FILE).exists() else "running"
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
    }


def board_run_status() -> dict:
    """run_status() without the log tail, for /api/board."""
    status = run_status()
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


# --- controllers: (params, body) -> (status, payload) -------------------------

def ctx():
    cfg = load_config(APP["root"], APP["scripts"])
    return cfg, store_dir(APP["root"], cfg)


def card_summary(dir: Path, card: dict) -> dict:
    note = parse_note(card)
    return {
        "number": card.get("number"),
        "title": card.get("title"),
        "state": card.get("state"),
        "labels": card.get("labels") or [],
        "updated_at": card.get("updated_at"),
        "active": is_active(dir, card.get("number")),
        "note": None if note is None else {k: note.get(k) for k in NOTE_FIELDS},
    }


def card_detail(cfg: dict, dir: Path, n: int) -> dict:
    card = read_card(dir, n)
    note = parse_note(card)
    pr = note.get("pr") if note else None
    repo = (cfg.get("board") or {}).get("repo")
    out = dict(card)
    out["active"] = is_active(dir, n)
    out["manager_note"] = note_body(card)
    ok = isinstance(pr, int) and not isinstance(pr, bool) and repo
    out["pr_url"] = "https://github.com/%s/pull/%d" % (repo, pr) if ok else None
    return out


def get_board(params, body):
    cfg, dir = ctx()
    return 200, {
        "states": states(cfg),
        "cards": [card_summary(dir, c) for c in read_cards(dir)],
        "run": board_run_status(),
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
        if state == "ready":
            argv += ["--state", "ready"]
        created = json.loads(board_write(argv))
    finally:
        os.unlink(path)
    if state not in (None, "ready", "backlog"):
        try:
            board_write(["bash", script("board-move.sh"), str(created["number"]), state])
        except ApiError as exc:
            raise ApiError(409, "created card #%s in backlog, but the move to %s failed: %s"
                           % (created["number"], state, exc.msg))
    return 200, created


def edit_card(params, body):
    cfg, dir = ctx()
    n = params["n"]
    card = read_card(dir, n)
    title = require_str(body, "title", required=False)
    text = require_str(body, "body", required=False)
    labels = require_labels(body)
    if title is None:
        title = card.get("title") or ""
    if text is None:
        text = card.get("body") or ""
    if labels is None:
        labels = card.get("labels") or []
    tpath, bpath = temp_text(title), temp_text(text)
    try:
        board_write(["bash", script("adapters/local/edit.sh"), str(n), tpath, bpath, json.dumps(labels)])
    finally:
        os.unlink(tpath)
        os.unlink(bpath)
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
        board_write(["bash", script("board-comment.sh"), str(n), path])
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
            raise ApiError(409, "a run is already alive")
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
            f.write("%d\n" % proc.pid)
        _RUN["proc"] = proc
        _RUN["alive"] = True
    return 200, {"pid": proc.pid}


def stop_run(params, body):
    with _RUN_LOCK:
        if not run_alive():
            raise ApiError(409, "no run is alive")
        Path(APP["root"], STOP_FILE).touch()
    return 200, {"state": "stopping"}


# --- handler and route dispatch -----------------------------------------------

# (method, path regex, controller); named groups that are digits become ints.
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
]
NO_BODY = (start_run, stop_run)  # POST routes that take no JSON body
PAGE_ROUTES = [r"/", r"/cards/\d+"]


def match_route(method: str, path: str):
    """(controller, params) for an API route, or None."""
    for m, pattern, fn in ROUTES:
        hit = re.fullmatch(pattern, path)
        if hit and m == method:
            return fn, {k: int(v) for k, v in hit.groupdict().items()}
    return None


def json_error(handler, code: int, msg: str):
    send_json(handler, code, {"error": msg})


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
            json_error(self, exc.code, exc.msg)
        except Exception as exc:  # noqa: BLE001 - every failure becomes a JSON 500
            traceback.print_exc(file=sys.stderr)
            json_error(self, 500, str(exc) or exc.__class__.__name__)


# --- main ---------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="board-web.py")
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--scripts", required=True)
    args = ap.parse_args(argv)
    APP["root"] = os.path.abspath(args.root)
    APP["scripts"] = os.path.abspath(args.scripts)
    APP["static"] = (Path(APP["scripts"]) / "board-web" / "static").resolve()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
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
