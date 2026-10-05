# Faye: MVP specification

*Status: draft v0.3 (2026-10-05). This document is the design source of
truth. Sections marked* **provisional** *describe suggested implementation
choices, not settled requirements. It supersedes the earlier org-format
draft kept in the gptel research checkout.*

Faye is an Emacs-native LLM client. It takes inspiration from gptel's
availability throughout Emacs, flexible input and output, and small command
surface, with one central difference: **a session owns its conversation
records. A working buffer is never the history store.**

## 1. Agreed scope

- Package name: **Faye**, Lisp prefix `faye-`.
- Provider: **ChatGPT subscription access** — OpenAI OAuth, the Codex
  Responses endpoint. Ordinary OpenAI API-key billing is not the MVP target.
- Transport: our own asynchronous Curl subprocess.
- Streaming: Server-Sent Events (SSE) from the start.
- Availability: any Emacs buffer — non-file buffers, read-only buffers, and
  the minibuffer included. There is no programming-mode requirement.
- A selected region may be the complete prompt. Sending it must not require
  entering an additional instruction elsewhere.
- Sessions: explicit in-memory objects with separate persistent storage.
- Storage: SQLite through Emacs's native support. The MVP requires Emacs
  29.1 or newer with SQLite available, checked with `sqlite-available-p`.
- Session views: Org buffers displaying session history plus a writable
  **draft area**.
- Output actions: session view, append, and replace; echo-area output is a
  small additional action useful for temporary interactions.
- Prompt macros: a minimal `@include` facility for adding text context.
- History changes: new sessions and **context-only forks at user records**.
  A fork copies the preceding history and places the selected prompt in a
  new draft for revision or resubmission. Existing history is immutable;
  working buffer changes and Git state are not rolled back.
- Model-requested tool execution is deferred. Macros are client-side prompt
  preparation, not model tool calls.

## 2. Principles

### A session is the conversation authority

The messages used for future requests come from the session — not from
parsing the current contents of a working buffer or a rendered history
buffer. Temporary notes, later edits, and inserted responses in a working
buffer do not silently become conversation history.

### Buffers are input and output surfaces

A buffer can supply a prompt, receive a response, display a session, or do
several of these things. These uses do not make its entire contents a
conversation.

### Sending a complete prompt should be direct

The common interaction is: select text, invoke the send command, receive the
response. Options are available on demand rather than required for every
send.

### Use the provider's structure without inventing unnecessary structure

Faye closely follows the ChatGPT subscription endpoint's Responses API
items, request fields, and response fields. It supports this backend alone;
there is no generic provider or request-settings schema.

Faye retains the OpenAI Responses API's message/content item structure.
Ordinary prompt text stays ordinary text. In particular, Faye does not
attempt to split a self-contained selection into separate "instruction" and
"context" sentences.

The application needs a small record for identity, persistence, and
rendering. It does not need a task-description language or a generic
multi-provider schema.

### Response placement and history selection are independent

A response is recorded in the session whether it is shown in a view,
appended to a document, or used as a replacement. Changing placement does
not change the messages already recorded in the session.

## 3. Core model and surfaces

### Sessions contain records

A **session** owns identity, association metadata, and ordered conversation
**records**:

```text
Session
  identity and file associations
  records
    user: authored prompt, resolved input items, request options
    assistant: returned output items, response metadata
    ...
```

A successful request adds a user record and an assistant record together.
Only user records are selectable fork points: a fork creates a new session
with the records before that point and the selected prompt as its draft.
There are no separate turn or round abstractions.

### Requests are runtime operations

A **request** is an asynchronous HTTP model invocation. It carries the
staged prompt, current provider options, streaming response, and status.
Pending, failed, or cancelled requests remain separate from completed
session history.

### Buffers supply input and receive output

A **working buffer** is any buffer in which the user is doing work. Its
attached, or active, session supplies history for future sends. A file can
have several associated sessions; attachment selects one for a buffer.

A **prompt** is explicitly captured text for the next user message. A
session **view** renders records in Org and provides a writable **draft
area** for the next prompt. An attachment adds text through a prompt macro.
An output action determines where and how the response is presented or
applied. None of these surfaces is the session's history store.

