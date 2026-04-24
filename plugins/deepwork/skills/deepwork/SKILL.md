---
name: deepwork
description: Rigorous think→plan→do→review workflow. Use when the user invokes /deepwork, /deepwork:deepwork, or asks for a planned and reviewed implementation with optional git worktree, commit, push, or deploy finishing.
---

# deepwork

Execute the following workflow end-to-end when invoked. Do not skip phases; do not collapse them. Every phase has a purpose that compounds.

## 0. Parse arguments

Inspect `$ARGUMENTS` for these tokens (position-insensitive, case-insensitive):

| Token | Effect |
|---|---|
| `commit` | Git action = commit only. **This is the default** if no git-action token is present. |
| `push` | Git action = commit + push. |
| `deploy` | Git action = commit + push + deploy. **Runs deploy with no confirmation prompt** (user preference). |
| `worktree` | Work happens inside a fresh git worktree (see Phase 2.5). Orthogonal — composes with any git-action. |

Examples: `/deepwork` → commit. `/deepwork push` → commit+push. `/deepwork deploy worktree` → worktree + commit+push+deploy.

**Before any destructive action** (worktree creation, edits, commits, deploy), emit a one-line confirmation: `Parsed args: git-action=<X>, worktree=<true|false>`. This lets the user course-correct before anything consequential happens. (Do not treat this as literally the "first line" of output — plan-mode entry or tool calls may come earlier.)

## Phase 1 — Enter plan mode

Call `EnterPlanMode`. Everything from here to `ExitPlanMode` is read-only exploration and question-asking. The plan-mode system reminder provides a **plan file path** (e.g., `~/.claude/plans/<slug>.md`). **Record this path** — you'll need it for Phase 4 and to pass to reviewers in Phase 6.

## Phase 2 — Progressive-disclosure clarification

**Read `references/progressive-disclosure.md`** for the tier catalog and example questions.

**Rule**: Ask **one tier at a time** via `AskUserQuestion`. Descend only if prior-tier answers leave a load-bearing decision ambiguous. Do not front-load.

Tiers:

- **T1 Intent** — outcome, success criteria, non-goals. Always asked first.
- **T2 Scope** — which files/modules, what to reuse or avoid.
- **T3 Implementation** — test strategy, backwards-compat, perf/bundle/migration constraints. Skip if unambiguous.
- **T4 Review config** — **always asked**: review-loop termination strategy (single-pass / iterate-max-2 / user-decides). The per-reviewer scope picker happens in Phase 6b, after exploration reveals the actual diff.

## Phase 2.5 — Worktree setup (only if `worktree` arg)

**Why after T1**: the branch slug needs a grounded task description. Running worktree setup before T1 forces slug-invention from a possibly-vague prompt.

1. **Branch slug rules**: 2–3 descriptive words from the user's confirmed T1 intent, lowercased, joined by `-`, stripped of non-`[a-z0-9-]` chars, plus today's ISO date. Prefix: `feat/` (default), `fix/` (bug fix), `chore/` (infra/deps). Example: `feat/leaderboard-refactor-2026-04-24`.
2. **If the intent words are fewer than 2 meaningful tokens**, ask a single `AskUserQuestion`: "What should I name this branch?" and skip derivation.
3. **Preflight**: verify current dir is a git repo (`git rev-parse --is-inside-work-tree`); if not, surface error and stop.
4. Record the original repo root (`git rev-parse --show-toplevel`) — Phase 11 needs it.
5. **Use the `EnterWorktree` tool** (load its schema via `ToolSearch` if needed) to create and switch to the worktree at `.worktrees/<slug>/` on new branch `<branch>`. **Do not use a raw `cd`** — `cd` in a Bash call does not persist working-directory context across subsequent tool invocations.

## Phase 3 — Explore in parallel

Spawn up to 3 `Explore` subagents **in a single message** (multiple tool calls) — never serially. Each gets a distinct search focus. Often 1 is enough; use more only when scope is uncertain or spans multiple areas.

Suggested focuses:
- Agent A: existing implementations / utilities to reuse.
- Agent B: surrounding architecture + patterns in the affected area.
- Agent C: test conventions + relevant test files.

Ask each to report file paths + short summaries, under 400 words each.

## Phase 4 — Design

Spawn **1 Plan subagent** with: user intent (T1/T2/T3 answers), Phase-3 findings, and any constraints. Ask for an implementation approach with critical files, reusable functions with paths, and a verification section.

Write the final plan (recommended approach only — not alternatives) to the plan file recorded in Phase 1.

Call `ExitPlanMode` — this surfaces the plan to the user and **blocks on their approval**. Do not proceed to Phase 5 until the user approves.

## Phase 5 — Implement

1. Use the session's task-tracking tool to break the plan into discrete steps. In Claude Code this is typically `TaskCreate`/`TaskUpdate`/`TaskList` (deferred — load via `ToolSearch` if needed) or the built-in equivalent. Mark each task `in_progress` before starting, `completed` as soon as finished — don't batch.
2. Delegate **independent** work to `general-purpose` subagents in parallel only where it saves meaningful wall time. Don't over-delegate trivial edits — there's handoff overhead.
3. Run linters/tests as you go; don't wait until the end.

## Phase 6 — Adversarial review

**Read `references/adversarial-pair.md`** for briefing templates + severity rubric.
**Read `references/review-scopes.md`** for baseline scopes + dynamic triggers.

### 6a. Establish the diff

