;;; faye-openai-auth.el --- OpenAI registration and sign-in API  -*- lexical-binding: t; -*-

;;; Commentary:

;; API surface for the documented ChatGPT-plan registration and sign-in flow.
;; Sign-in composes browser authorization, code exchange, ID-token validation,
;; and credential storage.  Request and cryptographic helpers run asynchronously.
;; Inspect value snapshots with `faye-log-show'; the result callback receives
;; the saved credentials, including :access_token, on success.
;;
;; Credential record: JSON object, represented in Lisp as a keyword plist.
;; Fields match the documented local-file schema:
;;   email, issuer, subject, client_id, ext_agent_host_id, id_token,
;;   access_token, refresh_token, token_type, expires_in, scopes, saved_at.
;; scopes is a vector of granted scope strings.  saved_at is a UTC timestamp
;; captured when the token response arrives, before validation or file writing.
;; Before the first successful sign-in, a generated host ID stays in memory.
;; There is one provider-specific credentials file, not a separate host-ID file.
;;
;; ext_agent_host_id identifies an app-defined host, such as an installation
;; or VM.  Once saved it is stable across restarts and sign-ins, distinct per host,
;; and is not an authentication credential.  An issued client_id identifies
;; the user's OAuth registration; that registration can be used on several hosts.
;; A UUIDv4 URI (urn:uuid:...) is a supported host-ID format.
;;
;; Async operations take ON-RESULT, a function of one local result plist:
;;   (:status succeeded :value VALUE)
;;   (:status failed :error (:kind SYMBOL :message STRING))
;; An error may also carry :data for inspection.
;; Callbacks run after the operation starts and returns, exactly once at its
;; termination.  Callback and async-operation return values are ignored.
;; Synchronous builders and file operations return directly and signal errors.
;;
;; send-request success values are:
;;   (:response PROVIDER-JSON :received-at UTC-TIMESTAMP)
;; PROVIDER-JSON retains the provider's field names.  Receiving tokens is not
;; identity validation: sign-in verifies the ID token and granted permissions
;; before constructing and saving the credential record.
;;
;; Request templates contain fixed HTTP fields and parameter names, never code.
;; build-request combines a template with raw parameter values and returns the
;; HTTP plist consumed by faye-curl.el: :method, :url, :headers and :body.
;; The authorize URL is opened in the browser.  exchange-code, refresh-token
;; and jwks requests are executed by send-request through Request/Curl.
;;
;; Reference: https://developers.openai.com/siwc/token-sharing-open-source/sign-in

;;; Code:

(require 'url-util)
(require 'json)
(require 'cl-lib)
(require 'browse-url)
(require 'faye-log)
(require 'faye-req)
(require 'faye-curl)

(defconst faye-openai-auth--request-templates
  '((authorize
     :method "GET"
     :url "https://auth.openai.com/api/accounts/authorize"
     :encoding query
     :fixed-parameters
     (("response_type" . "code")
      ("scope" . "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
      ("resource" . "https://api.openai.com/v1")
      ("code_challenge_method" . "S256"))
     :required-parameters
     ("client_id" "ext_agent_host_id" "redirect_uri" "state" "nonce" "code_challenge")
     :optional-parameters
     ("agent_name_hint" "id_token_hint" "login_hint"))
    (exchange-code
     :method "POST"
     :url "https://auth.openai.com/api/accounts/oauth/token"
     :encoding form
     :headers (("Content-Type" . "application/x-www-form-urlencoded"))
     :fixed-parameters
     (("grant_type" . "authorization_code")
      ("resource" . "https://api.openai.com/v1"))
     :required-parameters
     ("client_id" "code" "code_verifier" "redirect_uri"))
    (refresh-token
     :method "POST"
     :url "https://auth.openai.com/api/accounts/oauth/token"
     :encoding form
     :headers (("Content-Type" . "application/x-www-form-urlencoded"))
     :fixed-parameters
     (("grant_type" . "refresh_token")
      ("resource" . "https://api.openai.com/v1"))
     :required-parameters
     ("client_id" "refresh_token"))
    (jwks
     :method "GET"
     :url "https://auth.openai.com/.well-known/jwks.json"
     :encoding nil))
  "OpenAI request templates keyed by documented operation.
Each entry supplies fixed HTTP fields and fixed/required/optional parameters.
Encoding is query for URL parameters, form for body parameters, or nil.
Registration versus reauthorization choices belong in authorization.")

(defvar faye-openai-auth-credentials-file
  (expand-file-name "faye/openai/credentials.json" user-emacs-directory)
  "Default path for the OpenAI credential record.")

(defvar faye-openai-auth-sign-in-timeout 300
  "Seconds to wait for the browser callback during sign-in.")

(defvar faye-openai-auth--host-id nil
  "In-memory fallback host ID, saved with credentials after successful sign-in.")

(defvar faye-openai-auth--sign-in-active-p nil
  "Non-nil while a sign-in owns the active account's credential update.")

(defun faye-openai-auth--failure (kind message &optional data)
  "Construct a failed result with KIND, MESSAGE and inspection DATA."
  (list :status 'failed :error (list :kind kind :message message :data data)))

(defun faye-openai-auth--log (&rest values)
  "Log explicitly selected VALUES without affecting execution.
Callers supply diagnostic fields, never raw tokens, callback URLs or identity."
  (ignore-errors (faye-log-debug "AUTH" (format "%S" values))))

;; Credential storage.

(defun faye-openai-auth-load-credentials (&optional file)
  "Read and validate the credential record from FILE as a keyword plist.
FILE defaults to `faye-openai-auth-credentials-file'.  Return nil for a missing
file, empty or whitespace-only contents, or an empty JSON object.  Signal an
error for unreadable data or a nonempty record with invalid or missing fields.
Check the stored structure, not token freshness: expired tokens still load."
  (let ((file-path (or file faye-openai-auth-credentials-file)))
    (when (file-exists-p file-path)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents file-path))
        (goto-char (point-min))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (unless (eq (char-after) ?{)
            (error "Credential record must be a JSON object"))
          (let ((credentials (json-parse-buffer
                              :object-type 'plist :array-type 'array
                              :null-object nil :false-object :false)))
            (skip-chars-forward " \t\r\n")
            (unless (eobp)
              (error "Unexpected content after credential record"))
            (when credentials
              (dolist (field '(:client_id :ext_agent_host_id :issuer :subject
                                          :id_token :access_token :refresh_token
                                          :token_type :saved_at))
                (let ((value (plist-get credentials field)))
                  (unless (and (stringp value) (> (length value) 0))
                    (error "Missing or invalid saved credential field: %s" field))))
              (when (equal (plist-get credentials :client_id) "dynamic_agent_client")
                (error "Saved client ID must be an issued registration"))
              (unless (equal (downcase (plist-get credentials :token_type)) "bearer")
                (error "Saved token type must be Bearer"))
              (unless (or (null (plist-get credentials :email))
                          (stringp (plist-get credentials :email)))
                (error "Saved email must be a string or null"))
              (unless (and (numberp (plist-get credentials :expires_in))
                           (> (plist-get credentials :expires_in) 0))
                (error "Saved expires_in must be a positive number"))
              (let ((scopes (plist-get credentials :scopes)))
                (unless (and (vectorp scopes)
                             (cl-every (lambda (scope)
                                         (and (stringp scope) (> (length scope) 0)))
                                       scopes))
                  (error "Saved scopes must be an array of nonempty strings"))))
            credentials))))))

