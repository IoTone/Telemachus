#!/usr/bin/env bash
# test/server-smoke.sh — integration test for the HTTP server (slice 3).
# Boots the server on a temp DB, exercises the RBAC + localization flow, asserts.
# Run from refimpl/racketmaximus/ :  bash test/server-smoke.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
export PORT="${PORT:-8835}"   # must be exported — the server reads it from the environment

# Refuse to start if the port is taken — BEFORE creating the temp dir, so a refusal
# leaves nothing behind. Without this the readiness loop below is satisfied by
# SOMEONE ELSE's server (a dev instance on the default 8835) and every assertion
# runs against the wrong database — which reads as a baffling wall of failures
# rather than "the port was busy". The probe runs in a CHILD bash on purpose:
# `(exec 3<>/dev/tcp/...)` in this shell is optimized out of its subshell, so a
# failed redirection would take the script down with it instead of returning false.
port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
if port_busy "$PORT"; then
  echo "port $PORT is already in use — set PORT=<free port>" >&2
  exit 1
fi

export TELEMACHUS_DATA_DIR="$(mktemp -d)"
# Work on a COPY of the catalogs: the Localization Manager block exports, and an
# export must never land in the checkout's tracked locales/ during a test run.
cp -r locales "$TELEMACHUS_DATA_DIR/locales" && export TELEMACHUS_LOCALES="$TELEMACHUS_DATA_DIR/locales"
DB="$TELEMACHUS_DATA_DIR/telemachus.db"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$DB}"   # respect a pre-set URL (e.g. postgres)
echo "smoke DATABASE_URL=$DATABASE_URL"

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
# issue #11: the public probe says up and nothing else; the details moved behind instance:manage
if curl -s $B/health | grep -qE '"kdf"|"version"|"service"|"tls"'; then echo "  FAIL health discloses internals — $(curl -s $B/health)"; fail=1; else echo "  ok   health discloses nothing"; fi
HDRS=$(curl -s -D - -o /dev/null $B/)
assert "nosniff on the console"  "$HDRS" 'X-Content-Type-Options: nosniff'
assert "referrer policy"         "$HDRS" 'Referrer-Policy: strict-origin-when-cross-origin'
assert "frame options"           "$HDRS" 'X-Frame-Options: SAMEORIGIN'
if printf '%s' "$HDRS" | grep -qi 'Strict-Transport-Security'; then echo "  FAIL HSTS sent on a plain-http instance"; fail=1; else echo "  ok   no HSTS without TLS"; fi
assert "headers on JSON too"     "$(curl -s -D - -o /dev/null $B/health)" 'X-Content-Type-Options: nosniff'
# issue #11 part 2: the console's CSP — same-origin everything, no plugins, no base hijack
assert "CSP on the console"      "$HDRS" "Content-Security-Policy: default-src 'self'"
assert "CSP: no object-src"      "$HDRS" "object-src 'none'"
assert "CSP: frame-ancestors"    "$HDRS" "frame-ancestors 'self'"
# issue #12: the raw shell carries a description and Open Graph tags for unfurlers
SHELL_HTML=$(curl -s $B/)
assert "meta description (default)" "$SHELL_HTML" '<meta name="description" content="A self-hosted, privacy-first platform'
assert "og:title (default)"         "$SHELL_HTML" '<meta property="og:title" content="Telemachus">'
# the Tier-B bundle root: a trailing slash means index.html. The route table's `*path`
# once required a segment here and every bundle 404ed — caught by the beta tour, not
# by any smoke, so this pins it (the file is served with nosniff).
assert "bundle root serves index.html" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' $B/beta/bundle/beta-onboarding/)" '200 text/html'
assert "bundle file by path"           "$(curl -s -o /dev/null -w '%{http_code}' $B/beta/bundle/beta-onboarding/index.html)" '200'
assert "bundle traversal refused"      "$(curl -s -o /dev/null -w '%{http_code}' "$B/beta/bundle/beta-onboarding/../plugin.json")" '404'
# …and when the client does NOT collapse it either: a ".." segment reaches the
# server as Racket's 'up symbol, and used to raise a 500 instead of being refused
assert "…even unnormalized"           "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/beta/bundle/beta-onboarding/../plugin.json")" '404'
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
assert "admin status carries the version now" "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"kdf":"'
MB=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')
assert "member token"    "$MB" '"token":"tk_'
BOB=$(printf '%s' "$MB" | grep -oP '"token":\s*"\K[^"]+')
assert "member 403 en"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB")" 'Forbidden: instance:manage'
assert "member 403 ja"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB" -H 'Accept-Language: ja')" '権限がありません'
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
# issue #18: a prompt may be content PARTS, and a malformed one is named rather
# than reaching the provider as an opaque 400
assert "chat: a parts prompt"          "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":[{"type":"text","text":"hello"},{"type":"text","text":" world"}]}')" '"reply":"HELLO WORLD"'
assert "chat: an unsupported part"     "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":[{"type":"input_audio"}]}')" 'unsupported type'
assert "chat: a part with no type"     "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":[{"text":"loose"}]}')" 'content part 0: no'
assert "…and that is a 400"            "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":[{"text":"loose"}]}')" '400'
assert "chat: an unknown response_format" "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hi","response_format":{"type":"yaml"}}')" 'not supported'
assert "chat: a schemaless json_schema"   "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hi","response_format":{"type":"json_schema","json_schema":{"name":"x"}}}')" 'json_schema.schema'
# the simulated fallback cannot honour a format, and says so instead of passing an
# upper-cased echo off as conforming JSON
assert "chat: no model, no format"     "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hi","response_format":{"type":"json_object"}}')" 'no model configured'
assert "chat: a parts prompt streams"  "$(curl -sN -X POST $B/api/ai/chat/stream -H "Authorization: Bearer $OP" -d '{"prompt":[{"type":"text","text":"hello"}]}')" '"done":true'
assert "agent no-model"  "$(curl -s -X POST $B/api/agent -H "Authorization: Bearer $OP" -d '{"prompt":"hi"}')" 'requires a configured model'
assert "tools list"      "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'create_note'
assert "tool toggle off" "$(curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":false}')" '"enabled":false'
TKRESP=$(curl -s -X POST $B/api/tokens -H "Authorization: Bearer $OP" -d '{"name":"ci","scopes":["*:read"]}')
assert "token issued"    "$TKRESP" '"token":"tk_'
TKID=$(printf '%s' "$TKRESP" | grep -oP '"id":"\K[^"]+')
assert "token listed"    "$(curl -s $B/api/tokens -H "Authorization: Bearer $OP")" '"name":"ci"'
assert "token member 403" "$(curl -s $B/api/tokens -H "Authorization: Bearer $BOB")" 'Forbidden: settings:manage'
assert "token revoked"   "$(curl -s -X DELETE $B/api/tokens/$TKID -H "Authorization: Bearer $OP")" '"ok":true'
assert "audit lists"     "$(curl -s $B/api/audit -H "Authorization: Bearer $OP")" '"action":"token'
assert "audit member403" "$(curl -s $B/api/audit -H "Authorization: Bearer $BOB")" 'Forbidden: settings:manage'
assert "search note"     "$(curl -s "$B/api/search?q=Secret" -H "Authorization: Bearer $OP")" '"type":"note"'
assert "doc created"     "$(curl -s -X POST $B/api/documents -H "Authorization: Bearer $OP" -d '{"title":"Spec","content":"the master plan","visibility":"team"}')" '"title":"Spec"'
assert "doc list page"   "$(curl -s $B/api/documents -H "Authorization: Bearer $OP")" '"next_offset"'
assert "doc search"      "$(curl -s "$B/api/search?q=master" -H "Authorization: Bearer $OP")" '"type":"document"'
# async jobs: submit a chat job (fallback model), poll the worker pool to completion
JOB=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"chat","payload":{"prompt":"hello jobs"}}')
assert "job queued"      "$JOB" '"status":"queued"'
JID=$(printf '%s' "$JOB" | grep -oP '"id":"\K[^"]+')
JST=''; for i in $(seq 1 40); do JST=$(curl -s $B/api/jobs/$JID -H "Authorization: Bearer $OP"); printf '%s' "$JST" | grep -q '"status":"done"' && break; sleep 0.25; done
assert "job done"        "$JST" '"status":"done"'
assert "job result"      "$JST" 'HELLO JOBS'
assert "job list"        "$(curl -s $B/api/jobs -H "Authorization: Bearer $OP")" '"kind":"chat"'
# agent job kind: registered + processed to a terminal state (errors cleanly without a model in smoke)
AJ=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"agent","payload":{"prompt":"do something"}}')
AJID=$(printf '%s' "$AJ" | grep -oP '"id":"\K[^"]+')
AST=''; for i in $(seq 1 40); do AST=$(curl -s $B/api/jobs/$AJID -H "Authorization: Bearer $OP"); printf '%s' "$AST" | grep -qE '"status":"(done|error)"' && break; sleep 0.25; done
assert "agent job needs model" "$AST" 'configured model'
assert "seed samples"    "$(curl -s -X POST $B/api/admin/seed -H "Authorization: Bearer $OP")" '"jobs":3'
assert "seed member 403" "$(curl -s -X POST $B/api/admin/seed -H "Authorization: Bearer $BOB")" 'Forbidden: settings:manage'
# beta onboarding: public signup (no account) → async LLM judge → owner review → decide
assert "home config"     "$(curl -s $B/api/config)" '"home":"login"'
assert "beta form cfg"    "$(curl -s $B/api/beta/config)" '"name":"beta"'
# anti-abuse: a direct POST with no challenge is rejected (nothing written to the DB)
assert "beta no-challenge" "$(curl -s -X POST $B/api/beta/signup -d '{"name":"Bot","email":"bot@x.com"}')" 'invalid or expired challenge'
# honeypot filled → silent fake-success, still not stored
assert "beta honeypot"     "$(curl -s -X POST $B/api/beta/signup -d '{"name":"Bot","email":"bot@x.com","_hp":"gotcha"}')" '"ok":true'
# happy path: fetch a challenge, solve the proof-of-work, wait past min fill-time, submit
CH=$(curl -s $B/api/beta/challenge); TOK=$(printf '%s' "$CH" | grep -oP '"challenge":"\K[^"]+')
DIFF=$(printf '%s' "$CH" | grep -oP '"difficulty":\K[0-9]+'); NONCE=${TOK%%.*}
POW=$(PLTCOLLECTS="$(pwd)/pkgs:" racket -e "(require (file \"$(pwd)/domain/beta/antispam.rkt\"))(display (pow-of \"$NONCE\" $DIFF))" 2>/dev/null)
sleep 2   # min fill-time gate
# `job_title` is required:true in the shipped experience. Until required was
# actually ENFORCED this submission passed while omitting it — the form said the
# field was mandatory and the server did not care.
SIGN=$(curl -s -X POST $B/api/beta/signup -d "{\"name\":\"Dana\",\"email\":\"dana@acme.com\",\"company\":\"Acme\",\"job_title\":\"CTO\",\"use_case\":\"team chat\",\"challenge\":\"$TOK\",\"pow\":$POW}")
assert "beta signup"      "$SIGN" '"ok":true'
PID=$(printf '%s' "$SIGN" | grep -oP '"id":"\K[^"]+')
# velocity: a second signup for the same email is capped (default 1 / 24h)
CH2=$(curl -s $B/api/beta/challenge); TOK2=$(printf '%s' "$CH2" | grep -oP '"challenge":"\K[^"]+'); NONCE2=${TOK2%%.*}
POW2=$(PLTCOLLECTS="$(pwd)/pkgs:" racket -e "(require (file \"$(pwd)/domain/beta/antispam.rkt\"))(display (pow-of \"$NONCE2\" $DIFF))" 2>/dev/null)
sleep 2
assert "beta email cap"   "$(curl -s -X POST $B/api/beta/signup -d "{\"name\":\"Dupe\",\"email\":\"dana@acme.com\",\"job_title\":\"CTO\",\"use_case\":\"x\",\"challenge\":\"$TOK2\",\"pow\":$POW2}")" 'we already have your request'

