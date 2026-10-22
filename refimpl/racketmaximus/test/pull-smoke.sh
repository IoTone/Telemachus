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
# A mock that REFUSES (issue #93), and a port with nothing on it at all — the two
# shapes of "this host cannot serve the job" that must not cost a job an attempt.
MOCK503_PORT="${MOCK503_PORT:-8906}"; MOCK500_PORT="${MOCK500_PORT:-8908}"; DEAD_PORT="${DEAD_PORT:-8907}"
# issue #60: a SECOND instance, booted with a worker-token lifetime set, because
# the knob is read from the process environment and the shipped default here —
# and everywhere — is no expiry.
ROT_PORT="${ROT_PORT:-8909}"
port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
for p in "$PORT" "$MOCK_PORT" "$MOCK503_PORT" "$MOCK500_PORT" "$DEAD_PORT" "$ROT_PORT"; do port_busy "$p" && { echo "port $p is in use"; exit 1; }; done
export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/t.db}"
export TELEMACHUS_BIND=127.0.0.1
# the SERVER has no model; the WORKER has the mock
export MOCK_REPLY_FILE="$TELEMACHUS_DATA_DIR/reply.json"
printf '{"*": "pulled: hello from the worker"}' > "$MOCK_REPLY_FILE"
MOCK_PORT="$MOCK_PORT" racket test/mock-llm.rkt >"$TELEMACHUS_DATA_DIR/mock.log" 2>&1 & MOCK=$!
MOCK_PORT="$MOCK503_PORT" MOCK_STATUS=503 MOCK_REPLY_FILE="$MOCK_REPLY_FILE" \
  racket test/mock-llm.rkt >"$TELEMACHUS_DATA_DIR/mock503.log" 2>&1 & MOCK503=$!
MOCK_PORT="$MOCK500_PORT" MOCK_STATUS=500 MOCK_REPLY_FILE="$MOCK_REPLY_FILE" \
  racket test/mock-llm.rkt >"$TELEMACHUS_DATA_DIR/mock500.log" 2>&1 & MOCK500=$!
