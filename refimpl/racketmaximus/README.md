# racketmaximus — Telemachus Racket reference implementation

The first-prototype backend, in Racket, and the first entry under the repo's
`refimpl/` (reference implementations of the same contracts; others may follow in
other languages). Layout: reusable, spin-out-able packages under `pkgs/`;
app-specific glue in `config.rkt`; CLIs and the HTTP server added on top.

```
refimpl/racketmaximus/
  pkgs/            # app-agnostic, publishable libraries
    cli-kit/       #   JSON-emitting CLI scaffolding (run harness, pretty JSON)
    db-kit/        #   DATABASE_URL → connection + coercers + migration runner
    web-kit/       #   thin JSON-API helpers over web-server
  domain/          # the SDK engine, persistence, RBAC, (later) tool impls
    tools/
      dsl.rkt      #   the define-tool macro → OpenAI-compatible schemas
      convert.rkt  #   native function-call → tool-block converter
    agent/
      loop.rkt     #   pure run-agent spine (effects #:llm / #:exec injected)
      llm.rkt      #   OpenAI-compatible chat adapter (blocking + SSE)
      prompt-security.rkt  # untrusted-context wrapper
    db/            #   ids (UUIDv4) + schema migrations
    authz/         #   RBAC: permission catalog + AuthzService
    i18n/          #   Localizer (ICU MessageFormat), catalogs, lint/extract
  surface/         # user-facing strings, localized via `t` — the l10n surface
  locales/         # message catalogs: en.json (base) + ja.json …
  cli/
    telemachus-localize.rkt  # extract / sync-locale / check / report (CI gate)
  config.rkt       # the only app-branded shared module (paths, version, app db)
  info.rkt         # the `telemachus` app collection
  test/            # rackunit suites + scripted mock-LLM + server smoke test
  server/
    main.rkt       # HTTP surface: RBAC-gated, localized JSON API
```

## Implemented so far

- **Engine nucleus** — `define-tool` DSL, pure `run-agent` spine, OpenAI-compatible
  LLM adapter, untrusted-context wrapper.
- **Persistence** — `db-kit/migrate` (ordered, idempotent, transactional migrations
  in `schema_migrations`) + UUIDv4 ids; schema migration `0001-core`.
- **RBAC (slice 1)** — `AuthzService`: teams/memberships/roles/permissions, the
  operator tier (`instance:*` operator-only), `can?`/`require-perm`, resource
  grants (sharing), API tokens capped by *issuer-perms ∩ scopes*, and an audit log.
  See `docs/design/rbac-and-teams.md`.
- **Localization (slice 2)** — a `Localizer` (`t`/`no-i18n`) with an ICU
  MessageFormat subset (interpolation, plurals, select) and locale fallback
  (`es-419 → es → en`); JSON catalogs with source-hash staleness; a reader-based
  linter that flags unlocalized literals; and the `telemachus-localize` CLI
  (`extract`/`sync-locale`/`check`/`report`) that gates commits. English is the
  externalized baseline; `ja`/`nl`/`es-419` are produced by the tool. See
  `docs/design/localization.md`.
- **HTTP server (slice 3)** — `web-kit`-based JSON API wiring RBAC + the Localizer:
  identity from `Authorization: Bearer` (issuer∩scopes) or a trusted
  `X-Telemachus-User`/`-Team` header; per-request locale from `Accept-Language`;
  `require-perm` guards → **localized** 401/403.
- **Auth (slice 4)** — real password hashing (**PBKDF2-HMAC-SHA1**, RFC-6070
  verified) and **TOTP 2FA** (RFC-6238), both self-contained (built-in `sha1`, no
  native deps); `POST /api/login` (password + optional `code`), `POST /api/2fa/enable`.
- **Notes (slice 5)** — the first ownable/shareable resource, end to end through
  RBAC: `team`/`private`/`shared` visibility, owner-implicit rights, and
  `resource_grants` sharing. `POST/GET /api/notes`, `GET/PUT/DELETE /api/notes/:id`,
  `POST /api/notes/:id/share`.

- **Quotas + AI governor (slice 6)** — per-team quota limits (tokens/requests/day,
  concurrency) with a usage ledger, and a semaphore-based **concurrency governor**
  so AI jobs queue instead of overrunning the host. An `/api/ai/echo` job flows
  RBAC → quota check → governor slot → meter; over budget → **429**. Plus
  `GET /api/usage`, `POST /api/quota` (operator).

