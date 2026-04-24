# Repo map: format, freshness, and usage

An optional pre-computed index of the target repo, cached at `.claude/repo-map.md`. When fresh, Phase 3 Explore agents receive it as shared context and spend their budget confirming patterns + finding usages instead of re-discovering file structure from scratch.

Opt-in: users generate and refresh it manually via `scripts/generate-repo-map.sh`. The skill never generates or modifies the map automatically — that's the user's call.

## Format

The map is a single markdown file. The first line is always a freshness header comment; the body is organized by top-level directory.

```
<!-- repo-map head: <40-char-sha> -->

# Repo map

## src/

### src/index.ts
<leading file comment or docstring, if any>

- `export function bootstrap(config: AppConfig): Promise<App>` — L14
- `export class AppError extends Error` — L42

### src/db/client.ts
<leading file comment or docstring, if any>

- `export async function getClient(tenantId: string): Promise<Pool>` — L9

## scripts/
...
```

Hard rules:

- **First line** must be exactly `<!-- repo-map head: <sha> -->` where `<sha>` is the full 40-char HEAD SHA at generation time. The freshness check depends on this.
- **Section headings** use `##` for top-level directories, `###` for individual source files.
- **Per-file entries**: the leading file comment/docstring if present (one paragraph max), followed by a bulleted list of exported signatures with source line numbers.
- **No file bodies**. Signatures + line numbers only. The map is an index, not a snapshot.

## Freshness policy

A map is considered **fresh** when both conditions hold:

1. **SHA ancestor check** — the SHA in the header is an ancestor of current `HEAD`:
   ```
   git merge-base --is-ancestor <sha-from-header> HEAD
   ```
2. **No source-file drift** — no source-extension files have changed between that SHA and `HEAD`:
   ```
   git diff --name-only <sha-from-header>..HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.py' '*.go' '*.rs' '*.java' '*.rb'
   ```
   Empty output → fresh. Any output → stale.

   **Canonical extension list** — this set (11 extensions) is authoritative. The generator script's `EXTS` array, `SKILL.md`'s Phase 3 preamble, and the README's "Speeding up" section all track this list. Drift → silently stale maps.

If either check fails, the map is stale and the skill falls back to the normal Phase 3 Explore flow. The map file is not deleted — the user regenerates when convenient.

**Why SHA-based and not mtime-based**: mtime resets on `git clone` and differs between worktrees. SHA comparison is deterministic and portable across checkouts, which matters because the skill supports `worktree` mode.

## Usage from the skill

Phase 3 (see `SKILL.md`) performs the freshness check before spawning Explore agents. When fresh, each Explore agent receives the map as shared context with an instruction along the lines of:

> "A repo map is attached. Treat it as authoritative for which files exist and what they export. Spend your exploration budget confirming patterns, finding usages, and reading the specific files that matter for this task — do not re-list or re-summarize files already covered by the map."

This prevents paying for the same structural discovery twice.

## Generating and refreshing

Run the helper from **the target repo's root** (not the skill repo's root — the script generates `.claude/repo-map.md` in whatever git repo it's invoked inside):

```bash
# Local-dev install:
bash ~/ai-tools/plan-build-review/plugins/plan-build-review/skills/plan-build-review/scripts/generate-repo-map.sh

# Marketplace install (path under ~/.claude/plugins/ — exact path depends on your install):
bash ~/.claude/plugins/<plugin-install-path>/skills/plan-build-review/scripts/generate-repo-map.sh
```

The script is idempotent: running it twice in a row with no intervening source changes produces the same file (same SHA header, same signatures).

When to regenerate:

- After significant refactors that rename files or move exports.
- Before a batch of plan-build-review runs in a repo where you want the speedup.
- Never — it's strictly opt-in; the skill works fine without a map.

## Costs and tradeoffs

- **Generation** is fast (seconds for repos of a few hundred files; scales linearly).
- **Token cost during Phase 3**: the map typically runs 2–10K tokens depending on repo size. That's offset by Explore agents returning smaller summaries, so the net is slightly negative to roughly break-even on a single run and meaningfully positive across repeated runs in the same repo.
- **Staleness risk**: if source changes between generation and use, the freshness check catches it and falls back to normal exploration. The worst case is the map is silently wrong in a way the check missed — e.g., a signature changed within a file that the diff check flagged (the check is conservative: any diff in a source file marks the whole map stale). If you hit this, regenerate.
