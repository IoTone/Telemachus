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
assert "change pw"       "$(curl -s -X POST $B/api/password -H "Authorization: Bearer $OP" -d '{"current_password":"s3cret","new_password":"newpass1"}')" '"ok":true'
assert "login new pw"    "$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"newpass1"}')" '"token":"tk_'
assert "old pw rejected" "$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"s3cret"}')" 'Authentication required'
assert "whoami operator" "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" '"is_operator":true'
assert "admin operator"  "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"ok":true'
MB=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')
assert "member token"    "$MB" '"token":"tk_'
BOB=$(printf '%s' "$MB" | grep -oP '"token":\s*"\K[^"]+')
assert "member 403 en"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB")" 'Forbidden: instance:manage'
assert "member 403 ja"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB" -H 'Accept-Language: ja')" '禁止されています'
# notes: ownership + sharing over HTTP
CB=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"carol","role":"member"}')
CAROL_ID=$(printf '%s' "$CB" | grep -oP '"user_id":\s*"\K[^"]+')
CAROL=$(printf '%s' "$CB" | grep -oP '"token":\s*"\K[^"]+')
NOTE=$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $BOB" -d '{"title":"Secret","visibility":"private"}')
NID=$(printf '%s' "$NOTE" | grep -oP '"id":\s*"\K[^"]+')
assert "note created"       "$NOTE" '"title":"Secret"'
assert "carol denied priv"  "$(curl -s $B/api/notes/$NID -H "Authorization: Bearer $CAROL")" 'Forbidden: notes:read'
curl -s -X POST $B/api/notes/$NID/share -H "Authorization: Bearer $BOB" -d "{\"user_id\":\"$CAROL_ID\",\"permission\":\"notes:read\"}" >/dev/null
assert "carol reads shared" "$(curl -s $B/api/notes/$NID -H "Authorization: Bearer $CAROL")" '"title":"Secret"'
# AI jobs: concurrency governor (cap 2) + quota (429 when exhausted)
# NB: wait ONLY the curl PIDs — a bare `wait` would also wait on the server job.
pids=""
for i in 1 2 3 4; do curl -s -X POST $B/api/ai/echo -H "Authorization: Bearer $OP" -d '{"prompt":"hello world"}' > "$TELEMACHUS_DATA_DIR/ai-$i.txt" & pids="$pids $!"; done
wait $pids
MAXC=$(cat "$TELEMACHUS_DATA_DIR"/ai-*.txt | grep -oP '"concurrent":\s*\K[0-9]+' | sort -nr | head -1)
if [ "${MAXC:-9}" -le 2 ]; then echo "  ok   concurrency cap (max=$MAXC of 2)"; else echo "  FAIL concurrency cap (max=$MAXC)"; fail=1; fi
assert "ai model info"   "$(curl -s $B/api/ai/model -H "Authorization: Bearer $OP")" '"configured":false'
assert "ai chat reply"   "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hello"}')" '"reply":"HELLO"'
assert "ai chat stream"  "$(curl -sN -X POST $B/api/ai/chat/stream -H "Authorization: Bearer $OP" -d '{"prompt":"hello world"}')" '"done":true'
assert "agent no-model"  "$(curl -s -X POST $B/api/agent -H "Authorization: Bearer $OP" -d '{"prompt":"hi"}')" 'requires a configured model'
assert "tools list"      "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'create_note'
assert "tool toggle off" "$(curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":false}')" '"enabled":false'
assert "token issued"    "$(curl -s -X POST $B/api/tokens -H "Authorization: Bearer $OP" -d '{"name":"ci","scopes":["*:read"]}')" '"token":"tk_'
assert "token listed"    "$(curl -s $B/api/tokens -H "Authorization: Bearer $OP")" '"name":"ci"'
assert "token member 403" "$(curl -s $B/api/tokens -H "Authorization: Bearer $BOB")" 'Forbidden: settings:manage'
TKID=$(curl -s $B/api/tokens -H "Authorization: Bearer $OP" | grep -oP '"id":"\K[^"]+' | head -1)
assert "token revoked"   "$(curl -s -X DELETE $B/api/tokens/$TKID -H "Authorization: Bearer $OP")" '"ok":true'
assert "plugin loaded"   "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" 'example-tools'
assert "plugin tool"     "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'word_count'
assert "mcp connected"   "$(curl -s $B/api/mcp -H "Authorization: Bearer $OP")" '"name":"mock"'
assert "mcp tool"        "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'mcp__mock__add'
assert "oop connected"   "$(curl -s $B/api/oop -H "Authorization: Bearer $OP")" 'notes-helper'
assert "oop scope shown" "$(curl -s $B/api/oop -H "Authorization: Bearer $OP")" 'notes:write'
assert "oop tool"        "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'oop__notes-helper__save_idea'
assert "translate"       "$(curl -s -X POST $B/api/translate -H "Authorization: Bearer $OP" -d '{"text":"hello","target_lang":"ja"}')" '"result":"HELLO"'
assert "glossary add"    "$(curl -s -X POST $B/api/glossary -H "Authorization: Bearer $OP" -d '{"term":"note","translation":"memo","target_lang":"ja"}')" '"term":"note"'
assert "glossary list"   "$(curl -s $B/api/glossary -H "Authorization: Bearer $OP")" '"translation":"memo"'
assert "translate hist"  "$(curl -s $B/api/translate -H "Authorization: Bearer $OP")" '"source_text":"hello"'
assert "executors local" "$(curl -s $B/api/executors -H "Authorization: Bearer $OP")" '"name":"local"'
assert "executor gated"  "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $BOB" -d '{"prompt":"hi","executor":"gpu-node"}')" 'Forbidden: instance:manage'
assert "usage report"    "$(curl -s $B/api/usage -H "Authorization: Bearer $OP")" 'ai.tokens.total'
curl -s -X POST $B/api/quota -H "Authorization: Bearer $OP" -d '{"dimension":"ai.tokens.total","limit":3,"window":"day"}' >/dev/null
assert "quota 429"       "$(curl -s -X POST $B/api/ai/echo -H "Authorization: Bearer $OP" -d '{"prompt":"exceeds the tiny token budget now"}')" 'quota exceeded'
assert "ui served"       "$(curl -s $B/)" '<!doctype html>'
assert "members list"    "$(curl -s $B/api/members -H "Authorization: Bearer $OP")" '"username":"bob"'
assert "unauth 401 en"   "$(curl -s $B/api/whoami)" 'Authentication required.'
assert "unauth 401 ja"   "$(curl -s $B/api/whoami -H 'Accept-Language: ja')" '認証が必要です'

if [ $fail -eq 0 ]; then echo "server-smoke: PASS"; else echo "server-smoke: FAIL"; fi
exit $fail
