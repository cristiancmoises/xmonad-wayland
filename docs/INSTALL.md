# Building and installing the experimental port

This is an independent prototype, not an upstream XMonad release. It installs
`xmonad-wayland` alongside existing window managers. It requires **River 0.4 or
newer** to run a graphical session. River classic and River 0.3 do not implement
the required window-management protocol. Building this manager does not build
or install River, and a successful build does not establish compositor or GPU
compatibility.

The recipes below are local source recipes, not packages published by the named
distributions. The Fedora/openSUSE, Arch, Alpine, FreeBSD and Guix recipes have
not been built in their target environments. Consult the release verification
report for the actual local Debian build and test results; the existence of a
Debian-format package alone does not validate every Debian/Ubuntu release.

## Requirements

| Purpose | Requirement |
| --- | --- |
| Haskell build | GHC >= 9.0, with boot libraries `base`, `containers`, `transformers`, `process`, `directory` and their static development libraries |
| C build | C11 compiler (GCC or Clang), GNU make, pkg-config |
| Wayland build | libwayland-client development files and wayland-scanner >= 1.20 |
| Tests | Python 3; no live compositor required for the protocol fixture |
| Graphical session | River >= 0.4, its normal seat/device/session setup, and a usable `XDG_RUNTIME_DIR` |
| Default shortcuts | `foot` terminal and `fuzzel` launcher, or change the Haskell configuration |

The source includes the required River protocol XML and XMonad StackSet; no
Hackage dependency download or wlroots development package is required by this
manager. River has its own additional build and runtime dependencies. Package
names and River versions vary with the selected distribution release.

Useful checks before building:

```sh
ghc --numeric-version
ghc-pkg list
pkg-config --modversion wayland-client
wayland-scanner --version
python3 --version
```

## Build and stage without root

Run in the extracted `xmonad-wayland-0.1.0` directory:

```sh
make all
make test
make install PREFIX=/usr DESTDIR="$PWD/stage"
```

The last command stages files under `stage/usr`; it does not install to `/usr`.
GNU make is called `gmake` on BSD systems. `CC`, `GHC`, `PKG_CONFIG`,
`WAYLAND_SCANNER`, and `PYTHON` can be overridden on the make command line.

For an installation owned by your normal user:

```sh
make install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

Files installed below `PREFIX` include:

| Path | Purpose |
| --- | --- |
| `bin/xmonad-wayland` | Native Wayland window-manager client |
| `bin/xmonad-wayland-session` | Starts a dedicated River session |
| `share/wayland-sessions/xmonad-wayland.desktop` | Optional display-manager session entry |
| `share/xmonad-wayland/` | Haskell/C source, protocol XML and examples |
| `share/doc/xmonad-wayland/` | README, documentation and license notices |

Display managers may not discover a session entry installed under a user prefix.
For a system-wide session entry, use a package or an administrator-approved
system prefix. None of these recipes overwrites `xmonad`, changes the default
display manager, edits `river/init`, or installs user configuration.

## Starting a session

First check `river -version` and ensure it is >= 0.4. Set up River's seat/device
access using its documentation for your OS. From a normal user's appropriate
graphical login/TTY environment, run:

```sh
xmonad-wayland-session
```

The launcher passes a fixed startup command to River and runs this manager as
its window-management client. Running `xmonad-wayland` in a generic Wayland
desktop such as GNOME or KDE will not work: River's management globals must be
available to the process. The launcher does not start session-lock, notification,
clipboard, panel, wallpaper or portal services. This prototype is not a complete
desktop environment. Review its limitations before using it as a daily session.

## Debian and Ubuntu source packaging

Build prerequisites include `build-essential`, `ghc`, `pkg-config`,
`libwayland-dev`, `libwayland-bin`, `python3`, and `debhelper` >= 13. The selected
GHC and Wayland packages must meet the minimum versions above. Boot Haskell
libraries are supplied with Debian's GHC package.

With the supplied source archive beside the extracted source directory:

```sh
cp ../xmonad-wayland-0.1.0.tar.gz ../xmonad-wayland_0.1.0.orig.tar.gz
cp -a packaging/debian debian
dpkg-buildpackage -us -uc
```

Use a clean extraction and copy the packaging directory only once. This produces
an unsigned local source package and binary package; `dpkg-buildpackage -us -uc
-b` requests only the binary build. The recipes do not publish either package.
Inspect the resulting package before installation:

```sh
dpkg-deb --info ../xmonad-wayland_0.1.0-1_*.deb
dpkg-deb --contents ../xmonad-wayland_0.1.0-1_*.deb
```

The Debian package recommends `river (>= 0.4)` rather than requiring a particular
packaged compositor, allowing River built separately from source. This is an
installation convenience, **not** support for running without compatible River.
On a release with only River 0.3, install a suitable newer River separately; an
older compositor cannot be made compatible by bypassing package dependencies.

## Fedora and openSUSE RPM

`packaging/rpm/xmonad-wayland.spec` is a shared local recipe. It declares GHC's
individual boot-library development packages, Wayland pkg-config providers,
GCC, make and Python 3. No public project URL or remote source download is
invented. Supply the release archive locally and install the declared
BuildRequires with your distribution's package tools.

```sh
mkdir -p ../rpm-build/BUILD ../rpm-build/BUILDROOT ../rpm-build/RPMS
mkdir -p ../rpm-build/SOURCES ../rpm-build/SPECS ../rpm-build/SRPMS
cp ../xmonad-wayland-0.1.0.tar.gz ../rpm-build/SOURCES/
rpmbuild --define "_topdir $(cd ../rpm-build && pwd)" \
  -ba packaging/rpm/xmonad-wayland.spec
