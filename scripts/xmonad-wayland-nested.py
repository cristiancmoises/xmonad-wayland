#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Own a private nested River, its initial terminal and optional Sway forwarding."""

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class Stop:
    def __init__(self):
        self.signal = 0

    def handle(self, number, _frame):
        self.signal = number

    def install(self):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, self.handle)


class Child:
    """Hold a child unreaped until its PID or owned group has been stopped."""
    def __init__(self, argv, group=True, **kwargs):
        self.group = group
        self.process = subprocess.Popen(argv, start_new_session=group, **kwargs)

    def status(self):
        info = os.waitid(os.P_PID, self.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if info is None:
            return None
        if info.si_code == os.CLD_EXITED:
            return info.si_status
        return 128 + info.si_status

    def send(self, number):
        try:
            if self.group:
                os.killpg(self.process.pid, number)
            else:
                os.kill(self.process.pid, number)
        except ProcessLookupError:
            pass


def stop_children(children, grace=0.35):
    # No poll()/wait() before the last group signal: an unreaped leader keeps
    # its PID/PGID reserved even after a child exits during graceful shutdown.
    for child in children:
        child.send(signal.SIGTERM)
    deadline = time.monotonic() + grace
    while any(child.status() is None for child in children) and time.monotonic() < deadline:
        time.sleep(0.02)
    for child in children:
        child.send(signal.SIGKILL)
    for child in children:
        child.process.wait(timeout=3)


def write_status(path, status):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(status) + "\n")
    temporary.replace(path)


def session_init():
    """River runs this after selecting its child Wayland/Xwayland displays."""
    stop = Stop()
    stop.install()
    parent_pid = os.getppid()
    runtime = Path(os.environ["XMONAD_WAYLAND_NESTED_RUNTIME"])
    logs = Path(os.environ["XMONAD_WAYLAND_NESTED_LOGS"])
    children = []
    result = 0
    (runtime / "init-started").write_text(str(os.getpid()))
    try:
        with (logs / "manager.log").open("ab") as manager_log, (logs / "terminal.log").open("ab") as terminal_log:
            # Keep applications launched by the manager in River's init group.
            # Stopping only the manager must leave those applications running.
            manager = Child([os.environ["XMONAD_WAYLAND_MANAGER"]], group=False,
                            stdin=subprocess.DEVNULL, stdout=manager_log, stderr=manager_log)
            children.append(manager)
            terminal = Child([os.environ["XMONAD_WAYLAND_TERMINAL"]],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=terminal_log)
            children.append(terminal)
            startup_deadline = time.monotonic() + 2
            while not stop.signal and os.getppid() == parent_pid:
                if manager is not None:
                    manager_status = manager.status()
                    if manager_status is not None:
                        if manager_status and time.monotonic() < startup_deadline:
                            result = manager_status
                            break
                        manager.process.wait()
                        children.remove(manager)
                        manager = None
                        print("Manager stopped; River and applications remain running.",
                              file=sys.stderr, flush=True)
                if terminal is not None:
                    terminal_status = terminal.status()
                    if terminal_status is not None:
                        stop_children([terminal])
                        children.remove(terminal)
                        terminal = None
                        if terminal_status and time.monotonic() < startup_deadline:
                            print(f"Initial terminal failed with status {terminal_status}; see terminal.log",
                                  file=sys.stderr, flush=True)
                            result = terminal_status
                            break
                time.sleep(0.05)
    except (OSError, KeyError) as error:
        print(f"Nested startup failed: {error}", file=sys.stderr, flush=True)
        result = 1
    finally:
        # River makes init a group leader. On compositor death, also release
        # applications whose manager has already exited. Never signal a group
        # we do not lead if this internal entry point was invoked incorrectly.
        owns_group = os.getpgrp() == os.getpid()
        group_deadline = time.monotonic() + 0.35
        if owns_group:
            os.killpg(os.getpid(), signal.SIGTERM)
        stop_children(children)
        if owns_group:
            # Applications may outlive an already-reaped manager or terminal.
            # Give that whole group a grace period even when children is empty.
            time.sleep(max(0, group_deadline - time.monotonic()))
        write_status(runtime / "init-finished.json", {"status": result})
        if os.getpgrp() == os.getpid():
            # Separate owned groups have been stopped and reaped. Publish the
            # result before the final signal, which also kills this group
            # leader: remaining applications cannot keep ignoring TERM, and
            # our still-live PID prevents signaling a recycled process group.
            sys.stdout.flush()
            sys.stderr.flush()
            os.killpg(os.getpid(), signal.SIGKILL)
    return result


def executable(value, description):
    path = shutil.which(value)
    if path is None:
        raise ValueError(f"{description} executable unavailable: {value}")
    return os.path.abspath(path)


def socket_path(value, runtime):
    path = Path(value)
    if not path.is_absolute():
        path = runtime / path
    if not path.is_socket():
        raise ValueError(f"Parent Wayland socket is absent: {path}")
    return str(path)