unset TELEMACHUS_MODEL_URL
racket server/main.rkt >"$TELEMACHUS_DATA_DIR/server.log" 2>&1 & SRV=$!
WORKER=""; SRV2=""
cleanup(){ kill $SRV $MOCK $MOCK503 $MOCK500 2>/dev/null; [ -n "$WORKER" ] && kill $WORKER 2>/dev/null; [ -n "$SRV2" ] && kill $SRV2 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR" "${ROT_DIR:-/nonexistent-rot}"; }
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
echo "== 6b. issue #61: a worker hands a job back without spending an attempt =="
RJ=$(P /api/jobs '{"kind":"infer.chat","payload":{"messages":[{"role":"user","content":"release me"}]}}')
RJID=$(printf '%s' "$RJ" | jq_ 'd["id"]')
RCL=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"]}')
RFENCE=$(printf '%s' "$RCL" | jq_ 'd["claim_token"]')
RATT=$(printf '%s' "$RCL" | jq_ 'd["attempt"]')
WR(){ curl -s -X POST $B/api/workers/jobs/$RJID/release -H "Authorization: Bearer $WT" -d "$1"; }
# Fenced exactly like complete and fail: a stale token tells a stranger nothing.
assert "a release needs the attempt's token" "$(WR '{"claim_token":"nope"}')" 'not the lease holder'
assert "release"                            "$(WR "{\"claim_token\":\"$RFENCE\",\"reason\":\"unsupported\"}")" '"ok":true'
assert "…the job is queued again"           "$(G /api/jobs/$RJID)" '"status":"queued"'
# The whole point: the job is not blamed for the worker's problem.
RATT2=$(G /api/jobs/$RJID | jq_ 'd["attempt"]')
assert "…and it spent no attempt"           "$RATT2" "$RATT"
# The releasing box waits out a cool-off — the bound on a release loop, which an
# untouched attempt counter cannot provide.
assert "…and the releaser is not handed it straight back" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"]}')" '204'
# An operator can see a job workers keep handing back; `attempt` cannot show it.
assert "the queue view counts the releases"  "$(G '/api/admin/queue?status=queued')" '"releases":1'
assert "a user token is not a worker here"   "$(curl -s -X POST $B/api/workers/jobs/$RJID/release -H "Authorization: Bearer $TOK" -d '{}')" 'not bound to an executor'
curl -s -X POST $B/api/jobs/$RJID/cancel -H "Authorization: Bearer $TOK" >/dev/null

echo
echo "== 7b. FLEET-4: the queue, job by job =="
assert "the queue read pages and totals"      "$(G /api/admin/queue)" '"total"'
assert "…and says which ordering you got"     "$(G /api/admin/queue)" '"order":"recent"'
# Asked for the queued rows it is the claim's own order, so row 1 really is next.
# A list that LOOKED ordered and was not would mislead about what runs next.
assert "…drain order when asked for queued"   "$(G '/api/admin/queue?status=queued')" '"order":"drain"'
assert "a filter narrows rather than being ignored" \
  "$(G '/api/admin/queue?kind=no.such.kind')" '"total":0'
assert "…and the page is clamped, not refused" "$(G '/api/admin/queue?limit=9999')" '"limit":200'
# A queue is managed by kind, age, team and holder. This read crosses every team
# on the instance, so a team's prompt does not travel with the row.
assert "no payload travels with a cross-team row" \
  "$(G /api/admin/queue | grep -c '\"payload\"' || true)" '0'
assert "a worker token cannot read the queue" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/admin/queue" -H "Authorization: Bearer $WT")" '403'

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
echo "== 8b. issue #62: a worker writes a document DERIVED from one its job names =="
# The write counterpart of PULL-9's read: the text layer an OCR box produced
# lands beside the scan, as the job's own user, under the same fence.
EJ=$(P /api/jobs "{\"kind\":\"infer.chat\",\"payload\":{\"messages\":[{\"role\":\"user\",\"content\":\"ocr it\"}],\"object_id\":\"$DOCID\"}}")
EJID=$(printf '%s' "$EJ" | jq_ 'd["id"]')
ECLAIM=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["infer.chat"],"models":["mock"],"max_wait":2}')
EFENCE=$(printf '%s' "$ECLAIM" | jq_ 'd["claim_token"]')
B64=$(printf 'levee 7 looks sound (OCR)' | base64 | tr -d '\n')
WD(){ curl -s -X POST "$B/api/workers/jobs/$EJID/derive" -H "Authorization: Bearer $WT" -d "$1"; }
DRV=$(WD "{\"claim_token\":\"$EFENCE\",\"source\":\"$DOCID\",\"key\":\"scans/levee.txt.ocr.txt\",\"bytes_b64\":\"$B64\",\"content_type\":\"text/plain\"}")
assert "the worker writes a derived document"  "$DRV" '"derived_from"'
DRVID=$(printf '%s' "$DRV" | jq_ 'd["object_id"]')
assert "…byte-identical on the way back out" \
  "$(curl -s $B/api/repo-obj/$DRVID/content -H "Authorization: Bearer $TOK")" 'levee 7 looks sound (OCR)'
assert "…and the derivation row names the source" "$(G /api/repo-obj/$DRVID/derivations)" "$DOCID"
assert "…but never from a document the job does not name" \
  "$(WD "{\"claim_token\":\"$EFENCE\",\"source\":\"$OTHERID\",\"key\":\"x.txt\",\"bytes_b64\":\"$B64\"}")" 'not named by this job'
assert "…and never without the attempt's token" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/jobs/$EJID/derive -H "Authorization: Bearer $WT" -d "{\"claim_token\":\"nope\",\"source\":\"$DOCID\",\"key\":\"x.txt\",\"bytes_b64\":\"$B64\"}")" '409'
assert "there is no unanchored put"            "$(WD "{\"claim_token\":\"$EFENCE\",\"key\":\"x.txt\",\"bytes_b64\":\"$B64\"}")" 'source object id is required'
assert "…and the job still completes normally" \
  "$(curl -s -X POST $B/api/workers/jobs/$EJID/complete -H "Authorization: Bearer $WT" -d "{\"claim_token\":\"$EFENCE\",\"result\":{\"reply\":\"done\",\"tokens_used\":1}}")" '"ok":true'

