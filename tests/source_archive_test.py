#!/usr/bin/env python3
"""Check public source boundaries in a disposable checkout."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SourceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xmonad source ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "checkout"
        (self.root / "scripts").mkdir(parents=True)
        self.script = self.root / "scripts/package-source.py"
        shutil.copy2(ROOT / "scripts/package-source.py", self.script)
        (self.root / "scripts/source-manifest").write_text(
            "# fixture\nVERSION\nLICENSE\nsrc\nscripts/package-source.py\n"
            "scripts/source-manifest\n")
        (self.root / "VERSION").write_text("0.2.0-dev\n")
        (self.root / "LICENSE").write_text("Fixture license\n")
        (self.root / "src").mkdir()
        (self.root / "src/main.hs").write_text("main = pure ()\n")
        for name in ["GOD-TIER-PROMPT.md", "docs/superpowers/plan.md",
                     "packaging/debian/rules", "evidence/private.txt",
                     "src/__pycache__/cache.pyc", "src/unwanted.o"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("PRIVATE_SENTINEL\n")

    def run_script(self, *arguments):
        return subprocess.run([sys.executable, str(self.script), *map(str, arguments)],
                              capture_output=True, text=True, timeout=10,
                              env=dict(os.environ, SOURCE_DATE_EPOCH="1234"))

    def test_export_and_archive_have_same_public_files(self):
        out = Path(self.temp.name) / "archives"
        result = self.run_script(out)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = out / "xmonad-wayland-0.2.0-dev.tar.gz"
        with tarfile.open(archive) as handle:
            files = {str(Path(item.name).relative_to("xmonad-wayland-0.2.0-dev")):
                     handle.extractfile(item).read()
                     for item in handle.getmembers() if item.isfile()}
        self.assertEqual(set(files), {"VERSION", "LICENSE", "src/main.hs",
                                     "scripts/package-source.py", "scripts/source-manifest"})
        self.assertFalse(any(b"PRIVATE_SENTINEL" in data for data in files.values()))
        exported = Path(self.temp.name) / "export"
        result = self.run_script("--export-dir", exported)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = {str(path.relative_to(exported)): path.read_bytes()
                  for path in exported.rglob("*") if path.is_file()}
        self.assertEqual(actual, files)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(self.run_script(out).returncode, 0)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), digest)

    def test_symlink_in_public_tree_is_rejected(self):
        (self.root / "src/leak").symlink_to(self.root / "evidence/private.txt")
        result = self.run_script(Path(self.temp.name) / "archives")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link", result.stderr.lower())

    def test_missing_manifest_entry_fails(self):
        (self.root / "LICENSE").unlink()
        result = self.run_script(Path(self.temp.name) / "archives")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LICENSE", result.stderr)

    def test_escape_in_manifest_is_rejected(self):
        (self.root / "scripts/source-manifest").write_text("../private\n")
        result = self.run_script(Path(self.temp.name) / "archives")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest", result.stderr.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
