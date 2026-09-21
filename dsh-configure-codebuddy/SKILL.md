---
name: dsh-configure-codebuddy
description: Configure DeepSeek Harness (DSH) to route models through the Tencent CodeBuddy / WorkBuddy subscription gateway — credential, the hand-declared llm-pi-ai route, the gateway dialect quirks, image input, and the reasoning-effort/output-budget trap that makes a session burn minutes and then produce no answer or tool call at all.
whenToUse: Use when adding or repairing a hand-declared DSH provider route to CodeBuddy/WorkBuddy, when such a route 400s / 404s / 504s, when pasted images are rejected with UNSUPPORTED_CONTENT, when the route never thinks, or when it thinks so long that the answer or the tool call never arrives and tasks keep failing.
---

# Route DSH through CodeBuddy / WorkBuddy

`codebuddy` is not in pi-ai's installed catalog, so the entire provider must be
declared by hand under `llm-pi-ai`. Settings: `<DSH_HOME>/settings.yaml`
(default `~/.dsh/settings.yaml`). Credentials: `<DSH_HOME>/.credentials.yaml`.
Settings are re-read per request, so an edit lands on the next turn with no restart.

## Working configuration

Everything below the surface is in this block; the rest of the file says why.

```yaml
agent-default-model:
  provider: codebuddy
  model: deepseek-v4.1-flash
  reasoningEffort: medium          # NOT high — see "Pick the effort level"

llm-pi-ai:
  providers:
    codebuddy:
      displayName: CodeBuddy
      apiKeyEnv: CODEBUDDY_API_KEY
      api: openai-completions
      baseURL: https://www.codebuddy.cn/v2
      compat:
        supportsDeveloperRole: false   # 1 — gateway rejects `role: developer`
        maxTokensField: max_tokens     # 2 — or `maxTokens` is silently ignored
      streamIdleTimeoutMs: 600000      # a thinking turn holds one stream for minutes
      models:
        - id: deepseek-v4.1-flash
          name: DeepSeek V4.1 Flash
          contextWindow: 512000
          maxTokens: 20000             # 3 — must clear the thinking phase
          input: [text, image]         # 4 — or images are rejected locally
          reasoningEfforts:            # 5 — omit and the model never thinks
            off:
            minimal: minimal
            low: low
            medium: medium
            high: high
            max: max
```

`baseURL` is host-specific and used **verbatim** — the adapter does not append
`/v1`. Both rows were confirmed to answer with the same `ck_…` key:

| Gateway | baseURL |
|---|---|
| CodeBuddy (public) | `https://www.codebuddy.cn/v2` |
| WorkBuddy | `https://copilot.tencent.com/v2` |

## 1 — `supportsDeveloperRole: false`

pi-ai sends the system prompt with `role: "developer"` **only** to a reasoning
model, and this gateway rejects that role. pi-ai's `detectCompat()` defaults
`supportsDeveloperRole` to `true` for any route outside its known-gateway list
(Cerebras, xAI, DeepSeek, z.ai, Moonshot, Nvidia, Together, Ant Ling, Cloudflare,
opencode, OpenRouter) — CodeBuddy is not on that list, so the override is
mandatory rather than optional.

## 2 — `maxTokensField: max_tokens`

This is the quiet one: **the gateway accepts `max_completion_tokens` with a 200
and silently ignores it.** Measured on the same prompt, reasoning on, cap 900:

| field sent | completion_tokens | finish_reason |
|---|---|---|
| `max_tokens: 900` | 900 | `length` |
| `max_completion_tokens: 900` | 13,266 | `stop` |
| neither | 21,015 | `stop` |

`detectCompat()` resolves `maxTokensField` to `max_completion_tokens` for this
route, so without this override any `maxTokens:` you write is decorative.

## 3 — `maxTokens` must clear the thinking phase

**Thinking and the answer/tool-call share the same output budget.** If the cap is
smaller than the thinking phase wants, the whole response is thinking and the
content comes back empty — `finish_reason: length`, no answer, no tool call.
pi-ai says so in its own source (`api/openai-completions.js`): *an uncapped
reasoning phase can consume the whole response and leave no answer and no tool
call.* Same prompt, `reasoning_effort: high`:

| max_tokens | thinking tokens | answer chars | finish_reason |
|---|---|---|---|
| 1,200 | 1,198 | **0** | `length` |
| 6,000 | 5,999 | **0** | `length` |
| 20,000 | 12,221 | 7,050 | `stop` |

`20000` leaves room at every level on ordinary coding prompts. Raise it if
answers come back truncated; it is a ceiling, not a throttle.

## 4 — `input` / `defaultInput` for images

Without it the model is text-only (`DEFAULT_INPUT = ["text"]`) and DSH refuses
the image *before sending it*, as `UNSUPPORTED_CONTENT` /
`does not support image input`. That rejection is local config, not a gateway
limit. `defaultInput: [text, image]` on the route is a **fallback** — a model
entry that already declares `input` keeps its own value.

## 5 — `reasoningEfforts`, and picking the effort level

Omit `reasoningEfforts` on a hand-declared model and pi-ai's
`resolveModelReasoning()` takes `base?.reasoning ?? false`; `base` is undefined
for a route outside the catalog, so the model is registered as **non-reasoning**,
`reasoningInfo()` returns `{}`, the picker shows no effort entry, and **no
thinking field is ever sent**.

The seven level names are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`,
`max`; the six in the block above were all measured against this gateway
(`xhigh` was not). The key is what the picker offers, the value is what goes on
the wire (`max: xhigh` renames a level for a gateway with its own vocabulary).
Only `off` may be left valueless, and valueless `off` means "send nothing" —
measured as **zero** thinking on this gateway, not "let the gateway decide".

**The gateway accepts `minimal` / `low` / `medium` too — declaring only
`off`/`high`/`max` throws away the useful middle.** All levels measured on one
prompt, `max_tokens: 20000`:

| effort | thinking tokens | thinking chars | answer chars | wall |
|---|---|---|---|---|
| off (send nothing) | 0 | 0 | 10,374 | 13.0 s |
| minimal | 7,948 | 22,161 | 5,358 | 35.9 s |
| low | 7,805 | 22,146 | 6,596 | 35.2 s |
| **medium** | 12,963 | 34,357 | 8,979 | 56.5 s |
| high | 12,221 | 42,570 | 7,050 | 51.5 s |
| max | 15,024 | 54,289 | 6,761 | 61.7 s |

**`reasoningEffort: medium` (`low` on cheap turns) is the default to ship.**
`high`/`max` buy no better final answer here but take minutes per step, and on a
long agentic session that is where "it thinks forever and then fails" comes from:
a real session on this route with `high` produced **2.48 M characters of thinking
over 698 assistant messages** (single block: 112,070 chars), **3 steps that
emitted thinking and no output at all**, and 4 stream `TRANSPORT` errors. The
same project without a declared effort: 907 messages, zero reasoning blocks,
zero dead steps.

`off` is worth trying for mechanical edits — it was both the fastest and, in the
measurement above, the one that produced the longest answer.

### Two ways the effort wiring misfires

- **Route-level `reasoning:` with no model-level `reasoningEfforts`.** The model
  stays non-reasoning and every request fails locally with
  `UNSUPPORTED_REASONING_EFFORT`. The field itself is valid, so nothing rejects
  it at write time.
- **`compat.thinkingFormat: deepseek` on this route.** Do not set it. It makes
  pi-ai send `thinking: {type: enabled}` *instead of* `reasoning_effort`, and
  **this gateway ignores the `thinking` field entirely** — measured:
  `thinking: {type: enabled}` on its own returns 0 reasoning tokens, while
  `reasoning_effort: medium` on its own returns 102. With it set, thinking stops
  and every level collapses to the same request.

## Credential

```yaml
version: 1
refs:
  CODEBUDDY_API_KEY: ck_xxxxxxxxxxxx.xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The name is arbitrary; it only has to match `apiKeyEnv`.

> **Observed failure:** DSH's web **Models** page writes back to
> `.credentials.yaml` and has been seen overwriting `CODEBUDDY_API_KEY` with
> `DEEPSEEK_API_KEY`, sending the wrong bearer token and failing with **504**.
> If the route breaks right after visiting that page, look here first.

## Gateway quirks (verified)