echo
echo "== 8c. JUDGE-8: a typed judgment rides the same wire, as composed bytes =="
# The request is COMPOSED BYTES (JUDGE-13): the platform (or this test) writes
# it once and nothing re-serializes it. The verdict comes back AS RECEIVED.
JREQ='{"state":"I was billed twice.","questions":{"refund":{"type":"noul","instructions":"Does the customer ask for money back?","criteria":{"true":"asks for money back","false":"no money mentioned"}}}}'
JJOB=$(P /api/jobs "{\"kind\":\"judge.typed\",\"payload\":{\"request_json\":$(printf '%s' "$JREQ" | jq -Rs .)}}")
JID=$(printf '%s' "$JJOB" | jq_ 'd["id"]')
JCLAIM=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["judge.typed"],"max_wait":2}')
assert "a judge worker claims the job"            "$JCLAIM" '"kind":"judge.typed"'
assert "…and the payload carries the bytes composed" "$JCLAIM" 'asks for money back'
JFENCE=$(printf '%s' "$JCLAIM" | jq_ 'd["claim_token"]')
# the worker's half of the contract: a verdict with no checkpoint fails the JOB by name
BAD=$(curl -s -X POST $B/api/workers/jobs/$JID/complete -H "Authorization: Bearer $WT" \
  -d "{\"claim_token\":\"$JFENCE\",\"result\":{\"verdict_json\":\"{\\\"answers\\\":{}}\"}}")
assert "a verdict naming no checkpoint fails the job" "$(G /api/jobs/$JID)" 'names no checkpoint'
# again, properly: claim the retry and answer like laya does
JJOB2=$(P /api/jobs "{\"kind\":\"judge.typed\",\"payload\":{\"request_json\":$(printf '%s' "$JREQ" | jq -Rs .)}}")
JID2=$(printf '%s' "$JJOB2" | jq_ 'd["id"]')
JCLAIM2=$(curl -s -X POST $B/api/workers/claim -H "Authorization: Bearer $WT" -d '{"kinds":["judge.typed"],"max_wait":2}')
JFENCE2=$(printf '%s' "$JCLAIM2" | jq_ 'd["claim_token"]')
JVERDICT='{"model":"aac6fef/laya-mlx@20aed81 float16","answers":{"refund":{"type":"noul","noul":0.93,"confidence":0.93}},"usage":{"input_tokens":64,"output_tokens":0}}'
assert "the verdict lands" \
  "$(curl -s -X POST $B/api/workers/jobs/$JID2/complete -H "Authorization: Bearer $WT" \
      -d "{\"claim_token\":\"$JFENCE2\",\"result\":{\"verdict_json\":$(printf '%s' "$JVERDICT" | jq -Rs .)}}")" '"ok":true'
assert "…stored AS RECEIVED, checkpoint and all"  "$(G /api/jobs/$JID2)" 'laya-mlx@20aed81'
assert "…and the job is done"                     "$(G /api/jobs/$JID2)" '"status":"done"'
# JUDGE-10: a judgment bills its own dimension, one per question — output_tokens
# is 0 on this wire, so the token meter cannot see it. The limit makes quota-check
# read the ledger (used reports 0 with no limit set, by design).
assert "a judgments quota can be set"             "$(P /api/quota '{"dimension":"ai.judgments.total","limit":100,"window":"day"}')" '"ok":true'
assert "…and the verdict above was billed on it"  "$(G /api/usage)" '"dimension":"ai.judgments.total","limit":100,"remaining":99'

