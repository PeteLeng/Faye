# Faye: v1 foundation specification

*Status: draft v1 (2026-10-07). This is a fresh, deliberately small
specification. It does not inherit scope from `spec.md`. Anything not listed
here is out of scope for v1.*

## 1. Product goal

Faye is an Emacs-native client that sends text to OpenAI using the user's
ChatGPT plan. A prompt comes from an active region or, when no region is
active, from one minibuffer read. Responses stream into a dedicated response
buffer.

Each working buffer has one attached in-memory conversation session. The
session, not buffer text, owns the conversation history used by follow-up
requests.

V1 supports:

- One provider: OpenAI through the official ChatGPT-plan OAuth flow.
- One active ChatGPT account.
- Account-specific model discovery and one current model selection.
- One in-memory session attached to a working buffer.
- Text prompts and streamed text presentation.
- Full-history follow-ups.
- Cancellation, visible errors, and tagged logging.

Sessions are not persisted in v1.

## 2. Official provider contract

Faye uses OpenAI's documented ChatGPT plan usage flow for open-source,
locally hosted applications. It must not use ChatGPT's internal
`backend-api` endpoints.

### Authentication

On first sign-in, Faye dynamically registers a client and saves the issued
client ID. It generates and persists one stable, opaque `ext_agent_host_id`
for the local Faye installation.

Each authorization attempt uses a fresh PKCE verifier, `state`, and OIDC
`nonce`. The loopback callback uses `127.0.0.1` and the `/auth/callback` path.

The authorization and token endpoints are:

```text
https://auth.openai.com/api/accounts/authorize
https://auth.openai.com/api/accounts/oauth/token
```

The authorization request uses the resource `https://api.openai.com/v1` and
requests these scopes:

```text
openid profile email offline_access resource.invoke chatgpt.tokens.use.direct
```

Faye validates callback state before exchanging the code. It validates the ID
token's signature, issuer, audience, expiry, and nonce before accepting the
account. Inference is allowed only when the granted scopes contain
`chatgpt.tokens.use.direct`.

Faye stores the issued client ID, host ID, validated account identity, access
token, rotating refresh token, expiry, and granted scopes separately from
conversation state. Operations acquire a currently usable access token. Faye
reuses the cached token and refreshes it near expiry using the documented
refresh-token flow. Refreshes for the active account are serialized so rotating
refresh tokens cannot race. Credentials, authorization codes, and token values
must never be logged.

V1 has one active account and no account-switching interface.

### Model discovery

Faye obtains the active account's model catalog with:

```text
GET https://api.openai.com/v1/models
Authorization: Bearer <access token>
```

The model picker includes entries whose `visibility` is `list`, displays each
entry's `display_name`, and uses its `slug` as the request's `model`. The
selected slug is runtime configuration, not session history.

### Inference

Faye sends requests to:

```text
POST https://api.openai.com/v1/responses
Authorization: Bearer <access token>
Content-Type: application/json
```

Each request supplies the selected account-supported `model`, sends the full
required history in `input`, and sets `store` to `false` and `stream` to `true`.
`input` contains the session's successful provider items followed by the newly
staged user message. Faye does not use `previous_response_id`.

The exact v1 request fields, input and output item shapes, response envelope,
and streaming-event schemas are owned by the separate
[OpenAI HTTP and data model](openai-data-model.md). Open choices in that
document remain non-normative until they are reflected here deliberately.

Faye consumes the HTTP response as Server-Sent Events. At the provider level,
only `response.completed` permits application success. `response.failed`,
explicit error events, non-2xx HTTP responses, and streams that end without
completion are failures.

Faye retains the complete response output items needed for a follow-up, not
only their rendered text or only the fields understood by the renderer.

Official references:

