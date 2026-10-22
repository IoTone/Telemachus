#!/usr/bin/env bash
# test/server-smoke.sh — integration test for the HTTP server (slice 3).
# Boots the server on a temp DB, exercises the RBAC + localization flow, asserts.
# Run from refimpl/racketmaximus/ :  bash test/server-smoke.sh
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
# A test run uses the SHIPPED plugin set. These are unset rather than merely
# unused: a developer working on a downstream plugin exports them in their own
# shell, and an inherited value would put someone else's plugin — and its load
# failure, since PLTCOLLECTS is reset just above — into this suite's assertions.
unset TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS
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

# Issue #83: with TELEMACHUS_ENCRYPT_CONTENT on, the extracted text is sealed and
# CONTENT SEARCH is unavailable by design — the match is a SQL LIKE over that
# column. Three assertions below depend on it, so they are skipped in that mode
# rather than left to fail: a suite that reports four red lines an operator has to
# triage into "expected" and "not" is worse than one that says which capability is
# off. The skip is LOUD, because a silent one is how a gap hides (issue #25).
CONTENT_SEARCH=1
case "${TELEMACHUS_ENCRYPT_CONTENT:-}" in 1|yes|true|on) CONTENT_SEARCH=0;; esac
[ "$CONTENT_SEARCH" = 0 ] && echo "  note TELEMACHUS_ENCRYPT_CONTENT is on — content-search assertions are SKIPPED (#83 ENC-2)"

# <label> <haystack> <needle>, run only when document content is searchable.
assert_content(){
  if [ "$CONTENT_SEARCH" = 1 ]; then assert "$1" "$2" "$3"
  else echo "  skip $1 — content search is off (TELEMACHUS_ENCRYPT_CONTENT)"; fi
}

# <label> <haystack> <needle-that-must-be-ABSENT>. The other smokes have had this
# for a while and this one did not, so a `refute` written here ran as an unknown
# command: bash said "command not found" on stderr, nothing set `fail`, and the
# suite reported PASS with the assertion silently absent. It was asserting that a
# purged job no longer quotes its payload — the one property that mattered most.
refute(){
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  FAIL $1 — must NOT contain: $3 — got: $2"; fail=1; else echo "  ok   $1"; fi
}

# <label> <a> <b>: the two values must DIFFER. Added for #90, where the property
# is "two calls with no key produce two different ids" — which `assert` cannot
# express and which was written with `ok`/`bad` first. Those exist in the OTHER
# smokes and not in this one, so both branches ran as unknown commands and the
# assertions were silently absent: the THIRD time that shape of mistake appeared
# in this file's history, after `refute` and a vacuous payload check. Before
# using a helper here, grep for its definition.
differ(){
  if [ "$2" != "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 — both were: $2"; fail=1; fi
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
# issue #54: a password change now revokes every session it could have minted,
# INCLUDING the one making the call, so the caller signs in again. This suite used
# to change the password and keep using the same token.
assert "change pw"       "$(curl -s -X POST $B/api/password -H "Authorization: Bearer $OP" -d '{"current_password":"s3cret","new_password":"newpass1"}')" '"signed_out":true'
assert "the change revoked the session that made it" "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" 'Authentication required'
NEWLOGIN=$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"newpass1"}')
assert "login new pw"    "$NEWLOGIN" '"token":"tk_'
OP=$(printf '%s' "$NEWLOGIN" | grep -oP '"token":\s*"\K[^"]+')
assert "old pw rejected" "$(curl -s -X POST $B/api/login -d '{"username":"alice","password":"s3cret"}')" 'Authentication required'
assert "whoami operator" "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" '"is_operator":true'
assert "admin operator"  "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"ok":true'
assert "admin status carries the version now" "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"kdf":"'
MB=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')
assert "member token"    "$MB" '"token":"tk_'
BOB=$(printf '%s' "$MB" | grep -oP '"token":\s*"\K[^"]+')
# #124: the message names the permission actually required, which is now the
# narrower one. A member reaches neither.
assert "member 403 en"   "$(curl -s $B/api/admin/status -H "Authorization: Bearer $BOB")" 'Forbidden: instance:read'
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
# issue #64: this suite runs with NO model, so every reply above is the simulated
# echo. It has to SAY so — a plausible-looking reply from a model that was never
# called is the gotcha that keeps being rediscovered as "the judge is broken".
assert "…and the echo admits it is not a model"  "$(curl -s -X POST $B/api/ai/chat -H "Authorization: Bearer $OP" -d '{"prompt":"hello"}')" '"simulated":true'
assert "…on the stream's final event too"        "$(curl -sN -X POST $B/api/ai/chat/stream -H "Authorization: Bearer $OP" -d '{"prompt":"hello"}')" '"simulated":true'
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
assert_content "doc search"      "$(curl -s "$B/api/search?q=master" -H "Authorization: Bearer $OP")" '"type":"document"'
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
# issue #121: a plugin that owns data. The platform ran its migrations through
# its own runner at boot, so the table is there before any request — the
# alternative was CREATE TABLE IF NOT EXISTS on first use, which loses a
# duplicate-key race on PostgreSQL under concurrency.
assert "a plugin's migration is reported" \
  "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"x.example-tools.notes-seen"'
# …and it really ran: the prefixed table answers a query. Not via a plugin route,
# because the point is that the platform created it, not that the plugin can.
assert "…and its table exists, prefixed with the plugin's id" \
  "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"ok":true'
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

# ---- who may set a team's budget (issue #113) ---------------------------------
# `POST /api/quota` demanded `instance:manage`, so a team that hit its 2,000-token
# daily default could be unblocked only by the INSTANCE operator — while the
# catalog had been granting `quota:manage` to the team steward and to both
# company-admin roles all along, with nothing reading it. Reported from outside.
#
# The refusal MESSAGE is the pinned part: it names the permission, so a revert to
# `instance:manage` fails here and not merely in the route-table gate.
assert "a member cannot set the team budget" \
  "$(curl -s -X POST $B/api/quota -H "Authorization: Bearer $BOB" -d '{"dimension":"ai.requests","limit":500000,"window":"day"}')" \
  'Forbidden: quota:manage'
# a team OWNER can, which is the whole point of the issue
MO=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"frank","role":"owner"}')
FRANK=$(printf '%s' "$MO" | grep -oP '"token":\s*"\K[^"]+')
FRANK_ID=$(printf '%s' "$MO" | grep -oP '"user_id":\s*"\K[^"]+')
assert "an owner-role token was minted" "$MO" '"role":"owner"'
assert "a team owner sets the team budget" \
  "$(curl -s -X POST $B/api/quota -H "Authorization: Bearer $FRANK" -d '{"dimension":"ai.requests","limit":500000,"window":"day"}')" \
  '"ok":true'
assert "…and the limit reads back" \
  "$(curl -s $B/api/usage -H "Authorization: Bearer $FRANK")" \
  '"limit":500000'
# the operator still passes, as it did before the change
assert "the operator still sets it" \
  "$(curl -s -X POST $B/api/quota -H "Authorization: Bearer $OP" -d '{"dimension":"ai.requests","limit":500000,"window":"day"}')" \
  '"ok":true'
# Frank goes again, and that is not tidiness: a SECOND owner makes alice no
# longer the last one, and the membership block below asserts that the last owner
# can be neither demoted nor removed. Leaving him behind turned those two
# assertions green-to-red in a block that has nothing to do with quotas — which is
# how this fixture announced that it was changing global state.
assert "the second owner is removed again, so alice is the last one" \
  "$(curl -s -X DELETE $B/api/members/$FRANK_ID -H "Authorization: Bearer $OP")" \
  '"tokens_revoked":'
# the company plane's per-team route is multi-tenancy-gated: INVISIBLE when the
# flag is off (404), never a 403 that admits the route exists. Same assertion the
# other two org-plane routes carry.
assert "org team quota 404 single-tenant" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/org/teams/engineering/quota -H "Authorization: Bearer $OP" -d '{"dimension":"ai.requests","limit":1}')" \
  '404'
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
# issue #55: deferring is right, being silent about it was not. The held job says
# WHICH limit holds it, the usage report says the same without reading the queue,
# and the audit log carries one entry per window rather than one per tick.
QJ_ONE=$(curl -s $B/api/jobs/$QJID -H "Authorization: Bearer $OP")
assert "held job names the reason"     "$QJ_ONE" '"reason":"quota"'
assert "held job names the dimension"  "$QJ_ONE" '"dimension":"ai.tokens.total"'
assert "held job names the scope"      "$QJ_ONE" '"scope":"team"'
assert "the listing says so too" "$(curl -s $B/api/jobs -H "Authorization: Bearer $OP")" '"waiting"'
U55=$(curl -s $B/api/usage -H "Authorization: Bearer $OP")
assert "usage reports the hold"        "$U55" '"held":{'
# the reset time is the one field a client renders as a clock, so prove it is a
# real epoch rather than the null a window with no boundary answers with
RESET=$(printf '%s' "$QJ_ONE" | grep -oP '"resets_at":\K[0-9]+' | head -1)
if [ -n "$RESET" ] && [ "$RESET" -gt 1700000000 ]; then
  echo "  ok   held job says when it resumes ($RESET)"
else
  echo "  FAIL held job says when it resumes — expected an epoch, got: ${RESET:-null}"; fail=1
fi
assert "quota.exhausted is audited" \
  "$(curl -s "$B/api/audit?limit=50" -H "Authorization: Bearer $OP")" 'quota.exhausted'
# ONCE per window, not once per tick: the pool re-tries this queued job every
# 200ms, so a per-claim entry would have written dozens by now
AUDN=$(curl -s "$B/api/audit?limit=200" -H "Authorization: Bearer $OP" | grep -o 'quota.exhausted' | wc -l | tr -d ' ')
if [ "$AUDN" -le 2 ]; then
  echo "  ok   quota.exhausted is deduped per window ($AUDN entr(y|ies))"
