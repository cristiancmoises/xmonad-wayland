;; Official Guix, pinned so the compiler and libraries match this recipe.

(list
 (channel
  (name 'guix)
  (url "https://codeberg.org/guix/guix.git")
  (branch "master")
  (commit "fe590afef7319a8ea921d35b67fb39fb79f5a3b3")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
