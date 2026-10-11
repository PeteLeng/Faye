;;; faye-curl-test.el --- Curl execution stories  -*- lexical-binding: t; -*-

;;; Commentary:

;; GET a fixed response, or POST headers and body bytes to a local echo server.
;; Servers use free loopback ports.  Request and response chunks can split anywhere.
;; The API and plist contracts are defined in faye-curl.el.

;;; Code:

(require 'ert)
(require 'faye-curl)

(defun faye-curl-test--receive-request (connection request-chunk)
  "Accumulate REQUEST-CHUNK on CONNECTION, returning a complete request or nil.
This fixture reads Content-Length bodies and returns :headers and :body strings."
  (let* ((request-bytes
          (concat (process-get connection 'request-bytes) request-chunk))
         (headers-end (string-match "\r\n\r\n" request-bytes)))
    (process-put connection 'request-bytes request-bytes)
    (when headers-end
      (let* ((headers (substring request-bytes 0 headers-end))
             (case-fold-search t)
             (body-length
              (if (string-match "^Content-Length:[ \t]*\\([0-9]+\\)\r?$" headers)
                  (string-to-number (match-string 1 headers))
                0))
             (body-start (+ headers-end 4))
             (body-end (+ body-start body-length)))
        (when (>= (length request-bytes) body-end)
          (set-process-filter connection #'ignore)
          (list :headers headers :body (substring request-bytes body-start body-end)))))))

(defun faye-curl-test--reply-hello (connection request-chunk)
  "Reply with hello once CONNECTION has received a request via REQUEST-CHUNK."
  (when (faye-curl-test--receive-request connection request-chunk)
    (process-send-string
     connection
     (concat "HTTP/1.1 200 OK\r\n"
             "Content-Type: text/plain\r\n"
             "Content-Length: 5\r\n"
             "Connection: close\r\n"
             "\r\n"
             "hello"))
    (process-send-eof connection)))

(ert-deftest faye-curl-test-get-success ()
  "HTTP 200 delivers body bytes and one succeeded result with Curl exit 0."
  (let* ((accepted-connections nil)
         (received-body "")
         (terminal-result nil)
         (completion-count 0)
         (server
          (make-network-process
           :name "faye-curl-test-server"
           :server t :family 'ipv4 :host "127.0.0.1" :service t
           :coding 'binary :noquery t
           :filter #'faye-curl-test--reply-hello
           :sentinel #'ignore
           :log (lambda (_server connection _message)
                  (push connection accepted-connections)))))
    (unwind-protect
        (let ((http-request
               (list :method "GET"
                     :url (format "http://127.0.0.1:%d/example"
                                  (process-contact server :service)))))
          ;; Start one real HTTP exchange.  Collect body bytes as they arrive.
          (faye-curl-start
           http-request
           (lambda (event)
             (when (eq (plist-get event :type) 'body)
               (setq received-body
                     (concat received-body (plist-get event :bytes)))))
           (lambda (result)
             (setq terminal-result result)
             (setq completion-count (1+ completion-count))))
          ;; The contract requires callbacks to run after START returns.
          (should (equal received-body ""))
          (should (= completion-count 0))

          ;; Give Emacs time to serve the request and receive Curl's callbacks.
          (with-timeout (5 (ert-fail "HTTP exchange did not finish within five seconds"))
            (while (= completion-count 0)
              (accept-process-output nil 0.01)))

          ;; Chunk boundaries do not matter; their combined contents do.
          (should (equal received-body "hello"))
          (should-not (multibyte-string-p received-body))
          (should (= completion-count 1))
          (should (eq (plist-get terminal-result :status) 'succeeded))
          (should (= (plist-get terminal-result :http-status-code) 200))
          (should (= (plist-get terminal-result :curl-exit) 0)))

      ;; Release the test server's resources even when an assertion fails.
      (dolist (connection accepted-connections)
        (when (process-live-p connection)
          (delete-process connection)))
      (delete-process server))))

(ert-deftest faye-curl-test-post-headers-and-body ()
  "POST sends custom headers and exact body bytes; the server echoes those bytes."
  (let* ((accepted-connections nil)
         (server-request nil)
         (received-body "")
         (terminal-result nil)
         (completion-count 0)
         (header-value "\"quoted\" \\path %{literal}")
         ;; UTF-8, CRLF, NUL and 0xff must all survive unchanged.
         (body-bytes (concat (encode-coding-string "héllo" 'utf-8-unix)
                             (unibyte-string 13 10 0 255)))
         (server
          (make-network-process
           :name "faye-curl-test-echo-server"
           :server t :family 'ipv4 :host "127.0.0.1" :service t
           :coding 'binary :noquery t
           :sentinel #'ignore
           :log (lambda (_server connection _message)
                  (push connection accepted-connections))
           :filter
           (lambda (connection request-chunk)
             (let ((request (faye-curl-test--receive-request connection request-chunk)))
               (when request
                 (setq server-request request)
                 (let ((body (plist-get request :body)))
                   (process-send-string
                    connection
                    (concat "HTTP/1.1 200 OK\r\n"
                            "Content-Type: application/octet-stream\r\n"
                            "Content-Length: " (number-to-string (length body)) "\r\n"
                            "Connection: close\r\n\r\n"
                            body))
                   (process-send-eof connection))))))))
    (unwind-protect
        (progn
          (faye-curl-start
           (list :method "POST"
                 :url (format "http://127.0.0.1:%d/echo"
                              (process-contact server :service))
                 :headers (list (cons "Content-Type" "application/octet-stream")
                                (cons "X-Faye-Test" header-value))
                 :body body-bytes)
           (lambda (event)
             (when (eq (plist-get event :type) 'body)
               (setq received-body
                     (concat received-body (plist-get event :bytes)))))
           (lambda (result)
             (setq terminal-result result)
             (setq completion-count (1+ completion-count))))

          (with-timeout (5 (ert-fail "POST did not finish within five seconds"))
            (while (= completion-count 0)
              (accept-process-output nil 0.01)))

          (should (= completion-count 1))
          (should (eq (plist-get terminal-result :status) 'succeeded))
          (should (= (plist-get terminal-result :http-status-code) 200))
          (should (= (plist-get terminal-result :curl-exit) 0))
          (let ((headers (plist-get server-request :headers))
                (case-fold-search t))
            (should (string-prefix-p "POST /echo HTTP/" headers))
            (should (string-match-p "^Content-Type: application/octet-stream\r?$" headers))
            (should (string-match-p
                     (concat "^X-Faye-Test: " (regexp-quote header-value) "\r?$")
                     headers)))
          (should (equal (plist-get server-request :body) body-bytes))
          (should (equal received-body body-bytes))
          (should-not (multibyte-string-p received-body)))

      (dolist (connection accepted-connections)
        (when (process-live-p connection)
          (delete-process connection)))
      (delete-process server))))

(provide 'faye-curl-test)
;;; faye-curl-test.el ends here
