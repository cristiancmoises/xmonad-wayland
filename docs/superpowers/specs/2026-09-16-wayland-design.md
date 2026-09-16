# XMonad Wayland 0.1.0 design

This is an independent experimental port of XMonad's pure window-management core,
not an upstream release or a claim of full XMonad/contrib compatibility.

## Decision

Retain the unmodified BSD-licensed XMonad 0.18.1 StackSet. Add a Haskell policy
layer and a small libwayland-client C bridge implementing River's stable window
management and XKB binding protocols. River >=0.4 provides the compositor,
rendering, device access, XWayland and session locking infrastructure. River
classic/0.3 is incompatible. No direct wlroots dependency in this project.

A direct wlroots compositor would duplicate display-server work and bind us to
unstable wlroots APIs. Reviving Waymonad would require a separate modernization
of its old bindings. The River approach is selected for an executable first port.

## Initial behavior

Nine workspaces, genuine StackSet focus/swap/shift semantics, Tall/Mirror/Full
layouts, per-workspace ratios, output add/remove, focus-follow-click, keyboard
shortcuts, configurable Haskell defaults, cyan borders. Pure policy has no X11
imports. One logical keyboard focus; independent multiseat policy is excluded.
Existing arbitrary xmonad.hs and XMonad.Contrib modules are not compatible.
Floating windows, panels/reserved areas, manage hooks, stateful hot reload and
client fullscreen requests remain explicitly unimplemented in this first release.

## C / Haskell boundary

All IDs are uint32_t, all coordinates and event arguments int32_t.
Haskell exports `xw_event(kind,id,a,b,c,d)` called on the Wayland event thread.
Events: 1 output upsert(id,x,y,w,h); 2 output removed; 3 window added;
4 window removed; 5 focus request(window id); 6 action(id=action,a=argument);
7 manage start; 8 render start; 9 locked; 10 unlocked.
Actions: 1 focus next, 2 focus previous, 3 swap master, 4 next layout,
5 shrink, 6 expand, 7 view(argument 1..9), 8 shift(argument 1..9),
9 close, 10 terminal, 11 launcher, 12 stop WM, 13 swap next, 14 swap previous.

C exports `int xw_run(void)`, `void xw_set_window(uint32_t id,int visible,
int x,int y,int width,int height,int focused)`, `void xw_focus(uint32_t id)`
(0 clears focus), `void xw_close(uint32_t id)`, `void xw_stop(void)`.
Rectangles are outer tile allocations; the C bridge insets content for 2px
borders, using zero border for allocations with width or height <=4 pixels.
During event 7 Haskell applies policy and calls setters; during event 8 C applies
saved rendering coordinates/borders without sending manage-only requests.
Callbacks never expose application titles to command execution. Spawn uses argv.
Binding and lifecycle changes obey manage/render phase constraints. Window and
output handles remain valid until removal has been propagated at a manage cycle.

## Packaging and evidence

Build with GHC >=9.0, boot libraries base/containers/transformers/process,
wayland-scanner >=1.20 and libwayland-client >=1.20. Use GNU make with DESTDIR.
Produce source tarball, locally built Debian-format development package when
possible, Debian/Fedora/Arch/Alpine/openSUSE/FreeBSD/Guix recipes. Never pass off
recipes as tested packages. NetBSD/OpenBSD/DragonFly each get explicit status.
Guix uses local-file source, not a fabricated origin hash. Packages must not
overwrite XMonad, a display manager, river/init or user configuration.

## Verification

Compile both languages, test StackSet actions and geometry invariants, drive the
real executable with a synthetic Wayland protocol server to verify lifecycle and
phase ordering. Inspect package contents and dependencies. A protocol fixture is
not a real River/GPU test. Report that distinction in verification documentation.
