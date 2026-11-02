---
name: plan-build-review
description: Rigorous think→plan→do→review workflow. Use when the user invokes /plan-build-review, /plan-build-review:plan-build-review, or asks for a planned and reviewed implementation with optional git worktree, commit, push, or deploy finishing.
---

# plan-build-review

Execute the following workflow end-to-end when invoked. Do not skip phases; do not collapse them. Every phase has a purpose that compounds.

## Harness adapter

This skill runs in **Claude Code** and in **Cursor**. Decide which once, at the start, and record it: you are in **Claude Code** if an `Agent` or `ToolSearch` tool exists, or the Phase 0 placeholder was substituted; you are in **Cursor** if subagents are started with a `Task` tool and no `EnterPlanMode` tool exists. Every *italic verb* below resolves through this table (full detail and the Cursor reviewer roster: `references/harness-adapters.md` — read it before Phase 1 when in Cursor). Phase logic is identical in both harnesses; only the primitives differ. The Claude Code path is unchanged from v1.2.

| Verb | Claude Code | Cursor |
|---|---|---|
| *ask the user* | `AskUserQuestion` (load via `ToolSearch` if deferred; 4 options per call) | `AskQuestion` tool if present, else an inline numbered question |
| *enter plan mode* / *present the plan for approval* | `EnterPlanMode` / `ExitPlanMode` | user toggles Plan mode; stop the turn and wait for an explicit "approved" |
| *plan file path* | given by plan mode (`~/.claude/plans/<slug>.md`) | `~/.cursor/plans/<slug>.md` |
| *Explore subagents* / *produce the design* | `Agent` `Explore` / `Agent` `Plan` | built-in Explore via `Task` / main thread |
| *task tracker* | `TaskCreate`/`TaskUpdate`/`TaskList` | built-in todo list |
| *implementer subagents* | `Agent` general-purpose, `model: sonnet` (`opus` to escalate) | `Task`, inherit |
| *spawn the review pair* | `Agent` general-purpose, `model: opus` + `model: sonnet` | two roster `Task` subagents, different families |
| *create and enter* / *leave the worktree* | `EnterWorktree` / `ExitWorktree` | user runs `/worktree`, then `/apply-worktree` or `/delete-worktree` |

## 0. Parse arguments

Inspect the *invocation arguments* — `$ARGUMENTS` in Claude Code; in Cursor, the words that followed `/plan-build-review` in the user's message — for these tokens (position-insensitive, case-insensitive):

| Token | Effect |
|---|---|
| `commit` | Git action = commit only. **This is the default** if no git-action token is present. |
| `push` | Git action = commit + push. |
| `deploy` | Git action = commit + push + deploy. **Runs deploy with no confirmation prompt** (user preference). |
| `worktree` | Work happens inside a fresh git worktree (see Phase 2.5). Orthogonal — composes with any git-action. |

Examples: `/plan-build-review` → commit. `/plan-build-review push` → commit+push. `/plan-build-review deploy worktree` → worktree + commit+push+deploy.

**Before any destructive action** (worktree creation, edits, commits, deploy), emit a one-line confirmation: `Parsed args: git-action=<X>, worktree=<true|false>`. This lets the user course-correct before anything consequential happens. (Do not treat this as literally the "first line" of output — plan-mode entry or tool calls may come earlier.)

## Phase 1 — Enter plan mode

*Enter plan mode*. Everything from here until the plan is approved (Phase 4) is read-only exploration and question-asking. Record the **plan file path** (Claude Code: the path the plan-mode reminder gives you, e.g. `~/.claude/plans/<slug>.md`; Cursor: `~/.cursor/plans/<slug>.md`, create the directory) — you'll need it for Phase 4 and to pass to reviewers in Phase 6. In Cursor the agent cannot switch modes itself: say that Plan mode (Shift+Tab) is optional, and stay read-only by discipline until approval either way.

