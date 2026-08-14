#!/usr/bin/env bash
# Boot a fresh Telemachus server on a temp DB for the e2e run. Playwright's
# webServer runs this and tears it down. Points at ollama if present so chat /
# agent / translate screenshots show real model output; falls back otherwise.
set -e
cd "$(dirname "$0")/../.."                 # -> refimpl/racketmaximus (impl root)
export PLTCOLLECTS="$(pwd)/pkgs:"
: "${E2E_DATA_DIR:=$(mktemp -d)}"
export TELEMACHUS_DATA_DIR="$E2E_DATA_DIR"
export DATABASE_URL="sqlite:///$E2E_DATA_DIR/e2e.db"
export TELEMACHUS_BIND=127.0.0.1
# A demo federated executor so the Admin › Compute table has something to show
# (it is only listed, never called — no second endpoint required).
export TELEMACHUS_EXECUTORS="${TELEMACHUS_EXECUTORS:-$PWD/test/e2e/executors.example.json}"
# The model is inherited from the environment (run.sh sets it when a local ollama
# is reachable). With none set the server uses its deterministic fallback, so the
# tour still passes on CI runners that have no GPU/model.
exec racket server/main.rkt
