#!/usr/bin/env python3
"""Exercise the real compositor in its own headless socket/process group."""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_until(predicate, process, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"River exited early with {process.returncode}")
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for isolated compositor initialization")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--river", default="river")
    parser.add_argument("--manager", default=str(ROOT / "build/xmonad-wayland"))
    parser.add_argument("--probe", default=str(ROOT / "build/xdg-probe"))
    parser.add_argument("--foot", default="foot")
    parser.add_argument("--fuzzel", default="fuzzel")
    parser.add_argument("--backend", choices=("headless", "wayland"), default="headless",
                        help="wayland opens two temporary windows in the current desktop")
    parser.add_argument("--renderer", choices=("pixman", "gles2", "vulkan"), default="pixman")
    parser.add_argument("--output", default=str(ROOT / "evidence/river-smoke"))
    args = parser.parse_args()
    for key in ("river", "manager", "probe", "foot", "fuzzel"):
        resolved = shutil.which(getattr(args, key))
        if not resolved:
            parser.error(f"Missing {key}: {getattr(args, key)}")
        setattr(args, key, str(Path(resolved).resolve()))
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    processes = []
    with tempfile.TemporaryDirectory(prefix="xmonad-river-smoke-") as temporary:
        runtime = Path(temporary)
        runtime.chmod(0o700)
        init = runtime / "init"
        # Values cross the shell boundary through quoted environment variables.
        init.write_text('#!/bin/sh\nprintf "%s" "$WAYLAND_DISPLAY" > "$XW_SOCKET_FILE"\n'
                        'exec env WAYLAND_DEBUG=client "$XW_MANAGER" 2> "$XW_MANAGER_LOG"\n')
        init.chmod(0o755)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS=args.backend,
                   WLR_HEADLESS_OUTPUTS="2", WLR_WL_OUTPUTS="2", WLR_RENDERER=args.renderer,
                   WLR_LIBINPUT_NO_DEVICES="1",
                   XW_MANAGER=args.manager, XW_MANAGER_LOG=str(output / "manager.log"),
                   XW_SOCKET_FILE=str(runtime / "socket"), XW_INIT=str(init))
        for key in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY"):
            env.pop(key, None)
        if args.backend == "wayland":
            host_display = os.environ.get("WAYLAND_DISPLAY")
            host_runtime = os.environ.get("XDG_RUNTIME_DIR")
            if not host_display or not host_runtime:
                parser.error("The wayland backend requires an existing Wayland session")
            # The child compositor owns a private runtime directory; an absolute
            # parent socket path lets it connect without reusing the host socket.
            env["WAYLAND_DISPLAY"] = str(Path(host_runtime) / host_display)
        with (output / "river.log").open("w") as river_log:
            river = subprocess.Popen([args.river, "-no-xwayland", "-c", 'exec "$XW_INIT"'],
                                     env=env, stdout=river_log, stderr=river_log,
                                     start_new_session=True)
            try:
                socket_file = runtime / "socket"
                wait_until(lambda: socket_file.exists() and socket_file.read_text(), river)
                env["WAYLAND_DISPLAY"] = socket_file.read_text()
                manager_log = output / "manager.log"
                wait_until(lambda: manager_log.exists() and "manage_finish" in manager_log.read_text(), river)
                with (output / "foot.log").open("w") as foot_log:
                    for i in range(2):
                        processes.append(subprocess.Popen(
                            [args.foot, "--config=/dev/null", f"--title=Smoke terminal {i}",
                             "sh", "-c", "sleep 20"], env=env,
                             stdout=foot_log, stderr=foot_log, start_new_session=True))
                    wait_until(lambda: len(re.findall(r"\.window\(new id river_window_v1",
                                                      manager_log.read_text())) >= 2, river)
                    with (output / "probe.log").open("w") as probe_log:
                        probe = subprocess.run([args.probe], env=env, stdout=probe_log,
                                               stderr=probe_log, timeout=20)
                    if probe.returncode:
                        raise RuntimeError(f"xdg-shell probe failed: {output / 'probe.log'}")
                    if any(child.poll() is not None for child in processes):
                        raise RuntimeError(f"Foot exited early: {output / 'foot.log'}")
                    trace = manager_log.read_text()
                    windows = len(re.findall(r"\.window\(new id river_window_v1", trace))
                    outputs = len(re.findall(r"\.output\(new id river_output_v1", trace))
                    if windows < 5 or outputs < 2:
                        raise RuntimeError(f"Expected 5 windows/2 outputs, observed {windows}/{outputs}")
                    if not re.search(r"\.parent\(river_window_v1", trace):
                        raise RuntimeError("Compositor never delivered the transient parent relationship")
                    if river.poll() is not None or "protocol error" in trace.lower():
                        raise RuntimeError("Compositor or protocol failed")
                    # A default launcher is part of a usable session. River's
                    # layer-shell support must be enabled by the window manager.
                    launcher_log_path = output / "fuzzel.log"
                    with launcher_log_path.open("w") as launcher_log:
                        launcher = subprocess.Popen(
                            [args.fuzzel, "--config=/dev/null", "--dmenu"],
                            env=dict(env, WAYLAND_DEBUG="client"), stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=launcher_log, start_new_session=True)
                        processes.append(launcher)
                        launcher.stdin.write(b"XMonad Wayland test entry\n")
                        launcher.stdin.close()

                        def launcher_mapped():
                            content = launcher_log_path.read_text()
                            if launcher.poll() is not None or re.search(
                                    r"zwlr_layer_surface_v1#\d+\.closed\(", content):
                                raise RuntimeError(f"Fuzzel was rejected/closed: {launcher_log_path}")
                            return (re.search(r"zwlr_layer_surface_v1#\d+\.configure\(", content)
                                    and "ack_configure(" in content
                                    and re.search(r"wl_surface#\d+\.attach\(", content))

                        wait_until(launcher_mapped, river)
                    report = (f"PASS: real River, {outputs} {args.backend} outputs, "
                              f"renderer={args.renderer}, {windows} windows, "
                              "two Foot clients, transient/fullscreen/destroy probe, Fuzzel layer surface.\n"
                              "Direct DRM/seat, physical input, suspend, session lock and BSD were not tested.\n")
                    (output / "result.txt").write_text(report)
                    print(report, end="")
            finally:
                for child in processes:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                if river.poll() is None:
                    os.killpg(river.pid, signal.SIGTERM)
                try:
                    river.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(river.pid, signal.SIGKILL)
                    river.wait()


if __name__ == "__main__":
    main()
