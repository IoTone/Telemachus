# Telemachus — working notes for Claude

Telemachus is a clean-MIT, team-oriented, self-hosted, privacy-first, Racket-first
platform for hosting AI tools & apps (the successor to the Python "Odysseus"). Pure
OSS: no open-core, no held-back tier. Concepts may be reused from Odysseus; **only
owner-authored Racket + owner-authored docs** may be carried over (see
`docs/provenance/` if present, and `docs/design/`).

## Layout

- Design docs at the repo root and under `docs/` (`docs/design/`, `docs/FeatureRequirements.md`).
- Implementation lives under `refimpl/<name>/`. The reference impl is
  **`refimpl/racketmaximus/`** (Racket 9.2 CS). A second impl may later target the
  same contracts — the durable product is the SDK contract, APIs, security model, protocols.
- Copyright: IoTone, Inc. (MIT).

## Build / test (run from `refimpl/racketmaximus/`)

Racket is linuxbrew **minimal-racket 9.2 CS** (apt Racket is only 8.2 — don't use it):

```sh
export PATH="$HOME/.linuxbrew/opt/minimal-racket/bin:$PATH"
export PLTCOLLECTS="$(pwd)/pkgs:"        # REQUIRED — pkgs/{cli-kit,db-kit,web-kit} collide with any linked Odysseus copies
raco make server/main.rkt                # precompile before running/smoke (startup is slow otherwise)
raco test test/*-tests.rkt               # the unit suite
```

- **Never `raco test test/*.rkt`** — the glob pulls in `test/mock-*.rkt`, which are
  mock *servers* that block forever. Use `test/*-tests.rkt`.
- After changing a module's **exports**, `raco make` the test files too, or a stale
  `.zo` throws "reference to a variable that is not exported".
- Migrations: `domain/db/migrations.rkt` (`all-migrations` list, applied at startup).
  Keep SQL dialect-neutral (SQLite now, PostgreSQL target): quote reserved words
  (`"window"`), portable epoch columns for time windows, `db-dialect`-aware clauses.
  `pkgs/db-kit/portable.rkt` is a drop-in for `(require db)` that rewrites `?`→`$n`
  on Postgres — always `(require db-kit/portable)`, not `(require db)`.

## Running the server

```sh
export DATABASE_URL="sqlite:///$PWD/data/telemachus.db"   # or postgres://user:pass@host:port/db
export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions   # OpenAI-compat (ollama)
export TELEMACHUS_MODEL=qwen2.5:7b
export TELEMACHUS_HOME=login              # or `beta` to serve the beta funnel at /
export PORT=8080
racket server/main.rkt
```

- **`TELEMACHUS_MODEL_URL` is required for real model calls** — without it `run-chat`
  silently uses a *simulated* uppercase-echo fallback (a real gotcha: the LLM judge/agent
  will look "broken" — no model was ever called).
- The server **caches `static/index.html` at startup** — restart to pick up UI edits.
- Local model: ollama on `:11434`, `qwen2.5:7b` (tool-calling works; avoid qwen3.5
  "reasoning" models — the answer lands in a `reasoning` field). Warm it before e2e.

## e2e (Playwright) — `refimpl/racketmaximus/test/e2e/`

```sh
export PATH=~/.nvm/versions/node/v24.18.0/bin:$PATH   # box default node is v16 (too old)
node beta-tour.mjs        # drives a live server, writes catalog/beta/*.png + manifest.json
node build-catalog.mjs beta "<title>" "<subtitle>" "<footer>"   # → catalog/beta/catalog.html
```

- Use **plain Playwright** (`import { chromium } from '@playwright/test'`) — the
  `@playwright/test` *runner* hangs in this env (buffered, zero output).
- Launch chromium with `['--no-sandbox','--disable-dev-shm-usage']`.

## Environment constraints (this sandbox)

- **No root**; `sudo` is broken (`sudoers_audit` plugin fails). No Docker (no root).
  glibc 2.35 (too old for the brew Postgres bottle). To run live Postgres, use a host
  with working sudo → `apt install postgresql` — **do NOT use conda/brew** (see the
  deterministic-deps tenet: no "python spice kitchen").
- The **Bash tool** reaps `&`-backgrounded procs when the call returns and blocks
  foreground `sleep` — run long-lived servers via `run_in_background`, poll with a
  bounded `curl` loop.
- **`pkill` self-match footgun:** `pkill -f '<pat>'` also matches the *current*
  command's own line. `pkill -f server/main; raco make server/main.rkt` kills its own
  shell (exit 144). Kill in a **standalone** command, and prefer a bracket pattern
  (`[s]erver/main`) — but only when the literal doesn't appear elsewhere in the command.

## Beta onboarding subsystem

Skinnable, admin-configurable, plugin-owned funnel — see
`docs/design/beta-onboarding-experience.md`. Core captures leads + resists abuse +
stores the experience; the plugin owns fields/copy/theme/frontend. Three render tiers,
all through one anti-abuse gate: **A** built-in themeable shell, **B** custom plugin
bundle (`/beta/bundle/<plugin>/` + `window.Telemachus.beta` SDK), **C** sandboxed HTML
template (`/beta/template`). ENV seeds first-boot defaults (`TELEMACHUS_ONBOARDING`,
`TELEMACHUS_ONBOARDING_FILE`); a published DB experience then wins.

## Git

- Commit/push only when asked. Branch before committing on the default branch.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