echo
echo "== 8d. issue #93: a host whose model is down hands jobs back, and stops taking them =="
# A model endpoint that cannot answer is this HOST's problem, not the job's, and
# the old behaviour was worse than "costs an attempt": worker-fail! is TERMINAL
# (status error, no requeue), so one outage killed the job on its first try.
# `busy` is the reason PULL-12 defined for exactly this and that nothing sent.
W93(){ env TELEMACHUS_URL="http://127.0.0.1:$PORT" TELEMACHUS_WORKER_TOKEN="$WT" \
        TELEMACHUS_WORKER_MODELS=mock "$@" racket cli/telemachus-worker.rkt --once \
        >>"$TELEMACHUS_DATA_DIR/worker.log" 2>&1; }
newjob(){ P /api/jobs "{\"kind\":\"infer.chat\",\"payload\":{\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]}}" | jq_ 'd["id"]'; }
att(){ G /api/jobs/$1 | jq_ 'd["attempt"]'; }
lastaudit(){ G '/api/audit?limit=1'; }

# (a) nothing listening at all
DJ=$(newjob "model is down"); DA=$(att $DJ)
W93 TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$DEAD_PORT"
assert "an unreachable model requeues the job"   "$(G /api/jobs/$DJ)" '"status":"queued"'
# The point of the issue: the job is not blamed for the host's problem.
assert "…spending no attempt"                    "$(att $DJ)" "$DA"
assert "…recorded as a RELEASE, not a failure"   "$(lastaudit)" '"action":"job.released"'
assert "…and the worker says it handed it back"  "$(tail -40 "$TELEMACHUS_DATA_DIR/worker.log")" 'HANDED BACK'
curl -s -X POST $B/api/jobs/$DJ/cancel -H "Authorization: Bearer $TOK" >/dev/null

# (b) a gateway or a model server refusing: 502/503/504 is "not now"
SJ=$(newjob "model refuses"); SA=$(att $SJ)
W93 TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK503_PORT"
assert "a 503 from the model requeues the job"   "$(G /api/jobs/$SJ)" '"status":"queued"'
assert "…spending no attempt"                    "$(att $SJ)" "$SA"
assert "…recorded as a release too"              "$(lastaudit)" '"action":"job.released"'
curl -s -X POST $B/api/jobs/$SJ/cancel -H "Authorization: Bearer $TOK" >/dev/null

# (c) a 4xx is OUR malformed request and a 500 is the model failing on THIS
# input. Both are the job's problem and must still FAIL it, or a bad job would
# ride the queue for ever being handed from worker to worker.
FJ=$(newjob "model is broken")
W93 TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK500_PORT"
assert "a 500 from the model still fails the job" "$(G /api/jobs/$FJ)" '"status":"error"'
assert "…naming what the model said"              "$(G /api/jobs/$FJ)" 'model endpoint returned HTTP 500'

# (d) the readiness gate. A release alone cannot cover a longer outage: the
# cool-off is 30s for the releasing worker and MAX-RELEASES fails the job, so one
# host busy for five minutes would fail every queued job it touched.
# TELEMACHUS_WORKER_READY_URL is asked BEFORE each claim, so a host that cannot
# serve takes nothing at all.
GJ=$(newjob "gated"); GA=$(att $GJ)
W93 TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK_PORT" \
    TELEMACHUS_WORKER_READY_URL="http://127.0.0.1:$DEAD_PORT/ready"
assert "a worker that is not ready claims nothing" "$(G /api/jobs/$GJ)" '"status":"queued"'
assert "…spending no attempt"                      "$(att $GJ)" "$GA"
# Visibly alive and REFUSING, rather than quiet — quiet is what a crashed worker
# looks like, which is the gap #58 opened and this closes for an outage.
assert "…and reports paused rather than going quiet" "$(G /api/executors)" '"worker_state":"paused"'
assert "…while status still says active"             "$(G /api/executors)" '"status":"active"'
# 2xx means take work. The server's own /health is a ready endpoint that needs no
# stub, and the check is deliberately ignorant of what readiness MEANS — VRAM,
# memory, load or a schedule are all the operator's business, not the platform's.
W93 TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK_PORT" \
    TELEMACHUS_WORKER_READY_URL="http://127.0.0.1:$PORT/health"
assert "…and a ready host claims and runs it"      "$(G /api/jobs/$GJ)" '"status":"done"'

