#!/usr/bin/env python3
"""Exercise session process boundaries with stub executables, no desktop."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import signal
import socket
import stat
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xmonad session ")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.bin = self.path / "bin with spaces"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        XDG_RUNTIME_DIR=str(self.path), CAPTURE=str(self.path / "args"),
                        RIVER_VERSION="0.4.8")
        for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "SWAYSOCK"):
            self.env.pop(name, None)
        self.script("id", f'#!{shutil.which("sh")}\nprintf "1000\\n"\n')
        self.river = self.script("river", f'#!{sys.executable}\n' + '''
import json, os, sys
if sys.argv[1:] == ["-version"]:
    print(os.environ["RIVER_VERSION"])
else:
    with open(os.environ["CAPTURE"], "w") as out:
        json.dump(sys.argv[1:], out)
    sys.exit(int(os.environ.get("RIVER_EXIT", "0")))
''')
        self.manager = self.script("xmonad-wayland", f'#!{shutil.which("sh")}\nexit 0\n')
        self.env["XMONAD_WAYLAND_RIVER"] = str(self.river)
        self.env["XMONAD_WAYLAND_MANAGER"] = str(self.manager)

    def script(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def run_session(self, *args):
        return subprocess.run(["sh", str(ROOT / "scripts/xmonad-wayland-session"), *args],
                              env=self.env, text=True, capture_output=True, timeout=5)

    def test_check_does_not_start_compositor(self):
        result = self.run_session("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env["CAPTURE"]).exists())

    def test_passes_literal_compositor_arguments(self):
        args = ["-log-level", "debug", "one argument; $(false)"]
        result = self.run_session("--", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(Path(self.env["CAPTURE"]).read_text())
        self.assertEqual(captured[:2], ["-c", 'exec "$XMONAD_WAYLAND_MANAGER"'])
        self.assertEqual(captured[2:], args)

    def test_rejects_missing_runtime_directory(self):
        self.env["XDG_RUNTIME_DIR"] = str(self.path / "missing")
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XDG_RUNTIME_DIR", result.stderr)

    def test_rejects_incompatible_versions(self):
        for version in ["0.3.12", "river-classic 0.4.8", "unrecognized"]:
            with self.subTest(version=version):
                self.env["RIVER_VERSION"] = version
                result = self.run_session()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.env["CAPTURE"]).exists())

    def test_missing_override_fails_instead_of_using_another_binary(self):
        self.env["XMONAD_WAYLAND_RIVER"] = str(self.path / "not found")
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)

    def test_compositor_exit_status_is_preserved(self):
        self.env["RIVER_EXIT"] = "42"
        result = self.run_session()
        self.assertEqual(result.returncode, 42, result.stderr)

    def test_root_refused(self):
        self.script("id", f'#!{shutil.which("sh")}\nprintf "0\\n"\n')
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not root", result.stderr)

    def test_explicit_nested_rejects_absent_wayland_parent(self):
        result = self.run_session("--nested")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wayland", result.stderr)


class NestedSessionTests(unittest.TestCase):
    script = SessionTests.script
    run_session = SessionTests.run_session

    def setUp(self):
        SessionTests.setUp(self)
        self.parent_socket = socket.socket(socket.AF_UNIX)
        self.parent_socket.bind(str(self.path / "parent-wayland"))
        self.addCleanup(self.parent_socket.close)
        self.env.update(WAYLAND_DISPLAY="parent-wayland", DISPLAY=":host",
                        XDG_STATE_HOME=str(self.path / "state"), WAYLAND_DEBUG="client",
                        SWAYSOCK=str(self.path / "not-a-sway-socket"))
        self.script("river", f'#!{sys.executable}\n' + '''
import json, os, signal, subprocess, sys, time
if sys.argv[1:] == ["-version"]:
    print(os.environ["RIVER_VERSION"])
    sys.exit(0)
with open(os.environ["CAPTURE"], "w") as out:
    json.dump(sys.argv[1:], out)
child = subprocess.Popen(["sh", "-c", sys.argv[sys.argv.index("-c") + 1]],
    env=dict(os.environ, WAYLAND_DISPLAY="nested-test", DISPLAY=":nested"),
    start_new_session=True)
with open(os.environ["RECORD_RIVER"], "w") as out:
    json.dump({"pid": os.getpid(), "init_pid": child.pid}, out)
running = True
def stop(sig, frame):
    global running
    running = False
signal.signal(signal.SIGTERM, stop)
try:
    while running:
        time.sleep(.02)
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=4)
''')
        child_source = f'#!{sys.executable}\n' + '''
import json, os, signal, sys, time
name = os.path.basename(sys.argv[0])
if os.environ.get("IGNORE_TERM") == "yes":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
record = dict(pid=os.getpid(), argv=sys.argv, env={key: os.environ.get(key) for key in
    ("XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "WAYLAND_DEBUG",
     "PIPEWIRE_RUNTIME_DIR", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE")})
with open(os.environ["RECORD_" + ("MANAGER" if name == "xmonad-wayland" else "TERMINAL")], "w") as out:
    json.dump(record, out)
if name != "xmonad-wayland" and "TERMINAL_EXIT" in os.environ:
    sys.exit(int(os.environ["TERMINAL_EXIT"]))
if name == "xmonad-wayland" and "MANAGER_EXIT" in os.environ:
    import subprocess
    application = subprocess.Popen([sys.executable, "-c", """