## 4. User interactions

### One main send command

Provisional command name: `faye-send`.

Plain invocation uses the captured prompt and the current defaults. A prefix
argument, `C-u faye-send`, opens an options menu before submission.

The options menu must not discard the original region, origin buffer, or
output target when it takes focus. Input and target positions are captured
before opening the menu.

### Input selection

| Situation                       | Prompt source                                    |
|---------------------------------|---------------------------------------------------|
| Active region in any buffer     | The exact selected text.                          |
| Session view, no active region  | The designated draft area, not rendered history.  |
| Minibuffer, no active region    | Its contents, excluding the minibuffer prompt.    |
| Other buffer, no active region  | Read a prompt in the minibuffer.                  |

Active-region sending is self-contained: no extra prompt read is required.

The no-region prompt read is a fallback, not a step added to region
sending. It also does not automatically include the current function,
paragraph, file, or all text before point.

The user can select text from a session view as an explicit new prompt, just
as from another buffer. Doing so does not edit the existing record.

### Session selection

For ordinary buffers:

1. If a session is attached, use it.
2. Otherwise create a session and attach it.
3. The user can explicitly pick another associated session, attach a
   different session, detach, or start a new session.

There is no implicit "pick the newest session from disk" rule. Reopening a
file makes its saved sessions discoverable; choosing one attaches it to the
new buffer instance.

A view is attached to the session it displays. Its draft area continues that
session. The working buffer and its view may therefore share one session.

Temporary minibuffer interactions use transient sessions by default, without
a session-picker step or automatic file association. Invoking Faye while a
minibuffer is already active must not recursively ask for another prompt just
to send its existing contents.

### Output defaults

| Origin                               | Default output                                |
|--------------------------------------|-----------------------------------------------|
| Ordinary buffer, including read-only | Open or update the session's view.            |
| Session view                         | Update that view and keep a usable draft area. |
| Minibuffer                           | Replace the selected span or captured contents.|

An options menu can override placement for the next request:

- **View**: display the response in the session's Org view.
- **Append**: insert after the captured selection or at the captured point,
  with suitable newline separation.
- **Replace**: replace the captured input span with the completed response.
- **Echo**: display a short response in the echo area.

Replace requires a captured editable span, such as a selection or existing
minibuffer contents. A fallback prompt read does not create permission to
replace unselected text in the originating buffer. Unsupported placement
choices should be unavailable in the menu or resolved before making a model
request.

The menu may offer an optional prompt edit or additional text, but neither
is required for a self-contained selection. Its exact keys/layout are
provisional.

### First send and follow-ups

Both use the same session machinery. A fresh session sends only the new
user message; subsequent sends include its prior completed records.

Displaying history is independent of including it in a request. An append or
replace request can continue an existing session without opening its view.

To request a fresh answer without previous conversation history, start a new
session. A dedicated "one-shot mode" is not required in the MVP.

## 5. Session state and persistence

### Live state

Use a `cl-defstruct` or similarly small Lisp record for a session. It
contains:

- Stable ID and a human-readable title.
- Creation/update times.
- File associations, if any.
- Ordered conversation records.
- Parent session ID and selected source user-record ID for a fork, if any.

Model and system instructions are request-scoped, not fixed properties of
the session. Next-send defaults come from the last user record's request
options, or package defaults for a new session, and can be overridden before
submission. A fork initially uses its selected source user record's options.

The active network request, next-send overrides, process, draft contents,
and buffer position markers are runtime state, not persisted conversation
history.

A live registry is keyed by session ID. Buffer-local variables reference live
sessions; SQLite file associations support listing sessions when a file
reopens.

### Record representation

Use a small `faye-record` Lisp record with local identity, role, and OpenAI
data. No separate task schema or instruction/context split is needed.

- **User:** retain the authored prompt, resolved OpenAI input items, and the
  actual request body's fields except `input`. These fields include the
  requested `model`, effective `instructions`, `store`, and `stream`.
- **Assistant:** retain the completed response's `output` items and its
  remaining response fields, including its ID, reported model, and usage
  when supplied.