# ---- configurable fields: `required` is enforced FROM THE EXPERIENCE -------------
# The form an applicant fills in is the experience document's `fields` list, and
# until now that list was advisory: `required` rendered a "*" and nothing checked
# it, while a hardcoded rule demanded `name` whatever the form actually showed.
CH3=$(curl -s $B/api/beta/challenge); TOK3=$(printf '%s' "$CH3" | grep -oP '"challenge":"\K[^"]+'); NONCE3=${TOK3%%.*}
POW3=$(PLTCOLLECTS="$(pwd)/pkgs:" racket -e "(require (file \"$(pwd)/domain/beta/antispam.rkt\"))(display (pow-of \"$NONCE3\" $DIFF))" 2>/dev/null)
sleep 2
# use_case is required:true in the shipped config — omitting it is now a refusal,
# and the refusal NAMES the field using the label the applicant actually saw
REQ=$(curl -s -X POST $B/api/beta/signup -d "{\"name\":\"Eve\",\"email\":\"eve@acme.com\",\"job_title\":\"CTO\",\"challenge\":\"$TOK3\",\"pow\":$POW3}")
assert "required field enforced" "$REQ" 'is required'
assert "…and named by its label" "$REQ" 'What would you use Telemachus for?'

# The localized-label case lives in test/e2e/funnel-l10n.sh instead: this suite has
# already spent its 5-per-minute signup budget by here, so asserting it would test
# the rate limiter rather than the message.
# the experience's field constraints are served to the client too, so the browser
# can cap typing and pick a numeric keypad
assert "constraints reach the client" "$(curl -s $B/api/beta/config)" '"required":true'
assert "beta list owner"  "$(curl -s $B/api/beta/prospects -H "Authorization: Bearer $OP")" 'dana@acme.com'
assert "beta member 403"  "$(curl -s $B/api/beta/prospects -H "Authorization: Bearer $BOB")" 'Forbidden: settings:manage'
PS=''; for i in $(seq 1 40); do PS=$(curl -s $B/api/beta/prospects -H "Authorization: Bearer $OP"); printf '%s' "$PS" | grep -q '"status":"reviewed"' && break; sleep 0.25; done
assert "beta judged"      "$PS" '"status":"reviewed"'
assert "beta decide"      "$(curl -s -X POST $B/api/beta/prospects/$PID/decide -H "Authorization: Bearer $OP" -d '{"decision":"qualified"}')" '"status":"qualified"'
assert "plugin loaded"   "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" 'example-tools'
assert "onboarding plug" "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" 'beta-onboarding'
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
# ---- workflows (slice 46) -----------------------------------------------------
# Deliberately BEFORE the quota throttling below: a workflow step is a scheduler
# job, so a zeroed token budget would (correctly) leave its steps deferred forever.
# Note create_note is still DISABLED here, from the tool-toggle assertion above —
# which is what makes the first run a test of per-team tool activation.
assert "wf schema public" "$(curl -s $B/api/workflows/schema)" '"unknown_fields":"rejected"'
assert "wf rejects unknown field" \
  "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $OP" -d '{"spec":1,"slug":"x","steps":[{"id":"a","uses":"tool:t","onError":"ignore"}]}')" \
  "unknown field 'onError'"