## Phase 2 — Progressive-disclosure clarification

**Read `references/progressive-disclosure.md`** for the tier catalog and example questions.

**Rule**: *Ask the user* **one tier at a time**. Descend only if prior-tier answers leave a load-bearing decision ambiguous. Do not front-load.

Tiers:

- **T1 Intent** — outcome, success criteria, non-goals. Always asked first.
- **T2 Scope** — which files/modules, what to reuse or avoid.
- **T3 Implementation** — test strategy, backwards-compat, perf/bundle/migration constraints. Skip if unambiguous — **except** the test-strategy question, which is always asked when T1 intent is a bug fix (default answer: **test-first**, see Phase 5).
- **T4 Review config** — **always asked**: review-loop termination strategy (single-pass / iterate-max-2 / user-decides). **Cursor only**: also ask which model family this chat is running on (Anthropic / OpenAI / Google / other) — Phase 6c excludes it from reviewing its own code. The per-reviewer scope picker happens in Phase 6b, after exploration reveals the actual diff.

**Visual target** (UI tasks only): if T1 intent touches user-visible UI, ask in the same T1 call whether a screenshot, mockup, or reference page exists. If the user supplies one, record its path — Phase 4.5 and Phase 6a capture before/after screenshots against it when the project has screenshot tooling.

## Phase 2.5 — Worktree setup (only if `worktree` arg)

**Why after T1**: the branch slug needs a grounded task description. Running worktree setup before T1 forces slug-invention from a possibly-vague prompt.

1. **Branch slug rules**: 2–3 descriptive words from the user's confirmed T1 intent, lowercased, joined by `-`, stripped of non-`[a-z0-9-]` chars, plus today's ISO date. Prefix: `feat/` (default), `fix/` (bug fix), `chore/` (infra/deps). Example: `feat/leaderboard-refactor-2026-04-24`.
2. **If the intent words are fewer than 2 meaningful tokens**, *ask the user* a single question: "What should I name this branch?" and skip derivation.
3. **Preflight**: verify current dir is a git repo (`git rev-parse --is-inside-work-tree`); if not, surface error and stop. **Already in a worktree?** If `git rev-parse --git-dir` and `git rev-parse --git-common-dir` differ, you are inside an existing worktree (e.g. a Cursor `/worktree` session): record worktree mode with the current branch, skip step 5, and note whether it is harness-created (Cursor `/worktree`) or hand-made — Phase 11 branches on this.
4. Record the original repo root (`git rev-parse --show-toplevel`) — Phase 11 needs it.
5. *Create and enter the worktree* at `.worktrees/<slug>/` on new branch `<branch>` (Claude Code: the `EnterWorktree` tool, loaded via `ToolSearch` if deferred; Cursor: ask the user to re-run the same command inside `/worktree` and stop — the preflight above detects it on the re-run — or, if they decline, fall back to `git worktree add .worktrees/<slug> -b <branch>` and run every later command with the absolute worktree path). **Do not rely on a raw `cd`** — `cd` in a shell call does not persist working-directory context across subsequent tool invocations.

## Phase 3 — Explore in parallel

**Repo-map preamble**: Before spawning Explore agents, check for `.claude/repo-map.md` in the target repo root. If present, read its first line — it should be `<!-- repo-map head: <sha> -->`. The map is **fresh** iff that SHA is an ancestor of current `HEAD` (`git merge-base --is-ancestor <sha> HEAD`) AND `git diff --name-only <sha>..HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.py' '*.go' '*.rs' '*.java' '*.rb'` returns nothing. (The canonical extension list lives in `references/repo-map.md` — keep the three copies in sync.) If fresh, pass it as shared context to each Explore agent and instruct them to treat the map as authoritative for file existence — their exploration budget should go to confirming patterns and finding usages, not re-listing files. If missing or stale, proceed normally. See `references/repo-map.md` for format and the `scripts/generate-repo-map.sh` helper users run to create/refresh the map.

