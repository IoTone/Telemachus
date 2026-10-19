#!/usr/bin/env bash
# scripts/container-smoke.sh — the image actually serves (issue #89).
#
# The acceptance criterion is "`docker run` with the documented env vars against
# an external Postgres serves the API and passes a smoke script". Building an
# image proves nothing about that: the ways a working build fails to RUN are the
# interesting ones, and every assertion below is one of them.
#
#   bash scripts/container-smoke.sh                     # builds the image if needed
#   IMAGE=telemachus:0.1.0 bash scripts/container-smoke.sh
#
# Needs docker and a Postgres. With no DATABASE_URL in the environment it starts
# its own Postgres container; in CI the workflow's service container supplies one.
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-telemachus:0.1.0}"
PORT="${CONTAINER_SMOKE_PORT:-18835}"
NAME="telemachus-smoke-$$"
PGNAME="telemachus-smoke-pg-$$"
NET="telemachus-smoke-net-$$"
fail=0
# Substring tests in pure bash, with NO pipe. The `printf … | grep -qF` idiom the
# other smokes use is unsafe here because this script sets `pipefail`: grep -q
# exits on the first match, printf then gets EPIPE, and pipefail promotes that to
# the pipeline's status — so a SUCCESSFUL match reports FAIL, with a "write
# error: Broken pipe" beside it. It bit the SBOM assertions, whose haystack is
# large enough for the race to land.
assert(){ case "$2" in *"$3"*) echo "  ok   $1";;
                        *) echo "  FAIL $1 — expected: $3 — got: ${2:0:400}"; fail=1;; esac; }
refute(){ case "$2" in *"$3"*) echo "  FAIL $1 — did NOT expect: $3"; fail=1;;
                        *) echo "  ok   $1";; esac; }

