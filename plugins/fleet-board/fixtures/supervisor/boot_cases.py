"""Offline contract cases for boot registration, rendered service files and boot recovery.

Nothing here installs a service or touches the host: launchctl, systemctl and loginctl are
fakes that only record argv, and every written file lives under a private HOME. These cases
check generated files and decisions; they do not prove what happens on a real reboot.
"""
import json
import os
import plistlib
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(sys.argv.pop()).resolve()
SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from supervisor import paths  # noqa: E402
from supervisor.store import Store  # noqa: E402

try:
    import importlib
    boot = importlib.import_module("supervisor.boot")
except ModuleNotFoundError as exc:
    if exc.name not in ("supervisor", "supervisor.boot"):
        raise
    boot = None

YAML_TRUE = "board:\n  repo: acme/toy\nsupervisor:\n  start_on_boot: true\n"
YAML_FALSE = "board:\n  repo: acme/toy\nsupervisor:\n  start_on_boot: false\n"
SECRET = "s3cret-value-must-never-be-written"
SYSTEM_DAEMONS = Path("/Library/LaunchDaemons")

FAKE = """#!/bin/bash
name=$(basename "$0")
{ for a in "$@"; do printf '%s\\n' "$a"; done; echo "--"; } >> "$FAKE_LOG_DIR/$name.argv"
[ -f "$FAKE_LOG_DIR/$name.out" ] && cat "$FAKE_LOG_DIR/$name.out"
[ -f "$FAKE_LOG_DIR/$name.rc" ] && exit "$(cat "$FAKE_LOG_DIR/$name.rc")"
exit 0
"""
SENTINEL = """#!/bin/bash
echo "$(basename "$0") $*" >> "$SENTINEL_FILE"
exit 99
"""


def short_dir(prefix):
    path = Path(tempfile.mkdtemp(prefix=prefix, dir=os.path.realpath("/tmp")))
    os.chmod(path, 0o700)
    return path


class FakeChild:
    def __init__(self):
        self.terminated = False
        self.reaped = False

    def poll(self):
        return None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.terminated = True

    def wait(self, timeout=None):
        self.reaped = True
        return 0


class BootCase(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(boot, "supervisor.boot is not implemented")
        self.work = short_dir("fbb-")
        self.addCleanup(shutil.rmtree, str(self.work), True)
        self.home = self.work / "my home"
        self.home.mkdir(mode=0o700)
        self.board = self.work / "repo with space"
        self.board.mkdir()
        subprocess.run(["git", "init", "-q", str(self.board)], check=True)
        self.set_yaml(YAML_TRUE)
        self.logs = self.work / "log dir"
        self.sockets = self.work / "s"
        self.fakes = self.work / "fakes"
        self.sentinels = self.work / "sentinels"
        self.fake_log = self.work / "fakelog"
        self.sentinel_file = self.work / "REAL-REACHED"
        for directory in (self.fakes, self.sentinels, self.fake_log):
            directory.mkdir()
        for name in ("launchctl", "systemctl", "loginctl"):
            self.write_exec(self.fakes / name, FAKE)
        for name in ("sudo", "doas", "launchctl", "systemctl", "loginctl"):
            self.write_exec(self.sentinels / name, SENTINEL)
        self.daemons_before = self.list_daemons()
        self.counter = 0
        self.addCleanup(self.assert_host_untouched)

    # -- helpers ---------------------------------------------------------------
    @staticmethod
    def write_exec(path, text):
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    @staticmethod
    def list_daemons():
        try:
            return sorted(os.listdir(str(SYSTEM_DAEMONS)))
        except OSError:
            return None

    def assert_host_untouched(self):
        self.assertFalse(self.sentinel_file.exists(),
                         "a real privileged or service tool was reached: " +
                         (self.sentinel_file.read_text() if self.sentinel_file.exists() else ""))
        self.assertEqual(self.calls("sudo"), [])
        self.assertEqual(self.list_daemons(), self.daemons_before, "wrote to /Library/LaunchDaemons")

    def set_yaml(self, text):
        (self.board / ".fleet-board.yml").write_text(text, encoding="utf-8")

    def env(self, **extra):
        env = {"HOME": str(self.home), "PATH": os.pathsep.join([str(self.fakes), str(self.sentinels), "/usr/bin", "/bin"]),
               "PYTHONPATH": str(SCRIPTS), "PYTHONDONTWRITEBYTECODE": "1",
               "FAKE_LOG_DIR": str(self.fake_log), "SENTINEL_FILE": str(self.sentinel_file),
               "FLEET_BOARD_LOG_DIR": str(self.logs), "FLEET_BOARD_SOCKET_DIR": str(self.sockets),
               "FLEET_BOARD_DOMAIN": str(self.board)}
        env.update(extra)
        return env

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, "-m", "supervisor.cli"] + list(args), env=env or self.env(),
                              cwd=str(self.board), capture_output=True, text=True, timeout=60)

    def service(self, *args, env=None):
        done = self.cli("service", *args, env=env)
        self.assertEqual(done.returncode, 0, "service %s failed: %s %s" % (args, done.stdout, done.stderr))
        return json.loads(done.stdout)

    def install(self, *extra, platform="linux", env=None):
        out = self.work / "rendered"
        return self.service("install", "--platform", platform, "--output-dir", str(out),
                            "--install-dir", str(self.work / "installed"), *extra, env=env)

    def calls(self, name):
        path = self.fake_log / (name + ".argv")
        if not path.exists():
            return []
        calls, current = [], []
        for line in path.read_text(encoding="utf-8").splitlines():
            if line == "--":
                calls.append(current)
                current = []
            else:
                current.append(line)
        return calls

    def registry(self, env=None):
        return Path((env or self.env()).get("FLEET_BOARD_REGISTRY_DIR") or self.home / ".fleet-board" / "supervisor-registry")

    def domain(self):
        return paths.board_domain(self.board, self.logs / "supervisor")

    def store_command(self, command):
        self.counter += 1
        store = Store.open(self.domain())
        try:
            revision = store.snapshot()["domain"]["revision"]
            store.record_command({"id": "boot-%d" % self.counter, "actor": "fixture-human", "command": command,
                                  "payload": {}, "expected_revision": revision})
        finally:
            store.close()

    def store_state(self):
        store = Store.open(self.domain())
        try:
            snap = store.snapshot()
            return {"mode": snap["domain"]["desired_mode"], "revision": snap["domain"]["revision"],
                    "events": len(snap["events"])}
        finally:
            store.close()

    def set_mode(self, mode):
        if mode == "stopped":
            return
        self.store_command("start")
        if mode == "paused":
            self.store_command("pause")

    def boot_once(self, boot_id, mode=None, env=None):
        """One boot entry decision with recording fakes; returns (outcome, calls)."""
        calls = []

        def launch(root, launch_env):
            calls.append("launch")
            return FakeChild()

        def activate(root, launch_env):
            calls.append("start")

        outcome = boot.boot_domain(self.board, env=env or self.env(), boot_id=boot_id, launch=launch, activate=activate)
        return outcome, calls


