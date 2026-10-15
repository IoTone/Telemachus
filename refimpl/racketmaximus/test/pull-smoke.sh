#!/usr/bin/env bash
# test/pull-smoke.sh — a pull-model executor end to end over HTTP (slice 66):
# create the executor (worker token shown once), start the reference worker
# against the scripted mock model, route a chat through it, watch the sub-job.
#   bash test/pull-smoke.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
# A test run uses the SHIPPED plugin set. These are unset rather than merely
# unused: a developer working on a downstream plugin exports them in their own
# shell, and an inherited value would put someone else's plugin — and its load
# failure, since PLTCOLLECTS is reset just above — into this suite's assertions.
unset TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS
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
# issue #24: a claim hands back a fencing token, and a write without the right one
# is refused — this is what stops a lapsed attempt landing on the one that replaced it
CJ=$(P /api/jobs '{"kind":"infer.chat","payload":{"messages":[{"role":"user","content":"fence"}]}}')
CJID=$(printf '%s' "$CJ" | jq_ 'd["id"]')
CLAIM=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"],"max_wait":2}')
assert "the claim carries a fencing token" "$CLAIM" '"claim_token":"'
FENCE=$(printf '%s' "$CLAIM" | jq_ 'd["claim_token"]')
assert "a heartbeat without the token is 409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$CJID/heartbeat -H "Authorization: Bearer $WT" -d '{}')" '409'
assert "…with the wrong token too"           "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$CJID/heartbeat -H "Authorization: Bearer $WT" -d '{"claim_token":"nope"}')" '409'
assert "…and with the right one it is 200"   "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$CJID/heartbeat -H "Authorization: Bearer $WT" -d "{\"claim_token\":\"$FENCE\"}")" '200'
assert "a result without the token is 409"   "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$CJID/complete -H "Authorization: Bearer $WT" -d '{"result":{"reply":"x","tokens_used":1}}')" '409'
assert "…and with it, the job completes"     "$(curl -s -X POST $B/api/workers/jobs/$CJID/complete -H "Authorization: Bearer $WT" -d "{\"claim_token\":\"$FENCE\",\"result\":{\"reply\":\"fenced\",\"tokens_used\":1}}")" '"ok":true'
echo
echo "== 5. SCHED-8: cancelling a RUNNING remote job, and PULL-9's job-bound read =="
# a document, and a job whose payload NAMES it
DOC=$(curl -s -X PUT "$B/api/repo/scans/levee.txt?filename=levee.txt" \
        -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' \
        --data-binary 'levee 7 looks sound')
DOCID=$(printf '%s' "$DOC" | jq_ 'd["id"]')
OTHER=$(curl -s -X PUT "$B/api/repo/scans/other.txt?filename=other.txt" \
        -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary 'not this one')
OTHERID=$(printf '%s' "$OTHER" | jq_ 'd["id"]')
DJ=$(P /api/jobs "{\"kind\":\"infer.chat\",\"payload\":{\"messages\":[{\"role\":\"user\",\"content\":\"read it\"}],\"object_id\":\"$DOCID\"}}")
DJID=$(printf '%s' "$DJ" | jq_ 'd["id"]')
DCLAIM=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"],"max_wait":2}')
DFENCE=$(printf '%s' "$DCLAIM" | jq_ 'd["claim_token"]')
W(){ curl -s -X POST "$B/api/workers/jobs/$DJID/$1" -H "Authorization: Bearer $WT" -d "$2"; }
WC(){ curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/workers/jobs/$DJID/$1" -H "Authorization: Bearer $WT" -d "$2"; }
# the three halves of PULL-9's fence
assert "a worker reads the document ITS job names" \
  "$(W document "{\"claim_token\":\"$DFENCE\",\"object\":\"$DOCID\"}")" '"key":"scans/levee.txt"'
assert "…as text, for a worker that wants words" \
  "$(W document "{\"claim_token\":\"$DFENCE\",\"object\":\"$DOCID\",\"as\":\"text\"}")" 'levee 7 looks sound'
assert "…but not one the job does not name" \
  "$(W document "{\"claim_token\":\"$DFENCE\",\"object\":\"$OTHERID\"}")" 'not named by this job'
assert "…and not without the attempt's token" \
  "$(WC document "{\"claim_token\":\"nope\",\"object\":\"$DOCID\"}")" '409'
assert "…and a user token is not a worker"  \
  "$(curl -s -X POST $B/api/workers/jobs/$DJID/document -H "Authorization: Bearer $TOK" -d '{}')" 'not bound to an executor'
# cancel it while the worker holds it
assert "the owner cancels a RUNNING job"    "$(P /api/jobs/$DJID/cancel)" '"status":"canceling"'
assert "…the heartbeat tells the worker to stop" "$(W heartbeat "{\"claim_token\":\"$DFENCE\"}")" 'was canceled'
assert "…and it still holds its slot while it drains" "$(G /api/jobs/$DJID)" '"status":"canceling"'
assert "…and it can no longer read documents" \
  "$(WC document "{\"claim_token\":\"$DFENCE\",\"object\":\"$DOCID\"}")" '409'
assert "…posting the result settles it instead of landing it" \
  "$(W fail "{\"claim_token\":\"$DFENCE\",\"error\":\"canceled\"}")" 'was canceled'
assert "…so the job is canceled, with no result"  "$(G /api/jobs/$DJID)" '"status":"canceled"'
assert "cancelling a finished job is a 409" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/jobs/$DJID/cancel -H "Authorization: Bearer $TOK")" '409'

echo
echo "== 6. issue #58: the worker says whether it is taking work =="
WS(){ curl -s -X POST $B/api/workers/state -H "Authorization: Bearer $WT" -d "$1"; }
# The one channel a worker with NO job can use: a drained host has stopped
# claiming and holds nothing to heartbeat, so its silence would otherwise be
# indistinguishable from a crash.
assert "a worker reports paused"             "$(WS '{"state":"paused"}')" '"state":"paused"'
assert "…and GET /api/executors says so"     "$(G /api/executors)" '"worker_state":"paused"'
# Liveness and willingness are separate questions, and a paused worker is alive
# and refusing — `status` must keep answering the first one.
assert "…while status still says active"     "$(G /api/executors)" '"status":"active"'
# The vocabulary is closed. Here the state IS the request, so an unknown one is
# refused; on a claim it is ignored, because failing the call that fetches work
# over a cosmetic field would stop the queue.
assert "an unknown state is refused"         "$(WS '{"state":"draining"}')" 'state must be one of'
assert "…and the stored state is unchanged"  "$(G /api/executors)" '"worker_state":"paused"'
assert "a claim may carry the state instead" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"],"state":"ready"}')" '204'
assert "…which reports without a second request" "$(G /api/executors)" '"worker_state":"ready"'
assert "an unknown state on a CLAIM is ignored, not refused" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"],"state":"wat"}')" '204'
assert "…leaving the last good state in place" "$(G /api/executors)" '"worker_state":"ready"'
assert "a user token is not a worker here"   "$(curl -s -X POST $B/api/workers/state -H "Authorization: Bearer $TOK" -d '{"state":"ready"}')" 'not bound to an executor'

echo
echo "== 7. FLEET-2: the operator can see the fleet and the queue =="
# What each executor IS lives on GET /api/executors; what the fleet is DOING
# lives here. Instance-scoped, because a team-tier route widened to cross teams
# would answer past the org gate.
assert "the fleet read names the worker"      "$(G /api/admin/workers)" '"name":"laptop-gpu"'
assert "…with its derived health"             "$(G /api/admin/workers)" '"status":"active"'
assert "…and the queue block"                 "$(G /api/admin/workers)" '"oldest_queued_seconds"'
assert "…and the figure a deep queue cannot explain" "$(G /api/admin/workers)" '"unclaimable"'
assert "…which is zero while a worker can run the work" "$(G /api/admin/workers)" '"count":0'
# The claim records what the worker DECLARED, which is what makes the figure
# above mean anything: `capabilities` used to hold only what was typed at create.
assert "the capability record is the worker's own declaration" \
  "$(G /api/admin/workers)" '"models":["mock"]'
# A window, clamped rather than refused: a nonsense value on a read should answer
# with the default, not a 400 an operator has to decode.
assert "the window is configurable"           "$(G '/api/admin/workers?hours=3')" '"hours":3'
assert "…and a nonsense window falls back"    "$(G '/api/admin/workers?hours=-1')" '"hours":24'
# instance:manage. The worker's own token carries jobs:execute and nothing else,
# so the box cannot read the fleet it belongs to.
assert "a worker token cannot read the fleet" \
  "$(curl -s -o /dev/null -w '%{http_code}' $B/api/admin/workers -H "Authorization: Bearer $WT")" '403'
assert "…and neither can a stranger" \
  "$(curl -s -o /dev/null -w '%{http_code}' $B/api/admin/workers)" '401'

echo
echo "== 8. FLEET-3: the operator takes a host out of rotation, reversibly =="
# The only lever before this was a RETIRE, which revokes the worker token: a
# ten-minute drain meant re-provisioning the host afterwards.
assert "drain"                                "$(P /api/executors/$EXID/drain)" '"admin_state":"drained"'
assert "…and a drained worker is offered nothing" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"]}')" '204'
# The difference from a retire, and the reason to prefer it: the box is still
# there, still reporting, still holding its token.
assert "…while the host stays visibly alive"   "$(G /api/executors)" '"status":"active"'
assert "…and the fleet counts the intent apart from the liveness" \
  "$(G /api/admin/workers)" '"drained":1'
# `retired` is not an admin state: retiring is irreversible and is its own call.
assert "an unknown admin state is not reachable" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/executors/$EXID/retire -H "Authorization: Bearer $TOK")" '404'
assert "resume"                               "$(P /api/executors/$EXID/resume)" '"admin_state":"active"'
assert "…and it takes work again" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/state -H "Authorization: Bearer $WT" -d '{"state":"ready"}')" '200'
assert "a worker cannot drain itself"         "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/executors/$EXID/drain -H "Authorization: Bearer $WT")" '403'
assert "draining something that is not there is a 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/executors/no-such/drain -H "Authorization: Bearer $TOK")" '404'

echo
assert "retired" "$(curl -s -X DELETE $B/api/executors/$EXID -H "Authorization: Bearer $TOK")" '"ok":true'
assert "…and the worker token is dead" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{}')" '401'
assert "…and the executor is retired" "$(G /api/executors)" '"status":"retired"'
# A retired row has no token to drain, and saying so beats pretending it worked.
assert "…and a retired executor cannot be drained" \
  "$(P /api/executors/$EXID/drain)" 'no token to drain'
assert "an unknown executor is a 400" "$(P /api/ai/chat '{"prompt":"x","executor":"laptop-gpu"}')" 'unknown executor'

echo
if [ $fail = 0 ]; then echo "pull-smoke: PASS"; else echo "pull-smoke: FAIL"; tail -20 "$TELEMACHUS_DATA_DIR/server.log"; tail -5 "$TELEMACHUS_DATA_DIR/worker.log"; exit 1; fi
