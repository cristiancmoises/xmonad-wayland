#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Pass Sway shortcuts to one focused nested River; Ctrl+Alt+Escape releases.

Only runtime IPC state is changed. No bindings in Sway's default mode or
configuration files are edited. Run with an absolute Python path when packaged.
"""

import argparse
import json
import os
import secrets
import select
import signal
import socket
import struct
import sys


HEADER = struct.Struct("=6sII")
MAX_MESSAGE = 16 * 1024 * 1024
POLL_SECONDS = 0.25


def log(message):
    print(f"nested-input: {message}", file=sys.stderr, flush=True)


class IPCError(Exception):
    pass


class IPC:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(1)
        try:
            self.sock.connect(path)
        except BaseException:
            self.sock.close()
            raise

    def close(self):
        self.sock.close()

    def receive(self):
        def exact(size):
            data = bytearray()
            while len(data) < size:
                chunk = self.sock.recv(size - len(data))
                if not chunk:
                    raise IPCError("Sway IPC disconnected")
                data.extend(chunk)
            return bytes(data)

        magic, size, kind = HEADER.unpack(exact(HEADER.size))
        if magic != b"i3-ipc" or size > MAX_MESSAGE:
            raise IPCError("invalid Sway IPC frame")
        try:
            payload = json.loads(exact(size))
        except (ValueError, UnicodeError) as error:
            raise IPCError("invalid Sway IPC JSON") from error
        return kind, payload

    def request(self, kind, payload=""):
        data = payload.encode()
        self.sock.sendall(HEADER.pack(b"i3-ipc", len(data), kind) + data)
        reply_kind, reply = self.receive()
        if reply_kind != kind:
            raise IPCError("unexpected Sway IPC reply")
        return reply

    def command(self, command):
        result = self.request(0, command)
        if not isinstance(result, list) or not result or not all(
                isinstance(item, dict) and item.get("success") is True for item in result):
            raise IPCError("Sway rejected the temporary input mode command")

    def mode(self):
        result = self.request(12)
        if not isinstance(result, dict) or not isinstance(result.get("name"), str):
            raise IPCError("Sway did not report its current binding mode")
        return result["name"]


def process_exists(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def river_windows(tree, pid):
    """Read only identity and focus; never record other applications' titles."""
    if not isinstance(tree, dict):
        raise IPCError("Sway did not report a tree object")
    pending = [tree]
    found = []
    while pending:
        node = pending.pop()
        if node.get("app_id") == "river" and node.get("pid") == pid:
            found.append(node)
        pending.extend(node.get("nodes", []))
        pending.extend(node.get("floating_nodes", []))
    return found


class NestedInput:
    def __init__(self, ipc, pid):
        self.ipc = ipc
        self.pid = pid
        self.name = f"river-nested-{pid}-{os.getpid()}-{secrets.token_hex(4)}"
        self.defined = False
        self.owned = False
        self.blocked = False
        self.seen = False
        self.stopping = False

    def stop(self, _signal=None, _frame=None):
        self.stopping = True

    def restore(self):
        # A user selecting a different mode always wins, including at shutdown.
        if self.defined and self.ipc.mode() == self.name:
            self.ipc.command('mode "default"')
            log("restored Sway shortcuts")
        self.owned = False

    def event(self, kind, event):
        # Preserve a focus departure even when focus has already returned by
        # the time GET_TREE replies. The fresh tree still gates all captures.
        if kind == 0x80000003 and event.get("change") == "focus":
            node = event.get("container", {})
            if (node.get("app_id") != "river" or node.get("pid") != self.pid
                    or node.get("focused") is not True):
                self.blocked = False

    def reconcile(self):
        if self.stopping or not process_exists(self.pid):
            return False
        windows = river_windows(self.ipc.request(4), self.pid)
        if self.seen and not windows:
            return False
        self.seen = self.seen or bool(windows)
        focused = any(node.get("focused") is True for node in windows)
        current = self.ipc.mode()

        if not focused:
            self.blocked = False
            if current == self.name:
                self.restore()
            self.owned = False
            return True

        if self.owned and current != self.name:
            self.owned = False
            self.blocked = True
            log("released; leave and return focus to River to capture again")
        if current not in ("default", self.name):
            self.blocked = True
        if current != "default" or self.blocked or self.stopping:
            return True

        if not self.defined:
            self.ipc.command(
                f'mode "{self.name}" bindsym Ctrl+Alt+Escape mode "default"')
            self.defined = True

        # Recheck after defining the escape, because IPC replies are not an
        # atomic focus/mode transaction. Focus events and polling release a
        # capture promptly if focus changes while a command is in flight.
        windows = river_windows(self.ipc.request(4), self.pid)
        if (self.stopping or not process_exists(self.pid)
                or not any(node.get("focused") is True for node in windows)
                or self.ipc.mode() != "default"):
            return True
        self.owned = True
        self.ipc.command(f'mode "{self.name}"')
        log("River shortcuts active; Ctrl+Alt+Escape returns to Sway")
        return True


def run(pid, path):
    command = events = controller = None
    result = 0
    try:
        command = IPC(path)
        events = IPC(path)
        response = events.request(2, json.dumps(["window", "workspace", "mode", "shutdown"]))
        if not isinstance(response, dict) or response.get("success") is not True:
            raise IPCError("Sway rejected event subscription")
        controller = NestedInput(command, pid)
        signal.signal(signal.SIGTERM, controller.stop)
        signal.signal(signal.SIGINT, controller.stop)
        log(f"watching River PID {pid}; capture requires its focused window")
        while controller.reconcile():
            readable, _, _ = select.select([events.sock], [], [], POLL_SECONDS)
            if readable:
                kind, event = events.receive()
                if kind == 0x80000006:
                    break
                if not isinstance(event, dict):
                    raise IPCError("invalid Sway IPC event")
                controller.event(kind, event)
    except (OSError, IPCError) as error:
        log(f"input capture unavailable: {error}; use the host desktop normally")
        result = 1
    finally:
        if controller is not None:
            try:
                controller.restore()
            except (OSError, IPCError):
                log("could not restore via IPC; Ctrl+Alt+Escape returns to Sway if it is running")
                result = 1
        if events is not None:
            events.close()
        if command is not None:
            command.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--river-pid", type=int, required=True)
    parser.add_argument("--sway-socket", default=os.environ.get("SWAYSOCK"))
    args = parser.parse_args()
    if args.river_pid <= 0:
        parser.error("--river-pid must be positive")
    if not args.sway_socket:
        log("SWAYSOCK is unset; pass --sway-socket to enable nested shortcuts")
        return 1
    return run(args.river_pid, args.sway_socket)


if __name__ == "__main__":
    sys.exit(main())