- **Model executor (slice 7)** — `POST /api/ai/chat` calls a real OpenAI-compatible
  model (llama-server / ollama / vLLM) via `TELEMACHUS_MODEL_URL`, through the same
  quota + governor path; falls back to a simulated reply when unset, so it runs
  anywhere. `GET /api/ai/model` reports config.

  Endpoints: `/health`, `/api/bootstrap`, `/api/login`, `/api/2fa/enable`,
  `/api/whoami`, `/api/members`, `/api/admin/status`, `/api/notes…`,
  `/api/ai/echo`, `/api/ai/chat`, `/api/ai/model`, `/api/usage`, `/api/quota`.

- **Web UI (slice 8)** — a self-contained single-page dashboard served at `/`
  (vanilla HTML/CSS/JS, no build step): login + 2FA, first-run bootstrap, AI chat,
  notes (create / share / delete), team members, quota & usage, admin — with an
  **EN / 日本語 toggle** that localizes both the UI chrome and the server's error
  messages (via an `X-Telemachus-Locale` header). `GET /api/members` lists the
  team; `GET /` serves the UI.

- **Streaming chat (slice 9)** — `POST /api/ai/chat/stream` streams tokens as
  Server-Sent Events (still through RBAC → quota → governor, metered at the end);
  the UI renders them live token-by-token.
- **Hardening (slice 10)** — **TLS**: `TELEMACHUS_TLS=1` serves HTTPS, auto-
  generating a self-signed cert (openssl) on first run. **KDF**: password hashing
  is a versioned, prefix-dispatched provider — **argon2id** auto-engages when the
  `crypto` package is installed (self-tested at load), else hardened **PBKDF2**
  (100k iters). `GET /health` reports `{tls, kdf}`.

- **Agent mode (slice 11)** — `POST /api/agent` (SSE): the model uses **tools**
  to operate the platform (`create_note`, `list_notes`, `get_usage` to start),
  each **RBAC-checked at dispatch** and quota-metered, run through the pure
  `run-agent` spine. Streams the thinking, each tool call + result, and the final
  answer. This is the seed of the plugin SDK: a new tool = a `define-tool` schema
  + a permission + a handler. `domain/agent/{tools,run}.rkt`.

- **Plugin tool SDK + activation (slice 12)** — a **tool registry**
  (`domain/agent/registry.rkt`): a tool is `register-tool!(name, schema,
  permission, handler)` — the whole contract for extending the platform, first-
  or third-party. Tools are **activatable per team** (`tool_settings`, default on);
  the agent only offers enabled tools and dispatch re-checks. Manage via
  `GET /api/tools` + `POST /api/tools/:name` (settings:manage) and a Tools card in
  the Usage tab. Built-ins: `create_note`, `update_note`, `list_notes`, `get_usage`.

- **Third-party plugins (slice 13)** — tools can live **out-of-tree** and load at
  startup from a `plugins/` directory (`domain/agent/plugins.rkt`, `TELEMACHUS_PLUGINS`
  to override). A plugin is a folder with `plugin.json` + a Racket module that
  `(provide tools)` — `(list (list name schema permission handler) …)`. They register
  through the same registry, so they get RBAC + per-team activation, tagged with the
  plugin id as `source`. `GET /api/plugins` lists them; the Tools card shows a 🔌
  source badge. Ships an `example-tools` plugin (`word_count`).

- **MCP support (slices 14–15)** — an **MCP client** (`domain/mcp/`, JSON-RPC 2.0)
  over **two transports**: **stdio** (subprocess) and **Streamable HTTP** (POST +
  json/SSE response, `Mcp-Session-Id`). Connects to external Model Context Protocol
  servers at startup, lists their tools, and registers each as `mcp__<server>__<tool>`
  — so **any MCP server's tools become agent tools**, with the same RBAC + activation.
  Configure in `mcp.json` — a `command`+`args` entry (stdio) or a `url` entry (HTTP);
  `TELEMACHUS_MCP` overrides; `GET /api/mcp`. Ships Racket mock MCP servers
  (`test/mock-mcp{,-http}.rkt`); the stdio one is wired by default so the agent can
  call `mcp__mock__add`.

