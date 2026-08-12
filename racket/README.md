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
  domain/          # the SDK engine + (later) tool implementations
    tools/
      dsl.rkt      #   the define-tool macro → OpenAI-compatible schemas
      convert.rkt  #   native function-call → tool-block converter
    agent/
      loop.rkt     #   pure run-agent spine (effects #:llm / #:exec injected)
      llm.rkt      #   OpenAI-compatible chat adapter (blocking + SSE)
      prompt-security.rkt  # untrusted-context wrapper
  config.rkt       # the only app-branded shared module (paths, version, app db)
  info.rkt         # the `telemachus` app collection
  test/            # rackunit suite + scripted mock-LLM server
  cli/             # (planned) telemachus-* command-line tools
  server/          # (planned) the HTTP surface
```

## Dev setup

Requires Racket 9.x CS (`racket --version`).

```bash
# from racket/ — link the local packages so `(require cli-kit)` etc. resolve
raco pkg install --link pkgs/cli-kit pkgs/db-kit pkgs/web-kit

# compile everything
raco make config.rkt pkgs/*/main.rkt domain/tools/*.rkt domain/agent/*.rkt

# run the engine test suite (21 cases: DSL, converter, prompt-security, loop, llm)
raco test test/engine-tests.rkt
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
opencode (MIT); that design lineage is credited in `../ACKNOWLEDGMENTS.md`, which
satisfies the MIT attribution requirement. Rationale and the fuller plan live in
`../../odysseus/TelemachusMigration.md`.

## Data layer

SQLite for prototyping; PostgreSQL is the target. The backend seam lives in
`pkgs/db-kit/` so callers stay backend-neutral — `config.rkt` resolves a
`DATABASE_URL` and never assumes sqlite-only semantics upstream of db-kit.
