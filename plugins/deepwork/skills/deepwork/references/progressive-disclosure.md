# Progressive-disclosure clarification tiers

Purpose: collapse the "ask everything upfront" anti-pattern into tiered questions that only descend when genuinely needed. Each tier asks the **minimum** required to unblock the next phase.

## The skip rule

> Descend to the next tier **only if** the prior tier's answers leave at least one load-bearing decision ambiguous. Otherwise proceed to Phase 3 (exploration). Do not ask questions whose answers won't change what you do.

Tiers are cumulative, not optional. Tier 1 is always asked. Tier 4 (review config) is always asked. Tiers 2 and 3 are conditional.

## T1 — Intent (always asked)

**Goal**: pin down the outcome so the plan has a clear target.

Example `AskUserQuestion` frame (one question, 2–4 options tailored to the task):

> "What does done look like for this task?"
> - The observable outcome (user-visible change)
> - The internal outcome (refactor / cleanup — no user-visible delta)
> - Something else / not sure yet

If the user's original prompt already named an outcome clearly, skip the question and just confirm the non-goals:

> "To scope this correctly — what's explicitly **out of scope** for this change?"

## T2 — Scope (conditional)

**Ask if**: T1 didn't make clear which files/modules are affected, or if there are multiple plausible surfaces to touch.

**Placeholder substitution**: the examples below use `<specific area 1>`, `<specific area 2>`, etc. as placeholders. **You must substitute** these with concrete file/module names drawn from the user's prompt and any quick-glance exploration you've done. Never pass literal `<...>` tokens to `AskUserQuestion` — the user will see confusing angle-bracket text.

Example questions:

> "Which area should the change land in?"
> - `<specific area 1>` — you'll make this more load-bearing
> - `<specific area 2>` — less invasive, fits existing patterns
> - Both — accept the duplication trade-off
> - Let exploration decide — (Recommended if you don't know the codebase yet)

> "Anything specific we should reuse or avoid?"
> (open-ended; let user type. Expect answers like "use the existing `<util>` pattern" or "don't touch the legacy `<file>` module")

## T3 — Implementation (conditional)

**Ask if**: T1+T2 answers don't clarify test strategy, backwards-compat, or perf/migration constraints — AND those dimensions matter for the task.

Example questions (pick the ones that matter, ask only those):

> "Test strategy?"
> - Add unit tests only
> - Add integration tests only
> - Both (Recommended for anything touching a data boundary)
> - No tests for this change (explain why in notes)

> "Backwards-compat constraint?"
> - Must preserve all existing behavior
> - Can change behavior with a migration
> - Can change behavior, no migration (internal only)
> - N/A

Do **not** ask all T3 questions by default. Only ask the subset that the task actually turns on.

## T4 — Review config (always asked)

**Goal**: capture the user's preferences for the adversarial review *before* implementation starts, so you're not surprising them at the end.

> "How should the review→fix loop terminate?"
> - Single pass: review → fix blockers+highs → done (Recommended for small changes)
> - Iterate until clean, max 2 rounds — more thorough, ~2× review cost
> - User decides after first review — max control, interactive

Store the answer; the reviewer-scope picker itself happens in **Phase 6b** (after exploration), not here, because dynamic scope suggestions depend on what the diff actually touches.

## Meta-rule

If you find yourself asking more than 3 `AskUserQuestion` calls in a row in the clarification phase, stop and ask yourself: "Is the user trying to tell me this task is simple and I'm over-asking?" Err on the side of proceeding to exploration with reasonable assumptions that you'll surface in the plan for approval.