assert "wf rejects newer spec" \
  "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $OP" -d '{"spec":2,"slug":"x","steps":[{"id":"a","uses":"tool:t"}]}')" \
  'this server speaks 1'
assert "wf rejects dangling ref" \
  "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $OP" -d '{"spec":1,"slug":"x","steps":[{"id":"a","uses":"tool:t","with":{"v":"${steps.ghost.output.y}"}}]}')" \
  "references unknown step 'ghost'"

WF='{"spec":1,"slug":"smoke-filer","input":{"subject":"string"},"steps":[
 {"id":"write","uses":"tool:create_note","with":{"title":"${input.subject}","body":"via smoke"}},
 {"id":"gate","uses":"choice","when":{"contains":["${steps.write.output.result}","Created note"]},"then":"ok"},
 {"id":"ok","uses":"tool:create_note","with":{"title":"wf-confirmed","body":"${steps.write.output.result}"},"end":true}]}'
assert "wf publish" "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $OP" -d "$WF")" '"slug":"smoke-filer"'
assert "wf listed"  "$(curl -s $B/api/workflows -H "Authorization: Bearer $OP")" '"slug":"smoke-filer"'

# start a run and poll until it leaves 'running'; echoes the final run JSON
wf_run(){ # <subject> -> run json
  local rid
  rid=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
          -d "{\"input\":{\"subject\":\"$1\"}}" | grep -oP '"id":"\K[^"]+' | head -1)
  local rs=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rs=$(curl -s $B/api/runs/$rid -H "Authorization: Bearer $OP")
    printf '%s' "$rs" | grep -qF '"status":"running"' || break
    sleep 0.5
  done
  printf '%s' "$rs"
}

# a step may not do what the team has switched off — activation composes with flows
DISABLED=$(wf_run "Blocked deck")
assert "wf honors tool activation" "$DISABLED" "tool 'create_note' is disabled"
assert "wf fails the run"          "$DISABLED" '"status":"error"'

curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":true}' >/dev/null
DONE=$(wf_run "Smoke deck")
assert "wf run completes"  "$DONE" '"status":"done"'
assert "wf ran the branch" "$DONE" '"step_id":"ok"'
assert "wf did real work"  "$(curl -s $B/api/notes -H "Authorization: Bearer $OP")" '"title":"wf-confirmed"'
assert "wf member cannot publish" \
  "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $BOB" -d "$WF")" 'Forbidden: workflows:write'
curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":false}' >/dev/null  # restore

curl -s -X POST $B/api/quota -H "Authorization: Bearer $OP" -d '{"dimension":"ai.tokens.total","limit":3,"window":"day"}' >/dev/null
assert "quota 429"       "$(curl -s -X POST $B/api/ai/echo -H "Authorization: Bearer $OP" -d '{"prompt":"exceeds the tiny token budget now"}')" 'quota exceeded'
assert "ui served"       "$(curl -s $B/)" '<!doctype html>'

# HEAD reaches every GET route (monitors and unfurlers probe with HEAD; before
# 2026-09-04 every HEAD returned a JSON 404 from a healthy server), and
# web-server suppresses response bodies for HEAD itself.
assert "HEAD / is not a 404"        "$(curl -s -o /dev/null -w '%{http_code}' -I $B/)" "200"
assert "HEAD /health is not a 404"  "$(curl -s -o /dev/null -w '%{http_code}' -I $B/health)" "200"
assert "HEAD /api/branding is not a 404" "$(curl -s -o /dev/null -w '%{http_code}' -I $B/api/branding)" "200"

# The raw HTML title comes from the instance's configured branding, not the
# codename hardcoded in the static shell -- crawlers and unfurlers never run
# the SPA that would otherwise correct it. Fresh instance: the shipped
# default. After branding is set: the configured title, HTML-escaped.
assert "unbranded instance serves the default title" "$(curl -s $B/)" '<title>Telemachus</title>'
assert "branding title set" "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"title":"RCNT","tagline":"Import Compliance AI Platform"}')" '"title":"RCNT"'
assert "branded instance serves the configured title" "$(curl -s $B/)" '<title>RCNT</title>'
assert "…and og:title"                                "$(curl -s $B/)" '<meta property="og:title" content="RCNT">'
assert "…and the tagline as the description"         "$(curl -s $B/)" '<meta name="description" content="Import Compliance AI Platform">'
assert "a markup-bearing title is escaped, not injected" \
  "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"title":"<script>x</script>"}' >/dev/null; curl -s $B/)" \
  '<title>&lt;script&gt;x&lt;/script&gt;</title>'
# restore the default so later assertions and reruns start from a clean slate
curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{}' >/dev/null
assert "blank title put falls back to the default" "$(curl -s $B/api/branding)" '"title":"Telemachus"'

