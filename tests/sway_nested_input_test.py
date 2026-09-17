#!/usr/bin/env python3
"""Exercise the helper against a private fake Sway IPC server, never live Sway."""

import json
import os
from pathlib import Path
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts/xmonad-wayland-sway-input.py"
HEADER = struct.Struct("=6sII")


def receive(conn):
    def exact(size):
        out = bytearray()
        while len(out) < size:
            chunk = conn.recv(size - len(out))
            if not chunk:
                raise EOFError
            out.extend(chunk)
        return bytes(out)
    magic, size, kind = HEADER.unpack(exact(HEADER.size))
    if magic != b"i3-ipc":
        raise ValueError("wrong magic")
    return kind, exact(size).decode()


class FakeSway:
    def __init__(self, path, pid, focused=True, mode="default"):
        self.path, self.pid = str(path), pid
        self.mode = mode
        self.focused = focused
        self.present = True
        self.app_id = "river"
        self.commands = []
        self.modes = {"default", "resize"}
        self.escapes = {}
        self.clients = []
        self.subscribers = []
        self.lock = threading.RLock()
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.running = True
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while self.running:
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.clients.append(conn)
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def send(self, conn, kind, obj):
        payload = json.dumps(obj).encode()
        conn.sendall(HEADER.pack(b"i3-ipc", len(payload), kind) + payload)

    def emit(self, kind, obj):
        with self.lock:
            for conn in self.subscribers[:]:
                try:
                    self.send(conn, 0x80000000 | kind, obj)
                except OSError:
                    self.subscribers.remove(conn)

    def node(self):
        return {"id": 41, "pid": self.pid, "app_id": self.app_id,
                "focused": self.focused, "nodes": [], "floating_nodes": [],
                "name": "PRIVATE TITLE MUST NOT APPEAR IN HELPER LOG"}

    def serve(self, conn):
        try:
            while self.running:
                kind, payload = receive(conn)
                with self.lock:
                    if kind == 2:
                        self.assert_events = json.loads(payload)
                        self.send(conn, kind, {"success": True})
                        self.subscribers.append(conn)
                    elif kind == 4:
                        self.send(conn, kind, {"id": 1, "type": "root", "focused": False,
                                  "nodes": [self.node()] if self.present else [],
                                  "floating_nodes": []})
                    elif kind == 12:
                        self.send(conn, kind, {"name": self.mode})
                    elif kind == 8:
                        self.send(conn, kind, sorted(self.modes))
                    elif kind == 0:
                        self.commands.append(payload)
                        words = shlex.split(payload)
                        if words[0] != "mode":
                            self.send(conn, kind, [{"success": False, "error": "unsupported"}])
                            continue
                        name = words[1]
                        if len(words) > 2:
                            if words[2:] != ["bindsym", "Ctrl+Alt+Escape", "mode", "default"]:
                                self.send(conn, kind, [{"success": False, "error": "wrong escape"}])
                                continue
                            self.modes.add(name)
                            self.escapes[name] = True
                        else:
                            # Catch entering a mode before an escape is installed.
                            if name not in self.modes:
                                self.send(conn, kind, [{"success": False, "error": "unknown mode"}])
                                continue
                            self.mode = name
                            self.emit(2, {"change": name, "pango_markup": False})
                        self.send(conn, kind, [{"success": True}])
                    else:
                        raise AssertionError(f"unexpected IPC type {kind}")
        except (EOFError, OSError):
            pass

    def focus(self, focused):
        with self.lock:
            self.focused = focused
            self.emit(3, {"change": "focus", "container": self.node()})

    def change_mode(self, mode):
        with self.lock:
            self.mode = mode
            self.emit(2, {"change": mode, "pango_markup": False})

    def close_window(self):
        with self.lock:
            self.present = False
            self.emit(3, {"change": "close", "container": self.node()})

    def close(self):
        self.running = False
        self.listener.close()
        for conn in self.clients:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
        self.thread.join(timeout=1)


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.is_file(), "nested input helper is not implemented")
        self.temp = tempfile.TemporaryDirectory()
        self.target = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.server = None
        self.helper = None

    def tearDown(self):
        if self.helper is not None:
            if self.helper.poll() is None:
                self.helper.terminate()
            try:
                _, self.output = self.helper.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                self.helper.kill()
                _, self.output = self.helper.communicate(timeout=2)
                self.fail("helper did not finish bounded signal cleanup")
            self.assertNotIn("PRIVATE TITLE", self.output)
        if self.server is not None:
            self.server.close()
        self.target.terminate()
        self.target.wait(timeout=2)
        self.temp.cleanup()

    def start(self, focused=True, mode="default", app_id="river"):
        self.server = FakeSway(Path(self.temp.name) / "ipc.sock", self.target.pid, focused, mode)
        self.server.app_id = app_id
        env = dict(os.environ)
        env.pop("SWAYSOCK", None)
        self.helper = subprocess.Popen(
            [sys.executable, str(HELPER), "--river-pid", str(self.target.pid),
             "--sway-socket", self.server.path], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.wait_for(lambda: self.server.subscribers, "event subscription")

    def wait_for(self, check, label):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if check():
                return
            if self.helper is not None and self.helper.poll() is not None:
                self.fail(f"helper exited before {label}: {self.helper.communicate()[1]}")
            time.sleep(0.01)
        self.fail(f"timed out waiting for {label}")

    def captured(self):
        return self.server.mode not in ("default", "resize")

    def test_focus_restores_and_recaptures_with_escape_installed_first(self):
        self.start(focused=False)
        time.sleep(0.3)
        self.assertEqual(self.server.mode, "default")
        self.server.focus(True)
        self.wait_for(self.captured, "capture")
        self.assertIn(self.server.mode, self.server.escapes)
        self.server.focus(False)
        self.wait_for(lambda: self.server.mode == "default", "unfocus restore")
        self.server.focus(True)
        self.wait_for(self.captured, "recapture")

    def test_escape_requires_focus_leave_and_return(self):
        self.start()
        self.wait_for(self.captured, "capture")
        self.server.change_mode("default")
        time.sleep(0.6)
        self.assertEqual(self.server.mode, "default")
        self.server.focus(False)
        time.sleep(0.3)
        self.server.focus(True)
        self.wait_for(self.captured, "recapture after focus cycle")

    def test_other_modes_are_never_overwritten_or_restored_over(self):
        self.start(mode="resize")
        time.sleep(0.3)
        self.assertEqual(self.server.mode, "resize")
        self.server.focus(False)
        self.server.change_mode("default")
        time.sleep(0.3)
        self.server.focus(True)
        self.wait_for(self.captured, "capture")
        self.server.change_mode("resize")
        self.server.focus(False)
        time.sleep(0.3)
        self.helper.terminate()
        self.helper.wait(timeout=3)
        self.assertEqual(self.server.mode, "resize")

    def test_fast_focus_cycle_after_escape_is_not_lost(self):
        self.start()
        self.wait_for(self.captured, "capture")
        self.server.change_mode("default")
        time.sleep(0.3)
        self.assertEqual(self.server.mode, "default")
        # Both events are queued before GET_TREE can see the intermediate state.
        with self.server.lock:
            self.server.focus(False)
            self.server.focus(True)
        self.wait_for(self.captured, "capture after rapid focus cycle")

    def test_window_close_restores_and_exits(self):
        self.start()
        self.wait_for(self.captured, "capture")
        self.server.close_window()
        self.helper.wait(timeout=3)
        self.assertEqual(self.helper.returncode, 0)
        self.assertEqual(self.server.mode, "default")

    def test_term_and_interrupt_restore(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                self.start()
                self.wait_for(self.captured, "capture")
                self.helper.send_signal(sig)
                self.helper.wait(timeout=3)
                self.assertEqual(self.server.mode, "default")
                self.helper.communicate(timeout=1)
                self.server.close()
                self.server = None
                os.unlink(Path(self.temp.name) / "ipc.sock")

    def test_pid_exit_without_event_restores(self):
        self.start()
        self.wait_for(self.captured, "capture")
        self.target.terminate()
        self.target.wait(timeout=2)
        self.helper.wait(timeout=3)
        self.assertEqual(self.server.mode, "default")

    def test_wrong_application_never_captures(self):
        self.start(app_id="some-other-app")
        time.sleep(0.4)
        self.assertEqual(self.server.commands, [])

    def test_shutdown_event_exits_without_hanging(self):
        self.start()
        self.wait_for(self.captured, "capture")
        self.server.emit(6, {"change": "exit"})
        self.helper.wait(timeout=3)
        self.assertEqual(self.server.mode, "default")

    def test_no_socket_is_a_useful_fallback(self):
        env = dict(os.environ)
        env.pop("SWAYSOCK", None)
        result = subprocess.run([sys.executable, str(HELPER), "--river-pid", str(self.target.pid)],
                                env=env, text=True, capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SWAYSOCK", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
