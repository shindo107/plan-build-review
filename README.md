# deepwork

A Claude Code skill that wraps a rigorous **think → plan → do → review** workflow around whatever implementation task you throw at it. Replaces the "paste the same planning prompt every time" pattern with a single command.

## What it does

When invoked, `/deepwork` (or `/deepwork:deepwork` when installed as a plugin):

1. **Parses args** — `commit` (default) / `push` / `deploy`, plus orthogonal `worktree`
2. **Enters plan mode** — no edits until you approve
3. **Asks clarifying questions progressively** — one tier at a time, skipping tiers whose answers are already obvious. Tiers: Intent → Scope → Implementation → Review config
4. **Explores in parallel** — up to 3 `Explore` subagents concurrently to map the codebase
5. **Designs the implementation** — delegates drafting to a `Plan` subagent, synthesizes into a final plan
6. **Implements** — tracks discrete steps via the session's task tool, parallelizes independent work
7. **Adversarially reviews** — spawns two reviewers in parallel in a single message:
   - Opus reviewer (`model: opus`) — skeptical architectural lens
   - Sonnet reviewer (`model: sonnet`) — rigorous correctness lens
   - You pick each reviewer's scope from 4 baseline categories + 1–2 dynamically-suggested scopes based on the actual diff
8. **Applies fixes** — per your chosen termination strategy (single-pass / iterate-max-2 / decide-after)
9. **Commits** — detailed commit message, specific file staging, Co-Authored-By trailer, dirty-tree check
10. **Pushes / deploys** (if requested)
11. **Prompts to merge worktree to main** (if worktree was used)

## Install

### As a plugin (recommended for other users)

```
/plugin marketplace add https://github.com/shindo107/deepwork
/plugin install deepwork@darren-ai-tools
```

Invoke as `/deepwork:deepwork`. *(Note: exact invocation syntax depends on your Claude Code version's plugin-namespacing rules — if `/deepwork:deepwork` isn't recognized, try `/deepwork` or check `/help` for the installed form.)*

### Local dev (for editing the skill itself)

Clone the repo, then symlink the skill directory into Claude Code's global skills path:

```bash
git clone https://github.com/shindo107/deepwork ~/ai-tools/deepwork
mkdir -p ~/.claude/skills
ln -s ~/ai-tools/deepwork/plugins/deepwork/skills/deepwork ~/.claude/skills/deepwork
```

Invoke as `/deepwork`. Edits to files in `~/ai-tools/deepwork/` take effect immediately — no reinstall.

## Args

| Arg | Effect |
|---|---|
| (none) | commit only |
| `commit` | commit only (explicit) |
| `push` | commit + push |
| `deploy` | commit + push + deploy (no confirmation — runs immediately) |
| `worktree` | work happens in a fresh git worktree under `.worktrees/<slug>/` on a new branch; prompts to merge to main at the end |

Args compose. Position doesn't matter. Examples:

- `/deepwork` — commit only, in place
- `/deepwork push` — commit + push, in place
- `/deepwork deploy worktree` — worktree + commit + push + deploy
- `/deepwork worktree commit` — worktree + commit (redundant `commit` is fine)

## How `deploy` resolves the deploy command

No prompt, no confirmation. Looks up the command in this order:

1. Project `CLAUDE.md` if it has a `## Deploy` section or explicit `deploy command:` line
2. `package.json` → `scripts.deploy` → runs `npm run deploy`
3. `Makefile` target `deploy` → runs `make deploy`
4. `./deploy.sh` or `./scripts/deploy.sh` (executable) → runs it
5. None found → errors and stops (doesn't guess)

Branch safety: if the current branch isn't the default (`main`), emits a one-line warning but still proceeds (per user preference).

## Review scopes

Four baseline categories the user can assign to each reviewer:

- Correctness, regressions, & test coverage
- Architecture, design, & readability
- Security, data integrity, & safety
- Performance, UX, & accessibility

Plus 1–2 **dynamic scopes** synthesized from the actual diff. Examples:

- Touched `drizzle/migrations/` → suggests **migration rollback + forward-compat safety**
- Added table with `tenant_id` → suggests **RLS policy correctness**
- Touched `src/app/(app)/**` → suggests **dark-theme + mobile safe-area conformance**

See `plugins/deepwork/skills/deepwork/references/review-scopes.md` for the full trigger table.

## Review-loop termination

Chosen at plan time (T4 of clarification):

- **Single-pass** — one review, fix blockers+highs, done
- **Iterate (max 2 rounds)** — fix, re-review, stop at 2 rounds max
- **User decides** — interactive choice after first review

## Repo layout

```
deepwork/                                             # repo = marketplace
├── .claude-plugin/
│   └── marketplace.json                              # lists deepwork plugin
├── plugins/
│   └── deepwork/                                     # plugin root
│       ├── .claude-plugin/
│       │   └── plugin.json                           # plugin manifest
│       └── skills/
│           └── deepwork/
│               ├── SKILL.md                          # main workflow
│               └── references/
│                   ├── progressive-disclosure.md     # tier definitions
│                   ├── review-scopes.md              # baseline + dynamic triggers
│                   └── adversarial-pair.md           # reviewer briefing templates
├── README.md                                         # this file
├── LICENSE                                           # MIT
└── .gitignore
```

## Contributing

Issues and PRs welcome. Keep `SKILL.md` under 300 lines; push detail into `references/` for progressive disclosure to Claude.

## License

MIT. See `LICENSE`.