else
  echo "  FAIL quota.exhausted is deduped per window — expected <= 2, got: $AUDN"; fail=1
fi
# SCHED-8: who may cancel. A job's OWNER may always stop their own work; stopping
# SOMEBODY ELSE'S needs jobs:cancel, which a plain member does not hold. The team is
# still over its token budget here, so these jobs stay queued and can be cancelled.
BJ=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $BOB" -d '{"kind":"chat","payload":{"prompt":"bob owns this"}}')
BJID=$(printf '%s' "$BJ" | grep -oP '"id":"\K[^"]+')
assert "cancel: a member cannot cancel the operator's job" \
  "$(curl -s -X POST $B/api/jobs/$QJID/cancel -H "Authorization: Bearer $BOB")" 'forbidden: jobs:cancel'
assert "cancel: …but may always cancel their own" \
  "$(curl -s -X POST $B/api/jobs/$BJID/cancel -H "Authorization: Bearer $BOB")" '"status":"canceled"'
assert "cancel: an admin may cancel somebody else's" \
  "$(curl -s -X POST $B/api/jobs/$QJID/cancel -H "Authorization: Bearer $OP")" '"status":"canceled"'
assert "cancel: an unknown job is a 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/jobs/00000000-0000-0000-0000-000000000000/cancel -H "Authorization: Bearer $OP")" '404'
# Issue #59: purge a settled job's content. BJID was just canceled above, so it is
# settled — and `canceled` is deliberately purgeable, because the work stopped and
# the input it was given can go. The payload here is bob's prompt, which stands in
# for the document text an `infer.chat` payload actually carries.
assert "purge: a member cannot purge the operator's job" \
  "$(curl -s -X DELETE $B/api/jobs/$QJID/content -H "Authorization: Bearer $BOB")" 'forbidden: jobs:purge'
assert "purge: …but may always purge their own" \
  "$(curl -s -X DELETE $B/api/jobs/$BJID/content -H "Authorization: Bearer $BOB")" '"purged":true'
assert "purge: …and the prompt is gone from the job" \
  "$(curl -s $B/api/jobs/$BJID -H "Authorization: Bearer $BOB")" '"result":null'
# NOT "the payload text is gone from this response": `row->job` has no payload
# key, so the API never carried it and that assertion would pass for the wrong
# reason. The row-level property — that NO column still quotes the text — is
# asserted in test/scheduler-tests.rkt, where the row is actually visible.
# What is worth pinning here is the surface itself: if payload ever joins this
# response, a purge stops being purely a database concern and this fails.
refute "purge: the job API never exposes a payload at all" \
  "$(curl -s $B/api/jobs/$BJID -H "Authorization: Bearer $BOB")" '"payload"'
assert "purge: …while the row stays accountable" \
  "$(curl -s $B/api/jobs/$BJID -H "Authorization: Bearer $BOB")" '"status":"canceled"'
assert "purge: …and says it was purged, which '{}' alone cannot" \
  "$(curl -s $B/api/jobs/$BJID -H "Authorization: Bearer $BOB")" '"purged_at":'
assert "purge: a second call is honest that it did nothing" \
  "$(curl -s -X DELETE $B/api/jobs/$BJID/content -H "Authorization: Bearer $BOB")" '"purged":false'
assert "purge: an admin may purge somebody else's" \
  "$(curl -s -X DELETE $B/api/jobs/$QJID/content -H "Authorization: Bearer $OP")" '"purged":true'
assert "purge: an unknown job is a 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/jobs/00000000-0000-0000-0000-000000000000/content -H "Authorization: Bearer $OP")" '404'
assert "purge: the audit entry names the act and not the content" \
  "$(curl -s "$B/api/audit?limit=20" -H "Authorization: Bearer $OP")" 'job.purge'
assert "metrics"         "$(curl -s $B/api/metrics -H "Authorization: Bearer $OP")" '"users"'
# #124: /api/metrics is instance:read now
assert "metrics 403"     "$(curl -s $B/api/metrics -H "Authorization: Bearer $BOB")" 'Forbidden: instance:read'

# ---- timezones (#137) --------------------------------------------------------
# UTC is the last resort and is STATED: an instance that configures nothing
# behaves exactly as it did before timezones existed.
assert "timezone: nothing configured means UTC, and whoami says which layer answered" \
  "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" '"source":"default"'
assert "timezone: the zone list is derived from the tz database on disk" \
  "$(curl -s $B/api/timezones -H "Authorization: Bearer $BOB")" 'Europe/London'
# An unknown zone is REFUSED, never silently substituted — somebody quietly
# given UTC for a typo finds out from a report that arrives at the wrong hour.
assert "timezone: an unknown zone is refused on the profile" \
  "$(curl -s -X POST $B/api/profile -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{"timezone":"Europe/Berlin-ish"}')" 'is not a timezone this instance has data for'
assert "timezone: an unknown zone is refused on the instance default" \
  "$(curl -s -X PUT $B/api/timezone -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"timezone":"PST"}')" 'is not a timezone'
assert "timezone: the instance default is an operator write" \
  "$(curl -s -X PUT $B/api/timezone -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{"timezone":"Europe/London"}')" 'Forbidden: instance:manage'
# …and a monitoring credential may READ it (#124's split)
assert "timezone: reading the instance default is instance:read" \
  "$(curl -s -X PUT $B/api/timezone -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"timezone":"Europe/London"}')" '"timezone":"Europe/London"'
assert "timezone: a member with no zone of their own inherits the instance's" \
  "$(curl -s $B/api/whoami -H "Authorization: Bearer $BOB")" '"source":"instance"'
# A PERSON'S OWN CHOICE WINS. The layers do not tighten: a timezone is not a
# control, and nobody is protected by being forced into the wrong clock.
assert "timezone: a person sets their own" \
  "$(curl -s -X POST $B/api/profile -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{"timezone":"Asia/Tokyo"}')" '"source":"user"'
assert "timezone: …and it wins over the instance default" \
  "$(curl -s $B/api/whoami -H "Authorization: Bearer $BOB")" '"timezone":"Asia/Tokyo"'
assert "timezone: the offset and abbreviation come with it" \
  "$(curl -s $B/api/whoami -H "Authorization: Bearer $BOB")" '"utc_offset_seconds":32400'
# Either field alone: a body carrying only a timezone must not be refused for
# lacking a locale the caller never meant to change, and vice versa.
assert "timezone: a locale-only profile write still works" \
  "$(curl -s -X POST $B/api/profile -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{"locale":"ja"}')" '"locale":"ja"'
assert "timezone: …and the zone it did not mention is untouched" \
  "$(curl -s $B/api/whoami -H "Authorization: Bearer $BOB")" '"timezone":"Asia/Tokyo"'
assert "timezone: an empty profile write is refused rather than a silent no-op" \
  "$(curl -s -X POST $B/api/profile -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{}')" 'locale or timezone required'
assert "timezone: the trail names the instance write" \
  "$(curl -s "$B/api/audit?limit=20" -H "Authorization: Bearer $OP")" 'instance.timezone'

# ---- recurring work (#135) ---------------------------------------------------
# A schedule enqueues an ordinary job on an interval. Everything below the
# enqueue is the job row's — admission, the org gate, cancel, the lease — so what
# is worth pinning over HTTP is the permission, the refusals, and that a create
# does NOT fire immediately.
assert "schedule: a member may not commit the team to recurring spend" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","interval_seconds":3600}')" 'Forbidden: jobs:schedule'
assert "schedule: reading one is held to the same permission as writing it" \
  "$(curl -s $B/api/schedules -H "Authorization: Bearer $BOB")" 'Forbidden: jobs:schedule'
# An unknown kind would enqueue work nothing can run, on a timer, for ever —
# refused where somebody is present to read the answer.
assert "schedule: an unregistered kind is refused at create" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"no-such-kind","interval_seconds":3600}')" 'is not a registered job kind'
assert "schedule: the interval floor is enforced" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","interval_seconds":30}')" 'at least 60'
SCH=$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","interval_seconds":3600,"name":"hourly chat","payload":{"prompt":"tick"}}')
SCHID=$(printf '%s' "$SCH" | grep -oP '"id":"\K[^"]+')
assert "schedule: created, with its cadence and its principal" "$SCH" '"interval_seconds":3600'
# The first firing is one interval away. A create that fired at once would make
# every mistaken create cost a run.
assert "schedule: a create does not fire immediately" "$SCH" '"fired":0'
assert "schedule: it appears in the team's list" \
  "$(curl -s $B/api/schedules -H "Authorization: Bearer $OP")" '"hourly chat"'
assert "schedule: the list states the floor, so a client need not hardcode it" \
  "$(curl -s $B/api/schedules -H "Authorization: Bearer $OP")" '"min_interval_seconds":60'
assert "schedule: pausing is the brake" \
  "$(curl -s -X PATCH $B/api/schedules/$SCHID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"paused":true}')" '"paused":true'
assert "schedule: a patch cannot get round the interval floor" \
  "$(curl -s -X PATCH $B/api/schedules/$SCHID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"interval_seconds":1}')" 'at least 60'
# The principal is not patchable: changing whose authority a timer spends is a
# new schedule, not an edit. Sending one is ignored, and the row still names the
# operator who created it.
refute "schedule: the principal is not patchable" \
  "$(curl -s -X PATCH $B/api/schedules/$SCHID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"user_id":"somebody-else"}')" 'somebody-else'
# A WALL-CLOCK cadence (#140): "07:00" is the case an interval cannot express.
assert "schedule: a wall-clock cadence needs the minute of the local day" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","cadence":"daily"}')" 'at_minute must be the whole minute'
assert "schedule: weekly needs its weekday set" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","cadence":"weekly","at_minute":420}')" 'days_of_week must be'
assert "schedule: an unknown cadence is refused, not treated as an interval" \
  "$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","cadence":"hourly","at_minute":420}')" 'cadence must be one of'