class Rendering(BootCase):
    def test_launchd_daemon_plist_uses_argv_elements_username_and_explicit_environment(self):
        result = self.install("--kind", "boot", "--credential-env", "FB_TEST_TOKEN",
                              platform="darwin", env=self.env(FB_TEST_TOKEN=SECRET))
        plist_path = Path(result["rendered"])
        self.assertTrue(str(plist_path).startswith(str(self.home) + os.sep) or str(plist_path).startswith(str(self.work)))
        plist = plistlib.loads(plist_path.read_bytes())
        launcher = str(self.registry() / "bin" / "boot")
        self.assertIsInstance(plist["ProgramArguments"], list)
        self.assertIn(launcher, plist["ProgramArguments"], "launcher path with spaces must be one argv element")
        self.assertIn(str(self.board), plist["ProgramArguments"], "repo path with spaces must be one argv element")
        self.assertEqual(plist["UserName"], boot.current_user())
        self.assertEqual(plist["Label"], result["label"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["KeepAlive"], {"SuccessfulExit": False})
        env = plist["EnvironmentVariables"]
        self.assertEqual(env["FLEET_BOARD_SOCKET_DIR"], str(self.sockets))
        self.assertEqual(env["FLEET_BOARD_LOG_DIR"], str(self.logs))
        self.assertTrue(os.path.isabs(env["PATH"].split(os.pathsep)[0]))
        self.assertTrue(plist["StandardErrorPath"].startswith(str(self.logs)))
        self.assertTrue(result["boot_before_login"])
        self.assertFalse(result["login_fallback"])
        # Boot-before-login needs an administrator: the commands are printed for a person, never run.
        privileged = result["privileged_commands"]
        self.assertTrue(privileged and all(cmd[0] == "sudo" for cmd in privileged))
        self.assertTrue(any("/Library/LaunchDaemons/%s.plist" % result["label"] in cmd for cmd in privileged))
        self.assertEqual(self.calls("launchctl"), [], "rendering must not call launchctl")
        self.assert_no_secret_anywhere()

    def test_launchd_user_agent_is_a_labeled_login_fallback(self):
        result = self.install("--kind", "login", "--apply", platform="darwin")
        plist = plistlib.loads(Path(result["rendered"]).read_bytes())
        self.assertNotIn("UserName", plist)
        self.assertTrue(result["login_fallback"])
        self.assertFalse(result["boot_before_login"])
        self.assertEqual(result["privileged_commands"], [])
        installed = self.work / "installed" / (result["label"] + ".plist")
        self.assertTrue(installed.exists())
        self.assertIn(["bootstrap", "gui/%d" % os.getuid(), str(installed)], self.calls("launchctl"))
        status = self.service("status", "--platform", "darwin")
        self.assertEqual(status["boot_registration"], "login_fallback")

    def test_systemd_user_unit_quotes_exec_start_and_diagnoses_lingering(self):
        (self.fake_log / "loginctl.out").write_text("Linger=no\n", encoding="utf-8")
        result = self.install("--apply")
        text = Path(result["rendered"]).read_text(encoding="utf-8")
        lines = dict(line.split("=", 1) for line in text.splitlines() if "=" in line and not line.startswith("Environment"))
        argv = shlex.split(lines["ExecStart"].replace("%%", "%"))
        self.assertIn(str(self.registry() / "bin" / "boot"), argv)
        self.assertIn(str(self.board), argv)
        self.assertEqual(lines["Restart"], "on-failure")
        self.assertEqual(lines["WantedBy"], "default.target")
        self.assertIn("FLEET_BOARD_SOCKET_DIR", text)
        self.assertIn("FLEET_BOARD_LOG_DIR", text)
        self.assertEqual(result["diagnostics"]["lingering"], "missing")
        self.assertIn("loginctl", result["diagnostics"]["enable_lingering_command"][0])
        self.assertFalse(any(call and call[0] == "enable-linger" for call in self.calls("loginctl")),
                         "enabling lingering is a person's decision, not an install side effect")
        systemctl = self.calls("systemctl")
        self.assertIn(["--user", "daemon-reload"], systemctl)
        self.assertIn(["--user", "enable", result["unit"]], systemctl)
        self.assertFalse(any("--now" in call for call in systemctl), "setup must not start work")
        self.assertEqual(self.service("status")["boot_registration"], "lingering_missing")
        (self.fake_log / "loginctl.out").write_text("Linger=yes\n", encoding="utf-8")
        self.assertEqual(self.service("status")["boot_registration"], "verified")

    def test_no_secret_value_is_written_and_credentials_are_names_only(self):
        self.install("--credential-env", "FB_TEST_TOKEN", env=self.env(FB_TEST_TOKEN=SECRET))
        entry = json.loads(next((self.registry() / "domains").glob("*.json")).read_text(encoding="utf-8"))
        self.assertEqual(entry["credentials"], ["FB_TEST_TOKEN"])
        self.assert_no_secret_anywhere()

    def assert_no_secret_anywhere(self):
        for base in (self.home, self.work / "rendered"):
            for path in base.rglob("*") if base.exists() else []:
                if path.is_file():
                    self.assertNotIn(SECRET, path.read_text(encoding="utf-8", errors="replace"), str(path))


class Registry(BootCase):
    def test_status_is_missing_before_installation_and_never_claims_boot(self):
        status = self.service("status")
        self.assertEqual(status["boot_registration"], "missing")
        self.assertEqual(boot.registration_state(self.board, self.env())["boot_registration"], "missing")
        self.assertEqual(self.calls("systemctl"), [])

    def test_installed_but_not_activated_is_pending_not_verified(self):
        self.install()
        state = boot.registration_state(self.board, self.env())
        self.assertEqual(state["boot_registration"], "pending_activation")
        self.assertEqual(self.service("status", "--platform", "darwin")["boot_registration"], "pending_activation")

    def test_service_status_reports_registration_from_the_real_registry(self):
        from supervisor.service import Service
        self.install()
        with mock.patch.dict(os.environ, {"HOME": str(self.home), "FLEET_BOARD_LOG_DIR": str(self.logs),
                                          "FLEET_BOARD_SOCKET_DIR": str(self.sockets)}):
            service = Service.open(self.domain(), board_repo=str(self.board), execution_enabled=False)
            try:
                status = service.get_status()
            finally:
                service.close()
        self.assertEqual(status["boot_registration"], "pending_activation")
        self.assertIsNone(status["last_error"])

    def test_registry_is_private_and_override_is_honored(self):
        self.install()
        registry = self.registry()
        self.assertEqual(registry, self.home / ".fleet-board" / "supervisor-registry")
        self.assertEqual(stat.S_IMODE(registry.stat().st_mode), 0o700)
        for path in registry.rglob("*"):
            mode = stat.S_IMODE(path.stat().st_mode)
            if path.is_dir():
                self.assertEqual(mode, 0o700, str(path))
            elif path.parent.name == "bin":
                self.assertEqual(mode, 0o700, str(path))
            else:
                self.assertEqual(mode, 0o600, str(path))
        other = self.work / "other registry"
        env = self.env(FLEET_BOARD_REGISTRY_DIR=str(other))
        self.install(env=env)
        self.assertTrue((other / "registry.json").exists())
        record = json.loads((other / "registry.json").read_text(encoding="utf-8"))
        for key in ("version", "protocol", "python", "scripts_dir", "executables"):
            self.assertIn(key, record)
        self.assertTrue(os.path.isabs(record["python"]))

    def test_stable_launcher_lives_outside_the_plugin_directory(self):
        result = self.install()
        launcher = Path(result["launcher"])
        self.assertTrue(os.access(str(launcher), os.X_OK))
        self.assertFalse(str(launcher).startswith(str(SCRIPTS.parent)))

    def test_first_install_initializes_stopped_and_reinstall_keeps_intent(self):
        self.install()
        self.assertEqual(self.store_state()["mode"], "stopped")
        self.assertEqual(self.store_state()["events"], 0)
        self.set_mode("running")
        self.install()
        self.assertEqual(self.store_state()["mode"], "running", "reinstall is idempotent and never resets intent")

    def test_upgrade_keeps_a_backup_and_rollback_restores_the_previous_version(self):
        self.install()
        record_path = self.registry() / "registry.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        current_version = record["version"]
        record["version"] = "0.19.1"
        record_path.write_text(json.dumps(record), encoding="utf-8")
        result = self.install()
        backups = list((self.registry() / "backups").glob("0.19.1*"))
        self.assertEqual(len(backups), 1, "the previous version must be backed up")
        self.assertEqual(result["backup"], str(backups[0]))
        self.assertEqual(json.loads(record_path.read_text(encoding="utf-8"))["version"], current_version)
        rolled = self.service("rollback")
        self.assertEqual(rolled["restored_version"], "0.19.1")
        self.assertEqual(json.loads(record_path.read_text(encoding="utf-8"))["version"], "0.19.1")

    def test_uninstall_removes_registration_but_never_state(self):
        self.install("--apply")
        self.set_mode("running")
        before = self.store_state()
        result = self.service("uninstall", "--platform", "linux", "--apply", "--install-dir", str(self.work / "installed"))
        self.assertEqual(result["removed"], True)
        self.assertEqual(boot.registration_state(self.board, self.env())["boot_registration"], "missing")
        self.assertEqual(self.store_state(), before)
        self.assertIn(["--user", "disable", result["unit"]], self.calls("systemctl"))


class BootRecovery(BootCase):
    def setUp(self):
        super().setUp()
        self.install()

    def test_true_restores_running_then_scheduling(self):
        self.set_mode("running")
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, ["launch", "start"], "recovery (serve) first, then scheduling")
        self.assertEqual(outcome["action"], "restored")

    def test_true_restores_paused_to_recovery_then_paused(self):
        self.set_mode("paused")
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, ["launch"], "paused recovers but must not resume scheduling")
        self.assertEqual(outcome["action"], "restored")

    def test_true_keeps_stopped_stopped(self):
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, [])
        self.assertEqual(outcome["action"], "stayed_stopped")
        self.assertEqual(self.store_state()["mode"], "stopped")

    def test_keepalive_never_overrides_stopped_intent_on_same_boot(self):
        self.boot_once("boot-1")
        self.set_mode("running")
        self.store_command("stop")
        outcome, calls = self.boot_once("boot-1")
        self.assertEqual(calls, [])
        self.assertEqual(outcome["action"], "stayed_stopped")

    def test_same_boot_crash_restart_recovers_running(self):
        self.set_mode("running")
        self.boot_once("boot-1")
        outcome, calls = self.boot_once("boot-1")
        self.assertEqual(calls, ["launch", "start"])
        self.assertEqual(outcome["action"], "restored")
        self.assertFalse(outcome["reboot"])

    def test_a_new_boot_id_is_reported_as_reboot(self):
        self.set_mode("running")
        self.boot_once("boot-1")
        outcome, _calls = self.boot_once("boot-2")
        self.assertTrue(outcome["reboot"])

    def test_false_after_prior_true_suppresses_boot_activation_without_touching_state(self):
        self.set_mode("running")
        self.set_yaml(YAML_FALSE)
        before = self.store_state()
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, [])
        self.assertEqual(outcome["action"], "suppressed")
        self.assertEqual(outcome["status"]["reason"], "start_on_boot_false")
        self.assertEqual(self.store_state(), before, "suppression must not rewrite desired mode")
        # Changing the YAML back is honored on the next boot: the bootstrap reads it every start.
        self.set_yaml(YAML_TRUE)
        _outcome, calls = self.boot_once("boot-3")
        self.assertEqual(calls, ["launch", "start"])

    def test_false_still_honors_an_explicit_start_after_suppression(self):
        self.set_mode("paused")
        self.set_yaml(YAML_FALSE)
        self.boot_once("boot-2")
        self.store_command("start")
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, ["launch", "start"], "same-boot crash restart of an explicitly started domain recovers")
        self.assertEqual(outcome["action"], "restored")

    def test_false_same_boot_without_explicit_start_stays_suppressed(self):
        self.set_mode("running")
        self.set_yaml(YAML_FALSE)
        self.boot_once("boot-2")
        _outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, [])


