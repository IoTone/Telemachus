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

  Endpoints: `/health`, `/api/bootstrap`, `/api/login`, `/api/2fa/enable`,
  `/api/whoami`, `/api/members`, `/api/admin/status`, `/api/notes…`,
  `/api/ai/echo`, `/api/usage`, `/api/quota`.

45 unit tests pass (21 engine + 8 RBAC + 6 localization + 4 auth + 3 notes + 3
quota/governor) + an 18-assertion server integration test (`test/server-smoke.sh`),
which includes a live proof that the governor never exceeds the concurrency cap.

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
racket server/main.rkt              # http://127.0.0.1:8080  (sqlite in ./data)
bash   test/server-smoke.sh         # integration test (temp DB, 11 assertions)
```

Demo flow — RBAC + localization end to end:

```bash
curl -s localhost:8080/health
# first run: create the operator + a token
OP=$(curl -s -X POST localhost:8080/api/bootstrap -d '{"username":"alice"}' \
     | grep -oP '"token":\s*"\K[^"]+')
curl -s localhost:8080/api/whoami       -H "Authorization: Bearer $OP"   # is_operator:true
curl -s localhost:8080/api/admin/status -H "Authorization: Bearer $OP"   # ok
# add a member, then watch RBAC deny admin — localized by Accept-Language
BOB=$(curl -s -X POST localhost:8080/api/members -H "Authorization: Bearer $OP" \
      -d '{"username":"bob","role":"member"}' | grep -oP '"token":\s*"\K[^"]+')
curl -s localhost:8080/api/admin/status -H "Authorization: Bearer $BOB"                        # Forbidden: instance:manage
curl -s localhost:8080/api/admin/status -H "Authorization: Bearer $BOB" -H 'Accept-Language: ja' # 禁止されています: instance:manage
```

## Dev setup

Requires Racket 9.x CS (`racket --version`).

```bash
# from refimpl/racketmaximus/ — link local packages so `(require cli-kit)` resolves
raco pkg install --link pkgs/cli-kit pkgs/db-kit pkgs/web-kit

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
> global. If you also have the Odysseus checkout's copies linked, unlink those
> first (`raco pkg remove cli-kit db-kit web-kit`) or link only one project's at
> a time.

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
