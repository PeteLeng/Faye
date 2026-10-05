;;; faye.el --- An LLM client for Emacs with independent sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Faye is an Emacs-native LLM client targeting ChatGPT subscription
;; access through the Codex Responses endpoint.  Sessions own records;
;; working buffers are input/output surfaces, never the history store.
;;
;; This scaffold implements the local data model, registry, attachment,
;; request-option defaults, and user-record forks.  Sending, persistence,
;; and presentation arrive in the milestones documented below.
;;
;; The design record is docs/spec.md; the implementation plan is
;; docs/roadmap.md.  Module map:
;;
;; faye.el         -- entry point; later commands and request orchestration.
;; faye-session.el -- records, registry, attachment, forks; SQLite at M5.
;; faye-openai.el  -- OAuth, Codex request construction, Curl/SSE transport.
;; faye-view.el    -- Org session views and the draft area.
;; faye-context.el -- @include and prompt macro expansion.
;; faye-output.el  -- view/append/replace/echo output actions.

;;; Code:

(defgroup faye nil
  "An LLM client for Emacs with independent, persistent sessions."
  :group 'convenience)

(require 'faye-session)

(provide 'faye)

;;; faye.el ends here