def run(args):
    # WNOWAIT lets cleanup signal owned groups without a recycled-PGID race.
    if not all(hasattr(os, item) for item in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")):
        raise ValueError("Nested startup requires Python with POSIX waitid/WNOWAIT support")
    if os.getuid() == 0:
        raise ValueError("Run the nested session as your normal user, not root")
    host_runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    parent_display = socket_path(os.environ.get("WAYLAND_DISPLAY", ""), host_runtime)
    terminal = executable(os.environ.get("XMONAD_WAYLAND_TERMINAL", "foot"), "Initial terminal")
    river = executable(args.river, "River")
    manager = executable(args.manager, "Manager")
    helper = Path(__file__).resolve()
    sway_helper = helper.with_name("xmonad-wayland-sway-input.py")
    host_sway = os.environ.get("SWAYSOCK", "")
    if args.check:
        print(f"River: {river}\nManager: {manager}\nTerminal: {terminal}\nParent Wayland socket: {parent_display}")
        return 0

    stop = Stop()
    stop.install()
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "xmonad-wayland"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="nested-", dir=state))
    for name in ("river.log", "manager.log", "terminal.log", "sway-input.log"):
        fd = os.open(logs / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    runtime = Path(tempfile.mkdtemp(prefix="xmonad-wayland-", dir=host_runtime))
    children = []
    result = 0
    try:
        env = dict(os.environ)
        for name in ("SWAYSOCK", "DISPLAY", "WAYLAND_SOCKET", "WAYLAND_DEBUG",
                     "WLR_DRM_DEVICES", "WLR_HEADLESS_OUTPUTS"):
            env.pop(name, None)
        env.setdefault("PIPEWIRE_RUNTIME_DIR", str(host_runtime))
        if "PULSE_SERVER" not in env and (host_runtime / "pulse/native").is_socket():
            env["PULSE_SERVER"] = "unix:" + str(host_runtime / "pulse/native")
        env.update(XDG_RUNTIME_DIR=str(runtime), WAYLAND_DISPLAY=parent_display,
                   WLR_BACKENDS="wayland", WLR_WL_OUTPUTS="1", WLR_LIBINPUT_NO_DEVICES="1",
                   XDG_CURRENT_DESKTOP="XMonadWayland", XDG_SESSION_TYPE="wayland",
                   XDG_SESSION_DESKTOP="xmonad-wayland",
                   XMONAD_WAYLAND_MANAGER=manager, XMONAD_WAYLAND_TERMINAL=terminal,
                   XMONAD_WAYLAND_NESTED_HELPER=str(helper),
                   XMONAD_WAYLAND_NESTED_RUNTIME=str(runtime), XMONAD_WAYLAND_NESTED_LOGS=str(logs))
        print("Opening nested River with an initial terminal.", flush=True)
        print(f"Session diagnostics: {logs}", flush=True)
        with (logs / "river.log").open("ab") as river_log, (logs / "sway-input.log").open("ab") as input_log:
            river_child = Child([river, "-c", 'exec "$XMONAD_WAYLAND_NESTED_HELPER" --init', *args.river_args],
                                env=env, stdin=subprocess.DEVNULL, stdout=river_log, stderr=river_log)
            children.append(river_child)
            forwarding = None
            if host_sway and Path(host_sway).is_socket() and sway_helper.is_file():
                forwarding = Child([sys.executable, str(sway_helper), "--river-pid", str(river_child.process.pid),
                                    "--sway-socket", host_sway], env=env,
                                   stdin=subprocess.DEVNULL, stdout=input_log, stderr=input_log)
                children.insert(0, forwarding)
                print("Click River to use its shortcuts; Ctrl+Alt+Escape returns to Sway.", flush=True)
            else:
                print("Parent shortcut forwarding is unavailable; the host may intercept Super shortcuts.", flush=True)
            while not stop.signal:
                status = river_child.status()
                if status is not None:
                    result = status
                    break
                finished = runtime / "init-finished.json"
                if finished.exists():
                    result = json.loads(finished.read_text())["status"]
                    break
                if forwarding is not None and forwarding.status() is not None:
                    forwarding_status = forwarding.status()
                    stop_children([forwarding])
                    children.remove(forwarding)
                    forwarding = None
                    if forwarding_status:
                        print("Sway shortcut forwarding stopped; see sway-input.log.", flush=True)
                time.sleep(0.05)
            if stop.signal:
                result = 128 + stop.signal
    finally:
        stop_children(children, grace=3)
        # The init supervises its groups even if River was force-killed, by
        # noticing reparenting. Wait for its cleanup before removing its runtime.
        deadline = time.monotonic() + 4
        while ((runtime / "init-started").exists()
               and not (runtime / "init-finished.json").exists()
               and time.monotonic() < deadline):
            time.sleep(0.05)
        if (runtime / "init-started").exists() and not (runtime / "init-finished.json").exists():
            print(f"Nested init cleanup did not finish; preserved runtime: {runtime}", file=sys.stderr)
            result = result or 1
        else:
            shutil.rmtree(runtime)
        print(f"Nested River exited with status {result}. Diagnostics: {logs}", flush=True)
    return result


def main():
    if sys.argv[1:] == ["--init"]:
        return session_init()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--river", required=True)
    parser.add_argument("--manager", required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("river_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.river_args[:1] == ["--"]:
        args.river_args.pop(0)
    try:
        return run(args)
    except (OSError, ValueError, KeyError) as error:
        print(f"Nested session: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
