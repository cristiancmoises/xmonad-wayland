# Install and run on GNU Guix

[Português do Brasil](INSTALL.pt-BR.md) · [Project overview](../README.md)

Version **0.2.0-dev** is for development and testing. Start inside an existing
Wayland desktop. On the maintainer's laptop a physical River login session has
been running since September 2026; the steps below document the portable,
nested way of trying the manager anywhere.

## Build the local profile

You need a working Guix installation with access to its build daemon, this source
checkout and internet access for uncached dependencies. Run these commands from
the project directory as your normal user:

```sh
./scripts/guix-build
./run.sh --doctor
```

The script authenticates the Guix revision in `packaging/guix/channels.scm`, builds
the pinned River 0.4.8 and the manager from your current checkout, and runs their
package tests. It creates:

| Path | Contents |
| --- | --- |
| `build/guix-river` | River output, kept as a garbage-collector root |
| `build/guix-manager` | Manager output, kept as a garbage-collector root |
| `build/guix-runtime` | Dedicated profile with both programs, Foot, Fuzzel and fonts |

Your default Guix profile, channel configuration and login session are not
changed. `--doctor` checks executable availability, versions and the session
runtime directory; it does not start River or certify graphics support.
The script prints its log path under `evidence/`. These are locally generated
build records, not files required by the published source.

To limit build concurrency or omit the combined application profile:

```sh
GUIX_BUILD_CORES=2 ./scripts/guix-build
./scripts/guix-build --build-only
```

`--build-only` requires you to supply your terminal and launcher separately.
Run the full command again after editing the source to rebuild the dedicated
profile. It uses the pinned channel without running `guix pull` on your profile.

## Open a nested session

Inside your current Wayland desktop:

```sh
./run.sh --nested
```

River opens in a separate window with a Foot terminal. The launcher chooses
the Wayland backend and a private runtime directory. Click the River window,
then use **Super+Return** for another Foot or **Super+p** for Fuzzel.

When the outer desktop is Sway, a temporary mode forwards shortcuts only while
this River window is focused. **Ctrl+Alt+Escape** releases them. To capture again,
focus another window and return to River. Existing Sway bindings and files are
preserved. Other compositors may still intercept Super shortcuts.

Python 3 is included by the Guix package for nested process supervision. To use
another installed terminal for initial startup, set `XMONAD_WAYLAND_TERMINAL` to
one executable path. It is treated literally, without arguments or shell syntax.
This setting is separate from the Haskell `terminalCommand` shortcut.

The launcher prints a diagnostics path under `$XDG_STATE_HOME/xmonad-wayland`
(default `~/.local/state/xmonad-wayland`). Each session gets a private directory
and separate River, manager, terminal and Sway-helper logs. Interactive Wayland
protocol tracing is disabled; the logs do not record keystrokes.

Close the nested River window through the outer desktop to finish. The generic
Super+Shift+q shortcut stops only the manager, leaving River and applications
running; it is not a logout or lock action.

The machine-specific launcher named `xmonad-wayland-river` is separate from this
generic `run.sh`/`xmonad-wayland-session` workflow. Its 74 custom Sway-derived
bindings, automatic Kitty and Channel input rules belong to that local
deployment. The generic package provides its own terminal startup, private logs
and Sway forwarding, with the generic keyboard defaults.

## Physical sessions and NVIDIA

From a separate text-console login with working seat/device permissions and a
valid `XDG_RUNTIME_DIR`, `./run.sh` can start River directly. Configure those
permissions and your graphics stack through your Guix system configuration.
The launcher refuses root; running it with sudo is not a setup step.

The generic package neither configures a display manager nor selects a default
session. It does not supply input-device rules, automatic locking, notifications,
clipboard management, portals or a complete desktop service. Configure and test
these separately before replacing your existing session.

Proprietary NVIDIA Guix systems need a River package built with the same
Mesa-to-NVIDIA transformation as the rest of their graphics stack. Selecting an
EGL vendor JSON file alone does not replace linked Mesa libraries. A separate
machine configuration has passed accelerated nested tests with that
transformation; the generic free-software profile does not apply it. Direct DRM
output, physical input, hotplug and suspend/resume remain acceptance checks.

## Configure and diagnose

The generic defaults are Foot, Fuzzel and nine workspaces, as listed in the
[README](../README.md#default-keyboard-controls). A custom Haskell entrypoint can
change them and add reloadable bindings. Follow [configuration](CONFIGURATION.md)
for the API; an existing X11 `xmonad.hs` cannot be used unchanged.

| Symptom | What to check |
| --- | --- |
| `guix` is missing or the daemon is unreachable | Confirm that the Guix installation can build packages before running the project script. |
| Missing or incompatible River | Run the full build script. River 0.3 and river-classic cannot host this manager. |
| Invalid `XDG_RUNTIME_DIR` | Start from a normal logged-in session with its own writable runtime directory. |
| Empty nested window | Check terminal.log in the printed diagnostics directory; verify the configured initial terminal and Sway forwarding. |
| Renderer fails before a window appears | Read the launcher's terminal output and check the Guix graphics stack, especially Mesa/NVIDIA linkage. |
| Terminal or launcher unavailable | Use the full profile build or configure installed commands; `--build-only` omits these applications. |

Build failures remain in the log printed by `guix-build`; renderer and manager
diagnostics for nested sessions stay in the printed private directory. Further details are in
[Guix packaging](../packaging/guix/README.md),
[security boundaries](SECURITY.md) and [source provenance](PROVENANCE.md).