Spawn up to 3 *Explore subagents* **in a single message** (multiple tool calls) — never serially. (Both harnesses have a built-in Explore subagent.) Each gets a distinct search focus. Often 1 is enough; use more only when scope is uncertain or spans multiple areas.

Suggested focuses:
- Agent A: existing implementations / utilities to reuse.
- Agent B: surrounding architecture + patterns in the affected area.
- Agent C: test conventions + relevant test files.

Ask each to report file paths + short summaries, under 400 words each.

## Phase 4 — Design

*Produce the design* (Claude Code: spawn **1 Plan subagent**; Cursor: do it on the main thread) from: user intent (T1/T2/T3 answers), Phase-3 findings, and any constraints. The output is an implementation approach with critical files, reusable functions with paths, and a verification section.

Write the final plan (recommended approach only — not alternatives) to the plan file recorded in Phase 1.

*Present the plan for approval* (Claude Code: `ExitPlanMode`; Cursor: post the plan path + summary, tell the user to switch back to Agent mode if they used Plan mode, and end the turn) — this surfaces the plan to the user and **blocks on their approval**. Do not proceed to Phase 4.5 until the user explicitly approves.

## Phase 4.5 — Pre-implementation checkpoint

After plan approval, before breaking the plan into tasks. Creates a one-command rollback path if Phase 6 review reveals the implementation is unsalvageable.

1. **Dirty-tree check**: run `git status`. If there are unstaged/staged files unrelated to this task, stop and ask the user before proceeding. (This mirrors the Phase 8 check — promoted earlier so you don't build on top of pollution. Keep the Phase 8 check too; it catches mid-implementation drift this earlier check can't see.) In worktree mode this check always passes by construction — keep it for symmetry.
2. **Record base SHA**: `git rev-parse HEAD`. Store this — Phase 6a uses it as the diff base instead of re-recording.
3. **Create checkpoint**:
   - **Worktree mode**: no-op. The fresh branch is already the checkpoint.
   - **In-place mode**: create a lightweight tag with `git tag plan-build-review-base/<YYYYMMDDHHMMSS>` pointing at HEAD (seconds granularity — avoids collision on same-minute reruns). If the exact tag already exists from an aborted prior run, append `-N` with the next free integer (`-2`, `-3`, …). Rollback is `git reset --hard <the-chosen-tag>`.
4. **Append a `## Rollback` section to the plan file** (path captured in Phase 1, contents written in Phase 4) with instructions appropriate to the mode:
   - **In-place mode**: the chosen tag name + the exact `git reset --hard <tag>` command.
   - **Worktree mode**: the rollback path is "do not merge and discard the branch" — document `git worktree remove .worktrees/<slug>` + `git branch -D <branch>` as the rollback, since no tag exists.
5. **Before-screenshots (UI tasks only)**: if the plan touches user-visible UI **and** the project has screenshot tooling (a `## Screenshots` section in `CLAUDE.md`, or a `package.json` script whose name or body mentions `playwright` or `screenshot`), run it now against the affected routes and save the output under the session scratchpad (or `/tmp/plan-build-review-shots-<ts>/before/`). Record the directory in the plan file. Skip silently if no tooling is found — never install one for this.

## Phase 5 — Implement

**Scratch-file rule (all phases from here on)**: logs, diffs, packets, screenshots and any other temporary output go to the session scratchpad directory or `/tmp`, **never** into the repo working tree. A stray `deploy.log` in the repo root is a dirty tree, and a dirty tree fails Phase 8's check and most deploy scripts.

0. **Test-first (default for bug fixes; opt-in otherwise via T3)**: before changing any source file, write one failing test that reproduces the bug or captures the new behavior. Run it and show the failure in the transcript. Only then implement, and make it pass **without editing the test**. If the test itself turns out to be wrong, stop and tell the user instead of changing it.
   **Test-integrity rule (always on)**: never delete, skip (`.skip`, `xit`, `--no-verify`), loosen, or rewrite an existing test to get to green. A test that blocks you is a finding — surface it, don't silence it.
