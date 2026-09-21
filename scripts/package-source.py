#!/usr/bin/env python3
"""Export the reviewed public source list, or make a reproducible archive."""
import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


EXCLUDED = {"__pycache__", ".git", "build", "dist", "stage", "evidence"}
GENERATED = (".pyc", ".o", ".hi", ".deb", ".rpm", ".tar.gz")


def source_paths(root):
    selected = set()
    for line in (root / "scripts/source-manifest").read_text().splitlines():
        name = line.strip()
        if not name or name.startswith("#"):
            continue
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or name == ".":
            raise SystemExit("Invalid source manifest entry: " + name)
        path = root / relative
        if not path.exists() and not path.is_symlink():
            raise SystemExit("Missing source manifest entry: " + name)
        pending = [path]
        while pending:
            item = pending.pop()
            relative = item.relative_to(root)
            if any(part in EXCLUDED for part in relative.parts):
                continue
            if item.is_symlink():
                raise SystemExit("Public source must not contain links: " + str(relative))
            if item.is_dir():
                pending.extend(item.iterdir())
            elif item.is_file():
                if not item.name.endswith(GENERATED):
                    selected.add(relative)
            else:
                raise SystemExit("Unsupported source file: " + str(relative))
    return sorted(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", help="archive directory (default: dist)")
    parser.add_argument("--export-dir", type=Path, help="copy public files without Git history")
    parser.add_argument("--zupt", action="store_true",
                        help="compress with zupt -l 9 (post-quantum compressor, extreme) instead of gzip")
    args = parser.parse_args()
    if args.destination and args.export_dir:
        parser.error("choose an archive directory or --export-dir")
    root = Path(__file__).resolve().parent.parent
    paths = source_paths(root)
    if args.export_dir:
        destination = args.export_dir.resolve()
        # An export must never overwrite the working source or its ancestors.
        if destination == root or destination in root.parents:
            raise SystemExit("Export destination overlaps the source root")
        if destination.is_dir() and any(destination.iterdir()):
            raise SystemExit("Export destination must be empty")
        destination.mkdir(parents=True, exist_ok=True)
        for relative in paths:
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / relative, target)
            target.chmod(0o755 if (root / relative).stat().st_mode & 0o111 else 0o644)
        print(destination)
        return
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", version):
        raise SystemExit("VERSION must contain a safe numeric release version")
    destination = Path(args.destination or root / "dist").resolve()
    destination.mkdir(parents=True, exist_ok=True)
    basename = "xmonad-wayland-" + version
    timestamp = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    def normalize(info):
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = timestamp
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info

    def add_all(tar):
        for relative in paths:
            tar.add(root / relative, arcname=basename + "/" + str(relative),
                    recursive=False, filter=normalize)

    if args.zupt:
        # Same reproducible tar payload, compressed with the maintainer's zupt
        # tool at its maximum level (9) for extreme compression.  Compress in
        # a temporary directory so zupt never has to open the workspace path.
        compressor = shutil.which("zupt")
        if not compressor:
            raise SystemExit("zupt is required for --zupt")
        with tempfile.TemporaryDirectory() as tmp:
            tar_path = Path(tmp) / (basename + ".tar")
            tmp_archive = Path(tmp) / (basename + ".tar.zupt")
            with tar_path.open("wb") as raw:
                with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
                    add_all(tar)
            # Relative paths only: zupt stores the input path as-is, so a
            # relative name extracts back to the user's current directory.
            subprocess.run([compressor, "compress", "-l", "9",
                            (basename + ".tar.zupt"), (basename + ".tar")],
                           cwd=tmp, check=True, stdout=subprocess.DEVNULL)
            archive = destination / (basename + ".tar.zupt")
            shutil.move(str(tmp_archive), str(archive))
    else:
        archive = destination / (basename + ".tar.gz")
        with archive.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=timestamp) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
                    add_all(tar)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = archive.with_name(basename + ".sha256")
    checksum.write_text(digest + "  " + archive.name + "\n")
    print(archive)


if __name__ == "__main__":
    main()
