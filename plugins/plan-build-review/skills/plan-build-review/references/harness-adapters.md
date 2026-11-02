# Harness adapters: Claude Code ↔ Cursor

`SKILL.md` is written once and runs in two harnesses. Phase logic is identical; only the primitives differ. This file is the lookup table for every *italic verb* in `SKILL.md`, plus the Cursor-only reviewer roster rules.

## Detecting the harness

At the start of a run, decide once and record it:

- **Claude Code** — positive signals: an `Agent` tool or a `ToolSearch` tool exists, or the Phase 0 placeholder was substituted with real text. Skills are invoked as `/plan-build-review` (symlink install) or `/plan-build-review:plan-build-review` (plugin install). A Claude Code session with plan-mode tools denied is still Claude Code — it just cannot enter plan mode (surface that and stop, as v1.2 did).
- **Cursor** — subagents are started with a `Task` tool and no `EnterPlanMode` tool exists; the skill was attached with `/plan-build-review` in Agent chat.

If neither set of signals matches, use the Cursor column (it assumes the least).

## Primitive table

| Primitive (italic verb in SKILL.md) | Claude Code | Cursor |
|---|---|---|
| *Invocation arguments* (Phase 0) | The ARGUMENTS placeholder in Phase 0 is substituted with the text after the command. | No substitution. Read the words that followed `/plan-build-review` in the user's message (the placeholder may still appear literally — ignore it). |
| *Enter plan mode* (Phase 1) | `EnterPlanMode` tool. The system reply names the plan file path. | The agent cannot enter Plan mode. Say: "Phases 1–4 are read-only; you may switch this chat to Plan mode (Shift+Tab) if you want Cursor to enforce that." Either way, treat every phase up to approval as read-only by discipline. If Cursor's native plan flow produced its own plan file, record that path as the plan file. |
| *Plan file path* | `~/.claude/plans/<slug>.md` (given by the harness). | `~/.cursor/plans/<slug>.md` — create the directory; slug = 2–3 words from T1 intent + ISO date. |
| *Present the plan for approval* (Phase 4) | `ExitPlanMode` — blocks until the user approves. | Post the plan file path and a 5-line summary, add "if you switched to Plan mode, switch back to Agent mode (Shift+Tab) before replying", then **stop the turn**. Proceed only on an explicit `approved` (or equivalent) reply. Anything else is a revision request. |
| *Ask the user* (Phases 2, 6b, 7, 11) | `AskUserQuestion`. Max 4 options per call — split calls when a tier needs more. | The `AskQuestion` tool when the model exposes it; otherwise a numbered inline question and end the turn. The 4-option cap does not apply, but keep the same one-tier-at-a-time discipline. |
| *Explore subagents* (Phase 3) | `Agent` tool, `subagent_type: Explore`, up to 3 in one message. | Built-in `Explore` subagent via `Task`, up to 3 in one message. |
| *Design subagent* (Phase 4) | `Agent` tool, `subagent_type: Plan`. | No Plan subagent. Produce the design on the main thread, using the Phase 3 findings. |
| *Task tracker* (Phase 5) | `TaskCreate` / `TaskUpdate` / `TaskList` (load via `ToolSearch` if deferred). If absent, keep a checklist in the plan file. | Built-in todo list. If absent, keep a checklist in the plan file. |
| *Implementer subagents* (Phase 5) | `Agent`, `subagent_type: general-purpose`, `model: sonnet` by default, `opus` for architectural judgment. | `Task` with a plain prompt (`model: inherit`). |
| *Spawn the review pair* (Phase 6c) | **Unchanged from v1.2**: two `Agent` calls in one message, `subagent_type: general-purpose`, `model: opus` (architecture lens) and `model: sonnet` (correctness lens), templates in `adversarial-pair.md`. | Two `Task` calls in one message to **roster subagents** chosen by the rules below. Same templates, plus the `Lens:` and `Base SHA:` lines. |
| *Create and enter the worktree* (Phase 2.5) | `EnterWorktree` tool (load via `ToolSearch`). Never a raw `cd`. | No agent-callable worktree tool. First check whether you are already inside a worktree (`git rev-parse --git-dir` ≠ `git rev-parse --git-common-dir`): if so, record worktree mode (harness-created) and skip creation. Otherwise, preferred: ask the user to re-run the same command inside `/worktree` and stop. Fallback if they decline: `git worktree add .worktrees/<slug> -b <branch>` (record as hand-made) and run **every** later command with the absolute worktree path — `cd` does not persist between tool calls. |
| *Leave the worktree* (Phase 11) | `ExitWorktree`, then `git merge --no-ff`, `git push`, `git worktree remove`, `git branch -d`. | Harness-created (`/worktree`): ask the user to run `/apply-worktree` (merge) or `/delete-worktree` (discard); do not merge yourself. Hand-made fallback: run the Claude Code sequence with `git -C <original-root>` for every command. |
| Repo map (Phase 3) | `.claude/repo-map.md` | Same path — the skill reads it as a plain file, so the location does not depend on the harness. |
| Scratch files | Session scratchpad or `/tmp` | `/tmp`. Never the repo tree. |

