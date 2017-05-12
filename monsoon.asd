(in-package #:asdf-user)

(asdf:defsystem #:monsoon
  :serial t
  :description "Binary rainfall visualizer for data (packets)"
  :depends-on (#:plokami
               #:lispbuilder-sdl)
  :components ((:file "packages")
               (:file "monsoon")
               ))
