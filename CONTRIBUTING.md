# Contributing to Telemachus

Thanks for helping build Telemachus — a clean-MIT, self-hosted, privacy-first team
AI platform. This guide covers the reference implementation in
[`refimpl/racketmaximus`](refimpl/racketmaximus) (Racket-first, minimal Python).

## Ground rules

- **Licensing.** Telemachus is MIT. Only contribute code you wrote or can license
  under MIT — no copied code with incompatible terms.
- **Localize everything user-facing.** No bare string literals in the surfaces
  (`refimpl/racketmaximus/surface/`) — every user-visible string goes through the
  i18n layer and into the locale catalogs (`locales/`). The CI gate enforces this.
- **Authorize every endpoint.** New API routes must go through the AuthzService
  (`require-perm` / `can?`); new agent tools register with a permission.
- **Tests come with the feature.** New behavior ships with a `test/*-tests.rkt`.

## Prerequisites

- **Racket CS**, full distribution (provides `db`, `web-server`, `rackunit`).
- **Node 18+** and **Playwright** — only for the end-to-end tour (`test/e2e`).
- A local OpenAI-compatible model (e.g. `ollama`) is optional; without one the
  server uses a deterministic fallback, so all tests still pass.

Local packages under `pkgs/` are resolved via `PLTCOLLECTS` — set it before any
`raco` command (run everything from `refimpl/racketmaximus`):

```bash
cd refimpl/racketmaximus
export PLTCOLLECTS="$(pwd)/pkgs:"
```

## The checks (what CI runs)

```bash
# 1. Compile
raco make server/main.rkt

# 2. Unit tests
raco test \
  test/engine-tests.rkt test/authz-tests.rkt test/i18n-tests.rkt \
  test/auth-tests.rkt test/notes-tests.rkt test/quota-tests.rkt \
  test/executor-tests.rkt test/agent-tests.rkt test/plugin-tests.rkt \
  test/mcp-tests.rkt test/oop-tests.rkt test/translate-tests.rkt \
  test/federation-tests.rkt

# 3. HTTP server integration smoke
bash test/server-smoke.sh

# 4. Localization gate — fails on bare literals and missing/stale required strings
racket cli/telemachus-localize.rkt check surface/messages.rkt surface/greetings.rkt --required en
```

If you touched the UI, also run the end-to-end feature tour (it boots a throwaway
server, drives the whole UI, asserts each state, and builds a screenshot catalog):

```bash
bash test/e2e/run.sh          # → test/e2e/catalog/catalog.html
```

The tour uses a modern Node from `nvm` automatically; point it at a local model
for real chat/translate output:

```bash
TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
TELEMACHUS_MODEL=qwen2.5:7b bash test/e2e/run.sh
```

## Working with translations

```bash
racket cli/telemachus-localize.rkt extract surface/messages.rkt surface/greetings.rkt   # pull keys → catalogs
racket cli/telemachus-localize.rkt sync-locale ja surface/messages.rkt                  # mark missing/stale ja strings
racket cli/telemachus-localize.rkt report surface/messages.rkt                          # coverage per locale
```

English is required at launch; Japanese, Dutch, and Latin American Spanish follow.

## Commits & pull requests

- Branch off the working branch (`dev`); keep PRs focused.
- Conventional-commit subjects (`feat(scope): …`, `fix(scope): …`, `test(…)`,
  `ci: …`), imperative mood.
- Fill in the pull-request template and make sure the checklist passes — **CI must
  be green** before merge. On public repos CI is free.

## Style

Write Racket that reads like the code around it — match the surrounding module's
naming, comment density, and idioms. Prefer small, composable functions and the
existing helpers (`env*`, `require-perm`, the registry, db-kit) over new machinery.
