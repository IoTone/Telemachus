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
  config.rkt       # the only app-branded shared module (paths, version, app db)
  info.rkt         # the `telemachus` app collection
  test/            # rackunit suites + scripted mock-LLM server
  cli/             # (planned) telemachus-* command-line tools
  server/          # (planned) the HTTP surface
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

29 tests pass (21 engine + 8 RBAC/persistence).

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
