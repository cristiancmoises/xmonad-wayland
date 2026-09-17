#!/bin/sh
# Use only project-local Guix outputs, leaving the user's profile unchanged.
set -eu
project=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
profile=$project/build/guix-runtime
if [ -f "$profile/etc/profile" ]; then
    GUIX_PROFILE=$profile
    export GUIX_PROFILE
    # Guix profile fragments can reference unset variables.
    set +u
    # shellcheck disable=SC1091
    . "$profile/etc/profile"
    set -u
    unset GUIX_PROFILE
    PATH=$profile/bin:$PATH
    export PATH
fi
if [ -x "$project/build/guix-river/bin/river" ]; then
    XMONAD_WAYLAND_RIVER=$project/build/guix-river/bin/river
    export XMONAD_WAYLAND_RIVER
fi
if [ -x "$project/build/guix-manager/bin/xmonad-wayland" ]; then
    XMONAD_WAYLAND_MANAGER=$project/build/guix-manager/bin/xmonad-wayland
elif [ -x "$project/build/xmonad-wayland" ]; then
    XMONAD_WAYLAND_MANAGER=$project/build/xmonad-wayland
else
    echo 'Build first: ./scripts/guix-build (Guix), or make CC=gcc (native source).' >&2
    exit 1
fi
export XMONAD_WAYLAND_MANAGER
if [ "${1:-}" = --doctor ]; then
    shift
    exec "$project/scripts/xmonad-wayland-doctor" "$@"
fi
exec "$project/scripts/xmonad-wayland-session" "$@"
