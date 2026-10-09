# Faye: v1 foundation specification

*Status: draft v1 (2026-10-08). This specification defines v1 independently
of `spec.md`. Instructions and the interrupted-response filter remain open.*

## Scope and document ownership

Faye is an Emacs-native text client using one ChatGPT account through OpenAI's
official ChatGPT-plan OAuth flow. It supports account model discovery,
region/minibuffer prompts, streamed responses, full-history follow-ups,
cancellation, visible errors, and tagged logging.

Each working buffer has one attached Session and each Session has one response
buffer. The Session owns conversation history; buffers are input and
presentation surfaces. Buffer text is never reparsed to reconstruct history.
Sessions live in memory for the current Emacs process. Credentials are
persisted separately; session persistence is outside v1.

| Document | Owns |
|---|---|
| This specification | Scope, runtime model, history, Request lifecycle, commands, acceptance. |
| [OpenAI HTTP and data model](openai-data-model.md) | Official OAuth, HTTP, JSON, SSE, validation, and logging requirements. |
| [Response item filtering](response-replay.md) | Meaning of `Resp_i.items.filter(...)`; interrupted-response rules are undecided. |

The implementation starts from this contract. Earlier implementation choices
and the broader `spec.md` roadmap do not extend v1 scope.

## Notation and history

Indices refer to successive Requests in the same Session. Arrays are ordered
oldest first; `++` means flat, order-preserving concatenation.

| Symbol | Meaning |
|---|---|
| `user_i` | Newly captured user input item for Request `i`. |
| `Req_i` | Request `i`, including its captured body and runtime status. |
| `Req_i.items` | Shorthand for `Req_i.body.input`; a captured input array. |
| `Resp_i` | Locally accumulated provider Response data for `Req_i`. A final provider envelope may never arrive. |
| `Resp_i.items` | Ordered response items accumulated from SSE, including partial items; `[]` if none were received. |

### Request construction

For full-history continuation, with no history edits or compaction:

```text
Req_1.items = [user_1]

Req_{i+1}.items =
  Req_i.items ++ Resp_i.items.filter(...) ++ [user_{i+1}]
```

The recurrence describes the resulting input, not a requirement to retain or
concatenate every earlier request body. Each user Record contains only
`[user_i]`; earlier items already belong to earlier Records.

The body is constructed and deep-copied once per Request. Inspection, logging
metadata, and transport use that captured value. The selected model is current
runtime configuration, not an option inherited from previous user Records.

### Retention and filtering

```text
Req_i becomes staged
  => append its user Record to Session history exactly once

Req_i becomes failed or cancelled
  => retain that user Record

Req_i becomes succeeded
  => Resp_i.items.filter(...) = Resp_i.items
```

Response data is accumulated during streaming and retained on termination.
Filtering selects items for the next input; it preserves their order and
fields and does not erase or mutate the retained response. The detailed
filter for failed/cancelled Requests is an open decision in
[response-replay.md](response-replay.md), not an implicit discard-all rule.

Future persistence must use the same history-retention rules as memory,
including unsuccessful Requests' user Records and retained response data.
Saving history does not determine Request success.

## Runtime model

V1 uses small runtime records; provider data retains its JSON shape.

| Concept | Contents and ownership |
|---|---|
| Session | Local ID, ordered Records, latest Request if any. |
| Record | Local ID, user/assistant role, provider items, request/response metadata needed for inspection. |
| Request | Local ID, Session, user Record, captured body, status, transport handle, partial text, accumulated response items, provider envelope when available, error when available. |
| Credentials | Issued client ID, stable host ID, validated identity, access/refresh tokens, expiry, granted scopes. |

A user Record is captured and attached at `staged`. At termination, an
assistant Record retains available response items and metadata, including the
Request outcome, when response data exists. This includes partial responses;
the filter is applied when constructing subsequent input. Records are
deep-copied and treated as immutable once attached to history.

The Request's identity, prompt, and body are fixed. Its status, transport
handle, partial text, and response/error data evolve during execution.
The latest Request remains attached after termination and is replaced only
when another Request is staged. It retains the captured prompt/body and all
available partial response, provider envelope, and error for inspection.

## Request lifecycle

### States and history effects

```text
staged    -> in-flight | failed | cancelled
in-flight -> succeeded | failed | cancelled

succeeded | failed | cancelled -> no further transition
```

| Status | Meaning and history effect |
|---|---|
| `staged` | Prompt and body are captured and validated; user Record and latest Request are attached. Provider transport has not started; token acquisition may be pending. |
| `in-flight` | Provider transport has started and may have delivered the request. Response items accumulate on the Request. |
| `succeeded` | A valid completed provider Response was received and its assistant Record was added to the live Session. The user Record was already added at `staged`. |
| `failed` | Authentication, transport, parsing, provider completion, or assistant-Record construction/addition failed. Retain the user Record and available response/error data. |
| `cancelled` | The user stopped a staged/in-flight Request. Retain the user Record and available response data. |

Input rejected before staging adds no Record. Staging attaches the user Record
and latest Request together. If completion-time assistant-Record construction
or addition fails, fail the Request and keep the response inspectable on it;
its user Record remains in history. Retention errors during cancellation must
not replace `cancelled` with another outcome.

