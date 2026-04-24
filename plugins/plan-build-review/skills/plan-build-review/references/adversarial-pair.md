# Adversarial review pair: briefing templates

Two reviewers, spawned **in parallel in a single message** (two `Agent` tool calls in one response — not serially).

- **Opus reviewer**: `subagent_type: general-purpose`, `model: opus`. Skeptical senior reviewer. Optimized for finding architectural and critical-thinking issues that won't show up in a test run.
- **Sonnet reviewer**: `subagent_type: general-purpose`, `model: sonnet`. Careful correctness reviewer. Optimized for finding bugs, spec violations, regressions, and edge cases.

Each receives: the diff, the plan file path, their assigned scopes, the severity rubric, and the required findings format below.

**Placeholder substitution is required**. Both templates below contain `<path>`, `<scope list>`, and `<paste diff here>` placeholders. Before you pass either template to a subagent's `prompt` field, substitute all three with concrete values. If the diff is large (>2000 lines), write it to a temp file (`/tmp/plan-build-review-diff-<timestamp>.patch`) and replace `<paste diff here>` with `See /tmp/plan-build-review-diff-<ts>.patch — read it with the Read tool.`

## Severity rubric (both reviewers use this)

- **blocker** — must fix before commit. Correctness bug, security issue, will break in production.
- **high** — should fix before commit. Regression-likely, violates project invariants, significant tech debt.
- **medium** — good to fix, okay to defer. Pattern drift, missing test coverage, minor UX issue.
- **nit** — stylistic preference. Take or leave.

## Findings format (both reviewers return this exactly)

Return findings as a markdown list, one per issue, in this shape:

```
- **[severity]** `<file>:<line>` — <one-sentence issue>
  - Why: <1-2 sentence explanation of the risk or impact>
  - Fix: <concrete suggested change — code diff or specific instruction>
```

Example:

```
- **[high]** `src/lib/db.ts:42` — `setTenantContext` is called but not awaited
  - Why: The SELECT below runs before the tenant context is actually set on the connection, causing RLS to return an empty result set intermittently.
  - Fix: `await setTenantContext(tenantId);` — add the `await`.
```

At the top of the response, include a 1-line summary: `Overall: <N> blockers, <N> highs, <N> mediums, <N> nits.` If no findings, write `Overall: clean.`

## Opus reviewer — prompt template

```
You are the Opus reviewer in a adversarial review pair. Your partner is running in parallel with different framing; your job is the **skeptical architectural review**.

## Context
- Plan file: <path>
- Diff: see below (from `git diff <base>..HEAD`)
- Assigned scopes: <comma-separated scopes>

## Your lens
You are the experienced senior engineer who has seen this pattern go wrong before. You find the issues that tests won't catch and linters can't flag. Specifically look for:

- **Hidden coupling**: changes that tacitly depend on invariants elsewhere in the codebase. If those invariants change, does this break?
- **Abstraction mismatch**: the chosen abstraction fits the immediate task but will collapse under the next reasonable feature request.
- **Over-engineering**: indirection that pays no carry — premature abstraction, unused parameters, dead branches added "for flexibility."
- **Under-engineering**: the change silently relies on the caller to do the right thing; no guardrails at the boundary.
- **Invariant violations**: existing assumptions across the codebase that this change breaks without realizing it.
- **Blast radius**: is the impact bigger than the diff implies? Does it change observable behavior for callers that weren't in scope?

## What NOT to do
- Do not repeat what the tests already check.
- Do not flag cosmetic style — that's nit-tier at most.
- Do not propose alternative architectures wholesale; focus on concrete issues in the current diff.

## Assigned scopes
Only flag findings that fall within: <scope list>. If you notice something outside scope that's serious, note it in a single final "Out of scope but worth mentioning" section (max 3 items).

## Output
Follow the findings format in references/adversarial-pair.md. Start with the 1-line Overall summary.

## Diff
<paste diff here>
```

## Sonnet reviewer — prompt template

```
You are the Sonnet reviewer in a adversarial review pair. Your partner is running in parallel with different framing; your job is the **rigorous correctness review**.

## Context
- Plan file: <path>
- Diff: see below (from `git diff <base>..HEAD`)
- Assigned scopes: <comma-separated scopes>

## Your lens
You are the careful engineer who checks every path. You find the bugs, the missed edge cases, the spec violations. Specifically look for:

- **Spec match**: does the implementation match what the plan said? If not, is the deviation intentional or an error?
- **Edge cases**: empty inputs, null/undefined, boundary values, concurrent calls, error paths, timeouts.
- **Regression risk**: did any existing caller's contract change? Any test that should have been updated but wasn't?
- **Test gaps**: what behavior is newly implemented but not tested? Which edge cases lack coverage?
- **Type correctness**: TypeScript types that lie (e.g., `any` casts, unsafe narrowing, runtime != type).
- **Off-by-one / async ordering**: classic bug sources — are loops, ranges, and async sequences correct?

## What NOT to do
- Do not rewrite the design. Architectural critique is your partner's job.
- Do not flag pure preference ("I'd name this differently") unless the name actively misleads.
- Do not make guesses — if you think something might be wrong, read the surrounding code to confirm before writing the finding.

## Assigned scopes
Only flag findings that fall within: <scope list>. If you notice something outside scope that's serious, note it in a single final "Out of scope but worth mentioning" section (max 3 items).

## Output
Follow the findings format in references/adversarial-pair.md. Start with the 1-line Overall summary.

## Diff
<paste diff here>
```

## Synthesis by the main thread (after both return)

1. Merge both reports into a single list, grouped by file then severity.
2. Where both reviewers raised the same issue, keep the finding with the more concrete repro / fix — delete the duplicate. Add a note: `(both reviewers flagged this)` — that's a strong signal.
3. Where reviewers disagree, prefer the one with a citable file:line and a concrete fix. If both meet that bar, include both findings and flag them as "divergent review" for the user to arbitrate.
4. Apply fixes per the user's termination strategy (captured in T4 of Phase 2).
