;;; faye-req.el --- Minimal Request execution  -*- lexical-binding: t; -*-

;;; Commentary:

;; Start an injected attempt function; retry explicitly retryable failures.
;; The first executable example is `faye-req-test-retries-once'.

;;; Code:

(require 'cl-lib)

(cl-defstruct (faye-req
               (:constructor faye-req-create
                             (payload attempt-fn &optional retry-options)))
  "Inputs and current status for one Request."
  payload
  attempt-fn
  retry-options
  (status 'prepared))

(defun faye-req-start (request on-event on-done)
  "Start REQUEST asynchronously and return it.
The injected attempt function receives (PAYLOAD EMIT-EVENT EMIT-RESULT)
and owns cleanup of its resources before calling EMIT-RESULT.  Its return
value is ignored.  The reported result is a plist containing :status and,
for a retryable failure, :retryable t.

ON-EVENT receives (REQUEST EVENT); EVENT contains :attempt and :data.
ON-DONE receives (REQUEST RESULT) after terminal status is set.
Either callback may be nil.  Retry options are :max-attempts (default 1,
including the first attempt) and :retry-delay (default 0 seconds)."
  (unless (eq (faye-req-status request) 'prepared)
    (error "Request has already started"))

  (setf (faye-req-status request) 'running)

  ;; Capture the retry settings for this execution.
  (let* ((retry-options (faye-req-retry-options request))
         (max-attempts (or (plist-get retry-options :max-attempts) 1))
         (retry-delay (or (plist-get retry-options :retry-delay) 0)))
    (cl-labels
        ((run-attempt (attempt-number)
           (let ((done-p nil))
             (cl-flet
                 ((emit-event (event)
                    (when (and on-event (not done-p))
                      (funcall on-event request
                               (list :attempt attempt-number :data event))))

                  (emit-result (result)
                    (unless done-p
                      (setq done-p t)
                      (if (and (eq (plist-get result :status) 'failed)
                               (plist-get result :retryable)
                               (< attempt-number max-attempts))
                          ;; Retry.
                          (run-at-time retry-delay nil #'run-attempt
                                       (1+ attempt-number))

                        ;; Finish.
                        (setf (faye-req-status request)
                              (plist-get result :status))
                        (when on-done
                          (funcall on-done request result))))))

               ;; Execute the supplied attempt function.
               (funcall (faye-req-attempt-fn request)
                        (faye-req-payload request)
                        #'emit-event
                        #'emit-result)))))

      ;; Return to the caller before starting the first attempt.
      (run-at-time 0 nil #'run-attempt 1)))
  request)

(provide 'faye-req)
;;; faye-req.el ends here
