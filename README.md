# Skills

Agent skills maintained by [Martlet-Tech](https://github.com/Martlet-Tech).

Each skill is a directory bundle containing a `SKILL.md` with YAML frontmatter
(`name`, `description`, optional `whenToUse`). Drop a bundle into a scanned
skill root and it appears in the agent's catalog.

## Available skills

| Skill | Description |
|---|---|
| [`dsh-configure-codebuddy`](dsh-configure-codebuddy/SKILL.md) | Configure DeepSeek Harness (DSH) to route models through the Tencent CodeBuddy / WorkBuddy subscription gateway — credentials, the hand-declared `llm-pi-ai` route, gateway dialect quirks, enabling image input, and making reasoning effort take effect. |

## Install

Copy or symlink a skill directory into any root DSH scans:

| Root | Path |
|---|---|
| Project (DSH) | `<project>/.dsh/skills` |
| Project (agents) | `<project>/.agents/skills` |
| User (DSH) | `<DSH_HOME>/skills` (default `~/.dsh/skills`) |
| User (agents) | `~/.agents/skills` |

Or install from this repository:

```bash
npx skills add Martlet-Tech/skills@dsh-configure-codebuddy -g -y
```

## Adding a skill

Create `<skill-name>/SKILL.md`:

```markdown
---
name: my-skill
description: One sentence stating what this does and when to use it.
---

# My Skill

Instructions...
```

`name` must be kebab-case and match the directory name.
