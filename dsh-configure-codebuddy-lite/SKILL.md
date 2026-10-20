---
name: dsh-configure-codebuddy-lite
description: CodeBuddy / WorkBuddy 路由的速查卡：一份能直接抄的 llm-pi-ai 配置 + 五个必须项 + 报错对照表，不含实测数据。
whenToUse: 需要快速加一条到 CodeBuddy/WorkBuddy 的 DSH 路由，或该路由 400/404/504、图片被拒、只思考不出答案，而手边不需要长篇论证时。
---

# CodeBuddy / WorkBuddy 路由速查

完整版（含各项实测数据与推导）见 [`../dsh-configure-codebuddy`](../dsh-configure-codebuddy/SKILL.md)。

`codebuddy` 不在 pi-ai 的目录里，整条 provider 必须手写。
配置：`<DSH_HOME>/settings.yaml`；凭据：`<DSH_HOME>/.credentials.yaml`。
每轮请求都重读，改完不用重启。

## 能直接用的配置

```yaml
agent-default-model:
  provider: codebuddy
  model: deepseek-v4.1-flash
  reasoningEffort: medium

llm-pi-ai:
  providers:
    codebuddy:
      displayName: CodeBuddy
      apiKeyEnv: CODEBUDDY_API_KEY
      api: openai-completions
      # WorkBuddy 换成 https://copilot.tencent.com/v2
      baseURL: https://www.codebuddy.cn/v2
      compat:
        supportsDeveloperRole: false
        maxTokensField: max_tokens
      streamIdleTimeoutMs: 600000
      models:
        - id: deepseek-v4.1-flash
          name: DeepSeek V4.1 Flash
          contextWindow: 512000
          maxTokens: 20000
          input: [text, image]
          reasoningEfforts:
            off:
            minimal: minimal
            low: low
            medium: medium
            high: high
            max: max
```

## 五个必须项，少一个就出问题

1. `supportsDeveloperRole: false` —— 网关拒 `role: developer`，否则 400 空 body。
2. `maxTokensField: max_tokens` —— 发 `max_completion_tokens` 会被静默忽略（200 但不生效）。
3. `maxTokens` 给到 20000 —— 思考和答案共用输出预算，太小就整段思考、正文为空。
4. `input: [text, image]` —— 不写就只能在本地拒图（`UNSUPPORTED_CONTENT`）。
5. `reasoningEfforts` —— 不写则模型被登记成「非推理」，永远不发思考字段。

## 三个别踩

- 别设 `compat.thinkingFormat: deepseek`：该网关忽略 `thinking` 字段，思考会直接消失。
- 只写路由级 `reasoning:`、不写模型级 `reasoningEfforts` → `UNSUPPORTED_REASONING_EFFORT`，请求根本不发。
- 别去 Web 的 Models 页：它会覆写凭据文件（换成 `DEEPSEEK_API_KEY`），之后一路 504。

## 档位怎么选

默认 `medium`；机械改动用 `off`（最快，答案反而最长）。
`high` / `max` 换不来更好的结果，只是每步几分钟 —— 长会话「想很久然后失败」多半出在这里。

## 报错对照

| 现象 | 原因 / 修法 |
|---|---|
| 400 `11101 Non-stream ... not supported` | 必须 `stream: true`（DSH 默认就是，仅 curl 会踩） |
| 404 `Route Not Found` | 路径是 `<host>/v2/chat/completions`；没有 `/models` |
| 504 | bearer 用错（见上面 Models 页那条） |
| `finish_reason: length`、正文为空 | 抬 `maxTokens` 或降档 |
| 图片在本地就被拒 | 补 `input` |
| 选择器里没有档位 | 补 `reasoningEfforts` |

## 凭据

```yaml
version: 1
refs:
  CODEBUDDY_API_KEY: ck_...
```

名字随意，和 `apiKeyEnv` 对上即可。

## 排查用哪看

会话日志 `<DSH_HOME>/sessions/<cwd>/session-*/session.v3.jsonl.zstd` 是多帧 zstd，Node 内置解压只读第一帧（会假装只有 1 行），要用流式读取。
事件类型字段是 `type`；实际发送的配置在 `request/header` → `data.header.config`；助手内容在 `data.message.content`（`data.content` 是空的）。
只有 `reasoning` 块、没有 `text`/`tool-call`，就是「想了但没输出」。
