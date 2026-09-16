#!/bin/sh
# Build the fixture first; accepts its executable path as the only argument.
set -eu
PYTHON=${PYTHON:-python3}
export PYTHON
"$PYTHON" - "${1:-build/runtime-test/runtime-test}" <<'PY'
import json
import os
from pathlib import Path
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
    result = subprocess.run(
        [binary, "fail"], env=dict(environment, XW_RUNTIME_FAIL="1"),
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 1, result
    assert "callback failed; stopping: intentional callback test failure" in result.stderr
print("Runtime phase, literal argv, child reaping, and callback failure tests passed.")
PY
