;;; faye-curl.el --- One asynchronous HTTP exchange  -*- lexical-binding: t; -*-

;;; Commentary:

;; This module owns the Curl API and its data contract.  Request, event and
;; result values are ordinary property lists.
;;
;; HTTP request:
;;   :method       string -- HTTP method, e.g. "GET"
;;   :url          string -- absolute HTTP or HTTPS URL
;;   :headers      optional alist of (NAME . VALUE) strings, in sending order
;;                 Caller supplies an ASCII HTTP token as NAME.
;;                 Neither NAME nor VALUE may contain CR, LF or NUL.
;;                 Text is UTF-8 encoded.  An empty VALUE sends an empty header.
;;   :body         optional unibyte string -- exact bytes to send, with no encoding
;;                 nil/omitted means no supplied body; "" supplies an empty body.
;;   Example: (:method "GET" :url "http://127.0.0.1:8080/example")
;;   Example: (:method "POST" :url "http://127.0.0.1:8080/example"
;;             :headers (("Content-Type" . "application/json"))
;;             :body "{\"message\":\"hello\"}")
;;   Input values are captured before asynchronous execution.  The caller performs
;;   any JSON or form encoding and supplies the appropriate Content-Type header.
;;   Header values and body bytes are not placed in subprocess command arguments.
;;
;; Body event:
;;   :type         symbol -- body
;;   :bytes        unibyte string -- a chunk of HTTP body, excluding headers
;;   Example: (:type body :bytes "hello")
;;   Chunk boundaries are arbitrary; concatenate chunks in arrival order.
;;
;; Terminal result:
;;   :status           symbol -- succeeded or failed
;;   :http-status-code integer or nil -- final HTTP status, nil if unavailable
;;   :curl-exit        integer or nil -- exit code, including nonzero error codes
;;                     nil if Curl could not start or was terminated by a signal
;;   Example: (:status succeeded :http-status-code 200 :curl-exit 0)
;;   Failure before an HTTP response:
;;   (:status failed :http-status-code nil :curl-exit 6)
;;   Success requires a completed transfer, Curl exit 0 and HTTP status 200-299.
;;   HTTP success and Curl exit status are separate observations.

;;; Code:

