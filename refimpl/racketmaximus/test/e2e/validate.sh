#!/usr/bin/env bash
# Validate the demo top to bottom against a REAL server, and fail if it is broken.
#
#   bash test/e2e/validate.sh            # fresh throwaway server on a temp DB
#   BASE_URL=http://host:8835 bash test/e2e/validate.sh --no-server
#                                        # validate an already-running deployment
#
# The second form is the deploy gate: point it at the demo box after a restart.
# It creates a `demo-validator` operator on a fresh instance, so only aim it at a
# live one that already has an operator (it signs in) or at a throwaway.
set -u
cd "$(dirname "$0")"

# This box's default node is too old for Playwright; prefer a modern one.
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

PORT="${PORT:-8899}"
export BASE_URL="${BASE_URL:-http://127.0.0.1:$PORT}"
SRV_PID=""

cleanup() {
  # kill by PID, never by pattern: `pkill -f server/main` also matches this
  # script's own command line and takes the shell down with it.
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
  # NOTE: an ABSOLUTE temp data dir, for isolation. That means this job cannot
  # catch the relative-blob-root class of bug by itself — an absolute root is
  # already safe. Two other things cover that: the unit assertion in
  # test/repo-tests.rkt ("blob roots are absolute and cwd-independent") and the
  # boot guard in server/main.rkt, which refuses to serve with a relative root.
  export TELEMACHUS_DATA_DIR="$TMPDATA"
  # a COPY of the catalogs, so the Localize checks can never export into the checkout
  cp -r locales "$TMPDATA/locales" && export TELEMACHUS_LOCALES="$TMPDATA/locales"
  # Honour a pre-set DATABASE_URL, like the unit suite and both smoke suites do,
  # so this can be run against Postgres: drop/recreate the database first,
  # because bootstrap is first-run-only.
  export DATABASE_URL="${DATABASE_URL:-sqlite:///$TMPDATA/validate.db}"
  export TELEMACHUS_BIND=127.0.0.1
  export TELEMACHUS_HOME=login
  export PORT
  echo "booting server on $BASE_URL (data: $TMPDATA)"
  racket server/main.rkt >"$TMPDATA/server.log" 2>&1 &
  SRV_PID=$!
  cd test/e2e

  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "$BASE_URL/health" && break
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server died:"; tail -20 "$TMPDATA/server.log"; exit 1; }
    sleep 0.5
  done
  curl -sf -o /dev/null "$BASE_URL/health" || { echo "server never became healthy:"; tail -20 "$TMPDATA/server.log"; exit 1; }
  echo "server up"
fi

node demo-validate.mjs
RC=$?

if [ "$OWN_SERVER" = "1" ] && [ $RC -ne 0 ]; then
  echo; echo "── server log (tail) ──"; tail -40 "$TMPDATA/server.log"
fi
exit $RC
