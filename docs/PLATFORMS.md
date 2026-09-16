# Platform and dependency status

Source packaging is not evidence of a working desktop. All targets require a
native River >=0.4 advertising `river_window_manager_v1` and `river_xkb_bindings_v1`.
River 0.3 and river-classic are incompatible despite similar executable names.
This manager links libwayland-client, not wlroots. River carries the wlroots,
graphics/input and session dependencies.

| Target | Delivery | Runtime situation |
|---|---|---|
| Ubuntu 24.04 x86_64 build environment | Compiled manager and Debian-format development package | No real River/GPU session validated here |
| Debian / Ubuntu family | Debian source recipe, experimental amd64 binary | Compatible official River package not established; supply River >=0.4 separately |
| Fedora 44 / 45 | RPM source recipe and experimental x86_64 RPM built on Ubuntu | Official package lists River 0.4.8; native RPM installation untested |
| Fedora 43 / older enterprise derivatives | RPM source recipe | Fedora 43 lists River 0.3.14; old River is incompatible; compiler/runtime availability varies |
| openSUSE | RPM source recipe | Build and runtime dependency resolution untested |
| Arch family | Local-source PKGBUILD | Native build/install untested; verify River >=0.4 |
| Alpine | Local-source APKBUILD | Rebuild for musl; Linux glibc binaries are not Alpine binaries |
| GNU Guix | Local-file package recipe | Recipe unbuilt here; installed channel must supply River >=0.4 separately |
| FreeBSD | Local ports recipe | Current ports has River 0.4.8; manager build/runtime untested |
| OpenBSD current | Native source-build instructions | Current ports has River 0.4.5; no prebuilt manager package validated |
| OpenBSD stable | Source candidate | Do not assume current ports availability in the stable release |
| NetBSD | Research/build candidate | Wayland/wlroots exists; compatible River availability not verified |
| DragonFly BSD | Unverified | No compatible River stack verified; no runnable-package claim |

The downloadable ELF binaries are **Linux x86_64 glibc development builds**.
They cannot run on a BSD kernel. `.deb` and `.rpm` contain the same locally built
manager executable; wrapping it in RPM does not establish a Fedora-native build.
Rebuild the source recipe on each intended distribution and architecture.

## Primary evidence checked 2026-09-16

- [River architecture](https://isaacfreund.com/blog/river-window-management/)
- [River protocol documentation](https://isaacfreund.com/docs/wayland/river-window-management-v1/)
- [Fedora River packages](https://packages.fedoraproject.org/pkgs/river/river/)
- [FreeBSD River port](https://cgit.freebsd.org/ports/tree/x11-wm/river/Makefile)
- [OpenBSD current River port](https://cvsweb.openbsd.org/checkout/ports/wayland/river/Makefile?rev=1.2)
- [Guix River catalog entry](https://packages.guix.gnu.org/packages/river/0.3.12/)
- [NetBSD wlroots package](https://cdn.netbsd.org/pub/pkgsrc/current/pkgsrc/wayland/wlroots/index.html)

The indexed Guix catalog entry was 0.3.12; this is not proof that every current
channel has that version. Check `guix show river` and `river -version` locally.
The Guix recipe intentionally does not propagate an incompatible old compositor
or invent a new River package with unverified source hashes/build dependencies.