# ---- integrator theming: the console's palette rides the branding document
assert "branding carries a theme"      "$(curl -s $B/api/branding)" '"theme":'
assert "…the shipped palette by default" "$(curl -s $B/api/branding)" '"bg":"#0b1a2b"'
THEME='{"title":"Acme","theme":{"bg":"#101014","surface":"#1b1b22","ink":"#f5f5f7","muted":"#a0a0ad","brand":"#c9a227","brandInk":"#ffffff","radius":"12px","mode":"dark","fontBody":"Serif"}}'
assert "a theme is stored"             "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d "$THEME")" '"brand":"#c9a227"'
assert "…and served to the PUBLIC sign-in screen" "$(curl -s $B/api/branding)" '"brand":"#c9a227"'
assert "an unknown token is refused"   "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"theme":{"accent":"#ffffff"}}')" 'unknown theme token'
assert "…as a 400"                     "$(curl -s -o /dev/null -w '%{http_code}' -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"theme":{"accent":"#ffffff"}}')" '400'
assert "a non-colour is refused"       "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"theme":{"bg":"url(x)"}}')" 'must be a hex colour'
assert "an illegible theme is refused" "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"theme":{"bg":"#ffffff","ink":"#fefefe"}}')" 'will not be able to read it'
assert "…and the stored theme is untouched" "$(curl -s $B/api/branding)" '"brand":"#c9a227"'
assert "a member cannot theme the instance" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT $B/api/branding -H "Authorization: Bearer $BOB" -d "$THEME")" '403'
curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"title":"Telemachus"}' >/dev/null
assert "reset restores the shipped palette" "$(curl -s $B/api/branding)" '"brand":"#6fa0d1"'
assert "members list"    "$(curl -s $B/api/members -H "Authorization: Bearer $OP")" '"username":"bob"'
assert "unauth 401 en"   "$(curl -s $B/api/whoami)" 'Authentication required.'
assert "unauth 401 ja"   "$(curl -s $B/api/whoami -H 'Accept-Language: ja')" '認証が必要です'
# feature flags (last — gating chat would break earlier chat assertions)
assert "feature list"    "$(curl -s $B/api/features -H "Authorization: Bearer $OP")" '"feature":"chat"'
assert "feature off"     "$(curl -s -X POST $B/api/features/chat -H "Authorization: Bearer $OP" -d '{"enabled":false}')" '"enabled":false'
assert "chat gated"      "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hi"}')" 'Forbidden: chat'
assert "feature on"      "$(curl -s -X POST $B/api/features/chat -H "Authorization: Bearer $OP" -d '{"enabled":true}')" '"enabled":true'
# job quota metering: throttle tokens to 0, then a new job DEFERS (stays queued, not run)
curl -s -X POST $B/api/quota -H "Authorization: Bearer $OP" -d '{"dimension":"ai.tokens.total","limit":0,"window":"day"}' >/dev/null
QJ=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"chat","payload":{"prompt":"blocked"}}')
QJID=$(printf '%s' "$QJ" | grep -oP '"id":"\K[^"]+')
sleep 1.5
assert "job quota-gated" "$(curl -s $B/api/jobs/$QJID -H "Authorization: Bearer $OP")" '"status":"queued"'
assert "metrics"         "$(curl -s $B/api/metrics -H "Authorization: Bearer $OP")" '"users"'
assert "metrics 403"     "$(curl -s $B/api/metrics -H "Authorization: Bearer $BOB")" 'Forbidden: instance:manage'

# ---- document repository (slices 49-50) --------------------------------------
# Bytes over the wire, not base64 in JSON. The payload deliberately contains a NUL
# and invalid UTF-8, because "any format" is the requirement and a text-shaped
# pipeline would corrupt exactly this.
printf '%%PDF-1.7\n\000\377\376binary\000trailer' > /tmp/tmx-smoke-doc.pdf
RPUT=$(curl -s -X PUT "$B/api/repo/reports/q3.pdf?filename=q3.pdf&visibility=private" \
        -H "Authorization: Bearer $OP" -H 'Content-Type: application/pdf' \
        --data-binary @/tmp/tmx-smoke-doc.pdf)
assert "repo upload"        "$RPUT" '"key":"reports/q3.pdf"'
assert "repo private"       "$RPUT" '"visibility":"private"'
RID=$(printf '%s' "$RPUT" | grep -oP '"id":"\K[^"]+' | head -1)

curl -s "$B/api/repo-obj/$RID/content" -H "Authorization: Bearer $OP" -o /tmp/tmx-smoke-back.pdf
if cmp -s /tmp/tmx-smoke-doc.pdf /tmp/tmx-smoke-back.pdf; then echo "  ok   repo bytes round-trip"; else echo "  FAIL repo bytes round-trip"; fail=1; fi

# A PDF may be shown inline when the caller asks. ACTIVE content may not, ever:
# an SVG rendered inline from this origin is stored XSS with the console behind it.
PDFH=$(curl -s -D - -o /dev/null "$B/api/repo-obj/$RID/content?disposition=inline" -H "Authorization: Bearer $OP")
assert "repo pdf inline ok"  "$PDFH" 'Content-Disposition: inline'
assert "repo nosniff"        "$PDFH" 'X-Content-Type-Options: nosniff'
assert "repo csp"            "$PDFH" "Content-Security-Policy: default-src 'none'; sandbox"

printf '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' > /tmp/tmx-smoke.svg
SVG=$(curl -s -X PUT "$B/api/repo/evil.svg" -H "Authorization: Bearer $OP" \
       -H 'Content-Type: image/svg+xml' --data-binary @/tmp/tmx-smoke.svg)
SVGID=$(printf '%s' "$SVG" | grep -oP '"id":"\K[^"]+' | head -1)
SVGH=$(curl -s -D - -o /dev/null "$B/api/repo-obj/$SVGID/content?disposition=inline" -H "Authorization: Bearer $OP")
assert "svg forced download" "$SVGH" 'Content-Disposition: attachment'
assert "svg type neutralised" "$SVGH" 'Content-Type: application/octet-stream'
curl -s -X DELETE "$B/api/repo-obj/$SVGID" -H "Authorization: Bearer $OP" >/dev/null
rm -f /tmp/tmx-smoke.svg

# a colleague cannot read someone else's private document, or even see it listed
assert "repo private 403"   "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $BOB")" 'Forbidden: files:read'
# seeded sample documents live in the repository now, so the listing is never
# empty — what must be hidden is the PRIVATE key itself
BOBLIST=$(curl -s "$B/api/repo" -H "Authorization: Bearer $BOB")
if printf '%s' "$BOBLIST" | grep -qF 'reports/q3.pdf'; then echo "  FAIL repo hidden — the private key leaked into a colleague's listing"; fail=1; else echo "  ok   repo hidden"; fi

# the creator shares it with exactly that colleague, and then it resolves
BOBID=$(printf '%s' "$MB" | grep -oP '"user_id":\s*"\K[^"]+')
curl -s -X POST "$B/api/repo-obj/$RID/share" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$BOBID\"}" >/dev/null
assert "repo shared read"   "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $BOB")" '"key":"reports/q3.pdf"'

