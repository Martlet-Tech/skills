# Skills

Agent skills maintained by [Martlet-Tech](https://github.com/Martlet-Tech).

Each skill is a directory bundle containing a `SKILL.md` with YAML frontmatter
(`name`, `description`, optional `whenToUse`). Drop a bundle into a scanned
skill root and it appears in the agent's catalog.

## Available skills

| Skill | Description |
|---|---|
| [`dsh-configure-codebuddy`](dsh-configure-codebuddy/SKILL.md) | Configure DeepSeek Harness (DSH) to route models through the Tencent CodeBuddy / WorkBuddy subscription gateway — credential, the hand-declared `llm-pi-ai` route, gateway dialect quirks, image input, and choosing a reasoning effort that doesn't starve the answer. |
| [`dsh-configure-codebuddy-lite`](dsh-configure-codebuddy-lite/SKILL.md) | The same route as a speed-read card: one copy-paste config, the five must-haves, and an error→fix table — no measurement tables. |
| [`dsh-publish-to-market`](dsh-publish-to-market/SKILL.md) | List a DSH plugin on the awesome-dsh-plugin marketplace (the list behind dsh-market) — the one-file submission format, the hard eligibility gates (`dsh.bundle` manifest, 1-day repo age, `dsh-plugin` topic), the `screenshots.json` convention, and the reasons submissions actually get sent back. |
| [`esp-idf-release-pack`](esp-idf-release-pack/SKILL.md) | Package an ESP-IDF project into a shippable release — n original flash bins (whatever the partition table produces, not always 3), one merged bin writable from 0x0, a source zip without components, a source zip with components, a patch capturing local ESP-IDF modifications (so the exact same bin can be rebuilt), and a minimal README listing each bin's flash offset plus the IDF patch restore steps. Also reconstructs `IDF_PATH` / `IDF_TOOLS_PATH` / toolchain paths from `build/` when the shell environment is gone. |
| [`esp32p4-dsi-debug`](esp32p4-dsi-debug/SKILL.md) | Debug ESP32-P4 MIPI DSI display faults (diagonal skew, banding, tearing, inverted colours) and TDDI touch panels that never report. Covers the three integer-truncation points in the DSI clock chain, separating timing quantities from rate quantities, using the built-in VPG pattern to bisect the fault domain, reading `INT_ST1` and the bridge FIFO, the BGR byte order the hardware expects, the VFP floor for in-cell touch scanning, and a verified VFP=166 / DPI=30MHz / lane=480 parameter set. |
| [`blackbox-debug-method`](blackbox-debug-method/SKILL.md) | **Reading only — not recommended for agent loading.** A post-mortem of a real P4 DSI fault: six failed hypothesis rounds, the two moves that actually cracked it (single-axis scanning to find a discontinuity; splitting knobs into frozen timing values versus adjustable rates), and the three traps that kept fooling the author (numeric coincidence, ignored anti-correlation, treating an ineffective edit as a refuted hypothesis). Deliberately concrete rather than condensed, because the heuristics lose their boundary conditions when extracted. |
| [`common-facts`](common-facts/SKILL.md) | Background noise rather than instructions: 28 near-truisms (point/line/plane/body, structure decides function, abstractions are lossy, complexity only moves, scale changes nature) that carry no task and ask for no citation — loaded so they colour judgement without ever being mentioned. |
| [`lvgl-cjk-font`](lvgl-cjk-font/SKILL.md) | Make Chinese (CJK) text render correctly in LVGL — why the built-in `lv_font_simsun_*_cjk` fonts show tofu boxes and cap at 16 px, and how to generate a custom `lv_font_conv` bitmap font per design size containing only the characters the UI uses. Ships a `gen_fonts.py` that extracts the character set from string literals and regenerates every size. |
| [`win-electron-startup-repair`](win-electron-startup-repair/SKILL.md) | Diagnose and repair a Windows Electron desktop app that stopped opening after a self-update — the silent-update death loop (startup skips window creation to install a package it can never install), a shared install directory quietly uninstalling the other edition's exe, Appx sparse-package version conflicts, and dead shortcuts. Ships `triage.ps1` that collects install dirs, shortcuts, the updater cache, app logs and the Windows event log in one pass. |

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
