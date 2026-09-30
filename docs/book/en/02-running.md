# Getting it running


## The toolchain

    nix develop                         # from the repo root; pins Racket 9.3, exports PLTCOLLECTS
    cd refimpl/racketmaximus
    raco make server/main.rkt           # precompile; startup is slow otherwise
    raco test test/*-tests.rkt          # the unit suite
    racket server/main.rkt              # http://127.0.0.1:8835

Enter the shell from the repository root, not from inside `refimpl/racketmaximus`: the shell hook builds `PLTCOLLECTS` from the current directory, and entering it one level down doubles the path and breaks every `db-kit` import with “collection not found”.

Never run `raco test test/*.rkt`. The glob includes `test/mock-*.rkt`, which are mock servers that block forever. The unit suite is `test/*-tests.rkt`.

## Environment

    DATABASE_URL=sqlite:///$PWD/data/telemachus.db   # or postgres://user:pass@host:port/db
    TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions   # any OpenAI-compatible endpoint
    TELEMACHUS_MODEL=qwen2.5:7b
    TELEMACHUS_HOME=login          # or `beta` to serve the onboarding funnel at /
    TELEMACHUS_S3_PORT=8836        # turns on the S3 endpoint, a second listener
    TELEMACHUS_MULTITENANT=1       # several companies on one instance
    PORT=8835

Without `TELEMACHUS_MODEL_URL` the platform runs a simulated model that echoes its input in upper case. Chat works, the smoke suites work, and nothing that needs real inference does. The tools that need a model — the localization drafter, the document pipeline, the knowledge-graph extractor — refuse to run rather than fail every validation with a misleading message. This is deliberate: an operator needs to read “no model configured”, not “the reply was not JSON”.

## First run

`POST /api/bootstrap` with a username and password creates the operator, the first organization and the first team, and returns the operator’s token. It works exactly once. After that, sign in at `/` or with `POST /api/login`.

## Files to open

`CLAUDE.md` at the repository root is the working notebook: every gotcha that cost an afternoon is written there, by subsystem. `flake.nix` is the toolchain. `refimpl/racketmaximus/config.rkt` is the environment.