The following JSON illustrates **Faye's local record wrapper**, not an
official OpenAI request object or a whole-session storage file. The input
items and request/response fields inside it follow the provider's format:

```json
[
  {
    "id": "user-record-id",
    "role": "user",
    "authored": "Summarize these notes.\n@include \"notes.org\"",
    "request": {
      "model": "an-account-supported-model",
      "instructions": "Respond concisely.",
      "store": false,
      "stream": true
    },
    "items": [
      {
        "type": "message",
        "role": "user",
        "content": [
          {
            "type": "input_text",
            "text": "Summarize these notes.\n\nIn file notes.org:\n...captured text..."
          }
        ]
      }
    ]
  },
  {
    "id": "assistant-record-id",
    "role": "assistant",
    "response": {
      "id": "resp_example",
      "object": "response",
      "status": "completed",
      "model": "an-account-supported-model"
    },
    "items": [
      {
        "id": "msg_example",
        "type": "message",
        "role": "assistant",
        "status": "completed",
        "content": [
          {"type": "output_text", "text": "The discussion covered...", "annotations": []}
        ]
      }
    ]
  }
]
```

#### Local fields versus wire fields

| Record field | Origin and meaning |
|--------------|--------------------|
| `id` | Faye's stable local record ID; not an OpenAI message or response ID. |
| Outer `role` | Faye's classification of the record as user or assistant. |
| `authored` | Local original prompt, before macro expansion, for inspection and fork drafts. |
| `request` | Local container for the actual request fields except `input`; its contents become top-level HTTP fields. |
| `request.model` | OpenAI model selected for this request. |
| `request.instructions` | OpenAI's request-level instructions, separate from conversation input. |
| `request.store` | OpenAI response-storage option; Faye uses `false` and retains history locally. |
| `request.stream` | OpenAI streaming option; `true` requests SSE output. |
| `items` | Local container for OpenAI input items or the returned `output` array. |
| User item `type`, `role`, `content` | OpenAI message fields: `message`, `user`, and an array of content parts. |
| Content `type`, `text` | OpenAI content fields: `input_text` and the resolved text actually sent. |
| `response` | Local container for the returned response fields except `output`; server IDs and usage stay here. |

The whole wrapper is never sent. For a new request, collect completed
history's replayable items and the staged user items into `input`, alongside
the current request's top-level options. `authored` is not sent a second
time. See the HTTP example in section 9.

Source cross-check: OpenAI's Codex client defines `ResponsesApiRequest`
(`model`, `instructions`, `input`, `store`, `stream`, and other supported
controls) in
[`codex-api/src/common.rs`](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/common.rs).
Its `ResponseItem::Message` and `ContentItem::InputText` definitions in
[`protocol/src/models.rs`](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs)
serialize message items with `type: "message"` and text parts with
`type: "input_text"`. gptel's `gptel--request-data` Responses method uses
the same top-level fields and a compact message form without explicit
`type`; Faye uses the explicit Codex form.

These are source-verified wire structures, not a separately published
ChatGPT subscription API contract. The public Responses API reference
describes the underlying shape; endpoint-specific parameter acceptance is
verified during transport implementation. Add options only when implemented
and verified; do not invent a generic settings layer. OAuth credentials and
output targets are not part of these stored request fields.

Retain output items needed for valid continuation, including non-prose
items. The Codex adapter converts/removes response-only fields when building
future input; rendering assistant text is not a substitute for keeping the
provider items.

Each request sends completed history plus the new user items using the
current model and instructions. Historical request options are inspection
data, not settings to replay. A session can switch model or instructions
midway, or resume with different choices, without changing earlier records.

The authored prompt is retained for inspection. The resolved API items hold
the actual message content used for future history. Macro expansion is
therefore not repeated for old records. No second copy of the expanded text is
required solely for a `sent` field.

Detailed source-span metadata can be added when a feature needs it. It is not
a prerequisite for sending a plain-text region or using `@include`.

### Durable storage

Use one SQLite database at a customizable path, provisionally defaulting to
`user-emacs-directory/faye/faye.sqlite`.

SQLite replaces whole-session JSON files because it provides:

- Incremental record writes instead of rewriting a growing conversation.
- Transactions that commit the user and assistant records together.
- Indexed session discovery and ordered history retrieval.
- Partial loading without parsing an entire transcript.

JSON remains the representation of OpenAI data within individual records.
SQLite improves storage and retrieval; it does not reduce the context sent
to the model or remove its context-window limit. Compaction remains deferred.

#### Initial schema

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE sessions (
    id                  TEXT PRIMARY KEY NOT NULL,
    title               TEXT,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    parent_id           TEXT REFERENCES sessions(id),
    fork_user_record_id TEXT REFERENCES records(id)
);

CREATE TABLE records (
    id            TEXT PRIMARY KEY NOT NULL,
    session_id    TEXT NOT NULL REFERENCES sessions(id),
    position      INTEGER NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    authored      TEXT,
    items_json    TEXT NOT NULL,
    request_json  TEXT,
    response_json TEXT,
    UNIQUE (session_id, position)
);

CREATE TABLE file_associations (
    file       TEXT NOT NULL,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    PRIMARY KEY (file, session_id)
);

PRAGMA user_version = 1;
```

- `items_json` stores the user input items or assistant `response.output`
  items as a JSON array.
- `authored` and `request_json` are populated for user records;
  `response_json` is populated for assistant records. The latter two store
  the request body except `input` and the completed response except
  `output`, respectively.
- `position` orders records within a session. The unique index on
  `(session_id, position)` also supports ordered history queries.
- `fork_user_record_id` references the selected user record in the parent
  session, not a copied record in the new session.
- File associations are **many-to-many**: a file can have several sessions,
  and a session can cover several files. The join table's composite key
  prevents duplicate associations and supports lookup by file. Association
  metadata does not determine session identity.

Normal file-backed sessions are saved as requests complete. Insert the user
and assistant records and update session metadata in one transaction.
Pending, failed, and cancelled request state stays outside completed-history
tables. Enable foreign keys on each database connection and use
`user_version` for schema versioning.

Non-file buffers can use live sessions without inventing a filename. An
explicit save/associate operation can retain a session that initially had
no durable association. Persist serializable data, not buffer objects,
processes, overlays, or markers. OAuth credentials are stored separately.

### Source associations and position mappings

A working buffer may have several associated sessions and one currently
attached session. Including another buffer through `@include` does not
silently change that buffer's active session.

Markers or overlays may link inserted output/source ranges to a session ID
and record ID for inspection. These links are optional conveniences, not the
means of recovering history.

Changing, deleting, or moving mapped text does not modify a stored record.
Reopening a file uses its session association, not saved character offsets,
to find history.

File renames, remote-file identity, and non-file-buffer associations require
explicit conventions; see the open questions below.

## 6. Context-only forks

A fork starts at a selected **user record**. It creates a new session with
the records strictly before that record and places its authored prompt in
the new session's draft. The user can submit it unchanged or revise it.
Forking changes future request context, not the working environment.

```text
Original session:  user A -> reply A -> user B -> reply B -> user C -> reply C
Fork at user B:    user A -> reply A -> [draft copied from user B]
After submission:  user A -> reply A -> revised user B -> new reply B
```

- The original session is untouched.
- Only user records are selectable fork points. The selected record and all
  later records are absent from the copied history.
- The fork has a new ID and records its parent session ID and selected source
  user-record ID.
- Copy the preceding records with new local IDs, preserving their captured
  OpenAI items and request/response fields. Shared-history storage is not
  needed for the MVP.
- Initialize next-request options from the selected user record, allowing
  overrides before submission.
- The user can attach the fork to the current buffer and continue through
  its draft. The draft enters history as a new user record only when its
  request succeeds.
- Existing buffer edits, inserted output, filesystem state, and Git state are
  left exactly as they are. Forking performs no compensating operations.
- Forking does not replay previous output actions or re-expand macros in
  copied history. Submitting the new draft expands its macros normally,
  capturing current attachment contents.

The selected prompt can be revised on the new branch without editing its
original record.

In-place editing of old records, deletion of history, request undo, and
rollback of external effects are outside the MVP. Ordinary Emacs text undo
still applies to text inserted/replaced by Faye; it does not undo session
history.

## 7. Session view and draft area

The view is Org mode plus a small Faye minor mode. It renders records as
readable headings, for example:

```text
* You
Summarize these notes.