# ---- sharing with permissions (slice 56, DSH-1…6) ---------------------------------
SHARE="$B/api/repo-obj/$RID/share"; UNSHARE="$B/api/repo-obj/$RID/unshare"
# a VIEWER cannot forward what they were shown (DSH-2)
assert "share: viewer no re-share" "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $BOB" -d "{\"user_id\":\"$CAROL_ID\"}")" 'Forbidden: files:manage'
assert "share: carol still out"   "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" 'Forbidden: files:read'
# the grant list names a CAPABILITY, not a permission string
assert "share: grants list"       "$(curl -s "$B/api/repo-obj/$RID/grants" -H "Authorization: Bearer $OP")" '"capability":"view"'
# expiry (DSH-3): the past is refused, garbage is refused, the future opens and is listed
assert "share: past expiry 400"   "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$CAROL_ID\",\"expires_at\":\"2020-01-01T00:00:00Z\"}")" 'in the past'
assert "share: bad expiry 400"    "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$CAROL_ID\",\"expires_at\":\"soon\"}")" 'ISO-8601'
SH=$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"principal_type\":\"user\",\"principal_id\":\"$CAROL_ID\",\"capability\":\"edit\",\"expires_at\":\"2099-01-01T00:00:00Z\"}")
assert "share: edit capability"   "$SH" '"capability":"edit"'
assert "share: expiry listed"     "$SH" '"expires_at":"2099-01-01T00:00:00Z"'
assert "share: editor reads"      "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" '"key":"reports/q3.pdf"'
assert "share: editor no re-share" "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $CAROL" -d "{\"user_id\":\"$BOBID\"}")" 'Forbidden: files:manage'
# revoke removes every row the principal held
curl -s -X POST "$UNSHARE" -H "Authorization: Bearer $OP" -d "{\"principal_type\":\"user\",\"principal_id\":\"$CAROL_ID\"}" >/dev/null
assert "share: revoked"           "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" 'Forbidden: files:read'
# a TEAM is a principal (DSH-6): every member reads it, nobody needed a row
TEAMID=$(curl -s $B/api/whoami -H "Authorization: Bearer $OP" | grep -oP '"team_id":\s*"\K[^"]+')
assert "share: team grant"        "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"principal_type\":\"team\",\"principal_id\":\"$TEAMID\"}")" '"principal_type":"team"'
assert "share: team member reads" "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" '"key":"reports/q3.pdf"'
curl -s -X POST "$UNSHARE" -H "Authorization: Bearer $OP" -d "{\"principal_type\":\"team\",\"principal_id\":\"$TEAMID\"}" >/dev/null
assert "share: team revoked"      "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" 'Forbidden: files:read'
# `manage` delegates stewardship of ONE document: bob, a plain member, may now share it onward
curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$BOBID\",\"capability\":\"manage\"}" >/dev/null
assert "share: manage re-shares"  "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $BOB" -d "{\"user_id\":\"$CAROL_ID\"}")" '"ok":true'
assert "share: carol reads again" "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $CAROL")" '"key":"reports/q3.pdf"'
# bad input is a 400, never a row
assert "share: bad capability"    "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$CAROL_ID\",\"capability\":\"owner\"}")" 'capability must be one of'
assert "share: unknown user"      "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d '{"user_id":"nobody"}')" 'no such user'
assert "share: no principal"      "$(curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d '{}')" 'is required'
# provenance: an upload derives from nothing
assert "share: derivations"       "$(curl -s "$B/api/repo-obj/$RID/derivations" -H "Authorization: Bearer $OP")" '"derivations":[]'
# DSH step 3 / DWF step 4 reads: who can be shared with, what was shared with me, what processed it
assert "share targets: people"  "$(curl -s "$B/api/share-targets" -H "Authorization: Bearer $OP")" '"username":"bob"'
assert "share targets: teams"   "$(curl -s "$B/api/share-targets" -H "Authorization: Bearer $OP")" '"own":true'
assert "shared with me (carol)" "$(curl -s "$B/api/repo?shared=1" -H "Authorization: Bearer $CAROL")" '"key":"reports/q3.pdf"'
if curl -s "$B/api/repo?shared=1" -H "Authorization: Bearer $OP" | grep -qF 'reports/q3.pdf'; then echo "  FAIL shared with me (owner) — the owner's own document is not 'shared with me'"; fail=1; else echo "  ok   shared with me (owner)"; fi
assert "processing: nothing yet" "$(curl -s "$B/api/repo-obj/$RID/processing" -H "Authorization: Bearer $OP")" '"runs":[]'
# leave bob as a viewer, which is what the checks below assume
curl -s -X POST "$SHARE" -H "Authorization: Bearer $OP" -d "{\"user_id\":\"$BOBID\"}" >/dev/null
assert "share: narrowed to view"  "$(curl -s "$B/api/repo-obj/$RID/grants" -H "Authorization: Bearer $OP")" '"permissions":["files:read"]'

# an overwrite versions rather than destroys, and keeps the visibility it had
printf 'second draft' > /tmp/tmx-smoke-doc2.pdf
RPUT2=$(curl -s -X PUT "$B/api/repo/reports/q3.pdf" -H "Authorization: Bearer $OP" \
         -H 'Content-Type: application/pdf' --data-binary @/tmp/tmx-smoke-doc2.pdf)
assert "repo versioned"     "$RPUT2" '"version":2'
# sharing a PRIVATE document adds a grant without relabelling it; only a
# team-visible document is narrowed to 'shared'. Either way the overwrite must not
# change it.
assert "repo keeps vis"     "$RPUT2" '"visibility":"private"'
assert "repo version list"  "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $OP")" '"version":1'

# storage is a gauge: it goes up on write and back down on delete
assert "repo usage"         "$(curl -s "$B/api/repo" -H "Authorization: Bearer $OP")" '"dimension":"storage.bytes"'
curl -s -X DELETE "$B/api/repo-obj/$RID" -H "Authorization: Bearer $OP" >/dev/null
DELLIST=$(curl -s "$B/api/repo" -H "Authorization: Bearer $OP")
if printf '%s' "$DELLIST" | grep -qF 'reports/q3.pdf'; then echo "  FAIL repo deleted — the key is still listed"; fail=1; else echo "  ok   repo deleted"; fi
assert "repo gone"          "$(curl -s "$B/api/repo-obj/$RID" -H "Authorization: Bearer $OP")" 'not found'
rm -f /tmp/tmx-smoke-doc.pdf /tmp/tmx-smoke-doc2.pdf /tmp/tmx-smoke-back.pdf

# a repository object is findable in search, by path, like everything else — before
# this an uploaded PDF was invisible while an identically-named text document was not
printf 'x' > /tmp/tmx-smoke-find.pdf
curl -s -X PUT "$B/api/repo/reports/findme-q3.pdf?filename=findme-q3.pdf" \
  -H "Authorization: Bearer $OP" -H 'Content-Type: application/pdf' \
  --data-binary @/tmp/tmx-smoke-find.pdf >/dev/null
SR=$(curl -s "$B/api/search?q=findme" -H "Authorization: Bearer $OP")
assert "search finds a repository object" "$SR" '"type":"file"'
assert "…titled by its path"              "$SR" 'reports/findme-q3.pdf'
# a colleague finds the team-visible object; the private case is covered exhaustively
# in test/repo-tests.rkt, where the assertions can actually distinguish the outcomes
assert "…and a colleague finds it too" \
  "$(curl -s "$B/api/search?q=findme" -H "Authorization: Bearer $BOB")" 'reports/findme-q3.pdf'
rm -f /tmp/tmx-smoke-find.pdf

