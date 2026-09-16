# XMonad Wayland — experimental 0.1.0

An independent native Wayland port of **XMonad's real Haskell StackSet core**,
using **River 0.4 or newer** as the compositor. This is a development release,
not an official XMonad release, a finished replacement, or xmonad-contrib compatibility.

The unchanged upstream StackSet manages window order, focus and workspaces.
New Haskell code manages layouts and translates state to River's native Wayland
window-management protocol through a small C/libwayland-client bridge. There is
no X11 connection in this manager. River handles rendering and devices; X11
applications require River's optional XWayland support.

## What is implemented

- Nine workspaces, focus cycling, swap master, swap next/previous and move windows.
- Tall, Mirror and Full layouts, with a separate layout/ratio per workspace.
- Output addition/removal and preservation of windows when outputs disappear.
- Click-to-focus and keyboard bindings on the oldest live seat.
- Haskell configuration of terminal, launcher and layout defaults.
- Cyan focus borders and no desktop shell assets/background service.
- Debian, RPM, Arch, Alpine, FreeBSD and Guix packaging materials.

## Build

Install GHC >=9.0 with its `base`, `containers`, `transformers` and `process`
libraries, a C compiler, GNU make, pkg-config, Wayland headers and wayland-scanner
>=1.20, and Python 3 for integration tests. No Cabal/Hackage network download is
needed during the build.

```sh
make check-deps
make -j2
make test
make install PREFIX="$HOME/.local"
```

Ensure `$HOME/.local/bin` is on PATH. See [installation and packaging](docs/INSTALL.md)
for distribution-specific commands, Guix, BSDs, and uninstall instructions.

## Run safely

Keep your existing desktop session available. From a terminal in that session,
with a compatible River already installed, run:

```sh
xmonad-wayland-session
```

River can run nested; this is the recommended first real desktop test. The
launcher uses `river -c 'exec xmonad-wayland'` and does not overwrite `river/init`.
To use an existing River 0.4 session whose window manager has stopped, run
`xmonad-wayland` directly in that session. A compositor with no required River
protocol globals is rejected with an explanatory error. Sway, Hyprland, Weston
and river-classic cannot host this backend.

An optional display-manager entry is installed as **XMonad Wayland (Experimental)**.
Package installation does not select that session, stop your desktop or change
your default display manager. Guix does not automatically discover this entry;
its system/session integration must be configured separately.

## Keys

| Shortcut | Action |
|---|---|
| Super+Return | Start terminal (default `foot`) |
| Super+p | Launcher (default `fuzzel`) |
| Super+j / k | Focus next / previous |
| Super+Shift+j / k | Swap next / previous |
| Super+Shift+Return | Swap focused window with master |
| Super+Space | Tall → Mirror → Full |
| Super+h / l | Shrink / grow master area |
| Super+1…9 | View workspace |
| Super+Shift+1…9 | Move focused window to workspace |
| Super+Shift+c | Ask focused application to close |
| Super+Shift+q | Stop this window manager; River remains running |

Stopping the manager leaves applications alive but without its management/key
bindings. In a nested test, restart the manager from another River terminal or
close the nested compositor from the host session. **Stop is not a screen lock.**

## Compatibility limits

- Existing `xmonad.hs`, XMonad's X11 monad and arbitrary `xmonad-contrib` modules
  are not source-compatible. Only StackSet is directly reused.
- No floating/dialog policy, panels or reserved layer-shell areas, manage hooks,
  client fullscreen/maximize requests, status bar, clipboard UI, session-lock
  launcher, layout persistence or hot reload in this release.
- Keyboard bindings and borders currently live in the C bridge; Haskell config
  covers commands and layout defaults. Recompile to change configuration.
- Up to nine outputs have separate workspaces; excess outputs remain unassigned.
- Independent multiseat policies are not implemented.
- Protocol simulation does not prove DRM/GPU behavior, real application
  integration, BSD execution, or native distribution installation.

See [verification](docs/VERIFICATION.md), [platform status](docs/PLATFORMS.md),
[security model](docs/SECURITY.md), and [upstream provenance](docs/PROVENANCE.md).
The requested reusable execution prompt is [GOD-TIER-PROMPT.md](GOD-TIER-PROMPT.md).

## Next acceptance gates

1. Run nested River with at least three real Wayland applications; test focus,
   workspace movement, dialogs, resizing and compositor restart.
2. Validate monitor hotplug and scaling on Linux graphics hardware and the
   separate BSD input/session stacks.
3. Add float/transient policy, client fullscreen requests and panel reservation.
4. Build/install the native recipes in clean distro/Guix/BSD environments.
5. Add a migration layer for selected XMonad configuration and contrib modules.

BSD-3-Clause for new code and XMonad StackSet; MIT for vendored River protocol XML.
This project is not affiliated with or endorsed by XMonad or River maintainers.