Run `git diff` against the correct base:
- **Worktree mode**: `git diff <main-branch-name>...HEAD` (three dots — merge base). Detect the default branch via `git remote show origin | grep 'HEAD branch'` or `git symbolic-ref refs/remotes/origin/HEAD`.
- **In-place mode, this task has its own commits**: record the base SHA at the start of Phase 5 (`git rev-parse HEAD`) and diff against that: `git diff <base-sha>..HEAD` plus any staged/unstaged changes.
- **In-place mode, nothing committed yet**: `git diff HEAD` (covers staged + unstaged).

If the diff is larger than ~2000 lines, write it to a temp file (`/tmp/deepwork-diff-<timestamp>.patch`) and pass the path to reviewers instead of inlining.

### 6b. Synthesize dynamic scopes + ask per-reviewer scope config

Consult the trigger table in `review-scopes.md`. Synthesize **1–2 dynamic scope suggestions** specific to the diff.

`AskUserQuestion` caps options at 4 per call. The 4 baselines alone hit the cap, so any dynamic scope **forces a split**. Pattern:

1. First `AskUserQuestion` for the Opus reviewer: present 4 baseline scopes (multi-select).
2. If dynamic scopes exist, second `AskUserQuestion` for the Opus reviewer: "Any additional focus from these dynamic suggestions?" with the dynamic scopes + a "None, proceed" option.
3. Repeat both steps for the Sonnet reviewer.

Reviewers may share scopes — overlap surfaces divergence.

### 6c. Spawn both reviewers in parallel

**In a single message with two `Agent` tool calls:**

- **Opus reviewer**: `subagent_type: general-purpose`, `model: opus`. Use the Opus template from `adversarial-pair.md`.
- **Sonnet reviewer**: `subagent_type: general-purpose`, `model: sonnet`. Use the Sonnet template.

**Substitute placeholders explicitly** before passing the template to the subagent prompt:
- `<path>` → plan file path recorded in Phase 1
- `<scope list>` → comma-separated scopes assigned in 6b
- `<paste diff here>` → the diff output from 6a (or `See /tmp/deepwork-diff-<ts>.patch` if it was written to a file)

(If your Claude Code version does not support the `model` override on the `Agent` tool, degrade gracefully: run both reviewers with the default model but keep the adversarial framing. Log a note that model diversity was not available.)

## Phase 7 — Synthesize findings + apply fixes

1. Merge both reviewer reports, grouped by file then severity.
2. De-duplicate issues both reviewers raised (keep the one with the concrete fix; note "both reviewers flagged this" — strong signal).
3. Resolve conflicts: prefer the finding with a citable `file:line` and concrete fix.
4. Apply fixes per the user's termination strategy (T4):
   - **Single-pass**: fix `blocker` + `high` items. Log `medium`/`nit` for follow-up. Move to Phase 8.
   - **Iterate (max 2)**: fix → re-run both reviewers (Phase 6c) with updated diff + their round-1 findings + instruction to "focus on whether round-1 blockers/highs are resolved and flag any new issues introduced by the fixes." Hard cap at 2 review rounds. If blockers remain, surface to user via `AskUserQuestion` and stop.
   - **User-decides**: present merged findings via `AskUserQuestion` with options {fix-and-commit, fix-and-re-review, surface-and-stop}. Act accordingly.

## Phase 8 — Commit

Stage specific files only — **never** `git add .` or `git add -A`. Commit message sections are optional except `why` and the trailer — omit sections you'd be padding:

```
<type>(<scope>): <short summary under 72 chars>

<why — the motivation, constraint, or bug behavior>

<what changed conceptually — only if not obvious from the summary>

<anything non-obvious a future reader needs — only if there's real content>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`. Match the existing project's convention (check `git log --oneline -20`).

**Dirty-tree check**: before staging, run `git status`. If there are unstaged/staged files not related to this task, **stop and ask the user** — don't silently commit unrelated work.

## Phase 9 — Push (if `push` or `deploy`)

`git push -u origin <current-branch>`. The `-u` establishes upstream tracking on first push.

## Phase 10 — Deploy (if `deploy`)

**No confirmation prompt** — run deploy immediately. Look up the deploy command in this order:

1. Project `CLAUDE.md` — look for a `## Deploy` section or an explicit `deploy command:` line (not a keyword search).
2. `package.json` → `scripts.deploy` → run `npm run deploy`.
3. `Makefile` target `deploy` → run `make deploy`.
4. `./deploy.sh` or `./scripts/deploy.sh` (executable) → run it.
5. **None found** → **error and stop**: `deploy arg used but no deploy command found. Configure a deploy command in CLAUDE.md or add a scripts.deploy entry to package.json.` Do not guess.

**Branch-safety guard**: if the current branch is NOT the project's main deploy branch (usually `main`), emit a one-line warning before running — e.g., `Deploying from branch feat/foo (not main).` Still proceeds (no prompt per user preference), but the log is traceable.

Stream deploy output; surface final status. If deploy fails, surface the error and stop (do not retry).

## Phase 11 — Merge prompt (only if `worktree`)

After commit/push/deploy succeed, ask via `AskUserQuestion`: "Merge `<branch>` to the default branch now?"

- **Yes, merge and clean up** → call `ExitWorktree` to return to the original repo root. Run `git merge --no-ff <branch>`, then `git push`. Then `git worktree remove .worktrees/<slug>` and `git branch -d <branch>`.
- **No, leave worktree** → print resume instructions: worktree path, branch name, how to come back.

## End-of-run summary

One or two sentences: what was built, what was reviewed, what's next (e.g., "ready to merge worktree" or "deploy succeeded"). No trailing recap beyond that.
