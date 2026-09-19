#!/usr/bin/env bash
# test/pull-smoke.sh — a pull-model executor end to end over HTTP (slice 66):
# create the executor (worker token shown once), start the reference worker
# against the scripted mock model, route a chat through it, watch the sub-job.
#   bash test/pull-smoke.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
export PORT="${PORT:-8845}"; MOCK_PORT="${MOCK_PORT:-8905}"
port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
for p in "$PORT" "$MOCK_PORT"; do port_busy "$p" && { echo "port $p is in use"; exit 1; }; done
export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/t.db}"
export TELEMACHUS_BIND=127.0.0.1
# the SERVER has no model; the WORKER has the mock
export MOCK_REPLY_FILE="$TELEMACHUS_DATA_DIR/reply.json"
printf '{"*": "pulled: hello from the worker"}' > "$MOCK_REPLY_FILE"
MOCK_PORT="$MOCK_PORT" racket test/mock-llm.rkt >"$TELEMACHUS_DATA_DIR/mock.log" 2>&1 & MOCK=$!
unset TELEMACHUS_MODEL_URL
racket server/main.rkt >"$TELEMACHUS_DATA_DIR/server.log" 2>&1 & SRV=$!
WORKER=""
cleanup(){ kill $SRV $MOCK 2>/dev/null; [ -n "$WORKER" ] && kill $WORKER 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR"; }
trap cleanup EXIT
until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do :; done; exec 3>&- 2>/dev/null || true
fail=0
assert(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"; else echo "  FAIL $1 — expected: $3 — got: $2"; fail=1; fi; }
jq_(){ python3 -c 'import sys,json;print(eval(sys.argv[1],{"d":json.load(sys.stdin)}))' "$1"; }
B="localhost:$PORT"
TOK=$(curl -s -X POST $B/api/bootstrap -d '{"username":"ops","password":"pw-pw-pw1"}' | jq_ 'd["token"]')
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
P(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
curl -s -X POST $B/api/quota -H "Authorization: Bearer $TOK" -d '{"dimension":"ai.tokens.total","limit":1000000,"window":"day"}' >/dev/null

echo "== 1. an executor, and its worker token — shown once ==="
EX=$(P /api/executors '{"name":"laptop-gpu","mode":"pull","model":"mock","capabilities":{"kinds":["infer.chat"]}}')
assert "executor created"        "$EX" '"mode":"pull"'
assert "worker token returned"   "$EX" '"worker_token":"tk_'
WT=$(printf '%s' "$EX" | jq_ 'd["worker_token"]'); EXID=$(printf '%s' "$EX" | jq_ 'd["id"]')
assert "never seen yet"          "$(G /api/executors)" '"status":"never-seen"'
assert "listing never shows the token" "$(G /api/executors | grep -c worker_token || true)" "0"
assert "a member cannot create one" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/executors -H "Authorization: Bearer $WT" -d '{"name":"x"}')" '403'

echo "== 2. the worker token can ONLY work: claim yes, data no ==="
assert "worker token: notes refused"  "$(curl -s $B/api/notes -H "Authorization: Bearer $WT")" 'Forbidden: notes:read'
assert "worker token: no run"         "$(curl -s -X POST $B/api/workflows/index-documents/run -H "Authorization: Bearer $WT" -d '{}')" 'Forbidden'
assert "claim with nothing queued is 204" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"max_wait":0}')" '204'
assert "a user token cannot claim"    "$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $TOK" -d '{}')" 'not bound to an executor'

