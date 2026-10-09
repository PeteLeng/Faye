# OpenAI HTTP and data model

*Status: v1 wire reference (2026-10-08). Instructions and interrupted-response
filtering remain open. The [foundation specification](spec-v1.md) owns Session
history and Request lifecycle; this document maps them to the provider.*

## Official sources

| Contract | Official reference |
|---|---|
| ChatGPT-plan flow | [Overview](https://developers.openai.com/siwc/token-sharing-open-source) |
| Registration, authorization, identity | [Sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) |
| Tokens and refresh | [Token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference) |
| Account models and inference | [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) |
| Plan-specific restrictions | [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) |
| Request/Response schemas | [Create a Response](https://developers.openai.com/api/reference/resources/responses/methods/create) |
| SSE schemas | [Streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events) |
| Plan-specific errors | [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) |
| Request IDs and diagnostic headers | [API debugging](https://developers.openai.com/api/reference/overview#debugging-requests) |
| Stateless reasoning | [Reasoning without stored responses](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-without-stored-responses) |

Generated SDK types cross-check the public schema; they do not supersede plan
restrictions. Observed traffic verifies behavior, not a new provider contract.

## Provider setup

API requests use HTTPS at `https://api.openai.com/v1`.

### Authentication

On first login, dynamically register a client and persist its issued client ID
and one stable, opaque installation `ext_agent_host_id`.

| Setting | Value |
|---|---|
| Authorization endpoint | `https://auth.openai.com/api/accounts/authorize` |
| Token endpoint | `https://auth.openai.com/api/accounts/oauth/token` |
| Resource | `https://api.openai.com/v1` |
| Loopback callback | Host `127.0.0.1`, path `/auth/callback` |
| Scopes | `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` |

Each authorization attempt uses a fresh PKCE verifier, `state`, and OIDC `nonce`.
Validate callback state before code exchange. Validate the ID token's
signature, issuer, audience, expiry, and nonce before accepting the account.
Inference requires the granted `chatgpt.tokens.use.direct` scope.

Persist the validated identity, access token, rotating refresh token, expiry,
and granted scopes with the client/host IDs, separately from Session history.
Operations acquire a usable token: reuse the cached token, refresh near expiry,
and serialize refreshes for the active account so rotating refresh tokens
cannot race.

### Models

```http
GET /v1/models HTTP/1.1
Host: api.openai.com
Authorization: Bearer <ACCESS_TOKEN>
```

No request body. Successful JSON has this shape, with additional fields allowed:

```json
{
  "models": [
    {"slug": "account-model", "display_name": "Account Model", "visibility": "list"}
  ]
}
```

Preserve server order, include entries with `visibility == "list"`, display
`display_name`, and send the selected `slug` as `model`.

## Inference request

### HTTP

```http
POST /v1/responses HTTP/1.1
Host: api.openai.com
Authorization: Bearer <ACCESS_TOKEN>
Content-Type: application/json
```

Optional headers: `Accept: text/event-stream` and
`X-Client-Request-Id: <Req_i.id>`. The latter must be unique ASCII of at most
512 characters. `stream: true` selects SSE; `Accept` is descriptive.

Transport libraries supply headers such as `Host`, `Content-Length`, and
`User-Agent`; their exact values/order are not part of Faye's contract.
The official plan flow does not document `ChatGPT-Account-Id` or `Originator`,
and Faye does not depend on them or internal `backend-api` endpoints.

### Body

The baseline first request, pending the instruction decision:

```json
{
  "model": "account-model",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [{"type": "input_text", "text": "Hello"}]
    }
  ],
  "store": false,
  "stream": true
}
```

The first input item illustrates `user_1`. Faye uses this expanded item shape
rather than the also-supported `{"role":"user","content":"Hello"}` form.
For every Request, `input = Req_i.items` as defined by the
[history recurrence](spec-v1.md#request-construction); transport serializes the
captured body without rebuilding it. Every inference body uses the selected
model slug, `store: false`, and `stream: true`.

Omit `previous_response_id`. Plan restrictions also forbid fields including
`background`, `conversation`, `metadata`, `prompt`, `temperature`, `top_p`,
`truncation`, and `user`; the preview-limitations page owns the full list.

With `store: false`, current reasoning documentation says encrypted reasoning
is returned by default. `include: ["reasoning.encrypted_content"]` remains
accepted but is not required. Preserve returned opaque values without
generating or inspecting their contents.

## Response items and representation

This literal output array illustrates one reasoning item and one assistant
message. Subsequent schematic examples call it `output_items`:

```json
[
  {
    "id": "rs_123", "type": "reasoning", "status": "completed",
    "summary": [], "encrypted_content": "<OPAQUE_PROVIDER_VALUE>"
  },
  {
    "id": "msg_123", "type": "message", "role": "assistant",
    "status": "completed", "phase": "final_answer",
    "content": [
      {"type": "output_text", "text": "Hi.", "annotations": [], "logprobs": []}
    ]
  }
]
```

Retain unknown fields and passive output items. Preserve an assistant item's
optional `phase` when returned. Rendering text/refusal content is a view;
rendered strings cannot replace the retained provider items.

| JSON | Lisp |
|---|---|
| object | Property list with keyword keys |
| array | Vector |
| string / number | String / integer or float |
| `true` / `false` / `null` | `t` / `:false` / `nil` |

Deep-copy captured bodies and response data before storing immutable Records.
The [filter document](response-replay.md) owns interrupted-item eligibility;
filtering must not modify retained data.

## Streaming

A successful streaming HTTP response uses `Content-Type: text/event-stream`.
Record `x-request-id`, `openai-version`, `openai-processing-ms`, and rate-limit
headers when present; their absence is not failure. HTTP version and header
order are not fixed.

An SSE record ends with a blank line. Accumulate arbitrary byte chunks across
UTF-8 and SSE boundaries, handle LF/CRLF/CR line endings, and join multiple
`data:` lines before decoding their JSON value. Example wire record:

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_123","output_index":1,"content_index":0,"delta":"Hi","logprobs":[],"sequence_number":5}

```

Use JSON `type` as the event discriminator; the SSE `event` field may repeat it.
Unknown event types/additional fields are allowed and must not by themselves
cause failure.

| Event | Relevant payload | Effect |
|---|---|---|
| `response.output_item.added` | `output_index`, `item` | Introduce an item at its output position. |
| `response.content_part.added/done` | `item_id`, `output_index`, `content_index`, `part` | Assemble/update the corresponding content part. |
| `response.output_text.delta` / `response.refusal.delta` | Item/content indexes, `delta` | Accumulate content and notify presentation. |
| `response.output_item.done` | `output_index`, `item` | Retain the finalized provider item at that position. |
| `response.completed` | `response` | Validate completion; final `response.output` is authoritative. |
| `response.failed` / `response.incomplete` | `response` | Retain provider envelope and fail the Request. |
| `error` | `code`, `message`, `param` | Retain structured error and fail the Request. |

Assembled items form `Resp_i.items`. Retain received items if interrupted even
when no final envelope arrives; never invent a completed Response. A
failed/incomplete envelope is retained alongside available accumulated data.

These are schematic event objects, not literal JSON (`output_items` is the
array above; ellipses omit other provider fields):

```text
{
  type: "response.output_item.done", output_index: 0,
  item: output_items[0], sequence_number: 8
}

{
  type: "response.completed", sequence_number: 10,
  response: {
    id: "resp_123", object: "response", status: "completed",
    created_at: 1791331200, model: "account-model",
    error: null, incomplete_details: null,
    output: output_items,
    usage: {
      input_tokens: 10, input_tokens_details: {cached_tokens: 0},
      output_tokens: 5, output_tokens_details: {reasoning_tokens: 2},
      total_tokens: 15
    }, ...
  }
}
```

### Completion validation

Only a valid `response.completed` permits `Req_i.status = succeeded`:

- Its `response` is an object with a nonempty string `id`,
  `status == "completed"`, and an `output` array of provider items.
- A non-null provider `error` or `incomplete_details` contradicts completion.
- Recognized items have the fields required by their provider input shapes.
  Preserve unknown passive items/fields; do not require an exact key count.
- Client-side tool actions are unsupported in v1 and produce a visible failure,
  rather than being silently treated as completed assistant text.
- Do not manufacture a missing status/output array from earlier SSE events or
  treat `[DONE]`, HTTP 2xx, item-done, or EOF alone as completion.

Request success also requires the live assistant-Record update described in
[the lifecycle](spec-v1.md#request-lifecycle). Terminal callback guards there
apply to all later stream/process notifications.

## Failures

Non-2xx responses need not use a standard API error shape. For example:

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
x-request-id: req_example

{"detail":"Direct routing is temporarily unavailable"}
```

A structured API error instead has fields such as:

```json
{"error":{"message":"Usage availability could not be checked.","type":"server_error","param":null,"code":"subscription_sharing_usage_unavailable"}}
```

After streaming begins, the relevant shapes are schematic:

```text
{type: "response.failed", response: {
  ..., status: "failed", error: {code: "...", message: "..."}, output: [...]
}, sequence_number: 4}

{type: "response.incomplete", response: {
  ..., status: "incomplete", incomplete_details: {reason: "max_output_tokens"},
  output: [...]
}, sequence_number: 4}

{type: "error", code: "server_error", message: "...", param: null,
 sequence_number: 4}
```

Retain HTTP status, content type, request ID when present, and the whole decoded
error/envelope value. A display message is derived from this data, not a
replacement for it. Error bodies remain inspection data, not log content.

`response.failed`, `response.incomplete`, `error`, non-2xx HTTP, malformed SSE,
invalid JSON, and EOF without valid completion are non-success outcomes.

## Logging and live verification

Sanitize before data enters the log buffer. For a controlled first request and
follow-up, the following metadata is sufficient to verify the wire contract:

| Area | Permitted metadata |
|---|---|
| Request | Correlation ID, method, sanitized URL, header names, body byte count, field names, input item types/count. |
| HTTP | Status, content type, request ID, version, processing time, rate-limit headers when present. |
| SSE | Type, sequence number, indexes, item type, delta byte count, response status, provider error code. |
| Final Response | Field names, item types, presence of `phase` and encrypted content, encrypted byte length. |

Never log tokens, authorization headers, OAuth codes, callback query values or
URLs, cookies, account IDs, email, prompt/response/refusal text, encrypted
content values, or complete error bodies that may echo input. Do not use an
unsanitized `curl --trace`. Header recording must use the allowlisted response
metadata above.

Example:

```text
SSE type=response.output_item.done seq=8 output-index=0 item=reasoning encrypted-content=yes encrypted-bytes=1840
```

Live fixtures must replace request/item IDs, model output, and opaque encrypted
values with synthetic placeholders.

## Open decision: instructions

Baseline bodies omit instructions pending a product decision. The plan permits
top-level `instructions` or a developer message, and rejects explicit system
input messages. Options:

1. Prompt-only v1.
2. Top-level `instructions`, captured with each Request as configuration.
3. A developer message retained in input history.

Choose whether instructions are configuration or history and how changes
affect an existing Session before making any behavior normative.

## Schema cross-checks

- [Response](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response.py)
- [Output message](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_message.py)
- [Reasoning item](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_reasoning_item.py)
- [Text delta](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_text_delta_event.py)
- [Item done](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_item_done_event.py)
- [Completed](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_completed_event.py), [failed](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_failed_event.py), [incomplete](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_incomplete_event.py), [error](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_error_event.py)
- Input schemas relevant to interrupted replay are referenced in [response-replay.md](response-replay.md#provider-evidence).