# The zone DEFAULTS to the caller's own (#137) — nobody should have to think
# about it — and is then stored on the schedule.
DAILY=$(curl -s -X POST $B/api/schedules -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"kind":"chat","cadence":"daily","at_minute":420,"name":"morning briefing"}')
DAILYID=$(printf '%s' "$DAILY" | grep -oP '"id":"\K[^"]+')
# Europe/London here is the INSTANCE DEFAULT the timezone block above set — the
# assertion is deliberately that value, because it proves the #137 resolution is
# what supplied it rather than a hardcoded UTC. It is also a fixture dependency
# on an earlier block, which is the shape that has broken distant assertions in
# this file before: if that block changes the default, change this too.
assert "schedule: a daily cadence stores its own timezone, defaulted from the caller" "$DAILY" '"timezone":"Europe/London"'
assert "schedule: …and the minute of the local day" "$DAILY" '"at_minute":420'
# `interval_seconds` is hidden for a cadence it does not drive: the column is NOT
# NULL and carries a nominal value, and a number nothing computes with is how a
# reader comes to believe the wrong thing.
assert "schedule: interval_seconds is not reported for a wall-clock cadence" "$DAILY" '"interval_seconds":null'
assert "schedule: the first firing is not immediate" "$DAILY" '"fired":0'
# A patch is validated AS THE SCHEDULE WOULD BE, so it cannot reach a state a
# create could not.
assert "schedule: a patch cannot switch to weekly without the days" \
  "$(curl -s -X PATCH $B/api/schedules/$DAILYID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"cadence":"weekly"}')" 'days_of_week must be'
WEEKLY=$(curl -s -X PATCH $B/api/schedules/$DAILYID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"cadence":"weekly","days_of_week":"1,2,3,4,5"}')
assert "schedule: …and does switch when they are supplied" "$WEEKLY" '"cadence":"weekly"'
assert "schedule: the weekday set comes back as sent" "$WEEKLY" '"days_of_week":"1,2,3,4,5"'
assert "schedule: an unknown timezone on a schedule is refused" \
  "$(curl -s -X PATCH $B/api/schedules/$DAILYID -H "Authorization: Bearer $OP" -H 'Content-Type: application/json' \
      -d '{"timezone":"Mars/Olympus"}')" 'is not a timezone this instance has data for'
assert "schedule: the cadence vocabulary is published" \
  "$(curl -s $B/api/schedules -H "Authorization: Bearer $OP")" '"cadences"'
curl -s -o /dev/null -X DELETE $B/api/schedules/$DAILYID -H "Authorization: Bearer $OP"
assert "schedule: the trail names the create" \
  "$(curl -s "$B/api/audit?limit=20" -H "Authorization: Bearer $OP")" 'job.schedule.created'
assert "schedule: deleted" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/schedules/$SCHID -H "Authorization: Bearer $OP")" '200'
assert "schedule: an unknown id is a 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' $B/api/schedules/00000000-0000-0000-0000-000000000000 -H "Authorization: Bearer $OP")" '404'

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
assert_content "search now matches the document's CONTENT" \
  "$(curl -s "$B/api/search?q=wombat" -H "Authorization: Bearer $OP")" 'plans/forecast.md'

# ---- LAY-4/LAY-5: what a team asserts, and where the text came from ---------------
echo
echo "== retention rules and the legal hold (issue #86 r3) =="
assert "retention: an unconfigured instance has no rules" \
  "$(curl -s "$B/api/retention" -H "Authorization: Bearer $OP")" '"max_age_days":null'
assert "retention: …and its plan is empty" \
  "$(curl -s "$B/api/retention/plan" -H "Authorization: Bearer $OP")" '"objects":[]'
# 0 days would delete a document on arrival
assert "retention: 0 days is refused" \
  "$(curl -s -X PUT "$B/api/retention" -H "Authorization: Bearer $OP" -d '{"max_age_days":0}')" 'at least 1 day'
assert "retention: a field nobody defined is refused, not dropped" \
  "$(curl -s -X PUT "$B/api/retention" -H "Authorization: Bearer $OP" -d '{"keep_forever":1}')" 'unknown field'
assert "retention: a valid policy is accepted" \
  "$(curl -s -X PUT "$B/api/retention" -H "Authorization: Bearer $OP" -d '{"purge_job_payloads_after_days":7}')" '"ok":true'
assert "retention: …and reads back, naming which layer set it" \
  "$(curl -s "$B/api/retention" -H "Authorization: Bearer $OP")" '"purge_job_payloads_after_days":"team"'
# The READ is gated too, and was not: `routes.rkt` declared files:read and
# `ep-retention-get` enforced nothing, so any authenticated caller could read the
# team's, the company's and the INSTANCE's policy. `$CI` is scoped `*:read`,
# which does include files:read — so the proof is a token scoped to something
# ELSE entirely.
NOFILES=$(curl -s -X POST $B/api/tokens -H "Authorization: Bearer $OP" \
            -d '{"name":"nofiles","scopes":["notes:read"]}' | grep -oP '"token":"\K[^"]+')
assert "retention: a token without files:read cannot READ the rules" \
  "$(curl -s "$B/api/retention" -H "Authorization: Bearer $NOFILES")" 'Forbidden: files:read'
assert "retention: …nor the plan" \
  "$(curl -s "$B/api/retention/plan" -H "Authorization: Bearer $NOFILES")" 'Forbidden: files:read'
assert "retention: a plain member cannot set the team's rules" \
  "$(curl -s -X PUT "$B/api/retention" -H "Authorization: Bearer $BOB" -d '{"max_age_days":1}')" 'Forbidden'
# the hold: placed through the stewardship permission, and audited
HOLDOBJ=$(curl -s -X PUT "$B/api/repo/holdme.txt" -H "Authorization: Bearer $OP" \
          -H 'Content-Type: text/plain' --data-binary 'under litigation')
