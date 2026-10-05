;;; faye-output.el --- Output actions: view, append, replace, echo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Where and how responses are presented or applied.  Output targets
;; are captured with markers at invocation time: moving point while
;; waiting never redirects a response.  The session records every
;; completed response regardless of placement; placement and history selection
;; are independent (docs/spec.md, "Applying output to buffers").
;;
;; Action notes:
;; - view: render into the session's Org view.
;; - append: stream into a tracked, writable output range.
;; - replace: preserve input until completion, then one undoable edit;
;;   stale or edited targets are never overwritten.
;; - echo: short responses in the echo area.
;; - minibuffer replacement tracks the particular minibuffer invocation
;;   and never auto-executes the generated command.
;;
;; Roadmap placement: M9.

;;; Code:

(provide 'faye-output)

;;; faye-output.el ends here
