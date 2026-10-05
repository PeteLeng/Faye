;;; faye-session-test.el --- Local-core contracts for Faye  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Exercise snapshots of OpenAI data, independent buffer attachments,
;; completed-history updates, request defaults, and user-record forks.
;; Tests isolate the registry and use no network or persistent storage.

;;; Code:

(require 'ert)
(require 'json)
(require 'faye)

(defmacro faye-test--with-registry (&rest body)
  "Evaluate BODY with an isolated live registry."
  (declare (indent 0) (debug t))
  `(let ((faye--sessions (make-hash-table :test #'equal)))
     ,@body))

(defun faye-test--user (text &optional model instructions)
  "Make a user fixture with TEXT, MODEL, and INSTRUCTIONS."
  (faye-record-create-user
   text
   (vector (list :type "message" :role "user"
                 :content (vector (list :type "input_text" :text text))))
   (list :model (or model "model-a")
         :instructions (or instructions "Be brief.")
         :store :false :stream t)))

(defun faye-test--assistant (&optional text)
  "Make a completed OpenAI response fixture containing TEXT."
  (faye-record-create-assistant
   (list :id "resp_fixture" :object "response" :status "completed"
         :model "model-a"
         :output
         (vector (list :id "msg_fixture" :type "message"
                       :role "assistant" :status "completed"
                       :content (vector (list :type "output_text"
                                              :text (or text "Answer")
                                              :annotations []))))
         :usage (list :input_tokens 12 :output_tokens 4 :total_tokens 16))))

(ert-deftest faye-entry-loads-local-core ()
  (should (featurep 'faye-session))
  (should (faye-session-p (faye-session-create))))

(ert-deftest faye-session-registry-and-buffer-lifecycle ()
  (faye-test--with-registry
    (with-temp-buffer
      (should-not (faye-session-get-current))
      (let ((session (faye-session-ensure)))
        (should (eq session (faye-session-get (faye-session-id session))))
        (should (eq session (faye-session-ensure)))
        (faye-session-detach)
        (should-not (faye-session-get-current))
        (should-not (eq session (faye-session-ensure)))
        (faye-session-forget (faye-session-id session))
        (should-not (faye-session-get (faye-session-id session)))))))

(ert-deftest faye-session-explicit-buffer-attachment ()
  (faye-test--with-registry
    (with-temp-buffer
      (let ((origin (current-buffer)))
        (setq buffer-file-name (expand-file-name "test/origin.org"))
        (with-temp-buffer
          (let* ((target (current-buffer))
                 (file (expand-file-name "test/target.org"))
                 (session (faye-session-create)))
            (setq buffer-file-name file)
            (with-current-buffer origin
              (faye-session-attach session target)
              (should-not (faye-session-get-current)))
            (should (eq session (faye-session-get-current target)))
            (should (equal (faye-session-files session)
                           (list (file-truename file))))
            (faye-session-detach target)
            (should-not (faye-session-get-current target))
            (should (equal (faye-session-files session)
                           (list (file-truename file))))))))))

(ert-deftest faye-session-many-to-many-associations ()
  (faye-test--with-registry
    (let ((one (faye-session-register (faye-session-create)))
          (two (faye-session-register (faye-session-create)))
          (notes (expand-file-name "test/notes.org"))
          (other (expand-file-name "test/other.org")))
      (faye-session-associate-file one notes)
      (faye-session-associate-file one other)
      (faye-session-associate-file one notes)
      (faye-session-associate-file two notes)
      (setf (faye-session-updated-at one) 100
            (faye-session-updated-at two) 200)
      (should (= (length (faye-session-files one)) 2))
      (should (equal (faye-session-list notes) (list two one)))
      (should (equal (faye-session-list other) (list one)))
      (should (equal (faye-session-list) (list two one))))))

(ert-deftest faye-record-user-captures-resolved-input-and-options ()
  (let* ((authored (copy-sequence "Summarize.\n@include notes.org"))
         (items (vector (list :type "message" :role "user"
                              :content (vector (list :type "input_text"
                                                     :text (copy-sequence "Captured notes"))))))
         (options (list :model (copy-sequence "model-a")
                        :instructions "Be brief." :store :false :stream t))
         (record (faye-record-create-user authored items options)))
    (aset authored 0 ?X)
    (aset (plist-get options :model) 0 ?X)
    (aset (plist-get (aref (plist-get (aref items 0) :content) 0) :text) 0 ?X)
    (should (equal (faye-record-authored record) "Summarize.\n@include notes.org"))
    (should (equal (plist-get (faye-record-request record) :model) "model-a"))
    (should (equal (plist-get (aref (plist-get (aref (faye-record-items record) 0)
                                             :content) 0) :text)
                   "Captured notes"))
    (should-not (faye-record-response record))
    (should (string-match-p "\"store\":false"
                            (json-serialize (faye-record-request record))))))

(ert-deftest faye-record-user-does-not-duplicate-history-input ()
  (should-error (faye-record-create-user "Prompt" [] (list :input []))))

(ert-deftest faye-record-assistant-preserves-provider-items-and-envelope ()
  (let* ((response (json-parse-string
                    "{\"id\":\"resp_1\",\"status\":\"completed\",\"model\":\"routed-model\",\"output\":[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"},{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot comply\"}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}"
                    :object-type 'plist :array-type 'array))
         (output-json (json-serialize (plist-get response :output)))
         (record (faye-record-create-assistant response)))
    (should (equal (json-serialize (faye-record-items record)) output-json))
    (should (equal (plist-get (faye-record-response record) :model) "routed-model"))
    (should (equal (plist-get (faye-record-response record) :usage)
                   (plist-get response :usage)))
    (should-not (plist-member (faye-record-response record) :output))
    (should (plist-member response :output))
    (aset (plist-get (aref (plist-get response :output) 0) :encrypted_content) 0 ?X)
    (should (equal (plist-get (aref (faye-record-items record) 0) :encrypted_content)
                   "opaque"))))

(ert-deftest faye-record-assistant-rejects-incomplete-responses ()
  (dolist (status '("in_progress" "failed" "incomplete" "cancelled"))
    (should-error (faye-record-create-assistant (list :status status :output []))))
  (should-error (faye-record-create-assistant (list :status "completed"))))

(ert-deftest faye-session-appends-completed-pairs-only ()
  (let* ((session (faye-session-create))
         (user (faye-test--user "Question"))
         (assistant (faye-test--assistant)))
    (should-error (faye-session-append-records session assistant user))
    (should-not (faye-session-records session))
    (faye-session-append-records session user assistant)
    (should (equal (mapcar #'faye-record-role (faye-session-records session))
                   '(user assistant)))
    (should-error (faye-session-append-records session user assistant))
    (should (= (length (faye-session-records session)) 2))
    (should (eq (faye-session-get-record session (faye-record-id user)) user))))

(ert-deftest faye-session-new-request-options-use-package-defaults ()
  (let* ((faye-model (copy-sequence "default-model"))
         (faye-instructions "Default instructions")
         (session (faye-session-create))
         (options (faye-session-get-request-options session)))
    (should (equal options (list :model "default-model"
                                :instructions "Default instructions"
                                :store :false :stream t)))
    (aset (plist-get options :model) 0 ?X)
    (should (equal faye-model "default-model"))
    (should-not (faye-session-records session))))

(ert-deftest faye-session-option-overrides-do-not-rewrite-history ()
  (let* ((session (faye-session-create))
         (first (faye-test--user "One" "model-a" "Instructions A")))
    (faye-session-append-records session first (faye-test--assistant))
    (let ((options (faye-session-get-request-options
                    session (list :model "model-b" :instructions "Instructions B"))))
      (should (equal (plist-get options :model) "model-b"))
      (should (equal (plist-get options :instructions) "Instructions B"))
      (faye-session-append-records
       session (faye-record-create-user "Two" [] options) (faye-test--assistant))
      (should (equal (plist-get (faye-session-get-request-options session) :model)
                     "model-b")))
    (should (equal (plist-get (faye-record-request first) :model) "model-a"))
    (should (equal (plist-get (faye-record-request first) :instructions)
                   "Instructions A"))))

(ert-deftest faye-session-fork-copies-only-the-preceding-history ()
  (faye-test--with-registry
    (let* ((session (faye-session-create :title "Original"))
           (first (faye-test--user "One" "model-a"))
           (selected (faye-test--user "Two\n@include notes.org" "model-b")))
      (faye-session-append-records session first (faye-test--assistant))
      (faye-session-append-records session selected (faye-test--assistant))
      (faye-session-append-records session (faye-test--user "Three") (faye-test--assistant))
      (with-temp-buffer
        (insert "Working text")
        (faye-session-attach session)
        (let* ((fork (faye-session-fork session (faye-record-id selected)))
               (copied (faye-session-records fork)))
          (should (= (length copied) 2))
          (should (= (length (faye-session-records session)) 6))
          (should-not (equal (faye-session-id fork) (faye-session-id session)))
          (should (eq (faye-session-get (faye-session-id fork)) fork))
          (should (equal (faye-session-parent-id fork) (faye-session-id session)))
          (should (equal (faye-session-fork-user-record-id fork) (faye-record-id selected)))
          (should (eq (faye-session-get-fork-source fork) selected))
          (should (equal (faye-record-authored (faye-session-get-fork-source fork))
                         "Two\n@include notes.org"))
          (should (equal (plist-get (faye-session-get-request-options fork) :model)
                         "model-b"))
          (cl-mapc (lambda (original copy)
                     (should-not (equal (faye-record-id original) (faye-record-id copy)))
                     (should (equal (faye-record-items original) (faye-record-items copy))))
                   (cl-subseq (faye-session-records session) 0 2) copied)
          (should (equal (buffer-string) "Working text"))
          (should (eq (faye-session-get-current) session)))))))

(ert-deftest faye-session-fork-at-first-user-has-no-history ()
  (faye-test--with-registry
    (let* ((session (faye-session-create))
           (selected (faye-test--user "First")))
      (faye-session-append-records session selected (faye-test--assistant))
      (let ((fork (faye-session-fork session (faye-record-id selected))))
        (should-not (faye-session-records fork))
        (should (eq (faye-session-get-fork-source fork) selected))))))

(ert-deftest faye-session-fork-rejects-invalid-points ()
  (faye-test--with-registry
    (let ((session (faye-session-create))
          (assistant (faye-test--assistant)))
      (faye-session-append-records session (faye-test--user "One") assistant)
      (should-error (faye-session-fork session (faye-record-id assistant)))
      (should-error (faye-session-fork session "missing"))
      (should-error (faye-session-fork session nil))
      (should (= (hash-table-count faye--sessions) 0)))))

(ert-deftest faye-session-fork-does-not-share-mutable-data ()
  (faye-test--with-registry
    (let* ((session (faye-session-create :title (copy-sequence "Original")))
           (first (faye-test--user "First"))
           (selected (faye-test--user "Second")))
      (faye-session-associate-file session (expand-file-name "test/notes.org"))
      (faye-session-append-records session first (faye-test--assistant))
      (faye-session-append-records session selected (faye-test--assistant))
      (let* ((fork (faye-session-fork session (faye-record-id selected)))
             (copy (car (faye-session-records fork)))
             (text (plist-get (aref (plist-get (aref (faye-record-items copy) 0)
                                              :content) 0) :text)))
        (aset text 0 ?X)
        (aset (plist-get (faye-record-request copy) :model) 0 ?X)
        (aset (faye-session-title fork) 0 ?X)
        (aset (car (faye-session-files fork)) 0 ?X)
        (should (equal (plist-get (aref (plist-get (aref (faye-record-items first) 0)
                                                 :content) 0) :text) "First"))
        (should (equal (plist-get (faye-record-request first) :model) "model-a"))
        (should (equal (faye-session-title session) "Original"))
        (should (equal (faye-session-files session)
                       (list (file-truename (expand-file-name "test/notes.org")))))))))

(ert-deftest faye-session-fork-follow-up-options-use-new-user ()
  (faye-test--with-registry
    (let* ((session (faye-session-create))
           (selected (faye-test--user "First" "model-a")))
      (faye-session-append-records session selected (faye-test--assistant))
      (let ((fork (faye-session-fork session (faye-record-id selected))))
        (faye-session-append-records
         fork (faye-test--user "Revised" "model-b") (faye-test--assistant))
        (should (equal (plist-get (faye-session-get-request-options fork) :model)
                       "model-b"))
        (should (equal (faye-record-authored selected) "First"))))))

(provide 'faye-session-test)

;;; faye-session-test.el ends here
