# Review scopes: baseline catalog + dynamic-scope triggers

The adversarial review pair needs scope assignments per reviewer. This file catalogs the four baseline scopes and the trigger table for synthesizing 1–2 **dynamic** scope suggestions specific to the actual diff.

## The four baseline scopes

Every `plan-build-review` review offers these four as multi-select options. Reviewers can share scopes — overlap surfaces divergence, which is a feature.

### 1. Correctness, regressions, & test coverage

- Does the implementation match the approved plan?
- Any bugs, broken invariants, or off-by-one errors?
- Are existing tests still passing? Any regressions in adjacent behavior?
- What edge cases / failure modes aren't tested?
- Mocks where real implementations would catch more (e.g., database mocks where integration tests should run)?

### 2. Architecture, design, & readability

- Is the abstraction level right for the task, or is this over/under-engineered?
- Coupling and layering: does the change respect existing module boundaries?
- Does it fit the patterns already used in this area, or does it drift?
- Names that mislead, comments that rot, non-obvious decisions without context.
- Dead code, unused imports, stubs left behind.

### 3. Security, data integrity, & safety

- Input validation, auth checks, tenant / RLS isolation.
- Secrets handling — nothing hardcoded, no leaks into logs.
- SQL injection, XSS, prototype pollution, unsafe deserialization.
- Destructive operations: migrations, DELETE statements, file deletions — are they reversible or guarded?
- External API calls — timeouts, retries, idempotency?

### 4. Performance, UX, & accessibility

- Hot paths: N+1 queries, unnecessary renders, expensive sync work on the UI thread.
- Bundle / memory / cache invalidation concerns.
- Dark-theme conformance, mobile safe-area, keyboard nav.
- Loading states, error states, empty states — all handled?
- Color contrast, ARIA labels, focus management.

## Dynamic scope triggers

After implementation but before the scope picker, inspect `git diff`. If any of these patterns appear, **suggest the matching dynamic scope** alongside the 4 baselines (1–2 dynamic scopes max — pick the most load-bearing).

| If diff touches… | Suggest dynamic scope |
|---|---|
| `drizzle/migrations/` or `*/migrations/*.sql` | Migration rollback + forward-compat safety |
| New table definition with `tenant_id` column | RLS policy correctness (is the policy present? does it force?) |
| `src/app/(app)/**` or similar app-shell routes | Dark-theme conformance + mobile safe-area compliance |
| New route file under `src/app/api/` or similar API dir | Zod validation at boundary + tenant-context wrapper usage |
| React components with hooks | Re-render correctness + effect-dependency arrays |
| `.env*` files modified | Secrets handling + config surface consistency across environments |
| New third-party dependency added (`package.json`) | Supply-chain risk + license compatibility + bundle impact |
| Auth-related files (`auth/`, `session`, `login`) | Session lifecycle + token storage + CSRF |
| CI config (`.github/workflows/`, `firebase.json`) | CI/CD blast radius + secret exposure |
| Large refactor (>10 files changed) | Abstraction coherence + dead-code sweep |

If the diff doesn't match any trigger, skip dynamic scopes and offer only the 4 baselines.

## How to phrase dynamic scope suggestions to the user

Frame them as a recommendation, not a requirement:

> "Based on the diff, I'd suggest adding **RLS policy correctness** as an extra review scope — you added a new table with `tenant_id`. Include it?"

Let the user accept or skip per suggestion.

## Note on the `AskUserQuestion` 4-option cap

`AskUserQuestion` caps each call at 4 options. The 4 baseline scopes alone equal the cap, so any time you add a dynamic scope suggestion **you must split into two `AskUserQuestion` calls per reviewer**:

1. First call: present the 4 baseline scopes (multi-select).
2. Second call: present the 1–2 dynamic scope suggestions plus a "None, proceed" option.

Total per reviewer: up to 2 `AskUserQuestion` calls. For both reviewers: up to 4 calls. This is expected; do not try to cram options into a single call.
