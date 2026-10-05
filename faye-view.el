;;; faye-view.el --- Org session views with a draft area  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Session views: Org buffers rendered FROM session objects.  History is
;; read-only; a designated draft area (bounded by explicit runtime
;; markers, never inferred from text properties) is the view's only
;; writable input surface.  Views are regenerable from the session and
;; are never reparsed to recover user/assistant roles.
;;
;; See docs/spec.md, "Session view and draft area".  Roadmap
;; placement: M7.  A fork view initializes its draft from the authored
;; text returned by `faye-session-get-fork-source'; it does not add the
;; selected old user record to completed history.

;;; Code:

(provide 'faye-view)

;;; faye-view.el ends here
