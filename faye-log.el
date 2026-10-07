;;; faye-log.el --- Simple tagged logging  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Append timestamped level/tag/message entries to a non-file buffer.
;; Call `faye-log-show' to inspect it.  Logging never displays the buffer.

;;; Code:

(defconst faye-log--buffer-name "*Faye Log*")

(defun faye-log--get-buffer ()
  "Get or create the read-only log buffer."
  (let ((buffer (get-buffer-create faye-log--buffer-name)))
    (with-current-buffer buffer
      ;; Read-only inspection mode; initialize once to avoid resetting state.
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buffer))

(defun faye-log--write (level tag message)
  "Append MESSAGE with LEVEL and TAG, preserving point and narrowing."
  (with-current-buffer (faye-log--get-buffer)
    (let ((inhibit-read-only t))
      (save-excursion
        (save-restriction
          ;; Narrowing changes point-max; append at the actual buffer end.
          (widen)
          (goto-char (point-max))
          (insert (format "%s %-5s [%s] %s\n"
                          (format-time-string "%H:%M:%S.%3N")
                          level tag message)))))))

(defun faye-log-debug (tag message)
  "Log a debug MESSAGE with TAG."
  (faye-log--write "DEBUG" tag message))

(defun faye-log-info (tag message)
  "Log an informational MESSAGE with TAG."
  (faye-log--write "INFO" tag message))

(defun faye-log-warn (tag message)
  "Log a warning MESSAGE with TAG."
  (faye-log--write "WARN" tag message))

(defun faye-log-error (tag message)
  "Log an error MESSAGE with TAG."
  (faye-log--write "ERROR" tag message))

;;;###autoload
(defun faye-log-show ()
  "Display the log buffer."
  (interactive)
  (display-buffer (faye-log--get-buffer)))

(provide 'faye-log)

;;; faye-log.el ends here