echo
echo "== 8e. issue #60: a worker token may expire, and a rotation OVERLAPS =="
# This instance has no lifetime configured, which is the shipped default and the
# whole upgrade-safety argument: nothing anybody has deployed stops working.
WTOK(){ curl -s $B/api/workers/token -H "Authorization: Bearer ${1:-$WT}"; }
claim_code(){ curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/claim \
                -H "Authorization: Bearer $1" -d '{"kinds":["infer.chat"],"max_wait":0}'; }
assert "a worker reads its own credential"   "$(WTOK)" '"expires_at":null'
assert "…and is told there is nothing to do" "$(WTOK)" '"rotate":false'
assert "…and what the instance configured"   "$(WTOK)" '"ttl_seconds":null'
# the credential plane is the WORKER's: an operator token is not bound to a host
assert "a user token is not a worker"        "$(WTOK "$TOK")" 'not bound to an executor'

# An UNSOLICITED rotation inside the floor is refused. This instance configured
# no lifetime, so the platform is asking for nothing, and a worker rotating
# anyway in a loop would mint a credential per poll. The floor never refuses a
# rotation the platform ASKED for — section 8f is that case, and it is what the
# reference worker does.
assert "an unsolicited rotation is rate-limited" \
  "$(curl -s -X POST $B/api/workers/token -H "Authorization: Bearer $WT" -d '{}')" 'less than 300 seconds ago'
assert "…with the code a worker backs off on" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workers/token -H "Authorization: Bearer $WT" -d '{}')" '429'
assert "…and says when to come back"         \
  "$(curl -s -D - -o /dev/null -X POST $B/api/workers/token -H "Authorization: Bearer $WT" -d '{}' | tr -d '\r')" 'Retry-After: 300'

# The operator's plane, for a third-party worker that cannot rotate itself and
# for a token believed leaked. It is NEVER refused for rotating too often —
# a leak is not a reason to wait five minutes.
WT_A="$WT"
OROT=$(P /api/executors/$EXID/rotate-token)
assert "an operator may rotate for the host" "$OROT" '"token":"tk_'
WT_B=$(printf '%s' "$OROT" | jq_ 'd["token"]')
assert "…a different credential"             "$([ -n "$WT_B" ] && [ "$WT_B" != "$WT_A" ] && echo differs)" 'differs'
assert "…saying the old one still works"     "$OROT" 'shown once'
assert "the new token claims"                "$(claim_code "$WT_B")" '204'
# THE OVERLAP, over the wire: a host that has not finished deploying the new
# credential is still working, which is what makes an expiry survivable at all.
assert "…and the one it replaced still does" "$(claim_code "$WT_A")" '204'
assert "…which now has a horizon"            "$(WTOK "$WT_A")" '"overlap_seconds":3600'
# Two slots and no more: a third rotation revokes the oldest outright, so "how
# many live credentials does this host have" has an answer, and it is two.
OROT2=$(P /api/executors/$EXID/rotate-token)
assert "an operator rotation is never too soon" "$OROT2" '"token":"tk_'
WT=$(printf '%s' "$OROT2" | jq_ 'd["token"]')
assert "the token it replaced keeps working" "$(claim_code "$WT_B")" '204'
assert "…while the one before that is dead"  "$(claim_code "$WT_A")" '401'
assert "every rotation is in the trail"      "$(G '/api/audit?limit=5')" 'executor.token.rotate'
assert "the new credential still claims"     "$(claim_code "$WT")" '204'

echo
echo "== 8f. issue #60: the reference worker rotates itself, and refuses to without a file =="
# A second instance, booted with a 43-second worker-token lifetime: the knob is
# read from the server's environment, so this cannot be done to the one above
# without expiring every token the earlier sections depend on.
ROT_DIR=$(mktemp -d)
env TELEMACHUS_DATA_DIR="$ROT_DIR" DATABASE_URL="sqlite:///$ROT_DIR/t.db" \
    PORT="$ROT_PORT" TELEMACHUS_WORKER_TOKEN_DAYS=0.0005 \
    racket server/main.rkt >"$ROT_DIR/server.log" 2>&1 & SRV2=$!
