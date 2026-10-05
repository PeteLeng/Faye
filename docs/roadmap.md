# Faye: incremental roadmap

The spec ([spec.md](spec.md)) implemented as a sequence of small,
independently reviewable commits. Every milestone keeps `make test` and
`make compile` green. Size guide: one milestone = a few focused commits.

## M0 — Scaffold (done)

Spec: "Core model and surfaces", "Record representation", "Context-only
forks", "Naming convention".

- Repository layout, Emacs 29.1+ package metadata, README, Makefile, and
  `.gitignore`; `require 'faye` loads the local core.
- `faye-session` and `faye-record` structs. Keep OpenAI items, actual request
  fields except `input` on user records, and completed response fields except
  `output` on assistant records.
- Live registry, independent buffer attachment, many-to-many file
  associations, and completed user/assistant pair appends.
- Next-send options use the last user record or package defaults and permit
  overrides. Fork defaults come from the selected source user record.
- User-record forks copy only preceding records with fresh local IDs and
  independent snapshots. `faye-session-get-fork-source` exposes the authored
  prompt and options for the draft UI to be implemented in M7/M11.
- Verb-based operation suffixes, including `faye-session-get-current`, with
  noun-based field accessors.
- Focused ERT tests for capture, attachment, history, defaults, and forks;
  byte compilation treats warnings and errors as failures.
- Provider, view, context, and output modules remain milestone skeletons.
  Native SQLite availability is checked when persistence is implemented in
  M5; OpenAI data remains JSON-shaped inside records.

## M1 — Request assembly (pure functions, next)

Spec: "HTTP shape", "Record representation".

- `faye-openai`: build a Responses request (model, instructions, `input`
  array) from a session's completed history plus one staged user message.
- Use the current model and instructions. Retain historical request options
  for inspection without replaying them; follow the subscription endpoint's
  supported fields, not a generic provider schema.
- Preserve continuation-relevant output items and apply Codex-specific
  output-to-input conversion where needed.
- No network. Tests with canned sessions assert exact payload plists,
  including stable history across model/instruction changes and consecutive
  requests.

## M2 — SSE event parser (pure functions)

Spec: "Curl and SSE".

- Incremental parser fed arbitrary byte chunks; must tolerate splits at
  UTF-8, SSE-record, and JSON boundaries.
- Emits: output-text deltas, completion, failure/error, usage.
- Tests feed fragmented chunks and assert event order and payload decoding.

## M3 — OAuth login and tokens

Spec: "ChatGPT subscription backend".

- Token persistence and silent refresh with expiry margin (separate from
  session storage).
- PKCE authorization-code login with localhost callback; device-grant
  fallback.
- Interactive verification path documented in the commit message.

## M4 — Curl transport

Spec: "Curl and SSE", "Pipeline".

- Asynchronous streaming POST via `make-process` with config/body on stdin.
- Wire the M2 parser to the process filter from the start; abort via
  process deletion.
- Error surfaces (HTTP status, payload error events).

## M5 — Request lifecycle and SQLite persistence

Spec: "Pipeline" (staging/commit), "Durable storage".

- Runtime request staging: failure/cancel leaves completed history untouched.
- Native SQLite database using the spec's `sessions`, `records`, and
  `file_associations` tables; check `sqlite-available-p`, enable foreign keys
  on each connection, and version the schema with `user_version`.
- Commit the user/assistant records and session metadata in one transaction.
  Keep provider data as JSON within records, not whole-session JSON files.
- Load-on-demand and association queries; `faye-session-select` picker.
  Associations are many-to-many: several sessions per file and several files
  per session.
- Tests: staging semantics, transaction atomicity, save/load preservation of
  provider items and request/response fields, user-record fork persistence,
  discovery after simulated restart, and association queries in both
  directions.

## M6 — Entry command (fake transport)

Spec: "User interactions".

- `faye-send` DWIM matrix: region, view draft area, minibuffer contents,
  fallback minibuffer read; attach-or-create session; captured output
  markers.
- Tests drive the matrix against a stub transport; the real transport
  connects in M8.

## M7 — Session view

Spec: "Session view and draft area".

- Pure `session -> org text` rendering (unit-tested) before any UI.
- Minor mode: read-only history, explicit draft-area markers, send from
  draft, regeneration on updates without disturbing unrelated draft text.

## M8 — Wire the real pipeline end to end

- Connect M1 + M4 + M5 + M6: a real streamed request from a region selection
  to a view update, then a draft-area follow-up.
- Live verification checklist in the commit message (first real login).

## M9 — Output actions

Spec: "Applying output to buffers".

- Append at captured markers; echo-area action.
- Replace: preserve input until completion, single undoable edit,
  stale-target guard.
- Minibuffer replacement with per-invocation tracking and early-exit guard.

## M10 — @include macro

Spec: "Prompt macros".

- Macro registry (data-driven), `@include` resolution to labeled text,
  completion at point, unresolved-name errors before sending.
- Tests: expansion output, authored vs. resolved text, history re-use of
  captured content.

## M11 — Options menu, inspect, fork commands

Spec: "User interactions", "Context-only forks".

- `C-u faye-send` menu: placement, session, model, instructions, dry-run.
- `faye-request-inspect` (the debugging surface for all later work).
- `faye-session-fork` command: select a user record, copy the preceding
  history, seed its authored prompt as the new draft, and optionally attach.
  Verify draft revision/resubmission and normal macro expansion in the fork.

## M12 — Acceptance pass

- Walk every "MVP acceptance path" in the spec against the real provider;
  fix what falls out; update spec status to v1.0.

## Post-MVP (deferred)

Per spec §13: model tool calls, MCP, multi-provider, history editing,
diff/merge previews, Flymake annotation, media, compaction.