class RecoverableFailures(BootCase):
    def setUp(self):
        super().setUp()
        self.install("--credential-env", "FB_TEST_TOKEN", env=self.env(FB_TEST_TOKEN="present"))
        self.set_mode("running")
        self.good_env = self.env(FB_TEST_TOKEN="present")

    def assert_waiting(self, reason, env=None):
        before = self.store_state()
        outcome, calls = self.boot_once("boot-2", env=env or self.good_env)
        self.assertEqual(calls, [], "no launch and no dispatch while %s" % reason)
        self.assertEqual(outcome["action"], "waiting")
        self.assertEqual(outcome["status"]["reason"], reason)
        self.assertEqual(self.store_state(), before, "state must never be wiped")
        state = boot.registration_state(self.board, self.good_env)
        self.assertEqual(state["last_error"]["code"], reason, "the reason must be visible in status")
        self.assertNotIn(SECRET, json.dumps(state))

    def test_invalid_yaml_waits_and_recovers_when_fixed(self):
        self.set_yaml("board: [\n")
        self.assert_waiting("invalid_config")
        self.set_yaml(YAML_TRUE)
        outcome, calls = self.boot_once("boot-2", env=self.good_env)
        self.assertEqual(calls, ["launch", "start"])
        self.assertIsNone(boot.registration_state(self.board, self.good_env)["last_error"])

    def test_missing_repository_waits_and_creates_no_new_empty_board(self):
        moved = self.work / "moved"
        self.board.rename(moved)
        try:
            calls = []
            outcome = boot.boot_domain(self.board, env=self.good_env, boot_id="boot-2",
                                       launch=lambda *a: calls.append("launch"), activate=lambda *a: calls.append("start"))
            self.assertEqual(calls, [])
            self.assertEqual(outcome["status"]["reason"], "repo_missing")
            self.assertFalse(self.board.exists(), "a missing repository must not be recreated")
        finally:
            moved.rename(self.board)
        self.assertEqual(self.store_state()["mode"], "running")

    def test_missing_executable_waits(self):
        record_path = self.registry() / "registry.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["executables"]["python"] = str(self.work / "gone" / "python3")
        record_path.write_text(json.dumps(record), encoding="utf-8")
        self.assert_waiting("missing_executable")

    def test_missing_credentials_wait_without_dispatch(self):
        self.assert_waiting("missing_credentials", env=self.env())

    def test_protocol_incompatibility_is_refused_with_a_rollback_path(self):
        record_path = self.registry() / "registry.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["protocol"] = 999
        record_path.write_text(json.dumps(record), encoding="utf-8")
        self.assert_waiting("incompatible_protocol")
        state = boot.registration_state(self.board, self.good_env)
        self.assertIn("rollback", state["last_error"]["message"])


