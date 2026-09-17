#!/bin/sh
# Build the fixture first; accepts its executable path as the only argument.
set -eu
PYTHON=${PYTHON:-python3}
export PYTHON
"$PYTHON" - "${1:-build/runtime-test/runtime-test}" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="xmonad-runtime-") as directory:
    result_path = Path(directory) / "argv.json"
    injected_path = Path(directory) / "injected"
    environment = dict(os.environ)
    environment.pop("XW_RUNTIME_FAIL", None)
    subprocess.run(
        [binary, "normal", str(result_path), str(injected_path)],
        env=environment, check=True, timeout=15,
    )
    expected = ["space arg", "$(touch " + str(injected_path) + ")", "semi;colon"]
    assert json.loads(result_path.read_text()) == expected
    assert not injected_path.exists(), "command arguments were interpreted by a shell"
    for mode in ['reload', 'reload-invalid']:
        env = dict(environment, XW_RUNTIME_RELOAD='1')
        if mode == 'reload-invalid':
            env['XW_RUNTIME_RELOAD_INVALID'] = '1'
        result = subprocess.run(
            [binary, mode, str(result_path), str(injected_path)],
            env=env, capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0, result
        if mode == 'reload-invalid':
            assert 'workspaceIds cannot change during reload' in result.stderr
    for mode in ['confirm-exit', 'confirm-cancel', 'confirm-empty', 'confirm-fail', 'confirm-garbage', 'confirm-block', 'confirm-ignore-term']:
        marker = Path(directory) / (mode + '.pid')
        timeout = 5 if mode == 'confirm-ignore-term' else 15
        try:
            result = subprocess.run(
                [binary, mode, str(result_path), str(injected_path)],
                env=dict(environment, XW_RUNTIME_CONFIRM=mode, XW_CONFIRM_MARKER=str(marker)),
                capture_output=True, text=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            if marker.exists():
                for pid in marker.read_text().splitlines():
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            raise AssertionError(f'{mode}: runtime cleanup exceeded {timeout} seconds') from None
        assert result.returncode == 0, result
        pids = marker.read_text().splitlines()
        assert len(pids) == 1, 'repeated binding opened simultaneous confirmation dialogs'
        try:
            os.kill(int(pids[0]), 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(f'{mode}: confirmation process survived runtime cleanup')
    result = subprocess.run(
        [binary, "fail"], env=dict(environment, XW_RUNTIME_FAIL="1"),
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 1, result
    assert "callback failed; stopping: intentional callback test failure" in result.stderr
print("Runtime phase, indexed binding, reload, literal argv, confirmation/cancel/cleanup, child reaping, and callback failure tests passed.")
PY
