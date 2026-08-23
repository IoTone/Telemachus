#!/usr/bin/env bash
# test/translate-chat-demo.sh — the Translate Chat Workflow, end to end (slice 47).
#
# A deliberately useless product and a deliberately thorough test. It exercises,
# in one run:
#
#   • a PLUGIN-OWNED workflow — plugins/translate-chat ships the spec, not just tools
#   • a plugin-registered tool used as a workflow step (chat_message, translate_text)
#   • one step's output feeding two later steps
#   • two chained `map` fan-outs — the second maps over the first's results
#   • ${principal.locale}: "translate back" means the USER'S language, from the profile
#   • a mid-run failure: one broken step stops the run and hands back the reason
#
# NOT part of CI: it needs a real model. Without one the platform's uppercase-echo
# fallback would answer every call, the run would go green, and it would prove
# nothing — so this script refuses to start rather than lie.
#
#   ollama serve &  &&  ollama run qwen2.5:7b   # warm it first; cold start is slow
#   export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
#   export TELEMACHUS_MODEL=qwen2.5:7b
#   bash test/translate-chat-demo.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"

if [ -z "${TELEMACHUS_MODEL_URL:-}" ]; then
  cat >&2 <<'MSG'
TELEMACHUS_MODEL_URL is not set.

This demo translates real text, so it needs a real model. Without one the server
silently falls back to a simulated uppercase echo — every assertion would pass and
the demo would mean nothing, which is worse than failing.

  export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
  export TELEMACHUS_MODEL=qwen2.5:7b
MSG
  exit 2
fi

export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export PORT="${PORT:-8840}"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/telemachus.db}"
MESSAGE="${MESSAGE:-I just shipped the workflow engine and I am cautiously proud of it.}"
NATIVE="${NATIVE:-en}"

fail=0
assert(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"
          else echo "  FAIL $1 — expected to contain: $3 — got: $2"; fail=1; fi; }
jq_(){ python3 -c 'import sys,json;print(eval(sys.argv[1],{"d":json.load(sys.stdin)}))' "$1"; }

port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
if port_busy "$PORT"; then echo "port $PORT is in use — set PORT=<free port>" >&2; exit 1; fi

racket server/main.rkt >/tmp/tmx-tc.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR"' EXIT
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 40000 ] && { echo "server never came up"; cat /tmp/tmx-tc.log; exit 1; }
done; exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
P(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }

echo "translate-chat demo — model: ${TELEMACHUS_MODEL:-?} at $TELEMACHUS_MODEL_URL"
echo

echo "== 0. bootstrap, and set the user's own language ==============================="
TOK=$(curl -s -X POST $B/api/bootstrap -d '{"username":"ada","password":"demo-pass1"}' | jq_ 'd["token"]')
assert "profile locale set" "$(P /api/profile "{\"locale\":\"$NATIVE\"}")" "\"locale\":\"$NATIVE\""
assert "whoami reports it"  "$(G /api/whoami)" "\"locale\":\"$NATIVE\""

echo
echo "== 1. the workflow arrived from the PLUGIN, not from a publish call ============"
WFS=$(G /api/workflows)
assert "translate-chat present" "$WFS" '"slug":"translate-chat"'
assert "source is the plugin"   "$WFS" '"source":"plugin:translate-chat"'
SPEC=$(G /api/workflows/translate-chat)
assert "three steps"      "$SPEC" '"id":"back_home"'
assert "fan-out declared" "$SPEC" '"uses":"map"'
assert "binds the profile language" "$SPEC" '${principal.locale}'
echo "  --- the spec a deployer can read, without reading any Racket ---"
printf '%s' "$SPEC" | python3 -c '
import sys, json
for st in json.load(sys.stdin)["spec"]["steps"]:
    sid, uses = st["id"], st["uses"]
    if uses == "map":
        print("      %-10s map over %s -> %s" % (sid, json.dumps(st["over"]), st["step"]["uses"]))
    else:
        print("      %-10s %s" % (sid, uses))'

