;;; SPDX-License-Identifier: BSD-3-Clause
;;; Local development build; checks are recorded in evidence/guix-*.log.
;;; Run from the source root: guix build -f packaging/guix/guix.scm
;;; Intentionally no propagated River: older Guix river 0.3.12 is incompatible.
(use-modules (guix packages)
             (guix gexp)
             (guix utils)
             (guix build-system gnu)
             ((guix licenses)
              #:prefix license:)
             (gnu packages haskell)
             (gnu packages pkg-config)
             (gnu packages python)
             (gnu packages freedesktop)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

;; The same reviewed list drives release archives and installed source.
(define %source-directory
  (canonicalize-path (string-append (dirname (current-filename)) "/../..")))

(define %source-entries
  (filter (lambda (line)
            (and (not (string-null? line))
                 (not (string-prefix? "#" line))))
          (map string-trim-both
               (string-split (call-with-input-file (string-append
                                                    %source-directory
                                                    "/scripts/source-manifest")
                               get-string-all) #\newline))))

(define (public-source? file stat)
  (let ((relative (if (string=? file %source-directory) ""
                      (string-drop file
                                   (+ 1
                                      (string-length %source-directory))))))
    (and (not (any (lambda (part)
                     (member part
                             '(".git" "__pycache__"
                               "build"
                               "stage"
                               "result"
                               "evidence"
                               "dist"
                               ".guix-runtime")))
                   (string-split relative #\/)))
         (not (eq? (stat:type stat)
                   'symlink))
         (not (any (lambda (suffix)
                     (string-suffix? suffix relative))
                   '(".pyc" ".o" ".hi" ".deb" ".rpm" ".tar.gz")))
         (or (string-null? relative)
             (any (lambda (entry)
                    (or (string=? relative entry)
                        (string-prefix? (string-append entry "/") relative)
                        (string-prefix? (string-append relative "/") entry)))
                  %source-entries)))))

(package
  (name "xmonad-wayland")
  (version "0.4.1")
  (source
   (local-file %source-directory
               "xmonad-wayland-0.4.1-source"
               #:recursive? #t
               #:select? public-source?))
  (build-system gnu-build-system)
  (arguments
   ;; Make's built-in CC is not necessarily the compiler for this target.
   (list
    #:make-flags
    #~(list (string-append "CC="
                           #$(cc-for-target))
            (string-append "PREFIX="
                           #$output))
    #:test-target "test"
    #:phases
    #~(modify-phases %standard-phases
        (delete 'configure))))
  (native-inputs (list ghc-9.2 pkg-config wayland))
  (inputs (list wayland python-minimal))
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
