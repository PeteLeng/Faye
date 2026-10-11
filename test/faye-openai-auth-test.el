;;; faye-openai-auth-test.el --- Local OAuth helper tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise builders, temporary credential files, fake HTTP responses and local
;; OpenSSL operations.  No test contacts an OpenAI endpoint or uses real tokens.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'faye-openai-auth)

(defun faye-openai-auth-test--await (start-operation)
  "Call START-OPERATION with a result callback and wait for its result."
  (let ((completion-count 0) result)
    (funcall start-operation
             (lambda (value)
               (setq result value)
               (setq completion-count (1+ completion-count))))
    (should (= completion-count 0))
    (with-timeout (10 (ert-fail "Async helper did not finish within ten seconds"))
      (while (= completion-count 0)
        (accept-process-output nil 0.01)))
    (should (= completion-count 1))
    result))

(defun faye-openai-auth-test--openssl-output (arguments &optional input-bytes)
  "Run OpenSSL synchronously to prepare test fixtures, returning output bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (or input-bytes ""))
    (let ((coding-system-for-read 'binary)
          (coding-system-for-write 'binary))
      (should (= (apply #'call-process-region
                        (point-min) (point-max) "openssl" t t nil arguments)
                 0)))
    (buffer-string)))

(ert-deftest faye-openai-auth-test-build-requests ()
  "Build the token POST with correctly encoded fields and a byte-string body."
  (let* ((client-id "oaiapp_test")
         (authorization-code "code+value/with=padding")
         (pkce-verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
         (redirect-uri "http://127.0.0.1:1455/auth/callback")
         (parameters (list (cons "client_id" client-id)
                           (cons "code" authorization-code)
                           (cons "code_verifier" pkce-verifier)
                           (cons "redirect_uri" redirect-uri)))
         (request (faye-openai-auth-build-request 'exchange-code parameters))
         ;; Expected wire bytes, written explicitly rather than using an encoder.
         (expected-body
          (concat "grant_type=authorization_code"
                  "&resource=https%3A%2F%2Fapi.openai.com%2Fv1"
                  "&client_id=oaiapp_test"
                  "&code=code%2Bvalue%2Fwith%3Dpadding"
                  "&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
                  "&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback")))
    (should (equal (plist-get request :method) "POST"))
    (should (equal (plist-get request :url)
                   "https://auth.openai.com/api/accounts/oauth/token"))
    (should (equal (plist-get request :headers)
                   '(("Content-Type" . "application/x-www-form-urlencoded"))))
    (should (equal (plist-get request :body) expected-body))
    (should-not (multibyte-string-p (plist-get request :body)))
    ;; A caller may replace a header value without changing the shared template.
    (setcdr (car (plist-get request :headers)) "changed")
    (should (equal (plist-get (faye-openai-auth-build-request 'exchange-code parameters)
                              :headers)
                   '(("Content-Type" . "application/x-www-form-urlencoded")))))
  (let ((authorization
         (faye-openai-auth-build-request
          'authorize
          '(("client_id" . "dynamic_agent_client") ("agent_name_hint" . "Faye")
            ("ext_agent_host_id" . "urn:uuid:test")
            ("redirect_uri" . "http://127.0.0.1:1455/auth/callback")
            ("state" . "state+value") ("nonce" . "nonce")
            ("code_challenge" . "challenge"))))
        (refresh (faye-openai-auth-build-request
                  'refresh-token '(("client_id" . "oaiapp_test")
                                   ("refresh_token" . "refresh+token"))))
        (jwks (faye-openai-auth-build-request 'jwks nil)))
    (should (string-match-p "[?&]state=state%2Bvalue\\(?:&\\|$\\)"
                            (plist-get authorization :url)))
    (should-not (plist-get authorization :body))
    (should (string-match-p "refresh_token=refresh%2Btoken\\'"
                            (plist-get refresh :body)))
    (should (equal (plist-get jwks :url)
                   "https://auth.openai.com/.well-known/jwks.json"))
    (should-not (plist-get jwks :body))))

(ert-deftest faye-openai-auth-test-credential-file ()
  "Round-trip UTF-8 credentials; failed replacement preserves the old record."
  (let* ((directory (make-temp-file "faye-auth-store-test-" t))
         (file (expand-file-name "openai/credentials.json" directory))
         (credentials
          '(:email "tést@example.test" :issuer "https://auth.openai.com"
                   :subject "test-subject" :client_id "oaiapp_test"
                   :ext_agent_host_id "urn:uuid:test" :id_token "test-id-token"
                   :access_token "test-access-token" :refresh_token "test-refresh-token"
                   :token_type "Bearer" :expires_in 3600
                   :scopes ["openid" "chatgpt.tokens.use.direct"]
                   :saved_at "2026-10-11T00:00:00Z")))
    (unwind-protect
        (progn
          (should-not (faye-openai-auth-load-credentials file))
          (faye-openai-auth-save-credentials credentials file)
          (should (equal (faye-openai-auth-load-credentials file) credentials))
          (unless (eq system-type 'windows-nt)
            (should (= (logand (file-modes file) #o777) #o600)))
          (cl-letf (((symbol-function 'rename-file)
                     (lambda (&rest _) (error "Simulated replacement failure"))))
            (should-error
             (faye-openai-auth-save-credentials '(:access_token "replacement") file)))
          (should (equal (faye-openai-auth-load-credentials file) credentials))
          (should-not (directory-files (file-name-directory file) nil "^\\.credentials-"))
          (with-temp-file file (insert "[]"))
          (should-error (faye-openai-auth-load-credentials file)))
      (delete-directory directory t))))

(ert-deftest faye-openai-auth-test-send-request ()
  "Assemble fragmented JSON; preserve HTTP errors and report malformed JSON."
  (let ((http-request
         (faye-openai-auth-build-request
          'exchange-code '(("client_id" . "oaiapp_test") ("code" . "test-code")
                           ("code_verifier" . "verifier")
                           ("redirect_uri" . "http://127.0.0.1:1455/auth/callback"))))
        (token-response '(:access_token "test-token" :token_type "Bearer" :note "héllo"))
        (oauth-error '(:error "invalid_grant")))
    (dolist (scenario
             (list (list :body (json-serialize token-response)
                         :transport '(:status succeeded :http-status-code 200 :curl-exit 0)
                         :response token-response)
                   (list :body (json-serialize oauth-error)
                         :transport '(:status failed :http-status-code 400 :curl-exit 0)
                         :error-kind 'transport :response oauth-error)
                   (list :body "not JSON"
                         :transport '(:status succeeded :http-status-code 200 :curl-exit 0)
                         :error-kind 'json)))
      (let ((call-count 0))
        ;; Replace only the public transport boundary; no OpenAI call occurs.
        (cl-letf (((symbol-function 'faye-curl-start)
                   (lambda (request on-event on-result)
                     (should (equal request http-request))
                     (setq call-count (1+ call-count))
                     (run-at-time
                      0 nil
                      (lambda ()
                        (let* ((bytes (plist-get scenario :body))
                               (split (/ (length bytes) 2)))
                          (funcall on-event (list :type 'body :bytes (substring bytes 0 split)))
                          (funcall on-event (list :type 'body :bytes (substring bytes split)))
                          (funcall on-result (plist-get scenario :transport))))))))
          (let ((result
                 (faye-openai-auth-test--await
                  (lambda (on-result)
                    (faye-openai-auth-send-request http-request on-result)))))
            (should (= call-count 1))
            (if (plist-get scenario :error-kind)
                (let* ((error-data (plist-get result :error))
                       (details (plist-get error-data :data)))
                  (should (eq (plist-get result :status) 'failed))
                  (should (eq (plist-get error-data :kind) (plist-get scenario :error-kind)))
                  (should (equal (plist-get details :transport) (plist-get scenario :transport)))
                  (should (equal (plist-get details :response) (plist-get scenario :response))))
              (let ((value (plist-get result :value)))
                (should (eq (plist-get result :status) 'succeeded))
                (should (equal (plist-get value :response) token-response))
                (should (string-match-p
                         "\\`[0-9-]+T[0-9:]+Z\\'" (plist-get value :received-at)))))))))))

(ert-deftest faye-openai-auth-test-random-bytes ()
  "Read binary random bytes asynchronously and handle a missing OpenSSL executable."
  (let ((result (faye-openai-auth-test--await
                 (lambda (on-result)
                   (faye-openai-auth--random-bytes 32 on-result)))))
    (should (eq (plist-get result :status) 'succeeded))
    (should (= (length (plist-get result :value)) 32))
    (should-not (multibyte-string-p (plist-get result :value))))
  (let* ((exec-path nil)
         (result (faye-openai-auth-test--await
                  (lambda (on-result)
                    (faye-openai-auth--random-bytes 32 on-result)))))
    (should (eq (plist-get result :status) 'failed))
    (should-not (get-process "faye-openssl"))
    (should-not (get-process "faye-openssl-stderr"))))

(ert-deftest faye-openai-auth-test-rs256-verification ()
  "Verify a locally signed input and reject it after modification."
  (let* ((directory (make-temp-file "faye-auth-key-test-" t))
         (private-key-file (expand-file-name "private.pem" directory))
         (signing-input "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0"))
    (unwind-protect
        (progn
          ;; This private key is a disposable local fixture, never a real credential.
          (faye-openai-auth-test--openssl-output
           (list "genpkey" "-algorithm" "RSA" "-pkeyopt" "rsa_keygen_bits:2048"
                 "-out" private-key-file))
          (let* ((modulus-output
                  (faye-openai-auth-test--openssl-output
                   (list "rsa" "-in" private-key-file "-noout" "-modulus")))
                 (modulus-hex
                  (progn
                    (should (string-match "Modulus=\\([0-9A-Fa-f]+\\)" modulus-output))
                    (match-string 1 modulus-output)))
                 (modulus-bytes
                  (apply #'unibyte-string
                         (cl-loop for index from 0 below (length modulus-hex) by 2
                                  collect (string-to-number
                                           (substring modulus-hex index (+ index 2)) 16))))
                 (public-key (list :kty "RSA" :n (base64url-encode-string modulus-bytes t)
                                   :e "AQAB"))
                 (signature
                  (faye-openai-auth-test--openssl-output
                   (list "dgst" "-sha256" "-sign" private-key-file) signing-input)))
            (should
             (equal (faye-openai-auth-test--await
                     (lambda (on-result)
                       (faye-openai-auth--verify-rs256-signature
                        public-key signing-input signature on-result)))
                    '(:status succeeded :value t)))
            (let ((result
                   (faye-openai-auth-test--await
                    (lambda (on-result)
                      (faye-openai-auth--verify-rs256-signature
                       public-key (concat signing-input "x") signature on-result)))))
              (should (eq (plist-get result :status) 'failed)))))
      (delete-directory directory t))))

(provide 'faye-openai-auth-test)
;;; faye-openai-auth-test.el ends here