(require 'cl-lib)

(defun faye-curl-start (http-request on-event on-result)
  "Start one asynchronous Curl exchange for HTTP-REQUEST.
HTTP-REQUEST, events and results follow the plist contracts documented in
this module's Commentary section.

ON-EVENT is a function called with one body event, zero or more times.
ON-RESULT is a function called with one terminal result, exactly once.
Callbacks run after this function returns.  Body events arrive in order,
before the terminal result; no events follow that result.

The exchange owns its processes and temporary header file, releasing them
before calling ON-RESULT.  Return values from this function and its callbacks
are ignored.  Observer errors do not change the transport outcome.
One invocation performs one exchange, with no automatic retry.
Malformed argument types signal an error before starting."
  (unless (and (stringp (plist-get http-request :method))
               (stringp (plist-get http-request :url))
               (functionp on-event)
               (functionp on-result))
    (error "Expected :method and :url strings and two callback functions"))

  (let ((body (plist-get http-request :body)))
    (unless (or (null body)
                (and (stringp body) (not (multibyte-string-p body))))
      (error ":body must be nil or a unibyte string; encode text before sending")))

  (let* ((method (copy-sequence (plist-get http-request :method)))
         (url (copy-sequence (plist-get http-request :url)))
         (headers (plist-get http-request :headers))
         (headers-text
          (when headers
            (unless (listp headers)
              (error ":headers must be an alist"))
            (mapconcat
             (lambda (header)
               (let ((name (car header))
                     (value (cdr header)))
                 (unless (and (stringp name) (stringp value))
                   (error "Headers must be (NAME . VALUE) string pairs"))
                 (when (or (string-match-p "[\r\n\0]" name)
                           (string-match-p "[\r\n\0]" value))
                   (error "Header names and values must not contain CR, LF or NUL"))
                 ;; Curl uses a semicolon to send an explicitly empty header.
                 (if (equal value "")
                     (concat name ";")
                   (concat name ": " value))))
             headers
             "\n")))
         (body-bytes (copy-sequence (plist-get http-request :body)))
         (headers-file nil)
         (curl-process nil)
         (stderr-pipe-process nil)
         (http-status-code-text "")
         (done-p nil))

    (cl-labels
        ((finish (curl-exit-code)
           (unless done-p
             (setq done-p t)
             (let* ((http-status-code
                     (when (string-match-p "\\`[1-9][0-9][0-9]\\'"
                                           http-status-code-text)
                       (string-to-number http-status-code-text)))
                    (success-p (and (eq curl-exit-code 0)
                                    http-status-code
                                    (<= 200 http-status-code)
                                    (< http-status-code 300)))
                    (result (list :status (if success-p 'succeeded 'failed)
                                  :http-status-code http-status-code
                                  :curl-exit curl-exit-code)))
               ;; Notify after cleanup, including when cleanup signals an error.
               (unwind-protect
                   (progn
                     (dolist (process (list curl-process stderr-pipe-process))
                       (when process
                         (set-process-sentinel process #'ignore)
                         (delete-process process)))
                     (when headers-file
                       (delete-file headers-file)))
                 (ignore-errors (funcall on-result result))))))

         (on-process-change (process _message)
           ;; Sentinel: process-state notifications, rather than incoming bytes.
           ;; End notifications follow pending output; wait for both streams.
           (unless (process-live-p process)
             (process-put process 'faye-curl-ended-p t))
           (when (and curl-process stderr-pipe-process
                      (process-get curl-process 'faye-curl-ended-p)
                      (process-get stderr-pipe-process 'faye-curl-ended-p))
             (finish (when (eq (process-status curl-process) 'exit)
                       (process-exit-status curl-process)))))

         (on-stdout (_process bytes)
           (unless done-p
             (ignore-errors
               (funcall on-event (list :type 'body :bytes bytes)))))

         (on-stderr (_process bytes)
           (unless done-p
             (setq http-status-code-text (concat http-status-code-text bytes))))

         (start ()
           (condition-case nil
               (progn
                 ;; Header values stay out of the process command line.
                 (when headers-text
                   (setq headers-file (make-temp-file "faye-curl-headers-"))
                   (let ((coding-system-for-write 'utf-8-unix))
                     (write-region headers-text nil headers-file nil 'silent)))

                 (setq stderr-pipe-process
                       (make-pipe-process
                        :name "faye-curl-stderr"
                        :buffer nil
                        :coding 'binary
                        :noquery t
                        :filter #'on-stderr
                        :sentinel #'on-process-change))

                 ;; Build the complete command once the header file exists.
                 (let ((command
                        (append
                         (list "curl"
                               "--disable"
                               "--silent"
                               "--no-buffer"
                               "--retry" "0"
                               "--globoff"
                               "--proto" "=http,https"
                               "--request" method
                               "--url" url
                               ;; Body on stdout; final HTTP code on stderr.
                               "--write-out" "%{stderr}%{http_code}")
                         (when headers-file
                           ;; MSYS expands standalone @file arguments.
                           (list (concat "-H@" headers-file)))
                         (when body-bytes
                           (list "--data-binary" "@-"))))
                       ;; Disable MSYS brace expansion only for this child.
                       (process-environment
                        (if (eq system-type 'windows-nt)
                            (cons (concat "MSYS=" (getenv "MSYS") " noglob")
                                  process-environment)
                          process-environment)))
                   (setq curl-process
                         (make-process
                          :name "faye-curl"
                          :buffer nil
                          :command command
                          :connection-type 'pipe
                          :coding 'binary
                          :noquery t
                          :stderr stderr-pipe-process
                          :filter #'on-stdout
                          :sentinel #'on-process-change)))

                 ;; --data-binary reads the exact body bytes from stdin until EOF.
                 ;; An empty string is still a supplied body; nil is not.
                 (when body-bytes
                   (process-send-string curl-process body-bytes)
                   (process-send-eof curl-process)))
             (error (finish nil)))))

      ;; Callback delivery begins only after this function returns.
      (run-at-time 0 nil #'start)))
  nil)

(provide 'faye-curl)
;;; faye-curl.el ends here
