;;; Local build recipe; not evaluated or built with Guix in this release.
;;; Run from the source root: guix build -f packaging/guix/guix.scm
;;; Intentionally no propagated River: older Guix river 0.3.12 is incompatible.
(use-modules (guix packages)
             (guix gexp)
             (guix build-system gnu)
             ((guix licenses) #:prefix license:)
             (gnu packages haskell)
             (gnu packages pkg-config)
             (gnu packages python)
             (gnu packages freedesktop))

(package
  (name "xmonad-wayland")
  (version "0.1.0")
  (source
   (local-file "../.." "xmonad-wayland-0.1.0-source"
               #:recursive? #t
               #:select? (lambda (file stat)
                           (not (member (basename file)
                                        '(".git" "build" "stage" "result"))))))
  (build-system gnu-build-system)
  (arguments
   ;; GNU make defaults to cc, but the Guix toolchain supplies gcc.
   (list #:make-flags #~(list "CC=gcc" (string-append "PREFIX=" #$output))
         #:test-target "test"
         #:phases #~(modify-phases %standard-phases
                      (delete 'configure))))
  (native-inputs (list ghc-9.2 pkg-config python-minimal wayland))
  (inputs (list wayland))
  ;; No public project homepage has been assigned to this local prototype.
  (home-page #f)
  (synopsis "Experimental XMonad StackSet window manager for River Wayland")
  (description
   "This independent experimental manager ports XMonad's StackSet core to native
Wayland through River.  The manager can be built without a compositor.  Running
it requires River 0.4 or newer from a suitable Guix channel or another separately
managed installation.  River 0.3 and river-classic are incompatible.  No River
package is propagated, and this recipe does not supply a complete desktop
service or configure display-manager session discovery.")
  (license (list license:bsd-3 license:expat)))
