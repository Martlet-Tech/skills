---
name: dsh-configure-codebuddy
description: Configures DeepSeek Harness (DSH) to route models through the Tencent CodeBuddy (or WorkBuddy) subscription gateway instead of the official DeepSeek API. Use when a user wants to add, debug, or repair a hand-declared OpenAI-compatible provider route in DSH settings.yaml — including credential setup, protocol/compat quirks of the gateway, and enabling image (multimodal) input on such a route.
whenToUse: Use when setting up or troubleshooting a DSH provider route to CodeBuddy/WorkBuddy, or when pasted images are rejected on a hand-declared DSH route with UNSUPPORTED_CONTENT.
---

# Configure CodeBuddy / WorkBuddy as a DSH provider

Route DeepSeek Harness model traffic through a Tencent CodeBuddy subscription
gateway. This skill covers the whole path: credential, route declaration,
gateway dialect quirks, and the multimodal (`input`) declaration that is
routinely missed on hand-written routes.

## When to use this skill

- The user wants DSH to run on CodeBuddy/WorkBuddy subscription quota.
- A hand-declared DSH route fails to authenticate, returns 400/404/504, or
  streams but never answers.
- **Pasted images are rejected** on such a route (often surfaced as
  `UNSUPPORTED_CONTENT`, `does not support image input`).

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
          input: [text, image]     # see Step 3 — do not omit on a vision model
        - id: deepseek-v4-flash
          name: DeepSeek V4 Flash
          contextWindow: 131072
          maxTokens: 32768
```

For WorkBuddy, keep the structure identical and change only `baseURL`, the
route key, and the credential name to match that gateway. Everything else
(`api`, `compat`, `input` handling) is the same adapter behavior.

Settings are re-read **per request**, so edits take effect on the next turn with
no restart.

## Step 3 — declare image support (the commonly missed step)

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
| `400` with an **empty** body | Usually this same non-stream rejection; the body is only readable on some clients | Retry with streaming before assuming an auth problem. |
| `404 {"error_msg":"404 Route Not Found"}` | Wrong path | Endpoint is `https://www.codebuddy.cn/v2/chat/completions`. `/v1/...` and `/v2/v1/...` do not exist. |
| `504` | Wrong bearer token on the route | Check `.credentials.yaml` — see the Models-page warning in Step 1. |
| Images rejected locally | `input` not declared | Step 3. |

Note the baseURL is used verbatim — the adapter does **not** append
`/v1`. `baseURL: https://www.codebuddy.cn/v2` plus the client's own
`/chat/completions` produces the correct URL.

## Step 4 — verify

1. Confirm the route resolves and streams a text answer.
2. If vision is claimed, paste an image through the DSH UI and confirm the
   model describes it correctly. An attachment that reaches the model arrives
   as a normalized copy under `<DSH_HOME>/attachments/`.

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
