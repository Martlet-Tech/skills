---
name: dsh-publish-to-market
description: List a DSH plugin on the awesome-dsh-plugin marketplace (the list behind dsh-market) — the one-file submission format, the hard eligibility gates (dsh.bundle manifest, 1-day repo age, dsh-plugin topic), the screenshots.json convention, and the reasons submissions actually get sent back.
whenToUse: Use when publishing or listing a DSH plugin in the awesome-dsh-plugin marketplace or dsh-market, when a submission PR was rejected or sent back for changes, when preparing a plugin repo before submitting, or when checking whether a plugin is eligible yet.
---

# Publish a DSH plugin to the marketplace

The marketplace has two halves: [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
is the **list** (data + generated READMEs), and
[dsh-market](https://github.com/dsh-market/dsh-market) is the in-app **storefront**
that reads it. Getting listed is one PR adding **one YAML file**. Nothing else.

## The submission is one file

`data/plugins/<owner>__<repo>.yml` — open a PR that adds exactly that, nothing else:

```yaml
url: https://github.com/owner/repo        # must match the repo exactly
name: owner/repo                          # link text shown in the list
category: ui                              # see the category list below
description:
  en: 'One-line description ending with a period.'
  zh: '一句话描述，以句号结尾。'              # optional — a maintainer will add it
```

- **Only `description.en` is required.** A missing `zh` is the maintainer's work, not
  a reason to bounce you.
- **A description containing `: `** (colon+space) **must be quoted**, or YAML reads it
  as a nested key. Chinese full-width `：` has no such problem.
- The filename rule: `<owner>__<repo>.yml`. Monorepo subpackages get
  `owner__repo--packages-my-plugin.yml` with `url` pointing at the subdirectory and
  `name` as `owner/repo#subname`.

**Do not hand-edit the READMEs.** They are generated from `data/plugins/*.yml` by
`scripts/generate-readme.mjs` and regenerated on `main` automatically after merge.
Separate files never collide, which is the entire reason for the one-file-per-plugin
rule. Confirmed in practice: a `github-actions[bot]` commit
`chore: regenerate READMEs from data/plugins` landed **11 seconds** after the merge.

## Eligibility gates — check these before opening the PR

| Gate | Requirement | Notes |
|---|---|---|
| **`dsh.bundle` manifest** | `package.json` declares `dsh.bundle` | The #1 rejection cause. `dsh.client` alone is **not** installable. |
| **Repo age** | created ≥ **1 day** ago | Checked automatically by CI. |
| **Real code** | Working code, not a placeholder/squat/README-only repo | |
| **`dsh-plugin` topic** | Set on the repo | |
| **Accurate description** | Every claim verifiable in the code | Overstating is the other big rejection cause. |
| **Category** | Closest match | A near miss is fixed by a maintainer, never bounced. |
| **Not a meta-package** | Must ship its own behaviour | A bundle that is only a dependency list isn't listed — list the plugins, not the bundle. |
| **Upstream deps** | Dependencies resolve to the original author's repo/npm | Re-uploading others' plugins under your own account is not listed. |
| **Maintained** | Periodic decay scan removes gone/archived/dormant repos | |

The complete manifest example:

```jsonc
{
  "dsh": {
    "bundle": { "patch": "./cordis.patch.yml" },   // ← required
    "client": { "platform": "web" }                // only if you ship browser UI
  }
}
```

with `cordis.patch.yml` at the repo root:

```yaml
- insert:
    - id: your-plugin-id
      name: your-package-name
```

**Check the age gate as a fact, not a guess** — the local clone's first-commit date is
not the repo creation time:

```bash
curl -s https://api.github.com/repos/<owner>/<repo> | grep created_at
```

CI reads this same field, so a submission that is hours short fails no matter what
the commit history says.

### Categories

`agi` `ui` `usage` `theme` `model` `identity` `session` `memory` `tools` `wsl`
`browser` `vision` `voice` `docs` `skill` `workflow` `git` `notify` `dev`
`security` `remote` `market` `fun`

The set is not fixed — categories split as they grow. Pick the closest and don't
agonise; re-filing later is maintenance, not a correction of your judgement.

## Screenshots — declare them in *your own* repo

Add `screenshots.json` next to your `package.json` (in the subdirectory, for a
monorepo entry), listing 1–8 image paths:

```jsonc
// <your repo>/screenshots.json
[
 "screenshots/1.png"
]
```

`{"screenshots": [...]}` works too.

- Paths are relative to that file and may not escape the plugin directory
  (no leading `/`, no `..`).
- Absolute URLs must be **https on GitHub hosting** (`raw.githubusercontent.com`,
  `user-images.githubusercontent.com`, `camo.githubusercontent.com`, `github.com`
  attachments). Third-party image hosts are rejected for privacy reasons.
- **Do not add keys to the list repo's legacy `data/screenshots.json`** — that file is
  a fallback with an end date.
- Declaring nothing is allowed: storefronts fall back to extracting images from your
  README. Declaring gains you control over order and selection.

Why in your repo: you can change screenshots by pushing to your own repo, with no PR
and no waiting. A relative path breaks visibly if you rename the file; an absolute URL
written into the list repo can only rot silently — that is how 41 of 773 published
screenshots became 404s.

## npm (optional)

Publishing to npm lets storefronts show and sort by download count. Listing is
unaffected either way.

- The published package's `repository` field **must point back at the listed repo**,
  or the two are not linked. This deliberately stops a package from attaching itself
  to a repo that hasn't claimed it.
- **Do not add an `npm:` key to your entry** — the mapping is picked up from the
  registry automatically and a hand-written key is rejected.

## Prebuilt installs avoid the build-approval step

pnpm ≥ 10 blocks dependency `prepare` scripts. If your plugin ships a build step, users
hitting the git-dependency path need an `allowBuilds:` entry in their profile
`pnpm-workspace.yaml`. **Committing a prebuilt `lib/`** (so the package needs no
`prepare` script) sidesteps this entirely — worth doing before submitting, and worth
mentioning in the PR body as a verified fact.

Alternative if you can't install from source at all: attach a prebuilt tarball to a
GitHub Release and point at it with an optional `tarball:` field:

```yaml
tarball: https://github.com/owner/repo/releases/latest/download/your-plugin.tgz
# or pinned to a tag, where a versioned filename is fine:
tarball: https://github.com/owner/repo/releases/download/v1.2.0/your-plugin-1.2.0.tgz
```

⚠️ `latest/download/` resolves `latest` at request time but takes the **filename
literally**. A versioned asset name works the day you submit and 404s the moment you
cut the next release. Keep the asset name version-free, or pin the tag.

## `peerDependencies`, not `dependencies`, for official packages

Declare official `@deepseek-ai/*` packages as `peerDependencies`.

⚠️ **A peer range without an explicit prerelease branch silently excludes every
prerelease build of the harness.** node-semver only lets a version's prerelease tag
satisfy a range if *some* comparator shares its exact `major.minor.patch` tuple and
itself carries a prerelease tag. So `>=0.0.1-rc.1 <0.2.0` — and even the
"match everything" `>=0.0.0-0 <0.2.0-0` — does **not** match `0.1.0-rc.6`, and users
hit an `ERESOLVE` they must work around by hand.

```jsonc
// ❌ looks broad, silently excludes every 0.1.0-* prerelease
"peerDependencies": { "@deepseek-ai/dsh-tools": ">=0.0.1-rc.1 <0.2.0" }

// ✅ explicit prerelease branch on the 0.1.0 tuple
"peerDependencies": { "@deepseek-ai/dsh-tools": ">=0.0.1-rc.1 <0.1.0 || >=0.1.0-rc.1 <0.2.0-0" }
```

## Write the PR body as a claims checklist

A maintainer reads the target repo and checks every claim. State the checks you ran as
facts, so the review has nothing to catch:

```markdown
Adds one entry: `owner/repo`, category `ui`.

- `dsh.bundle` is declared in `package.json` (not just `dsh.client`).
- Repo age is over 1 day (`created_at` 2026-01-01T00:00:00Z).
- The `dsh-plugin` topic is set.
- `lib/` is committed, so a GitHub install needs no `prepare` script or `allowBuilds`.
- `screenshots.json` is declared next to `package.json` with one real screenshot.
- Every claim in the description is checked against the code: <name the file>.
- Only one file added — no existing entry is touched.
```

**Hard rules for the PR itself:**

- **At most 3 entries per PR.** Over that CI rejects and asks you to split. Send the
  ones you'd keep if you could only keep a few, not everything that works.
- **Touch only your own entry.** A PR updating one plugin must not rewrite another's
  description. The gate now lists every existing entry a PR modifies.

## What CI checks, in order

1. **Entry count** — ≤ 3, checked first, before any network fetch.
2. **`dsh.bundle`** — fetched from your repo's `package.json` (root, or a
   `packages/` · `plugins/` · `apps/` subpackage). `dsh.client` alone fails here.
3. **Repo age** — the 1-day bar.
4. **`awesome-lint`** and the site build — locale parity, separators, dates, screenshots.

A green CI run is the **precondition, not the decision** — it verifies the submission's
shape and cannot tell whether the plugin does what its entry says. A maintainer reads
the repo before merging.

**If a check fails, it says exactly what to change. Push a fix to the same branch — do
not open a new PR.**

## What actually gets submissions sent back

1. **Inaccurate description.** Read as a claim about your plugin and checked against
   the code. Claim "46 tools across six domains" and there had better be 46 tools and
   six domains. This is the top reason an otherwise-good plugin is bounced.
2. **Only `dsh.client` declared.** Not installable; see the manifest block.
3. **Repo younger than a day.** Automatic, no judgement implied — finish the work and
   resubmit; nothing is held against a resubmission.
4. **A meta-package** (dependency list only), or **dependencies re-uploaded** under
   your own account instead of pointing at upstream.
5. **A PR that edits someone else's entry** or hand-edits the READMEs.

## Themes specifically

Entries in **Themes & Appearance** (`theme`) automatically appear in dsh-market's
dedicated **Themes tab**, where users install, switch and uninstall with one click. Put
themes there, **not** under UI Enhancements.

## Timeline, as observed

Real numbers from a successful submission, useful for setting expectations:

| Event | Time |
|---|---|
| Repo created | T+0 |
| `screenshots.json` commit pushed | T+26.5 h |
| PR opened | T+26.6 h (gates satisfied) |
| CI `PR check` green | +8 min |
| Merged by maintainer (squash) | +1 h 46 min |
| READMEs auto-regenerated | +11 s after merge |

It took **zero review comments** — the review cost is entirely front-loaded into getting
the eligibility facts true and the description accurate.

## Verify your listing

```bash
# entry file on main
curl -s https://raw.githubusercontent.com/awesome-dsh-plugin/awesome-dsh-plugin/main/data/plugins/<owner>__<repo>.yml

# merge state (merged: true, merge_commit_sha)
curl -s https://api.github.com/repos/awesome-dsh-plugin/awesome-dsh-plugin/pulls/<number>

# was the PR check green?
curl -s 'https://api.github.com/repos/awesome-dsh-plugin/awesome-dsh-plugin/actions/runs?head_sha=<head-sha>'
```

The README is a multi-megabyte file with thousands of entries; a plain fetch may
truncate before reaching your section. Grep the raw file, or trust the entry file and
the regenerate-bot commit instead of eyeballing the README.

## Etiquette worth knowing

- A listing is **not permanent**: repos that go away, stop being maintained, or turn
  out broken get removed. A fork *is* added when it's the better-kept one or genuinely
  adds something — the rule is whichever is better, not first-come.
- **Being listed is not a security review.** The list says so plainly; review a
  plugin's source before installing it.
- Maintainers also add notable plugins directly, so the list grows by curation as well
  as by PR.
- PRs fixing descriptions, moving entries between categories, or removing dead projects
  are equally welcome.
