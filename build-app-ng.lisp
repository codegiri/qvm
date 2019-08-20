;;;; build-app-ng.lisp
;;;;
;;;; This file is loaded by the Makefile to produce a qvm-ng[.exe] binary.
;;;;

(unless *load-truename*
  (error "This file is meant to be loaded."))

(require 'asdf)

(let ((*default-pathname-defaults* (make-pathname :type nil
                                                  :name nil
                                                  :defaults *load-truename*))
      (output-file (make-pathname :name "qvm-ng"
                                  :type #+win32 "exe" #-win32 nil))
      (system-table (make-hash-table :test 'equal))
      (toplevel (lambda ()
                  (with-simple-restart (abort "Abort")
                    (funcall (read-from-string "qvm-app-ng::%main")
                             (rest sb-ext:*posix-argv*))))))
  (labels ((load-systems-table ()
             (unless (probe-file "system-index.txt")
               (error "Generate system-index.txt with 'make system-index.txt' first."))
             (setf (gethash "qvm-app-ng" system-table) (merge-pathnames "qvm-app-ng.asd"))
             (with-open-file (stream "system-index.txt")
               (loop
                 :for system-file := (read-line stream nil)
                 :while system-file
                 :do (setf (gethash (pathname-name system-file) system-table)
                           (merge-pathnames system-file)))))
           (local-system-search (name)
             (values (gethash name system-table))))
    (load-systems-table)
    (push #'local-system-search asdf:*system-definition-search-functions*)
    (asdf:load-system "qvm-app-ng")
    (funcall (read-from-string "qvm-app-ng::zap-info"))
    (funcall (read-from-string "qvm-app-ng::disable-debugger"))
    (when (find "--qvm-sdk" sb-ext:*posix-argv* :test 'string=)
      (load "app/src/mangle-shared-objects.lisp"))
    (sb-ext:save-lisp-and-die output-file
                              :compression #+sb-core-compression t
                                           #-sb-core-compression nil
                              :save-runtime-options t
                              :executable t
                              :toplevel toplevel)))