until (exec 3<>/dev/tcp/127.0.0.1/$ROT_PORT) 2>/dev/null; do :; done; exec 3>&- 2>/dev/null || true
B2="localhost:$ROT_PORT"
TOK2=$(curl -s -X POST $B2/api/bootstrap -d '{"username":"ops","password":"pw-pw-pw1"}' | jq_ 'd["token"]')
curl -s -X POST $B2/api/quota -H "Authorization: Bearer $TOK2" -d '{"dimension":"ai.tokens.total","limit":1000000,"window":"day"}' >/dev/null
EX2=$(curl -s -X POST $B2/api/executors -H "Authorization: Bearer $TOK2" \
       -d '{"name":"rotator","mode":"pull","model":"mock","capabilities":{"kinds":["infer.chat"]}}')
WT_R=$(printf '%s' "$EX2" | jq_ 'd["worker_token"]')
assert "a configured lifetime reaches the token" \
  "$(curl -s $B2/api/workers/token -H "Authorization: Bearer $WT_R")" '"ttl_seconds":43'
assert "…and the platform asks for a rotation at once" \
  "$(curl -s $B2/api/workers/token -H "Authorization: Bearer $WT_R")" '"rotate":true'

W60(){ env TELEMACHUS_URL="http://127.0.0.1:$ROT_PORT" TELEMACHUS_WORKER_TOKEN="$WT_R" \
        TELEMACHUS_WORKER_MODELS=mock TELEMACHUS_WORKER_MODEL_URL="http://127.0.0.1:$MOCK_PORT" \
        "$@" racket cli/telemachus-worker.rkt --once >>"$ROT_DIR/worker.log" 2>&1; }
newjob2(){ curl -s -X POST $B2/api/jobs -H "Authorization: Bearer $TOK2" \
             -d "{\"kind\":\"infer.chat\",\"payload\":{\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]}}" | jq_ 'd["id"]'; }

# A WORKER THAT CANNOT PERSIST A NEW TOKEN MUST NOT ROTATE. It would receive
# one, forget it, and go on working on the outgoing credential until the overlap
# ended — a rotation it asked for, turned into the outage the overlap prevents.
RJ1=$(newjob2 "before rotation")
W60 TELEMACHUS_WORKER_TOKEN_FILE=
assert "with no token file the worker does not rotate" \
  "$(curl -s $B2/api/executors -H "Authorization: Bearer $TOK2")" '"prev_token_id":null'
assert "…and says an operator has to rotate for it" "$(cat $ROT_DIR/worker.log)" 'cannot keep a new one'
assert "…while still doing its work"                "$(curl -s $B2/api/jobs/$RJ1 -H "Authorization: Bearer $TOK2")" '"status":"done"'

# With somewhere to put it, the host rotates itself: no person, no outage.
RJ2=$(newjob2 "after rotation")
W60 TELEMACHUS_WORKER_TOKEN_FILE="$ROT_DIR/token"
assert "with a token file it rotates itself"  "$(cat $ROT_DIR/worker.log)" 'worker token rotated'
assert "…persisting the new token"            "$([ -s "$ROT_DIR/token" ] && echo yes)" 'yes'
assert "…which is not the one it started with" "$([ "$(cat $ROT_DIR/token)" != "$WT_R" ] && echo differs)" 'differs'
assert "…and the server agrees it rotated"    "$(curl -s $B2/api/executors -H "Authorization: Bearer $TOK2")" '"prev_token_id":"'
assert "…and the job still ran"               "$(curl -s $B2/api/jobs/$RJ2 -H "Authorization: Bearer $TOK2")" '"status":"done"'
# the persisted token is the durable home: a restart reads the FILE, not the
# bootstrap variable, which is what makes the next rotation possible
assert "the persisted token is a live credential" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B2/api/workers/claim \
      -H "Authorization: Bearer $(cat $ROT_DIR/token)" -d '{"kinds":["infer.chat"],"max_wait":0}')" '204'
kill $SRV2 2>/dev/null; SRV2=""

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