### Successful path

```text
capture input -> ensure Session -> require selected account model
  -> capture user Record and body -> stage
  -> acquire usable token -> start transport / in-flight
  -> accumulate SSE items and present deltas
  -> validate response.completed -> attach assistant Record / succeeded
```

Completion validation is defined in
[the wire contract](openai-data-model.md#completion-validation).
The history update and terminal status are settled before terminal observers
run. A provider completion alone is insufficient if its assistant Record
cannot be added to the live Session.

### Execution invariants

| Rule | Requirement |
|---|---|
| Concurrency | At most one `staged` or `in-flight` Request per Session; independent Sessions may run concurrently. |
| Cancellation | Set `cancelled` before stopping transport. A later token callback must not start transport. |
| Terminal callbacks | May release resources or log observations; cannot start transport, mutate captured history/response data, change outcome, or notify terminal completion again. |
| Retry | No automatic retries. A later submission is a new Request with a new ID and captured body. |
| Presentation | Insertion/display failures cannot become HTTP/SSE failures or change Request outcome/history. |
| Logging | Logging failures cannot change authentication, transport, parsing, history, or presentation. |

## Provider and user interface

### Provider

Use the [official provider contract](openai-data-model.md): dynamic client
registration, validated OAuth login, cached/serialized token refresh,
account-specific model discovery, and streaming Responses requests. V1 has
one active account. Internal ChatGPT `backend-api` endpoints are excluded.

### Commands

| Command | Behavior |
|---|---|
| `faye-login` | Authorize the active account and save its credentials. |
| `faye-model-select` | Fetch visible account models and select one slug. |
| `faye-send` | Capture the exact active region, or read one prompt with `read-string`; ensure the buffer's Session and stage a Request. |
| `faye-abort` | Cancel the current Session's staged/in-flight Request. |
| `faye-session-new` | Attach a fresh Session to the current buffer without modifying its contents or the previous Session. |
| `faye-log-show` | Display the log buffer. |

Region input requires no additional prompt read. Later point, mark, or buffer
changes do not affect the captured input. Invocation from an already-active
minibuffer is outside v1.

The first send attaches a Session; later sends continue it. Its dedicated
response buffer is read-only and displays prompts, streamed text, terminal
status, and errors. It shares the originating buffer's Session, so sending
there continues the same conversation. Killing it does not change history;
Faye recreates it when needed.

Logging uses `faye-log-debug/info/warn/error`, each with `(TAG MESSAGE)`.
Initial tags are `REQUEST`, `AUTH`, `HTTP`, `SSE`, and `SESSION`; each Request
has a correlation ID. The log buffer never opens automatically. The wire
contract owns the [logging content rules](openai-data-model.md#logging-and-live-verification).

## Acceptance criteria

| Path | Required observation |
|---|---|
| New installation and restart | Official registration/login succeeds; credentials reload and refresh when needed. |
| Invalid authentication | Bad callback state, ID-token validation, missing plan scope, or unusable refresh credentials are rejected without leaking secrets. |
| Model selection | Only visible account models are listed; the selected slug appears in the captured inference body. |
| Input capture | Exact region, no second prompt read, or one minibuffer read; later buffer changes do not affect input. |
| Staging | Exactly one user Record enters history; invalid input adds none; body is captured once. |
| Streaming | Emacs stays responsive and renders progressively across UTF-8/SSE chunk boundaries. |
| Success and follow-up | One assistant Record is added, the user Record is not duplicated, status becomes `succeeded`, and the next input satisfies the recurrence. |
| Failure/truncation/cancellation | User Record remains; available response/error data stays inspectable. No response data is mistaken for successful completion. Interrupted replay checks await the filter decision. |
| Concurrency | A second active Request in one Session is rejected; independent Sessions progress concurrently. |
| Token acquisition | Usable cached token avoids refresh; near-expiry token refreshes; concurrent refresh waiters share one refresh. |
| Cancellation races | Cancellation before token acquisition prevents HTTP submission; process/SSE callbacks after cancellation cannot change outcome or history. |
| Completion failure | Invalid completion or assistant-Record construction/addition failure produces `failed`; user Record and Request inspection data remain. |
| Observer isolation | Presentation/logging failures preserve provider/history state; terminal notification occurs at most once. |
| Logging | Correlates staging, auth, HTTP, SSE, history update, and outcome using permitted metadata only. |
| Fresh Session | Its first Request contains no earlier conversation; the previously attached Session is unchanged. |

## Open decisions and deferred scope

Open contract decisions:

- [Filtering failed/cancelled response items](response-replay.md).
- [Instruction semantics](openai-data-model.md#open-decision-instructions).

Outside v1:

- Session persistence, including SQLite; multiple accounts/account switching.
- Saved-session discovery/pickers, multiple saved sessions per file.
- Org history views, writable drafts, forks, branches, and history editing.
- Append/replace/echo/minibuffer-replacement output actions; active-minibuffer invocation.
- Prompt macros (`@include`), instruction profiles, options menus, per-request overrides.
- Model-requested tools/tool-result loops, media input, file uploads.
- Generic providers/plugin abstractions, automatic compaction or retries, device-code login.
