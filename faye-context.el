;;; faye-context.el --- Prompt macros: @include and context expansion  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Client-side prompt preparation: macros add or transform context
;; before a request is sent.  They are interpreted by Faye, not by the
;; model, and they are distinct from system-instruction profiles and
;; from model-requested tool calls.  Macros are processed only in the
;; newly submitted prompt (including a fork draft), never in completed
;; records or attachment text.
;;
;; The minimal MVP set is @include (named buffers and text files,
;; resolved into labeled text).  See docs/spec.md, "Prompt macros".
;; Roadmap placement: M10.

;;; Code:

(provide 'faye-context)

;;; faye-context.el ends here
