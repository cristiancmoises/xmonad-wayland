# Execution prompt: XMonad on Wayland

Act as a senior Haskell, Wayland and Unix packaging engineer. Port XMonad's real
pure StackSet semantics to native Wayland without pretending that XWayland makes
an X11 window manager a Wayland window manager. Research current upstream APIs
and platform availability before selecting an architecture.

Use a separate Haskell window manager on River >=0.4 as the first backend. Keep
the upstream StackSet module unchanged and preserve its license and provenance.
Implement a small C/libwayland bridge with generated, pinned protocol bindings.
Keep focus, window ordering, workspaces and layout policy in Haskell. Respect
manage/render transactions, closed object lifetimes, keyboard event ordering,
output hotplug, and failed compositor connections. Do not run shell commands
constructed from window metadata. Fail explicitly when required globals or
runtime dependencies are absent.

Deliver an executable experimental release with Tall, Mirror and Full layouts,
nine workspaces, focus/swap/shift shortcuts, Haskell configuration and examples.
Use tests that check behavioral properties and drive the actual executable over
a Wayland socket. Preserve existing XMonad sessions and user configuration.

Provide source and native build recipes for Debian/Ubuntu, Fedora/RHEL family,
openSUSE, Arch, Alpine, GNU Guix and feasible BSDs. Verify dependency versions;
do not invent Guix hashes or upstream release URLs. Distinguish built packages,
compiled code, protocol tests, recipes, real desktop tests and unsupported hosts.
Never claim compatibility with arbitrary xmonad.hs or xmonad-contrib.

Include exact build/install/uninstall commands, BSD constraints, security model,
upstream licenses, checksums, a verification report and next development gates.
Execute the work now, making reversible implementation choices autonomously.
Never represent an experimental port as finished production software. Continue
until the deliverable is reviewable and report any blocked acceptance criteria.