class EndToEnd(BootCase):
    def test_rendered_service_and_a_plain_client_agree_with_no_overrides(self):
        env = {"HOME": str(self.home), "PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
               "PYTHONPATH": str(SCRIPTS), "FLEET_BOARD_DOMAIN": str(self.board)}
        base = Path("/tmp") / ("fleet-board-%d" % os.getuid())
        base_existed = base.exists()
        domain_id = paths.domain_id_for_root(self.board)
        socket_dir = paths.socket_dir(domain_id, base=base)
        self.addCleanup(self.cleanup_sockets, base, base_existed, socket_dir)
        result = subprocess.run([sys.executable, "-m", "supervisor.cli", "service", "install", "--platform", "linux",
                                 "--output-dir", str(self.work / "rendered")],
                                env=env, cwd=str(self.board), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = Path(json.loads(result.stdout)["rendered"]).read_text(encoding="utf-8")
        self.assertIn("FLEET_BOARD_SOCKET_DIR=" + str(base), rendered.replace('"', ""))
        self.assertIn(str(self.home / ".fleet-board" / "runs"), rendered)
        store = Store.open(paths.board_domain(self.board, self.home / ".fleet-board" / "runs" / "supervisor"))
        try:
            store.record_command({"id": "e2e-start", "actor": "fixture-human", "command": "start", "payload": {},
                                  "expected_revision": store.snapshot()["domain"]["revision"]})
        finally:
            store.close()
        launcher = self.home / ".fleet-board" / "supervisor-registry" / "bin" / "boot"
        service_env = {"HOME": str(self.home), "PATH": os.environ["PATH"]}
        child = subprocess.Popen(["bash", str(launcher), "--domain", str(self.board)], env=service_env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, child)
        status = None
        deadline = time.time() + 30
        while time.time() < deadline and status is None:
            if child.poll() is not None:
                out, err = child.communicate()
                if "Operation not permitted" in err:
                    self.skipTest("sandbox denies local Unix socket service")
                self.fail("boot entry exited early (%s): %s %s" % (child.returncode, out, err))
            probe = subprocess.run([sys.executable, "-m", "supervisor.cli", "status"], env=env, cwd=str(self.board),
                                   capture_output=True, text=True, timeout=30)
            if probe.returncode == 0:
                status = json.loads(probe.stdout)
            else:
                time.sleep(0.2)
        self.assertIsNotNone(status, "a plain client never reached the rendered service")
        self.assertEqual(status["desired_mode"], "running")
        self.assertEqual(status["boot_registration"], "pending_activation")
        self.assertEqual(status["runtime"]["protocol"], boot.PROTOCOL_VERSION,
                         "status must report the live service's protocol so an upgrade can compare it")
        stop = subprocess.run([sys.executable, "-m", "supervisor.cli", "stop", "--mode", "drain"], env=env,
                              cwd=str(self.board), capture_output=True, text=True, timeout=30)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        time.sleep(1)
        self.assertIsNone(child.poll(), "the resident boot entry stays alive after a Stop (it never relaunches)")
        child.terminate()
        self.assertEqual(child.wait(timeout=30), 0, "SIGTERM must end the resident boot entry cleanly")
        log = self.home / ".fleet-board" / "runs" / "supervisor-service.log"
        self.assertTrue(log.exists(), "service stderr must go to a real log file")
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)

    @staticmethod
    def reap(child):
        if child.poll() is None:
            child.kill()
        try:
            child.communicate(timeout=5)
        except Exception:  # noqa: BLE001
            pass

    @staticmethod
    def cleanup_sockets(base, base_existed, socket_dir):
        shutil.rmtree(str(socket_dir), True)
        if not base_existed:
            try:
                base.rmdir()
            except OSError:
                pass