| Symptom | Cause | Fix |
|---|---|---|
| `400 {"code":11101,"msg":"Non-stream chat request is currently not supported"}` | Gateway requires streaming | Send `"stream": true`. DSH always streams; this only bites hand-rolled curl/python. |
| `404 {"error_msg":"404 Route Not Found"}` | Wrong path | The endpoint is `https://<host>/v2/chat/completions`. `/v1/...`, `/v2/v1/...`, and any `/models` listing do not exist. |
| `504` | Wrong bearer token | See the Models-page warning above. |
| `400` with an **empty** body, starting the moment reasoning is declared, and persisting with no effort selected | Reasoning models get `role: "developer"`; the gateway rejects it | `compat.supportsDeveloperRole: false`. The tell is that it survives selecting no effort — it is the request shape, not the effort value. |
| Answer **or** tool call never arrives: `finish_reason: length` with empty content | Thinking shares the output budget and the cap is smaller than the thinking phase wants | Raise `maxTokens`, and/or drop to a lower effort — §3 |
| No thinking at all, though a level is selected | Either the model declares no `reasoningEfforts` (no field is sent at all), or `compat.thinkingFormat` is `deepseek` and the gateway is ignoring `thinking` | §5 |
| `maxTokens` has no effect | Sent as `max_completion_tokens` | `compat.maxTokensField: max_tokens` |
| Long thinking turns die mid-stream | One stream held open for minutes | `streamIdleTimeoutMs: 600000`. |
| Images rejected locally | `input` not declared | `input` / `defaultInput`. |
| No effort entry in the picker | Hand-declared model with no `reasoningEfforts` | Declare them. |
| `UNSUPPORTED_REASONING_EFFORT`, nothing sent | Route-level `reasoning:` without model-level `reasoningEfforts` | Declare the levels too. |

Reasoning is delivered as `choices[].delta.reasoning_content` (pi-ai also reads
`reasoning` and `reasoning_text`).

## Verify from the session log, not by feel

`<DSH_HOME>/sessions/<cwd>/session-*/session.v3.jsonl.zstd` is **multi-frame**
zstd — Node's `zlib.zstdDecompressSync` reads only the first frame and reports a
fake `lines=1`, so use a streaming reader (`python -m pip install zstandard`).
Field names, which are easy to get wrong:

- the event kind is `type` (not `kind`);
- `request/header` → `data.header.config` holds what was actually sent
  (`{provider, model, reasoningEffort?, maxTokens?}`);
- an assistant message's blocks are under **`data.message.content`** —
  `data.content` is empty, and reading only that makes a thinking session look
  like a non-thinking one. `content[].type` is `reasoning` / `text` / `tool-call`.

A block set of `("reasoning",)` alone means the step thought and produced
nothing — count those first when a task "keeps failing".

## Verify with curl / python

```bash
# stream:true is mandatory; host = the baseURL from the table above.
curl -sS https://www.codebuddy.cn/v2/chat/completions \
  -H "Authorization: Bearer $CODEBUDDY_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","stream":true,"max_tokens":20000,
       "reasoning_effort":"medium",
       "messages":[{"role":"user","content":"用一句话说明什么是死锁。"}]}'
```

To check image reading, send a solid-colour PNG and ask for the colour, with a
control that asks about an image when none was attached — a correct model says it
sees none. (Never use "what colour is the sky" as the control; it answers
"blue" with no image attached.) Attachments that reach the model appear under
`<DSH_HOME>/attachments/`.

## Route fields that bite

- **`api` is mandatory** for a provider pi-ai does not ship; omitting it fails to resolve.
- **`provider` is not a route field** — it is the `providers` dict key. Setting it inside an entry is rejected.
- **`maxRetries` / `maxRetryDelayMs` were removed** from this namespace; compose recovery with `dsh-llm-retry`.
- **Provider ids are lowercase hyphenated.** A key outside that grammar cannot address a stored credential record, so such routes must use `apiKeyEnv`.
- **A refused section keeps the namespace's last good value**, so a malformed edit can look like a no-op. Look for `keeping the previously registered routes` in the log.
- **`llm-deepseek` is not a drop-in alternative.** It brings its own `off`/`low`/`high`/`max` and defaults `reasoningEffort` to `high`, and its `baseURL` must be a **base** — writing `https://<host>/v1/chat/completions` there fails every request (seen as `HTTP 403 AUTH`); drop the path.