```

The RPM has `Requires: river >= 0.4`. Fedora's current package index lists River
0.4.8 for Fedora 44/45; Fedora 43's old River branch is not sufficient. Check
the active repository before installation. On openSUSE, inspect the selected
Tumbleweed/Leap repository for a compatible River and GHC; no openSUSE runtime
validation is claimed. [Fedora River packages](https://packages.fedoraproject.org/pkgs/river/river/)

## Arch local-source package

The PKGBUILD is restricted to x86_64, the architecture documented by the
available official GHC packages. It includes `ghc-static`: Arch splits static
boot libraries from the compiler. [Arch ghc-static](https://archlinux.org/packages/extra/x86_64/ghc-static/)

```sh
cp ../xmonad-wayland-0.1.0.tar.gz packaging/arch/
cd packaging/arch
updpkgsums
makepkg -s
```

`updpkgsums` comes from `pacman-contrib`. It replaces the explicitly marked local
`SKIP` bootstrap value with the digest of your archive. Verify the archive against
the supplied release checksums before recording this digest. No remote source
or AUR publication is configured. Runtime dependencies require River >= 0.4.

## Alpine local-source package

The APKBUILD targets x86_64 and needs a repository with suitable GHC and River
versions. It declares both `ghc` and `ghc-dev`, plus `wayland-dev`, which supplies
the scanner. Prepare your normal unprivileged abuild environment and signing
key following Alpine's package-building instructions, then:

```sh
cp ../xmonad-wayland-0.1.0.tar.gz packaging/alpine/
cd packaging/alpine
abuild checksum
abuild -r
```

The initially empty checksum list must be populated by `abuild checksum`; no
digest is fabricated. The package metadata's `file:` URL points to its installed
local README because this prototype has no published homepage. This local
recipe is not submission-ready aports metadata. Alpine edge's package index
contains River 0.4.x; do not assume an older stable branch does.
[Alpine River](https://pkgs.alpinelinux.org/package/edge/community/x86_64/river),
[Alpine GHC development files](https://pkgs.alpinelinux.org/package/edge/community/x86_64/ghc-dev),
[abuild guide](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package)

## FreeBSD local port and other BSD systems

The directory `packaging/freebsd` is a local port recipe using the system ports
framework. It fetches no remote archive. With a current ports tree and compatible
dependencies installed, use a private distfiles directory to generate real
`distinfo` from the archive:

```sh
mkdir -p ../freebsd-distfiles
cp ../xmonad-wayland-0.1.0.tar.gz ../freebsd-distfiles/
xw_distdir=$(cd ../freebsd-distfiles && pwd)
cd packaging/freebsd
make DISTDIR="$xw_distdir" makesum
make DISTDIR="$xw_distdir" test stage package
```

These are FreeBSD `make` commands: the ports framework invokes GNU make for the
project. `stage` does not install the package on the host. Current FreeBSD ports
provide River >= 0.4, but quarterly repositories can differ. This port recipe and
a real River session still require native verification; a Linux-built binary
does not run as a native FreeBSD package.
[FreeBSD River port](https://cgit.freebsd.org/ports/tree/x11-wm/river),
[FreeBSD port testing](https://docs.freebsd.org/en/books/porters-handbook/testing/)

OpenBSD current has River 0.4.5 in ports. No OpenBSD binary or tested package
recipe is supplied. Install matching GHC >= 9.0, gmake, pkgconf, Wayland headers
and scanner, and Python 3; then use the generic source commands with `gmake`.
Set `PYTHON` to the installed versioned Python command if no `python3` alias is
available. Check seat access and session startup against OpenBSD's River package
documentation. Compilation and runtime remain unverified here.

NetBSD and DragonFly BSD remain unverified. The existence of Wayland or GHC
packages is insufficient to claim that River's current compositor stack works
there. No working package, compositor port, or hardware-session support is
claimed for either system.

## Guix: manager build, compositor supplied separately

```sh
guix build -f packaging/guix/guix.scm
```

The recipe imports the local source tree with `local-file`, uses Guix's GHC 9.2,
Wayland and Python, deletes the unused configure phase, and runs `make test`.
It does not rely on an invented release URL or fixed-output hash. Start from a
clean source extraction; generated build/stage directories are excluded.
[Guix local-source build pattern](https://guix.gnu.org/cookbook/en/html_node/Building-with-Guix.html)

This builds **only the manager**. Some Guix revisions still provide River 0.3.12,
which is incompatible. The recipe deliberately does not propagate that package
and does not select an unknown third-party channel for you. Before attempting a
session, obtain River >= 0.4 from a suitable channel, a current compatible Guix
package, or a separately managed installation and confirm `river -version`.

To install the manager into the current user's profile:

```sh
guix package -f packaging/guix/guix.scm
```

The manager and compatible River must both be on the session's `PATH`. Guix
System display-manager discovery and seat/session configuration are separate
tasks; this recipe does not declare an operating-system service or change your
system configuration. The Guix recipe has not been evaluated or built here, and
there is no claim of a working Guix desktop session.

## Downloaded development binaries

The release includes `xmonad-wayland_0.1.0-1_amd64.deb` and
`xmonad-wayland-0.1.0-1.x86_64.rpm`. Both are Linux x86_64 development builds
made in an Ubuntu 24.04 environment, requiring glibc >=2.38. They have not been
installed into a native Debian/Fedora desktop. Use the source recipe for older
systems, other architectures, Alpine/musl and every BSD.

After verifying `SHA256SUMS`, an appropriate Debian/Ubuntu system can install
the local `.deb` with `sudo apt install ./xmonad-wayland_0.1.0-1_amd64.deb`.
For a suitable Fedora system, use
`sudo dnf install ./xmonad-wayland-0.1.0-1.x86_64.rpm`.
Package installation does not validate or start a River session. Read the
platform matrix and keep your existing window manager available.

## Haskell configuration

Edit `examples/Main.hs`, which uses this port's Config and Runtime modules.
From the extracted source directory, build your selected configuration with:

```sh
make MAIN=examples/Main.hs
```

This replaces only `build/xmonad-wayland` in the source tree. To install that
configuration, keep passing the same selection:

```sh
make install MAIN=examples/Main.hs PREFIX="$HOME/.local"
```

To rebuild the supplied defaults, use `make MAIN=app/Main.hs`. The current API
configures terminal/launcher argv and layout defaults; keyboard bindings and
border colors live in `cbits/bridge.c`. There is no automatic config compilation
or state-preserving reload. Existing X11 `xmonad.hs` files need a manual port.

## Uninstall

For a source installation, use the same prefix as the original install:

```sh
make uninstall PREFIX="$HOME/.local"
```

For managed packages, use the package manager, for example
`sudo apt remove xmonad-wayland`, `sudo dnf remove xmonad-wayland`, or
`guix remove xmonad-wayland`. Removal does not delete user configuration or
remove an independently installed compositor.