HOLDID=$(printf '%s' "$HOLDOBJ" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
assert "hold: can be placed" \
  "$(curl -s -X POST "$B/api/repo-obj/$HOLDID/legal-hold" -H "Authorization: Bearer $OP" -d '{"hold":true}')" '"ok":true'
assert "hold: …and is reported on the object" \
  "$(curl -s -X POST "$B/api/repo-obj/$HOLDID/legal-hold" -H "Authorization: Bearer $OP" -d '{"hold":true}')" '"legal_hold":'
assert "hold: …and the plan counts what it protects" \
  "$(curl -s "$B/api/retention/plan" -H "Authorization: Bearer $OP")" '"held":1'
assert "hold: can be released" \
  "$(curl -s -X POST "$B/api/repo-obj/$HOLDID/legal-hold" -H "Authorization: Bearer $OP" -d '{"hold":false}')" '"legal_hold":null'
assert "hold: placing one is audited" \
  "$(curl -s "$B/api/audit?limit=30" -H "Authorization: Bearer $OP")" 'repo.hold'
# put the team's policy back so nothing downstream runs under a retention rule
curl -s -o /dev/null -X PUT "$B/api/retention" -H "Authorization: Bearer $OP" -d '{}'

echo "== cascade and prefix delete (issue #86) =="
# A source with one derived output, then the cascade, then the verification read.
CSRC=$(curl -s -X PUT "$B/api/repo/purgeme/src.txt" -H "Authorization: Bearer $OP" \
       -H 'Content-Type: text/plain' --data-binary 'the source document')
CSID=$(printf '%s' "$CSRC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
CDER=$(curl -s -X PUT "$B/api/repo/purgeme/src.txt.extracted.json" -H "Authorization: Bearer $OP" \
       -H 'Content-Type: application/json' --data-binary '{"total":1}')
CDID=$(printf '%s' "$CDER" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
assert "cascade: traces show the object before anything is deleted" \
  "$(curl -s "$B/api/repo-obj/$CSID/traces" -H "Authorization: Bearer $OP")" '"deleted":false'
# a dry run must change nothing
assert "cascade: a dry run reports and does not delete" \
  "$(curl -s -X DELETE "$B/api/repo-obj/$CSID?cascade=1&dry_run=1" -H "Authorization: Bearer $OP")" '"dry_run":true'
assert "cascade: …so the object is still there" \
  "$(curl -s "$B/api/repo-obj/$CSID" -H "Authorization: Bearer $OP")" "$CSID"
# an empty prefix is refused rather than meaning "everything"
assert "prefix: an empty prefix is refused, not read as every object" \
  "$(curl -s -X DELETE "$B/api/repo?prefix=&confirm=1" -H "Authorization: Bearer $OP")" 'a prefix is required'
# and a prefix delete is a dry run unless confirmed
assert "prefix: the default is a dry run" \
  "$(curl -s -X DELETE "$B/api/repo?prefix=purgeme/" -H "Authorization: Bearer $OP")" '"dry_run":true'
assert "prefix: …and nothing went" \
  "$(curl -s "$B/api/repo-obj/$CDID" -H "Authorization: Bearer $OP")" "$CDID"
assert "prefix: confirmed, it deletes the prefix" \
  "$(curl -s -X DELETE "$B/api/repo?prefix=purgeme/&confirm=1" -H "Authorization: Bearer $OP")" '"dry_run":false'
assert "prefix: …the source is gone" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/repo-obj/$CSID" -H "Authorization: Bearer $OP")" '404'
assert "prefix: …and so is what it derived" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/repo-obj/$CDID" -H "Authorization: Bearer $OP")" '404'
TRACES=$(curl -s "$B/api/repo-obj/$CSID/traces" -H "Authorization: Bearer $OP")
assert "traces: the tombstone says deleted"        "$TRACES" '"deleted":true'
assert "traces: no versions remain"                "$TRACES" '"versions":0'
assert "traces: no bytes remain"                   "$TRACES" '"blobs":0'
assert "traces: no derivation rows remain"         "$TRACES" '"derivation_rows":0'

echo "== instance-wide feature switch (issue #63) =="
# The gap the integrator's guide stated: flags were per TEAM only.
assert "features: the instance switch reads back"  \
  "$(curl -s $B/api/instance-features -H "Authorization: Bearer $OP")" '"known"'
assert "features: a member cannot set it" \
  "$(curl -s -X PUT $B/api/instance-features -H "Authorization: Bearer $BOB" -d '{"features":{}}')" \
  'Forbidden: instance:manage'
# an unknown feature is REFUSED, not stored: a flag that does nothing is how an
# operator concludes the switch is broken
assert "features: an unknown feature is refused" \
  "$(curl -s -X PUT $B/api/instance-features -H "Authorization: Bearer $OP" \
      -d '{"features":{"nosuchthing":false}}')" "unknown feature"
assert "features: a non-boolean is refused" \
  "$(curl -s -X PUT $B/api/instance-features -H "Authorization: Bearer $OP" \
      -d '{"features":{"search":"yes"}}')" "must be true or false"
# turn search off for the whole instance
assert "features: the instance can turn one off" \
  "$(curl -s -X PUT $B/api/instance-features -H "Authorization: Bearer $OP" \
      -d '{"features":{"search":false}}')" '"search":false'
assert "features: ...and the team's listing says WHICH layer did it" \
  "$(curl -s $B/api/features -H "Authorization: Bearer $OP")" '"disabled_by":"instance"'
# The endpoint itself refuses, which is the point of the switch — and it refuses
# through `require-feature`, whose message is `Forbidden: <feature>`. That the
# wording is unchanged is the evidence that matters: the instance layer resolves
# inside `feature-enabled?`, so every gate that already asked is now covered
# without being touched.
assert "features: ...and the feature's endpoint refuses" \
  "$(curl -s "$B/api/search?q=anything" -H "Authorization: Bearer $OP")" 'Forbidden: search'
# THE DECISION: a team may tighten and may never loosen
assert "features: a team cannot turn back on what the instance disabled" \
  "$(curl -s -X POST $B/api/features/search -H "Authorization: Bearer $OP" -d '{"enabled":true}')" \
  'cannot'
assert "features: ...refused as a 409, not stored and ignored" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/features/search \
      -H "Authorization: Bearer $OP" -d '{"enabled":true}')" "409"
# a team turning it OFF is always allowed -- that is a team recording its own
# intention, which survives the instance flipping back
assert "features: a team may still turn it off" \
  "$(curl -s -X POST $B/api/features/search -H "Authorization: Bearer $OP" -d '{"enabled":false}')" \
  '"enabled":false'
# and an unknown feature name on the team route is a 400 too
assert "features: an unknown feature name is a 400" \
  "$(curl -s -X PUT $B/api/instance-features -H "Authorization: Bearer $OP" -d '{"features":{}}' >/dev/null; \
     curl -s -X POST $B/api/features/nosuch -H "Authorization: Bearer $OP" -d '{"enabled":true}')" \
  "unknown feature"
# restore: the instance allows everything again, and the team's own OFF stands
assert "features: the instance switch is cleared" \
  "$(curl -s $B/api/instance-features -H "Authorization: Bearer $OP")" '"features":{}'
assert "features: ...and the team's own choice is still remembered" \
  "$(curl -s $B/api/features -H "Authorization: Bearer $OP")" '"disabled_by":"team"'
assert "features: ...which the team CAN undo" \
  "$(curl -s -X POST $B/api/features/search -H "Authorization: Bearer $OP" -d '{"enabled":true}')" \
  '"effective":true'
# single-tenant: the org plane is invisible, as every other org route is
assert "features: the org plane is invisible single-tenant" \
  "$(curl -s -o /dev/null -w '%{http_code}' $B/api/org/features -H "Authorization: Bearer $OP")" "404"

echo "== idempotency keys (issue #90) =="
# THE ACCEPTANCE CRITERIA, over HTTP, because what is promised is a RESPONSE.
#
#   "Two identical run requests with the same key create one run and return the
#    same run id."  /  "A changed payload with the same key returns 409."
IDK="idem-$(date +%s)-$$"
IR1=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
        -H "Idempotency-Key: $IDK" -d '{"input":{"subject":"idem-one"}}')
IR2=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
        -H "Idempotency-Key: $IDK" -d '{"input":{"subject":"idem-one"}}')
ID1=$(printf '%s' "$IR1" | grep -oP '"id":"\K[^"]+' | head -1)
ID2=$(printf '%s' "$IR2" | grep -oP '"id":"\K[^"]+' | head -1)
assert "idem: a retry returns the SAME run id" "$ID2" "$ID1"
# ...and it must be the same ROW, not two rows that happen to agree
assert "idem: ...and only ONE run exists for that subject" \
  "$(curl -s $B/api/runs -H "Authorization: Bearer $OP" | python3 -c "
import json,sys
rs=[r for r in json.load(sys.stdin)['runs'] if r.get('input',{}).get('subject')=='idem-one']
print(len(rs))")" "1"
# the replay is VISIBLE: a silent replay and a fresh success are otherwise
# indistinguishable, and an integrator debugging a double-send needs to know
assert "idem: the replay says it is one"       "$IR2" '"idempotent_replay":true'
refute "idem: a first call does NOT claim to be a replay" "$IR1" 'idempotent_replay'
# the ORIGINAL status code comes back, not a 200: 202 is part of the answer
assert "idem: the replay carries the original 202" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workflows/smoke-filer/run \
      -H "Authorization: Bearer $OP" -H "Idempotency-Key: $IDK" \
      -d '{"input":{"subject":"idem-one"}}')" "202"
# a CHANGED payload on the same key: answering either request would be wrong
assert "idem: the same key with a different payload is a 409" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/workflows/smoke-filer/run \
      -H "Authorization: Bearer $OP" -H "Idempotency-Key: $IDK" \
      -d '{"input":{"subject":"idem-CHANGED"}}')" "409"
assert "idem: ...and says what to do about it" \
  "$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
      -H "Idempotency-Key: $IDK" -d '{"input":{"subject":"idem-CHANGED"}}')" 'use a new key'
# JSON key ORDER is not a payload change -- a client's serializer may reorder
assert "idem: reordered JSON keys are the SAME request" \
  "$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
      -H "Idempotency-Key: $IDK" -d '{"input":{"subject":"idem-one"}}' | grep -c idempotent_replay)" "1"
# the body field, for a caller that cannot set headers
IDK2="idem-body-$(date +%s)-$$"
BR1=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" \
       -d "{\"kind\":\"echo\",\"payload\":{},\"idempotency_key\":\"$IDK2\"}")
BR2=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" \
       -d "{\"kind\":\"echo\",\"payload\":{},\"idempotency_key\":\"$IDK2\"}")
assert "idem: the key may ride in the BODY too" \
  "$(printf '%s' "$BR2" | grep -oP '"id":"\K[^"]+')" \
  "$(printf '%s' "$BR1" | grep -oP '"id":"\K[^"]+')"
assert "idem: ...and jobs create is covered"   "$BR2" '"idempotent_replay":true'
# NO key at all behaves exactly as before: two calls, two runs
NK1=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"echo","payload":{}}' | grep -oP '"id":"\K[^"]+')
NK2=$(curl -s -X POST $B/api/jobs -H "Authorization: Bearer $OP" -d '{"kind":"echo","payload":{}}' | grep -oP '"id":"\K[^"]+')
differ "idem: with no key, nothing changed" "$NK1" "$NK2"
# r2: dedupe:true DERIVES a key from the work, so re-processing an unchanged
# input is a no-op. No header is sent at all here.
DD1=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
       -d '{"input":{"subject":"dedupe-me"},"dedupe":true}')
DD2=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
       -d '{"input":{"subject":"dedupe-me"},"dedupe":true}')
