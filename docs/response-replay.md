# Response item filtering

*Status: discussion draft (2026-10-08). The filter for failed/cancelled
Requests is undecided. Examples below do not establish that policy.*

## Contract boundary

Use the [notation and history recurrence](spec-v1.md#notation-and-history)
from `spec-v1.md`. This document defines the open work behind:

```text
Resp_i.items.filter(...)
```

Agreed constraints:

- `user_i` enters Session history when `Req_i` becomes `staged` and remains
  after failure/cancellation. Response filtering does not decide user retention.
- A succeeded Request replays its complete response item array.
- Filtering selects an ordered subset of whole items without changing their
  fields. It does not mutate or erase retained response data.
- Memory and future persistence follow the same retention policy, including
  data excluded from subsequent input. Persistence is outside v1.
- Replaying an item does not change its Request's terminal status.

## Provider evidence

| Source | What it establishes |
|---|---|
| [Responses input union](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_input_param.py) | Assistant output messages and reasoning items are accepted input item types. |
| [Assistant-message input schema](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_message_param.py) | Requires message ID, role, type, content, and status; permits `in_progress`, `completed`, and `incomplete`. Preserve returned `phase`. |
| [Reasoning-item input documentation](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_reasoning_item_param.py) | For streaming continuation, use the finalized item and encrypted content from `response.output_item.done`; encrypted content from `response.output_item.added` may be incomplete. |

These generated OpenAI types provide schema evidence, not live verification of
every interrupted-input combination on the ChatGPT-plan endpoint. Apply the
[plan restrictions and wire contract](openai-data-model.md) as well.

## Examples

### No response items received

This follows the agreed user-retention rule:

```text
Req_1.items = [user_1]
Resp_1.items = []

Req_2.items = [user_1, user_2]
```

### Interrupted reasoning and assistant text

**Conditional example:** if the filter excludes unfinished reasoning and
retains the partial assistant message, the next request is:

```text
Req_1.items = [user_1]

Resp_1.items = [
  unfinished_reasoning,
  partial_assistant_message
]

Req_2.items = [
  user_1,
  partial_assistant_message,
  user_2
]
```

The retained `Resp_1.items` still contains both items. This example illustrates
selection, not an agreed filter or proof that a particular partial item is
valid provider input.

## Questions for the filter decision

1. Should valid partial assistant text/refusal messages pass for both `failed`
   and `cancelled` Requests? Which fields must be available?
2. Which finalized reasoning items are eligible, and what dependencies must
   remain between selected items?
3. How should empty messages and unfamiliar partial/passive items be treated?
4. Can accumulated items be passed unchanged? If a provider requires a
   transformation, specify it explicitly rather than hiding it in `.filter`.

Once decided, add a filter table and expected input arrays for each outcome,
update the foundation acceptance criteria, and verify with synthetic fixtures
and controlled provider requests. Until then, neither keep-all nor discard-all
is the normative interrupted-response policy.
