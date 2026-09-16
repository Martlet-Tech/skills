---
name: dsh-configure-codebuddy
description: Configures DeepSeek Harness (DSH) to route models through the Tencent CodeBuddy (or WorkBuddy) subscription gateway instead of the official DeepSeek API. Use when a user wants to add, debug, or repair a hand-declared OpenAI-compatible provider route in DSH settings.yaml — including credential setup, protocol/compat quirks of the gateway, enabling image (multimodal) input, and making reasoning effort actually take effect on such a route.
whenToUse: Use when setting up or troubleshooting a DSH provider route to CodeBuddy/WorkBuddy, when pasted images are rejected on a hand-declared DSH route with UNSUPPORTED_CONTENT, or when the route answers but never thinks — no effort entry in the model picker, no reasoning blocks in the session log, or a bodyless 400 as soon as reasoning is declared.
---

# Configure CodeBuddy / WorkBuddy as a DSH provider

Route DeepSeek Harness model traffic through a Tencent CodeBuddy subscription
gateway. This skill covers the whole path: credential, route declaration,
gateway dialect quirks, and the two declarations a hand-written route is
routinely missing — `input` (images) and `reasoningEfforts` (thinking).

## When to use this skill

- The user wants DSH to run on CodeBuddy/WorkBuddy subscription quota.
- A hand-declared DSH route fails to authenticate, returns 400/404/504, or
  streams but never answers.
- **Pasted images are rejected** on such a route (often surfaced as
  `UNSUPPORTED_CONTENT`, `does not support image input`).
- **The route never thinks** — no effort entry in the model picker, no
  `reasoning` content blocks in the session log. See Step 3.

## Background: why a hand-written route is needed

DSH's `dsh-llm-pi-ai` adapter serves providers from pi-ai's installed catalog.
**`codebuddy` is not in that catalog**, so the whole provider must be declared
by hand in user settings. Only the `llm-pi-ai` namespace describes an entire
provider this way — a `llm-deepseek` route is a composition fact and cannot be
created from settings.

Settings live at `<DSH_HOME>/settings.yaml` (default `~/.dsh/settings.yaml`).
Credentials live at `<DSH_HOME>/.credentials.yaml`.

## Step 1 — store the credential

In `<DSH_HOME>/.credentials.yaml`, under `refs:`:

```yaml
version: 1
refs:
  CODEBUDDY_API_KEY: ck_xxxxxxxxxxxx.xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The key name is arbitrary; it only has to match `apiKeyEnv` in the route below.

> **Warning (this is a real, observed failure):** the DSH web **Models** page
> writes back to `.credentials.yaml`. It has been seen overwriting
> `CODEBUDDY_API_KEY` with the value of `DEEPSEEK_API_KEY`, which makes the
> CodeBuddy route send the wrong bearer token and fail with **504**. If the
> route suddenly breaks after visiting that page, re-check this file first.

## Step 2 — declare the route

In `<DSH_HOME>/settings.yaml`:

```yaml
agent-default-model:
  provider: codebuddy
  model: deepseek-v4.1-flash

llm-pi-ai:
  providers:
    codebuddy:
      displayName: CodeBuddy
      apiKeyEnv: CODEBUDDY_API_KEY
      api: openai-completions
      baseURL: https://www.codebuddy.cn/v2
      compat:
        # CodeBuddy speaks the DeepSeek dialect: max_tokens only, no developer role.
        thinkingFormat: deepseek
        supportsDeveloperRole: false
        maxTokensField: max_tokens
      streamIdleTimeoutMs: 600000
      models:
        - id: deepseek-v4.1-flash
          name: DeepSeek V4.1 Flash
          contextWindow: 512000
          maxTokens: 32768
          input: [text, image]     # see Step 4 — do not omit on a vision model
          compat:
            # A replayed assistant turn needs an empty reasoning_content while
            # reasoning is on; DeepSeek-dialect gateways expect the field.
            requiresReasoningContentOnAssistantMessages: true
          reasoningEfforts:        # see Step 3 — omit this and the model never thinks
            off:
            high: high
            max: max
        - id: deepseek-v4-flash
          name: DeepSeek V4 Flash
          contextWindow: 131072
          maxTokens: 32768
```

`baseURL` is host-specific and used verbatim:

| Gateway | baseURL |
|---|---|
| CodeBuddy (public product) | `https://www.codebuddy.cn/v2` |
| WorkBuddy (ships `endpoint: https://copilot.tencent.com`) | `https://copilot.tencent.com/v2` |