assert "dedupe: an unchanged input is a no-op returning the previous run" \
  "$(printf '%s' "$DD2" | grep -oP '"id":"\K[^"]+' | head -1)" \
  "$(printf '%s' "$DD1" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "dedupe: ...and says so"                "$DD2" '"idempotent_replay":true'
# a CHANGED input under dedupe is a different derived key, so it RUNS -- it is
# not a conflict, because the client never claimed the two were the same request
DD3=$(curl -s -X POST $B/api/workflows/smoke-filer/run -H "Authorization: Bearer $OP" \
       -d '{"input":{"subject":"dedupe-OTHER"},"dedupe":true}')
differ "dedupe: a changed input runs, rather than conflicting" \
  "$(printf '%s' "$DD3" | grep -oP '"id":"\K[^"]+' | head -1)" \
  "$(printf '%s' "$DD1" | grep -oP '"id":"\K[^"]+' | head -1)"
# r3: the run says WHICH definition version ran, which is how a client can tell
# an edited workflow legitimately re-ran
assert "the run records which workflow VERSION ran" "$DD1" '"version"'

echo "== audit reads (issue #84) =="
# Its OWN object: $RID was deleted by the repository block above, and this needs
# one that still exists. PRIVATE, so bob's read is refused and r4 has an event.
APUT=$(curl -s -X PUT "$B/api/repo/audited/ssn-444-55-6666.txt?filename=a.txt&visibility=private" \
        -H "Authorization: Bearer $OP" -H 'Content-Type: text/plain' --data-binary 'audited body')
AOID=$(printf '%s' "$APUT" | grep -oP '"id":"\K[^"]+' | head -1)
# THE CONTENT ROUTE, not the metadata one. `GET /api/repo-obj/:id` answers
# metadata and is deliberately NOT audited — auditing it would bury the reads
# that matter under rows about rendering a table. `/content` is the GET that
# returns the document, which is what r1 means by "API GET".
curl -s -o /dev/null "$B/api/repo-obj/$AOID/content" -H "Authorization: Bearer $OP" \
  -H "X-Request-Id: smoke-read-1" -H "User-Agent: telemachus-smoke/1"
AR=$(curl -s "$B/api/repo-obj/$AOID/reads" -H "Authorization: Bearer $OP")
assert "reads: the API read is recorded"            "$AR" '"action":"repo.read"'
assert "reads: ...through the api door"             "$AR" '"via":"api"'
assert "reads: ...with the client's own request id" "$AR" 'smoke-read-1'
assert "reads: ...and its user agent"               "$AR" 'telemachus-smoke/1'
assert "reads: ...and the loopback client address"  "$AR" '"client_ip":"127.0.0.1"'
# metadata is NOT a content read, and the absence is asserted rather than assumed
MBEFORE=$(printf '%s' "$AR" | grep -o '"action"' | wc -l | tr -d ' ')
curl -s -o /dev/null "$B/api/repo-obj/$AOID" -H "Authorization: Bearer $OP"
MAFTER=$(curl -s "$B/api/repo-obj/$AOID/reads" -H "Authorization: Bearer $OP" | grep -o '"action"' | wc -l | tr -d ' ')
assert "reads: a METADATA get is not a content read" "$MBEFORE" "$MAFTER"
# r2: ids, never the key — this key carries something that looks like an SSN
assert "reads: the record carries no object key" \
  "$(printf '%s' "$AR" | python3 -c "
import json,sys
print('LEAKED' if '444-55-6666' in json.dumps(json.load(sys.stdin)['reads']) else 'clean')")" "clean"
# ...while the id on the entry still resolves to it, under that table's own gate
assert "reads: ...and the id still resolves to the key" \
  "$(curl -s "$B/api/repo-obj/$AOID" -H "Authorization: Bearer $OP")" '444-55-6666'
# r4: a REFUSED read is the event an auditor is looking for. The object is
# private, so a colleague is refused -- private is private from admins too.
curl -s -o /dev/null "$B/api/repo-obj/$AOID/content" -H "Authorization: Bearer $BOB"
AR2=$(curl -s "$B/api/repo-obj/$AOID/reads" -H "Authorization: Bearer $OP")
assert "reads: a refused read is recorded too"      "$AR2" '"result":"denied"'
assert "reads: ...naming what was lacking"          "$AR2" 'files:read'
# Who may read the RECORD is narrower than who may read the DOCUMENT: who has
# looked is information about the people, so `object-reads` requires
# files:manage (DSH-2's "you decide who sees this") even though the ROUTE asks
# only for files:read.
#
# On THIS object the refusal comes one step earlier and says files:read, because
# the object is private and `repo-get` refuses before the listing is reached —
# which is the honest answer and the reason the assertion names it rather than
# the permission the listing would have asked for. The two-tier case (a
# TEAM-VISIBLE document a colleague may read but may not see the readers of) is
# pinned in test/audit-read-tests.rkt, where both principals exist in one
# fixture.
assert "reads: a member may not enumerate who looked" \
  "$(curl -s "$B/api/repo-obj/$AOID/reads" -H "Authorization: Bearer $BOB")" \
  'Forbidden: files:read'

# ---- r3: the chain and the export, over HTTP --------------------------------------
# Single-tenant, so every entry this run wrote has no org: `-` is that bucket and
# is the default, which on this box is the whole log.
AV=$(curl -s "$B/api/admin/audit/verify" -H "Authorization: Bearer $OP")
assert "chain: the log verifies"                   "$AV" '"ok":true'
assert "chain: ...and says how many it checked"    "$AV" '"checked"'
assert "chain: ...with nothing broken"             "$AV" '"broken_at":null'
# verify SEALS first, so an operator never sees an unsealed tail reported as a gap
assert "chain: nothing is left unsealed after a verify" "$AV" '"unsealed":0'
assert "chain: ...and the head is named"           "$AV" '"head":"'
# the export is JSONL with the chain fields in it, which is what makes a copy
# kept elsewhere verifiable on its own
EXP=$(curl -s "$B/api/admin/audit/export?limit=20" -H "Authorization: Bearer $OP")
assert "export: one JSON object per line" \
  "$(printf '%s' "$EXP" | python3 -c "
import json,sys
ls=[l for l in sys.stdin.read().split(chr(10)) if l.strip()]
print('ok' if ls and all(isinstance(json.loads(l),dict) for l in ls) else 'BAD')")" "ok"
assert "export: ...carrying the chain hash" \
  "$(printf '%s' "$EXP" | python3 -c "
import json,sys
ls=[json.loads(l) for l in sys.stdin.read().split(chr(10)) if l.strip()]
print('ok' if all(l.get('chain_hash') for l in ls) else 'MISSING')")" "ok"
assert "export: ...and each line links to the one before" \
  "$(printf '%s' "$EXP" | python3 -c "
import json,sys
ls=[json.loads(l) for l in sys.stdin.read().split(chr(10)) if l.strip()]
print('ok' if all(b['chain_prev']==a['chain_hash'] for a,b in zip(ls,ls[1:])) else 'BROKEN')")" "ok"
# taking a copy of the log off the box is itself exactly the event a later reader
# would want to find, so the export audits itself
assert "export: the export is itself recorded" \
  "$(curl -s "$B/api/admin/audit/export?limit=200000" -H "Authorization: Bearer $OP" \
     | grep -c 'audit.exported' | awk '{print ($1 >= 1) ? "ok" : "MISSING"}')" "ok"
# an operator permission, not a team one
assert "chain: a member cannot verify the instance's log" \
  "$(curl -s "$B/api/admin/audit/verify" -H "Authorization: Bearer $BOB")" \
  'Forbidden: instance:read'
assert "chain: ...nor export it" \
  "$(curl -s "$B/api/admin/audit/export" -H "Authorization: Bearer $BOB")" \
  'Forbidden: instance:manage'
assert "chain: an unknown org is a 404, not an empty export" \
  "$(curl -s "$B/api/admin/audit/export?org=nope" -H "Authorization: Bearer $OP")" 'no such org'

echo "== object metadata =="
assert "a member may not define the team's fields" \
  "$(curl -s -X PUT $B/api/repo-fields -H "Authorization: Bearer $BOB" -d '{"fields":[]}')" \
  'Forbidden: settings:manage'
assert "an unknown setting on a field is refused, not dropped" \
  "$(curl -s -X PUT $B/api/repo-fields -H "Authorization: Bearer $OP" \
       -d '{"fields":[{"key":"structure","label":"Structure","pattern":"^x$"}]}')" \
  'unknown setting'
assert "the team defines its fields" \
  "$(curl -s -X PUT $B/api/repo-fields -H "Authorization: Bearer $OP" \
       -d '{"fields":[{"key":"structure","label":"Structure","required":true},{"key":"risk","label":"Risk","digits":true,"maxlength":"1"}]}')" \
  '"key":"structure"'
printf 'levee seven survey' > /tmp/tmx-smoke-meta.txt
MOBJ=$(curl -s -X PUT "$B/api/repo/surveys/levee7.txt" -H "Authorization: Bearer $OP" \
         -H 'Content-Type: text/plain' --data-binary @/tmp/tmx-smoke-meta.txt)
MID=$(printf '%s' "$MOBJ" | grep -oP '"id":"\K[^"]+' | head -1)
assert "a key the team never defined is refused" \
  "$(curl -s -X PATCH $B/api/repo-obj/$MID/attributes -H "Authorization: Bearer $OP" -d '{"attributes":{"depth":"4m"}}')" \
  'not a field this team has defined'
assert "the funnel's vocabulary applies here too" \
  "$(curl -s -X PATCH $B/api/repo-obj/$MID/attributes -H "Authorization: Bearer $OP" -d '{"attributes":{"structure":"levee-7","risk":"high"}}')" \
  'Risk'
assert "the document carries what the team asserted" \
  "$(curl -s -X PATCH $B/api/repo-obj/$MID/attributes -H "Authorization: Bearer $OP" -d '{"attributes":{"structure":"levee-7","risk":"3"}}')" \
  '"structure":"levee-7"'
assert "...and the listing can narrow by it" \
  "$(curl -s "$B/api/repo?attr=structure:levee-7" -H "Authorization: Bearer $OP")" 'surveys/levee7.txt'
assert "...and a value nothing has is empty" \
  "$(curl -s "$B/api/repo?attr=structure:bridge-2" -H "Authorization: Bearer $OP" | grep -c 'levee7' || true)" '0'
assert "stacked filters both apply" \
  "$(curl -s "$B/api/repo?attr=structure:levee-7&attr=risk:9" -H "Authorization: Bearer $OP" | grep -c 'levee7' || true)" '0'
# LAY-5: the seam exists before any built-in fills it — a text file has no regions
assert "provenance answers empty rather than erroring" \
  "$(curl -s "$B/api/repo-obj/$MID/spans" -H "Authorization: Bearer $OP")" '"total":0'
assert "an unknown document is a 404" \
  "$(curl -s "$B/api/repo-obj/nope/spans" -H "Authorization: Bearer $OP")" 'no such document'
rm -f /tmp/tmx-smoke-meta.txt

# ---- LAY-7: a plugin can claim a FILE FORMAT -------------------------------------
# RTF is a format the platform has no reader for — an unreadable document is
# invisible to search. example-tools registers an extractor for it, so the word
# "aqueduct", which appears ONLY inside the RTF control codes, has to come back
# through the plugin's reader, the index and search, over HTTP.
assert "the plugin's claimed format is in the reference" \
  "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"extractors":["application/rtf"]'
printf '{\\rtf1\\ansi The \\b aqueduct\\b0 survey is filed.}' > /tmp/tmx-smoke-rtf.rtf
curl -s -X PUT "$B/api/repo/surveys/report.rtf" -H "Authorization: Bearer $OP" \
  -H 'Content-Type: application/rtf' --data-binary @/tmp/tmx-smoke-rtf.rtf >/dev/null
assert "not searchable before indexing" \
  "$(curl -s "$B/api/search?q=aqueduct" -H "Authorization: Bearer $OP" | grep -c '"type":"file"' || true)" "0"
RTFRUN=$(curl -s -X POST $B/api/workflows/index-documents/run -H "Authorization: Bearer $OP" -d '{}')
RTFID=$(printf '%s' "$RTFRUN" | grep -oP '"id":"\K[^"]+' | head -1)
rtfs=""
for i in $(seq 1 40); do
  rtfs=$(curl -s "$B/api/runs/$RTFID" -H "Authorization: Bearer $OP" | grep -oP '"status":"\K[^"]+' | head -1)
  case "$rtfs" in done|error|canceled) break;; esac
  sleep 0.5
done
assert "the indexing run completed" "$rtfs" "done"
assert_content "a format only a PLUGIN can read is searchable" \
  "$(curl -s "$B/api/search?q=aqueduct" -H "Authorization: Bearer $OP")" 'surveys/report.rtf'
rm -f /tmp/tmx-smoke-rtf.rtf

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

# ---- issue #40: identity headers still work from LOOPBACK (local tooling), and
# the peer rule that refuses them from anywhere else is unit-tested in
# test/peer-tests.rkt — a smoke running on the same host cannot be a stranger.
assert "identity headers work from loopback" "$(curl -s $B/api/whoami -H 'X-Telemachus-User: alice' -H 'X-Telemachus-Team: default')" '"is_operator":true'
assert "…and no headers is still a 401"      "$(curl -s -o /dev/null -w '%{http_code}' $B/api/whoami)" '401'

# ---- issue #41: bootstrap closed after first use, whatever the caller presents
assert "bootstrap refuses a second run"      "$(curl -s -X POST $B/api/bootstrap -d '{"username":"mallory","password":"pw-pw-pw1"}')" 'Already initialized'

# ---- issue #43: an authenticated plugin page can be OPENED in a browser
TKT=$(curl -s -X POST $B/api/x/example-tools/bundle-ticket -H "Authorization: Bearer $OP" -d '{}')
assert "a bundle ticket is minted"           "$TKT" '"ticket":"'
assert "…with the url to open"               "$TKT" '"url":"/api/x/example-tools/bundle/?ticket='
TICKET=$(printf '%s' "$TKT" | grep -oP '"ticket":\s*"\K[^"]+')
assert "the page opens with the ticket, no bearer" "$(curl -s "$B/api/x/example-tools/bundle/?ticket=$TICKET")" 'Word count'
assert "…and sets a cookie scoped to that bundle" "$(curl -s -D- -o /dev/null "$B/api/x/example-tools/bundle/?ticket=$TICKET" | tr -d '\r' | grep -i '^set-cookie:')" 'tmx_bundle='
assert "…HttpOnly and SameSite=Strict"        "$(curl -s -D- -o /dev/null "$B/api/x/example-tools/bundle/?ticket=$TICKET" | tr -d '\r' | grep -i '^set-cookie:')" 'HttpOnly; SameSite=Strict'
assert "a sub-resource loads on the cookie alone" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: tmx_bundle=$TICKET" $B/api/x/example-tools/bundle/index.html)" '200'
assert "a made-up ticket is refused"          "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/example-tools/bundle/?ticket=nope")" '401'
assert "a ticket for one plugin is not another's" "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/integrator-demo/bundle/?ticket=$TICKET")" '401'
assert "a bearer still works, as the smoke always did" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/x/example-tools/bundle/ -H "Authorization: Bearer $OP")" '200'
assert "a ticket for an unknown plugin is a 404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/x/nope/bundle-ticket -H "Authorization: Bearer $OP" -d '{}')" '404'