* Faye
The discussion covered...

* Draft
What should we follow up on next?
```

- History is read-only. The draft area is editable.
- Draft area boundaries are explicit runtime markers or an equivalent Emacs
  field; they are not inferred from gaps between response text properties.
- A send captures the draft area as one user prompt. Clearing it must
  preserve any new draft the user has typed after submission.
- Updating streamed/history text must preserve unrelated draft text and
  avoid stealing point or scrolling unconditionally.
- A session view can be rebuilt from the session. It is not reparsed to
  recover user/assistant roles.
- New-session, pick-session, fork, inspect-request, and abort commands are
  available. History-editing commands are deferred.

Saving/exporting the Org view can be offered as a readable transcript. The
SQLite records remain the durable conversation authority; import/edit
synchronization is not part of the MVP.

## 8. Prompt macros

### Meaning

A macro adds or transforms context before a request is sent. It is
interpreted by Faye, not by the model. It is distinct from a
system-instruction profile and from a model-requested tool call.

Macros are processed only in the newly submitted prompt, including a fork's
draft, not in completed records or text read from attachments.

### Minimal set: @include

Include the current text of named buffers or text files. Buffer sources must
include unsaved edits; file-only sources are read when preparing the request.

Provisional syntax: an `@include` line with quoted or unquoted source names.

```text
Compare these passages and identify contradictions.
@include "notes.org" "*scratch*"
```

The macro resolves these sources into labeled text in the new user message.
The authored syntax stays available in the session for inspection;
continuation uses the captured message content rather than re-reading the
attachments.

- Provide completion for file/buffer names in the draft area and prompt
  minibuffer.
- Report unresolved or ambiguous source names before making a model request.
- A small explicit macro registry is sufficient. Generic asynchronous plugin
  protocols and arbitrary Lisp/shell evaluation are deferred.
- Directory recursion, binary/media input, `@visible-text`, `@expand`,
  `@json`, and notification macros are candidates for later iterations.

## 9. Provider and request lifecycle

### ChatGPT subscription backend

Target the endpoint used by gptel's OAuth backend:
`https://chatgpt.com/backend-api/codex/responses`.

Use OAuth access tokens rather than OpenAI API keys, with an account-ID
header where applicable. Implement login and token refresh using the verified
PKCE or device-login behavior; precise endpoint requirements must be checked
during the transport implementation.

The model is configurable and must be available to the user's account. Avoid
hard-coding speculative model availability. The current gptel OAuth adapter
removes temperature and max-output-token settings for this endpoint; Faye
should follow the endpoint's actual supported parameter set.

### Pipeline

```text
Capture prompt and output target
  -> resolve/create attached session
  -> apply next-request options
  -> expand new prompt macros
  -> stage captured user record and request options in runtime state
  -> construct Responses API input from session items
  -> send with Curl
  -> receive SSE events
  -> commit user and assistant records to history
  -> save persistent records and session metadata in one SQLite transaction
  -> present/apply completed output
```

Streaming display may occur while the response is being received; a
destructive replace action waits for successful completion.

Keep pending/failed/cancelled request status separately from completed
history. Partial assistant text may be shown and inspected, but must not
silently be replayed as a completed response on the next request. The precise
retry command is an implementation detail; it must not silently duplicate a
pending prompt.

Request construction uses completed history plus the staged new user
message. Successful completion commits both records. Failure or cancellation
keeps the attempt inspectable without implicitly adding it to future
conversation context.

### HTTP shape

```json
{
  "model": "an-account-supported-model",
  "instructions": "Respond concisely.",
  "input": [
    {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Hello."}]}
  ],
  "store": false,
  "stream": true
}
```

Each request supplies completed session history plus the new user items in
`input`, using the current `model` and `instructions`. Earlier records'
request options are not merged into this request. Use `store: false` and
full-context requests rather than `previous_response_id`. Output placement
and Emacs buffer metadata are local state, not special provider API fields.

