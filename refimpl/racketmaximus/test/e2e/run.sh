#!/usr/bin/env bash
# Telemachus e2e: boot a throwaway server on a temp DB, drive the whole UI with
# Playwright, and build a screenshot catalog.  Usage: bash test/e2e/run.sh
set -e
cd "$(dirname "$0")"

# This box's default node is too old for Playwright; prefer a modern one if present.
for v in v24.18.0 v22.22.3 v20.17.0; do
  if [ -x "$HOME/.nvm/versions/node/$v/bin/node" ]; then
    export PATH="$HOME/.nvm/versions/node/$v/bin:$PATH"; break
  fi
done
echo "node $(node -v)"

[ -d node_modules/@playwright ] || npm install
npx playwright install chromium chromium-headless-shell >/dev/null 2>&1 || true

# Boot a fresh server on 127.0.0.1:8080 (temp DB). Tear it down on exit.
export E2E_DATA_DIR="$(mktemp -d)"
bash boot-server.sh >/tmp/telemachus-e2e-server.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$E2E_DATA_DIR"' EXIT

echo -n "waiting for server"
for i in $(seq 1 120); do
  curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 && { echo " up"; break; }
  echo -n .; sleep 0.5
done

node run-tour.mjs
node build-catalog.mjs
echo "catalog → $(pwd)/catalog/catalog.html"