# ---- instance localization policy (default locale + the off switch) --------------
# Before this the fallback was the literal string "en" in the request wrapper, so
# an operator running a Japanese instance had no way to say so — every visitor
# whose browser did not volunteer `ja` got English, sign-in screen included.
CFG=$(curl -s $B/api/config)
assert "policy is public"        "$CFG" '"localization"'
assert "…default is en"          "$CFG" '"default":"en"'
assert "…negotiation on"         "$CFG" '"enabled":true'
assert "…advertises its catalogs" "$CFG" '"ja"'
# with negotiation ON, the header decides
assert "ja honoured"   "$(curl -s $B/api/whoami -H 'Accept-Language: ja')" '認証が必要です'
assert "en honoured"   "$(curl -s $B/api/whoami -H 'Accept-Language: en')" 'Authentication required'
# an unknown locale lands on the instance DEFAULT, not on a hardcoded English
assert "unknown → default" "$(curl -s $B/api/whoami -H 'Accept-Language: fr')" 'Authentication required'

# flip the instance to Japanese
assert "set default ja" \
  "$(curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"ja","enabled":true}')" '"default":"ja"'
assert "no header → ja now"  "$(curl -s $B/api/whoami)" '認証が必要です'
assert "unknown → ja now"    "$(curl -s $B/api/whoami -H 'Accept-Language: fr')" '認証が必要です'
assert "en still honoured"   "$(curl -s $B/api/whoami -H 'Accept-Language: en')" 'Authentication required'

# turn negotiation OFF: the header stops having a say at all
assert "switch off" \
  "$(curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"ja","enabled":false}')" '"enabled":false'
assert "en request forced to ja" "$(curl -s $B/api/whoami -H 'Accept-Language: en')" '認証が必要です'
assert "console told to hide it" "$(curl -s $B/api/config)" '"enabled":false'

# an unknown locale is a 400, never a silent substitution
assert "unknown locale refused" \
  "$(curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"de","enabled":true}')" 'unknown locale'
assert "…and nothing changed"    "$(curl -s $B/api/config)" '"default":"ja"'
# members cannot touch it
assert "member cannot set" \
  "$(curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $BOB" -d '{"default":"en"}')" 'instance:manage'
# put it back so the rest of the run reads English
assert "restore en" \
  "$(curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"en","enabled":true}')" '"default":"en"'
assert "…and 401 is English again" "$(curl -s $B/api/whoami)" 'Authentication required'

# ---- beta funnel localization (the public sign-up page) --------------------------
# The funnel's copy is operator-authored config, not a shipped catalog, so it is an
# `i18n` overlay on the experience document. What must hold over HTTP: the visitor
# gets ONE language, never the overlay table, and the field KEYS are identical in
# every language — the submitted body cannot depend on which language was read.
BXEN=$(curl -s "$B/api/beta/config")
assert "funnel advertises its locales"  "$BXEN" '"locales":'
assert "…including ja"                  "$BXEN" '"ja"'
assert "…default answers in en"         "$BXEN" '"locale":"en"'
assert "…English copy"                  "$BXEN" 'Join the Telemachus beta'
BXJA=$(curl -s "$B/api/beta/config?lang=ja")
assert "?lang=ja answers in ja"         "$BXJA" '"locale":"ja"'
assert "…localized title"               "$BXJA" 'ベータ版に参加する'
assert "…localized CTA"                 "$BXJA" 'アクセスを申請'
assert "…localized field label"         "$BXJA" '勤務先メールアドレス'
# the data contract is language-independent, by construction (experience.rkt)
assert "…field keys unchanged"          "$BXJA" '"key":"use_case"'
refute "…overlay table never shipped"   "$BXJA" '"i18n"'
refute "…judge prompt never shipped"    "$BXJA" 'judge-system'
# the header works too, and a region tag reaches the base language
assert "header selects ja" "$(curl -s "$B/api/beta/config" -H 'X-Telemachus-Locale: ja')" '"locale":"ja"'
assert "ja-JP → ja"        "$(curl -s "$B/api/beta/config?lang=ja-JP")" '"locale":"ja"'
# a locale with no overlay falls back whole, never half-translated
BXFR=$(curl -s "$B/api/beta/config?lang=fr")
assert "unknown locale falls back"  "$BXFR" '"locale":"en"'
assert "…to complete English"       "$BXFR" 'Join the Telemachus beta'
# and the instance off switch governs the funnel like every other surface
curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"en","enabled":false}' >/dev/null
assert "negotiation off pins the funnel" "$(curl -s "$B/api/beta/config?lang=ja")" '"locale":"en"'
curl -s -X PUT $B/api/i18n -H "Authorization: Bearer $OP" -d '{"default":"en","enabled":true}' >/dev/null

# ---- slice 54: the indexing workflow makes document CONTENT searchable ------------
# The word "wombat" appears only in the bytes, never in the key — so this hit can
# only come from extraction, through the real engine, over HTTP.
# the quota-gating check above throttled ai.tokens.total to 0, which defers EVERY
# job at claim time — flow.step included. Lift it, or this run sits queued forever
# (which is deferral working, but not what this block is testing).
curl -s -X POST $B/api/quota -H "Authorization: Bearer $OP" \
  -d '{"dimension":"ai.tokens.total","limit":1000000,"window":"day"}' >/dev/null
printf 'quarterly wombat forecast' > /tmp/tmx-smoke-idx.md
curl -s -X PUT "$B/api/repo/plans/forecast.md" -H "Authorization: Bearer $OP" \
  -H 'Content-Type: text/markdown' --data-binary @/tmp/tmx-smoke-idx.md >/dev/null
assert "content not searchable before indexing" \
  "$(curl -s "$B/api/search?q=wombat" -H "Authorization: Bearer $OP" | grep -c '"type":"file"' || true)" "0"
IDXRUN=$(curl -s -X POST $B/api/workflows/index-documents/run -H "Authorization: Bearer $OP" -d '{}')
IDXID=$(printf '%s' "$IDXRUN" | grep -oP '"id":"\K[^"]+' | head -1)
assert "index-documents run accepted" "$IDXRUN" '"status":"running"'
idxs=""; idxjson=""
for i in $(seq 1 40); do
  idxjson=$(curl -s "$B/api/runs/$IDXID" -H "Authorization: Bearer $OP")
  idxs=$(printf '%s' "$idxjson" | grep -oP '"status":"\K[^"]+' | head -1)
  case "$idxs" in done|error|canceled) break;; esac
  sleep 0.5
