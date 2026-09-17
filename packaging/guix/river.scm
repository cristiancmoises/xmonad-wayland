;;; SPDX-License-Identifier: BSD-3-Clause
;;; Local River 0.4.8 package. Use the accompanying pinned channels.scm.
(use-modules (guix packages)
             (guix download)
             (guix gexp)
             (guix build-system zig)
             ((guix licenses)
              #:prefix license:)
             (gnu packages freedesktop)
             (gnu packages linux)
             (gnu packages man)
             (gnu packages pkg-config)
             (gnu packages window-management)
             (gnu packages xdisorg)
             (gnu packages xorg)
             (gnu packages zig))

(define pixman-source
  (origin
    (method url-fetch)
    (uri "https://codeberg.org/ifreund/zig-pixman/archive/v0.3.0.tar.gz")
    (file-name "zig-pixman-0.3.0.tar.gz")
    (sha256 (base32 "17j90nnn2gd4pakg4nqmj8n0v0v0s29yqvn75wn3mfzp6z75f2sb"))))

(define wayland-source
  (origin
    (method url-fetch)
    (uri "https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz")
    (file-name "zig-wayland-0.6.0.tar.gz")
    (sha256 (base32 "09gga9c758vsmwb9la20bpk38bwxlr1lmmyj2bjf0j596qp676km"))))

(define wlroots-source
  (origin
    (method url-fetch)
    (uri "https://codeberg.org/ifreund/zig-wlroots/archive/v0.20.1.tar.gz")
    (file-name "zig-wlroots-0.20.1.tar.gz")
    (sha256 (base32 "0xd18dqc4ydkw0laj4apgh08iav4423kh9pajyl1xa6jiiid3xfl"))))

(define xkbcommon-source
  (origin
    (method url-fetch)
    (uri "https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.4.0.tar.gz")
    (file-name "zig-xkbcommon-0.4.0.tar.gz")
    (sha256 (base32 "1ixmp1sjwq5scy0l2i678xxksgr084bmsam89p6xal3fmlsqh7yc"))))

(define translate-c-source
  (origin
    (method url-fetch)
    (uri
     "https://codeberg.org/ziglang/translate-c/archive/57c559cf581b1fcad90494eda219f98abeb155ce.tar.gz")
    (file-name "zig-translate-c-57c559c.tar.gz")
    (sha256 (base32 "0pn6kp6n1jr800hkahk9kx8qjamb21yami1761dn8iva67rmvamr"))))

(define aro-source
  (origin
    (method url-fetch)
    (uri
     "https://codeload.github.com/Vexu/arocc/tar.gz/5f5a050569a95ecc40a426f0c3666ae7ef987ede")
    (file-name "zig-aro-5f5a050.tar.gz")
    (sha256 (base32 "0zpb3lx3cgdfia97hz2cwhgnjay0iw6sg66pl5dfzs2962hlj2z2"))))

(package
  (name "river-xmonad-runtime")
  (version "0.4.8")
  (source
   (origin
     (method url-fetch)
     (uri
      "https://codeberg.org/river/river/releases/download/v0.4.8/river-0.4.8.tar.gz")
     (file-name "river-0.4.8.tar.gz")
     (sha256
      (base32 "1yh08k9w450k5vir7paksfp87ddcvbbb8rvi6pg40zihdr930h3d"))))
  (build-system zig-build-system)
  (arguments
   (list
    #:zig zig-0.16
    #:install-source? #f
    #:zig-release-type "safe"
    #:zig-build-flags
    #~(list "-Dpie"
            "-Dxwayland"
            "-Dcpu=baseline"
            "-Dllvm=true"
            "--system"
            "/tmp/zig-cache/p")
    #:zig-test-flags
    #~(list "-Doptimize=ReleaseSafe" "-Dcpu=baseline" "-Dllvm=true" "--system"
            "/tmp/zig-cache/p")
    #:phases
    #~(modify-phases %standard-phases
        (add-after 'configure 'keep-pkg-config-include-paths
          (lambda _
            ;; pkg-config suppresses Guix's C_INCLUDE_PATH entries by default,
            ;; but the separate Aro translate-c tool does not read that variable.
            (setenv "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS" "1")))
        (add-after 'unpack 'use-guix-shell
          (lambda _
            (substitute* '("build.zig" "river/main.zig")
              (("/bin/sh")
               (which "sh")))))
        ;; Keep upstream dependency names and content hashes intact.
        ;; Seed only the verified archives; --system then prohibits downloads.
        (replace 'unpack-dependencies
          (lambda* (#:key inputs native-inputs #:allow-other-keys)
            (let ((all-inputs (append (or native-inputs
                                          '()) inputs)))
              (for-each (lambda (entry)
                          (let ((archive (assoc-ref all-inputs
                                                    (car entry)))
                                (expected (cadr entry)))
                            (unless archive
                              (error "missing Zig source archive"
                                     (car entry)))
                            (invoke "zig" "fetch" "--global-cache-dir"
                                    "/tmp/zig-cache" archive)
                            ;; Zig 0.16 caches fetched packages as archives.
                            ;; --system expects hash-named directories.
                            (let ((cached (string-append "/tmp/zig-cache/p/"
                                                         expected ".tar.gz")))
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
                                      "/tmp/zig-cache/p"))
                            (unless (file-exists? (string-append
                                                   "/tmp/zig-cache/p/"
                                                   expected "/build.zig.zon"))
                              (error "upstream Zig content hash mismatch"
                                     (car entry)))))
                        '(("pixman-source"
                           "pixman-0.3.0-LClMnz2VAAAs7QSCGwLimV5VUYx0JFnX5xWU6HwtMuDX")
                          ("wayland-source"
                           "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX")
                          ("wlroots-source"
                           "wlroots-0.20.1-jmOlcqNVBAB3uB5oqBTzpRlwu-FmMyyZMVAWCe5kmcSt")
                          ("xkbcommon-source"
                           "xkbcommon-0.4.0-VDqIe0i2AgDRsok2GpMFYJ8SVhQS10_PI2M_CnHXsJJZ")
                          ("translate-c-source"
                           "translate_c-0.0.0-Q_BUWlX1BgCD1wo6uo97prlp9VJ4gxAjwN_vZ7nsSjGN")
                          ("aro-source"
                           "aro-0.0.0-JSD1Qi7QNgDnfcrdEJf82v3o6MhZySjYVrtdfEf3E4Se"))))))
        (add-after 'install 'fix-installed-protocol-prefix
          (lambda _
            (substitute* (string-append #$output
                                        "/share/pkgconfig/river-protocols.pc")
              (("^prefix=.*")
               (string-append "prefix="
                              #$output "\n")))))
        (add-after 'install 'check-installed-version
          (lambda _
            (invoke (string-append #$output "/bin/river") "-version"))))))
  (inputs (list libevdev
                libinput-minimal
                wlroots-0.20
                wayland
                libxkbcommon
                pixman))
  (native-inputs (list (list "pkg-config" pkg-config)
                       (list "scdoc" scdoc)
                       (list "wayland" wayland)
                       (list "wayland-protocols" wayland-protocols)
                       (list "pixman-source" pixman-source)
                       (list "wayland-source" wayland-source)
                       (list "wlroots-source" wlroots-source)
                       (list "xkbcommon-source" xkbcommon-source)
                       (list "translate-c-source" translate-c-source)
                       (list "aro-source" aro-source)))
  (home-page "https://isaacfreund.com/software/river/")
  (synopsis "River compositor for the experimental XMonad Wayland manager")
  (description
   "River separates Wayland composition from window-management policy.
This local package builds River 0.4.8 with Xwayland support and requires a
separate window manager implementing river-window-management-v1.  It is used
by the XMonad Wayland nested test and does not configure a system session.")
  (supported-systems '("x86_64-linux" "aarch64-linux"))
  (license (list license:gpl3 license:expat license:bsd-0 license:cc-by-sa4.0)))