For WorkBuddy, keep the structure identical and change only `baseURL`, the
route key, and the credential name to match that gateway. Everything else
(`api`, `compat`, `input`, reasoning handling) is the same adapter behavior.

Settings are re-read **per request**, so edits take effect on the next turn with
no restart.

## Step 3 — declare reasoning effort (the other commonly missed step)

Omitting `reasoningEfforts` on a hand-declared model does more than leave the
effort menu empty: DSH registers the model as **non-reasoning** and sends no
thinking field at all, so the endpoint's own default decides — and on a gateway
that defaults to off, the route never thinks.

The decision lives in `dsh-llm-pi-ai`'s `resolveModelReasoning()`:

```js
// A hand-declared model has no installed catalog entry, so `base` is undefined
// and this line decides: reasoning = false.
if (efforts === undefined) return { reasoning: base?.reasoning ?? false }
```

`codebuddy` is not a pi-ai provider id, so `catalogProvider("codebuddy")`
returns `undefined` and there is no `base` to inherit from. `reasoningInfo()`
then withholds the capability outright — `if (!model.reasoning) return {}` —
which is why the model picker shows no effort entry at all rather than a
disabled one.

Declare the levels the gateway accepts. Each key is a level the picker offers
and its value is the spelling sent on the wire, so `max: xhigh` can rename a
level for a gateway with its own vocabulary. Only `off` may be left valueless:

```yaml
          reasoningEfforts:
            off:                     # valueless = "supported, send nothing"
            high: high
            max: max
```

The seven level names are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`,
`max`; a level absent from the dict is not offered. For DeepSeek V4, pi-ai's own
catalog entry declares `high` and `max` only (it pins `low`/`medium` to null),
which is a safe starting pair. Leaving `off` empty sends no reasoning field at
all, which only stops a model that thinks on request; with
`compat.thinkingFormat: deepseek` set (as in Step 2), `off` instead sends
`thinking: {type: disabled}` and every other level sends `thinking: {type: enabled}`
beside the effort.

### Two ways this goes wrong

- **A route-level `reasoning:` on its own.** Setting `reasoning: high` on the
  route while the model still declares no `reasoningEfforts` keeps the model
  non-reasoning, and every request then fails locally with
  `UNSUPPORTED_REASONING_EFFORT` — there is no supported level to select. The
  field itself is valid, so nothing refuses it when written; declare the levels
  as well.
- **A bodyless `400` the moment the model becomes a reasoning model.** pi-ai
  sends the system prompt with `role: "developer"` *only* to a reasoning model,
  and this gateway rejects that role. The tell is that the 400 begins exactly
  when `reasoningEfforts` appears and **persists even with no effort selected**
  — it is the request shape, not the `reasoning_effort` value. Fix with
  `compat.supportsDeveloperRole: false` (already in the Step 2 block); if it
  survives that, add `compat.maxTokensField: max_tokens`.

Verify from the session log rather than by feel. `<DSH_HOME>/sessions/<cwd>/session-*/session.v3.jsonl.zstd`
is **multi-frame** zstd — Node's `zlib.zstdDecompressSync` reads only the first
frame, so use a streaming reader. In the JSONL, `request/header` carries the
per-call `config` (`{provider, model, reasoningEffort?}`), and an assistant
message that thought records `reasoning` entries in `message.content[].type`.
No `reasoning` block means no thinking.

## Step 4 — declare image support

A hand-written route that omits `input` is treated as **text-only**, because
pi-ai falls back to `DEFAULT_INPUT = ["text"]`. DSH then refuses an image
*before it is ever sent*:

```js
// dsh-llm-pi-ai: if (containsImage && !model.input.includes("image"))
//   throw new LlmError(`pi-ai model "${model.id}" does not support image input`, "UNSUPPORTED_CONTENT")
```

The model can be perfectly multimodal and still fail here — the rejection is
purely local configuration, not a gateway limitation.

Fix by declaring modalities either per model or once per route:

```yaml
      # Once for every model on the route that nothing else describes:
      defaultInput: [text, image]
```

`defaultInput` is a *fallback*, not an override: a model whose entry or
installed-catalog entry already declares `input` keeps that value, and it never
narrows one. Prefer per-model `input:` when models differ.

**Verify the gateway before claiming vision.** Over-claiming is the more
expensive mistake: the image is admitted, the provider rejects it mid-turn
*after the message is durable*, and the session loops on a request that cannot
succeed. Confirm real image reading with a solid-color PNG and a color question
— a model that answers the actual color is genuinely reading it:

```bash
# Must use stream:true — see gateway quirks below.
# Host: use the baseURL from the table in Step 2.
curl -sS https://www.codebuddy.cn/v2/chat/completions \
  -H "Authorization: Bearer $CODEBUDDY_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","stream":true,"max_tokens":64,
       "messages":[{"role":"user","content":[
         {"type":"text","text":"What is the dominant color? One word."},
         {"type":"image_url","image_url":{"url":"data:image/png;base64,<BASE64>"}}]}]}'