import os, signal, time
if os.environ.get("IGNORE_APP_TERM") == "yes":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["APP_READY"], "w") as out:
    out.write("ready")
time.sleep(60)
"""])
    with open(os.environ["RECORD_APP"], "w") as out:
        json.dump({"pid": application.pid}, out)
    sys.exit(int(os.environ["MANAGER_EXIT"]))
while True:
    time.sleep(.02)
'''
        self.script("xmonad-wayland", child_source)
        self.script("foot", child_source)
        self.env.update(RECORD_MANAGER=str(self.path / "manager.json"),
                        RECORD_TERMINAL=str(self.path / "terminal.json"),
                        RECORD_APP=str(self.path / "application.json"),
                        APP_READY=str(self.path / "application.ready"),
                        RECORD_RIVER=str(self.path / "river.json"))

    def start_nested(self, *args):
        proc = subprocess.Popen(["sh", str(ROOT / "scripts/xmonad-wayland-session"), *args],
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        self.addCleanup(self.stop_nested, proc)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                self.fail("nested launcher exited: " + proc.communicate()[1])
            if all(Path(self.env[name]).exists() for name in ("RECORD_MANAGER", "RECORD_TERMINAL")):
                return proc
            time.sleep(.02)
        self.fail("nested launcher did not start its manager and terminal")

    def stop_nested(self, proc):
        if proc.poll() is None:
            proc.terminate()
        try:
            return proc.communicate(timeout=6)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate(timeout=2)
            self.fail("nested launcher did not clean up within six seconds")

    def test_starts_terminal_on_child_display_and_keeps_logs_private(self):
        proc = self.start_nested("--nested", "--", "-log-level", "debug", "literal; $(false)")
        records = [json.loads(Path(self.env[name]).read_text())
                   for name in ("RECORD_MANAGER", "RECORD_TERMINAL")]
        for record in records:
            env = record["env"]
            self.assertEqual(env["WAYLAND_DISPLAY"], "nested-test")
            self.assertEqual(env["DISPLAY"], ":nested")
            self.assertIsNone(env["SWAYSOCK"])
            self.assertIsNone(env["WAYLAND_DEBUG"])
            self.assertEqual(env["PIPEWIRE_RUNTIME_DIR"], str(self.path))
            self.assertEqual(env["XDG_CURRENT_DESKTOP"], "XMonadWayland")
            self.assertEqual(env["XDG_SESSION_TYPE"], "wayland")
            self.assertNotEqual(env["XDG_RUNTIME_DIR"], str(self.path))
            self.assertEqual(stat.S_IMODE(Path(env["XDG_RUNTIME_DIR"]).stat().st_mode), 0o700)
        args = json.loads(Path(self.env["CAPTURE"]).read_text())
        self.assertEqual(args[-3:], ["-log-level", "debug", "literal; $(false)"])
        stdout, _ = self.stop_nested(proc)
        log_line = next(line for line in stdout.splitlines() if line.startswith("Session diagnostics: "))
        logs = Path(log_line.split(": ", 1)[1])
        self.assertEqual(stat.S_IMODE(logs.stat().st_mode), 0o700)
        for log in logs.glob("*.log"):
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
        self.assertFalse(Path(records[0]["env"]["XDG_RUNTIME_DIR"]).exists())
        for record in records:
            with self.assertRaises(ProcessLookupError):
                os.kill(record["pid"], 0)

    def test_terminal_override_is_one_literal_executable(self):
        self.env["XMONAD_WAYLAND_TERMINAL"] = str(self.script(
            "terminal; $(false)", (self.bin / "foot").read_text()))
        self.start_nested()
        record = json.loads(Path(self.env["RECORD_TERMINAL"]).read_text())
        self.assertEqual(record["argv"], [self.env["XMONAD_WAYLAND_TERMINAL"]])

    def test_missing_terminal_fails_before_compositor(self):
        self.env["XMONAD_WAYLAND_TERMINAL"] = str(self.path / "missing-terminal")
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("terminal", result.stderr.lower())
        self.assertFalse(Path(self.env["CAPTURE"]).exists())

    def test_explicit_nested_requires_wayland_parent(self):
        self.env.pop("WAYLAND_DISPLAY")
        result = self.run_session("--nested")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wayland", result.stderr)

    def test_nested_check_does_not_launch_or_create_logs(self):
        result = self.run_session("--nested", "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env["CAPTURE"]).exists())
        self.assertFalse(Path(self.env["XDG_STATE_HOME"]).exists())

    def test_cleanup_reaps_children_which_ignore_term(self):
        self.env["IGNORE_TERM"] = "yes"
        proc = self.start_nested()
        pids = [json.loads(Path(self.env[name]).read_text())["pid"]
                for name in ("RECORD_MANAGER", "RECORD_TERMINAL")]
        self.stop_nested(proc)
        for pid in pids:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_terminal_startup_failure_stops_empty_session(self):
        self.env["TERMINAL_EXIT"] = "7"
        result = self.start_nested()
        try:
            result.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.fail("terminal startup failure left an empty session running")
        self.assertEqual(result.returncode, 7)
        manager = json.loads(Path(self.env["RECORD_MANAGER"]).read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(manager["pid"], 0)

    def test_manager_startup_failure_preserves_its_status(self):
        self.env["MANAGER_EXIT"] = "19"
        proc = self.start_nested()
        proc.wait(timeout=3)
        self.assertEqual(proc.returncode, 19)
        manager = json.loads(Path(self.env["RECORD_MANAGER"]).read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(manager["pid"], 0)

    def test_closed_terminal_is_reaped_while_manager_keeps_running(self):
        self.env["TERMINAL_EXIT"] = "0"
        proc = self.start_nested()
        terminal = json.loads(Path(self.env["RECORD_TERMINAL"]).read_text())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(terminal["pid"], 0)
            except ProcessLookupError:
                break
            time.sleep(.02)
        else:
            self.fail("closed terminal was not reaped")
        self.assertIsNone(proc.poll())

    def test_clean_manager_exit_preserves_terminal_and_applications(self):
        self.env["MANAGER_EXIT"] = "0"
        proc = self.start_nested()
        time.sleep(.4)
        self.assertIsNone(proc.poll(), "manager Stop must not end the nested session")
        manager = json.loads(Path(self.env["RECORD_MANAGER"]).read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(manager["pid"], 0)
        for name in ("RECORD_TERMINAL", "RECORD_APP"):
            child = json.loads(Path(self.env[name]).read_text())
            os.kill(child["pid"], 0)

    def check_descendant_cleanup(self, force_river=False, terminal_closed=False):
        self.env.update(MANAGER_EXIT="0", IGNORE_APP_TERM="yes")
        if terminal_closed:
            self.env["TERMINAL_EXIT"] = "0"
        proc = self.start_nested()
        deadline = time.monotonic() + 2
        while not Path(self.env["APP_READY"]).exists():
            self.assertLess(time.monotonic(), deadline, "application did not initialize")
            time.sleep(.02)
        application = json.loads(Path(self.env["RECORD_APP"]).read_text())["pid"]
        # Keep fixture teardown safe even when running this regression against
        # old code: a pidfd never signals a different process after PID reuse.
        if hasattr(os, "pidfd_open"):
            fd = os.pidfd_open(application)
            self.addCleanup(os.close, fd)
            def release_application():
                try:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.addCleanup(release_application)
        retired = [json.loads(Path(self.env["RECORD_MANAGER"]).read_text())["pid"]]
        if terminal_closed:
            retired.append(json.loads(Path(self.env["RECORD_TERMINAL"]).read_text())["pid"])
        deadline = time.monotonic() + 2
        while retired:
            for pid in retired[:]:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    retired.remove(pid)
            self.assertLess(time.monotonic(), deadline, "exited child was not reaped")
            time.sleep(.02)
        self.assertIsNone(proc.poll())
        if force_river:
            river = json.loads(Path(self.env["RECORD_RIVER"]).read_text())
            os.kill(river["pid"], signal.SIGKILL)
            proc.wait(timeout=6)
            self.assertEqual(proc.returncode, 137)
        self.stop_nested(proc)
        runtime = json.loads(Path(self.env["RECORD_MANAGER"]).read_text())["env"]["XDG_RUNTIME_DIR"]
        self.assertFalse(Path(runtime).exists())
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                os.kill(application, 0)
            except ProcessLookupError:
                return
            # An orphan may briefly await PID 1's reaper. It is terminated,
            # unlike a running descendant that ignored the cleanup signal.
            if sys.platform.startswith("linux"):
                try:
                    state = Path(f"/proc/{application}/stat").read_text().split(") ", 1)[1][0]
                except FileNotFoundError:
                    return
                if state == "Z":
                    return
            time.sleep(.02)
        self.fail("TERM-ignoring init-group application survived session shutdown")

    def test_term_stops_init_group_descendant_after_manager_exit(self):
        self.check_descendant_cleanup()

    def test_kill_stops_init_group_descendant_after_manager_exit(self):
        self.check_descendant_cleanup(force_river=True)

    def test_term_cleans_init_group_after_terminal_already_exited(self):
        self.check_descendant_cleanup(terminal_closed=True)

    def test_kill_cleans_init_group_after_terminal_already_exited(self):
        self.check_descendant_cleanup(force_river=True, terminal_closed=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
