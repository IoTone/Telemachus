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

**Nix is the toolchain. There is no second one.** `nix develop` from the repo root
pins Racket 9.2, exports `PLTCOLLECTS`, and adds postgres/sqlite/openssl/node.
`nix build` runs the unit suite in the sandbox; `nix flake check` adds the HTTP
smoke. Nix only sees **git-tracked** files, so `git add` a new source file before
building.

```sh
nix develop                              # from the repo root; then:
cd refimpl/racketmaximus
raco make server/main.rkt                # precompile before running/smoke (startup is slow otherwise)
raco test test/*-tests.rkt               # the unit suite
```

Run a one-off without entering the shell: `nix develop --command <cmd>`.

> **Do not use linuxbrew/homebrew — it is a proven bad path and was removed from
> these notes.** Its glibc mismatch breaks `libcrypto` (so no SHA‑256, and the
> `openssl` binary won't run), and it is the "python spice kitchen" the
> deterministic-deps tenet exists to prevent. apt Racket is 8.2 and also unusable.
> If Nix is unavailable on a box, that box is not a build host.

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
export PORT=8835                          # default; the server reads PORT / TELEMACHUS_PORT
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
  glibc 2.35 (too old for brew bottles generally — this is why brew is out). To run
  live Postgres, use a host with working sudo → `apt install postgresql`, or the
  `nix develop` shell, which already provides it — **do NOT use conda/brew** (see the
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

## Multi-tenancy (several companies on one instance)

Off by default. `TELEMACHUS_MULTITENANT=1` adds an **org** layer above teams plus two
management planes — see `docs/design/multi-tenancy.md` (decision TEN‑2, supersedes TEN).

- **superadmin** (`instance:*`, from bootstrap) runs the instance: `/api/orgs*`.
- **org admin** (`org:*`, `users.org_role_key`) runs one company: `/api/org*`.
  It **manages but does not read** team data (TEN‑2a).
- Isolation is **step 0 of `can?`** — an unconditional deny *before* permissions,
  owner-ok, token scopes and resource grants, so a share can't tunnel out of an org.
- `teams.slug` is now unique **per org** (migration `0016-orgs` rebuilds the table on
  SQLite); `users.username` stays instance-global — use email.
- Org quotas nest above team quotas (`subject_type='org'`); admission needs both.

```sh
TELEMACHUS_MULTITENANT=1 bash test/multitenant-demo.sh   # seeds 2 companies, 46 assertions
raco test test/tenancy-tests.rkt                          # the authz core, no server
```

`POST /api/admin/seed-tenants` (superadmin) seeds Acme + Globex with **known dev
passwords** (`admin@acme.test` / `acme-admin1`, etc.) — demo fixture only, never prod.

## HTTP/1.1 listener (`web-kit/http1`, slice 51)

`serve/servlet` stays the JSON control plane. `pkgs/web-kit/http1.rkt` is the data
plane — the thing that can move a 2 GB file.

- Bodies are an **input port**, not bytes. `Content-Length` and `chunked` both.
- **`Expect: 100-continue` is sent lazily, on the first read of the body.** A
  handler that refuses before reading (401/403/quota) means the client never sends
  the body at all. Measured: the AWS CLI gets its continue in **1 ms** here vs
  **16,016 ms** against `serve/servlet`, which never implements it. Do NOT "fix"
  this by sending the continue eagerly — that discards the whole point.
- Never peek at a request body port: peeking fires the continue. `body-state`
  carries started?/finished?/remaining for the keep-alive decision instead.
- The path and query stay **percent-encoded** — SigV4 signs what was sent.

```sh
raco test test/http1-tests.rkt    # 46 cases over raw TCP
```

## Document repository (binary documents, slices 49-50)

Any format in, byte-identical out, with the creator setting visibility. See
`docs/design/document-repository.md` (decisions DOC-1…DOC-17).

- `domain/repo/repo.rkt` is the ownable resource; **`can?` governs it with no new
  authorization code** — same `team_id`/`owner_user_id`/`visibility` triple as notes.
- Bytes live in a **content-addressed** store keyed by SHA-256, never in the DB.
  `domain/repo/blobs.rkt` is the seam; `plugins/rs3/` is the local filesystem one
  (`TELEMACHUS_BLOB_STORE`, default `rs3`). **The store is never handed a principal**
  — only a namespace and a digest — so a backend has no authorization to get wrong.
- The namespace is the **org id**, deliberately: global dedup across tenants is an
  existence oracle. Blob refcounts must be org-scoped too (DOC-6).
- `domain/authz/sha2.rkt` is SHA-256/HMAC-SHA256 over **libcrypto** — do NOT add it
  to `crypto.rkt`, whose contract is "no native deps". Pinned to NIST/RFC vectors.
- Uploads are a **raw `PUT` body**, not base64 in JSON. `TELEMACHUS_MAX_UPLOAD`
  (default 32 MiB) sets `web-kit`'s `#:max-body-length`; web-server's own default is
  1 MiB and it enforces it by **dropping the connection with no response at all**.
- Every download is `Content-Disposition: attachment` + `nosniff` + a denying CSP
  unless the type is on a short inline allowlist. **SVG/HTML are never inline** —
  same origin as the console means stored XSS.
- `storage.bytes` is a **gauge**: `+size` on write, `-size` on delete, window
  `"total"` (the ledger's `window-clause` falls through to `1 = 1`).

```sh
raco test test/repo-tests.rkt test/sha2-tests.rkt   # 99 cases, no server
bash test/server-smoke.sh                            # includes the repository block
```

## Workflow engine (plugins that process in steps)

Slice 46. A workflow is a **validated data spec** — that spec is the public
contract (WF‑9), and `define-workflow` is a macro that emits it, the same move
`define-tool` already makes for tools. See `docs/design/workflow-engine.md`.

- `domain/flow/spec.rkt` is **normative**: both the macro's output and a document
  posted to `/api/workflows` go through `validate-spec`. Never add a second path.
- **Unknown fields are rejected** (WF‑10), including a newer `spec` version and a
  step kind this build lacks. That refusal is the design, not a gap.
- The binding sublanguage is **frozen** (`domain/flow/bind.rkt`): references and
  seven predicates, no arithmetic, no eval. The escape hatch is "write a tool".
- Execution is a reducer: `flow-advance!` reads the run from the DB and enqueues
  the next step as a `flow.step` **scheduler job**, so durability, cancel, quota
  admission and the org gate are all inherited. Nothing lives in memory — a run
  survives a restart because the rows are the state.
- Ships `tool:<name>`, `choice` and `map` (fan-out). `agent`/`job:`/`flow:` deferred.
- A plugin may `(provide workflows)` or drop `workflows/*.json`; those specs are
  **materialized** into a team's `workflow_defs` on first lookup (`source:
  'plugin:<id>'`) — a plugin has no team at load time.
- `${principal.locale}` is `users.locale` (migration 0018), NOT `Accept-Language`.

Operator runbook: `docs/ops/workflow-engine-runbook.md`.

```sh
raco test test/flow-tests.rkt      # 20 cases, no server
bash test/server-smoke.sh          # includes publish → run → assert over HTTP
# needs a live model; refuses to start without one, on purpose:
TELEMACHUS_MODEL_URL=... bash test/translate-chat-demo.sh
```

## Git

- Commit/push only when asked. Branch before committing on the default branch.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