### Curl and SSE

- Start Curl with `make-process` so Emacs remains responsive.
- Supply request headers/body through stdin rather than placing credentials
  in command-line arguments.
- Incrementally decode UTF-8 and SSE records; process chunks need not align
  with JSON, SSE events, or Unicode character boundaries.
- Handle output-text deltas, completion, failure/error, and usage events.
- Retain provider response items needed for future requests, even if their
  presentation is simplified in the Org view.
- Abort stops the current network request. It does not roll back buffer
  edits or delete previously completed records.
- Serialize submissions within a session for the MVP. Independent sessions
  may have requests in flight concurrently.

## 10. Applying output to buffers

Capture output targets with markers at invocation. Moving point while
waiting does not redirect the response. Read-only buffers remain usable as
input even when they cannot receive append/replace output.

For append, stream into a tracked output range when the target is writable and
still live. Use normal Emacs undo behavior rather than session rollback.

For replace, preserve the original text while waiting, then apply the
completed replacement as one undoable text edit. If the selected target was
edited or is no longer valid, keep the response in the session and show it in
the view instead of overwriting the user's new work. Rich diff/merge
previews are a later feature.

For minibuffer replacement, track the particular minibuffer invocation, not
just its buffer object: Emacs reuses minibuffers. If the user exits that
invocation before completion, do not insert into a subsequent prompt; retain
the answer and make it available in a view. Never automatically press RET or
execute a generated shell/Emacs command.

## 11. Provisional code organization

| File            | Responsibility                                             |
|-----------------|------------------------------------------------------------|
| faye.el         | Entry commands, options menu, request orchestration.        |
| faye-session.el | Live records, persistence, associations, selection, forks.  |
| faye-openai.el  | OAuth, Codex request construction, Curl/SSE transport.       |
| faye-view.el    | Org rendering, draft area, status, request inspection.     |
| faye-context.el | @include resolution and text expansion.                    |
| faye-output.el  | View/append/replace/echo adapters and target tracking.      |

These are responsibility boundaries, not a requirement to create every file
immediately. Start with the smallest split that keeps the implementation
clear.

### Naming convention

Use `faye-<subsystem>-<operation>` with an explicit verb in the operation
suffix. Field accessors keep noun suffixes:

```elisp
(faye-session-attach session &optional buffer)
(faye-session-get-current &optional buffer)
(faye-session-detach &optional buffer)
(faye-session-get id)
(faye-session-fork session user-record-id)

(faye-session-id session)
(faye-session-records session)
(faye-record-role record)
(faye-record-items record)
```

`get-current` retrieves the session attached to a buffer; avoid the ambiguous
operation name `active`. Small structs and ordinary functions are sufficient;
classes or dynamic dispatch are not required by this naming convention.

Candidate interactive API:

- `faye-send`: direct send; prefix opens options.
- `faye-session-start`: create and attach a fresh session.
- `faye-session-select`: list associated sessions and attach one.
- `faye-session-detach`: clear the buffer-local attachment.
- `faye-session-view`: display or refresh a session view.
- `faye-session-fork`: copy history before a selected user record, seed the
  new draft, and optionally attach the fork.
- `faye-request-inspect`: show the resolved request without sending it.
- `faye-request-abort`: cancel a live request.

Default keybindings and function signatures are still open for iteration.

## 12. MVP acceptance paths

### Direct, self-contained region

In an arbitrary buffer, select a complete question (possibly including
material to discuss), invoke `faye-send`, and receive a reply in the session
view without an extra prompt read. Unselected text must not appear in the
request.

### Follow-up from either surface

Continue through the view's draft area or send another selected prompt from
an attached working buffer. Both use the same stored history; selecting a
different session changes future request history without changing buffer
contents.

### Persistence and discovery

Complete a session associated with a file, restart Emacs, reopen that file,
list its sessions, attach one, and continue. Earlier resolved messages must
remain the same regardless of edits to the working file or its displayed
responses.

### Model and instructions can change

Complete a request with model A and instructions X, then send a follow-up
using model B and instructions Y. Inspect the new request: it must contain
the same earlier items plus the new prompt, with B and Y as its top-level
options. Verify that the earlier user record still retains A and X. Save,
reload, and resume with different options without modifying prior records.

