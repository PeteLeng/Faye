# Execution loop: design iteration

*Status: discussion draft (2026-10-10). Captures the agreed execution
structure for iteration; it does not yet revise [spec-v1.md](spec-v1.md).*

## Direction

- A captured user prompt starts a conversation loop.
- One execution of that loop is represented by a **Run**.
- A Run can contain multiple model **Requests**; each Request can have multiple
  network **Attempts**.
- Conversation execution and provider/network execution have separate owners.
- Retry is a separate, configurable layer on the network side.
- Introduce this structure before implementing tool use. Initially, a Run
  makes one logical Request.

## Overall structure

```text
Emacs input
(region, minibuffer, ...)
          |
          v
Capture / transform
          |
          v
      User prompt
          |
          v
+-----------------------------+
| Conversation loop — Run     |
|                             |
| Owns conversation progress  |<----> Session history
| Decides finish / continue   |
| Handles user cancellation   |
+-------------+---------------+
              | captured Request body
              v
+-----------------------------+
| Provider/network execution  |
|                             |
| Retry controller            |
|   `- Attempt                |
|        |- acquire token     |
|        |- HTTP exchange     |
|        `- parse / validate  |
+-------------+---------------+
              |
              v
    Progress + terminal result
         back to the Run
```

The Session owns history. The Run coordinates its updates; provider/network
execution receives a captured Request body and reports results.

## Run means loop state

```text
Loop = the behavior
Run  = the state of one execution of that loop
```

This is not a functional-programming requirement. It is the loop's state,
given a name so callbacks, cancellation, and inspection can reference it.
A small Emacs Lisp struct is a suitable representation.

Emacs stays responsive while execution waits:

```text
Start --> submit --> return control to Emacs
                         |
                    network callback
                         |
                         v
                  update Run state
                         |
                   finish / continue
```

Conceptual state ownership, not a finalized field schema:

```text
Run
 |- captured prompt
 |- status
 `- current Request
      |- captured body
      |- status
      `- current Attempt
           |- transport handle
           |- parser / accumulated response
           `- outcome
```

## Two kinds of repetition

### Retry: same Request, same captured body

```text
Request A
   |
   |- Attempt 1 --> retryable failure
   |                      |
   |                    backoff
   |                      |
   `- Attempt 2 <---------+
          |
          v
       Response A
```

A retry does not capture another user prompt or advance conversation history.

### Continuation: new Request, new captured body

```text
User prompt
    |
    v
Request A --> Response A
                  |
                  v
          continuation work
          (future tool use)
                  |
                  v
Request B --> Response B --> finish
```

Retry repeats delivery; continuation advances the conversation.

## Incremental scope

```text
NOW

Prompt --> Run --> Request --> Attempt(s) --> Response --> finish


LATER

Prompt --> Run --> Request --> Attempt(s) --> Response
                     ^                         |
                     |                  finish or tools?
                     |                         |
                     `---- tool results <------+
```

The extension point is the decision after handling a response: finish the Run
or prepare its next Request.

Retry policy/defaults and exact APIs remain undecided. Tool execution and its
effects on history data structures and Request recurrence are deferred to the
tool-use design.
