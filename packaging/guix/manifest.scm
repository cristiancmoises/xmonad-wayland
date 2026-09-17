;;; SPDX-License-Identifier: BSD-3-Clause
;;; A project-local runtime profile, built by scripts/guix-build.
(use-modules (gnu packages)
             (guix profiles))

(define recipe-directory
  (dirname (canonicalize-path (current-filename))))

(packages->manifest (append (list (load (string-append recipe-directory
                                                       "/guix.scm"))
                                  (load (string-append recipe-directory
                                                       "/river.scm")))
                            (map specification->package
                                 '("foot" "fuzzel" "font-dejavu"))))
