(in-package #:qvm-tests)

;;; TODO: export symbols from QVM
(deftest test-tracing-simple-quilt-program ()
  (let ((pp (quil:parse-quil "
SET-FREQUENCY 0 \"xy\" 1e9
SET-PHASE 0 \"xy\" 0.5
PULSE 0 \"xy\" gaussian(duration: 1.0, fwhm: 2, t0: 3)    # 0s-1s
FENCE 0 1
PULSE 1 \"xy\" gaussian(duration: 1.0, fwhm: 2, t0: 3)    # 1s-2s
DECLARE ro BIT[100]
RAW-CAPTURE 1 \"rx\" 2.0 ro                               # 2s-4s
PULSE 0 1 \"foo\" flat(duration: 1.5, iq: 1.0)            # 4s-5.5s
"))
        ;; The frames here are pure nonsense.
        (qvm (qvm::make-pulse-tracing-qvm (list (cons (quil:frame (list (quil:qubit 0)) "xy")
                                                      (qvm::make-frame-state :frequency 100000 :sample-rate 50000))
                                                (cons (quil:frame (list (quil:qubit 1)) "xy")
                                                      (qvm::make-frame-state :frequency 100000 :sample-rate 50000))
                                                (cons (quil:frame (list (quil:qubit 1)) "rx")
                                                      (qvm::make-frame-state :frequency 400000 :sample-rate 50000))
                                                (cons (quil:frame (mapcar #'quil:qubit '(0 1)) "foo")
                                                      (qvm::make-frame-state :frequency 800000 :sample-rate 50000))))))
    (load-program qvm pp)
    (run qvm)
    ;; check frame state
    (let* ((frame (quil:frame (list (quil:qubit 0)) "xy"))
           (state (qvm::frame-state qvm frame)))
      (is (= 1e9 (qvm::frame-state-frequency state)))
      (is (- 0.5 (qvm::frame-state-phase state))))

    (let ((log (qvm::pulse-event-log qvm)))
      ;; check # of events
      (is (= 4 (length log)))
      ;; check that the last event has the right timing
      (let ((event (elt log (1- (length log)))))
        (is (= 4.0 (qvm::pulse-event-start-time event)))
        (is (= 5.5 (qvm::pulse-event-end-time event)))
        (is (= 1.5 (qvm::pulse-event-duration event)))))))


(deftest test-pulse-tracing-illegal-frame ()
    (let ((pp (quil:parse-quil "
SET-FREQUENCY 0 \"xy\" 1e9
SET-PHASE 0 \"xy\" 0.5
PULSE 0 \"xy\" gaussian(duration: 1.0, fwhm: 2, t0: 3)    # 0s-1s
FENCE 0 1
PULSE 1 \"xy\" gaussian(duration: 1.0, fwhm: 2, t0: 3)    # 1s-2s
DECLARE ro BIT[100]
RAW-CAPTURE 1 \"rx\" 2.0 ro                               # 2s-4s
PULSE 0 1 \"foo\" flat(duration: 1.5, iq: 1.0)            # 4s-5.5s
"))
          (qvm (qvm::make-pulse-tracing-qvm (list (cons (quil:frame (list (quil:qubit 1)) "xy")
                                                        (qvm::make-frame-state :frequency 100000 :sample-rate 50000))
                                                  (cons (quil:frame (list (quil:qubit 1)) "rx")
                                                        (qvm::make-frame-state :frequency 400000 :sample-rate 50000))
                                                  (cons (quil:frame (mapcar #'quil:qubit '(0 1)) "foo")
                                                        (qvm::make-frame-state :frequency 800000 :sample-rate 50000))))))
      (load-program qvm pp)
      ;; Execution fails on the first pulse, since we haven't told the QVM about
      ;; the presence of an "xy" frame on qubit 0.
      (signals error
        (run qvm))))