(defun faye-openai-auth-save-credentials (credentials &optional file)
  "Atomically write CREDENTIALS to FILE and return CREDENTIALS on success.
FILE defaults to `faye-openai-auth-credentials-file'.  Use the documented JSON
field names and restrictive file permissions.  A failed replacement leaves
the previous file intact and signals an error."
  (unless (and (listp credentials) (keywordp (car credentials)))
    (error "Credentials must be a nonempty keyword plist"))
  (let* ((file-path (expand-file-name (or file faye-openai-auth-credentials-file)))
         (directory (file-name-directory file-path))
         (json-bytes (json-serialize credentials :null-object nil :false-object :false)))
    (make-directory directory t)
    (let ((temporary-file (make-temp-file (expand-file-name ".credentials-" directory))))
      (unwind-protect
          (progn
            (set-file-modes temporary-file #o600)
            (let ((coding-system-for-write 'binary))
              (write-region json-bytes nil temporary-file nil 'silent))
            ;; Same-directory rename replaces the complete record in one step.
            (rename-file temporary-file file-path t)
            credentials)
        (when (file-exists-p temporary-file)
          (delete-file temporary-file))))))

;; Registration and sign-in.

(defun faye-openai-auth-sign-in (on-result &optional credentials-file)
  "Perform registration or reauthorization and report through ON-RESULT.
CREDENTIALS-FILE defaults to `faye-openai-auth-credentials-file'.
This method composes the documented steps: load saved data, prepare the host
and fresh authorization values, start the listener, open the authorization
URL, validate the callback, exchange the code, verify the ID token and granted
permissions, and save credentials.  ON-RESULT receives saved credentials as
its success value, including :access_token.  Inspect progress with
`faye-log-show'.  Only one sign-in may run at a time.

Reuse the saved host ID, or generate an in-memory fallback and persist it only
with successful credentials.  A restart before that save may change the ID.
Callbacks run after this function returns.  The browser wait is bounded by
`faye-openai-auth-sign-in-timeout'.  Release the listener on completion or
failure."
  (unless (functionp on-result)
    (error "ON-RESULT must be a function"))
  (let ((credentials-file (expand-file-name
                           (or credentials-file faye-openai-auth-credentials-file)))
        (done-p nil)
        (owns-sign-in-lock-p nil)
        saved-credentials auth-result)
    (cl-labels
        ((finish (result)
           (unless done-p
             (setq done-p t)
             ;; A busy rejection must not release another sign-in's lock.
             (when owns-sign-in-lock-p
               (setq faye-openai-auth--sign-in-active-p nil))
             (faye-openai-auth--log
              :operation 'sign-in :status (plist-get result :status)
              :error-kind (plist-get (plist-get result :error) :kind)
              :message (plist-get (plist-get result :error) :message))
             (ignore-errors (funcall on-result result))))

         (start ()
           (condition-case error-data
               (if faye-openai-auth--sign-in-active-p
                   (finish (faye-openai-auth--failure 'busy "Sign-in is already running"))
                 (setq owns-sign-in-lock-p t faye-openai-auth--sign-in-active-p t)
                 (setq saved-credentials
                       (faye-openai-auth-load-credentials credentials-file))
                 (faye-openai-auth--authorize saved-credentials #'exchange-code))
             ((error quit)
              (finish (faye-openai-auth--failure
                       'preparation "Could not prepare sign-in" error-data)))))

         (exchange-code (result)
           (if (eq (plist-get result :status) 'succeeded)
               (condition-case error-data
                   (progn
                     (setq auth-result (plist-get result :value))
                     (faye-openai-auth-send-request
                      (faye-openai-auth-build-request
                       'exchange-code
                       `(("client_id" . ,(plist-get auth-result :client-id))
                         ("code" . ,(plist-get auth-result :code))
                         ("code_verifier" . ,(plist-get auth-result :code-verifier))
                         ("redirect_uri" . ,(plist-get auth-result :redirect-uri))))
                      #'verify-tokens))
                 ((error quit)
                  (finish (faye-openai-auth--failure
                           'exchange "Could not exchange authorization code" error-data))))
             (finish result)))

         (verify-tokens (result)
           (if (eq (plist-get result :status) 'succeeded)
               (condition-case error-data
                   (let ((token-result (plist-get result :value)))
                     (faye-openai-auth--verify-token-response
                      (plist-get token-result :response)
                      (plist-get token-result :received-at)
                      auth-result saved-credentials
                      (lambda (verification-result)
                        (if (eq (plist-get verification-result :status) 'succeeded)
                            (condition-case error-data
                                (let ((credentials (plist-get verification-result :value)))
                                  (faye-openai-auth-save-credentials credentials credentials-file)
                                  (faye-openai-auth--log
                                   :operation 'save-credentials
                                   :saved-at (plist-get credentials :saved_at))
                                  (finish verification-result))
                              ((error quit)
                               (finish (faye-openai-auth--failure
                                        'storage "Could not save credentials" error-data))))
                          (finish verification-result)))))
                 ((error quit)
                  (finish (faye-openai-auth--failure
                           'token "Invalid token response" error-data))))
             (finish result))))
      (run-at-time 0 nil #'start)))
  nil)

(defun faye-openai-auth--authorize (saved-credentials on-result)
  "Authorize in the browser using SAVED-CREDENTIALS, or register when nil.
Own authorization values, the listener and its timeout.  ON-RESULT receives
an async result whose success value contains :code, :client-id, :host-id,
:code-verifier, :redirect-uri and :nonce for exchange and token verification.
Close the listener before delivering the result."
  (let* ((client-registration-needed-p (null saved-credentials))
         (client-id (if client-registration-needed-p "dynamic_agent_client"
                      (plist-get saved-credentials :client_id)))
         (host-id (or (plist-get saved-credentials :ext_agent_host_id)
                      faye-openai-auth--host-id))
         (done-p nil)
         listener browser-timer state nonce code-verifier redirect-uri)
    (cl-labels
        ((finish (result)
           (unless done-p
             (setq done-p t)
             (unwind-protect
                 (progn
                   (when browser-timer (cancel-timer browser-timer))
                   (faye-openai-auth--stop-callback-listener listener))
               (ignore-errors (funcall on-result result)))))

         (accept-code (parameters)
           ;; Browser callbacks and the timeout compete for one completion.
           (unless done-p
             (condition-case error-data
                 (progn
                   (dolist (name '("code" "state" "client_id" "error" "error_description" "scope"))
                     (when (> (cl-count name parameters :key #'car :test #'equal) 1)
                       (error "Duplicate callback parameter: %s" name)))
                   (let ((code (cdr (assoc "code" parameters)))
                         (returned-client-id (cdr (assoc "client_id" parameters)))
                         (oauth-error (assoc "error" parameters))
                         (state-match-p (equal (cdr (assoc "state" parameters)) state)))
                     (faye-openai-auth--log
                      :operation 'authorize :state-match-p state-match-p
                      :code-present-p (and code t) :oauth-error-p (and oauth-error t)
                      :client-id-present-p (and returned-client-id t)
                      :client-id-match-p (equal returned-client-id client-id))
                     (unless state-match-p (error "Callback state does not match"))
                     (if oauth-error
                         (finish (faye-openai-auth--failure
                                  'oauth "Authorization was not granted" parameters))
                       (unless (and (stringp code) (> (length code) 0))
                         (error "Missing authorization code"))
                       (if client-registration-needed-p
                           (unless (and (stringp returned-client-id)
                                        (> (length returned-client-id) 0)
                                        (not (equal returned-client-id "dynamic_agent_client")))
                             (error "Registration did not return an issued client ID"))
                         (when (and returned-client-id (not (equal returned-client-id client-id)))
                           (error "Callback client ID does not match")))
                       (finish
                        (list :status 'succeeded
                              :value (list :code code :client-id (or returned-client-id client-id)
                                           :host-id host-id :code-verifier code-verifier
                                           :redirect-uri redirect-uri :nonce nonce))))))
               ((error quit)
                (finish (faye-openai-auth--failure
                         'callback "Invalid authorization callback" error-data))))))

         (start ()
           (condition-case error-data
               (progn
                 (faye-openai-auth--log
                  :operation 'authorize :client-registration-needed-p client-registration-needed-p
                  :host-id-source
                  (cond ((plist-get saved-credentials :ext_agent_host_id) 'credentials)
                        (host-id 'memory) (t 'generated)))
                 ;; Independent slices: state, nonce, verifier, then UUID material.
                 (faye-openai-auth--random-bytes
                  112
                  (lambda (result)
                    (if (eq (plist-get result :status) 'succeeded)
                        (condition-case error-data
                            (let ((bytes (plist-get result :value)))
                              (setq state (base64url-encode-string (substring bytes 0 32) t)
                                    nonce (base64url-encode-string (substring bytes 32 64) t)
                                    code-verifier (base64url-encode-string
                                                   (substring bytes 64 96) t))
                              (unless host-id
                                (setq host-id (faye-openai-auth--uuid-v4 (substring bytes 96 112))
                                      faye-openai-auth--host-id host-id))
                              (setq listener
                                    (faye-openai-auth--start-callback-listener #'accept-code)
                                    redirect-uri (format "http://127.0.0.1:%d/auth/callback"
                                                         (process-contact listener :service)))
                              (let ((parameters
                                     `(("client_id" . ,client-id) ("ext_agent_host_id" . ,host-id)
                                       ("redirect_uri" . ,redirect-uri)
                                       ("state" . ,state) ("nonce" . ,nonce)
                                       ("code_challenge"
                                        . ,(base64url-encode-string
                                            (secure-hash 'sha256 code-verifier nil nil t) t)))))
                                (if client-registration-needed-p
                                    (push '("agent_name_hint" . "Faye") parameters)
                                  (when (plist-get saved-credentials :id_token)
                                    (push (cons "id_token_hint"
                                                (plist-get saved-credentials :id_token))
                                          parameters))
                                  (when (plist-get saved-credentials :email)
                                    (push (cons "login_hint" (plist-get saved-credentials :email))
                                          parameters)))
                                (setq browser-timer
                                      (run-at-time
                                       faye-openai-auth-sign-in-timeout nil
                                       (lambda ()
                                         (finish
                                          (faye-openai-auth--failure
                                           'timeout
                                           "Timed out waiting for authorization callback")))))
                                (faye-openai-auth--log
                                 :operation 'authorize :redirect-uri redirect-uri
                                 :state-length (length state) :nonce-length (length nonce)
                                 :verifier-length (length code-verifier))
                                (browse-url
                                 (plist-get
                                  (faye-openai-auth-build-request 'authorize parameters)
                                  :url))))
                          ((error quit)
                           (finish (faye-openai-auth--failure
                                    'authorization "Could not start browser authorization"
                                    error-data))))
                      (finish result)))))
             ((error quit)
              (finish (faye-openai-auth--failure
                       'authorization "Could not prepare authorization" error-data))))))
      (run-at-time 0 nil #'start)))
  nil)

(defun faye-openai-auth--verify-token-response
    (token-response received-at auth-result saved-credentials on-result)
  "Verify TOKEN-RESPONSE and deliver a credential plist through ON-RESULT.
RECEIVED-AT is the token receipt timestamp.  AUTH-RESULT is the successful
authorization value containing the client ID, host ID and nonce.
SAVED-CREDENTIALS supplies the expected identity for a returning sign-in.
This async wrapper validates token fields, verifies the ID token and builds
the credential record.  Its caller owns saving the record.  All callbacks,
including validation failures, run after this function returns."
  (run-at-time
   0 nil
   (lambda ()
     (condition-case error-data
         (let ((scopes (faye-openai-auth--validate-token-response token-response)))
           (faye-openai-auth--verify-id-token
            (plist-get token-response :id_token)
            (plist-get auth-result :client-id)
            (plist-get auth-result :nonce)
            saved-credentials
            (lambda (result)
              (when (eq (plist-get result :status) 'succeeded)
                (setq result
                      (condition-case error-data
                          (let* ((claims (plist-get result :value))
                                 (credentials
                                  (list :email (plist-get claims :email)
                                        :issuer (plist-get claims :iss)
                                        :subject (plist-get claims :sub)
                                        :client_id (plist-get auth-result :client-id)
                                        :ext_agent_host_id (plist-get auth-result :host-id)
                                        :id_token (plist-get token-response :id_token)
                                        :access_token (plist-get token-response :access_token)
                                        :refresh_token (plist-get token-response :refresh_token)
                                        :token_type (plist-get token-response :token_type)
                                        :expires_in (plist-get token-response :expires_in)
                                        :scopes scopes :saved_at received-at)))
                            (list :status 'succeeded :value credentials))
                        ((error quit)
                         (faye-openai-auth--failure
                          'credentials "Could not build credential record" error-data)))))
              (ignore-errors (funcall on-result result)))))
       ((error quit)
        (ignore-errors
          (funcall on-result
                   (faye-openai-auth--failure
                    'token "Invalid token response" error-data)))))))
  nil)

(defun faye-openai-auth--validate-token-response (token-response)
  "Validate TOKEN-RESPONSE fields and plan permission; return a scopes vector."
  (dolist (field '(:access_token :refresh_token :id_token :token_type :scope))
    (let ((value (plist-get token-response field)))
      (unless (and (stringp value) (> (length value) 0))
        (error "Missing or invalid token field: %s" field))))
  (let ((scopes (split-string (plist-get token-response :scope) " +" t)))
    (faye-openai-auth--log
     :operation 'validate-token-response :token-type (plist-get token-response :token_type)
     :expires-in (plist-get token-response :expires_in) :scopes scopes
     :access-token-bytes (string-bytes (plist-get token-response :access_token))
     :refresh-token-present-p t :id-token-present-p t)
    (unless (and (equal (downcase (plist-get token-response :token_type)) "bearer")
                 (numberp (plist-get token-response :expires_in))
                 (> (plist-get token-response :expires_in) 0)
                 (member "chatgpt.tokens.use.direct" scopes))
      (error "Invalid token type, expiry or granted plan scope"))
    (vconcat scopes)))

(defun faye-openai-auth--verify-id-token
    (id-token client-id nonce saved-credentials on-result)
  "Verify ID-TOKEN for CLIENT-ID and NONCE, reporting through ON-RESULT.
Fetch trusted JWKS, verify the RS256 signature, and validate claims.  When
SAVED-CREDENTIALS is non-nil, require its identity to match.  The async success
value is the verified claims object."
  (let (header claims signing-input signature)
    (cl-labels
        ((finish (result)
           (ignore-errors (funcall on-result result)))

         (start ()
           (condition-case error-data
               (let ((parts (split-string id-token "\\.")))
                 (unless (= (length parts) 3)
                   (error "Expected a three-part ID token"))
                 (setq header (faye-openai-auth--decode-jwt-object (car parts)))
                 (unless (and (equal (plist-get header :alg) "RS256")
                              (stringp (plist-get header :kid))
                              (> (length (plist-get header :kid)) 0)
                              (not (plist-member header :crit))
                              (not (plist-member header :b64)))
                   (error "Expected an RS256 ID token with a key ID"))
                 (setq claims (faye-openai-auth--decode-jwt-object (nth 1 parts))
                       signing-input (encode-coding-string
                                      (concat (car parts) "." (nth 1 parts)) 'us-ascii)
                       signature (base64-decode-string (nth 2 parts) t))
                 (faye-openai-auth-send-request
                  (faye-openai-auth-build-request 'jwks nil) #'verify-signature))
             ((error quit)
              (finish (faye-openai-auth--failure
                       'id-token "Could not decode ID token" error-data)))))

         (verify-signature (result)
           (if (eq (plist-get result :status) 'succeeded)
               (condition-case error-data
                   (let ((public-key
                          (faye-openai-auth--select-signing-key
                           (plist-get (plist-get result :value) :response)
                           (plist-get header :kid))))
                     (faye-openai-auth--verify-rs256-signature
                      public-key signing-input signature
                      (lambda (verification-result)
                        (if (eq (plist-get verification-result :status) 'succeeded)
                            (condition-case error-data
                                (finish
                                 (list :status 'succeeded
                                       :value (faye-openai-auth--validate-id-token-claims
                                               claims client-id nonce saved-credentials)))
                              ((error quit)
                               (finish (faye-openai-auth--failure
                                        'id-token "Invalid ID-token claims" error-data))))
                          (finish verification-result)))))
                 ((error quit)
                  (finish (faye-openai-auth--failure
                           'jwks "Could not select or use signing key" error-data))))
             (finish result))))
      (run-at-time 0 nil #'start)))
  nil)

(defun faye-openai-auth--select-signing-key (jwks key-id)
  "Return the unique RS256 signing key for KEY-ID in JWKS, or signal an error."
  (let* ((keys (plist-get jwks :keys))
         (matches (and (vectorp keys)
                       (cl-remove-if-not
                        (lambda (key) (equal (plist-get key :kid) key-id))
                        (append keys nil))))
         (key (car matches)))
    (faye-openai-auth--log
     :operation 'select-signing-key :kid key-id :matching-key-count (length matches))
    (unless (and (= (length matches) 1)
                 (equal (plist-get key :kty) "RSA")
                 (or (not (plist-member key :alg)) (equal (plist-get key :alg) "RS256"))
                 (or (not (plist-member key :use)) (equal (plist-get key :use) "sig"))
                 (or (not (plist-member key :key_ops))
                     (and (vectorp (plist-get key :key_ops))
                          (member "verify" (append (plist-get key :key_ops) nil)))))
      (error "No unique compatible signing key"))
    key))

(defun faye-openai-auth--validate-id-token-claims (claims client-id nonce saved-credentials)
  "Validate signed CLAIMS against CLIENT-ID, NONCE and SAVED-CREDENTIALS.
Return CLAIMS on success; signal an error if any required check fails."
  (let* ((issuer (plist-get claims :iss))
         (subject (plist-get claims :sub))
         (audience (plist-get claims :aud))
         (audiences (if (stringp audience) (list audience)
                      (and (vectorp audience) (append audience nil))))
         (azp (plist-get claims :azp))
         (expiry (plist-get claims :exp))
         (not-before (plist-get claims :nbf))
         (now (float-time))
         (issuer-match-p (equal issuer "https://auth.openai.com"))
         (audience-match-p (and audiences (cl-every #'stringp audiences)
                                (member client-id audiences) t))
         (nonce-match-p (equal (plist-get claims :nonce) nonce))
         (identity-match-p (or (null saved-credentials)
                               (and (equal issuer (plist-get saved-credentials :issuer))
                                    (equal subject (plist-get saved-credentials :subject))))))
    (faye-openai-auth--log
     :operation 'validate-id-token-claims :signature-valid-p t
     :issuer-match-p issuer-match-p :audience-match-p audience-match-p
     :nonce-match-p nonce-match-p :identity-match-p identity-match-p
     :exp expiry :nbf not-before :now now)
    (unless (and issuer-match-p audience-match-p nonce-match-p identity-match-p
                 (stringp subject) (> (length subject) 0)
                 (numberp expiry) (> expiry now)
                 (or (not (plist-member claims :nbf))
                     (and (numberp not-before) (<= not-before now)))
                 (if (or (plist-member claims :azp) (> (length audiences) 1))
                     (equal azp client-id)
                   t))
      (error "ID-token claims do not match this authorization"))
    claims))

(defun faye-openai-auth--uuid-v4 (bytes)
  "Format sixteen random BYTES as a UUIDv4 URI."
  (let ((octets (copy-sequence bytes)))
    (aset octets 6 (logior #x40 (logand (aref octets 6) #x0f)))
    (aset octets 8 (logior #x80 (logand (aref octets 8) #x3f)))
    (let ((hex (mapconcat (lambda (byte) (format "%02x" byte)) octets "")))
      (format "urn:uuid:%s-%s-%s-%s-%s"
              (substring hex 0 8) (substring hex 8 12) (substring hex 12 16)
              (substring hex 16 20) (substring hex 20 32)))))

(defun faye-openai-auth--decode-jwt-object (segment)
  "Decode a base64url JWT SEGMENT as a JSON object, without trusting it."
  (unless (and (stringp segment) (string-match-p "\\`[A-Za-z0-9_-]+\\'" segment))
    (error "Invalid JWT segment encoding"))
  (let ((bytes (base64-decode-string segment t)))
    (unless (string-match-p "\\`[ \t\r\n]*{" bytes)
      (error "JWT header and claims must be JSON objects"))
    (json-parse-string bytes :object-type 'plist :array-type 'array
                       :null-object nil :false-object :false)))

(defun faye-openai-auth--start-callback-listener (on-callback)
  "Start a loopback listener on 127.0.0.1 and return its process object.
Choose an available port, obtainable with `process-contact'.  Accept the
documented /auth/callback path.  ON-CALLBACK receives decoded query parameters
as an alist of string pairs; preserve duplicate entries for caller validation.
Authorization owns callback state/client-ID checks and listener lifetime."
  (let (server)
    (cl-labels
        ((reply (connection status text)
           (set-process-filter connection #'ignore)
           (process-send-string
            connection
            (concat "HTTP/1.1 " status "\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    "Connection: close\r\nCache-Control: no-store\r\n"
                    "Content-Length: " (number-to-string (string-bytes text)) "\r\n\r\n" text))
           (process-send-eof connection))

         (decode-value (value)
           ;; Replace + before percent decoding, so %2B stays a literal plus.
           (when (string-match-p
                  "%\\(?:[^0-9A-Fa-f]\\|[0-9A-Fa-f][^0-9A-Fa-f]\\|[0-9A-Fa-f]?\\'\\)"
                  value)
             (error "Invalid query escape"))
           (decode-coding-string
            (url-unhex-string (replace-regexp-in-string "+" " " value t t)) 'utf-8-unix))

         (receive (connection chunk)
           (condition-case nil
               (let* ((bytes (concat (process-get connection 'faye-auth-request) chunk))
                      (end (string-match "\r\n\r\n" bytes)))
                 (process-put connection 'faye-auth-request bytes)
                 (cond
                  ((> (length bytes) 16384)
                   (reply connection "431 Request Header Fields Too Large" "Request too large."))
                  (end
                   (unless (string-match "\\`GET \\([^ \r\n]+\\) HTTP/1\\.[01]\r\n" bytes)
                     (error "Expected an HTTP GET request"))
                   (let* ((target (match-string 1 bytes))
                          (query-start (string-match "?" target))
                          (path (if query-start (substring target 0 query-start) target)))
                     (if (not (equal path "/auth/callback"))
                         (reply connection "404 Not Found" "Not found.")
                       (let ((parameters
                              (mapcar
                               (lambda (field)
                                 (let ((equals (string-match "=" field)))
                                   (cons (decode-value
                                          (if equals (substring field 0 equals) field))
                                         (decode-value
                                          (if equals (substring field (1+ equals)) "")))))
                               (split-string
                                (if query-start (substring target (1+ query-start)) "")
                                "&" t))))
                         (reply connection "200 OK" "Callback received; return to Emacs.")
                         (process-put connection 'faye-auth-request nil)
                         (funcall on-callback parameters)))))))
             (error
              (when (process-live-p connection)
                (ignore-errors (reply connection "400 Bad Request" "Invalid request.")))))))
      (setq server
            (make-network-process
             :name "faye-auth-callback" :server t :family 'ipv4
             :host "127.0.0.1" :service t :coding 'binary :noquery t
             :filter #'receive
             :sentinel (lambda (connection _message)
                         (unless (process-live-p connection)
                           (process-put server 'faye-auth-connections
                                        (delq connection
                                              (process-get server 'faye-auth-connections)))
                           (process-put connection 'faye-auth-request nil)))
             :log (lambda (_server connection _message)
                    (process-put server 'faye-auth-connections
                                 (cons connection (process-get server 'faye-auth-connections)))))))
    server))

(defun faye-openai-auth--stop-callback-listener (listener-process)
  "Close LISTENER-PROCESS and its accepted connections, idempotently."
  (when listener-process
    (dolist (process (cons listener-process (process-get listener-process 'faye-auth-connections)))
      (set-process-filter process #'ignore)
      (set-process-sentinel process #'ignore)
      (process-put process 'faye-auth-request nil)
      (ignore-errors (delete-process process)))
    (process-put listener-process 'faye-auth-connections nil)))

;; Shared request construction and execution.

(defun faye-openai-auth-build-request (operation parameters)
  "Build an HTTP request for OPERATION using raw PARAMETERS.
OPERATION is authorize, exchange-code, refresh-token or jwks.
PARAMETERS is an alist of unique parameter-name/raw-string-value pairs.
Required and optional names are listed in `faye-openai-auth--request-templates'.
Reject missing, unknown, duplicate or fixed-parameter overrides.

Combine fixed parameters with supplied parameters, in that order, and encode
each name and value once.  Query encoding appends them to :url; form encoding
puts UTF-8 bytes in :body.  Return :method, :url, :headers and :body as a plist.
The caller opens authorize's URL in the browser; other operations can be
passed to `faye-openai-auth-send-request'."
  (let* ((template (alist-get operation faye-openai-auth--request-templates))
         (required (plist-get template :required-parameters))
         (allowed (append required (plist-get template :optional-parameters))))
    (unless template
      (error "Unknown OpenAI auth operation: %S" operation))
    (unless (listp parameters)
      (error "Parameters must be an alist of names and raw string values"))
    (dolist (parameter parameters)
      (let ((name (car parameter))
            (value (cdr parameter)))
        (unless (member name allowed)
          (error "Unexpected parameter for %S: %S" operation name))
        (unless (stringp value)
          (error "Parameter %s must be a raw string" name))))
    (unless (= (length parameters)
               (length (delete-dups (mapcar #'car parameters))))
      (error "Duplicate parameter names"))
    (dolist (name required)
      (unless (assoc name parameters)
        (error "Missing parameter for %S: %s" operation name)))

    (let* ((fields (append (plist-get template :fixed-parameters) parameters))
           (encoded-parameters
            (mapconcat
             (lambda (field)
               (let ((name (car field))
                     (value (cdr field)))
                 (concat (url-hexify-string name) "=" (url-hexify-string value))))
             fields
             "&"))
           (encoding (plist-get template :encoding))
           (url (copy-sequence (plist-get template :url))))
      (list :method (copy-sequence (plist-get template :method))
            :url (if (eq encoding 'query)
                     (concat url "?" encoded-parameters)
                   url)
            :headers (copy-tree (plist-get template :headers))
            :body (when (eq encoding 'form)
                    (encode-coding-string encoded-parameters 'utf-8-unix))))))

(defun faye-openai-auth-send-request (http-request on-result)
  "Execute HTTP-REQUEST through Request/Curl and report JSON via ON-RESULT.
Collect body events and decode the completed response.  The success value is
(:response PROVIDER-JSON :received-at UTC-TIMESTAMP), retaining the provider's
field names.  Capture receipt time before further validation or persistence.

Report transport and JSON-decoding failures explicitly; retain available
transport/response details in the error's :data.  OAuth error interpretation,
ID-token validation and credential persistence belong in the caller.
Authorization URLs are opened in the browser instead of sent by this helper."
  (unless (functionp on-result)
    (error "ON-RESULT must be a function"))
  (let ((request
         (faye-req-create
          http-request
          (lambda (payload _emit-event emit-result)
            ;; Each attempt gets its own accumulator; responses never mingle.
            (let (body-chunks)
              (condition-case error-data
                  (faye-curl-start
                   payload
                   (lambda (event)
                     (when (eq (plist-get event :type) 'body)
                       (push (plist-get event :bytes) body-chunks)))
                   (lambda (transport-result)
                     (let ((received-at (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                           (body-bytes (apply #'concat (nreverse body-chunks)))
                           response decode-error)
                       (condition-case error-data
                           (setq response
                                 (json-parse-string
                                  body-bytes :object-type 'plist :array-type 'array
                                  :null-object nil :false-object :false))
                         (error (setq decode-error error-data)))
                       (faye-openai-auth--log
                        :transport transport-result :body-bytes (length body-bytes)
                        :json-error (car decode-error))
                       (funcall
                        emit-result
                        (cond
                         ((not (eq (plist-get transport-result :status) 'succeeded))
                          (faye-openai-auth--failure
                           'transport "OpenAI HTTP request failed"
                           (list :transport transport-result :response response
                                 :body body-bytes :decode-error decode-error)))
                         (decode-error
                          (faye-openai-auth--failure
                           'json "OpenAI response could not be decoded as JSON"
                           (list :transport transport-result :body body-bytes
                                 :decode-error decode-error)))
                         (t
                          (list :status 'succeeded
                                :value (list :response response
                                             :received-at received-at))))))))
                (error
                 (funcall emit-result
                          (faye-openai-auth--failure
                           'transport "Could not start OpenAI HTTP request"
                           error-data)))))))))
    ;; OAuth retry classification is a separate policy; use one attempt for now.
    (faye-req-start request nil
                    (lambda (_request result)
                      (ignore-errors (funcall on-result result))))))

;; Atomic cryptographic operations.
;; Authorization and ID-token verification compose these operations.

(defun faye-openai-auth--run-openssl (arguments input-bytes on-result)
  "Run OpenSSL with ARGUMENTS asynchronously, sending INPUT-BYTES when non-nil.
Report stdout bytes on success or a crypto failure with exit/stderr details.
This helper owns both process objects; its caller owns any argument files."
  (let ((command (cons "openssl" arguments))
        (openssl-process nil)
        (stderr-pipe-process nil)
        (stdout-chunks nil)
        (stderr-chunks nil)
        (done-p nil))
    (cl-labels
        ((finish (exit-code &optional cause)
           (unless done-p
             (setq done-p t)
             (let ((result
                    (if (eq exit-code 0)
                        (list :status 'succeeded
                              :value (apply #'concat (nreverse stdout-chunks)))
                      (faye-openai-auth--failure
                       'crypto "OpenSSL operation failed"
                       (list :exit-code exit-code :cause cause
                             :stderr (apply #'concat (nreverse stderr-chunks)))))))
               (unwind-protect
                   (dolist (process (list openssl-process stderr-pipe-process))
                     (when process
                       (set-process-sentinel process #'ignore)
                       (delete-process process)))
                 (ignore-errors (funcall on-result result))))))

         (on-process-change (process _message)
           (unless (process-live-p process)
             (process-put process 'faye-openai-auth-ended-p t))
           (when (and openssl-process stderr-pipe-process
                      (process-get openssl-process 'faye-openai-auth-ended-p)
                      (process-get stderr-pipe-process 'faye-openai-auth-ended-p))
             (finish (when (eq (process-status openssl-process) 'exit)
                       (process-exit-status openssl-process)))))

         (on-stdout (_process bytes)
           (unless done-p (push bytes stdout-chunks)))

         (on-stderr (_process bytes)
           (unless done-p (push bytes stderr-chunks)))

         (start ()
           (condition-case error-data
               (progn
                 (setq stderr-pipe-process
                       (make-pipe-process
                        :name "faye-openssl-stderr" :buffer nil
                        :coding 'binary :noquery t
                        :filter #'on-stderr :sentinel #'on-process-change))
                 (let ((process-environment
                        (if (eq system-type 'windows-nt)
                            (cons (concat "MSYS=" (getenv "MSYS") " noglob")
                                  process-environment)
                          process-environment)))
                   (setq openssl-process
                         (make-process
                          :name "faye-openssl" :buffer nil :command command
                          :connection-type 'pipe :coding 'binary :noquery t
                          :stderr stderr-pipe-process
                          :filter #'on-stdout :sentinel #'on-process-change)))
                 (when input-bytes
                   (process-send-string openssl-process input-bytes)
                   (process-send-eof openssl-process)))
             (error (finish nil error-data)))))
      (run-at-time 0 nil #'start)))
  nil)

(defun faye-openai-auth--random-bytes (byte-count on-result)
  "Obtain BYTE-COUNT cryptographically secure bytes using OpenSSL.
BYTE-COUNT is a positive integer.  ON-RESULT receives a unibyte string as its
success value.  The caller chooses its use and encoding: state, nonce,
code_verifier or host-ID material."
  (unless (and (integerp byte-count) (> byte-count 0) (functionp on-result))
    (error "Expected a positive byte count and a callback function"))
  (faye-openai-auth--run-openssl
   (list "rand" (number-to-string byte-count)) nil
   (lambda (result)
     (when (eq (plist-get result :status) 'succeeded)
       (unless (= (length (plist-get result :value)) byte-count)
         (setq result (faye-openai-auth--failure 'crypto "Unexpected random byte count"))))
     (funcall on-result result))))

(defun faye-openai-auth--der-value (tag contents)
  "Encode a DER value with TAG and unibyte CONTENTS."
  (let ((size (length contents))
        (length-bytes nil))
    (if (< size 128)
        (setq length-bytes (unibyte-string size))
      (let (octets)
        (while (> size 0)
          (push (logand size 255) octets)
          (setq size (ash size -8)))
        (setq length-bytes
              (apply #'unibyte-string (cons (+ 128 (length octets)) octets)))))
    (concat (unibyte-string tag) length-bytes contents)))

(defun faye-openai-auth--rsa-public-key-der (public-key)
  "Convert RSA JWK PUBLIC-KEY to a DER SubjectPublicKeyInfo value.
This is key-format conversion only; OpenSSL performs signature verification."
  (unless (equal (plist-get public-key :kty) "RSA")
    (error "Expected an RSA JWK"))
  (cl-flet
      ((encode-integer (value)
         (let ((bytes (base64-decode-string value t)))
           (while (and (> (length bytes) 1) (= (aref bytes 0) 0))
             (setq bytes (substring bytes 1)))
           (when (or (= (length bytes) 0)
                     (and (= (length bytes) 1) (= (aref bytes 0) 0)))
             (error "RSA key integers must be positive"))
           ;; DER INTEGER is signed; prefix a zero when the high bit is set.
           (when (>= (aref bytes 0) 128)
             (setq bytes (concat (unibyte-string 0) bytes)))
           (faye-openai-auth--der-value #x02 bytes))))
    (let ((rsa-key
           (faye-openai-auth--der-value
            #x30 (concat (encode-integer (plist-get public-key :n))
                         (encode-integer (plist-get public-key :e)))))
          ;; AlgorithmIdentifier: rsaEncryption OID followed by NULL.
          (algorithm
           (unibyte-string #x30 #x0d #x06 #x09 #x2a #x86 #x48 #x86
                           #xf7 #x0d #x01 #x01 #x01 #x05 #x00)))
      (faye-openai-auth--der-value
       #x30 (concat algorithm
                    (faye-openai-auth--der-value
                     #x03 (concat (unibyte-string 0) rsa-key)))))))

(defun faye-openai-auth--verify-rs256-signature
    (public-key signing-input signature on-result)
  "Verify SIGNATURE over SIGNING-INPUT using PUBLIC-KEY and OpenSSL RS256.
PUBLIC-KEY is an RSA JWK from OpenAI's trusted JWKS, with kty, n and e fields.
SIGNING-INPUT is the original encoded-header.encoded-payload byte string;
SIGNATURE is the decoded signature byte string.  ON-RESULT receives t as its
success value.  An invalid signature or verification error reports failure.
The caller checks the ID token's algorithm and claims separately."
  (unless (and (stringp signing-input) (not (multibyte-string-p signing-input))
               (stringp signature) (not (multibyte-string-p signature))
               (functionp on-result))
    (error "Expected byte strings for signing input/signature and a callback"))
  (let ((signing-input (copy-sequence signing-input))
        (signature (copy-sequence signature)))
    (run-at-time
     0 nil
     (lambda ()
       (let ((key-file nil)
             (signature-file nil)
             (done-p nil))
         (cl-flet
             ((finish (result)
                (unless done-p
                  (setq done-p t)
                  (unwind-protect
                      (dolist (file (list key-file signature-file))
                        (when file (delete-file file)))
                    (ignore-errors (funcall on-result result))))))
           (condition-case error-data
               (let ((key-bytes (faye-openai-auth--rsa-public-key-der public-key)))
                 (setq key-file (make-temp-file "faye-auth-public-key-"))
                 (setq signature-file (make-temp-file "faye-auth-signature-"))
                 (let ((coding-system-for-write 'binary))
                   (write-region key-bytes nil key-file nil 'silent)
                   (write-region signature nil signature-file nil 'silent))
                 (faye-openai-auth--run-openssl
                  (list "dgst" "-sha256" "-verify" key-file "-keyform" "DER"
                        "-signature" signature-file "-sigopt" "rsa_padding_mode:pkcs1")
                  signing-input
                  (lambda (result)
                    (finish (if (eq (plist-get result :status) 'succeeded)
                                (list :status 'succeeded :value t)
                              result)))))
             (error
              (finish (faye-openai-auth--failure
                       'crypto "Could not prepare signature verification"
                       error-data)))))))))
  nil)

(provide 'faye-openai-auth)
;;; faye-openai-auth.el ends here