- **Sandboxed out-of-process plugins (slice 16)** — untrusted plugins run as
  **subprocesses with no database handle** (`domain/oop/host.rkt`). A plugin declares
  its tools and the capability **scopes** it needs; to touch the platform it asks the
  host over the pipe, and the host runs the request through a small **capability API**
  that is **double-gated**: the plugin must have declared the scope **and** the calling
  user must hold the matching RBAC permission (`notes.create` → `notes:write`, etc.).
  Configure in `oop.json` (`TELEMACHUS_OOP` overrides); `GET /api/oop` lists plugins +
  their declared scopes (visible consent); the Tools card shows a 🛡️ badge. Ships a
  `notes-helper` plugin that saves an idea **only** via the mediated `notes.create`
  capability — it never sees the DB.

- **Translation app (slice 17)** — the first user-facing **app** on the platform
  (`domain/apps/translate.rkt`): translate text via the model with a team **glossary**
  for consistent terminology and a team-scoped history; every call is metered through
  the normal AI quotas + concurrency governor. `POST /api/translate`, `GET /api/translate`
  (history), `POST/GET /api/glossary`. The model call is injected, so the app is fully
  unit-tested without a live model. **Dogfood:** `POST /api/translate/catalog` translates
  a whole locale catalog (keys unchanged, `{placeholders}`/ICU preserved) — the engine
  behind producing our ja/nl/es-419 files. UI: a **Translate** tab (source → target,
  glossary editor, recent).

- **Executor federation (slice 18)** — the pluggable compute seam (`domain/exec/federation.rkt`).
  The reference impl runs on one local node, but you can register additional **named
  executors** — extra OpenAI-compatible backends (a second GPU box, a remote inference
  node, an HPC gateway) — in `executors.json` (`TELEMACHUS_EXECUTORS`). `run-chat` routes
  to a named backend via `#:executor`; `POST /api/ai/chat {…, "executor":"gpu-node"}` picks
  one (operator-gated — routing to specific compute is an `instance:manage` decision).
  `GET /api/executors` lists local + federated; the Admin tab shows a Compute table.
  Standing up real remote/HPC compute plugs in behind this seam without touching call sites.

- **Hosted onboarding (slice 19)** — a `saas` mode for running one isolated instance
  per tenant (`domain/saas/onboarding.rkt`, migration `0006`). `TELEMACHUS_MODE=saas`
  disables the interactive bootstrap; the control plane calls `POST /api/provision`
  (provision-token auth, idempotent per `provision_id`) to **seed exactly one owner**
  in an `invited` state with plan quotas, and the owner claims a one-time
  **magic-link** (`/api/activate`) to set a password and go `active`.
  `POST /api/instance/{suspend,resume}` flip tenant status (suspended = writes `402`,
  reads OK). Boot-env seeding (`TELEMACHUS_SEED_*`) covers VM launches.
  See [docs/design/saas-onboarding.md](../../docs/design/saas-onboarding.md).

- **Platform batch (slices 20–26)** — provider-token **tenant quota** endpoint
  (billing lifecycle); **API tokens** (issue/list/revoke, scoped, audited); **audit
  log** surfaced (read API + Team "recent activity"); **search** across notes +
  documents + translations (RBAC-filtered); **per-team feature flags** (activate/
  deactivate chat·agent·translate·search, enforced + tab-hiding); **operator
  metrics** (`GET /api/metrics`); **documents** (paginated ownable resource behind
  the research/translation apps).

- **Async workload scheduler (slice 27)** — an AI **jobs queue** with a bounded
  worker pool (`domain/sched/scheduler.rkt`, migration `0009`). Submit deferred work
  (`POST /api/jobs {kind,payload}` → `202`), poll it (`GET /api/jobs/:id`), list, and
  cancel queued jobs. Work is *claimed atomically* (no double-run), run by a fixed
  pool of N threads (kinds: `chat`, `translate`), and status/result recorded.
  `process-one!` is synchronous so the async path is deterministically tested. A Jobs
  tab submits + polls. See [docs/design/ai-queue-and-concurrency.md](../../docs/design/ai-queue-and-concurrency.md).

- **Job fairness + quota metering (slices 28–29)** — the pool claim skips a team
  already at its `ai.concurrency` cap (no team monopolizes the workers), and job runs
  are metered against the normal AI quotas: an over-budget team's jobs **defer**
  (stay queued) and successful runs bill tokens + a request — the queue is not a
  budget bypass.