# ---- issue #48: a plugin that failed to load is reported, not just logged
assert "the plugin listing carries a failed list" "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"failed":'
assert "…and it is empty on a healthy instance"   "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"failed":[]'
assert "a plugin with a page says so"            "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"bundle":true'

# ---- issue #27: the console runs under a NONCE, not 'unsafe-inline'
CSPH=$(curl -s -D- -o /dev/null $B/ | tr -d '\r' | grep -i '^content-security-policy:')
# #110 r6: the console has NO inline script, so its policy is a plain
# `script-src 'self'` — no 'unsafe-inline' AND no nonce. The nonce #27 introduced
# only ever authorized our own inline block; with none left it authorizes
# nothing. These four assertions are what stop that becoming a loosening by
# accident: no 'unsafe-inline', no nonce, no inline block, and the external
# script really is served.
assert "the console's CSP allows only same-origin script" "$CSPH" "script-src 'self';"
assert "…with no 'unsafe-inline'"            "$(printf '%s' "$CSPH" | grep -c "script-src 'self' 'unsafe-inline'" || true)" '0'
assert "…and no nonce, because there is nothing inline to authorize" \
  "$(printf '%s' "$CSPH" | grep -c "nonce-" || true)" '0'
assert "…while styles keep theirs (~250 attributes)" "$CSPH" "style-src 'self' 'unsafe-inline'"
assert "the shell carries no inline script block" "$(curl -s $B/ | grep -c '<script>' || true)" '0'
assert "…and loads its script from /console/"     "$(curl -s $B/)" '<script src="/console/01-base.js">'
# the file is really there: a 404 here is a console that renders an empty shell
assert "a console script file is served"      "$(curl -s $B/console/01-base.js)" 'function H(fn)'
assert "…uncached, so a deploy cannot leave a stale script against a new shell" \
  "$(curl -s -D- -o /dev/null $B/console/01-base.js | tr -d '\r' | grep -i '^cache-control:')" 'no-store'
# the traversal guard, on the raw path so curl does not collapse it first
assert "…and the path cannot climb out of static/console" \
  "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/console/../index.html")" '404'

# ---- a monitoring credential (issue #124) ------------------------------------
# Every operational READ required instance:manage, and a token holding that can
# reset any user's password. The fix is a narrower permission, not a new tier: a
# monitoring system gets an operator-issued token SCOPED to instance:read.
echo
echo "== a monitoring credential reads and cannot administer ========================"
MONTOK=$(curl -s -X POST $B/api/tokens -H "Authorization: Bearer $OP" \
  -d '{"name":"monitoring","scopes":["instance:read"],"ttl":"never"}' | grep -oP '"token":\s*"\K[^"]+')
assert "the monitoring token reads instance status" \
  "$(curl -s $B/api/admin/status -H "Authorization: Bearer $MONTOK")" '"ok":true'
assert "…and the metrics"      "$(curl -s $B/api/metrics -H "Authorization: Bearer $MONTOK")" '"users":'
assert "…and the worker fleet" "$(curl -s $B/api/admin/workers -H "Authorization: Bearer $MONTOK")" '"executors":'
assert "…and the queue"        "$(curl -s $B/api/admin/queue -H "Authorization: Bearer $MONTOK")" '"jobs":'
assert "…and can verify the audit chain" \
  "$(curl -s "$B/api/admin/audit/verify" -H "Authorization: Bearer $MONTOK")" '"ok":'
# BOTH HALVES. Only the second one is the bug: a credential that can read the
# fleet and also reset a password is what was reported.
assert "…but NOT reset a password"  \
  "$(curl -s -X POST $B/api/admin/users/$CAROL_ID/password -H "Authorization: Bearer $MONTOK" -d '{"new_password":"hijacked1"}')" 'Forbidden: instance:manage'
assert "…nor write instance branding" \
  "$(curl -s -X PUT $B/api/branding -H "Authorization: Bearer $MONTOK" -d '{"title":"nope"}')" 'Forbidden: instance:manage'
# NOT /api/orgs: the multi-tenancy flag gate answers 404 before any permission
# is consulted (#110 r2's load-bearing order), so single-tenant it would pass for
# the wrong reason.
assert "…nor tighten the instance session policy" \
  "$(curl -s -X PUT $B/api/session-policy -H "Authorization: Bearer $MONTOK" -d '{"idle_seconds":60}')" 'Forbidden: instance:manage'
# the audit EXPORT hands over the log itself, so it is deliberately NOT a read
# this permission opens — "no tenant names, no document content" was the line
assert "…and NOT the audit export, which hands over the log" \
  "$(curl -s "$B/api/admin/audit/export" -H "Authorization: Bearer $MONTOK")" 'Forbidden: instance:manage'
# the compatibility half: the operator keeps every route they had
assert "an operator still reads the fleet" "$(curl -s $B/api/admin/workers -H "Authorization: Bearer $OP")" '"executors":'
assert "…and still exports the audit log"  "$(curl -s "$B/api/admin/audit/export" -H "Authorization: Bearer $OP")" '"action":'
assert "a plain member reaches none of it" "$(curl -s $B/api/metrics -H "Authorization: Bearer $BOB")" 'Forbidden: instance:read'

# ---- what a refusal and a 500 are allowed to say (issue #123) ----------------
# A username that already exists used to reach `create-user!`, raise the UNIQUE
# violation, and come back as a 500 carrying the INSERT statement. The org plane
# always answered 409; the two agree now.
echo
echo "== duplicate username, and what a 500 says ==================================="
assert "a duplicate username is a 409 on the team plane" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')" '409'
DUP=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"bob","role":"member"}')
assert "…and says so in words a caller can act on" "$DUP" 'username already exists on this instance'
refute "…with no SQL in the reply"                 "$DUP" 'INSERT'
refute "…and no engine wording either"             "$DUP" 'constraint'
# the generic-500 rule itself is unit-tested (test/error-response-tests.rkt),
# because after this fix there may be no request left that still raises — a
# smoke assertion for it would pass by never reaching the path.

# ---- sign-in: the record, the throttle, and a person's own sessions ----------
# Issues #116, #117 and #118. A dedicated user throughout: throttling `alice`
# would leave her counter set and break every later block that signs in as her,
# which is how the quota block announced it was changing global state once.
echo
echo "== sign-in, sessions and the attempt throttle ================================="
SI=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"sven","password":"sven-pass-1","role":"member"}')
SVEN=$(printf '%s' "$SI" | grep -oP '"token":\s*"\K[^"]+')
SVEN_ID=$(printf '%s' "$SI" | grep -oP '"user_id":\s*"\K[^"]+')

