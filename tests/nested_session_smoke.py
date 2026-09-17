#!/usr/bin/env python3
"""Test nested startup inside a separate headless River; no user desktop IPC."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def until(check, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"test process exited early: {process.returncode}")
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise RuntimeError("timed out waiting for nested startup")


def stop(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)
        raise RuntimeError("compositor cleanup exceeded eight seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--river", default="river")
    parser.add_argument("--manager", default=str(ROOT / "build/xmonad-wayland"))
    parser.add_argument("--foot", default="foot")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    for name in ("river", "manager", "foot"):
        resolved = shutil.which(getattr(args, name))
        if not resolved:
            parser.error(f"missing {name}")
        setattr(args, name, str(Path(resolved).resolve()))
    output = Path(args.output).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xmonad-nested-smoke-") as directory:
        temporary = Path(directory)
        runtime = temporary / "runtime"
        runtime.mkdir(mode=0o700)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(temporary / "config"),
                   XDG_STATE_HOME=str(temporary / "state"), WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1",
                   WLR_NO_HARDWARE_CURSORS="1", XW_TEST_PARENT_MANAGER=args.manager)
        for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "SWAYSOCK", "I3SOCK",
                     "WAYLAND_DEBUG", "XMONAD_WAYLAND_CONFIG"):
            env.pop(name, None)
        nested = parent = None
        logs = None
        with (output / "parent-river.log").open("w") as parent_log, (output / "launcher.log").open("w") as launcher_log:
            try:
                parent = subprocess.Popen([args.river, "-no-xwayland", "-log-level", "debug", "-c",
                                           'exec "$XW_TEST_PARENT_MANAGER"'],
                                          env=env, stdin=subprocess.DEVNULL, stdout=parent_log,
                                          stderr=parent_log, start_new_session=True)
                parent_socket = until(lambda: next((item for item in runtime.glob("wayland-*")
                                                    if item.is_socket()), None), parent)
                until(lambda: "finished committing transaction" in (output / "parent-river.log").read_text(), parent)
                nested_env = dict(env, WAYLAND_DISPLAY=str(parent_socket),
                                  XMONAD_WAYLAND_RIVER=args.river, XMONAD_WAYLAND_MANAGER=args.manager,
                                  XMONAD_WAYLAND_TERMINAL=args.foot)
                nested = subprocess.Popen([str(ROOT / "scripts/xmonad-wayland-session"), "--nested",
                                           "--", "-no-xwayland", "-log-level", "debug"],
                                          env=nested_env, stdin=subprocess.DEVNULL, stdout=launcher_log,
                                          stderr=launcher_log, start_new_session=True)
                log_base = temporary / "state/xmonad-wayland"
                logs = until(lambda: next(log_base.glob("nested-*"), None), nested)
                def terminal_mapped():
                    trace = (logs / "river.log").read_text()
                    if "protocol error" in trace.lower():
                        raise RuntimeError("nested protocol error")
                    return re.search(r"window '.+' mapped", trace)
                until(terminal_mapped, nested)
                assert "Starting Wayland backend" in (logs / "river.log").read_text()
                assert not (logs / "sway-input.log").read_text(), "unexpected Sway helper activity"
                child_runtime = next(runtime.glob("xmonad-wayland-*"))
                stop(nested)
                assert nested.returncode == 143, nested.returncode
                assert not child_runtime.exists(), "nested runtime survived shutdown"
                assert parent.poll() is None, "nested cleanup stopped the separate parent"
                report = {"status": "PASS", "backend": "wayland inside isolated headless River",
                          "renderer": "pixman", "initial_foot_mapped": True,
                          "cleanup_status": nested.returncode, "private_runtime_removed": True,
                          "host_sway_ipc_used": False, "physical_input_tested": False}
                (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(report, indent=2))
            finally:
                try:
                    stop(nested)
                finally:
                    stop(parent)
                if logs is not None:
                    shutil.copytree(logs, output / "nested", dirs_exist_ok=True)


if __name__ == "__main__":
    main()