- **Agent jobs + sample data (slices 30–31)** — an `agent` job kind runs full
  tool-loop flows through the queue (deferred + metered), returning
  `{reply, rounds, tools}`. An operator **"Load sample data"** action
  (`POST /api/admin/seed`, Admin console) populates a team with sample notes,
  documents, and queued chat/translate/agent jobs — instant functionality to test.

- **PostgreSQL backend (slice 32)** — the same code runs on **SQLite _or_
  PostgreSQL**, chosen by one `DATABASE_URL` (`sqlite:///…` or
  `postgres://user:pass@host:port/db`); `db-kit`'s connector dispatches the backend
  and no app code branches on it. `db-kit/portable` re-exports `db` but rewrites
  `?`→`$n` placeholders for Postgres (SQLite unchanged), so callers stay
  backend-neutral. Schema + queries are dialect-neutral (one reserved-word fix:
  `"window"`); the few dialect-specific spots — quota time-windows, upsert-ignore,
  activation expiry — are `db-dialect`-aware or computed in Racket, and timestamps
  use portable epoch/`CURRENT_TIMESTAMP`. **The full server smoke passes against
  Postgres 18** as well as SQLite.

- **Beta onboarding (slices 33–34)** — a pre-sales **qualification funnel** that
  captures prospects **without creating accounts**, vets each with an **LLM judge**
  ({valid, score, revenue estimate, reasoning} via a metered `beta_judge` job), and
  lets the team owner **review / qualify / reject**. Root-route **home routing**
  (`TELEMACHUS_HOME=beta`) makes the default experience the beta landing page instead
  of login. The onboarding experience (copy, form fields, judge prompt) is a
  **pluggable provider** — customized via the SDK's new plugin `init!` hook (see the
  `beta-onboarding` example plugin).

- **Anti-abuse for the public signup (slice 35)** — self-hosted, dependency-free
  defense-in-depth so the open beta endpoint can't flood the DB or burn LLM tokens
  (`domain/beta/antispam.rkt`), all checked *before* any write/spend: per-IP + global
  **rate limit**, a **signed single-use challenge** (`GET /api/beta/challenge`, kills
  direct-POST spam + replay), a **honeypot** field, a **min fill-time** gate, a
  **proof-of-work** (hashcash over an FNV hash matched byte-for-byte in Racket + JS,
  so it works over plain HTTP with no SubtleCrypto or third-party CAPTCHA), and cheap
  **email/disposable-domain** heuristics, and **per-email / per-domain velocity caps**
  (portable epoch window). Blocked-reason **counters** surface to owners, and each
  signup's **anti-abuse signals** (domain velocity, free-email) are fed into the LLM
  judge so borderline prospects are scored more skeptically.

106 unit tests pass + a 77-assertion server integration test (green on SQLite **and** Postgres)
(`test/server-smoke.sh`), incl. a live proof the governor never exceeds the cap.
**Open http://localhost:8835** after `racket server/main.rkt`.

- **End-to-end feature tour (`test/e2e`)** — a headless Playwright walk through the
  whole UI against a real running server: bootstrap → chat → agent tool use →
  translation → notes → teams/RBAC → quotas & tool registry → federated compute →
  Japanese localization. It asserts each state and assembles a self-contained
  **screenshot catalog** (`bash test/e2e/run.sh` → `catalog/catalog.html`).

### Writing a plugin

```
plugins/my-plugin/plugin.json    {"id":"my-plugin","name":"…","version":"0.1.0","entry":"main.rkt"}
plugins/my-plugin/main.rkt       #lang racket/base
                                 (provide tools)   ; (list (list name schema-jsexpr permission handler) …)
                                 ; handler : (conn principal args) -> string
```

Drop the folder in `plugins/`, restart — the tool appears in `/api/tools`, is
RBAC-checked, activatable per team, and usable by the agent. (In-process plugins
run with platform trust; installing one is the consent. Sandboxed out-of-process
plugins are future hardening.)

Point at a real model (chat answers come from it, metered + governed):

```bash
TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
TELEMACHUS_MODEL=qwen2.5:7b  racket server/main.rkt
```

Serve over HTTPS (self-signed cert auto-generated in `data/`); install argon2id:

```bash
TELEMACHUS_TLS=1 racket server/main.rkt          # https://localhost:8835
raco pkg install crypto                          # → password hashing auto-upgrades to argon2id
```

