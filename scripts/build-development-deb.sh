#!/bin/sh
# Local Linux amd64 development packaging; not a cross-distribution certification.
set -eu
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
    echo 'This development binary recipe targets Linux x86_64 only; use native source packaging.' >&2
    exit 1
}
out=${1:-"$PWD/dist"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/xmonad-wayland-deb.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
make all
make install PREFIX=/usr DESTDIR="$stage"
strip "$stage/usr/bin/xmonad-wayland"
glibc_min=$(readelf --version-info "$stage/usr/bin/xmonad-wayland" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' | sort -V | tail -n 1)
[ -n "$glibc_min" ] || { echo 'Cannot determine the required glibc ABI.' >&2; exit 1; }
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'EOF'
Package: xmonad-wayland
Version: 0.1.0-1
Architecture: amd64
Maintainer: Local Builder <root@localhost>
Section: x11
Priority: optional
Depends: libc6 (>= 2.38), libgmp10, libffi8, libwayland-client0 (>= 1.20)
Recommends: river (>= 0.4)
Suggests: foot, fuzzel
Description: experimental native Wayland port of XMonad's StackSet core
 Haskell window-management policy using River 0.4 or newer. This is an
 independent development build, not an official XMonad release. Existing
 xmonad.hs/contrib configurations are not compatible. A compatible River
 compositor is required separately; river-classic and River 0.3 cannot work.
 This amd64 build requires glibc 2.38 or newer. Rebuild the source recipe
 for other architectures, older glibc, musl, or BSD.
EOF
sed -i "s/libc6 (>= 2.38)/libc6 (>= $glibc_min)/" "$stage/DEBIAN/control"
printf 'Installed-Size: %s\n' "$(du -sk "$stage/usr" | awk '{print $1}')" >> "$stage/DEBIAN/control"
dpkg-deb --root-owner-group --build "$stage" "$out/xmonad-wayland_0.1.0-1_amd64.deb"