- [ChatGPT plan usage overview](https://developers.openai.com/siwc/token-sharing-open-source)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Responses API](https://developers.openai.com/api/reference/resources/responses)
- [Streaming responses](https://developers.openai.com/api/docs/guides/streaming-responses)

## 3. Core invariants

1. **The session is authoritative.** Buffer contents are never reparsed to
   reconstruct conversation history.
2. **A successful exchange enters history as one pair.** A request succeeds
   only after a valid completed provider response is received and its
   user/assistant pair is added together to the live in-memory session. Other
   outcomes leave replayable history unchanged.
3. **The latest request remains inspectable.** A staged, failed, or cancelled
   request keeps its captured prompt, body, partial response, provider response
   when available, and error in runtime state without entering follow-up
   context.
4. **Provider completion is validated before history changes.** A
   `response.completed` event must contain a valid completed response whose
   output can form an assistant record. The pair is validated before either
   record is added.
5. **A request body is captured once.** Inspection, logging metadata, and
   transport refer to the same constructed value. Transport does not rebuild
   it.
6. **Input is captured at invocation.** Later point, mark, or buffer changes do
   not alter the request.
7. **One request may be active per session.** A session rejects another
   submission while its latest request is staged or in flight. Independent
   sessions may run concurrently.
8. **Each request is one immutable invocation.** Its state moves forward and
   reaches at most one terminal outcome. A later resubmission is a new request
   with its own identity and captured body.
9. **Terminal callbacks cannot change the outcome.** OAuth, process, and SSE
   callbacks belonging to a terminal request cannot start transport, add
   records, invoke terminal completion again, or replace its status.
10. **Provider items are retained.** Rendered prose never replaces the complete
    items required for follow-up context.
11. **Presentation is not transport.** A response-buffer insertion failure does
    not become an HTTP or SSE failure and cannot corrupt history.
12. **Logging is observational.** Logging failures cannot alter authentication,
    transport, parsing, live-session updates, or presentation behavior.
13. **Secrets are never logged.** This includes tokens, authorization headers,
    OAuth codes, and callback query values.

## 4. Minimal runtime model

V1 has four runtime concepts.

```text
Session
  id
  ordered successful records
  latest request, if any

Record
  local id
  role: user or assistant
  provider items
  request or response metadata needed for inspection

Request
  id
  session
  staged user record
  captured request body
  status
  transport handle
  partial text
  completed response or error

Credentials
  issued client ID and host ID
  validated account identity
  access and refresh tokens
  expiry and granted scopes
```

A user record contains only the newly captured user input items. An assistant
record contains the completed response output items. Records are treated as
immutable after they enter session history.

Request status is one of:

```text
staged -> in-flight -> succeeded
staged -> failed or cancelled
in-flight -> failed or cancelled
```

The states mean:

- `staged`: the prompt and exact request body are captured and validated, but
  provider transport has not started. The request may be waiting for a usable
  access token.
- `in-flight`: provider transport has started, so the provider may have
  received the request. Streaming may be underway.
- `succeeded`: a valid completed provider response was received, and its
  user/assistant pair was added to the live in-memory session.
- `failed`: the request could not produce a valid pair in live session history.
  Its available prompt, body, partial response, provider response, and error
  remain inspectable.
- `cancelled`: the user stopped the request before it succeeded. Its available
  runtime data remains inspectable and no pair is added to history.

`succeeded`, `failed`, and `cancelled` are terminal. Callbacks may still release
resources or log observations after a terminal transition, but they cannot
perform another state transition. The latest request remains attached to its
session after termination and is replaced only when a later request is staged.

Sessions live only for the current Emacs process. A response buffer shares the
same session as its originating working buffer but remains only a presentation
surface.

## 5. Request lifecycle

The successful path is:

```text
capture prompt
  -> get or create the buffer's session
  -> require a selected account model
  -> create the staged user record
  -> construct the request body once
  -> create a staged request and retain it as the session's latest request
  -> acquire a usable cached or refreshed OAuth token
  -> start the HTTP request and mark it in-flight
  -> consume SSE and present text deltas
  -> receive response.completed
  -> validate the completed response
  -> construct the assistant record
  -> add the user and assistant records together to the live session
  -> mark the request succeeded
```

Authentication failure, HTTP failure, provider failure, an invalid or
truncated stream, cancellation, and live-session pair-addition failure are
terminal non-success outcomes. They leave successful session history unchanged
and preserve the available request data and error for inspection, display, and
logging.

Cancelling a staged request marks it cancelled and prevents a later token
callback from starting transport. Cancelling an in-flight request marks it
cancelled before stopping the transport process, so a process sentinel or SSE
callback caused by shutdown cannot replace the outcome.

V1 does not retry automatically. A later submission creates a new request and
does not reactivate the earlier terminal request.

## 6. Initial user flow

V1 exposes this command surface:

- `faye-login`: authorize one ChatGPT account and save its credentials.
- `faye-model-select`: fetch the account catalog and select one model slug.
- `faye-send`: capture and submit a prompt.
- `faye-abort`: cancel the current session's staged or in-flight request.
- `faye-session-new`: create and attach a fresh in-memory session to the current
  buffer.
- `faye-log-show`: display the log buffer.

`faye-send` uses the exact active region when one exists. It performs no
additional prompt read in that case. Without an active region, it reads one
prompt with `read-string`. Invoking Faye from inside an already-active
minibuffer is not supported in v1.

On the first send from a working buffer, Faye creates and attaches a session.
Later sends from that buffer continue it. `faye-session-new` creates and
attaches a fresh session for future sends without changing buffer contents or
mutating the previously attached session.

Each session has one dedicated response buffer. It is read-only to the user
and shows submitted prompts, streamed response text, terminal completion, and
visible errors. It shares the session, so `faye-send` there can read a
minibuffer prompt and continue the same conversation. Killing the response
buffer does not alter session history; Faye recreates it when needed.

Logging uses the existing Java-style level functions with `(TAG MESSAGE)`:

```elisp
(faye-log-debug "REQUEST" "request staged id=req-17")
(faye-log-info  "HTTP" "response status=200 id=req-17")
(faye-log-warn  "SSE" "stream ended without completion id=req-17")
(faye-log-error "SESSION" "pair addition failed id=req-17")
```

The initial tags are `REQUEST`, `AUTH`, `HTTP`, `SSE`, and `SESSION`. Each
request has a correlation ID. Logging records state transitions, event types,
sizes, status codes, and failures, but not prompt or response contents by
default. Logging never displays its buffer automatically.

## 7. Acceptance criteria

V1 is accepted when these paths work:

1. A new installation completes official dynamic registration and login;
   restart loads the credentials and refreshes them when required.
2. Invalid OAuth state, ID-token validation, missing plan scope, and unusable
   refresh credentials are rejected without leaking secrets.
3. Model selection lists the active account's visible models and sends the
   selected slug to `POST https://api.openai.com/v1/responses`.
4. Region sending transmits exactly the selected text, excludes unselected
   text, and performs no second prompt read.
5. Sending without a region reads one prompt from the minibuffer.
6. Text appears progressively while Emacs remains responsive, including when
   UTF-8 characters or SSE records cross process-chunk boundaries.
7. The first success adds exactly one user and one assistant record together,
   then gives the request status `succeeded`.
8. A follow-up sends the earlier provider items followed by the new user item.
9. Failure, truncation, and cancellation add no records to session history and
   leave the latest request inspectable.
10. A second submission in one session is rejected while its request is
    staged or in flight; independent sessions can run concurrently.
11. A usable cached access token starts transport without a refresh request;
    a token near expiry is refreshed before transport starts.
12. Cancelling before token refresh completes prevents HTTP submission.
13. Cancelling in flight prevents later process or SSE callbacks from changing
    the terminal status or adding records.
14. Presentation and logging failures do not change provider or history state.
15. A pair-addition failure leaves history unchanged and gives the request
    status `failed`.
16. Every request reaches at most one of `succeeded`, `failed`, or `cancelled`.
17. Logs correlate staging, authentication, HTTP, SSE completion, live-session
    update, and terminal status without containing secrets.
18. Creating a fresh session causes the next request to contain no prior
    conversation history and does not mutate the previously attached session.

## 8. Explicitly deferred work

The following are not part of v1:

- SQLite or any other session persistence.
- Multiple accounts or account switching.
- Multiple saved sessions per file, session discovery, or a session picker.
- Org history views or writable draft areas.
- Append, replace, echo, or minibuffer-replacement output actions.
- Invocation from inside an already-active minibuffer.
- Prompt macros, including `@include`.
- Session forks, branch history, or history editing.
- Options menus and per-request model or instruction overrides.
- System-instruction profiles.
- Model-requested tools or tool-result loops.
- Media input or file-upload APIs.
- Generic providers or provider plugin abstractions.
- Automatic context compaction.
- Automatic retry behavior.
- Device-code login.
