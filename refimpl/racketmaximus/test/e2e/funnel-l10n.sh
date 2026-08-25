#!/usr/bin/env bash
# Validate that the PUBLIC beta funnel is actually localized, in a real browser.
#
#   bash test/e2e/funnel-l10n.sh          # fresh throwaway server on a temp DB
#   BASE_URL=http://host:8835 bash test/e2e/funnel-l10n.sh --no-server
#
# Why a browser and not the smoke suite: server-smoke.sh already proves
# /api/beta/config serves the right language. What it cannot see is whether the
# SWITCHER renders, whether clicking it repaints the page, and whether the
# submit-path feedback a real applicant gets is localized — three things that can
# each fail silently while every API assertion still passes.
#
# The server must serve the funnel at /, so this boots with TELEMACHUS_HOME=beta.
set -u
cd "$(dirname "$0")"

for v in v24.18.0 v22.22.3 v20.17.0; do
  if [ -x "$HOME/.nvm/versions/node/$v/bin/node" ]; then
    export PATH="$HOME/.nvm/versions/node/$v/bin:$PATH"; break
  fi
done
echo "node $(node -v)"

[ -d node_modules/@playwright ] || npm install
npx playwright install chromium chromium-headless-shell >/dev/null 2>&1 || true

OWN_SERVER=1
[ "${1:-}" = "--no-server" ] && OWN_SERVER=0

PORT="${PORT:-8898}"
export BASE="${BASE_URL:-http://127.0.0.1:$PORT}"
SRV_PID=""

cleanup() {
  # kill by PID, never by pattern: `pkill -f server/main` also matches this
  # script's own command line — and every OTHER server on the box.
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  [ -n "${TMPDATA:-}" ] && rm -rf "$TMPDATA"
}
trap cleanup EXIT

if [ "$OWN_SERVER" = "1" ]; then
  TMPDATA="$(mktemp -d)"
  cd ../..                                  # -> refimpl/racketmaximus
  export PLTCOLLECTS="$PWD/pkgs:"
  export TELEMACHUS_DATA_DIR="$TMPDATA"
  export DATABASE_URL="${DATABASE_URL:-sqlite:///$TMPDATA/funnel.db}"
  export TELEMACHUS_BIND=127.0.0.1
  export TELEMACHUS_HOME=beta            # the funnel IS the front page here
  export PORT
  echo "booting funnel on $BASE (data: $TMPDATA)"
  racket server/main.rkt >"$TMPDATA/server.log" 2>&1 &
  SRV_PID=$!
  cd test/e2e

  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "$BASE/health" && break
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died:"; tail -20 "$TMPDATA/server.log"; exit 1; }
    sleep 0.5
  done
  curl -sf -o /dev/null "$BASE/health" || { echo "server never became healthy:"; tail -20 "$TMPDATA/server.log"; exit 1; }
  # The signup endpoint answers 503 before an instance has an operator, so the
  # submit-path assertions would test the wrong refusal without this.
  curl -sf -o /dev/null -X POST "$BASE/api/bootstrap" \
    -d '{"username":"funnel-validator","password":"funnel-validator1"}' || true
  echo "server up"
fi

node funnel-l10n.mjs
RC=$?
if [ "$OWN_SERVER" = "1" ] && [ $RC -ne 0 ]; then
  echo; echo "── server log (tail) ──"; tail -40 "$TMPDATA/server.log"
fi
exit $RC