echo "== 3. a chat routed to the pull executor waits for the worker ==="
# start the chat in the background (it blocks on the sub-job), then the worker
( curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $TOK" -d '{"prompt":"hello","executor":"laptop-gpu"}' > "$TELEMACHUS_DATA_DIR/chat.json" ) & CHAT=$!
sleep 1
assert "the sub-job is queued for a worker" "$(G /api/jobs)" '"kind":"infer.chat"'
TELEMACHUS_URL="http://127.0.0.1:$PORT" TELEMACHUS_WORKER_TOKEN="$WT" TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" TELEMACHUS_WORKER_MODELS=mock \
  racket cli/telemachus-worker.rkt --once >"$TELEMACHUS_DATA_DIR/worker.log" 2>&1
wait $CHAT
assert "the worker ran the job"      "$(cat "$TELEMACHUS_DATA_DIR/worker.log")" 'done'
assert "the chat got the worker's reply" "$(cat "$TELEMACHUS_DATA_DIR/chat.json")" 'pulled: hello from the worker'
assert "…attributed to the executor"  "$(cat "$TELEMACHUS_DATA_DIR/chat.json")" '"executor":"laptop-gpu"'
assert "the sub-job is done"          "$(G /api/jobs)" '"status":"done"'
assert "the executor is active now"   "$(G /api/executors)" '"status":"active"'
assert "AI spend was metered"         "$(G /api/usage)" '"dimension":"ai.tokens.total"'

echo "== 3b. issue #18: a schema-shaped chat, and a parts prompt, through the worker ==="
# the mock re-reads its reply file per request; a needle now answers with JSON
printf '{"give me the invoice": "Sure:\\n```json\\n{\\"total\\": 42, \\"currency\\": \\"JPY\\"}\\n```", "*": "pulled: hello from the worker"}' > "$MOCK_REPLY_FILE"
SCHEMA='{"type":"json_schema","json_schema":{"name":"invoice","schema":{"type":"object","properties":{"total":{"type":"number"},"currency":{"type":"string"}},"required":["total","currency"]}}}'
run_worker(){ TELEMACHUS_URL="http://127.0.0.1:$PORT" TELEMACHUS_WORKER_TOKEN="$WT" TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" TELEMACHUS_WORKER_MODELS=mock \
  racket cli/telemachus-worker.rkt --once >>"$TELEMACHUS_DATA_DIR/worker.log" 2>&1; }

( curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $TOK" \
    -d "{\"prompt\":\"give me the invoice\",\"executor\":\"laptop-gpu\",\"response_format\":$SCHEMA}" > "$TELEMACHUS_DATA_DIR/schema.json" ) & C2=$!
sleep 1; run_worker; wait $C2
assert "a schema request reaches the worker"  "$(cat "$TELEMACHUS_DATA_DIR/schema.json")" '"total":42'
assert "…and comes back parsed"               "$(cat "$TELEMACHUS_DATA_DIR/schema.json")" '"parsed":'
assert "…through the pull executor"           "$(cat "$TELEMACHUS_DATA_DIR/schema.json")" '"executor":"laptop-gpu"'

# the same reply against a schema it does NOT satisfy: refused, naming the path.
# The mock ignores response_format, exactly as a local server does — which is why
# the platform checks the reply itself.
BAD='{"type":"json_schema","json_schema":{"name":"invoice","schema":{"type":"object","properties":{"total":{"type":"string"}},"required":["total"]}}}'
( curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $TOK" \
    -d "{\"prompt\":\"give me the invoice\",\"executor\":\"laptop-gpu\",\"response_format\":$BAD}" > "$TELEMACHUS_DATA_DIR/bad.json" ) & C3=$!
sleep 1; run_worker; wait $C3
assert "a reply that misses the schema is refused" "$(cat "$TELEMACHUS_DATA_DIR/bad.json")" 'does not honour response_format'
assert "…and the refusal names the path"          "$(cat "$TELEMACHUS_DATA_DIR/bad.json")" '$.total'

# a PARTS prompt reaches the provider verbatim: the mock matches its needle in a
# text part, so a parts prompt is not silently an empty one
( curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $TOK" \
    -d '{"prompt":[{"type":"text","text":"give me the invoice"}],"executor":"laptop-gpu"}' > "$TELEMACHUS_DATA_DIR/parts.json" ) & C4=$!
sleep 1; run_worker; wait $C4
# the invoice reply (not the "*" default) proves the needle was found in a TEXT PART
assert "a parts prompt reaches the model"     "$(cat "$TELEMACHUS_DATA_DIR/parts.json")" '"reply":"Sure:'

echo "== 4. a stale result is refused; retire kills the token ==="
JID=$(G /api/jobs | python3 -c 'import sys,json;print(json.load(sys.stdin)["jobs"][0]["id"])')
assert "completing a finished job is 409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$JID/complete -H "Authorization: Bearer $WT" -d '{"result":{"reply":"x","tokens_used":1}}')" '409'
assert "retired" "$(curl -s -X DELETE $B/api/executors/$EXID -H "Authorization: Bearer $TOK")" '"ok":true'
assert "…and the worker token is dead" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{}')" '401'
assert "…and the executor is retired" "$(G /api/executors)" '"status":"retired"'
assert "an unknown executor is a 400" "$(P /api/ai/chat '{"prompt":"x","executor":"laptop-gpu"}')" 'unknown executor'

echo
if [ $fail = 0 ]; then echo "pull-smoke: PASS"; else echo "pull-smoke: FAIL"; tail -20 "$TELEMACHUS_DATA_DIR/server.log"; tail -5 "$TELEMACHUS_DATA_DIR/worker.log"; exit 1; fi
