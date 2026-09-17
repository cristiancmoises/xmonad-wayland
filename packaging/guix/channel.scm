;;; SPDX-License-Identifier: BSD-3-Clause
;;; Optional input configuration daemon for the pinned River runtime.
(use-modules (guix packages)
             (guix download)
             (guix git-download)
             (guix gexp)
             (guix build-system zig)
             ((guix licenses)
              #:prefix license:)
             (gnu packages freedesktop)
             (gnu packages linux)
             (gnu packages pkg-config)
             (gnu packages xdisorg)
             (gnu packages zig))

(define channel-commit
  "94a3d6c72c7493dd21a3b2ed10f8776bb887b857")

(define channel-river-runtime
  (load (string-append (dirname (canonicalize-path (current-filename)))
                       "/river.scm")))

(define channel-wayland-source
  (origin
    (method url-fetch)
    (uri "https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz")
    (file-name "zig-wayland-0.6.0.tar.gz")
    (sha256 (base32 "09gga9c758vsmwb9la20bpk38bwxlr1lmmyj2bjf0j596qp676km"))))

(define channel-tributary-source
  (origin
    (method url-fetch)
    (uri (string-append "https://codeberg.org/Sivecano/libtributary/archive/"
                        "b1e00ffdc1a87f6601b7913a1196c488ff39b27d.tar.gz"))
    (file-name "libtributary-b1e00ff.tar.gz")
    (sha256 (base32 "008br7rmcmv5zhiblmdjycsc9w3h6j5vxm5ch4qdj7hh7p6f7902"))))

(define channel-zig-dependencies
  '(("wayland-source"
     "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX")
    ("tributary-source"
     "tributary-0.4.1-tqCfWzbUAACWcbClrEM-xQIfPNogwri6nGNyWrt123vK")))

(package
  (name "channel-river-input")
  (version (git-version "0.4.2" "0" channel-commit))
  (source
   (origin
     (method url-fetch)
     (uri (string-append "https://codeberg.org/Sivecano/channel/archive/"
                         channel-commit ".tar.gz"))
     (file-name (string-append "channel-" channel-commit ".tar.gz"))
     (sha256
      (base32 "1zh69wg2qgmqvmy565w5v09bw07xrzp6367qcn8dpa6i135aimpq"))))
  (build-system zig-build-system)
  (arguments
   (list
    #:zig zig-0.16
    #:install-source? #f
    #:zig-release-type "safe"
    #:zig-build-flags
    #~(list "-Dcpu=baseline" "--system" "/tmp/zig-cache/p")
    #:zig-test-flags
    #~(list "-Doptimize=ReleaseSafe"
            "-Dcpu=baseline"
            "--summary"
            "all"
            "--system"
            "/tmp/zig-cache/p")
    #:phases
    #~(modify-phases %standard-phases
        (add-after 'unpack 'configure-kernel-header-path
          (lambda _
            (substitute* "build.zig"
              (("    translate_c.linkSystemLibrary")
               (string-append
                "    translate_c.addSystemIncludePath(.{ .cwd_relative = \""
                #$(file-append linux-libre-headers "/include")
                "\" });\n    translate_c.linkSystemLibrary")))))
        (add-after 'configure 'keep-pkg-config-include-paths
          (lambda _
            ;; Zig's C translator needs explicit system-library include flags.
            (setenv "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" "1")))
        (replace 'unpack-dependencies
          (lambda* (#:key inputs native-inputs #:allow-other-keys)
            (let ((all-inputs (append (or native-inputs
                                          '()) inputs)))
              (for-each (lambda (entry)
                          (let* ((archive (assoc-ref all-inputs
                                                     (car entry)))
                                 (expected (cadr entry))
                                 (cached (string-append "/tmp/zig-cache/p/"
                                                        expected ".tar.gz")))
                            (invoke "zig" "fetch" "--global-cache-dir"
                                    "/tmp/zig-cache" archive)
                            (unless (file-exists? cached)
                              (error "upstream Zig content hash mismatch"
                                     (car entry)))
                            (invoke "tar"
                                    "--extract"
                                    "--gzip"
                                    "--no-same-owner"
                                    "--file"
                                    cached
                                    "--directory"
                                    "/tmp/zig-cache/p")
                            (unless (file-exists? (string-append
                                                   "/tmp/zig-cache/p/"
                                                   expected "/build.zig.zon"))
                              (error "missing verified Zig package"
                                     (car entry)))))
                        '#$channel-zig-dependencies))))
        (add-after 'unpack-dependencies 'enable-tributary-tests
          (lambda _
            ;; Use the same Wayland module that Channel supplies to tributary.
            ;; Upstream's standalone test target omits that required import.
            (substitute* "build.zig"
              (("    b.installArtifact\\(exe\\);")
               (string-append
                "    const tests = b.addTest(.{ .root_module = mod_tributary });
"
                "    const run_tests = b.addRunArtifact(tests);
"
                "    b.step(\"test\", \"Run libtributary tests\")"
                ".dependOn(&run_tests.step);\n" "    b.installArtifact(exe);")))
            ;; Preserve the upstream rectangle test after Vec2 became a struct.
            (substitute* (string-append "/tmp/zig-cache/p/"
                                        (cadr (assoc "tributary-source"
                                                     '#$channel-zig-dependencies))
                                        "/src/utils.zig")
              (("\\.\\{ 0, 0 \\}")
               ".{ .x = 0, .y = 0 }")
              (("\\.\\{ 20, 20 \\}")
               ".{ .x = 20, .y = 20 }")
              (("\\.\\{ 25, 25 \\}")
               ".{ .x = 25, .y = 25 }")
              (("\\.\\{ 100, 100 \\}")
               ".{ .x = 100, .y = 100 }"))))
        (add-after 'install 'install-documentation
          (lambda* (#:key inputs native-inputs #:allow-other-keys)
            (let ((doc (string-append #$output
                                      "/share/doc/channel-river-input"))
                  (all-inputs (append (or native-inputs
                                          '()) inputs)))
              (install-file "README.asciidoc" doc)
              (install-file "config.rh" doc)
              ;; The tributary Zig manifest excludes its license file.
              (mkdir-p "tributary-license")
              (invoke "tar"
                      "--extract"
                      "--gzip"
                      "--no-same-owner"
                      "--file"
                      (assoc-ref all-inputs "tributary-source")
                      "--strip-components=1"
                      "--directory"
                      "tributary-license"
                      "libtributary/LICENSE")
              (copy-file "tributary-license/LICENSE"
                         (string-append doc "/libtributary-LICENSE"))))))))
  (native-inputs (list (list "pkg-config" pkg-config)
                       (list "linux-libre-headers" linux-libre-headers)
                       (list "river-xmonad-runtime" channel-river-runtime)
                       (list "wayland" wayland)
                       (list "wayland-protocols" wayland-protocols)
                       (list "wayland-source" channel-wayland-source)
                       (list "tributary-source" channel-tributary-source)))
  (inputs (list wayland libxkbcommon))
  (home-page "https://codeberg.org/Sivecano/channel")
  (synopsis "Input configuration daemon for River")
  (description
   "Channel configures River input devices through the River input-management,
libinput-configuration and XKB-configuration protocols.  It reads profiles and
matching rules from the River config.rh file, applying settings when devices
appear or the configuration changes.  It runs separately from the window
manager and does not configure the system or start itself automatically.")
  (supported-systems '("x86_64-linux" "aarch64-linux"))
  (license (list license:agpl3 license:expat)))
