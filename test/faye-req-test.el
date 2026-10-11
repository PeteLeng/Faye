;;; faye-req-test.el --- First Request execution story  -*- lexical-binding: t; -*-

;;; Commentary:

;; One test: fail once, retry, then succeed.
;; Exercise the public Request API with an attempt function that fails once
;; and then succeeds.  Let Emacs process callbacks until the Request completes.

;;; Code:

(require 'ert)

(ert-deftest faye-req-test-retries-once ()
  "Given two allowed attempts, one retryable failure then success finishes once."
  ;; Require here so ERT can register the test before implementation exists.
  (require 'faye-req)
  (let* ((attempt-count 0)
         (attempt-payloads nil)
         (request-results nil)
         ;; First call fails; second call succeeds.  No network is involved.
         (fake-start-attempt
          (lambda (attempt-payload _report-event complete-attempt)
            (setq attempt-count (1+ attempt-count))
            (push attempt-payload attempt-payloads)
            (if (= attempt-count 1)
                (funcall complete-attempt
                         '(:status failed :retryable t :error temporary))
               (funcall complete-attempt '(:status succeeded :value "answer")))))
         (request
          (faye-req-create "hello" fake-start-attempt
                           '(:max-attempts 2 :retry-delay 0))))
    ;; Start the Request, recording each terminal notification.
    (faye-req-start
     request nil
     (lambda (_request request-result)
       (push request-result request-results)))
    (should (= attempt-count 0))
    (should-not request-results)

    ;; Allow asynchronous callbacks to run.  Fail rather than wait forever.
    (with-timeout (2 (ert-fail "Request did not complete within two seconds"))
      (while (null request-results)
        (accept-process-output nil 0.01)))

    ;; Two attempts with the same input, one successful Request completion.
    (should (= attempt-count 2))
    (should (equal attempt-payloads '("hello" "hello")))
    (should (eq (faye-req-status request) 'succeeded))
    (should (equal request-results '((:status succeeded :value "answer"))))))

(provide 'faye-req-test)
;;; faye-req-test.el ends here