```

Ask about a color that has no textual give-away (avoid "what color is the sky"
as a control — it answers "blue" with no image at all). A reliable control is
to ask about an attached image when none was sent; a correct model answers that
it sees none.

## Gateway quirks (verified against codebuddy.cn)

| Symptom | Cause | Fix |
|---|---|---|
| `400 {"code":11101,"msg":"Non-stream chat request is currently not supported"}` | Gateway **requires** streaming | Send `"stream": true`. DSH always streams, so this only bites hand-rolled scripts. |
| `400` with an **empty** body | Either the non-stream rejection above, or a reasoning model's `developer` role (next row) | Check whether `reasoningEfforts` is declared before assuming either cause. |
| `400` with an **empty** body, appearing the moment reasoning is declared | Reasoning models get `role: "developer"` for the system prompt; this gateway rejects it | `compat.supportsDeveloperRole: false`. See Step 3. |
| `404 {"error_msg":"404 Route Not Found"}` | Wrong path | Endpoint is `https://<host>/v2/chat/completions`. `/v1/...` and `/v2/v1/...` do not exist. |
| `504` | Wrong bearer token on the route | Check `.credentials.yaml` — see the Models-page warning in Step 1. |
| Images rejected locally | `input` not declared | Step 4. |
| No effort entry in the picker; the route never thinks | Hand-declared model without `reasoningEfforts` | Step 3. |
| `UNSUPPORTED_REASONING_EFFORT`, no request sent | Route-level `reasoning:` with no model-level `reasoningEfforts` | Step 3. |

Note the baseURL is used verbatim — the adapter does **not** append
`/v1`. `baseURL: https://www.codebuddy.cn/v2` plus the client's own
`/chat/completions` produces the correct URL.

## Step 5 — verify

1. Confirm the route resolves and streams a text answer.
2. If vision is claimed, paste an image through the DSH UI and confirm the
   model describes it correctly. An attachment that reaches the model arrives
   as a normalized copy under `<DSH_HOME>/attachments/`.
3. If reasoning is claimed, confirm the picker offers the declared levels and
   that a thinking turn logs `reasoning` content blocks (see Step 3).

## Troubleshooting checklist

- **Wrong credential silently used** → inspect `.credentials.yaml` first; the
  Models page can overwrite it.
- **Image rejected with `UNSUPPORTED_CONTENT`** → `input`/`defaultInput` missing.
- **`pi-ai image input requires the durable attachment service`** → the
  composition lacks the attachment service; this is a composition issue, not a
  route-config issue.
- **Route works, then stops after a settings edit** → a refused section keeps
  the namespace's last good value, so a malformed edit can look like a no-op.
  Check the log for `keeping the previously registered routes`.
- **No effort entry, or the route never thinks** → the hand-declared model has
  no `reasoningEfforts`. Step 3.
- **`UNSUPPORTED_REASONING_EFFORT`** → a route-level `reasoning:` without
  model-level `reasoningEfforts`. Step 3.
- **Bodyless `400` right after declaring reasoning** → the `developer` system
  role. Step 3.
- **Do not use `max_tokens` and `max_completion_tokens` interchangeably** —
  this gateway accepts `max_tokens` only, hence `maxTokensField: max_tokens`.

## Pitfalls

- **`api` is mandatory** for a route pi-ai does not ship. Omitting it fails to
  resolve.
- **`provider` is not a route field.** It moved to the `providers` dict key;
  setting it inside an entry is rejected outright.
- **`maxRetries`/`maxRetryDelayMs` were removed** from this namespace; compose
  recovery with `dsh-llm-retry` instead.
- **Provider ids are lowercase hyphenated identifiers.** A key outside that
  grammar cannot address a stored credential record and so cannot use
  interactive sign-in; such routes must authenticate via `apiKeyEnv`.
- **A `llm-deepseek` route is not a drop-in fallback.** It brings its own
  `off`/`low`/`high`/`max` levels and defaults `reasoningEffort` to `high`, so
  it reasons without any of the above — but its `baseURL` must be a **base**.
  Writing `https://<host>/v1/chat/completions` there makes every request fail
  (seen as `HTTP 403 AUTH` with a key that looks fine); drop the path.
