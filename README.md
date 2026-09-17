# XMonad Wayland

[Português do Brasil](README.pt-BR.md)

A Haskell window manager for **River 0.4+**, using XMonad's unmodified StackSet
for window order, focus and workspaces. River handles graphics, input and
Wayland/XWayland clients; this project supplies the window-management policy.

**0.2.0-dev is a development release for GNU Guix.** Since September 2026 it
runs in a real River login session on a Predator Helios laptop (NVIDIA RTX 4060
plus Intel) through the SecurityOps channel, and in nested sessions for trying
it out on any Wayland desktop. Daily-use acceptance — suspend/resume, monitor
hotplug, screen locking — is still being evaluated. This is an independent
project, not an official XMonad release; existing X11 `xmonad.hs` files and
arbitrary `xmonad-contrib` modules are not compatible.

![XMonad Wayland running on River](screenshots/river-xmonad-fastfetch.png)

Unmodified capture from the real laptop session: a terminal running fastfetch
with the manager and compositor detected.

## Try it on Guix

From the project directory, as your normal user:

```sh
./scripts/guix-build
./run.sh --doctor
./run.sh --nested
```

Run the last command inside an existing **Wayland** desktop. River opens in a
nested window with a Foot terminal. Click it, then press **Super+Return** for
another terminal or **Super+p** for Fuzzel. Super means the Windows/logo key.

Inside Sway, shortcuts are forwarded while the River window has focus.
**Ctrl+Alt+Escape** returns control to Sway; leave and refocus River to capture
again. Other outer compositors may need their own shortcut setup. Close the
River window when finished. The launcher prints a private diagnostics directory.
See the [installation guide](docs/INSTALL.md) for NVIDIA setup and troubleshooting.

The build script uses pinned Guix dependencies and River 0.4.8, runs package
tests, and creates `build/guix-runtime` with the manager, River, Foot, Fuzzel
and fonts. It leaves your default profile, channels and login session unchanged.
The first build can take a while; it prints the build-log path.

## Default keyboard controls

These are the **generic defaults**, with nine workspaces. The separately
configured Guix laptop profile has 74 Sway-derived bindings and different
commands; installing the generic package does not import that profile.

| Shortcut | Action |
| --- | --- |
| Super+Return | Open Foot |
| Super+p | Open Fuzzel |
| Super+j / k | Focus next / previous window |
| Super+Shift+j / k | Swap with next / previous window |
| Super+Shift+Return | Swap with the master window |
| Super+Space | Cycle Tall, Mirror and Full layouts |
| Super+h / l | Shrink / grow the master area |
| Super+1…9 | View a workspace |
| Super+Shift+1…9 | Move the focused window and its transient children |
| Super+period / comma | Focus next / previous monitor |
| Super+t | Toggle floating |
| Super+f | Toggle fullscreen |
| Super+Shift+c | Ask the focused application to close |
| Super+Shift+q | Stop the manager |

Stopping the manager is neither logout nor screen lock. River and applications
remain running. Run `xmonad-wayland` in a terminal inside that River session to
resume management.

## Configuration and current limits

A custom Haskell entrypoint can select commands, keyboard modes, workspaces,
cursor settings and layouts. An optional reloadable configuration preserves
open windows while updating bindings. See [configuration](docs/CONFIGURATION.md).
The generic executable does not automatically read `~/.xmonad/xmonad.hs` or the
laptop profile's editable bindings.

Available layouts include Tall, Mirror, Full, Columns, Rows, Tabbed and Stacking.
The manager supports multiple outputs, transient dialogs, fullscreen and layer
surfaces such as Fuzzel. Tabbed/Stacking do not draw tab headers, and layouts
operate on whole workspaces rather than Sway's nested container tree.

A physical session has been running on the maintainer's laptop since September
2026 (direct NVIDIA DRM output included). Suspend/resume, monitor hotplug,
screen locking and long-term daily use are still being evaluated. Input
configuration, notifications, portals, wallpaper and locking need separate
session setup. Independent multiseat policy and layout persistence across
manager restarts are not implemented.

## License and source

The project uses the **BSD 3-Clause license**, the same license as XMonad.
Vendored StackSet retains its upstream copyright and license. River protocol
XML files retain their MIT license. See [LICENSE](LICENSE),
[source provenance](docs/PROVENANCE.md) and [security boundaries](docs/SECURITY.md).
