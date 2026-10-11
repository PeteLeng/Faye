;;; faye-openai-auth.el --- OpenAI registration and sign-in API  -*- lexical-binding: t; -*-

;;; Commentary:

;; API surface for the documented ChatGPT-plan registration and sign-in flow.
;; Request construction/execution, credential I/O and cryptographic helpers
;; are implemented.  Sign-in orchestration and its callback listener are stubs.
;; Composition and policy belong in sign-in, including host-ID reuse/creation,
;; generation of each authorization value, and decisions to fetch signing keys.
;;
;; Credential record: JSON object, represented in Lisp as a keyword plist.
;; Fields match the documented local-file schema:
;;   email, issuer, subject, client_id, ext_agent_host_id, id_token,
;;   access_token, refresh_token, token_type, expires_in, scopes, saved_at.
;; scopes is a vector of granted scope strings.  saved_at is a UTC timestamp
;; captured when the token response arrives, before validation or file writing.
;; The first-run record format before credentials exist is still an open decision.
;; There is one provider-specific credentials file, not a separate host-ID file.
;;
;; ext_agent_host_id identifies an app-defined host, such as an installation
;; or VM.  It is stable across restarts and sign-ins, distinct for each host,
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
Registration versus reauthorization choices belong in sign-in.")

(defvar faye-openai-auth-credentials-file
  (expand-file-name "faye/openai/credentials.json" user-emacs-directory)
  "Default path for the OpenAI credential record.")

(defun faye-openai-auth--failure (kind message &optional data)
  "Construct a failed result with KIND, MESSAGE and inspection DATA."
  (list :status 'failed :error (list :kind kind :message message :data data)))

;; Credential storage.

(defun faye-openai-auth-load-credentials (&optional file)
  "Read the credential record from FILE as a JSON-compatible plist.
FILE defaults to `faye-openai-auth-credentials-file'.  Return nil if absent;
signal an error for unreadable or malformed data.  Loading a record does not
establish that its access token is still usable."
  (let ((file-path (or file faye-openai-auth-credentials-file)))
    (when (file-exists-p file-path)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents file-path))
        (goto-char (point-min))
        (skip-chars-forward " \t\r\n")
        (unless (eq (char-after) ?{)
          (error "Credential record must be a JSON object"))
        (let ((credentials (json-parse-buffer
                            :object-type 'plist :array-type 'array
                            :null-object nil :false-object :false)))
          (skip-chars-forward " \t\r\n")
          (unless (eobp)
            (error "Unexpected content after credential record"))
          credentials)))))

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
its success value.  Release the listener on completion or failure.
The initial host-ID persistence format remains to be decided."
  (ignore on-result credentials-file)
  (error "faye-openai-auth-sign-in is not implemented yet"))

(defun faye-openai-auth--start-callback-listener (on-callback)
  "Start a loopback listener on 127.0.0.1 and return its process object.
Choose an available port, obtainable with `process-contact'.  Accept the
documented /auth/callback path.  ON-CALLBACK receives decoded query parameters
as an alist of string pairs; preserve duplicate entries for caller validation.
Sign-in owns callback state/client-ID checks and listener lifetime."
  (ignore on-callback)
  (error "faye-openai-auth--start-callback-listener is not implemented yet"))

(defun faye-openai-auth--stop-callback-listener (listener-process)
  "Close LISTENER-PROCESS and its accepted connections, idempotently."
  (ignore listener-process)
  (error "faye-openai-auth--stop-callback-listener is not implemented yet"))

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
              (condition-case start-error
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
                           start-error)))))))))
    ;; OAuth retry classification is a separate policy; use one attempt for now.
    (faye-req-start request nil
                    (lambda (_request result)
                      (ignore-errors (funcall on-result result))))))

;; Atomic cryptographic operations.
;; Sign-in composes these; caching decisions and claim checks stay in sign-in.

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
           (condition-case start-error
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
             (error (finish nil start-error)))))
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
     (if (and (eq (plist-get result :status) 'succeeded)
              (/= (length (plist-get result :value)) byte-count))
         (funcall on-result
                  (faye-openai-auth--failure 'crypto "Unexpected random byte count"))
       (funcall on-result result)))))

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
           (condition-case preparation-error
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
                       preparation-error)))))))))
  nil)

(provide 'faye-openai-auth)
;;; faye-openai-auth.el ends here