## Cursor reviewer roster

The plugin ships three read-only reviewer subagents under `cursor/agents/`, one per model family, each pinned via `model:` frontmatter:

| Subagent | Family | Pinned model (edit to match your model picker) |
|---|---|---|
| `reviewer-anthropic` | Anthropic | `claude-opus-5-5` |
| `reviewer-openai` | OpenAI | `gpt-5.5` |
| `reviewer-google` | Google | `gemini-3.1-pro` |

They are only present when the plugin was installed through a Cursor marketplace (or the files were copied/symlinked into `~/.cursor/agents/`). A symlink install of the skill alone (`~/.claude/skills/`) does **not** carry them.

### Selection rule (Phase 6c, Cursor only)

1. **Implementer family.** In T4 (Phase 2) ask one extra question: "Which model family is this chat running on?" with options Anthropic / OpenAI / Google / "Auto or not sure — use the agent's self-report" / other. Put your own self-identified family first as the recommended option. That family wrote the code and is excluded from reviewing it. **"Other" or unknown excludes nothing**: skip the implementer comparison in step 4, still require the two reviewers to differ, and log `implementer exclusion not possible: family unknown`.
2. **Pick two.** From the roster minus the implementer's family, take two different families. Give the **architecture** lens to the first and the **correctness** lens to the second. **Partial roster** (some `reviewer-*` files missing): use the available non-implementer members and fill the remaining lens with a plain `Task` subagent (`model: inherit`), logging the reduced diversity.
3. **Spawn both in one message** (two `Task` calls) with the templates from `adversarial-pair.md`, substituting `<path>`, `<scope list>`, `<paste diff here>`, `<base-sha>`, `<repo>` and `<lens>`.
4. **Check line 1.** Each report starts with `Reviewer model: …`. Cursor silently substitutes a compatible model when a pinned one is unavailable on the plan, so the line is the only signal. A collision is: both reports name the same family, or either names the implementer's family.
5. **Re-spawn at most once, and only when it can help.** Re-spawn the offending lens only if an **unused** roster member exists whose family is neither the implementer's nor one already reported. With the 3-member roster and a known implementer family, both non-implementer members are already in use, so there is no such member — go straight to step 6. The re-spawn is reachable when the implementer is "other"/unknown (three candidates, two in use) or when the roster has been extended with a fourth family.
6. **Bounded.** On any collision you cannot repair, log `model diversity unavailable: <lens> reported <family>` and continue with the findings you have. Never loop, never spawn a third full review.

### Fallback when no roster subagents exist

If `reviewer-anthropic` / `reviewer-openai` / `reviewer-google` are not available as `Task` targets, spawn two plain `Task` subagents (`model: inherit`) with the two lens templates, and log `model diversity unavailable: roster agents not installed`. The adversarial framing is preserved; only the family split is lost.

## Things that are intentionally the same in both harnesses

- Phase order, tier questions, test-first and test-integrity rules, lint/typecheck-per-task, the scratch-file rule, commit message format, deploy resolution order, and the review findings format.
- The severity rubric and the "verify before fixing" step in Phase 7.