# #118: a member reads their OWN sessions with no permission at all. The team's
# API tokens stay behind settings:manage, which is a different route.
assert "a member is refused the team's tokens" \
  "$(curl -s $B/api/tokens -H "Authorization: Bearer $SVEN")" 'Forbidden: settings:manage'
SESS=$(curl -s $B/api/sessions -H "Authorization: Bearer $SVEN")
assert "…but reads their own sessions"        "$SESS" '"sessions":['
assert "…and the one they are holding is marked" "$SESS" '"current":true'
assert "…with a prefix and no token"          "$SESS" '"prefix":"tk_'
refute "the listing never carries a token"    "$SESS" '"token":'
assert "…and it reports the cap"              "$SESS" '"max":'

# a second session for the same person, so there is something to end
S2=$(curl -s -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}' | grep -oP '"token":\s*"\K[^"]+')
assert "a second sign-in works"               "$(curl -s $B/api/whoami -H "Authorization: Bearer $S2")" '"user_id":'
# grep -c counts LINES and the reply is one line, so it would answer 1 for any
# number of sessions. Count OCCURRENCES.
assert "both sessions are listed"             "$(curl -s $B/api/sessions -H "Authorization: Bearer $S2" | grep -o '"prefix"' | wc -l | tr -d ' ')" '2'

# "sign out everywhere else" keeps the caller's own
assert "…everywhere else ends the other one"  "$(curl -s -X DELETE $B/api/sessions -H "Authorization: Bearer $S2")" '"ended":1'
assert "…the caller's own still works"        "$(curl -s $B/api/whoami -H "Authorization: Bearer $S2")" '"user_id":'
assert "…and the other one is dead"           "$(curl -s $B/api/whoami -H "Authorization: Bearer $SVEN")" 'Authentication required'

# #118: logout ends THIS session — the console's button called nothing before
S3=$(curl -s -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}' | grep -oP '"token":\s*"\K[^"]+')
assert "logout answers ok"                    "$(curl -s -X POST $B/api/logout -H "Authorization: Bearer $S3")" '"ok":true'
assert "…and the token really stops working"  "$(curl -s $B/api/whoami -H "Authorization: Bearer $S3")" 'Authentication required'

# one of the caller's own, by id; somebody else's is a 404 and not a 403
S4=$(curl -s -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}' | grep -oP '"token":\s*"\K[^"]+')
S5=$(curl -s -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}' | grep -oP '"token":\s*"\K[^"]+')
S4ID=$(curl -s $B/api/sessions -H "Authorization: Bearer $S4" | grep -oP '"id":"[^"]+","name":[^,]*,"prefix":"[^"]*","status":"active"' | head -1 | grep -oP '"id":"\K[^"]+')
assert "a session ends by id"                 "$(curl -s -X DELETE $B/api/sessions/$S4ID -H "Authorization: Bearer $S5")" '"ok":true'
OPSESS=$(curl -s $B/api/sessions -H "Authorization: Bearer $OP" | grep -oP '"id":"\K[^"]+' | head -1)
assert "…and somebody else's is a 404, not a 403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B/api/sessions/$OPSESS -H "Authorization: Bearer $S5")" '404'
assert "…so the operator's session is untouched" "$(curl -s $B/api/whoami -H "Authorization: Bearer $OP")" '"user_id":'

# #116: every attempt is audited. The operator reads the team trail.
assert "a successful sign-in is recorded"     "$(curl -s $B/api/audit -H "Authorization: Bearer $OP")" '"action":"user.login"'
assert "…and the logout too"                  "$(curl -s $B/api/audit -H "Authorization: Bearer $OP")" '"action":"user.logout"'

# #116: the growing delay. Three failures are free, the fourth starts costing.
for i in 1 2 3; do
  curl -s -o /dev/null -X POST $B/api/login -d '{"username":"sven","password":"wrong"}'
done
assert "three failures still answer 401"      "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/login -d '{"username":"sven","password":"wrong"}')" '401'
THROTTLED=$(curl -s -D- -X POST $B/api/login -d '{"username":"sven","password":"wrong"}' | tr -d '\r')
assert "…then the next one is throttled"      "$THROTTLED" '429'
assert "…with a retry-after the client can read" "$THROTTLED" 'retry_after'
assert "…and the header form too"             "$(printf '%s' "$THROTTLED" | grep -ci '^retry-after:' || true)" '1'
# The throttle refuses a CORRECT password too while the delay is running — it has
# to, or it would be an account-existence oracle of a different kind — which is
# exactly why the delay is capped at a minute and why a hard lock is opt-in.
assert "…and it refuses the right password too, while the delay runs" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}')" '429'
# the fourth failure bought a 2-second delay; wait it out and the counter clears
sleep 3
assert "…then a correct password works and forgets the history" \
  "$(curl -s -X POST $B/api/login -d '{"username":"sven","password":"sven-pass-1"}')" '"token":"tk_'
assert "…so the next wrong password is a plain 401 again" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/login -d '{"username":"sven","password":"wrong"}')" '401'
# the failures are in the trail as well, with the username that was tried and
# never the password
AUD=$(curl -s $B/api/admin/audit/export -H "Authorization: Bearer $OP")
assert "a failed sign-in is recorded"      "$AUD" '"result":"failed"'
# `meta` rides in the export as a STRING, so its own quotes are escaped — the
# needle has to be the escaped form, not the shape the handler wrote.
assert "…naming the account that was tried" "$AUD" 'username\":\"sven'
refute "…and never the password"           "$AUD" 'sven-pass-1'
refute "…nor the one that was guessed"     "$AUD" 'password\":\"wrong'

# ---- issue #19: secrets at rest, and a TOTP seed that can be revoked
assert "admin status says whether a dump is replayable" "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"secrets":'
# Inapplicable when a key IS configured, which TELEMACHUS_ENCRYPT_CONTENT requires.
if [ -n "${TELEMACHUS_SECRET_KEY:-}" ]; then
  echo "  skip …plaintext when no key is configured — a key is set in this run"
else
  assert "…plaintext when no key is configured"           "$(curl -s $B/api/admin/status -H "Authorization: Bearer $OP")" '"secrets":"plaintext"'
fi
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

# ---- reviews (LAY-1..3): a workflow that waits for a person ---------------------
echo
echo "== reviews =="
# create_note is left DISABLED by the tool-activation assertion above; this block
# needs a tool that runs, and restores the state it found when it is done.
curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":true}' >/dev/null
RWF='{"spec":1,"slug":"smoke-review","description":"draft then ask a person",
      "max_steps":10,"input":{"subject":"string"},"start":"draft",
      "steps":[
        {"id":"draft","uses":"tool:create_note",
         "with":{"title":"${input.subject}","body":"a drafted finding"},"next":"check"},
        {"id":"check","uses":"review","title":"Check the finding",
         "instructions":"Confirm it is supported.",
         "of":"${steps.draft.output.result}",
         "checklist":[{"key":"method","label":"Technical validity","required":true}],
         "four_eyes":true,
         "on":{"approve":"file","revise":"draft","reject":null}},
        {"id":"file","uses":"tool:create_note","with":{"title":"filed","body":"approved"},"end":true}]}'
assert "review wf publish" "$(curl -s -X POST $B/api/workflows -H "Authorization: Bearer $OP" -d "$RWF")" '"slug":"smoke-review"'
RRID=$(curl -s -X POST $B/api/workflows/smoke-review/run -H "Authorization: Bearer $OP" \
         -d '{"input":{"subject":"levee 7"}}' | grep -oP '"id":"\K[^"]+' | head -1)
rrun=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  rrun=$(curl -s $B/api/runs/$RRID -H "Authorization: Bearer $OP")
  printf '%s' "$rrun" | grep -qF '"status":"running"' || break
  sleep 0.5
done
assert "a review step PARKS the run" "$rrun" '"status":"waiting"'

RQ=$(curl -s "$B/api/reviews" -H "Authorization: Bearer $OP")
assert "the queue carries it"          "$RQ" '"title":"Check the finding"'
assert "...with its checklist"         "$RQ" '"label":"Technical validity"'
assert "...and what is under review"   "$RQ" 'Created note'
RVID=$(printf '%s' "$RQ" | grep -oP '"id":"\K[^"]+' | head -1)
# a filter that is ignored rather than refused is invisible to a model test
assert "?status is honoured, not defaulted" \
  "$(curl -s "$B/api/reviews?status=decided" -H "Authorization: Bearer $OP")" '"reviews":[]'

# a plain member reviews — this is the specialist's job, not a stewardship act
assert "a member may read the queue" "$(curl -s $B/api/reviews -H "Authorization: Bearer $BOB")" '"title":"Check the finding"'
assert "a rationale is required to send work back" \
  "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $BOB" -d '{"verdict":"revise"}')" \
  'rationale is required'
assert "an unknown verdict is refused" \
  "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $BOB" -d '{"verdict":"escalate"}')" \
  'verdict must be one of'
assert "a required checklist answer is demanded" \
  "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $BOB" -d '{"verdict":"approve"}')" \
  'Technical validity'
# four eyes: the operator STARTED this run, so the operator may not wave it through
assert "four eyes refuses the run's own initiator" \
  "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $OP" \
       -d '{"verdict":"approve","answers":{"method":"sound"}}')" \
  'second pair of eyes'
assert "...and the run is still parked" "$(curl -s $B/api/runs/$RRID -H "Authorization: Bearer $OP")" '"status":"waiting"'

assert "a colleague decides it" \
  "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $BOB" \
       -d '{"verdict":"approve","rationale":"supported by the survey","answers":{"method":"sound"}}')" \
  '"verdict":"approve"'
rdone=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  rdone=$(curl -s $B/api/runs/$RRID -H "Authorization: Bearer $OP")
  printf '%s' "$rdone" | grep -qE '"status":"(waiting|running)"' || break
  sleep 0.5