### Context-only fork

Select an earlier user record, fork, and verify that its authored prompt is
in the new draft while only preceding records are in the new history.
Revise and submit the draft. Inspect the request to verify that the original
selected record and its answer, and all later records, are absent. Verify
that the source session and existing working buffer/filesystem changes
remain untouched, and that assistant records are not selectable fork points.

### Include macro

Send a prompt containing `@include` with a text file and an unsaved buffer.
Inspect the resolved request and verify the labeled contents. Edit the
included sources and send a follow-up: earlier history must still use the
previously captured text.

### Append and replace

Use the options menu to choose append or replace. Verify that the captured
target is used even if point moves. Replace must preserve its input until
completion and produce one normal undoable text edit. Edited/stale targets
must not be overwritten.

### Minibuffer interaction

In an existing command-reading minibuffer, type a description and invoke
Faye. The description itself is the prompt. Replace it with the completed
response and let the user accept it normally. Also verify that exiting early
does not modify the next minibuffer invocation.

### Streaming, errors, and cancellation

Verify progressive output, split SSE-event handling, continued Emacs
interaction, abort, and provider failures. These must not corrupt completed
history or destroy draft/input text. Verify independent sessions can run
concurrently.

## 13. Deferred work

- Model-requested tool registry/execution and tool-result continuation loops.
- MCP and generic multi-provider compatibility.
- In-place history editing, record deletion, conversation undo, or
  Git/filesystem rollback. Forking is already in scope and requires none of
  these.
- Rich replacement previews, diff/ediff/merge workflows.
- Annotation/Flymake output and its source-location contract.
- Media attachments, shell/Lisp expansion, broad macro/preset systems.
- Automatic context compaction, agent orchestration, branch-tree interfaces.

## 14. Open questions for the next iteration

1. Final options-menu ergonomics and keybindings: a Transient menu is a
   candidate, but a dependency or a particular layout is not yet agreed.
2. Exact `@include` syntax and source-name disambiguation.
3. Durable association conventions for renamed files, remote buffers, and
   sessions begun from non-file buffers.
4. How to present failed/pending requests and retry them without duplicate
   records.
5. Which minimal model/request settings should be visible in the MVP menu.

## 15. Research references

gptel source inspected during design (upstream repository):

- [`gptel-send`](https://github.com/karthink/gptel/blob/master/gptel.el):
  direct sending and prefix menu.
- [`gptel-mode`](https://github.com/karthink/gptel/blob/master/gptel.el):
  Org/Markdown/text chat UI and buffer-as-store persistence.
- [`gptel context collection`](https://github.com/karthink/gptel/blob/master/gptel-context.el):
  regions, Dired, Ibuffer, and overlay tracking.
- [`gptel-openai-oauth`](https://github.com/karthink/gptel/blob/master/gptel-openai-oauth.el):
  subscription endpoint, login, token refresh, and headers.
- [`gptel-openai-responses`](https://github.com/karthink/gptel/blob/master/gptel-openai-responses.el):
  instructions, input items, and stateless requests.
- [`gptel curl transport`](https://github.com/karthink/gptel/blob/master/gptel-request.el):
  asynchronous process and streaming handling.

Demo recordings: [general usage](https://www.youtube.com/watch?v=bsRnh_brggM)
(minibuffer replacement, arbitrary-buffer use, redirection) and
[advanced usage](https://www.youtube.com/watch?v=xHEnWvKmSKM) (presets,
context macros, response integrations, and historical prompt reconstruction
issues). Readable transcripts of both are kept in the research checkout under
`transcript/`.

OpenAI's own Codex client source inspected for the wire format:

- [`ResponsesApiRequest`](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/common.rs):
  request-level fields and serialization.
- [`ResponseItem` and `ContentItem`](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs):
  message, text, and non-prose item structures.

Official provider reference for the underlying Responses API shape:
[OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses/create).
The subscription Codex endpoint has its own accepted parameter set; use the
inspected OAuth code and actual endpoint behavior rather than assuming every
public API option works.