class WatchCase(BootCase):
    """The resident boot watcher, driven by a fake clock and a scripted world."""

    def setUp(self):
        super().setUp()
        self.install()
        self.owner = False
        self.log = []
        self.now = [1000.0]
        self.sleeps = []
        self.live = None

    def world_launch(self, root, launch_env):
        self.log.append("launch")
        self.owner = True
        return FakeChild()

    def world_activate(self, root, launch_env):
        self.log.append("start")

    def watch(self, ticks, script=None, interval=10.0, env=None, boot_id="boot-1"):
        tick = [0]

        def sleep(seconds):
            tick[0] += 1
            self.sleeps.append(seconds)
            self.now[0] += seconds
            if script:
                script(tick[0])

        return boot.watch(self.board, env=env or self.env(), boot_id=boot_id, interval=interval, sleep=sleep,
                          clock=lambda: self.now[0], launch=self.world_launch, activate=self.world_activate,
                          owner_alive=lambda root, entry: self.owner, live_status=lambda root, entry: self.live,
                          max_ticks=ticks)


class ResidentWatcher(WatchCase):
    def test_stopped_domain_stays_resident_and_launches_nothing(self):
        result = self.watch(5)
        self.assertIsNone(result, "the watcher must stay alive while the domain is stopped")
        self.assertEqual(self.log, [])
        self.assertEqual(self.sleeps, [10.0] * 4, "the interval is injectable and the clock is fake")

    def test_explicit_start_after_suppression_is_launched_by_the_watcher(self):
        self.set_mode("paused")
        self.set_yaml(YAML_FALSE)
        launched_at = []

        def script(tick):
            if tick == 2:
                self.store_command("resume")  # the explicit Start of this boot
            launched_at.append((tick, list(self.log)))

        self.watch(5, script)
        self.assertEqual(launched_at[0][1], [], "start_on_boot false: boot activation stays suppressed")
        self.assertEqual(launched_at[1][1], [])
        self.assertEqual(self.log, ["launch", "start"], "an explicit Start with no live owner is relaunched")

    def test_owner_crash_is_relaunched_through_the_launcher(self):
        self.set_mode("running")

        def script(tick):
            if tick == 2:
                self.owner = False  # the served child died

        self.watch(5, script)
        self.assertEqual(self.log, ["launch", "start", "launch", "start"])

    def test_stop_is_never_overridden_by_keep_alive(self):
        self.set_mode("running")

        def script(tick):
            if tick == 1:
                self.store_command("stop")
                self.owner = False

        self.watch(6, script)
        self.assertEqual(self.log, ["launch", "start"], "after Stop the dead owner must not be relaunched")

    def test_another_owner_serving_keeps_the_watcher_resident(self):
        self.set_mode("running")
        self.owner = True

        def script(tick):
            if tick == 2:
                self.owner = False

        result = self.watch(5, script)
        self.assertIsNone(result, "a healthy foreign owner must not end the watcher")
        self.assertEqual(self.log, ["launch", "start"], "launched only once the foreign owner was gone")

    def test_recoverable_wait_keeps_watching_and_recovers(self):
        self.set_mode("running")
        self.set_yaml("board: [\n")

        def script(tick):
            if tick == 2:
                self.set_yaml(YAML_TRUE)

        result = self.watch(5, script)
        self.assertIsNone(result)
        self.assertEqual(self.log, ["launch", "start"])

    def test_not_registered_ends_with_success_so_the_manager_does_not_loop(self):
        shutil.rmtree(str(self.registry() / "domains"))
        self.assertEqual(self.watch(5), 0)
        self.assertEqual(self.log, [])

    def test_a_changed_runtime_asks_the_manager_for_a_restart(self):
        record_path = self.registry() / "registry.json"

        def script(tick):
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["version"] = "9.9.9"
            record_path.write_text(json.dumps(record), encoding="utf-8")

        self.assertEqual(self.watch(5, script), boot.EXIT_WAITING,
                         "after an upgrade or rollback the resident process must restart to load the new runtime")

    def test_interval_defaults_and_env_override(self):
        self.assertEqual(boot.watch_interval({}), 15.0)
        self.assertEqual(boot.watch_interval({"FLEET_BOARD_BOOT_INTERVAL": "0.25"}), 0.25)
        self.assertEqual(boot.watch_interval({"FLEET_BOARD_BOOT_INTERVAL": "junk"}), 15.0)


