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
SIGN=$(curl -s -X POST $B/api/beta/signup -d "{\"name\":\"Dana\",\"email\":\"dana@acme.com\",\"company\":\"Acme\",\"use_case\":\"team chat\",\"challenge\":\"$TOK\",\"pow\":$POW}")
assert "beta signup"      "$SIGN" '"ok":true'
PID=$(printf '%s' "$SIGN" | grep -oP '"id":"\K[^"]+')
# velocity: a second signup for the same email is capped (default 1 / 24h)
CH2=$(curl -s $B/api/beta/challenge); TOK2=$(printf '%s' "$CH2" | grep -oP '"challenge":"\K[^"]+'); NONCE2=${TOK2%%.*}
POW2=$(PLTCOLLECTS="$(pwd)/pkgs:" racket -e "(require (file \"$(pwd)/domain/beta/antispam.rkt\"))(display (pow-of \"$NONCE2\" $DIFF))" 2>/dev/null)
sleep 2
assert "beta email cap"   "$(curl -s -X POST $B/api/beta/signup -d "{\"name\":\"Dupe\",\"email\":\"dana@acme.com\",\"challenge\":\"$TOK2\",\"pow\":$POW2}")" 'we already have your request'
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
assert "a markup-bearing title is escaped, not injected" \
  "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{"title":"<script>x</script>"}' >/dev/null; curl -s $B/)" \
  '<title>&lt;script&gt;x&lt;/script&gt;</title>'
# restore the default so later assertions and reruns start from a clean slate
curl -s -X PUT $B/api/branding -H "Authorization: Bearer $OP" -d '{}' >/dev/null
assert "blank title put falls back to the default" "$(curl -s $B/api/branding)" '"title":"Telemachus"'
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
rm -f /tmp/tmx-smoke-idx.md

if [ $fail -eq 0 ]; then echo "server-smoke: PASS"; else echo "server-smoke: FAIL"; fi
exit $fail
