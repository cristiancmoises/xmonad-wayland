#!/bin/sh
# Build a fresh source snapshot with Debian tools and generated ABI dependencies.
set -eu
cd "$(dirname "$0")/.."
for tool in dpkg-buildpackage dpkg-parsechangelog python3 tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing $tool; run this script in a Debian/Ubuntu build environment." >&2
        exit 1
    }
done
out=${1:-"$PWD/dist/debian"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/xmonad-wayland-deb.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
archive=$(python3 scripts/package-source.py "$work")
version=$(cat VERSION)
tar -xzf "$archive" -C "$work"
source="$work/xmonad-wayland-$version"
cp -R "$source/packaging/debian" "$source/debian"
debversion=$(dpkg-parsechangelog -l "$source/debian/changelog" -S Version)
upstream=${debversion%-*}
mv "$archive" "$work/xmonad-wayland_${upstream}.orig.tar.gz"
(cd "$source" && dpkg-buildpackage -us -uc)
for artifact in "$work"/*.deb "$work"/*.dsc "$work"/*.changes \
    "$work"/*.buildinfo "$work"/*.tar.gz "$work"/*.tar.xz "$work"/*.tar.bz2; do
    [ ! -f "$artifact" ] || cp "$artifact" "$out/"
done
printf 'Native Debian artifacts: %s\n' "$out"