done
# A failed run already knows why — carry it into the FAIL line, or this reads as a
# mystery. The one that actually bites is a host without poppler-utils: extracting
# the PDF uploaded further up reports 'missing-tool and fails the run ON PURPOSE.
[ "$idxs" = done ] || idxs="$idxs — $(printf '%s' "$idxjson" | grep -oP '"error":"\K[^"]*' | head -1)"
assert "index-documents run completed" "$idxs" "done"
assert "search now matches the document's CONTENT" \
  "$(curl -s "$B/api/search?q=wombat" -H "Authorization: Bearer $OP")" 'plans/forecast.md'

# ---- slice 61: the knowledge graph — the surface exists, and extraction refuses to
# run on the fallback model (the mention rule and the pipeline are unit-tested;
# the whole flow over HTTP is in test/doc-pipeline-smoke.sh against a scripted model)
KGE=$(curl -s "$B/api/kg/entities?q=" -H "Authorization: Bearer $OP")
assert "kg: empty graph"          "$KGE" '"entities":[]'
assert "kg: stats count the indexed document as waiting" "$KGE" '"unextracted":'
assert "kg: unknown entity is 404" "$(curl -s "$B/api/kg/entities/nope" -H "Authorization: Bearer $OP")" 'not found'
KGRUN=$(curl -s -X POST $B/api/kg/extract -H "Authorization: Bearer $OP")
KGID=$(printf '%s' "$KGRUN" | grep -oP '"id":"\K[^"]+' | head -1)
assert "kg: extract queues index-knowledge" "$KGRUN" '"status":"running"'
kgs=""; kgjson=""
for i in $(seq 1 40); do
  kgjson=$(curl -s "$B/api/runs/$KGID" -H "Authorization: Bearer $OP")
  kgs=$(printf '%s' "$kgjson" | grep -oP '"status":"\K[^"]+' | head -1)
  case "$kgs" in done|error|canceled) break;; esac
  sleep 0.5
done
assert "kg: extraction fails without a model" "$kgs" "error"
assert "…and says so"                          "$kgjson" 'no model configured'

# ---- slice 67: model roles — where a team's bulk AI work goes
assert "model roles: default is local" "$(curl -s $B/api/model-roles -H "Authorization: Bearer $OP")" '"utility":null'
assert "model roles: unknown executor refused" "$(curl -s -X PUT $B/api/model-roles -H "Authorization: Bearer $OP" -d '{"roles":{"utility":"nope"}}')" 'unknown executor'
assert "model roles: unknown role refused"     "$(curl -s -X PUT $B/api/model-roles -H "Authorization: Bearer $OP" -d '{"roles":{"fancy":null}}')" 'unknown role'
ROLE_EX=$(curl -s -X POST $B/api/executors -H "Authorization: Bearer $OP" -d '{"name":"cheap-box","mode":"pull","model":"small"}' | grep -oP '"name":"\K[^"]+' | head -1)
assert "model roles: set to an executor"       "$(curl -s -X PUT $B/api/model-roles -H "Authorization: Bearer $OP" -d '{"roles":{"utility":"cheap-box"}}')" '"utility":"cheap-box"'
assert "model roles: a member cannot set"      "$(curl -s -X PUT $B/api/model-roles -H "Authorization: Bearer $BOB" -d '{"roles":{"utility":null}}')" 'Forbidden: settings:manage'
assert "model roles: cleared"                  "$(curl -s -X PUT $B/api/model-roles -H "Authorization: Bearer $OP" -d '{"roles":{"utility":null}}')" '"utility":null'

# ---- issue #19: secrets at rest, and a TOTP seed that can be revoked
assert "admin status says whether a dump is replayable" "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"secrets":'
assert "…plaintext when no key is configured"           "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"secrets":"plaintext"'
TFA=$(curl -s -X POST $B/api/2fa/enable -H "Authorization: Bearer $OP")
assert "2fa enable returns the seed once"     "$TFA" '"secret":'
# issue #26: enrolling hands out the way back in at the same time
assert "…and a set of recovery codes"         "$TFA" '"recovery_codes":['
assert "ten of them are unspent"              "$(curl -s $B/api/2fa/recovery-codes -H "Authorization: Bearer $OP")" '"remaining":10'
assert "re-issuing returns a fresh set"       "$(curl -s -X POST $B/api/2fa/recovery-codes -H "Authorization: Bearer $OP")" '"count":10'
assert "…and the count endpoint never leaks them" "$(curl -s $B/api/2fa/recovery-codes -H "Authorization: Bearer $OP" | grep -c recovery_codes || true)" '0'
assert "…and resetting it says it was on"     "$(curl -s -X DELETE $B/api/2fa -H "Authorization: Bearer $OP")" '"was_enabled":true'
assert "…taking the recovery codes with it"   "$(curl -s $B/api/2fa/recovery-codes -H "Authorization: Bearer $OP")" '"remaining":0'
assert "…a second reset says it was not"      "$(curl -s -X DELETE $B/api/2fa -H "Authorization: Bearer $OP")" '"was_enabled":false'
assert "an operator may revoke another user's seed" "$(curl -s -X DELETE $B/api/admin/users/$BOBID/2fa -H "Authorization: Bearer $OP")" '"ok":true'
assert "…a member may not"                    "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/admin/users/$BOBID/2fa -H "Authorization: Bearer $BOB")" '403'
assert "…and an unknown user is a 404"        "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/admin/users/nobody/2fa -H "Authorization: Bearer $OP")" '404'

# ---- slice 63: a plugin's authenticated HTTP route, mounted under /api/x/<plugin>/
assert "plugin route (GET, query)"  "$(curl -s "$B/api/x/example-tools/word-count?text=one+two+three" -H "Authorization: Bearer $OP")" '"words":3'
assert "plugin route (POST, body)"  "$(curl -s -X POST $B/api/x/example-tools/word-count -H "Authorization: Bearer $OP" -d '{"text":"a b"}')" '"words":2'
assert "plugin route needs a token" "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/example-tools/word-count?text=x")" '401'
assert "plugin route: a user error is a 400" "$(curl -s -X POST $B/api/x/example-tools/word-count -H "Authorization: Bearer $OP" -d '{}')" 'text is required'
assert "plugin route in the plugin listing" "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"GET /word-count"'
assert "no plugin route outside its prefix"  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/word-count?text=x" -H "Authorization: Bearer $OP")" '404'
assert "plugin job kind is listed for its plugin" "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"x.example-tools.word-count"'

# ---- issue #20: a plugin's AUTHENTICATED bundle. The funnel's landing bundle is
# public and publicly cached; customer screens must not be, so they come from a
# second directory behind a bearer token and a no-store response.
assert "plugin bundle needs a token"  "$(curl -s -o /dev/null -w '%{http_code}' $B/api/x/example-tools/bundle/)" '401'
assert "plugin bundle serves index.html" "$(curl -s $B/api/x/example-tools/bundle/ -H "Authorization: Bearer $OP")" 'Word count'
assert "…the same file by name"       "$(curl -s $B/api/x/example-tools/bundle/index.html -H "Authorization: Bearer $OP")" 'Word count'
assert "…is never publicly cached"    "$(curl -s -D- -o /dev/null $B/api/x/example-tools/bundle/ -H "Authorization: Bearer $OP" | tr -d '\r' | grep -i '^cache-control:')" 'private, no-store'
assert "…and varies by Authorization" "$(curl -s -D- -o /dev/null $B/api/x/example-tools/bundle/ -H "Authorization: Bearer $OP" | tr -d '\r' | grep -i '^vary:')" 'Authorization'
assert "the public landing path is NOT the authenticated one" "$(curl -s -o /dev/null -w '%{http_code}' $B/beta/bundle/example-tools/index.html)" '404'
# --path-as-is, or curl collapses the ../ itself and the server never sees it
assert "plugin bundle: no traversal out of the directory" "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/api/x/example-tools/bundle/../main.rkt" -H "Authorization: Bearer $OP")" '404'
assert "plugin bundle: no ENCODED traversal either" "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/api/x/example-tools/bundle/%2e%2e/main.rkt" -H "Authorization: Bearer $OP")" '404'
assert "plugin bundle: a nested traversal is a 404 too" "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/api/x/example-tools/bundle/a/../../plugin.json" -H "Authorization: Bearer $OP")" '404'
assert "plugin bundle: an unloaded plugin is a 404" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/x/nope/bundle/index.html -H "Authorization: Bearer $OP")" '404'

