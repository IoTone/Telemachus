# Telemachus — Racket prototype

The first-prototype backend, in Racket. Layout mirrors a strangler-free
greenfield: reusable, spin-out-able packages under `pkgs/`; app-specific glue in
`config.rkt`; CLIs and the HTTP server added on top.

```
racket/
  pkgs/            # app-agnostic, publishable libraries
    cli-kit/       #   JSON-emitting CLI scaffolding (run harness, pretty JSON)
    db-kit/        #   DATABASE_URL → connection + SQL coercers (sqlite today)
    web-kit/       #   thin JSON-API helpers over web-server
  config.rkt       # the only app-branded shared module (paths, version, app db)
  info.rkt         # the `telemachus` app collection
  cli/             # (planned) telemachus-* command-line tools
  server/          # (planned) the HTTP surface
  test/            # (planned) rackunit + scripted mock-LLM
```

## Dev setup

Requires Racket 9.x CS (`racket --version`).

```bash
# from racket/ — link the local packages so `(require cli-kit)` etc. resolve
raco pkg install --link pkgs/cli-kit pkgs/db-kit pkgs/web-kit

# compile everything
raco make config.rkt pkgs/*/main.rkt
```

> **Note:** the package collection names (`cli-kit`, `db-kit`, `web-kit`) are
> global. If you also have the Odysseus checkout's copies linked, unlink those
> first (`raco pkg remove cli-kit db-kit web-kit`) or link only one project's at
> a time.

## Provenance

`pkgs/` and `config.rkt` are original, app-agnostic Racket authored by the
maintainer — no third-party source. Attribution obligations (opencode, etc.)
attach only to later modules that reproduce adapted patterns; see
`../../odysseus/TelemachusMigration.md`.

## Data layer

SQLite for prototyping; PostgreSQL is the target. The backend seam lives in
`pkgs/db-kit/` so callers stay backend-neutral — `config.rkt` resolves a
`DATABASE_URL` and never assumes sqlite-only semantics upstream of db-kit.
