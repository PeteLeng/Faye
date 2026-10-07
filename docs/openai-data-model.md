# OpenAI HTTP and data model

*Status: concrete v1 wire reference with one open decision: instructions.
The examples below use the official public ChatGPT-plan and Responses API
documentation. Observed traffic may verify the contract but does not replace
it.*

## 1. Official sources

There are official references for this flow. They divide into two layers:

| Question | Official source |
|---|---|
| Which endpoint, token, model slug, and required flags? | [ChatGPT-plan models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) |
| Which request fields are forbidden for this plan flow? | [ChatGPT-plan preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) |
| What JSON shapes may `input`, `output`, and a Response contain? | [Create a Response](https://developers.openai.com/api/reference/resources/responses/methods/create) |
| What does each streaming event contain? | [Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events) |
| What do ChatGPT-plan failures look like? | [ChatGPT-plan errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) |
| Which HTTP headers carry request IDs and rate limits? | [API overview: debugging requests](https://developers.openai.com/api/reference/overview#debugging-requests) |
| How is reasoning replayed with `store: false`? | [Reasoning: preserve reasoning without stored responses](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-without-stored-responses) |

OpenAI's generated SDK types are a useful machine-readable cross-check because
they are generated from OpenAI's schema. They are not a substitute for the
ChatGPT-plan restrictions.

## 2. Model discovery

### Request

```http
GET /v1/models HTTP/1.1
Host: api.openai.com
Authorization: Bearer <ACCESS_TOKEN>
```

There is no request body.

### Successful response

```http
HTTP/1.1 200 OK
Content-Type: application/json
x-request-id: req_...

{
  "models": [
    {
      "slug": "account-supported-model",
      "display_name": "Account Supported Model",
      "visibility": "list"
    }
  ]
}
```

The body may contain additional fields. Faye preserves server order, keeps
entries whose `visibility` is `list`, displays `display_name`, and sends `slug`
as the inference `model`.

`x-request-id` is a documented common response header, not a guaranteed field
of every response.

## 3. Inference request

### Headers

The official ChatGPT-plan example sends these two application headers:

```http
POST /v1/responses HTTP/1.1
Host: api.openai.com
Authorization: Bearer <ACCESS_TOKEN>
Content-Type: application/json
```

Faye may also send:

```http
Accept: text/event-stream
X-Client-Request-Id: <FAYE_REQUEST_ID>
```

`Accept` is descriptive but is not required by the official example;
`stream: true` selects SSE. `X-Client-Request-Id` is officially supported and
recommended for tracing when it is unique ASCII of at most 512 characters.

HTTP libraries add transport headers such as `Host`, `Content-Length`, and
`User-Agent`. Faye must not depend on their exact values.

The official public flow does not document `ChatGPT-Account-Id` or `Originator`
request headers. The new v1 contract does not depend on either header.

### First request body

While the instruction decision in section 8 remains open, the exact baseline
body is:

```json
{
  "model": "account-supported-model",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Hello"
        }
      ]
    }
  ],
  "store": false,
  "stream": true
}
```

The Responses API also accepts the shorter
`{"role":"user","content":"Hello"}` form. Faye uses the expanded item form
because it gives session history one stable provider-shaped representation.

The current reasoning documentation says that when `store` is `false`,
reasoning output contains `encrypted_content` by default. The legacy request
field below is still accepted but is not required:

```json
{
  "include": ["reasoning.encrypted_content"]
}
```

Faye should preserve returned encrypted reasoning, not generate or inspect it.

The ChatGPT-plan preview requires Faye to omit `previous_response_id` and send
the required history in `input`. It also forbids fields including `background`,
`conversation`, `metadata`, `prompt`, `temperature`, `top_p`, `truncation`, and
`user`. The preview-limitation page is the authoritative full list.

### Follow-up body

For stateless continuation, Faye sends the earlier user item, every item from
the successful response's `output` array in original order, and the new user
item:

```json
{
  "model": "account-supported-model",
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Hello"
        }
      ]
    },
    {
      "id": "rs_123",
      "type": "reasoning",
      "summary": [],
      "encrypted_content": "<OPAQUE_PROVIDER_VALUE>",
      "status": "completed"
    },
    {
      "id": "msg_123",
      "type": "message",
      "role": "assistant",
      "status": "completed",
      "phase": "final_answer",
      "content": [
        {
          "type": "output_text",
          "text": "Hi.",
          "annotations": [],
          "logprobs": []
        }
      ]
    },
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Continue."
        }
      ]
    }
  ],
  "store": false,
  "stream": true
}
```

The reasoning item is opaque. The assistant `phase` field is optional, but when
the provider returns it Faye must preserve and replay it. Faye must preserve all
other output items and unknown fields as well; rendered assistant text alone is
not sufficient conversation state.

## 4. Successful inference response

With `stream: true`, the response body is not one JSON document. It is an SSE
stream whose `data` values are JSON event objects.

### Headers

A successful response has this semantic shape; the HTTP version and header
order are not fixed:

```http
HTTP/1.1 200 OK
Content-Type: text/event-stream
x-request-id: req_...
openai-processing-ms: ...
openai-version: 2020-10-01
```

Only `Content-Type: text/event-stream` defines the body format. `x-request-id`,
`openai-processing-ms`, `openai-version`, and rate-limit headers are documented
common headers but may be absent. Faye records them when present and does not
fail when they are absent.

### Body

An SSE record ends with a blank line. A text delta looks like:

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_123","output_index":1,"content_index":0,"delta":"Hi","logprobs":[],"sequence_number":5}

```

On the wire, each event object is serialized on one `data:` line as above. The
remaining examples pretty-print that JSON value for readability.

The completed reasoning item carries the reusable opaque value:

```json
{
  "type": "response.output_item.done",
  "output_index": 0,
  "item": {
    "id": "rs_123",
    "type": "reasoning",
    "summary": [],
    "encrypted_content": "<OPAQUE_PROVIDER_VALUE>",
    "status": "completed"
  },
  "sequence_number": 8
}
```

The completed assistant item looks like:

```json
{
  "type": "response.output_item.done",
  "output_index": 1,
  "item": {
    "id": "msg_123",
    "type": "message",
    "role": "assistant",
    "status": "completed",
    "phase": "final_answer",
    "content": [
      {
        "type": "output_text",
        "text": "Hi.",
        "annotations": [],
        "logprobs": []
      }
    ]
  },
  "sequence_number": 9
}
```

Success ends with `response.completed`. Its `response` member is the completed
Response object, including the final ordered `output` array:

```json
{
  "type": "response.completed",
  "response": {
    "id": "resp_123",
    "object": "response",
    "created_at": 1791331200,
    "status": "completed",
    "error": null,
    "incomplete_details": null,
    "instructions": null,
    "model": "account-supported-model",
    "output": [
      {
        "id": "rs_123",
        "type": "reasoning",
        "summary": [],
        "encrypted_content": "<OPAQUE_PROVIDER_VALUE>",
        "status": "completed"
      },
      {
        "id": "msg_123",
        "type": "message",
        "role": "assistant",
        "status": "completed",
        "phase": "final_answer",
        "content": [
          {
            "type": "output_text",
            "text": "Hi.",
            "annotations": [],
            "logprobs": []
          }
        ]
      }
    ],
    "parallel_tool_calls": true,
    "tool_choice": "auto",
    "tools": [],
    "usage": {
      "input_tokens": 10,
      "input_tokens_details": {"cached_tokens": 0},
      "output_tokens": 5,
      "output_tokens_details": {"reasoning_tokens": 2},
      "total_tokens": 15
    }
  },
  "sequence_number": 10
}
```

The public schema permits additional response fields and new event types.
OpenAI explicitly treats those additions as backwards compatible. Faye checks
the fields it needs and preserves the rest instead of requiring an exact key
count.

Faye uses the JSON `type` field as the event discriminator. The SSE `event`
line may repeat the same value.

`[DONE]` is not application success. Only a valid `response.completed` event
can lead to request status `succeeded`.

## 5. Failure responses

### Failure before an SSE stream opens

The ChatGPT-plan documentation explicitly warns that direct admission may
return a non-standard JSON body:

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
x-request-id: req_...

{"detail":"Direct routing is temporarily unavailable"}
```

Faye must not assume every non-2xx response uses the standard API error shape.

A structured API error normally looks like:

```json
{
  "error": {
    "message": "Usage availability could not be checked.",
    "type": "server_error",
    "param": null,
    "code": "subscription_sharing_usage_unavailable"
  }
}
```

Faye retains the HTTP status, content type, `x-request-id` when present, and the
whole decoded JSON value. A human-readable message is derived for display but
does not replace the structured data.

### Failure after streaming begins

A Responses failure event contains a full Response object whose status is
`failed` and whose `error` contains the provider code and message:

```json
{
  "type": "response.failed",
  "response": {
    "id": "resp_123",
    "object": "response",
    "created_at": 1791331200,
    "status": "failed",
    "error": {
      "code": "subscription_sharing_usage_limit_exceeded",
      "message": "Usage limit exceeded."
    },
    "incomplete_details": null,
    "model": "account-supported-model",
    "output": [],
    "parallel_tool_calls": true,
    "tool_choice": "auto",
    "tools": []
  },
  "sequence_number": 4
}
```

An incomplete response has the same outer event shape and records why it did
not complete:

```json
{
  "type": "response.incomplete",
  "response": {
    "id": "resp_123",
    "object": "response",
    "created_at": 1791331200,
    "status": "incomplete",
    "error": null,
    "incomplete_details": {"reason": "max_output_tokens"},
    "model": "account-supported-model",
    "output": [],
    "parallel_tool_calls": true,
    "tool_choice": "auto",
    "tools": []
  },
  "sequence_number": 4
}
```

An explicit stream error has this smaller schema:

```json
{
  "type": "error",
  "code": "server_error",
  "message": "The request failed.",
  "param": null,
  "sequence_number": 4
}
```

`response.failed`, `response.incomplete`, `error`, malformed SSE, invalid JSON,
and EOF without `response.completed` are all non-success outcomes.

## 6. Faye representation

Provider JSON is decoded as follows:

| JSON | Lisp |
|---|---|
| object | property list with keyword keys |
| array | vector |
| string | string |
| number | integer or float |
| `true` | `t` |
| `false` | `:false` |
| `null` | `nil` |

The captured request body and successful response items are deep-copied before
storage in runtime records. Unknown object fields and unknown passive output
items are preserved. Items that request a client-side tool action are not
silently treated as completed assistant text; tool loops are outside v1.

Faye renders `output_text` and refusal deltas for the response buffer. Rendering
is a view. The complete provider items, not the rendered string, are replayed in
the next request.

## 7. Live verification and safe logging

Live traffic can verify what the current service actually sends. It cannot turn
an undocumented behavior into a stable contract.

The current transport in `faye-openai.el` extracts the HTTP status and discards
the parsed response headers. Before live verification, it must expose a
sanitized header record to the request layer.

For one controlled first request and one follow-up, record:

- Request method, URL, header names, body byte count, top-level field names,
  input item types, and input item count.
- HTTP status, `Content-Type`, `x-request-id`, `openai-version`,
  `openai-processing-ms`, and rate-limit headers when present.
- For each SSE event: `type`, `sequence_number`, indexes, item type, delta byte
  count, response status, and provider error code.
- The field names and item types present in the final Response object.
- Whether reasoning `encrypted_content` and assistant `phase` are present.

Never record:

- `Authorization`, access tokens, refresh tokens, ID tokens, OAuth codes, or
  callback URLs.
- Prompt text, response text, refusal text, cookies, account IDs, email, or
  complete error bodies that may echo input.
- `encrypted_content` values. Record only presence and byte length.

Do not use an unsanitized `curl --trace`, because it records the Authorization
header and full request and response bodies. Sanitization must happen before
data enters the Faye log buffer.

A useful sanitized event line is:

```text
SSE type=response.output_item.done seq=8 output-index=0 item=reasoning encrypted-content=yes encrypted-bytes=1840
```

Live fixtures used in tests must replace request IDs, item IDs, model output,
and opaque encrypted values with synthetic placeholders.

## 8. Open decision: instructions

The baseline bodies above intentionally omit instructions.

The ChatGPT-plan preview permits either the top-level `instructions` field or a
developer message and rejects explicit system-message input items. Faye still
needs to choose among:

1. Prompt-only v1.
2. One top-level `instructions` value captured with each request.
3. A developer message represented in replayable `input` history.

The decision depends on the desired session semantics: whether an instruction
is request configuration or conversation history, and what should happen when
it changes during an existing session. No instruction behavior is normative
until that product decision is made and `spec-v1.md` is updated.

## 9. Schema cross-checks

- [Generated `Response` type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response.py)
- [Generated output message type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_message.py)
- [Generated reasoning item type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_reasoning_item.py)
- [Generated text-delta event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_text_delta_event.py)
- [Generated output-item-done event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_item_done_event.py)
- [Generated completed event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_completed_event.py)
- [Generated failed event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_failed_event.py)
- [Generated incomplete event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_incomplete_event.py)
- [Generated error event type](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_error_event.py)
