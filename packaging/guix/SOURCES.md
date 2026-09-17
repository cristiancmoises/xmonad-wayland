# Pinned sources

The recipe is maintained locally for this experimental project, not an upstream
River or GNU Guix release. It uses the upstream River release source without
application changes, except substituting Guix shell paths and correcting the
installed pkg-config prefix.

Official Guix commit: `fe590afef7319a8ea921d35b67fb39fb79f5a3b3`.
The official channel introduction is retained for authentication.
This revision provides Zig 0.16.0, wlroots 0.20.2 and libxkbcommon 1.13.1, while
its existing `river` package remains at 0.3.12.

- [Guix Zig compiler definitions](https://codeberg.org/guix/guix/src/commit/fe590afef7319a8ea921d35b67fb39fb79f5a3b3/gnu/packages/zig.scm)
- [Guix wlroots definitions](https://codeberg.org/guix/guix/src/commit/fe590afef7319a8ea921d35b67fb39fb79f5a3b3/gnu/packages/window-management.scm)
- [River 0.4.8 build requirements](https://github.com/riverwm/river/blob/v0.4.8/README.md)
- [River packaging instructions](https://github.com/riverwm/river/blob/v0.4.8/PACKAGING.md)

The SHA-256 values below were computed from the downloaded archives. The Zig
content hashes are also pinned to the upstream `build.zig.zon` manifests.
No prebuilt compositor or compiler is bundled; Guix supplies the toolchain.

## Licensing and bundled code review

The River archive contains GPL-3.0-only compositor code, MIT protocol XML,
CC-BY-SA-4.0 documentation/artwork, and 0BSD examples/configuration. The recipe
records all four licenses; Guix installs the upstream `LICENSES` directory.
The four Zig library bindings, translate-c and Aro carry MIT licenses. The
Wayland/wlroots archives also contain ISC examples outside their selected Zig
package paths. Aro includes Unicode data/license text and Zig support code.
Its source archive also contains GPL-3.0-or-later test fixtures, which are
outside the manifest's package paths and are not included in the built River.

System libraries are separate Guix packages: wlroots, Wayland, libinput,
libevdev, libxkbcommon and pixman. The six Zig archives are separately pinned
build inputs. translate-c's Aro dependency is included explicitly. River
supplies its protocol XML and three upstream protocol files in the signed
release source. No additional network fetch is permitted by `zig build
--system`; the source audit and successful/failed build evidence are retained
under `evidence/guix-*`.

| Archive | SHA-256 | URL |
|---|---|---|
| river-0.4.8.tar.gz | `6d4030526e307e40de357167b4d6daacb583aed353dd93e32e1314c2d34400fa` | [source](https://codeberg.org/river/river/releases/download/v0.4.8/river-0.4.8.tar.gz) |
| zig-pixman-0.3.0.tar.gz | `4b0b57ce37f7bb3a2c2fc76eec93d060830d2c92155bf2a6baa43d61ad05499e` | [source](https://codeberg.org/ifreund/zig-pixman/archive/v0.3.0.tar.gz) |
| zig-wayland-0.6.0.tar.gz | `759a632e36a948e0e412d2d74a43a69d2f34e65d40289a16af7aa3725852ef25` | [source](https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz) |
| zig-wlroots-0.20.1.tar.gz | `d4f5d1628cd2a81ea897ea2638872064ab88007c5711a928e0b379c27043a175` | [source](https://codeberg.org/ifreund/zig-wlroots/archive/v0.20.1.tar.gz) |
| zig-xkbcommon-0.4.0.tar.gz | `cc1f8835ad6e50d5cd4da82a5d1741203f3d7b47c744418167ba602e75b8b5c7` | [source](https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.4.0.tar.gz) |
| zig-translate-c-57c559c.tar.gz | `b9aa5df3316a47645b3027c4aa7c10ab2a89519f694235210028cb60cd9dc65e` | [source](https://codeberg.org/ziglang/translate-c/archive/57c559cf581b1fcad90494eda219f98abeb155ce.tar.gz) |
| zig-aro-5f5a050.tar.gz | `e20b49a13049e8ef5aa1d798a70d8fc02b691fe44c7c78928aae3d363a1deb7e` | [source](https://codeload.github.com/Vexu/arocc/tar.gz/5f5a050569a95ecc40a426f0c3666ae7ef987ede) |

## Optional Channel input daemon

`channel.scm` pins Channel's `0.4.2` development source at commit
`94a3d6c72c7493dd21a3b2ed10f8776bb887b857`. It is a separate daemon using
River's input-management, libinput-configuration and XKB-configuration
protocols. It does not install a user configuration or start a service.

| Archive | SHA-256 | URL |
|---|---|---|
| Channel `94a3d6c` | `f8d6a8ca08d1a8db9065f89861eecffd00be12d88517537cddb83e2c1e4f06fe` | [source](https://codeberg.org/Sivecano/channel/archive/94a3d6c72c7493dd21a3b2ed10f8776bb887b857.tar.gz) |
| libtributary `b1e00ff` | `02a4e3cc3d101ed93081acd4be8b3470f0c434f3b255ba22fc655756f3c90b01` | [source](https://codeberg.org/Sivecano/libtributary/archive/b1e00ffdc1a87f6601b7913a1196c488ff39b27d.tar.gz) |

Channel also uses the already listed zig-wayland `0.6.0` archive. Both Zig
package content hashes are verified before extracting their build inputs;
`--system` prohibits dependency downloads during compilation. The C
translation step uses the Guix Zig compiler directly. River's pinned package
provides protocol XML as a native input; Wayland and libxkbcommon are separate
shared-library inputs.

Channel and libtributary each ship the GNU Affero General Public License,
version 3, in their `LICENSE` files. No separate source-file grant specifying
“or any later version” was found, so this recipe records AGPL-3.0-only rather
than GPL or AGPL-3.0-or-later. The zig-wayland bindings and generated River
protocol bindings use MIT licensing. The libtributary Zig manifest omits its
license file, so the recipe separately installs that file from the verified
archive alongside Channel's documentation and upstream example config.

Channel has no upstream test target. Its libtributary dependency does, but
running that target unchanged fails because it lacks the Wayland module
normally supplied by its consumer and uses obsolete positional initializers
for `Vec2` in two rectangle test fixtures. The recipe adds a test target using
libtributary's existing test root with Channel's generated Wayland module and
updates those fixture initializers to named `x`/`y` fields. All upstream test
bodies remain enabled. The original failure is preserved in
`evidence/guix-channel-tributary-upstream-test.log`; build, lint and runtime
results are recorded separately under `evidence/guix-channel-*`.

This Channel revision has no command-line help or version option. It logs its
version at startup, then reads `$XDG_CONFIG_HOME/river/config.rh` or
`$HOME/.config/river/config.rh` and connects to the configured Wayland socket.
Runtime checks must use an isolated compositor and configuration directory.
