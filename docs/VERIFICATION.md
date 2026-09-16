# Verification record — 2026-09-16

This release is experimental. Validation below concerns the window manager,
not a complete desktop or all operating systems named in the packaging matrix.

## Environment

Linux x86_64, Ubuntu 24.04 environment; GHC 9.4.7, Wayland 1.22.0, GCC and GNU
make. Compiler and Wayland development dependencies were extracted from official
Ubuntu packages to a local build prefix. No user desktop was changed.

## Verified code behavior

- Both Haskell and C compile. C passes `-Wall -Wextra -Werror -Wconversion`.
- Pure Haskell tests cover focus/swap/view/shift, unique windows/workspaces,
  output disconnect/reconnect, layout and ratio retention, tiny geometry,
  Int32 coordinate bounds, large arithmetic and lock-state action suppression.
- The actual ELF executable is exercised with a synthetic Wayland server through
  an inherited Unix socket pair. It rejects missing and unavailable management
  globals. Successful transactions cover geometry, focus, workspace shift/view,
  output add/remove, closed windows, locking/unlocking and orderly stop.
  The normal scenario validates 274 client requests; missing/unavailable cases
  validate 2/4 requests. Separate SIGINT and SIGTERM scenarios validate clean
  exit while idle after 86 requests each.
- The protocol fixture validates request versions, manage/render phase ordering
  and use-after-destroy at the protocol-object level. It is a deliberately small
  server, not River, and cannot verify real rendering or application behavior.
- A separate runtime fixture verifies C/Haskell phase discipline, literal command
  arguments without shell expansion, child reaping and callback exception handling.
  The test interpreter override also passed with a PATH containing python3.12
  and no python3 alias.
- The linked executable uses system libwayland-client, libgmp, libffi, libm and
  libc. ELF inspection found no RPATH/RUNPATH to the build workspace.

Reproduce the tests with `make test`. The vendored unmodified StackSet has an
existing unused `foldr` import warning under GHC 9.4.7; no source alteration was
made just to suppress that upstream warning.

## Package boundary

The source includes Debian, RPM, Arch, Alpine, FreeBSD and Guix build recipes.
Local Linux amd64 Debian-format and x86_64 RPM builds are development artifacts.
They require **glibc >=2.38** and a separately available compatible River. Use
source builds on Debian 12/older Ubuntu, musl, other architectures and BSD.
RPM generation on Ubuntu is not a Fedora or openSUSE installation test.

No native Arch/Alpine/Guix/BSD build, package-manager installation, real River
session, DRM/GPU, physical monitor, performance benchmark or security audit has
been completed. Existing arbitrary XMonad configurations have not been ported.
Those are remaining acceptance gates, not implied capabilities of this archive.
