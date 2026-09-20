PREFIX ?= /usr/local
DESTDIR ?=
GHC ?= ghc
CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
PYTHON ?= python3
WAYLAND_PROTOCOLS_DIR ?= $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)
GHCFLAGS ?= -O2 -Wall -threaded
MAIN ?= app/Main.hs
CFLAGS ?= -O2 -g
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags wayland-client) -Ibuild -Icbits
LDLIBS += $(shell $(PKG_CONFIG) --libs wayland-client)
PROTOCOLS = river-window-management-v1 river-xkb-bindings-v1 river-layer-shell-v1 wlr-layer-shell-unstable-v1
HEADERS = $(addprefix build/,$(addsuffix -client-protocol.h,$(PROTOCOLS)))
OBJECTS = build/bridge.o $(addprefix build/,$(addsuffix -protocol.o,$(PROTOCOLS)))
HASKELL = $(shell find src app vendor -name '*.hs')
XWM_GHC_PATH ?= $(shell command -v $(GHC))
XWM_SRC_DIR ?= $(PREFIX)/share/xmonad-wayland/src
XWM_LDLIBS ?= $(shell $(PKG_CONFIG) --libs wayland-client)

.PHONY: all test test-policy test-protocol test-runtime test-session test-keymap test-sway-policy test-bindings-protocol test-source-archive test-pointer-policy test-pointer-protocol test-xconfig test-xconfig-sample install uninstall clean check-deps FORCE
all: build/xmonad-wayland

build:
	mkdir -p build

build/BuildInfo.hs: FORCE | build
	@printf '%s\n' 'module BuildInfo where' \
	  'ghcPath :: FilePath' 'ghcPath = "$(XWM_GHC_PATH)"' \
	  'srcDir :: FilePath' 'srcDir = "$(XWM_SRC_DIR)"' \
	  'bridgeObjects :: [FilePath]' \
	  'bridgeObjects = ["$(PREFIX)/share/xmonad-wayland/lib/bridge.o","$(PREFIX)/share/xmonad-wayland/lib/river-window-management-v1-protocol.o","$(PREFIX)/share/xmonad-wayland/lib/river-xkb-bindings-v1-protocol.o","$(PREFIX)/share/xmonad-wayland/lib/river-layer-shell-v1-protocol.o"]' \
	  'bridgeLibs :: [String]' 'bridgeLibs = words "$(XWM_LDLIBS)"' > $@

check-deps:
	$(PKG_CONFIG) --atleast-version=1.20 wayland-client
	$(WAYLAND_SCANNER) --version
	$(GHC) --numeric-version

build/%-client-protocol.h: protocols/%.xml | build
	$(WAYLAND_SCANNER) client-header $< $@

build/%-protocol.c: protocols/%.xml | build
	$(WAYLAND_SCANNER) private-code $< $@

build/%-protocol.o: build/%-protocol.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -c $< -o $@

build/bridge.o: cbits/bridge.c cbits/bridge.h $(HEADERS) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -Wall -Wextra -Werror -c $< -o $@

build/xmonad-wayland: $(HASKELL) $(MAIN) $(OBJECTS) build/BuildInfo.hs FORCE | build
	$(GHC) $(GHCFLAGS) -isrc -ivendor -ibuild -i$(dir $(MAIN)) -outputdir build/ghc $(MAIN) $(OBJECTS) $(LDLIBS) $(addprefix -optl,$(LDFLAGS)) -o $@

build/policy-test: tests/PolicyTest.hs $(HASKELL) | build
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/test-ghc tests/PolicyTest.hs -o $@

test-policy: build/policy-test
	./build/policy-test

test-protocol: build/xmonad-wayland
	$(PYTHON) tests/protocol_smoke.py ./build/xmonad-wayland

build/runtime-test/runtime-test: tests/RuntimeTest.hs tests/runtime_fixture.c $(HASKELL) | build
	mkdir -p build/runtime-test
	$(GHC) -Wall -Wno-unused-imports -Werror -threaded -isrc -ivendor -outputdir build/runtime-test tests/RuntimeTest.hs tests/runtime_fixture.c -o $@

test-runtime: build/runtime-test/runtime-test
	PYTHON="$(PYTHON)" sh tests/runtime_test.sh build/runtime-test/runtime-test

test-session:
	$(PYTHON) tests/session_test.py
	$(PYTHON) tests/sway_nested_input_test.py

build/keymap-test/keymap-test: tests/KeymapTest.hs $(HASKELL) | build
	mkdir -p build/keymap-test
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/keymap-test tests/KeymapTest.hs -o $@

test-keymap: build/keymap-test/keymap-test
	./build/keymap-test/keymap-test

build/sway-policy-test/sway-policy-test: tests/SwayPolicyTest.hs $(HASKELL) | build
	mkdir -p build/sway-policy-test
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/sway-policy-test tests/SwayPolicyTest.hs -o $@

