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
export TELEMACHUS_MODEL_URL="${TELEMACHUS_MODEL_URL:-http://127.0.0.1:11434/v1/chat/completions}"
export TELEMACHUS_MODEL="${TELEMACHUS_MODEL:-qwen2.5:7b}"
exec racket server/main.rkt
