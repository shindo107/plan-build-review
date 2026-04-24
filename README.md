# plan-build-review

> A Claude Code skill that wraps a rigorous **plan → build → review** workflow around any implementation task. Replaces the "paste the same planning prompt every time" pattern with one command.

Rigorous plan→build→review workflow. Progressive clarification, parallel subagent exploration, adversarial Opus+Sonnet review with user-selected scopes, then commit/push/deploy/worktree finishing.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Who it's for](#who-its-for)
- [Quick start](#quick-start)
- [Install](#install)
- [Invocation & arguments](#invocation--arguments)
- [Workflow walkthrough](#workflow-walkthrough)
- [Progressive disclosure: the clarification tiers](#progressive-disclosure-the-clarification-tiers)
- [The adversarial review pair](#the-adversarial-review-pair)
- [Review scopes](#review-scopes)
- [Review-loop termination strategies](#review-loop-termination-strategies)
- [Estimating token cost](#estimating-token-cost)
- [Deploy command resolution](#deploy-command-resolution)
- [Worktree lifecycle](#worktree-lifecycle)
- [Repo layout](#repo-layout)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
- [Extending & customizing](#extending--customizing)
- [Contributing](#contributing)
- [License](#license)

---

## Why this exists

Most real implementation work in Claude Code benefits from the same rough sequence: understand the problem, plan the approach, execute, check the work, and ship. In practice, users paste long "please plan this carefully and review it at the end" prompts into every session because there's no built-in way to encode that discipline once. The prompts drift, the steps get dropped, and the quality varies by how awake you were when you typed it.

`plan-build-review` is that discipline, codified into a single skill. It runs the same rigorous sequence every time — with progressive clarification so it doesn't over-ask on simple tasks, parallel subagent exploration so it's fast, and an adversarial two-model review gate at the end so shipping-grade quality isn't dependent on the main thread noticing its own mistakes.

The core premise: **two independent reviewers running in parallel, on different models, with scopes you assigned at plan time, catch issues neither the main thread nor any single reviewer would surface alone.**

## Who it's for

- Claude Code users who've internalized that the best output comes from a **plan → build → review** loop, and want that loop to happen automatically rather than by remembering to ask for it.
- Engineers working in complex codebases where "just do it" often produces subtly wrong code that passes type checks but violates invariants the main thread couldn't see.
- Teams who want a consistent review bar across projects without having to train everyone on the same custom prompt.
- Anyone who wants the safety of plan-then-implement without the friction of manually driving every phase.

Not ideal for: trivial one-line fixes, pure refactors with no behavioral change, interactive debugging sessions, or rapid prototyping where you're iterating on design in real time. For those, standard Claude Code without the skill is the right tool.

## Quick start

```bash
# Clone and symlink (local dev install)
git clone https://github.com/shindo107/plan-build-review ~/ai-tools/plan-build-review
mkdir -p ~/.claude/skills
ln -s ~/ai-tools/plan-build-review/plugins/plan-build-review/skills/plan-build-review ~/.claude/skills/plan-build-review
```

In any Claude Code session:

```
/plan-build-review push worktree
```

Then describe what you want built. The skill takes it from there.

## Install

Two install paths depending on whether you're a consumer or a contributor.

### As a plugin (recommended for most users)

```
/plugin marketplace add https://github.com/shindo107/plan-build-review
/plugin install plan-build-review@darren-ai-tools
```

Invoke as `/plan-build-review:plan-build-review`.

> **Note on invocation syntax**: Plugin skills are namespaced as `plugin:skill`. Because both the plugin and the skill are named `plan-build-review`, the fully-qualified invocation reads twice. If that's awkward, the local-dev install below lets you invoke it as plain `/plan-build-review`.

### Local dev install (edit the skill in place)

Clone the repo and symlink the skill directory into Claude Code's global skills path:

```bash
git clone https://github.com/shindo107/plan-build-review ~/ai-tools/plan-build-review
mkdir -p ~/.claude/skills
ln -s ~/ai-tools/plan-build-review/plugins/plan-build-review/skills/plan-build-review ~/.claude/skills/plan-build-review
```

Invoke as `/plan-build-review`. Edits to files in `~/ai-tools/plan-build-review/` take effect immediately — no reinstall or restart.

## Invocation & arguments

`/plan-build-review [commit|push|deploy] [worktree]`

All args are position-insensitive and case-insensitive. A git-action token and the `worktree` flag compose freely.

| Arg | Effect |
|---|---|
| *(none)* | commit only — equivalent to explicit `commit` |
| `commit` | Commit after review passes. No push, no deploy. |
| `push` | Commit + push to the current branch's upstream (sets upstream on first push). |
| `deploy` | Commit + push + deploy. **Runs deploy with no confirmation prompt** — configure a deploy command first (see [Deploy command resolution](#deploy-command-resolution)). |
| `worktree` | Work happens in a fresh git worktree at `.worktrees/<slug>/` on a new branch. After the git action succeeds, prompts whether to merge back to the default branch. Orthogonal — composes with any git action. |

### Example invocations

| Command | What happens |
|---|---|
| `/plan-build-review` | Plan, build, review, commit in place |
| `/plan-build-review commit` | Same as above (explicit) |
| `/plan-build-review push` | Plan, build, review, commit, push |
| `/plan-build-review deploy` | Plan, build, review, commit, push, deploy (no confirmation) |
| `/plan-build-review worktree` | Work in `.worktrees/<slug>/`, commit, prompt-to-merge |
| `/plan-build-review push worktree` | Worktree + push; then prompt-to-merge |
| `/plan-build-review deploy worktree` | Worktree + full deploy pipeline; then prompt-to-merge |

## Workflow walkthrough

Eleven phases. Each one exists because the one before it leaves something underspecified or unverified that the next one relies on. Skipping phases collapses the rigor.

### Phase 0 — Parse arguments

First thing the skill does: read `$ARGUMENTS`, identify which git-action mode you chose, and whether `worktree` is set. Emits a one-line confirmation before anything destructive so you can course-correct.

### Phase 1 — Enter plan mode

Calls `EnterPlanMode`. From here until the plan is approved, the skill is read-only. Records the plan file path from plan mode's system reminder for later phases.

### Phase 2 — Progressive-disclosure clarification

Asks one tier of questions at a time, only descending when prior-tier answers leave something load-bearing ambiguous. See [Progressive disclosure](#progressive-disclosure-the-clarification-tiers).

### Phase 2.5 — Worktree setup (conditional)

Runs only if you used the `worktree` arg. Happens after Tier-1 intent clarification so the branch slug can be derived from a confirmed task description instead of invented from a possibly-vague one-liner. Uses the `EnterWorktree` tool (not raw `cd`) so working-directory context persists across tool calls.

### Phase 3 — Explore in parallel

Spawns up to 3 `Explore` subagents **in a single message** (parallel, not serial). Each gets a distinct search focus — existing utilities, architectural patterns, test conventions — and returns file paths and short summaries. Often one agent is enough; more only when scope is genuinely uncertain.

### Phase 4 — Design

Spawns a single `Plan` subagent with Phase 1-3 outputs. It drafts the implementation approach. The main thread reviews, writes the final plan (recommended approach only, not alternatives) to the plan file, then calls `ExitPlanMode` — which surfaces the plan and blocks until you approve.

### Phase 5 — Implement

Breaks the plan into discrete tracked tasks. Delegates independent work to general-purpose subagents in parallel where that actually saves wall time (not for trivial edits — handoff has overhead). Runs linters and tests as it goes, not only at the end.

### Phase 6 — Adversarial review

The core differentiator. Three sub-steps:

- **6a.** Establishes the diff against the correct base (worktree → `git diff main...HEAD`; in-place-with-commits → against recorded base SHA; in-place-with-nothing-committed → `git diff HEAD`). Large diffs go to a temp file rather than being inlined in the prompt.
- **6b.** Synthesizes 1–2 dynamic scope suggestions specific to what the diff actually touches, then asks you to assign scopes per reviewer (multi-select).
- **6c.** Spawns both reviewers in parallel in a single message: one `general-purpose` agent with `model: opus`, one with `model: sonnet`. Each gets the diff, the plan path, their assigned scopes, and the severity rubric.

### Phase 7 — Synthesize findings and apply fixes

Merges both reports, de-duplicates, resolves conflicts (prefer the finding with a concrete file:line and concrete fix). Applies fixes per the termination strategy you chose in Phase 2.

### Phase 8 — Commit

Specific file staging only — never `git add .`. Detailed commit message in a loose template: subject, `why`, optional `what`/`non-obvious`, Co-Authored-By trailer. Dirty-tree check before staging — if there are unrelated pending changes, stops and asks before committing.

### Phase 9 — Push

Only if `push` or `deploy`. `git push -u origin <current-branch>` (sets upstream on first push).

### Phase 10 — Deploy

Only if `deploy`. No confirmation. Resolves the deploy command from CLAUDE.md → package.json → Makefile → deploy scripts, in that order. Branch-safety warning if you're not on the default branch (logs but doesn't block).

### Phase 11 — Merge prompt

Only if `worktree`. Asks whether to merge the feature branch back to the default branch now. Yes → exits the worktree, merges with `--no-ff`, pushes, cleans up the worktree and the local branch. No → leaves the worktree intact with resume instructions.

## Progressive disclosure: the clarification tiers

Four tiers of clarification. Not all four are asked every time — the skill skips tiers whose answers are already obvious from prior context.

| Tier | Focus | Always asked? |
|---|---|---|
| **T1 Intent** | Outcome, success criteria, non-goals | ✅ Always |
| **T2 Scope** | Which files/modules, reuse vs. avoid | Only if T1 didn't cover it |
| **T3 Implementation** | Test strategy, backwards-compat, perf/bundle/migration | Only if T1+T2 didn't cover it |
| **T4 Review config** | Review-loop termination strategy | ✅ Always (reviewer-scope picker itself runs in Phase 6b) |

Rule: descend only when the prior tier leaves a load-bearing decision ambiguous. The skill explicitly tries not to over-ask; if your one-line prompt already contains the answers, expect to see a single `AskUserQuestion` call and move on.

## The adversarial review pair

Two reviewers, spawned in parallel in a single message, running on different models with different framing:

**Opus reviewer** (`model: opus`) — the skeptical architectural lens. Looks for:
- Hidden coupling across the codebase
- Abstraction mismatches that will collapse under the next reasonable feature
- Over- or under-engineering
- Invariants that this change silently violates
- Blast radius larger than the diff implies

**Sonnet reviewer** (`model: sonnet`) — the rigorous correctness lens. Looks for:
- Spec match against the approved plan
- Edge cases: empty inputs, boundary values, concurrent calls, error paths
- Regression risk on existing callers' contracts
- Test gaps for newly implemented behavior
- Type correctness, off-by-one, async ordering

Both follow the same severity rubric (`blocker` / `high` / `medium` / `nit`) and return findings in a structured `severity / file:line / issue / fix` format so the main thread can merge deterministically. When both reviewers flag the same issue, that's a strong signal. When they disagree, the one with a citable file:line and concrete fix wins.

If your Claude Code version doesn't support per-invocation model overrides on the `Agent` tool, the skill degrades gracefully: both reviewers run on the default model, adversarial framing preserved, model diversity logged as unavailable.

## Review scopes

Four baseline categories, assigned independently to each reviewer:

- **Correctness, regressions, & test coverage** — does it match the plan, any bugs, edge cases, test gaps
- **Architecture, design, & readability** — right abstraction, coupling, pattern fit, misleading names
- **Security, data integrity, & safety** — auth, validation, tenant isolation, secrets, destructive ops
- **Performance, UX, & accessibility** — hot paths, re-renders, dark-theme, a11y, loading states

Plus **1–2 dynamic scopes** synthesized from what the diff actually touches. Examples from the trigger table:

| If diff touches… | Suggested dynamic scope |
|---|---|
| `drizzle/migrations/` | Migration rollback + forward-compat safety |
| New table with `tenant_id` column | RLS policy correctness |
| `src/app/(app)/**` | Dark-theme + mobile safe-area conformance |
| New API route under `src/app/api/` | Zod validation + tenant-context wrapper |
| React components with hooks | Re-render / effect-dependency correctness |
| `.env*` files | Secrets handling + config surface consistency |
| New `package.json` dependency | Supply-chain risk + license + bundle impact |
| Auth files | Session lifecycle + token storage + CSRF |
| CI config | CI/CD blast radius + secret exposure |
| Large refactor (>10 files) | Abstraction coherence + dead-code sweep |

Full trigger list and rationale: [`references/review-scopes.md`](./plugins/plan-build-review/skills/plan-build-review/references/review-scopes.md).

Reviewers may share scopes — overlap surfaces divergence, which is useful.

## Review-loop termination strategies

Chosen at plan time (Tier 4 of clarification). Three options:

- **Single-pass** — one review, fix `blocker`+`high` items, continue. Predictable cost, no surprises. Best for small changes.
- **Iterate (max 2 rounds)** — after fixes, re-run both reviewers with their round-1 findings + the updated diff. Hard cap at 2 review rounds. If blockers remain, stops and surfaces to user. Roughly 2× review cost; more thorough.
- **User decides after first review** — presents merged findings and asks: fix-and-commit / fix-and-re-review / surface-and-stop. Maximum control at the cost of one more interactive step.

## Estimating token cost

For a diff of `X` tokens (the `+`/`-` lines the main thread produces), a single-pass run roughly costs:

- **Fixed overhead** — ~80–150K tokens. Dominated by the exploration + planning subagents in Phases 3–4.
- **Implementation** — ~6–10 × X. Main thread reads 5–9× more context than it outputs per code token.
- **Review pair** — ~max(25K, 2X + 25K). Each of two reviewers reads the full diff plus ~10K of fixed context.
- **Fix cycle** — ~2–3 × X. Fixes typically touch 20–40% of the original diff plus context re-reads.

### Approximate totals (single-pass mode)

| Diff size (X) | Change size | Review | Fix | **Total** |
|---|---|---|---|---|
| 500 | tiny tweak | ~26K | ~1.5K | **~110K** |
| 2,000 | small feature | ~29K | ~5K | **~140K** |
| 10,000 | medium feature | ~45K | ~25K | **~280K** |
| 50,000 | large refactor | ~125K | ~125K | **~850K** |

### Modifiers

- **`iterate` termination mode** — roughly 2× the review + fix costs (max 2 rounds)
- **`user-decides` termination** — behaves like single-pass on the happy path
- **Tier 3 clarification triggered** — adds ~4K
- **3 Explore subagents instead of 1** — adds ~30K to overhead

### Caveats

These figures are derived from the skill's phase structure and typical Anthropic API patterns — not measured from instrumented runs. Expect ±30–50% variance per invocation. Use as a rough budget sanity check before committing to a large change, not a precise forecast.

## Deploy command resolution

No confirmation prompt. The skill looks up the deploy command in this fixed order:

1. Project `CLAUDE.md` — scanned for a `## Deploy` section or an explicit `deploy command:` line (not a keyword search)
2. `package.json` → `scripts.deploy` → runs `npm run deploy`
3. `Makefile` target `deploy` → runs `make deploy`
4. `./deploy.sh` or `./scripts/deploy.sh` (executable) → runs it
5. **None found** → errors and stops with: `deploy arg used but no deploy command found. Configure a deploy command in CLAUDE.md or add a scripts.deploy entry to package.json.`

The skill does **not** guess. If you want a deploy integration, configure one of the above paths.

**Branch-safety guard**: if the current branch isn't the project's main deploy branch (typically `main`), the skill emits a one-line warning but still proceeds — per the "no-prompt" design. The log is preserved for auditability.

## Worktree lifecycle

Only active when the `worktree` arg is present.

1. **Branch slug**: 2–3 descriptive words from Tier 1 intent, lowercased, kebab-case, stripped of non-`[a-z0-9-]`, plus today's ISO date. Prefix by task type: `feat/` (default), `fix/` (bug), `chore/` (infra). Example: `feat/leaderboard-refactor-2026-04-24`.
2. **If intent is too vague** (fewer than 2 meaningful tokens), the skill asks a single question: "What should I name this branch?"
3. **Preflight**: verifies the current directory is inside a git repo.
4. **Records** the original repo root — Phase 11 uses this to merge back.
5. **Creates** the worktree at `.worktrees/<slug>/` on a new branch using the `EnterWorktree` tool. (Raw `cd` would lose working-directory context across tool calls.)
6. **All subsequent phases** run inside the worktree.
7. **Phase 11** asks whether to merge. Yes → exits the worktree, `git merge --no-ff <branch>`, `git push`, `git worktree remove`, `git branch -d`. No → leaves the worktree intact and prints resume instructions.

## Repo layout

```
plan-build-review/                                          # repo root = marketplace
├── .claude-plugin/
│   └── marketplace.json                                    # lists the plugin
├── plugins/
│   └── plan-build-review/                                  # plugin root
│       ├── .claude-plugin/
│       │   └── plugin.json                                 # plugin manifest
│       └── skills/
│           └── plan-build-review/
│               ├── SKILL.md                                # main workflow (~175 lines)
│               └── references/
│                   ├── progressive-disclosure.md           # clarification tier catalog
│                   ├── review-scopes.md                    # baseline scopes + dynamic triggers
│                   └── adversarial-pair.md                 # reviewer briefing templates
├── README.md                                               # this file
├── LICENSE                                                 # MIT
└── .gitignore
```

Architectural note: `SKILL.md` stays under ~300 lines so it loads quickly into context. Detailed content lives in `references/` and is read on-demand by Claude when the relevant phase needs it. This is progressive disclosure applied to the skill itself.

## Requirements

- **Claude Code** — any recent version. Some features depend on specific tools:
  - `Agent` tool with `model` parameter support (for adversarial model diversity) — degrades gracefully if unavailable
  - `EnterWorktree` / `ExitWorktree` tools (for worktree mode) — loaded via `ToolSearch` if deferred
  - `EnterPlanMode` / `ExitPlanMode` (for plan-mode phases) — built-in in recent versions
  - `AskUserQuestion` (for clarification phases) — built-in
  - A task-tracking tool (`TaskCreate`/`TaskUpdate`/`TaskList` or equivalent) — used in Phase 5
- **Git** — required for all git-action modes and for worktree lifecycle
- **A deploy command** — only if you use the `deploy` arg (see [Deploy command resolution](#deploy-command-resolution))

No other dependencies. The skill itself is pure markdown — no runtime, no npm install, no build step.

## Troubleshooting

**"Skill not found" after install**
- Plugin install: try `/plugin list` to confirm it's present. Expected invocation is `/plan-build-review:plan-build-review`.
- Local dev install: verify the symlink with `ls -la ~/.claude/skills/plan-build-review` — it should resolve to the cloned repo's skill directory.

**Adversarial review uses the same model for both reviewers**
- Your Claude Code version may not support per-invocation `model` overrides on the `Agent` tool. The skill detects this and logs it. Functionality is preserved, only model diversity is lost.

**Worktree mode creates the worktree but subsequent phases run in the wrong directory**
- This happens if the skill fell back to a raw `cd` instead of using the `EnterWorktree` tool. Make sure your Claude Code version has `EnterWorktree` available via `ToolSearch`.

**Deploy arg errors with "no deploy command found"**
- Add one of: a `## Deploy` section to your project `CLAUDE.md`, a `scripts.deploy` in `package.json`, a `deploy` target in `Makefile`, or an executable `./deploy.sh`. See [Deploy command resolution](#deploy-command-resolution).

**RLS/tenant errors on database queries during the review phase**
- Not a skill issue — this is environmental. The skill runs `git diff`, not SQL. If you're hitting RLS errors, check your project's database connection string (Neon pooler vs. direct endpoint is a common culprit).

**Review loop keeps finding the same issue after "fixing" it**
- Your chosen termination strategy is likely `iterate` — round 2 is expected to re-raise unresolved items. If the issue is actually fixed and the reviewer is wrong, switch to `user-decides` and arbitrate manually.

## Extending & customizing

Everything in `references/` is designed to be edited. Common customizations:

- **Add a dynamic scope trigger**: edit `references/review-scopes.md`, add a row to the trigger table. The skill will pick it up on the next invocation.
- **Tweak reviewer framing**: edit the Opus/Sonnet templates in `references/adversarial-pair.md`. Anything from wording changes to entirely new lenses (e.g., an "adversarial security" lens that asks pointedly about auth flows).
- **Change the clarification tiers**: edit `references/progressive-disclosure.md`. Add a T2.5 for "performance budgets" or whatever dimension matters in your domain.
- **Add a new arg**: edit `SKILL.md` Phase 0 arg table + the corresponding phase that should run. E.g., `tag` to auto-create a git tag after commit.

Keep `SKILL.md` itself thin — the goal is that Claude loads it quickly, sees the phase structure, and reads the relevant reference file only when that phase needs detail. Think of it as progressive disclosure for Claude itself.

## Contributing

Issues and PRs welcome.

- Keep `SKILL.md` under ~300 lines. Push detail into `references/`.
- Any new reference file should be self-contained: Claude should be able to act on it without reading other references.
- Prefer concrete examples and tables over prose where possible — it's easier for Claude to pattern-match from.
- If a change affects the adversarial-review framing, run the skill on itself to verify the new framing still catches representative issues.

## License

MIT. See [`LICENSE`](./LICENSE).

Do whatever you want with the code — use it, copy it, change it, sell it, bundle it into commercial products — as long as the copyright notice and license text stay attached. No warranty; if it breaks, it's on you.