OWN_PG=0
cleanup(){
  docker rm -f "$NAME" >/dev/null 2>&1
  # The data volume goes here rather than only on the success path: an early
  # exit (a container that would not start, a failed assertion) otherwise left
  # one behind per run, which is a slow leak nobody would think to look for.
  docker volume rm "$NAME-data" >/dev/null 2>&1
  [ "$OWN_PG" = 1 ] && docker rm -f "$PGNAME" >/dev/null 2>&1
  [ "$OWN_PG" = 1 ] && docker network rm "$NET" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

command -v docker >/dev/null || { echo "docker is required"; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== building $IMAGE from the flake =="
  command -v nix >/dev/null || { echo "nix is required to build the image"; exit 1; }
  nix build .#container || exit 1
  docker load < result || exit 1
fi

echo "== 0. what the image promises about itself =="
CFG=$(docker image inspect "$IMAGE" --format '{{json .Config}}')
assert "runs as a non-root uid"        "$CFG" '"User":"65532:65532"'
assert "declares /data as a volume"    "$CFG" '"/data"'
assert "declares a healthcheck"        "$CFG" 'Healthcheck'
assert "binds every interface"         "$CFG" 'TELEMACHUS_BIND=0.0.0.0'
assert "points the data dir at /data"  "$CFG" 'TELEMACHUS_DATA_DIR=/data'
# A shell is the first thing an attacker looks for, and nothing in the image
# needs one — the healthcheck is the exec form for exactly this reason.
refute "ships no /bin/sh"              "$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'echo reachable' 2>&1)" 'reachable'

echo
echo "== 1. the SBOM shipped with it =="
# Read it with the image's OWN curl, over file://.
#
# Two things rule out the obvious approaches: there is no `cat` in the image (the
# point of it), and `/share/telemachus/sbom.json` is a SYMLINK into the Nix store
# — which is how dockerTools assembles `contents` — so `docker cp`'s tar stream
# copies the link rather than the bytes and yields nothing. Inside the container
# the link resolves, because the store is in the image.
SBOM=$(docker run --rm --entrypoint curl "$IMAGE" -s file:///share/telemachus/sbom.json 2>/dev/null)
assert "the SBOM names the component"  "$SBOM" '"name": "telemachus"'
assert "…and lists its closure"        "$SBOM" '"storePath"'
assert "…with a package count"         "$SBOM" '"packageCount"'

echo
echo "== 2. it serves, as a non-root user, on a read-only root filesystem =="
# Two shapes, because the database comes from somewhere different in each.
#
#   • CI supplies one on the runner's own loopback (a service container with a
#     published port). The app then runs with `--network host` so it can reach
#     127.0.0.1 — and host networking CANNOT also publish a port, so the app is
#     reached on its own 8835 rather than a mapped one. Passing both -p and
#     --network host is an error, not a no-op.
#   • Run by hand, this starts its own Postgres on a private network and
#     publishes the app's port.
if [ -n "${DATABASE_URL:-}" ]; then
  # `postgres` is the hostname inside a CI job's service network; from the
  # runner (and so from a host-networked container) it is loopback.
  DB_URL=$(printf '%s' "$DATABASE_URL" | sed 's/@postgres:/@127.0.0.1:/')
  DOCKER_NET_ARGS="--network host"
  PUBLISH=""
  APP_PORT=8835
  # Host networking means the caller shares the container's loopback, so the
  # peer gate legitimately ADMITS an unauthenticated bootstrap. The refusal is
  # only a meaningful assertion when the caller is genuinely remote.
  LOOPBACK_CALLER=1
  echo "  (using the DATABASE_URL from the environment, host networking)"
else
  OWN_PG=1
  docker network create "$NET" >/dev/null
  docker run -d --name "$PGNAME" --network "$NET" \
    -e POSTGRES_USER=telemachus -e POSTGRES_PASSWORD=telemachus -e POSTGRES_DB=telemachus \
    postgres:16 >/dev/null
  echo "  (started $PGNAME)"
  for _ in $(seq 1 60); do
    docker exec "$PGNAME" pg_isready -U telemachus -d telemachus >/dev/null 2>&1 && break
    sleep 1
  done
  DB_URL="postgres://telemachus:telemachus@$PGNAME:5432/telemachus"
  DOCKER_NET_ARGS="--network $NET"
  PUBLISH="-p $PORT:8835"
  APP_PORT="$PORT"
  # A published port on a bridge network: the container sees the gateway, not
  # loopback, so the gate is live and testable.
  LOOPBACK_CALLER=0
fi

# The posture the image is built for, asserted by RUNNING it that way: no writable
# root filesystem, no capabilities, no new privileges, a tmpfs for /tmp and one
# named volume. If any of these were wrong the container would not come up.
docker run -d --name "$NAME" $DOCKER_NET_ARGS \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$NAME-data:/data" \
  -e DATABASE_URL="$DB_URL" \
  -e TELEMACHUS_SECRET_KEY="$(printf '0%.0s' $(seq 1 64))" \
  -e TELEMACHUS_SECRET="container-smoke-secret" \
  -e TELEMACHUS_BOOTSTRAP_SECRET="container-smoke-bootstrap" \
  -e PORT=8835 \
  $PUBLISH \
  "$IMAGE" >/dev/null || { echo "  FAIL the container did not start"; exit 1; }

B="http://127.0.0.1:$APP_PORT"
up=0
for _ in $(seq 1 90); do
  if curl -fsS "$B/health" >/dev/null 2>&1; then up=1; break; fi
  # a container that EXITED is not going to come up; say so now
  st=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
  if [ "$st" = "exited" ]; then
    echo "  FAIL the container exited during startup:"
    docker logs "$NAME" 2>&1 | tail -30 | sed 's/^/    /'
    exit 1
  fi
  sleep 1
done
[ "$up" = 1 ] || { echo "  FAIL /health never answered"; docker logs "$NAME" 2>&1 | tail -30 | sed 's/^/    /'; exit 1; }

assert "/health answers"                "$(curl -s $B/health)" '"ok":true'
# It must be the EXTERNAL database, not a SQLite file it quietly fell back to.
LOGS=$(docker logs "$NAME" 2>&1)
assert "…against the external Postgres" "$LOGS" 'db: postgres://'
assert "…with secrets sealed"            "$LOGS" 'secrets: sealed'
refute "…and no startup check failed"    "$LOGS" 'STARTUP ERROR'
assert "the process is the non-root uid"  "$(docker exec "$NAME" id -u 2>/dev/null || docker inspect -f '{{.Config.User}}' "$NAME")" '65532'

echo
echo "== 3. the API works end to end, through the published port =="
# POST /api/bootstrap is LOOPBACK-ONLY unless TELEMACHUS_BOOTSTRAP_SECRET is set
# (issue #40) — a fresh instance on a network otherwise belongs to whoever calls
# first.
#
# Whether that gate is EXERCISABLE depends on how this run reached the
# container, so the assertion is conditional rather than skipped or faked. Under
# host networking the caller shares the container's loopback and is not a
# stranger at all; asserting a refusal there would be asserting a bug. And it
# must come FIRST where it applies, because a successful bootstrap is
# first-run-only: one admitted call consumes it and every later assertion 401s,
# which is exactly how this failed in CI.
if [ "$LOOPBACK_CALLER" = 0 ]; then
  assert "bootstrap refuses an unauthenticated stranger" \
    "$(curl -s -X POST $B/api/bootstrap -d '{"username":"nope","password":"pw-pw-pw1"}')" \
    'this host only'
else
  echo "  --   bootstrap refusal not applicable (host networking: the caller IS loopback)"
fi
TOK=$(curl -s -X POST $B/api/bootstrap -H 'X-Telemachus-Bootstrap: container-smoke-bootstrap' \
        -d '{"username":"ops","password":"pw-pw-pw1"}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
assert "bootstrap mints a token"  "$TOK" 'tk_'
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
# whoami answers with ids, permissions and the session policy — NOT a username.
# Assert on the thing that proves the token is the operator's.
assert "whoami answers for the operator"  "$(G /api/whoami)" '"permissions":["*:*"]'
# A document round trip is what proves /data is actually writable under
# --read-only: the blob store is the thing that writes, and a wrong volume or a
# root-owned directory surfaces exactly here and nowhere earlier.
KEY="container-smoke/hello.txt"
PUT=$(curl -s -X PUT "$B/api/repo/$KEY" -H "Authorization: Bearer $TOK" \
       -H 'Content-Type: text/plain' --data-binary 'hello from the container')
assert "a document uploads"              "$PUT" '"key":"'
OID=$(printf '%s' "$PUT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
assert "…and downloads byte-identically" "$(curl -s "$B/api/repo-obj/$OID/content" -H "Authorization: Bearer $TOK")" 'hello from the container'

echo
echo "== 4. it drains on SIGTERM rather than being killed =="
# `docker stop` sends SIGTERM and waits. Racket delivers that as exn:break, which
# is what the drain hangs off; a container that ignored it would be SIGKILLed
# after the timeout and say nothing.
docker stop -t 30 "$NAME" >/dev/null
# grep the WHOLE log, not its tail: the boot block is long (plugins, MCP, the
# startup warnings) and `tail -20` was still inside it, so these assertions
# reported the wrong thing about a drain that had genuinely not run.
STOPLOGS=$(docker logs "$NAME" 2>&1)
assert "the drain ran"                   "$STOPLOGS" 'draining'
assert "…and reported what it did"       "$STOPLOGS" 'drained:'
assert "…exiting 0, not on a signal"     "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" '0'

echo
if [ $fail = 0 ]; then echo "container-smoke: PASS"; else echo "container-smoke: FAIL"; exit 1; fi