test-sway-policy: build/sway-policy-test/sway-policy-test
	./build/sway-policy-test/sway-policy-test

build/bindings-protocol-test/bindings-protocol-test: tests/BindingsProtocolMain.hs $(HASKELL) $(OBJECTS) | build
	mkdir -p build/bindings-protocol-test
	$(GHC) $(GHCFLAGS) -isrc -ivendor -outputdir build/bindings-protocol-test tests/BindingsProtocolMain.hs $(OBJECTS) $(LDLIBS) $(addprefix -optl,$(LDFLAGS)) -o $@

test-bindings-protocol: build/bindings-protocol-test/bindings-protocol-test
	$(PYTHON) tests/bindings_protocol.py ./build/bindings-protocol-test/bindings-protocol-test

test-source-archive:
	$(PYTHON) tests/source_archive_test.py

build/pointer-policy-test/pointer-policy-test: tests/PointerPolicyTest.hs $(HASKELL) | build
	mkdir -p build/pointer-policy-test
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/pointer-policy-test tests/PointerPolicyTest.hs -o $@

test-pointer-policy: build/pointer-policy-test/pointer-policy-test
	./build/pointer-policy-test/pointer-policy-test

test-pointer-protocol: build/xmonad-wayland
	$(PYTHON) tests/pointer_protocol.py ./build/xmonad-wayland

build/xconfig-test/xconfig-test: tests/XConfigTest.hs $(HASKELL) $(OBJECTS) | build
	mkdir -p build/xconfig-test
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/xconfig-test tests/XConfigTest.hs $(OBJECTS) $(LDLIBS) $(addprefix -optl,$(LDFLAGS)) -o $@

test-xconfig: build/xconfig-test/xconfig-test
	./build/xconfig-test/xconfig-test

test-xconfig-sample:
	$(GHC) -isrc -ivendor -fno-code tests/sample-xmonad.hs

test: test-policy test-protocol test-runtime test-session test-keymap test-sway-policy test-bindings-protocol test-source-archive test-pointer-policy test-pointer-protocol test-xconfig test-xconfig-sample

# Optional integration test; requires a separately installed compatible River.
build/xdg-shell-client-protocol.h: | build
	$(WAYLAND_SCANNER) client-header "$(WAYLAND_PROTOCOLS_DIR)/stable/xdg-shell/xdg-shell.xml" $@

build/xdg-shell-protocol.c: | build
	$(WAYLAND_SCANNER) private-code "$(WAYLAND_PROTOCOLS_DIR)/stable/xdg-shell/xdg-shell.xml" $@

build/xdg-probe: tests/xdg_probe.c build/xdg-shell-protocol.c build/xdg-shell-client-protocol.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -Wall -Wextra -Werror tests/xdg_probe.c build/xdg-shell-protocol.c $(LDLIBS) -o $@

install: all
	install -d "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(PREFIX)/share/wayland-sessions"
	install -m755 build/xmonad-wayland "$(DESTDIR)$(PREFIX)/bin/"
	install -m755 scripts/xmonad-wayland-session scripts/xmonad-wayland-doctor scripts/xmonad-wayland-nested.py scripts/xmonad-wayland-sway-input.py "$(DESTDIR)$(PREFIX)/bin/"
	install -m644 packaging/xmonad-wayland.desktop "$(DESTDIR)$(PREFIX)/share/wayland-sessions/"
	install -d "$(DESTDIR)$(PREFIX)/share/xmonad-wayland" "$(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland" "$(DESTDIR)$(PREFIX)/share/xmonad-wayland/lib"
	install -m644 $(OBJECTS) "$(DESTDIR)$(PREFIX)/share/xmonad-wayland/lib/"
	@set -eu; xw_source=$$(mktemp -d); \
	trap 'rm -rf "$$xw_source"' EXIT HUP INT TERM; \
	$(PYTHON) scripts/package-source.py --export-dir "$$xw_source"; \
	cp -R "$$xw_source/." "$(DESTDIR)$(PREFIX)/share/xmonad-wayland/"; \
	for xw_doc in LICENSE licenses README.md README.pt-BR.md docs; do \
	  cp -R "$$xw_source/$$xw_doc" "$(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland/"; \
	done

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/xmonad-wayland" "$(DESTDIR)$(PREFIX)/bin/xmonad-wayland-session" "$(DESTDIR)$(PREFIX)/bin/xmonad-wayland-doctor"
	rm -f "$(DESTDIR)$(PREFIX)/bin/xmonad-wayland-nested.py" "$(DESTDIR)$(PREFIX)/bin/xmonad-wayland-sway-input.py"
	rm -f "$(DESTDIR)$(PREFIX)/share/wayland-sessions/xmonad-wayland.desktop"
	rm -rf "$(DESTDIR)$(PREFIX)/share/xmonad-wayland" "$(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland"

clean:
	rm -rf build