done
assert "the decision resumed the run" "$rdone" '"status":"done"'
assert "deciding again is refused"    "$(curl -s -X POST $B/api/reviews/$RVID/decide -H "Authorization: Bearer $BOB" -d '{"verdict":"approve"}')" 'already been decided'
# LAY-10/LAY-11: the signal and the evidence, over the decision just made.
# /api/reviews/stats must not be swallowed by /api/reviews/:id — literal paths
# come first in the table, and a 'no such review' here would mean they do not.
RSTATS=$(curl -s "$B/api/reviews/stats" -H "Authorization: Bearer $OP")
assert "the accuracy report is a query, not a subsystem" "$RSTATS" '"workflow":"smoke-review"'
assert "...reporting the step that was reviewed"        "$RSTATS" '"step":"check"'
assert "...and how often the output stood"              "$RSTATS" '"approval_rate"'
assert "a member may read it"                           "$(curl -s "$B/api/reviews/stats" -H "Authorization: Bearer $BOB")" '"stats":'
RVERIFY=$(curl -s "$B/api/reviews/verify" -H "Authorization: Bearer $OP")
assert "the decision chain verifies"       "$RVERIFY" '"ok":true'
assert "...having actually checked a link" "$RVERIFY" '"checked":1'
assert "verifying the chain is an auditor's act, not a reviewer's" \
  "$(curl -s "$B/api/reviews/verify" -H "Authorization: Bearer $BOB")" 'Forbidden: audit:read'

assert "the decision is in the audit log" \
  "$(curl -s "$B/api/audit?limit=5" -H "Authorization: Bearer $OP")" 'review.approve'
curl -s -X POST $B/api/tools/create_note -H "Authorization: Bearer $OP" -d '{"enabled":false}' >/dev/null  # restore

# ---- LAY-6: an out-of-process plugin can reach the repository --------------------
# It could reach notes.create and notes.list and nothing else, so a Python OCR or
# CV pipeline could read no bytes and write no result — while an in-process Racket
# tool read blobs freely. doc-reader is the worked example: no database handle, it
# asks the host for repo.text and repo.put.
assert "the out-of-process reader registered" \
  "$(curl -s $B/api/tools -H "Authorization: Bearer $OP")" 'oop__doc-reader__read_document'
assert "...listed as sandboxed, with the scopes it declared" \
  "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" '"name":"doc-reader"'
assert "...and the declared scope is visible to an operator" \
  "$(curl -s $B/api/plugins -H "Authorization: Bearer $OP")" 'files:write'

# ---- identity: offboarding and password hygiene (issue #54) ---------------------
echo
echo "== members and passwords =="
# a user of this block's own, so revoking sessions cannot strip $OP or $BOB
DN=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"dana","password":"dana-pass-1","role":"member"}')
DANA=$(printf '%s' "$DN" | grep -oP '"token":\s*"\K[^"]+')
DANA_ID=$(printf '%s' "$DN" | grep -oP '"user_id":\s*"\K[^"]+')
assert "dana is a member" "$(curl -s $B/api/members -H "Authorization: Bearer $OP")" '"username":"dana"'

assert "a member may not change roles" \
  "$(curl -s -X PATCH $B/api/members/$DANA_ID -H "Authorization: Bearer $DANA" -d '{"role":"admin"}')" \
  'Forbidden: members:manage'
assert "an unknown role is refused" \
  "$(curl -s -X PATCH $B/api/members/$DANA_ID -H "Authorization: Bearer $OP" -d '{"role":"wizard"}')" \
  'unknown role'
assert "the role changes" \
  "$(curl -s -X PATCH $B/api/members/$DANA_ID -H "Authorization: Bearer $OP" -d '{"role":"admin"}')" \
  '"role":"admin"'
assert "...and the new role is in force" \
  "$(curl -s $B/api/audit -H "Authorization: Bearer $DANA")" '"audit":'

# the last owner is the one thing that may not go — a team with no owner cannot
# grant anybody the permission to fix it
OPID=$(curl -s $B/api/whoami -H "Authorization: Bearer $OP" | grep -oP '"user_id":\s*"\K[^"]+')
assert "the last owner cannot be demoted" \
  "$(curl -s -X PATCH $B/api/members/$OPID -H "Authorization: Bearer $OP" -d '{"role":"admin"}')" \
  'last owner cannot be demoted'
assert "the last owner cannot be removed" \
  "$(curl -s -X DELETE $B/api/members/$OPID -H "Authorization: Bearer $OP")" \
  'last owner cannot be removed'

# removing somebody whose credentials go on working is not removing them
assert "dana's token works while she is a member" \
  "$(curl -s $B/api/notes -H "Authorization: Bearer $DANA")" '"notes":'
assert "removing her revokes her team tokens" \
  "$(curl -s -X DELETE $B/api/members/$DANA_ID -H "Authorization: Bearer $OP")" '"tokens_revoked":'
assert "...her credential stops working" \
  "$(curl -s $B/api/notes -H "Authorization: Bearer $DANA")" 'Authentication required'
assert "...and she is off the member list" \
  "$(curl -s $B/api/members -H "Authorization: Bearer $OP" | grep -c dana || true)" '0'
assert "removal is audited" "$(curl -s "$B/api/audit?limit=5" -H "Authorization: Bearer $OP")" 'member.remove'

# a password change signs every session out, including the one making the call
EV=$(curl -s -X POST $B/api/members -H "Authorization: Bearer $OP" -d '{"username":"eve","password":"eve-pass-111","role":"member"}')
EVE=$(printf '%s' "$EV" | grep -oP '"token":\s*"\K[^"]+')
EVE_ID=$(printf '%s' "$EV" | grep -oP '"user_id":\s*"\K[^"]+')
assert "eve changes her password" \
  "$(curl -s -X POST $B/api/password -H "Authorization: Bearer $EVE" -d '{"current_password":"eve-pass-111","new_password":"eve-pass-222"}')" \
  '"signed_out":true'
assert "...which revoked the session that made the call" \
  "$(curl -s $B/api/notes -H "Authorization: Bearer $EVE")" 'Authentication required'
assert "...and is audited" "$(curl -s "$B/api/audit?limit=5" -H "Authorization: Bearer $OP")" 'user.password'
assert "...and the new password signs in" \
  "$(curl -s -X POST $B/api/login -d '{"username":"eve","password":"eve-pass-222"}')" '"token":"tk_'

# the way back in for somebody who cannot sign in at all
assert "a member may not reset another's password" \
  "$(curl -s -X POST $B/api/admin/users/$EVE_ID/password -H "Authorization: Bearer $BOB" -d '{"new_password":"zzz-999"}')" \
  'Forbidden: instance:manage'
assert "a short reset is refused" \
  "$(curl -s -X POST $B/api/admin/users/$EVE_ID/password -H "Authorization: Bearer $OP" -d '{"new_password":"x"}')" \
  'min 6'
assert "an operator resets a locked-out password" \
  "$(curl -s -X POST $B/api/admin/users/$EVE_ID/password -H "Authorization: Bearer $OP" -d '{"new_password":"eve-pass-333"}')" \
  '"ok":true'
assert "...and the reset password signs in" \
  "$(curl -s -X POST $B/api/login -d '{"username":"eve","password":"eve-pass-333"}')" '"token":"tk_'
assert "...and the reset is audited" "$(curl -s "$B/api/audit?limit=20" -H "Authorization: Bearer $OP")" 'user.password.reset'

# ---- session policy (issue #38, OWASP idle + absolute timeouts) -----------------
echo
echo "session policy:"
SP=$(curl -s "$B/api/session-policy" -H "Authorization: Bearer $OP")
assert "the shipped idle window is OWASP's 30 minutes" "$SP" '"idle_seconds":1800'
assert "...and the absolute cap is 8 hours"            "$SP" '"absolute_seconds":28800'
assert "the bounds are published with the policy"      "$SP" '"idle_min"'
assert "a member may not read the instance policy" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/session-policy" -H "Authorization: Bearer $BOB")" "403"
assert "an operator may tighten it" \
  "$(curl -s -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" -d '{"idle_seconds":900,"absolute_seconds":14400,"warn_seconds":60}')" \
  '"idle_seconds":900'
# validation is the point: a control that silently ignores a setting is worse than none
assert "an unknown field is refused, not dropped" \
  "$(curl -s -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" -d '{"idle_minutes":30}')" 'unknown field'
assert "an idle window below the floor is refused" \
  "$(curl -s -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" -d '{"idle_seconds":5}')" 'at least 60 seconds'
assert "a warning after the fact is refused" \
  "$(curl -s -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" -d '{"idle_seconds":300,"warn_seconds":300}')" 'must be less than'
assert "an absolute cap under the idle window is refused" \
  "$(curl -s -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" -d '{"idle_seconds":3600,"absolute_seconds":600}')" 'must not be less than'
# the console needs its own numbers to warn in advance, and gets them per-caller
assert "whoami carries the caller's effective policy" \
  "$(curl -s "$B/api/whoami" -H "Authorization: Bearer $OP")" '"session_policy"'
# a token listing distinguishes a browser session from a machine credential
TL=$(curl -s "$B/api/tokens" -H "Authorization: Bearer $OP")
assert "the token listing labels the kind" "$TL" '"kind"'
assert "the bootstrap credential is a session" "$TL" '"kind":"session"'
# the org plane is 404 while multi-tenancy is off, like the rest of it
assert "the org policy plane is invisible single-tenant" \
  "$(curl -s "$B/api/org/session-policy" -H "Authorization: Bearer $OP")" 'not enabled'
# put it back so nothing downstream in this smoke runs under a 15-minute window
curl -s -o /dev/null -X PUT "$B/api/session-policy" -H "Authorization: Bearer $OP" \
  -d '{"idle_seconds":1800,"absolute_seconds":28800,"warn_seconds":60}'

if [ $fail -eq 0 ]; then echo "server-smoke: PASS"; else echo "server-smoke: FAIL"; fi
exit $fail