# ---- the integrator example (docs/integrators-guide.md): all four seams at once
assert "example: the tool is registered"   "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" '"shipment_eta"'
assert "example: its route answers"        "$(curl -s "$B/api/x/integrator-demo/eta?lane=sin-lax" -H "Authorization: Bearer $OP")" '"days":18'
assert "…and needs a token"                "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/integrator-demo/eta?lane=sin-lax")" '401'
assert "…and refuses a missing argument"   "$(curl -s -X POST $B/api/x/integrator-demo/eta -H "Authorization: Bearer $OP" -d '{}')" 'lane is required'
assert "example: its job kind is namespaced" "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"x.integrator-demo.lane-report"'
EJ=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"x.integrator-demo.lane-report","payload":{"lanes":["sin-lax","hkg-lax"]}}')
assert "example: the job is accepted"      "$EJ" '"id"'
assert "example: its screen is served to a signed-in caller" "$(curl -s $B/api/x/integrator-demo/bundle/ -H "Authorization: Bearer $OP")" 'Lane ETA'

# ---- slice 57: the document pipeline plugin is present, and refuses to run on the
# fallback model. Without this the uppercase-echo fallback would fail every schema
# with "the model did not return a JSON object" — true, and useless to an operator.
# The pipeline itself runs in test/doc-pipeline-smoke.sh against a scripted model.
assert "process-upload arrived from the plugin" "$(curl -s $B/api/workflows -H "Authorization: Bearer $OP")" '"slug":"process-upload"'
PIPEOBJ=$(curl -s "$B/api/repo?prefix=plans/" -H "Authorization: Bearer $OP" | grep -oP '"id":"\K[^"]+' | head -1)
PIPERUN=$(curl -s -X POST $B/api/workflows/process-upload/run -H "Authorization: Bearer $OP" \
  -d "{\"input\":{\"object_id\":\"$PIPEOBJ\",\"schema\":{\"type\":\"object\"},\"template\":\"\",\"locales\":[]}}")
PIPEID=$(printf '%s' "$PIPERUN" | grep -oP '"id":"\K[^"]+' | head -1)
assert "process-upload run accepted" "$PIPERUN" '"status":"running"'
pipes=""; pipejson=""
for i in $(seq 1 40); do
  pipejson=$(curl -s "$B/api/runs/$PIPEID" -H "Authorization: Bearer $OP")
  pipes=$(printf '%s' "$pipejson" | grep -oP '"status":"\K[^"]+' | head -1)
  case "$pipes" in done|error|canceled) break;; esac
  sleep 0.5
done
assert "process-upload fails without a model" "$pipes" "error"
assert "…and says so"                          "$pipejson" 'no model configured'
assert "a declared input is required"          "$(curl -s -X POST $B/api/workflows/process-upload/run -H "Authorization: Bearer $OP" -d "{\"input\":{\"object_id\":\"$PIPEOBJ\"}}")" "is required"
rm -f /tmp/tmx-smoke-idx.md

# ---- Localization Manager (the flagship) --------------------------------------
# These run over HTTP on purpose. The model has its own unit suite, but the bug
# that actually bit here lived in the ENDPOINT layer: `query-param` compared a
# string key with assq against url-query's symbol keys, so every filter silently
# fell back to its default and a request for Dutch was answered with Japanese.
# A filter that is ignored rather than refused is invisible to a model test.
curl -s -X POST $B/api/l10n/import -H "Authorization: Bearer $OP" >/dev/null
assert "l10n import links the shipped ja catalog as approved" \
  "$(curl -s "$B/api/l10n/coverage?locale=ja" -H "Authorization: Bearer $OP")" '"locale":"ja"'

# the locale filter is really applied — qps is a pseudo-locale with no catalog, so nothing is approved
nlcov=$(curl -s "$B/api/l10n/coverage?locale=qps" -H "Authorization: Bearer $OP")
assert "l10n coverage honours ?locale (qps is not ja)" "$nlcov" '"locale":"qps"'
assert "l10n coverage: nothing approved in qps"        "$nlcov" '"approved":0'

# the status filter is really applied
lmid=$(curl -s "$B/api/l10n/messages?locale=qps&status=missing&limit=1" -H "Authorization: Bearer $OP" \
       | grep -oP '"message_id":"\K[^"]+' | head -1)
assert "l10n messages?status=missing returns a message" "$lmid" "-"
curl -s -X PUT "$B/api/l10n/messages/$lmid" -H "Authorization: Bearer $OP" \
     -d '{"locale":"qps","text":"Verboden"}' >/dev/null
ltid=$(curl -s "$B/api/l10n/messages?locale=qps&status=needs_review" -H "Authorization: Bearer $OP" \
       | grep -oP '"translation_id":"\K[^"]+' | head -1)
assert "a submitted string lands in needs_review" "$ltid" "-"

# the review gate is enforced server-side, not merely hidden in the UI
assert "a translator cannot approve their own string" \
  "$(curl -s -X POST "$B/api/l10n/review/$ltid" -H "Authorization: Bearer $OP" -d '{"decision":"approve"}')" \
  "cannot approve their own"

# export is approved-only, and refuses to advertise a language with nothing in it
assert "export refuses an empty catalog" \
  "$(curl -s -X POST $B/api/l10n/export -H "Authorization: Bearer $OP" -d '{"locale":"qps"}')" \
  "nothing is approved"
assert "en is never an export target" \
  "$(curl -s -X POST $B/api/l10n/export -H "Authorization: Bearer $OP" -d '{"locale":"en"}')" \
  "source catalog"

# The permission split is the point: translating is a TEAM activity, so a plain
# member may read and draft. Approving your colleague's work and writing the
# catalogs to disk are not a member's to do.
assert "a member may read the catalogue" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/l10n/coverage?locale=ja" -H "Authorization: Bearer $BOB")" \
  "200"
assert "a member may NOT review" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/l10n/review/$ltid" -H "Authorization: Bearer $BOB" -d '{"decision":"approve"}')" \
  "403"
assert "a member may NOT export to disk" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/api/l10n/export" -H "Authorization: Bearer $BOB" -d '{"locale":"qps"}')" \
  "403"

if [ $fail -eq 0 ]; then echo "server-smoke: PASS"; else echo "server-smoke: FAIL"; fi
exit $fail
