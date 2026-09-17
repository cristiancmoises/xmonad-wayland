# Platform and dependency status

This development release is a Haskell window manager for River's native Wayland
management protocol. It is not the upstream XMonad X11 executable. Building a
package and running a compositor are separate validation steps; neither proves
that every GPU, monitor, input device or desktop application works.

All runtime targets need **River >= 0.4**, advertising `river_window_manager_v1`
and `river_xkb_bindings_v1`. River 0.3 and `river-classic` cannot host this manager.
The manager links libwayland-client; River carries the wlroots, input, graphics
and seat-management dependencies. Do not install Linux ELF binaries on BSD, or
a Guix-linked ELF binary as a conventional Debian/Fedora package.

## Targets

The package availability column was checked on 2026-09-16. It describes upstream
distribution repositories, not a guarantee for every release or architecture.
Current execution evidence is recorded in [VERIFICATION.md](VERIFICATION.md).

Debian 13 (amd64, GHC 9.6.6) and Fedora 44 (x86_64, GHC 9.10.3) have passed
native source/binary package builds, the automated suite, package installation
and installed-binary execution in containers. Fedora's installed RPM has also
passed the real River 0.4.8 headless test with two outputs and five windows.
Other distribution recipes have not been built natively here.

| Target | Packaging path | Compatible compositor availability / limit |
| --- | --- | --- |
| Guix System / Guix on Linux | Local Guix manager and separate pinned River recipe | Older channels contain River 0.3.12; use the supplied River recipe and its documented channel |
| Debian 13 (trixie) | Native `.deb` source build and CI job | Manager toolchain available; River >= 0.4 must be supplied separately if absent from selected repositories |
| Ubuntu / other Debian releases | Same source recipe; rebuild natively | Build needs GHC >= 9.0 and Wayland >= 1.20; no cross-release binary compatibility claim |
| Fedora 44 | Native RPM source build and CI job | Official package index lists River 0.4.8 |
| Fedora 45 / Rawhide | Same RPM recipe; rebuild natively | Official index lists River 0.4.8; no native validation of these releases here |
| Fedora 43 / enterprise derivatives | Source candidate | Fedora 43 River 0.3.14 is incompatible; dependencies vary on derivatives |
| openSUSE | RPM source candidate | GHC package names and compatible River availability require native validation |
| Arch Linux x86_64 | Local PKGBUILD | Official Extra contains River 0.4.8; `ghc-static` is required for compilation |
| Alpine edge x86_64 | Local APKBUILD | Community contains River 0.4.8; rebuild for musl with `ghc-dev` |
| FreeBSD | Local ports recipe | Current ports contains River 0.4.8; quarterly package sets can differ; native build and runtime remain unverified |
| OpenBSD current | Native source build | Ports contains River 0.4.5 and OpenBSD-specific evdev/input dependencies; native manager execution unverified |
| OpenBSD stable | Source candidate | Do not mix current ports/packages with a stable system to obtain this stack |
| NetBSD | Research candidate | No compatible River package/stack verified; no working package supplied |
| DragonFly BSD | Research candidate | No compatible River package/stack verified; no working package supplied |

Container package builds share the Linux host kernel and have no GPU or physical
seat access. A passing container build covers its native compiler, libraries,
package installation and automated tests. BSD validation requires a BSD kernel
(VM or hardware), its own GHC build and its compositor/input stack. Cross-compiling
the client alone does not establish those runtime dependencies.

## Why this backend

[Upstream XMonad](https://github.com/xmonad/xmonad) remains an X11 project.
River's [documented separation of compositor and window manager](https://isaacfreund.com/blog/river-window-management/)
allows this project to reuse XMonad's unchanged pure StackSet and implement its
policy in Haskell without maintaining a graphics driver/compositor stack.
The [River README](https://github.com/riverwm/river) documents the stable protocol
boundary and current compositor build requirements (Zig 0.16, wlroots 0.20,
Wayland, wayland-protocols, xkbcommon >= 1.12, libevdev and pixman). These are
River requirements, not additional libraries linked by this manager.

A broader independent port exists in Michael Sloan's `xmonad-on-river` branches.
The revisions inspected are:

- [xmonad dec3b72d726c766dfeba2a605f51e52073d96538](https://github.com/mgsloan/xmonad/tree/dec3b72d726c766dfeba2a605f51e52073d96538)
- [xmonad-contrib 24a21fb037ca0a291ac62ffec6566279e78574df](https://github.com/mgsloan/xmonad-contrib/tree/24a21fb037ca0a291ac62ffec6566279e78574df)

That fork preserves substantially more of XMonad's API. Its own
[backend report](https://github.com/mgsloan/xmonad/blob/dec3b72d726c766dfeba2a605f51e52073d96538/README.river.md)
limits the initial runtime evidence to headless compositor tests, while its
[contrib survey](https://github.com/mgsloan/xmonad-contrib/blob/24a21fb037ca0a291ac62ffec6566279e78574df/SURVEY.md)
reports 304 compiling modules, 21 failures and 9 not attempted. Compilation is
not desktop runtime coverage. It is an alternative for a future compatibility
migration, not vendored code or a feature claim for this package. The older
[Waymonad project](https://github.com/waymonad/waymonad) describes itself as work
in progress and not a reimplementation of XMonad.

## Primary distribution sources

- [Fedora River packages](https://packages.fedoraproject.org/pkgs/river/river/)
- [Arch River](https://archlinux.org/packages/extra/x86_64/river/) and [GHC static libraries](https://archlinux.org/packages/extra/x86_64/ghc-static/)
- [Alpine edge River](https://pkgs.alpinelinux.org/package/edge/community/x86_64/river) and [GHC development libraries](https://pkgs.alpinelinux.org/package/edge/community/x86_64/ghc-dev)
- [FreeBSD River port](https://cgit.freebsd.org/ports/tree/x11-wm/river/Makefile)
- [OpenBSD current River port](https://github.com/openbsd/ports/blob/master/wayland/river/Makefile)
- [Debian trixie GHC](https://packages.debian.org/trixie/ghc)