class ResidentProcess(BootCase):
    """A real boot entry process: a crash is relaunched, a Stop is not."""

    def served_pids(self):
        done = subprocess.run(["pgrep", "-f", "supervisor.cli serve --domain " + str(self.board)],
                              capture_output=True, text=True)
        return sorted(int(p) for p in done.stdout.split() if p.isdigit())

    def wait_for(self, check, seconds=40):
        deadline = time.time() + seconds
        while time.time() < deadline:
            value = check()
            if value:
                return value
            time.sleep(0.15)
        return check()

    def test_crash_of_the_served_child_is_relaunched_and_stop_is_not(self):
        launcher = self.install()["launcher"]
        self.set_yaml(YAML_FALSE)
        self.set_mode("paused")
        env = self.env(FLEET_BOARD_BOOT_INTERVAL="0.3")
        watcher = subprocess.Popen(["bash", launcher, "--domain", str(self.board)], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(EndToEnd.reap, watcher)
        self.addCleanup(lambda: [os.kill(p, 9) for p in self.served_pids()])
        time.sleep(2)
        self.assertEqual(self.served_pids(), [], "start_on_boot false: nothing is launched before an explicit Start")
        self.assertIsNone(watcher.poll(), "the entry stays resident while suppressed")
        self.store_command("resume")
        first = self.wait_for(self.served_pids)
        if not first:
            watcher.kill()
            _out, err = watcher.communicate()
            if "Operation not permitted" in err:
                self.skipTest("sandbox denies local Unix socket service")
            self.fail("the watcher never launched the explicitly started domain: " + err)
        os.kill(first[0], 9)
        second = self.wait_for(lambda: [p for p in self.served_pids() if p != first[0]])
        self.assertTrue(second, "the crashed service was not relaunched by the resident watcher")
        status = self.wait_for(lambda: self.status_or_none(env))
        self.assertEqual(status["desired_mode"], "running")
        stop = self.cli("stop", "--mode", "drain", env=env)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertEqual(self.wait_for(lambda: not self.served_pids()), True)
        time.sleep(2)
        self.assertEqual(self.served_pids(), [], "a Stop must never be undone by keep-alive")
        self.assertIsNone(watcher.poll())

    def status_or_none(self, env):
        done = self.cli("status", env=env)
        return json.loads(done.stdout) if done.returncode == 0 else None


class UpgradeCompatibility(BootCase):
    def setUp(self):
        super().setUp()
        self.install()
        self.set_mode("running")
        self.db = self.logs / "supervisor" / paths.domain_id_for_root(self.board) / "store.sqlite3"

    def sql(self, statement, *args):
        connection = sqlite3.connect(str(self.db))
        try:
            rows = connection.execute(statement, args).fetchall()
            connection.commit()
            return rows
        finally:
            connection.close()

    def assert_refused(self, reason, **kw):
        before = self.sql("SELECT desired_mode, (SELECT COUNT(*) FROM events) FROM domain")
        outcome, calls = self.boot_once("boot-2", **kw)
        self.assertEqual(calls, [], "nothing may launch on %s" % reason)
        self.assertEqual(outcome["action"], "waiting")
        self.assertEqual(outcome["status"]["reason"], reason)
        self.assertIn("rollback", outcome["status"]["message"])
        self.assertEqual(self.sql("SELECT desired_mode, (SELECT COUNT(*) FROM events) FROM domain"), before,
                         "state must never be wiped or rewritten")
        state = boot.registration_state(self.board, self.env())
        self.assertEqual(state["last_error"]["code"], reason, "the refusal must be visible in status")

    def test_store_schema_newer_than_this_runtime_is_refused(self):
        self.sql("PRAGMA user_version=2")
        self.assert_refused("incompatible_store")
        self.assertEqual(self.sql("PRAGMA user_version"), [(2,)])

    def test_active_attempt_with_unsupported_runner_protocol_event_is_refused(self):
        self.sql("INSERT INTO attempts VALUES('a1','j1','n1','claude','running','{}')")
        self.sql("INSERT INTO events(timestamp,type,payload) VALUES(1,'runner_version','{\"runner_id\":\"a1\",\"protocol\":99}')")
        self.assert_refused("incompatible_runner")

    def test_active_attempt_with_unsupported_recorded_protocol_in_its_data_is_refused(self):
        self.sql("INSERT INTO attempts VALUES('a1','j1','n1','claude','launching',?)", json.dumps({"runner_protocol": 99}))
        self.assert_refused("incompatible_runner")

    def test_supported_or_finished_attempts_do_not_block(self):
        self.sql("INSERT INTO attempts VALUES('a1','j1','n1','claude','running','{}')")
        self.sql("INSERT INTO events(timestamp,type,payload) VALUES(1,'runner_version','{\"runner_id\":\"a1\",\"protocol\":%d}')" % boot.RUNNER_PROTOCOL)
        self.sql("INSERT INTO attempts VALUES('a2','j2','n2','claude','completed',?)", json.dumps({"runner_protocol": 99}))
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(outcome["action"], "restored")
        self.assertEqual(calls, ["launch", "start"])

    def test_live_service_with_a_different_protocol_is_refused(self):
        calls = []
        outcome = boot.boot_domain(self.board, env=self.env(), boot_id="boot-2", launch=lambda *a: calls.append("launch"),
                                   activate=lambda *a: calls.append("start"),
                                   live_status=lambda root, entry: {"runtime": {"protocol": boot.PROTOCOL_VERSION + 1}})
        self.assertEqual(calls, [])
        self.assertEqual(outcome["status"]["reason"], "incompatible_protocol")
        self.assertIn("rollback", outcome["status"]["message"])

    def test_install_refuses_a_store_this_runtime_cannot_read_and_changes_nothing(self):
        current = (self.registry() / "current").read_text(encoding="utf-8")
        self.sql("PRAGMA user_version=2")
        done = self.cli("service", "install", "--platform", "linux", "--output-dir", str(self.work / "rendered"))
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("rollback", done.stderr)
        self.assertEqual((self.registry() / "current").read_text(encoding="utf-8"), current)
        self.assertEqual(self.sql("PRAGMA user_version"), [(2,)])

    def test_install_refuses_a_live_protocol_mismatch_only_with_active_attempts(self):
        def live(running):
            return lambda root, entry: {"runtime": {"protocol": boot.PROTOCOL_VERSION + 1}, "queue": {"running": running}}
        kw = dict(env=self.env(), platform="linux", output_dir=self.work / "rendered", install_dir=self.work / "installed")
        with self.assertRaises(Exception) as caught:
            boot.install(self.board, live_status=live(2), **kw)
        self.assertIn("rollback", str(caught.exception))
        result = boot.install(self.board, live_status=live(0), **kw)
        self.assertTrue(result["warnings"], "an idle mismatched service is warned about, not refused")

    def test_upgrade_backs_up_the_store_privately_and_rollback_restores_runtime_not_store(self):
        record_path = self.registry() / "registry.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["version"] = "0.19.1"
        record_path.write_text(json.dumps(record), encoding="utf-8")
        events_then = self.sql("SELECT COUNT(*) FROM events")[0][0]
        result = self.install()
        backup = Path(result["backup"]) / "store.sqlite3"
        self.assertTrue(backup.exists(), "the store must be backed up before an upgrade")
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(backup.parent.stat().st_mode), 0o700)
        copy = sqlite3.connect(str(backup))
        try:
            self.assertEqual(copy.execute("SELECT COUNT(*) FROM events").fetchone()[0], events_then)
            self.assertEqual(copy.execute("SELECT desired_mode FROM domain").fetchone()[0], "running")
        finally:
            copy.close()
        self.store_command("pause")
        self.service("rollback")
        self.assertEqual(self.store_state()["mode"], "paused", "rollback leaves the store alone unless asked")

    def test_rollback_restores_the_store_only_when_asked_and_only_when_not_served(self):
        record_path = self.registry() / "registry.json"
        record = json.loads(record_path.read_text(encoding="utf-8"))
        record["version"] = "0.19.1"
        record_path.write_text(json.dumps(record), encoding="utf-8")
        self.install()
        events_then = self.sql("SELECT COUNT(*) FROM events")[0][0]
        self.store_command("pause")
        lock_dir = self.db.parent
        import fcntl
        fd = os.open(str(lock_dir / "service.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            refused = self.cli("service", "rollback", "--restore-store")
            self.assertNotEqual(refused.returncode, 0, "a served store must not be replaced underneath the service")
            self.assertEqual(self.sql("SELECT desired_mode FROM domain"), [("paused",)])
        finally:
            os.close(fd)
        done = self.service("rollback", "--restore-store")
        self.assertTrue(done["store_restored"])
        self.assertEqual(self.sql("SELECT desired_mode, (SELECT COUNT(*) FROM events) FROM domain"),
                         [("running", events_then)])
        saved = list(Path(done["backup"]).glob("store-before-restore*.sqlite3"))
        self.assertEqual(len(saved), 1, "the replaced store is kept, not discarded")


class ReviewMinors(BootCase):
    def test_systemd_exec_start_escapes_dollar_percent_and_quote_exactly(self):
        weird = self.work / 'we$ir%d "x"'
        weird.mkdir()
        subprocess.run(["git", "init", "-q", str(weird)], check=True)
        (weird / ".fleet-board.yml").write_text(YAML_TRUE, encoding="utf-8")
        env = self.env(FLEET_BOARD_DOMAIN=str(weird))
        result = self.install(env=env)
        text = Path(result["rendered"]).read_text(encoding="utf-8")
        expected = '"' + str(self.work) + '/we$$ir%%d \\"x\\""'
        self.assertIn(expected, text)
        self.assertIn('"/bin/bash" "%s"' % (self.registry() / "bin" / "boot"), text)

    def test_launcher_exits_75_when_the_recorded_python_is_missing(self):
        result = self.install()
        (self.registry() / "current").write_text(str(self.work / "gone" / "python3") + "\n" + str(SCRIPTS) + "\n", encoding="utf-8")
        done = subprocess.run(["bash", result["launcher"], "--domain", str(self.board)], env=self.env(),
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, boot.EXIT_WAITING, "the documented retry code")
        status = json.loads((self.registry() / "runtime-status.json").read_text(encoding="utf-8"))
        self.assertEqual(status["reason"], "missing_executable")

    def test_uninstall_without_the_privileged_step_is_pending_not_missing(self):
        self.install("--kind", "boot", platform="darwin")
        result = self.service("uninstall", "--platform", "darwin")
        self.assertFalse(result["removed"], "the LaunchDaemon still exists until an administrator removes it")
        self.assertTrue(result["pending"])
        self.assertTrue(result["privileged_commands"])
        self.assertEqual(boot.registration_state(self.board, self.env())["boot_registration"], "uninstall_pending")
        self.assertEqual(self.service("status")["boot_registration"], "uninstall_pending")
        # The watcher must not loop on a unit that is being removed.
        outcome = boot.boot_domain(self.board, env=self.env(), boot_id="b", launch=lambda *a: self.fail("launched"))
        self.assertEqual(outcome["status"]["reason"], "uninstall_pending")
        self.assertEqual(boot.watch(self.board, env=self.env(), boot_id="b", sleep=lambda s: None, max_ticks=3), 0)
        # Once the unit is really gone, status settles to missing.
        (self.fake_log / "launchctl.rc").write_text("113\n", encoding="utf-8")
        self.assertEqual(self.service("status")["boot_registration"], "missing")

    def test_linux_uninstall_without_apply_keeps_the_entry_until_the_unit_is_gone(self):
        self.install("--apply")
        pending = self.service("uninstall", "--platform", "linux", "--install-dir", str(self.work / "installed"))
        self.assertTrue(pending["pending"])
        self.assertEqual(self.service("status")["boot_registration"], "uninstall_pending")
        done = self.service("uninstall", "--platform", "linux", "--apply", "--install-dir", str(self.work / "installed"))
        self.assertTrue(done["removed"])
        self.assertEqual(self.service("status")["boot_registration"], "missing")

    def test_started_work_is_truthful(self):
        self.set_mode("running")
        agent = self.install("--kind", "login", "--apply", platform="darwin")
        self.assertTrue(agent["started_work"], "bootstrapping a RunAtLoad agent for a running domain starts work")
        self.assertTrue(agent["will_start_work_on_load"])
        linux = self.install("--apply")
        self.assertFalse(linux["started_work"], "systemctl enable does not start the unit")
        planned = self.install("--kind", "boot", platform="darwin")
        self.assertFalse(planned["started_work"])
        self.assertTrue(planned["will_start_work_on_load"], "the printed sudo bootstrap would start it")
        self.set_yaml(YAML_FALSE)
        self.assertFalse(self.install("--kind", "login", "--apply", platform="darwin")["started_work"])

    def test_started_work_is_false_for_a_stopped_domain(self):
        agent = self.install("--kind", "login", "--apply", platform="darwin")
        self.assertFalse(agent["started_work"])
        self.assertFalse(agent["will_start_work_on_load"])

    def test_registration_from_a_linked_worktree_is_found_by_status(self):
        from supervisor.service import Service
        subprocess.run(["git", "-C", str(self.board), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                        "--allow-empty", "-m", "init"], check=True)
        linked = self.work / "linked tree"
        subprocess.run(["git", "-C", str(self.board), "worktree", "add", "-q", "--detach", str(linked)], check=True)
        (linked / ".fleet-board.yml").write_text(YAML_TRUE, encoding="utf-8")
        env = self.env(FLEET_BOARD_DOMAIN=str(linked))
        self.install(env=env)
        domain = paths.board_domain(linked, self.logs / "supervisor")
        with mock.patch.dict(os.environ, {"HOME": str(self.home), "FLEET_BOARD_LOG_DIR": str(self.logs),
                                          "FLEET_BOARD_SOCKET_DIR": str(self.sockets)}):
            service = Service.open(domain, board_repo="acme/toy", execution_enabled=False)
            try:
                status = service.get_status()
            finally:
                service.close()
        self.assertEqual(status["boot_registration"], "pending_activation")
        self.assertNotEqual(boot.domain_key(linked), boot.domain_key(self.board), "two worktrees are two registrations")

    def test_a_malformed_registry_entry_does_not_break_status(self):
        self.install()
        entry_path = next((self.registry() / "domains").glob("*.json"))
        entry_path.write_text(json.dumps({"root": str(self.board)}), encoding="utf-8")
        status = self.service("status")
        self.assertEqual(status["boot_registration"], "missing")
        self.assertEqual(status["last_error"]["code"], "registry_entry_invalid")
        state = boot.registration_state(self.board, self.env())
        self.assertEqual(state["last_error"]["code"], "registry_entry_invalid")
        outcome, calls = self.boot_once("boot-2")
        self.assertEqual(calls, [])
        self.assertEqual(outcome["status"]["reason"], "registry_entry_invalid")

    def test_rendered_directory_is_private_whatever_the_umask(self):
        old = os.umask(0o022)
        try:
            result = boot.install(self.board, env=self.env(), platform="linux")
        finally:
            os.umask(old)
        rendered = Path(result["rendered"]).parent
        self.assertEqual(rendered, self.registry() / "rendered")
        self.assertEqual(stat.S_IMODE(rendered.stat().st_mode), 0o700)

    def test_boot_id_comes_from_the_host_not_from_an_environment_hook(self):
        real = boot.current_boot_id({})
        self.assertEqual(boot.current_boot_id({"FLEET_BOARD_BOOT_ID": "stale-export"}), real)

    def test_an_over_long_socket_base_raises_unsafe_socket_dir(self):
        from supervisor import errors
        domain_id = paths.domain_id_for_root(self.board)
        with self.assertRaises(errors.UnsafeSocketDir):
            paths.socket_dir(domain_id, base=Path("/tmp") / ("x" * 100))
        with self.assertRaises(errors.UnsafeSocketDir):
            boot.install(self.board, env=self.env(FLEET_BOARD_SOCKET_DIR="/tmp/" + "y" * 100), platform="linux",
                         output_dir=self.work / "rendered")

    def test_a_start_failure_after_launch_does_not_orphan_the_child(self):
        self.install()
        self.set_mode("running")
        child = FakeChild()

        def activate(root, launch_env):
            raise RuntimeError("start refused")

        outcome = boot.boot_domain(self.board, env=self.env(), boot_id="boot-2", launch=lambda *a: child, activate=activate)
        self.assertEqual(outcome["status"]["reason"], "service_launch_failed")
        self.assertTrue(child.terminated, "the launched child must be terminated")
        self.assertTrue(child.reaped, "and reaped")


class CliSocketTrust(BootCase):
    def serve_stub(self, base):
        import socket as socketlib
        domain_id = paths.domain_id_for_root(self.board)
        directory = paths.socket_dir(domain_id, base=base)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = directory / "c.sock"
        server = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
        try:
            server.bind(str(path))
        except PermissionError:
            self.skipTest("sandbox denies local Unix socket service")
        server.listen(4)
        self.addCleanup(server.close)

        def run():
            while True:
                try:
                    client, _ = server.accept()
                except OSError:
                    return
                client.recv(65536)
                client.sendall(json.dumps({"ok": True, "result": {"revision": 1, "stub": True}}).encode())
                client.close()
        import threading
        threading.Thread(target=run, daemon=True).start()

    def test_cli_refuses_a_socket_under_an_unsafe_base_and_trusts_a_private_one(self):
        base = self.work / "planted"
        base.mkdir(mode=0o700)
        self.serve_stub(base)
        env = self.env(FLEET_BOARD_SOCKET_DIR=str(base))
        os.chmod(str(base), 0o755)
        refused = self.cli("status", env=env)
        self.assertNotEqual(refused.returncode, 0)
        self.assertNotIn("stub", refused.stdout, "a socket under a group/other-accessible base must not be trusted")
        os.chmod(str(base), 0o700)
        trusted = self.cli("status", env=env)
        self.assertEqual(trusted.returncode, 0, trusted.stderr)
        self.assertIn("stub", trusted.stdout)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=1)
