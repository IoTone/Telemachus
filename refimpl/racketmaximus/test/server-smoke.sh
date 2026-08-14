#!/usr/bin/env bash
# test/server-smoke.sh — integration test for the HTTP server (slice 3).
# Boots the server on a temp DB, exercises the RBAC + localization flow, asserts.
# Run from refimpl/racketmaximus/ :  bash test/server-smoke.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
export TELEMACHUS_DATA_DIR="$(mktemp -d)"
PORT="${PORT:-8080}"
DB="$TELEMACHUS_DATA_DIR/telemachus.db"
export DATABASE_URL="sqlite:///$DB"

fail=0
assert(){ # <label> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"; else echo "  FAIL $1 — expected to contain: $3 — got: $2"; fail=1; fi
}

racket server/main.rkt >/tmp/tmx-smoke.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR"' EXIT
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do tries=$((tries+1)); [ $tries -gt 30000 ] && { echo "server never came up"; cat /tmp/tmx-smoke.log; exit 1; }; done; exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
assert "health"          "$(curl -s $B/health)" '"ok":true'
BS=$(curl -s -X POST $B/api/bootstrap -d '{"username":"alice","password":"s3cret"}')
assert "bootstrap token" "$BS" '"token":"tk_'
assert "bootstrap msg"   "$BS" 'Created operator alice'
OP=$(printf '%s' "$BS" | grep -oP '"token":\s*"\K[^"]+')
assert "login good"      "$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"s3cret"}')" '"token":"tk_'
assert "login bad pw"    "$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"nope"}')" 'Authentication required'
assert "whoami operator" "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" '"is_operator":true'
assert "admin operator"  "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"ok":true'
MB=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')
assert "member token"    "$MB" '"token":"tk_'
BOB=$(printf '%s' "$MB" | grep -oP '"token":\s*"\K[^"]+')
assert "member 403 en"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB")" 'Forbidden: instance:manage'
assert "member 403 ja"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB" -H 'Accept-Language: ja')" '禁止されています'
assert "unauth 401 en"   "$(curl -s $B/api/whoami)" 'Authentication required.'
assert "unauth 401 ja"   "$(curl -s $B/api/whoami -H 'Accept-Language: ja')" '認証が必要です'

if [ $fail -eq 0 ]; then echo "server-smoke: PASS"; else echo "server-smoke: FAIL"; fi
exit $fail
