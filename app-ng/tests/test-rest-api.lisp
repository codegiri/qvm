(in-package :qvm-app-ng-tests)

(defun plist-lowercase-keys (plist)
  (assert (evenp (length plist)))
  (loop :for (k v) :on plist :by #'cddr
        :collect (string-downcase k) :collect v))

(defun plist->json (plist)
  (with-output-to-string (*standard-output*)
    (yason:encode-plist (plist-lowercase-keys plist))))

(defun %url (protocol host port &optional path)
  (format nil "~A://~A:~D~@[~A~]" protocol host port path))

(defun %request-url (host-url path)
  (concatenate 'string host-url path))

(defun %simulation-method->qvm-type (simulation-method)
  (ecase (qvm-app-ng::keywordify simulation-method)
    (:pure-state 'qvm:pure-state-qvm)
    (:full-density-matrix 'qvm:density-qvm)))

(defmacro with-rest-server
    ((url-var &key (protocol "http") (host "127.0.0.1") (port 0)) &body body)
  (check-type url-var symbol)
  (alexandria:once-only (protocol host port)
    (alexandria:with-gensyms (app)
      `(let (,app)
         (unwind-protect
              ;; Ensure required special vars are bound. Maybe this should happen in START-SERVER.
              (special-bindings-let* ((qvm-app-ng::*simulation-method*
                                       (or qvm-app-ng::*simulation-method* 'qvm-app-ng::pure-state)))
                ;; BT:*DEFAULT-SPECIAL-BINDINGS* isn't recursive by default. That is, any direct
                ;; child threads spawned by the current thread will take them into account, threads
                ;; spawned by *those* threads will not, unless you add BT:*DEFAULT-SPECIAL-BINDINGS*
                ;; to BT:*DEFAULT-SPECIAL-BINDINGS*! This is required for bindings to be visible in
                ;; the request-handling threads created by hunchentoot.
                (special-bindings-let* ((bt:*default-special-bindings* bt:*default-special-bindings*))
                  (setf ,app (qvm-app-ng::start-server ,host ,port))
                  (let ((,url-var (%url ,protocol ,host (tbnl:acceptor-port ,app))))
                    ,@body)))
           (tbnl:stop ,app))))))

(defmacro check-request (request-form &key (status 200) (response-re nil response-re-p))
  (alexandria:once-only (status response-re)
    (alexandria:with-gensyms
        (body-or-stream status-code headers uri stream must-close reason-phrase body-as-string)
      `(multiple-value-bind
             (,body-or-stream ,status-code ,headers ,uri ,stream ,must-close ,reason-phrase)
           ,request-form
         (declare (ignore ,headers ,uri ,must-close ,reason-phrase))
         (unwind-protect
              (progn
                (is (= ,status ,status-code))
                (let ((,body-as-string (if (streamp ,body-or-stream)
                                           (alexandria:read-stream-content-into-string ,body-or-stream)
                                           ,body-or-stream)))
                  ,@(when response-re-p
                      `((is (cl-ppcre:scan ,response-re ,body-as-string))))

                  ,body-as-string))
           (progn
             (close ,stream)
             (when (streamp ,body-or-stream)
               (close ,body-or-stream))))))))

(defun http-request (&rest args)
  "Make an HTTP-REQUEST via DRAKMA:HTTP-REQUEST and treat application/json responses as text."
  (let ((drakma:*text-content-types* (append drakma:*text-content-types*
                                             '(("application" . "json")))))
    (apply #'drakma:http-request args)))

(defun simple-request (host-url method path &rest json-plist)
  "Make a METHOD request to HOST-URL/PATH. Any additional keyword args are collected in JSON-PLIST and converted to a JSON dict and sent as the request body."
  (http-request (%request-url host-url path) :method method :content (plist->json json-plist)))

(defun single-request (method path &rest json-plist)
  "Like SIMPLE-REQUEST but wrapped in a WITH-REST-SERVER. Only a single request will be made against a freshly started server."
  (with-rest-server (host-url)
    (apply #'simple-request host-url method path json-plist)))

(deftest test-rest-api-invalid-request ()
  (with-rest-server (host-url)
    (dolist (content '("" "{}" "not-a-json-dict"))
      (check-request (http-request (%request-url host-url "/") :method ':POST :content content)
                     :status 500
                     :response-re "qvm_error"))))

(deftest test-rest-api-version ()
  (check-request (single-request ':POST "/" :type "version")
                 :response-re "\\A[0-9.]+ \\[[A-Fa-f0-9]+\\]\\z"))

(deftest test-rest-api-multishot-trivial-requests ()
  (with-rest-server (host-url)
    (dolist (trivial-args `(;; trials = 0
                            (:trials 0 :addresses ,(alexandria:plist-hash-table '("ro" t)))
                            ;; null addresses index list
                            (:trials 1 :addresses ,(alexandria:plist-hash-table '("ro" ())))
                            ;; empty addresses table
                            (:trials 1 :addresses ,(alexandria:plist-hash-table '()))))
      (check-request (apply #'simple-request host-url ':POST "/"
                            :type "multishot"
                            :compiled-quil "H 0"
                            trivial-args)
                     :response-re "\\A{}\\z"))))

(deftest test-rest-api-multishot-simple-request ()
  (with-rest-server (host-url)
    (dolist (trials '(1 2 10))
      (check-request (simple-request host-url ':POST "/"
                                     :type "multishot"
                                     :compiled-quil "DECLARE ro BIT[4]; X 0; MEASURE 0 ro[0]"
                                     :addresses (alexandria:plist-hash-table '("ro" t))
                                     :trials trials)
                     ;; TODO: support for richer reponse matching than just regexes
                     :response-re (format nil
                                          "\\A{\"ro\":\\[\\[1,0,0,0\\](,\\[1,0,0,0\\]){~D}\\]}\\z"
                                          (1- trials))))))

(deftest test-rest-api-persistent-qvm-info ()
  (with-rest-server (host-url)
    ;; Intentionally do not bind qvm-app-ng::*simulation-method* here, to ensure that the persistent
    ;; QVM is respecting the simulation-method request parameter.
    (dolist (simulation-method qvm-app-ng::*available-simulation-methods*)
      (let* ((response (check-request (simple-request host-url ':POST "/"
                                                      :type "make-persistent-qvm"
                                                      :simulation-method simulation-method
                                                      :number-of-qubits 1)
                                      :response-re "\\A{\"token\":\\d+}\\z"))
             (token (gethash "token" (yason:parse response))))
        (is (integerp token))

        ;; info on non-existing token
        (check-request (simple-request host-url ':POST "/"
                                       :type "persistent-qvm-info"
                                       :persistent-qvm-token (1- token))
                       :status 500
                       :response-re "Failed to find persistent QVM")

        ;; delete on non-existing token
        (check-request (simple-request host-url ':POST "/"
                                       :type "delete-persistent-qvm"
                                       :persistent-qvm-token (1- token))
                       :status 500
                       :response-re "Failed to find persistent QVM")

        ;; info on existing token
        (check-request (simple-request host-url ':POST "/"
                                       :type "persistent-qvm-info"
                                       :persistent-qvm-token token)
                       :response-re (string (%simulation-method->qvm-type simulation-method)))

        ;; delete on existing token
        (check-request (simple-request host-url ':POST "/"
                                       :type "delete-persistent-qvm"
                                       :persistent-qvm-token token)
                       :response-re "Deleted persistent QVM")

        ;; info on deleted token
        (check-request (simple-request host-url ':POST "/"
                                       :type "persistent-qvm-info"
                                       :persistent-qvm-token token)
                       :status 500
                       :response-re "Failed to find persistent QVM")))))

(deftest test-rest-api-persistent-qvm-multishot ()
  (with-rest-server (host-url)
    (dolist (simulation-method qvm-app-ng::*available-simulation-methods*)
      (let* ((response (check-request (simple-request host-url ':POST "/"
                                                      :type "make-persistent-qvm"
                                                      :simulation-method simulation-method
                                                      :number-of-qubits 2)
                                      :response-re "\\A{\"token\":\\d+}\\z"))
             (token (gethash "token" (yason:parse response))))
        (is (integerp token))

        ;; multishot on existing token
        (check-request (simple-request host-url ':POST "/"
                                       :type "multishot"
                                       :persistent-qvm-token token
                                       :compiled-quil "DECLARE ro BIT[2]; X 0; MEASURE 0 ro[0]"
                                       :addresses (alexandria:plist-hash-table '("ro" t))
                                       :trials 1)
                       ;; TODO: support for richer reponse matching than just regexes
                       :response-re "\\A{\"ro\":\\[\\[1,0\\]\\]}\\z")

        ;; I 0: qubit 0 remains in excited state
        (check-request (simple-request host-url ':POST "/"
                                       :type "multishot"
                                       :persistent-qvm-token token
                                       :compiled-quil "DECLARE ro BIT[2]; I 0; MEASURE 0 ro[0]"
                                       :addresses (alexandria:plist-hash-table '("ro" t))
                                       :trials 1)
                       ;; TODO: support for richer reponse matching than just regexes
                       :response-re "\\A{\"ro\":\\[\\[1,0\\]\\]}\\z")

        ;; X 0: flips qubit 0 back to ground state
        (check-request (simple-request host-url ':POST "/"
                                       :type "multishot"
                                       :persistent-qvm-token token
                                       :compiled-quil "DECLARE ro BIT[2]; X 0; MEASURE 0 ro[0]"
                                       :addresses (alexandria:plist-hash-table '("ro" t))
                                       :trials 1)
                       ;; TODO: support for richer reponse matching than just regexes
                       :response-re "\\A{\"ro\":\\[\\[0,0\\]\\]}\\z")

        ;; multishot on non-existent token
        (check-request (simple-request host-url ':POST "/"
                                       :type "multishot"
                                       :persistent-qvm-token (1- token)
                                       :compiled-quil ""
                                       :addresses (make-hash-table)
                                       :trials 1)
                       :status 500
                       :response-re "Failed to find persistent QVM")

        (check-request (simple-request host-url ':POST "/"
                                       :type "delete-persistent-qvm"
                                       :persistent-qvm-token token)
                       :response-re "Deleted persistent QVM")))))