### Localization CLI

```bash
# build the English base catalog from the surface modules
racket cli/telemachus-localize.rkt extract surface --locales locales
# scaffold a target locale (all strings empty), then translators fill them
racket cli/telemachus-localize.rkt sync-locale ja surface --locales locales
# coverage per locale
racket cli/telemachus-localize.rkt report surface --locales locales
# CI gate — fails (exit 1) on unlocalized literals; --required makes a locale blocking
racket cli/telemachus-localize.rkt check surface --locales locales
```

Wire `check` as a git pre-commit hook or CI step:

```bash
# .git/hooks/pre-commit
exec racket refimpl/racketmaximus/cli/telemachus-localize.rkt \
     check refimpl/racketmaximus/surface --locales refimpl/racketmaximus/locales
```

### HTTP server

```bash
racket server/main.rkt              # http://127.0.0.1:8835  (sqlite in ./data)
bash   test/server-smoke.sh         # integration test (temp DB, 11 assertions)
```

Demo flow — RBAC + localization end to end:

```bash
curl -s localhost:8835/health
# first run: create the operator + a token
OP=$(curl -s -X POST localhost:8835/api/bootstrap -d '{"username":"alice"}' \
     | grep -oP '"token":\s*"\K[^"]+')
curl -s localhost:8835/api/whoami       -H "Authorization: Bearer $OP"   # is_operator:true
curl -s localhost:8835/api/admin/status -H "Authorization: Bearer $OP"   # ok
# add a member, then watch RBAC deny admin — localized by Accept-Language
BOB=$(curl -s -X POST localhost:8835/api/members -H "Authorization: Bearer $OP" \
      -d '{"username":"bob","role":"member"}' | grep -oP '"token":\s*"\K[^"]+')
curl -s localhost:8835/api/admin/status -H "Authorization: Bearer $BOB"                        # Forbidden: instance:manage
curl -s localhost:8835/api/admin/status -H "Authorization: Bearer $BOB" -H 'Accept-Language: ja' # 禁止されています: instance:manage
```

## Dev setup

Requires Racket 9.x CS (`racket --version`).

```bash
# from refimpl/racketmaximus/ — resolve the local pkgs/ so `(require cli-kit)` works.
# Required for every racket/raco command; export it once per shell.
export PLTCOLLECTS="$(pwd)/pkgs:"

# compile everything
raco make config.rkt pkgs/*/main.rkt pkgs/db-kit/migrate.rkt \
         domain/tools/*.rkt domain/agent/*.rkt domain/db/*.rkt domain/authz/*.rkt

# run the test suites (29 cases: engine + RBAC/persistence)
raco test test/engine-tests.rkt test/authz-tests.rkt
```

The agent spine is pure: `run-agent` takes its `#:llm` and `#:exec` as injected
effects, so it runs deterministically in tests without a model. `test/mock-llm.rkt`
is a tiny OpenAI-compatible server that drives the real loop over real HTTP for
end-to-end checks without ollama.

> **Note:** the package collection names (`cli-kit`, `db-kit`, `web-kit`) are
> global, and the Odysseus checkout ships its own diverged copies under the same
> names — so **don't `raco pkg install --link` them**. A global link silently wins
> over `PLTCOLLECTS` for whichever project didn't set it, compiling against the
> wrong sources. `PLTCOLLECTS` alone (used by the scripts, CI, and the runbooks)
> keeps each checkout self-contained; if a kit is ever linked globally, remove it
> with `raco pkg remove cli-kit db-kit web-kit`. With no links, a forgotten
> `PLTCOLLECTS` fails loudly with `collection not found`.

## Provenance

`pkgs/`, `config.rkt`, and the `domain/` engine are original Racket authored by
the maintainer — no third-party source is copied. The agent-loop / tool-execution
*patterns* in `domain/agent/loop.rkt` and `domain/tools/convert.rkt` descend from
opencode (MIT); that design lineage is credited in `../../ACKNOWLEDGMENTS.md`,
which satisfies the MIT attribution requirement. Rationale and the fuller plan
live in `../../../odysseus/TelemachusMigration.md`.

## Data layer

SQLite for prototyping; PostgreSQL is the target. The backend seam lives in
`pkgs/db-kit/` so callers stay backend-neutral — `config.rkt` resolves a
`DATABASE_URL` and never assumes sqlite-only semantics upstream of db-kit.
