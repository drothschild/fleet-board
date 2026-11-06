#!/usr/bin/env python3
"""Bounded controller-side chat tool loop. Tests run in a networkless container."""
import argparse
import decimal
import json
import os
import re
import selectors
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MAX_BODY = 20 * 1024 * 1024
TOOLS = [
    {"type": "function", "function": {"name": "read_file", "description": "Read a UTF-8 file in the assigned checkout", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "write_file", "description": "Write a UTF-8 file in the assigned checkout", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "run_test", "description": "Run one controller-approved test by ID", "parameters": {"type": "object", "properties": {"test_id": {"type": "string"}}, "required": ["test_id"], "additionalProperties": False}}},
]

class Invalid(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def integer(value, low, high):
    return type(value) is int and low <= value <= high

def validate_url(value):
    if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Invalid("invalid base URL")
    u = urllib.parse.urlsplit(value)
    if u.username is not None or u.password is not None or u.query or u.fragment or not u.hostname:
        raise Invalid("invalid base URL")
    if u.scheme != "https" and not (u.scheme == "http" and u.hostname in ("localhost", "127.0.0.1", "::1")):
        raise Invalid("base URL must use HTTPS or loopback HTTP")
    try:
        u.port
    except ValueError:
        raise Invalid("invalid base URL port")
    return value.rstrip("/") + "/chat/completions"

def parts(path):
    if not isinstance(path, str) or not path or path.startswith("/") or "\x00" in path:
        raise Invalid("invalid path")
    p = path.split("/")
    if any(x in ("", ".", "..", ".git") for x in p):
        raise Invalid("path outside checkout")
    return p

def open_parent(root, name):
    p = parts(name)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in p[:-1]:
            nxt = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd, p[-1]
    except Exception:
        os.close(fd)
        raise

def read_file(root, path, cap):
    parent, name = open_parent(root, path)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Invalid("not an isolated regular file")
            data = os.read(fd, cap + 1)
            if len(data) > cap:
                raise Invalid("file exceeds output limit")
            return data.decode("utf-8")
        finally:
            os.close(fd)
    finally:
        os.close(parent)

def write_file(root, path, content, cap):
    if not isinstance(content, str) or len(content.encode()) > cap:
        raise Invalid("invalid content or size")
    parent, name = open_parent(root, path)
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
        fd = os.open(name, flags, 0o600, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Invalid("not an isolated regular file")
            os.ftruncate(fd, 0)
            data = content.encode()
            while data:
                n = os.write(fd, data)
                if n <= 0:
                    raise Invalid("write failed")
                data = data[n:]
        finally:
            os.close(fd)
    finally:
        os.close(parent)
    return "written"

def run_test(req, test_id, timeout):
    if not isinstance(test_id, str) or test_id not in req["tests"]:
        raise Invalid("test is not approved")
    root = req["worktree"]
    gitdir = os.path.join(root, ".git")
    if not os.path.isdir(gitdir) or os.path.islink(gitdir) or os.path.exists(os.path.join(gitdir, "objects", "info", "alternates")):
        raise Invalid("test requires an isolated checkout")
    # A bind mount preserves host hard links; deny them before exposing the
    # checkout to a test process. Git metadata is hidden by a tmpfs mount.
    for directory, dirs, files in os.walk(root, followlinks=False):
        if directory == root and ".git" in dirs:
            dirs.remove(".git")
        for entry in files:
            info = os.lstat(os.path.join(directory, entry))
            if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
                raise Invalid("checkout contains hard links")
    if "," in root or "\n" in root:
        raise Invalid("invalid checkout mount")
    docker = shutil.which("docker")
    if not docker:
        raise Invalid("container isolation unavailable")
    l = req["limits"]
    name = "fleet-tool-" + str(os.getpid()) + "-" + secrets.token_hex(12)
    env = {"PATH": os.defpath}
    for variable in ("HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"):
        if variable in os.environ:
            env[variable] = os.environ[variable]
    command = [docker, "create", "--pull", "never", "--name", name, "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", str(l["pids"]), "--memory", str(l["memory_mb"]) + "m", "--cpus", "1", "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m", "--mount", "type=bind,src=" + root + ",dst=/work", "--tmpfs", "/work/.git:rw,noexec,nosuid,size=1m", "--workdir", "/work", "--entrypoint", "/usr/bin/env", req["image"], "-i", "PATH=/usr/bin:/bin", "HOME=/tmp"] + req["tests"][test_id]
    # A detached monitor removes the named container if this process is killed.
    watch_code = ("import os,subprocess,sys,time; p=int(sys.argv[1]); "
                  "print('ready', flush=True); exec('while os.getppid()==p:\\n time.sleep(0.2)'); "
                  "subprocess.run([sys.argv[2], 'rm', '-f', sys.argv[3]], "
                  "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)")
    watchdog = None
    process = None
    started = time.monotonic()
    try:
        watchdog = subprocess.Popen([sys.executable, "-I", "-c", watch_code, str(os.getpid()), docker, name], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, start_new_session=True, close_fds=True)
        watcher_ready = selectors.DefaultSelector()
        watcher_ready.register(watchdog.stdout, selectors.EVENT_READ)
        if not watcher_ready.select(min(2, timeout)) or watchdog.stdout.readline() != b"ready\n":
            raise Invalid("container watchdog unavailable")
        watcher_ready.close()
        created = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout, env=env, check=False)
        if created.returncode != 0:
            raise Invalid("container isolation unavailable")
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            raise Invalid("isolated test timed out")
        process = subprocess.Popen([docker, "start", "-a", name], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, close_fds=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        chunks, total, truncated = [], 0, False
        while selector.get_map():
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise Invalid("isolated test timed out")
            events = selector.select(remaining)
            if not events:
                raise Invalid("isolated test timed out")
            data = os.read(process.stdout.fileno(), 8192)
            if not data:
                selector.unregister(process.stdout)
                break
            keep = max(0, l["max_output_bytes"] - total)
            chunks.append(data[:keep])
            total += len(data)
            if total > l["max_output_bytes"]:
                truncated = True
                raise Invalid("isolated test exceeded output limit")
        rc = process.wait(timeout=max(0.1, timeout - (time.monotonic() - started)))
        return json.dumps({"exit_code": rc, "output": b"".join(chunks).decode("utf-8", "replace"), "truncated": truncated}, separators=(",", ":"))
    except (OSError, subprocess.TimeoutExpired):
        raise Invalid("isolated test failed to run")
    finally:
        try:
            subprocess.run([docker, "rm", "-f", name], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, env=env, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
        if process is not None:
            if process.poll() is None:
                process.kill()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if watchdog is not None:
            watchdog.terminate()
            try:
                watchdog.wait(timeout=2)
            except subprocess.TimeoutExpired:
                watchdog.kill()
                watchdog.wait()

def validate_request(req, scratch):
    if not isinstance(req, dict) or req.get("version") != 1:
        raise Invalid("invalid request version")
    url = validate_url(req.get("base_url"))
    key_env = req.get("key_env")
    if not isinstance(key_env, str) or not (key_env == "-" or re.fullmatch(r"[A-Z_][A-Z0-9_]*", key_env)):
        raise Invalid("invalid credential name")
    if key_env == "-" and urllib.parse.urlsplit(url).hostname not in ("localhost", "127.0.0.1", "::1"):
        raise Invalid("anonymous provider must be loopback")
    key = "" if key_env == "-" else os.environ.get(key_env, "")
    if key_env != "-" and (not key or any(ord(c) < 32 or ord(c) == 127 for c in key)):
        raise Invalid("provider credential unavailable")
    if key_env != "-":
        rates = req.get("pricing")
        limit = req.get("max_cost_usd")
        def amount(value):
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise Invalid("paid provider requires valid budget and pricing")
            amount_value = decimal.Decimal(str(value))
            if not amount_value.is_finite() or amount_value < 0 or amount_value > decimal.Decimal("1000000000"):
                raise Invalid("paid provider requires valid budget and pricing")
            return amount_value
        if not isinstance(rates, dict):
            raise Invalid("paid provider requires valid budget and pricing")
        amount(rates.get("input_usd_per_million"))
        amount(rates.get("output_usd_per_million"))
        amount(limit)
    if not isinstance(req.get("model"), str) or not req["model"] or len(req["model"]) > 256:
        raise Invalid("invalid model")
    msgs = req.get("messages")
    if not isinstance(msgs, list) or not msgs or len(msgs) > 128 or any(not isinstance(m, dict) or m.get("role") not in ("system", "user") or not isinstance(m.get("content"), str) or len(m["content"].encode("utf-8")) > 1048576 for m in msgs):
        raise Invalid("invalid initial messages")
    root = req.get("worktree")
    if not isinstance(root, str) or not os.path.isabs(root) or os.path.realpath(root) != root or not os.path.isdir(root):
        raise Invalid("invalid checkout")
    if not os.path.isdir(scratch) or os.path.islink(scratch):
        raise Invalid("invalid scratch")
    image = req.get("image")
    if not isinstance(image, str) or not re.fullmatch(r"[A-Za-z0-9._/:@-]+", image):
        raise Invalid("invalid image")
    l = req.get("limits")
    if not isinstance(l, dict) or not all(integer(l.get(k), lo, hi) for k, lo, hi in [("max_calls", 1, 100), ("seconds", 1, 3600), ("memory_mb", 64, 8192), ("pids", 8, 512), ("max_output_bytes", 1, 1048576)]):
        raise Invalid("invalid limits")
    if not integer(l.get("max_output_tokens", 4096), 1, 65536):
        raise Invalid("invalid output token limit")
    tests = req.get("tests")
    if not isinstance(tests, dict) or len(tests) > 32:
        raise Invalid("invalid tests")
    for name, argv in tests.items():
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", name) or not isinstance(argv, list) or not argv or len(argv) > 64 or any(not isinstance(a, str) or not a or "\x00" in a or len(a) > 4096 for a in argv):
            raise Invalid("invalid approved test")
    return url, key

def validate_calls(calls, remaining, tests):
    if not isinstance(calls, list) or not calls or len(calls) > remaining:
        raise Invalid("tool call limit exceeded")
    seen, parsed = set(), []
    for call in calls:
        if not isinstance(call, dict) or call.get("type") != "function" or not isinstance(call.get("id"), str) or not call["id"] or call["id"] in seen:
            raise Invalid("invalid tool call")
        seen.add(call["id"])
        fn = call.get("function")
        if not isinstance(fn, dict) or fn.get("name") not in ("read_file", "write_file", "run_test") or not isinstance(fn.get("arguments"), str):
            raise Invalid("invalid tool function")
        try:
            args = json.loads(fn["arguments"])
        except (ValueError, TypeError):
            raise Invalid("malformed tool arguments")
        expected = {"read_file": {"path"}, "write_file": {"path", "content"}, "run_test": {"test_id"}}[fn["name"]]
        if not isinstance(args, dict) or set(args) != expected:
            raise Invalid("invalid tool arguments")
        if "path" in args:
            parts(args["path"])
        if fn["name"] == "write_file" and not isinstance(args["content"], str):
            raise Invalid("invalid content")
        if fn["name"] == "run_test" and (not isinstance(args["test_id"], str) or args["test_id"] not in tests):
            raise Invalid("unapproved test")
        parsed.append((call["id"], fn["name"], args))
    return parsed

def interrupted(signum, frame):
    raise Invalid("interrupted")

def main():
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    ap.add_argument("--scratch", required=True)
    cli = ap.parse_args()
    usage = {"input_tokens": 0, "output_tokens": 0, "attempts": 0, "unknown": False, "cost_usd": 0}
    cost = decimal.Decimal(0)
    attempts = []
    try:
        with open(cli.request, encoding="utf-8") as f:
            req = json.load(f)
        url, key = validate_request(req, cli.scratch)
        messages = list(req["messages"])
        l = req["limits"]
        deadline = time.monotonic() + l["seconds"]
        count = 0
        opener = urllib.request.build_opener(NoRedirect())
        while True:
            remaining = deadline - time.monotonic()
            if key and cost >= decimal.Decimal(str(req["max_cost_usd"])):
                raise Invalid("provider budget exhausted")
            if remaining <= 0:
                raise Invalid("time limit exceeded")
            body = json.dumps({"model": req["model"], "messages": messages, "tools": TOOLS, "tool_choice": "auto", "max_tokens": l.get("max_output_tokens", 4096)}, separators=(",", ":")).encode()
            headers = {"Content-Type": "application/json"}
            if key:
                headers["Authorization"] = "Bearer " + key
            request = urllib.request.Request(url, data=body, headers=headers, method="POST")
            usage["attempts"] += 1
            attempt = {"id": secrets.token_hex(16), "status": "unknown", "usage": None}
            attempts.append(attempt)
            try:
                with opener.open(request, timeout=remaining) as response:
                    data = response.read(MAX_BODY + 1)
                if len(data) > MAX_BODY:
                    raise Invalid("provider response too large")
                result = json.loads(data)
            except (OSError, ValueError, urllib.error.URLError):
                usage["unknown"] = True
                raise Invalid("provider request failed or returned invalid JSON")
            u = result.get("usage") if isinstance(result, dict) else None
            if not isinstance(u, dict) or not integer(u.get("prompt_tokens"), 0, 10**12) or not integer(u.get("completion_tokens"), 0, 10**12):
                usage["unknown"] = True
                raise Invalid("provider usage unavailable")
            attempt["status"] = "received"
            attempt["usage"] = {"input_tokens": u["prompt_tokens"], "output_tokens": u["completion_tokens"]}
            attempt["reported_model"] = result.get("model", req["model"])
            usage["input_tokens"] += u["prompt_tokens"]
            usage["output_tokens"] += u["completion_tokens"]
            if key:
                if result.get("model") != req["model"]:
                    usage["unknown"] = True
                    raise Invalid("reported model differs from priced model")
                rates = req["pricing"]
                cost += (decimal.Decimal(u["prompt_tokens"]) * decimal.Decimal(str(rates["input_usd_per_million"])) + decimal.Decimal(u["completion_tokens"]) * decimal.Decimal(str(rates["output_usd_per_million"]))) / decimal.Decimal(1000000)
                usage["cost_usd"] = float(cost)
                attempt["cost_usd"] = float((decimal.Decimal(u["prompt_tokens"]) * decimal.Decimal(str(rates["input_usd_per_million"])) + decimal.Decimal(u["completion_tokens"]) * decimal.Decimal(str(rates["output_usd_per_million"]))) / decimal.Decimal(1000000))
                if cost >= decimal.Decimal(str(req["max_cost_usd"])):
                    raise Invalid("provider budget exhausted")
            choices = result.get("choices")
            if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict) or not isinstance(choices[0].get("message"), dict):
                raise Invalid("invalid provider response")
            msg = choices[0]["message"]
            if msg.get("role") != "assistant":
                raise Invalid("invalid assistant message")
            calls = msg.get("tool_calls")
            if calls is None:
                if choices[0].get("finish_reason") != "stop" or not isinstance(msg.get("content"), str):
                    raise Invalid("invalid final response")
                print(json.dumps({"version": 1, "outcome": "done", "text": msg["content"], "model": result.get("model", req["model"]), "usage": usage, "attempts": attempts}))
                return 0
            if choices[0].get("finish_reason") != "tool_calls":
                raise Invalid("invalid tool finish reason")
            parsed = validate_calls(calls, l["max_calls"] - count, req["tests"])
            messages.append(msg)
            for call_id, name, args in parsed:
                if name == "read_file":
                    output = read_file(req["worktree"], args["path"], l["max_output_bytes"])
                elif name == "write_file":
                    output = write_file(req["worktree"], args["path"], args["content"], l["max_output_bytes"])
                else:
                    output = run_test(req, args["test_id"], max(0.1, deadline - time.monotonic()))
                messages.append({"role": "tool", "tool_call_id": call_id, "content": output})
                count += 1
    except (Invalid, OSError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        print(json.dumps({"version": 1, "outcome": "failed", "error": str(error) if isinstance(error, Invalid) else "invalid input or filesystem operation", "usage": usage, "attempts": attempts}))
        return 1

if __name__ == "__main__":
    sys.exit(main())
