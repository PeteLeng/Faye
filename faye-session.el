;;; faye-session.el --- Sessions, OpenAI records, and context-only forks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Sessions own completed conversation records.  Buffers supply input and
;; receive output; their text is never reparsed as conversation history.
;;
;; Records keep OpenAI Responses items and request/response fields with a
;; small local wrapper.  User records are the only selectable fork points.
;; Forks copy preceding records and retain the source reference needed to
;; initialize a future view's draft.  Drafts and pending requests belong to
;; the later UI and request-lifecycle milestones, not completed history.
;;
;; This is the local core.  SQLite persistence arrives at M5; see
;; docs/spec.md and docs/roadmap.md.

;;; Code:

(require 'cl-lib)

(defgroup faye-session nil
  "Conversation records, attachment, and forks for Faye."
  :group 'faye)

(defcustom faye-model nil
  "Default model for a session without recorded request options.
Choose a model available to your ChatGPT subscription before sending."
  :type '(choice (const :tag "Choose before sending" nil) string)
  :group 'faye-session)

(defcustom faye-instructions nil
  "Default OpenAI instructions for a new session."
  :type '(choice (const :tag "No instructions" nil) string)
  :group 'faye-session)

(defcustom faye-session-database
  (expand-file-name "faye/faye.sqlite" user-emacs-directory)
  "Database path reserved for the SQLite persistence milestone."
  :type 'file
  :group 'faye-session)

;;;; Identity and snapshots

(defvar faye--id-counter 0)

(defun faye--generate-id ()
  "Return a fresh local session or record identifier."
  (substring
   (secure-hash 'sha256
                (format "%s:%S:%s:%s" (emacs-pid) (current-time)
                        (cl-incf faye--id-counter) (random)))
   0 32))

(defun faye--get-time ()
  "Return Unix time in integer seconds."
  (time-convert nil 'integer))

(defun faye--copy-data (value)
  "Copy JSON-shaped Lisp VALUE, including mutable strings and vectors.
Objects are plists; arrays are vectors.  Scalars are retained as-is."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (faye--copy-data (car value)) (faye--copy-data (cdr value))))
   ((vectorp value) (vconcat (mapcar #'faye--copy-data value)))
   (t value)))

;;;; Records and sessions

(cl-defstruct (faye-record (:constructor faye-record-create))
  "A completed user message or assistant response.
ITEMS is a vector of OpenAI items, not rendered prose.  User records
keep AUTHORED text and REQUEST fields except input.  Assistant records
keep RESPONSE fields except output.  The wrapper itself is local."
  (id (faye--generate-id) :type string)
  (role nil :type symbol)
  (authored nil :type (or null string))
  (items [] :type vector)
  (request nil :type list)
  (response nil :type list))

(cl-defstruct (faye-session (:constructor faye-session-create))
  "Identity, associations, and ordered completed records.
FILES are association metadata, not identity.  PARENT-ID and
FORK-USER-RECORD-ID refer to the original fork source.  Model options,
drafts, and pending requests are not session history fields."
  (id (faye--generate-id) :type string)
  (title nil :type (or null string))
  (created-at (faye--get-time) :type integer)
  (updated-at (faye--get-time) :type integer)
  (files nil :type list)
  (records nil :type list)
  (parent-id nil :type (or null string))
  (fork-user-record-id nil :type (or null string)))

(defun faye-record-create-user (authored items request)
  "Capture a user record from AUTHORED text, ITEMS, and REQUEST.
ITEMS is a vector of input items for this new prompt.  REQUEST is a
plist of actual request fields except input, which is reconstructed
from history at send time.  Capture independent snapshots of all data."
  (cl-check-type authored string)
  (cl-check-type items vector)
  (cl-check-type request list)
  (when (plist-member request :input)
    (error "Record request options must not contain history input"))
  (faye-record-create :role 'user
                      :authored (faye--copy-data authored)
                      :items (faye--copy-data items)
                      :request (faye--copy-data request)))

(defun faye-record-create-assistant (response)
  "Capture an assistant record from a completed OpenAI RESPONSE plist.
Keep its entire output vector, including non-prose items, and retain
the other response fields separately.  Do not modify RESPONSE."
  (unless (equal (plist-get response :status) "completed")
    (error "Only completed responses can become history records"))
  (cl-check-type (plist-get response :output) vector)
  (let* ((metadata (faye--copy-data response))
         (items (plist-get metadata :output)))
    (cl-remf metadata :output)
    (faye-record-create :role 'assistant :items items :response metadata)))

;;;; Live registry and buffer attachment

(defvar faye--sessions (make-hash-table :test #'equal)
  "Live sessions keyed by local ID.")

(defvar-local faye--current-session nil
  "Session attached to this buffer for future sends.")

(defun faye-session-register (session)
  "Register SESSION in the live registry and return it."
  (setf (gethash (faye-session-id session) faye--sessions) session))

(defun faye-session-get (id)
  "Return the live session with ID, or nil."
  (gethash id faye--sessions))

(defun faye-session-forget (id)
  "Remove ID from the live registry."
  (remhash id faye--sessions))

(defun faye-session-list (&optional file)
  "List live sessions, most recently updated first.
When FILE is supplied, list sessions associated with its truename."
  (let ((file (and file (file-truename file))) sessions)
    (maphash (lambda (_id session)
               (when (or (null file) (member file (faye-session-files session)))
                 (push session sessions)))
             faye--sessions)
    (sort sessions (lambda (a b)
                     (> (faye-session-updated-at a)
                        (faye-session-updated-at b))))))

(defun faye-session-associate-file (session file)
  "Associate SESSION with FILE's truename and return SESSION."
  (let ((file (file-truename file)))
    (unless (member file (faye-session-files session))
      (push file (faye-session-files session))
      (setf (faye-session-updated-at session) (faye--get-time))))
  session)

(defun faye-session-attach (session &optional buffer)
  "Register and attach SESSION to BUFFER, then return SESSION.
BUFFER defaults to the current buffer.  Associate its visited file,
if any, with SESSION.  Other buffers' attachments are independent."
  (with-current-buffer (or buffer (current-buffer))
    (when buffer-file-name
      (faye-session-associate-file session buffer-file-name))
    (setq faye--current-session (faye-session-register session))))

(defun faye-session-get-current (&optional buffer)
  "Return the session attached to BUFFER, or nil.
BUFFER defaults to the current buffer."
  (buffer-local-value 'faye--current-session (or buffer (current-buffer))))

(defun faye-session-detach (&optional buffer)
  "Detach BUFFER's session without removing file associations."
  (with-current-buffer (or buffer (current-buffer))
    (setq faye--current-session nil)))

(defun faye-session-ensure (&optional buffer)
  "Get BUFFER's attached session, or create and attach a fresh one."
  (or (faye-session-get-current buffer)
      (faye-session-attach (faye-session-create) buffer)))

;;;; Completed history

(defun faye-session-get-record (session id)
  "Find the record with local ID in SESSION, or return nil."
  (cl-find id (faye-session-records session) :key #'faye-record-id :test #'equal))

(defun faye-session-append-records (session user assistant)
  "Append the completed USER and ASSISTANT records to SESSION together.
Validate the pair before changing history.  SQLite transaction handling
and pending request state arrive in the request-lifecycle milestone."
  (unless (and (eq (faye-record-role user) 'user)
               (eq (faye-record-role assistant) 'assistant)
               (equal (plist-get (faye-record-response assistant) :status)
                      "completed"))
    (error "History requires a user record and completed assistant record"))
  (when (or (equal (faye-record-id user) (faye-record-id assistant))
            (faye-session-get-record session (faye-record-id user))
            (faye-session-get-record session (faye-record-id assistant)))
    (error "Record IDs must be unique within a session"))
  (setf (faye-session-records session)
        (append (faye-session-records session) (list user assistant))
        (faye-session-updated-at session) (faye--get-time))
  session)

;;;; Context-only forks and next-request defaults

(defun faye--copy-record (record)
  "Copy RECORD with a fresh local ID and independent captured data."
  (faye-record-create
   :role (faye-record-role record)
   :authored (faye--copy-data (faye-record-authored record))
   :items (faye--copy-data (faye-record-items record))
   :request (faye--copy-data (faye-record-request record))
   :response (faye--copy-data (faye-record-response record))))

(defun faye-session-fork (session user-record-id)
  "Create a registered fork before SESSION's USER-RECORD-ID.
Only a user record can be selected.  Copy preceding records with fresh
local IDs; do not change SESSION, buffers, files, or provider item IDs.
Register the source so `faye-session-get-fork-source' can retrieve the
authored prompt and options for a future draft UI."
  (let* ((records (faye-session-records session))
         (position (cl-position user-record-id records
                                :key #'faye-record-id :test #'equal)))
    (unless position (error "No record with ID %s" user-record-id))
    (unless (eq (faye-record-role (nth position records)) 'user)
      (error "Fork point must be a user record"))
    (faye-session-register session)
    (faye-session-register
     (faye-session-create
      :title (faye--copy-data (faye-session-title session))
      :files (faye--copy-data (faye-session-files session))
      :records (mapcar #'faye--copy-record (cl-subseq records 0 position))
      :parent-id (faye--copy-data (faye-session-id session))
      :fork-user-record-id (faye--copy-data user-record-id)))))

(defun faye-session-get-fork-source (session)
  "Get SESSION's selected source user record, or nil for a non-fork.
Signal an error if its source is no longer live.  Persistence will
restore this provenance through SQLite at M5.  The source's authored
text seeds the draft; it is not a completed record in the fork."
  (when-let ((id (faye-session-fork-user-record-id session)))
    (let* ((parent (faye-session-get (faye-session-parent-id session)))
           (record (and parent (faye-session-get-record parent id))))
      (unless record (error "Fork source %s is not live" id))
      record)))

(defun faye-session-get-request-options (session &optional overrides)
  "Get independent next-request options for SESSION, applying OVERRIDES.
Use the latest user record, or package defaults for a new session.
Before a fork's first new submission, use its selected source record.
OVERRIDES is a plist; merging it does not alter historical options."
  (let* ((records (faye-session-records session))
         (source (faye-session-get-fork-source session))
         (parent (and source (faye-session-get (faye-session-parent-id session))))
         (prefix-length (and source (cl-position source (faye-session-records parent))))
         (user (if (and source (= (length records) prefix-length))
                   source
                 (cl-find 'user records :key #'faye-record-role :from-end t)))
         (options (if user
                      (faye--copy-data (faye-record-request user))
                    (append (and faye-model (list :model (faye--copy-data faye-model)))
                            (and faye-instructions
                                 (list :instructions (faye--copy-data faye-instructions)))
                            (list :store :false :stream t)))))
    (while overrides
      (let ((key (pop overrides)) (value (pop overrides)))
        (setq options (plist-put options key (faye--copy-data value)))))
    options))

(provide 'faye-session)

;;; faye-session.el ends here
