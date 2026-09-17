#!/bin/sh
# Compatibility entry point; native Debian packaging is the only .deb path.
set -eu
exec "$(dirname "$0")/build-deb.sh" "$@"
