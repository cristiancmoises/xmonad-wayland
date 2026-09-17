# Haskell policy and reloadable bindings

[Português do Brasil](CONFIGURATION.pt-BR.md)

The generic executable keeps the XMonad-style defaults listed in the README.
A custom `Main.hs` can change `workspaceIds`, `keyBindings`, commands, layout,
master ratio and cursor theme/size. Build with `make MAIN=/path/to/Main.hs`.
The API is separate from XMonad's X11 API and `xmonad-contrib`.

`XMonad.Wayland.Keymap` supplies `key`, `modeKey`, `keySym`, modifier constants
and common special keysyms. Modifiers are River's protocol bitmask, and keysyms
use XKB values. For example:

```haskell
key (keySym 'l') super CycleSwayLayout
key (keySym 't') super FocusModeToggle
key (keySym 'r') (super + shift) (EnterMode ResizeMode)
modeKey ResizeMode keyLeft 0 (Resize Width (-10))
modeKey ResizeMode keyEscape 0 (EnterMode NormalMode)
```

Normal and resize bindings are separate modes. The runtime rejects duplicate
chords within a mode, unknown modifier bits, invalid workspace lists and bindings
referring to unknown workspaces. Changing workspace IDs requires restarting the
manager; a reload rejects that change and retains the current configuration.

Use `runWithReload initialConfig loader` to provide a reload action. The loader
returns a validated `Config`; `readConfig path` reads the `Read`/`Show` text form.
`show config` produces that form. The `Reload` action replaces bindings and
commands and updates the cursor, preserving windows, focus, floating geometry,
workspace membership, active mode and existing per-workspace layout/ratio state.
`run config` uses a constant loader, so its reload action reloads the same value.
Invalid files retain the old configuration and report the error on stderr.
The text format is version-specific; keep a backup when upgrading.

Commands use `Command executable [argument, ...]`. Pipelines, `$()` and `~`
expansion require an explicit shell, for example `Command "sh" ["-c", "..."]`.
Only trusted configuration should supply these commands. Application titles and
IDs are never interpreted as shell programs.

`ConfirmExit (Command "fuzzel" ["--dmenu"])` provides the entries `Cancel` and
`Exit`. Only successful output exactly equal to `Exit` followed by a newline
requests River session exit. Escape, empty output, failure and other text cancel.
The runtime refuses session exit when the compositor lacks protocol version 4.
The separate `Stop` action stops only the manager; it is neither logout nor lock.

# Sway-style layouts

`Columns` and `Rows` distribute the workspace's tiled windows horizontally or
vertically. `Tabbed` and `Stacking` show the selected tiled window; they currently
share geometry and do not draw Sway's tab/stack titlebars. `CycleSwayLayout` cycles
split, tabbed and stacking. `ToggleSplit` switches horizontal/vertical splits.
Directional focus uses geometry; directional movement swaps tiles or transfers
a window family to a neighboring output. Floating movement/resizing uses pixels.

These actions preserve useful Sway shortcut intents but do not implement Sway's
nested container tree. Splitting and changing layout apply to the workspace.
Titlebar tabs and exact nested-container movement remain missing. This distinction
matters before replacing an existing Sway setup.

Hold Super and drag the left mouse button to move a floating window; use the
right button to resize from the nearest corner. Client-side move/resize requests
also work. Release the mouse button to finish, even if Super was released first.
The operation stays within its starting output's work area and accepts only
already-floating windows fully inside that area. It does not turn tiles into
floating windows or drag windows between monitors. Fullscreen, window/output
removal, focus conflicts and session lock cancel the grab safely.

# Layer surfaces and desktop services

When River advertises `river_layer_shell_v1`, the manager binds it, enables layer
surfaces such as Fuzzel, respects panel work-area reservations, and handles layer
keyboard focus. Fullscreen windows use the physical output rectangle. The tests
exercise protocol work areas and an actual Fuzzel surface; no complete panel or
portal desktop is bundled. Notifications, wallpaper, input configuration, session
locking and portals require separate programs and session configuration.

# Migrating an xmonad.hs from X11

X11 users keep their config idiom on Wayland. Write `~/.xmonad/xmonad.hs`:

```haskell
import XMonad.Wayland.XConfig

main :: IO ()
main = xmonad $ def
  { modMask    = mod4Mask
  , terminal   = "kitty"
  , workspaces = ["1" .. "9"]
  , layoutHook = tall ||| mirror ||| full
  , keys       = [ ((mod4Mask, xK_Return), spawn "kitty")
                 , ((mod4Mask, xK_j), focusNext)
                 , ((mod4Mask, xK_k), focusPrevious)
                 ]
  , startupHook = [startup "swaybg -i ~/wallpaper.png"]
  }
```

Then run `xmonad-wayland --recompile`. The manager executes
`~/.xmonad/xmonad-wayland-bin` automatically at startup, and the `restart`
action re-executes it, exactly like XMonad's recompile flow. The command
uses the GHC and the installed sources recorded in the package; no shell
profile or `ghc` in PATH is needed.

Supported: `xmonad`, `def`, `XConfig`, `modMask`, `terminal`, `workspaces`
(numeric tags), `layoutHook` with `tall`, `mirror`, `full`, `columns`, `rows`,
`tabbed`, `stacking` and `(|||)`, `keys` as a list of `(mask, keysym)` chords,
the action helpers (`spawn`, `focusNext`, `focusPrevious`, `swapNext`,
`swapPrevious`, `swapMaster`, `nextLayout`, `shrink`, `expand`, `close`,
`toggleFloat`, `toggleFullscreen`, `nextOutput`, `previousOutput`, `viewWS`,
`shiftWS`, `restart`, `reload`, `stop`), the mask constants and the common
`xK_*` keysym names. `spawn` runs through `/bin/sh -c`, like XMonad.

Not supported in this release, and reported with a clear error instead of a
silent fallback: `xmonad-contrib` modules, X11 hooks, the `X ()` monad,
`manageHook`, non-numeric workspace tags and layouts with per-layout ratio
arguments. Cursor theme and size remain available in the advanced `Config`
API below.
