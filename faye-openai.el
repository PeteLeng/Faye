;;; faye-openai.el --- OAuth, Codex requests, and Curl/SSE transport  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faye contributors
;; This file is not part of GNU Emacs.

;;; Commentary:

;; Provider layer for the single supported backend: a ChatGPT
;; subscription account reached through OpenAI OAuth and the Codex
;; Responses endpoint (https://chatgpt.com/backend-api/codex/responses).
;;
;; Responsibilities, per docs/spec.md ("Provider and request lifecycle"):
;; - OAuth login and token refresh, stored separately from sessions.
;; - Building Responses API payloads from completed record items and
;;   current request options.  Faye's local record wrapper is not sent.
;; - The asynchronous Curl subprocess (config and body supplied on
;;   stdin) and SSE event decoding, including chunk boundaries that
;;   split UTF-8, SSE records, or JSON.
;;
;; Roadmap placement: M1 (request assembly), M2 (SSE parser), M3
;; (OAuth), M4 (transport).  Schema references:
;; https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/common.rs
;; https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs

;;; Code:

(provide 'faye-openai)

;;; faye-openai.el ends here