1. Use the harness *task tracker* to break the plan into discrete steps (Claude Code: `TaskCreate`/`TaskUpdate`/`TaskList`, loaded via `ToolSearch` if deferred; Cursor: the built-in todo list; neither available: a checklist in the plan file). Mark each task `in_progress` before starting, `completed` as soon as finished — don't batch.
2. Delegate **independent** work to *implementer subagents* in parallel only where it saves meaningful wall time (Claude Code: `general-purpose` with `model: sonnet` by default, escalating an individual subagent to `model: opus` only when the task requires architectural judgment the architecture reviewer in Phase 6c would otherwise be asked to repair; Cursor: plain `Task` subagents inheriting the chat model). Don't over-delegate trivial edits — there's handoff overhead.
3. **Auto-lint + typecheck after each task**. After each Phase-5 task completes, run the project's lint **and** its type-check, and only then mark the task `completed`. Resolve each command separately (CLAUDE.md → package.json → binary on PATH), with a graceful skip instead of Phase 10's error-and-stop:
   a. Project `CLAUDE.md` or `AGENTS.md` (Cursor: also `.cursor/rules/*`) — `## Lint` / `## Typecheck` section or an explicit `lint command:` / `typecheck command:` line (not a keyword search).
   b. `package.json` → `scripts.lint` → `npm run lint`; `scripts.typecheck` (or `scripts.tsc`, `scripts.type-check`) → `npm run <that>`.
   c. Tooling binary on `PATH` (`eslint`, `ruff`, `mypy`) → run with default config. For typecheck: if a `tsconfig.json` exists and no script matched, run `npx tsc --noEmit`.
   d. **None found** for either → log a one-line note (`no lint command detected…` / `no typecheck command detected…`) and proceed. Do not error.

   Typecheck is **not** optional when a command exists: a lint pass that skips `tsc` is how type errors in new test files reach the reviewers instead of being fixed at the task boundary.

   On violations: attempt auto-fix only if the detected tool supports it (`eslint --fix`, `ruff check --fix`, or if the project's `npm run lint` script already includes a fix flag). If the tool does **not** auto-fix, surface the diagnostics and resolve them manually before marking the task complete. Do not silently add `--fix` to a user's lint command that didn't already use it — that changes observable behavior.

   If per-task lint is noticeably slow (>30s per run) on large monorepos, the main thread may batch lint at the end of a task group instead — but the default is per-task.
4. Tests: run the project's test command at milestones (end of each meaningful task group), not after every edit.

## Phase 6 — Adversarial review

**Read `references/adversarial-pair.md`** for briefing templates + severity rubric.
**Read `references/review-scopes.md`** for baseline scopes + dynamic triggers.

### 6a. Establish the diff

Run `git diff` against the correct base:
- **Worktree mode**: `git diff <main-branch-name>...HEAD` (three dots — merge base). Detect the default branch via `git remote show origin | grep 'HEAD branch'` or `git symbolic-ref refs/remotes/origin/HEAD`.
- **In-place mode, this task has its own commits**: use the base SHA recorded in Phase 4.5 and diff against that: `git diff <base-sha>..HEAD` plus any staged/unstaged changes.
- **In-place mode, nothing committed yet**: `git diff HEAD` (covers staged + unstaged).

If the diff is larger than ~2000 lines, write it to a temp file (`/tmp/plan-build-review-diff-<timestamp>.patch`) and pass the path to reviewers instead of inlining. Always pass the base SHA too — a read-only reviewer that cannot open the patch file regenerates the diff from it.

**After-screenshots (UI tasks only)**: if Phase 4.5 captured before-screenshots, run the same tooling again into a sibling `after/` directory. Pass both directories (and the user's visual target, if any) to both reviewers so they review the rendered result, not just the diff.

### 6b. Synthesize dynamic scopes + ask per-reviewer scope config

Consult the trigger table in `review-scopes.md`. Synthesize **1–2 dynamic scope suggestions** specific to the diff.

*Ask the user* per reviewer. In Claude Code, `AskUserQuestion` caps options at 4 per call; the 4 baselines alone hit the cap, so any dynamic scope **forces a split**. Pattern:

1. First question for the architecture reviewer: present 4 baseline scopes (multi-select).
2. If dynamic scopes exist, second question for the architecture reviewer: "Any additional focus from these dynamic suggestions?" with the dynamic scopes + a "None, proceed" option.
3. Repeat both steps for the correctness reviewer.

Reviewers may share scopes — overlap surfaces divergence.

### 6c. *Spawn the review pair* in parallel

Two reviewers, two lenses (**architecture** and **correctness**), always **in a single message with two subagent calls**. Templates are in `adversarial-pair.md`.

**Claude Code** (unchanged):

- **Architecture reviewer**: `Agent`, `subagent_type: general-purpose`, `model: opus`. Use the architecture (Opus) template.
- **Correctness reviewer**: `Agent`, `subagent_type: general-purpose`, `model: sonnet`. Use the correctness (Sonnet) template.

(If your Claude Code version does not support the `model` override on the `Agent` tool, degrade gracefully: run both reviewers with the default model but keep the adversarial framing. Log a note that model diversity was not available.)

**Cursor** (roster — full rules in `references/harness-adapters.md`):

- The plugin ships read-only subagents `reviewer-anthropic`, `reviewer-openai`, `reviewer-google`, each pinned to one model family. Exclude the implementer's family (from T4; "other"/unknown excludes nothing); pick two different remaining families; architecture lens to the first, correctness lens to the second; spawn both with `Task` in one message.
- Each report must start with `Reviewer model: …`. If the two families match, or either matches the implementer, re-spawn that lens **once** — but only if an unused roster member exists whose family is neither the implementer's nor one already reported (with a 3-member roster that is only possible when the implementer is "other"). Otherwise, or if it still collides, log `model diversity unavailable: <lens> reported <family>` and continue with the findings you have.
- Partial or missing roster (skill-only symlink install): use whatever non-implementer members exist, fill the rest with plain `Task` subagents carrying the lens templates, and log `model diversity unavailable: roster agents not installed`.

**Substitute placeholders explicitly** before passing the template to the subagent prompt:
- `<path>` → plan file path recorded in Phase 1
- `<scope list>` → comma-separated scopes assigned in 6b
- `<paste diff here>` → the diff output from 6a (or `See /tmp/plan-build-review-diff-<ts>.patch` if it was written to a file)
- `<base-sha>` → the base SHA from Phase 4.5 (or the merge base in worktree mode)
- `<repo>` → absolute path of the repo or worktree being reviewed (subagents start in the orchestrator's working directory, which may differ)
- `<lens>` → `architecture` or `correctness`

## Phase 7 — Synthesize findings + apply fixes

1. Merge both reviewer reports, grouped by file then severity.
2. De-duplicate issues both reviewers raised (keep the one with the concrete fix; note "both reviewers flagged this" — strong signal).
3. Resolve conflicts: prefer the finding with a citable `file:line` and concrete fix.
3.5. **Verify before fixing.** Reviewers always find something. For every `blocker` and `high`, read the cited code yourself and confirm the failure scenario is real before touching anything. Downgrade a finding whose scenario can't actually occur, and say so in the summary. Findings tagged `confidence: low` by the reviewer need this check even at `medium`.
4. Apply fixes per the user's termination strategy (T4):
   - **Single-pass**: fix `blocker` + `high` items. Log `medium`/`nit` for follow-up. Move to Phase 8.
   - **Iterate (max 2)**: fix → re-run both reviewers (Phase 6c) with updated diff + their round-1 findings + instruction to "focus on whether round-1 blockers/highs are resolved and flag any new issues introduced by the fixes." Hard cap at 2 review rounds. If blockers remain, *ask the user* and stop.
   - **User-decides**: *ask the user* with the merged findings and options {fix-and-commit, fix-and-re-review, surface-and-stop}. Act accordingly.

## Phase 8 — Commit

Stage specific files only — **never** `git add .` or `git add -A`. Commit message sections are optional except `why` and the trailer — omit sections you'd be padding:

```
<type>(<scope>): <short summary under 72 chars>

<why — the motivation, constraint, or bug behavior>

<what changed conceptually — only if not obvious from the summary>

<anything non-obvious a future reader needs — only if there's real content>

<attribution trailer>
```

**Attribution trailer**: use the exact `Co-Authored-By:` line the session's system reminder supplies for the current model. Do not hard-code a model name — it goes stale the moment the model changes. If the session supplies none, omit the trailer.

Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`. Match the existing project's convention (check `git log --oneline -20`).

**Dirty-tree check**: before staging, run `git status`. If there are unstaged/staged files not related to this task, **stop and ask the user** — don't silently commit unrelated work.

## Phase 9 — Push (if `push` or `deploy`)

`git push -u origin <current-branch>`. The `-u` establishes upstream tracking on first push.

## Phase 10 — Deploy (if `deploy`)

**No confirmation prompt** — run deploy immediately. Look up the deploy command in this order:

1. Project `CLAUDE.md` or `AGENTS.md` (Cursor: also `.cursor/rules/*`) — look for a `## Deploy` section or an explicit `deploy command:` line (not a keyword search).
2. `package.json` → `scripts.deploy` → run `npm run deploy`.
3. `Makefile` target `deploy` → run `make deploy`.
4. `./deploy.sh` or `./scripts/deploy.sh` (executable) → run it.
5. **None found** → **error and stop**: `deploy arg used but no deploy command found. Configure a deploy command in CLAUDE.md/AGENTS.md or add a scripts.deploy entry to package.json.` Do not guess.

**Branch-safety guard**: if the current branch is NOT the project's main deploy branch (usually `main`), emit a one-line warning before running — e.g., `Deploying from branch feat/foo (not main).` Still proceeds (no prompt per user preference), but the log is traceable.

Stream deploy output; surface final status. If you capture deploy output to a file, write it to the scratchpad or `/tmp/plan-build-review-deploy-<ts>.log` — **never** into the repo (see the Phase 5 scratch-file rule). After deploy finishes, run `git status --porcelain`; if anything new appeared in the tree, report it — that's a leak the next deploy would trip over. If deploy fails, surface the error and stop (do not retry).

## Phase 11 — Merge prompt (only if `worktree`)

After commit/push/deploy succeed, *ask the user*: "Merge `<branch>` to the default branch now?"

- **Yes, merge and clean up** → *leave the worktree* (Claude Code: `ExitWorktree` to return to the original repo root, then `git merge --no-ff <branch>`, `git push`, `git worktree remove .worktrees/<slug>`, `git branch -d <branch>`; Cursor, harness-created worktree: ask the user to run `/apply-worktree`, then `/delete-worktree`; Cursor, hand-made `git worktree add` fallback: run the same merge sequence as Claude Code using `git -C <original-root>` for every command).
- **No, leave worktree** → print resume instructions: worktree path, branch name, how to come back.

## End-of-run summary

One or two sentences: what was built, what was reviewed, what's next (e.g., "ready to merge worktree" or "deploy succeeded"). Then one line: the plan file path (it holds the plan, rollback and screenshot locations) and a recommendation to `/clear` before the next unrelated task — long contexts degrade, and everything needed to resume is already on disk. No trailing recap beyond that.
