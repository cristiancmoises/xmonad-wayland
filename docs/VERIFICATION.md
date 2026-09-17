# Verification

Version 0.3.0 is being developed on GNU Guix. This record distinguishes
completed checks from the checks needed before replacing a daily desktop.
Commands produce fresh results; the presence of a recipe or test is not a pass.

## Automated checks

```sh
make CC=gcc test
```

The suite covers window policy, protocol lifetimes, manage/render boundaries,
subprocess cleanup, keymap validation, reload, confirmed exit and launcher
behavior, including repeated termination signals and applications that ignore
TERM after the manager exits. Policy runs include 15,000 general events and 12,000 Sway-oriented
events, plus 7,500 pointer-policy events and directed geometry, transient,
fullscreen, output and lock cases. The source-export tests check that private material stays outside archives.

The unchanged upstream StackSet produces an unused-import warning with the
host's GHC 9.10.2. The C bridge builds with `-Wall -Wextra -Werror`. The Guix
recipe uses its pinned GHC and runs the package test target.

## Actual River sessions

```sh
make CC=gcc all build/xdg-probe
python3 tests/river_smoke.py --river /path/to/river
```

The integration harness creates its own compositor and clients. It checks two
outputs, Foot, Fuzzel, transient/fixed-size dialogs, fullscreen transitions and
window destruction. It needs Foot, Fuzzel and Wayland protocol XML in addition
to the compiled manager. Use `--backend wayland --renderer gles2` for a nested
trial in an existing Wayland session with a compatible accelerated River build.
The default is an isolated headless pixman session.

Completed Guix trials include real River 0.4.8 headless and nested sessions. A
machine-specific River build using the existing NVIDIA package transformation
also passed the nested GLES2 test on an RTX 4060. The ordinary Mesa closure
failed that NVIDIA initialization, so selecting an EGL environment variable
alone is not presented as a fix.

The real pointer harness also exercised Super+button movement, corner resizing
and client-side resize requests in an isolated River session. These tests use
virtual input; they do not inject keys into the host desktop.

The local Sway-derived profile has 74 keyboard bindings. The unused Super+o
binding was deliberately removed; other conflicts follow the active Sway
configuration. The user confirmed a visible Kitty terminal and Super+Enter
opening another terminal inside River. Separate automated checks verified the
ABNT2 keymap, window operations, private diagnostics and owned-process cleanup.
These checks do not establish physical keyboard/touchpad behavior.

The README screenshots are unedited captures of controlled nested sessions.
Only prepared demonstration terminals appear in them. They demonstrate actual
window placement, not physical-session acceptance or test results.

## Guix packaging

`./scripts/guix-build` authenticates the pinned official channel and builds River
and the manager with tests enabled. Source pins and licensing are recorded in
[the source inventory](../packaging/guix/SOURCES.md). The [Guix recipe notes](../packaging/guix/README.md)
explain the channel pin, optional input daemon and NVIDIA package transformation.

Local build, lint and style checks have passed on the earlier deployed snapshot.
Every new source change needs a fresh build before deployment. Network source
and vulnerability checks have also encountered timeouts; local lint does not
replace those remote checks. Public homepage/release metadata remains pending
publication. No source origin or public package URL is invented for this local
`local-file` recipe.

## Remaining acceptance

Physical DRM/seat access, monitor hotplug/scaling, touchpad behavior,
suspend/resume, screen-lock recovery and sustained daily use remain unverified.
Testing currently stays inside Sway at the user's request. The replacement
system configuration remains a candidate and has not been activated.

The present target is GNU Guix. Earlier experiments with other distributions are
outside this release scope. No production, external security audit, upstream
endorsement or arbitrary XMonad/contrib compatibility is claimed.