echo
echo "== 2. run it: chat once, out to 3 languages, then all 3 back ==================="
echo "  message: \"$MESSAGE\""
RID=$(python3 -c 'import json,sys;print(json.dumps({"input":{"message":sys.argv[1]}}))' "$MESSAGE" \
      | curl -s -X POST $B/api/workflows/translate-chat/run -H "Authorization: Bearer $TOK" -d @- | jq_ 'd["id"]')
echo "  run $RID — 7 model calls, this takes a moment"
for _ in $(seq 1 120); do
  RUN=$(G /api/runs/$RID)
  ST=$(printf '%s' "$RUN" | jq_ 'd["status"]')
  [ "$ST" = "running" ] || break
  sleep 2
done
assert "run completed" "$RUN" '"status":"done"'
printf '%s' "$RUN" | python3 -c '
import sys,json
d=json.load(sys.stdin)
by={s["step_id"]:s for s in d["steps"]}
langs={"es":"Spanish","nl":"Dutch","is":"Icelandic"}
if d["status"]!="done":
    print("      run did not finish:", d.get("error")); raise SystemExit
print("\n      reply (the chat step):\n       ", by["chat"]["output"]["result"].strip()[:300])
out=[r["result"].strip() for r in by["to_all"]["output"]["results"]]
back=[r["result"].strip() for r in by["back_home"]["output"]["results"]]
for code,o,b in zip(["es","nl","is"],out,back):
    print(f"\n      -> {langs[code]}:\n         {o[:220]}")
    print(f"      <- back:\n         {b[:220]}")'

echo
echo "== 3. the fan-out really was 3 separate jobs ==================================="
assert "child 0" "$RUN" '"step_id":"to_all#0"'
assert "child 2" "$RUN" '"step_id":"to_all#2"'
assert "second fan-out chained off the first" "$RUN" '"step_id":"back_home#2"'
STEPS=$(printf '%s' "$RUN" | jq_ 'len(d["steps"])')
echo "  ($STEPS step rows: 1 chat + 1 fan-out parent + 3 children, twice over)"

echo
echo "== 4. a failing step cancels the rest and reports back ========================="
# switch the translation tool off mid-demo: the chat step still succeeds, then every
# child of the first fan-out fails, the fan-out fails, and the run stops there
curl -s -X POST $B/api/tools/translate_text -H "Authorization: Bearer $TOK" -d '{"enabled":false}' >/dev/null
RID2=$(python3 -c 'import json,sys;print(json.dumps({"input":{"message":sys.argv[1]}}))' "$MESSAGE" \
       | curl -s -X POST $B/api/workflows/translate-chat/run -H "Authorization: Bearer $TOK" -d @- | jq_ 'd["id"]')
for _ in $(seq 1 60); do
  RUN2=$(G /api/runs/$RID2)
  ST2=$(printf '%s' "$RUN2" | jq_ 'd["status"]')
  [ "$ST2" = "running" ] || break
  sleep 2
done
assert "run stopped with an error" "$RUN2" '"status":"error"'
assert "the reason names the step" "$RUN2" "step 'to_all"
assert "…and the cause"            "$RUN2" "translate_text' is disabled"
assert "the fan-out is marked"     "$RUN2" '"status":"error","step_id":"to_all"'
# the run never reached the second fan-out — that is the "cancel the rest" property
if printf '%s' "$RUN2" | grep -qF '"step_id":"back_home'; then
  echo "  FAIL later steps ran anyway"; fail=1
else echo "  ok   later steps never ran"; fi
echo "  error surfaced to the initiator:"
printf '%s' "$RUN2" | python3 -c 'import sys,json;print("       ",json.load(sys.stdin)["error"])'
curl -s -X POST $B/api/tools/translate_text -H "Authorization: Bearer $TOK" -d '{"enabled":true}' >/dev/null

echo
if [ $fail -eq 0 ]; then echo "translate-chat-demo: PASS"; else echo "translate-chat-demo: FAIL"; fi
exit $fail
