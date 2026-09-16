# XMonad Wayland implementation plan

**Goal:** deliver an experimental native Wayland port of XMonad's StackSet core
with honest platform packaging and executable verification.
**Architecture:** Haskell owns policy, a C bridge owns Wayland objects, River
owns composition. The boundary is specified in the accompanying design.
**Tech stack:** GHC, C11, libwayland-client, GNU make, Python integration tests.
**Spec:** ../specs/2026-09-16-wayland-design.md

## Global constraints

Keep vendored StackSet unchanged; preserve BSD/MIT notices. Require River >=0.4,
never river-classic. No privileged installation or modifications to user configs.
Haskell callbacks and C exports use the exact interface in the design.

## Tasks

- [x] Vendor pinned protocol XML and StackSet with license/provenance hashes.
- [x] Implement pure `XMonad.Wayland.Policy` and `Layout` with tests covering
  unique windows, view/shift, focus cycles, close, output removal, tiny/odd output
  geometry and layout changes. Run with `make test`.
- [x] Implement C event bridge and Haskell runtime. During manage cycles propose
  sizes and focus, during render cycles position nodes. Fail clearly when no
  River WM or binding global exists. Map/remove proxy lifecycles safely.
- [x] Generate bindings with `wayland-scanner client-header` and `private-code`,
  build using `make`, and verify a simulated compositor transaction with
  `python3 tests/protocol_smoke.py build/xmonad-wayland`.
- [x] Add DESTDIR installation, examples, Debian/RPM/Arch/Alpine/FreeBSD/Guix
  source recipes and support matrix. Build packages possible in this environment.
- [x] Independent code review; resolve concrete correctness defects; rerun
  affected checks. Record actual evidence and residual real-compositor gap.
- [ ] Archive source and prompt, produce SHA256SUMS, persist deliverables.
