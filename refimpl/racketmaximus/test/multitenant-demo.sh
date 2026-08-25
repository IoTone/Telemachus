#!/usr/bin/env bash
# test/multitenant-demo.sh — the multi-tenancy demo + validation (slice 45).
#
# Boots a server with TELEMACHUS_MULTITENANT=1 on a temp DB, seeds two complete
# companies (Acme Robotics + Globex Media) with known dev logins, and asserts the
# properties that make "several companies on one system" actually true:
#
#   1  two orgs each own a team slugged `engineering`   (per-org slug uniqueness)
#   2  an org owner cannot reach `instance:*`           (no superadmin leak down)
#   3  an org owner CAN run its own company
#   4  cross-org reads fail                             (the org gate)
#   5  a cross-org resource_grant does NOT open access  (gate runs before grants)
#   6  an org admin manages but does not read (TEN-2a); it can read the org audit
#   7  the org quota caps the company above its teams
#   8  suspending a company freezes only that company
#   9  flag OFF → the whole surface is 404 and single-tenant behaves as before
#  10  a company is provisioned from a devops pipeline, with NO restart
#
# Run from refimpl/racketmaximus/ :  bash test/multitenant-demo.sh
# Read it top-to-bottom as the narrated demo; the logins it prints are usable by
# hand against the same server.
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export PORT="${PORT:-8836}"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/telemachus.db}"
export TELEMACHUS_MULTITENANT=1
echo "multitenant demo — DATABASE_URL=$DATABASE_URL"

fail=0
assert(){ # <label> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"
  else echo "  FAIL $1 — expected to contain: $3 — got: $2"; fail=1; fi
}
refute(){ # <label> <haystack> <needle-that-must-be-absent>
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  FAIL $1 — must NOT contain: $3 — got: $2"; fail=1
  else echo "  ok   $1"; fi
}
# read a value out of a JSON body: jget '<python expr over d>' <<< "$JSON"
jget(){ python3 -c 'import sys,json;print(eval(sys.argv[1],{"d":json.load(sys.stdin)}))' "$1"; }

# declared before the trap: with `set -u` an EXIT before section 11 would otherwise
# abort the cleanup on an unbound variable and leak the temp dir
SRV2=""; DIR2=""

# Refuse to start if either port is already taken. Without this the readiness loop
# below is satisfied by SOMEONE ELSE's server (a dev instance on the default port),
# and every assertion then runs against the wrong database — which reads as a
# baffling wall of failures rather than "the port was busy".
# The probe runs in a CHILD bash on purpose: `(exec 3<>/dev/tcp/...)` in this shell
# is optimized out of its subshell, so a failed redirection would take the script
# down with it instead of returning false.
port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
for port in "$PORT" "$((PORT+1))"; do
  if port_busy "$port"; then
    echo "port $port is already in use — set PORT=<free port> (the demo needs PORT and PORT+1)" >&2
    exit 1
  fi
done

racket server/main.rkt >/tmp/tmx-mt.log 2>&1 &
SRV=$!
trap 'kill $SRV $SRV2 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR" "$DIR2"' EXIT
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 30000 ] && { echo "server never came up"; cat /tmp/tmx-mt.log; exit 1; }
done; exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
# curl helpers: GET/POST as a given bearer token
g(){ curl -s "$B$1" -H "Authorization: Bearer $2"; }
pj(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $2" -d "${3:-{\}}"; }

echo
echo "== 0. bootstrap the SUPERADMIN (instance operator) =============================="
assert "flag advertised" "$(curl -s $B/health)" '"multitenant":true'
BS=$(curl -s -X POST $B/api/bootstrap -d '{"username":"root@instance","password":"superadmin1"}')
ROOT=$(jget 'd["token"]' <<<"$BS")
assert "superadmin created"  "$BS" '"multitenant":true'
assert "instance org"        "$(g /api/whoami $ROOT)" '"org_slug":"system"'
assert "is operator"         "$(g /api/whoami $ROOT)" '"is_operator":true'

echo
echo "== 1. seed two companies ======================================================="
SEED=$(pj /api/admin/seed-tenants $ROOT)
assert "seeded"          "$SEED" '"ok":true'
assert "seed is idempotent-guarded" "$(pj /api/admin/seed-tenants $ROOT)" 'already seeded'

ACME_ORG=$(jget 'd["tenants"][0]["org_id"]'            <<<"$SEED")
ACME_TEAM=$(jget 'd["tenants"][0]["team_id"]'          <<<"$SEED")
ACME_OWNER=$(jget 'd["tenants"][0]["owner"]["token"]'  <<<"$SEED")
ACME_DEV=$(jget 'd["tenants"][0]["member"]["token"]'   <<<"$SEED")
ACME_DEV_ID=$(jget 'd["tenants"][0]["member"]["user_id"]' <<<"$SEED")
ACME_NOTE=$(jget 'd["tenants"][0]["private_note_id"]'  <<<"$SEED")
GLBX_ORG=$(jget 'd["tenants"][1]["org_id"]'            <<<"$SEED")
GLBX_TEAM=$(jget 'd["tenants"][1]["team_id"]'          <<<"$SEED")
GLBX_OWNER=$(jget 'd["tenants"][1]["owner"]["token"]'  <<<"$SEED")
GLBX_DEV=$(jget 'd["tenants"][1]["member"]["token"]'   <<<"$SEED")
GLBX_NOTE=$(jget 'd["tenants"][1]["private_note_id"]'  <<<"$SEED")

echo "  --- demo logins (dev passwords, printed on purpose) ---"
jget 'chr(10).join("      %-20s %-16s %s" % (t["org_name"], r, t[k]["username"]+" / "+t[k]["password"]) for t in d["tenants"] for k,r in (("owner","org_owner"),("member","member")))' <<<"$SEED"
echo "      root@instance / superadmin1   (superadmin)"

echo
echo "== 2. per-org team slugs: BOTH companies run an 'engineering' team ============="
ORGS=$(g /api/orgs $ROOT)
assert "acme listed"    "$ORGS" '"slug":"acme"'
assert "globex listed"  "$ORGS" '"slug":"globex"'
assert "acme eng team"   "$(g /api/orgs/$ACME_ORG $ROOT)" '"slug":"engineering"'
assert "globex eng team" "$(g /api/orgs/$GLBX_ORG $ROOT)" '"slug":"engineering"'
if [ "$ACME_TEAM" != "$GLBX_TEAM" ]; then echo "  ok   the two 'engineering' teams are distinct"
else echo "  FAIL the two 'engineering' teams collided"; fail=1; fi

echo
echo "== 3. an org owner is NOT a superadmin ========================================="
assert "no instance:manage"  "$(g /api/admin/status $ACME_OWNER)" 'Forbidden: instance:manage'
assert "cannot list orgs"    "$(g /api/orgs $ACME_OWNER)"         'Forbidden: instance:manage'
assert "cannot see globex"   "$(g /api/orgs/$GLBX_ORG $ACME_OWNER)" 'Forbidden: instance:manage'
assert "cannot seed"         "$(pj /api/admin/seed-tenants $ACME_OWNER)" 'Forbidden: instance:manage'
assert "no org tier for dev" "$(g /api/org $ACME_DEV)"            'Forbidden: org:read'

echo
echo "== 4. an org owner CAN run its own company ====================================="
MYORG=$(g /api/org $ACME_OWNER)
assert "own org visible"  "$MYORG" '"slug":"acme"'
refute "globex not shown" "$MYORG" 'Globex'
NT=$(pj /api/org/teams $ACME_OWNER '{"name":"Operations"}')
assert "team created"     "$NT" '"slug":"operations"'
OPS_TEAM=$(jget 'd["id"]' <<<"$NT")
assert "team listed"      "$(g /api/org/teams $ACME_OWNER)" '"slug":"operations"'
assert "dup slug refused" "$(pj /api/org/teams $ACME_OWNER '{"name":"Operations"}')" 'already exists'
# the same slug is free in the other company — that is the point of per-org slugs
assert "globex may reuse it" "$(pj /api/org/teams $GLBX_OWNER '{"name":"Operations"}')" '"slug":"operations"'

echo
echo "== 5. cross-org isolation ======================================================"
assert "acme owner ✗ globex note" "$(g /api/notes/$GLBX_NOTE $ACME_OWNER)" 'Forbidden'
assert "acme dev   ✗ globex note" "$(g /api/notes/$GLBX_NOTE $ACME_DEV)"   'Forbidden'
assert "globex dev ✗ acme note"   "$(g /api/notes/$ACME_NOTE $GLBX_DEV)"   'Forbidden'
refute "acme note list is acme-only" "$(g /api/notes $ACME_DEV)" 'Globex'
refute "globex note list is globex-only" "$(g /api/notes $GLBX_DEV)" 'Acme'
# and the superadmin, by design, can cross
assert "superadmin sees org detail" "$(g /api/orgs/$GLBX_ORG $ROOT)" '"slug":"globex"'

echo
echo "== 6. a cross-org share does NOT tunnel out of the org ========================="
SH=$(curl -s -X POST $B/api/notes/$GLBX_NOTE/share -H "Authorization: Bearer $GLBX_DEV" \
     -d "{\"user_id\":\"$ACME_DEV_ID\",\"permission\":\"notes:read\"}")
echo "  (grant written: $(printf '%s' "$SH" | head -c 60))"
assert "grant does not open it" "$(g /api/notes/$GLBX_NOTE $ACME_DEV)" 'Forbidden'

echo
echo "== 7. TEN-2a — an org admin MANAGES but does not READ =========================="
# a company administrator who is not a member of engineering
HR=$(pj /api/org/members $ACME_OWNER "{\"username\":\"hr@acme.test\",\"password\":\"acme-hr1\",\"org_role\":\"org_admin\",\"team_id\":\"$OPS_TEAM\",\"role\":\"admin\"}")
assert "org admin created" "$HR" '"org_role":"org_admin"'
HR_TOK=$(jget 'd["token"]' <<<"$HR")
# a team-visible note in engineering — not private, just another team's data
TV=$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $ACME_DEV" \
     -d '{"title":"Sprint plan","body":"team-visible","visibility":"team"}')
TV_ID=$(jget 'd["id"]' <<<"$TV")
assert "org admin ✗ other team's note" "$(g /api/notes/$TV_ID $HR_TOK)" 'Forbidden'
assert "org admin ✓ org audit"         "$(g /api/org/audit $HR_TOK)"    '"events"'
assert "org admin ✓ org teams"         "$(g /api/org/teams $HR_TOK)"    '"slug":"engineering"'
assert "org admin ✗ instance"          "$(g /api/admin/status $HR_TOK)" 'Forbidden: instance:manage'
refute "org audit is acme-only"        "$(g /api/org/audit $HR_TOK)"    'globex'

echo
echo "== 8. the org quota caps the company above its teams ==========================="
# the team's own budget is generous (200 req/day); the COMPANY is capped at 1
assert "org cap set" "$(pj /api/orgs/$ACME_ORG/quota $ROOT '{"dimension":"ai.requests","limit":1,"window":"day"}')" '"ok":true'
E1=$(pj /api/ai/echo $ACME_DEV '{"prompt":"first"}')
assert "1st call allowed" "$E1" '"reply":"FIRST"'
E2=$(pj /api/ai/echo $ACME_DEV '{"prompt":"second"}')
assert "2nd call refused"     "$E2" 'quota exceeded'
assert "refused by the ORG"   "$E2" '"subject":"org"'
# a DIFFERENT team in the same company shares the exhausted company budget
E3=$(curl -s -X POST $B/api/ai/echo -H "Authorization: Bearer $HR_TOK" -d '{"prompt":"other team"}')
assert "sibling team also refused" "$E3" 'quota exceeded'
# ...while the other company is untouched
assert "globex unaffected" "$(pj /api/ai/echo $GLBX_DEV '{"prompt":"hello"}')" '"reply":"HELLO"'

echo
echo "== 9. suspending a company freezes only that company ==========================="
assert "suspend acme" "$(pj /api/orgs/$ACME_ORG/suspend $ROOT)" '"status":"suspended"'
assert "acme writes blocked"  "$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $ACME_DEV" -d '{"title":"nope"}')" 'tenant suspended'
assert "acme sibling blocked" "$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $HR_TOK"   -d '{"title":"nope"}')" 'tenant suspended'
assert "acme reads still ok"  "$(g /api/notes $ACME_DEV)" '"notes"'
assert "globex unaffected"    "$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $GLBX_DEV" -d '{"title":"still working"}')" '"title":"still working"'
assert "resume acme" "$(pj /api/orgs/$ACME_ORG/resume $ROOT)" '"status":"active"'
assert "acme writes restored" "$(curl -s -X POST $B/api/notes -H "Authorization: Bearer $ACME_DEV" -d '{"title":"back"}')" '"title":"back"'

echo
echo "== 10. onboarding a company from a pipeline (no restart) ========================"
# This is the devops path: a superadmin token, one POST, declarative and re-runnable.
# The server is the SAME PROCESS that has been serving sections 0-9 — nothing here
# restarts it, and Initech is live on the very next request.
PIPE='{"name":"Initech","slug":"initech","plan":"starter","owner_username":"admin@initech.test","owner_password":"initech-admin1","team_name":"Platform","team_slug":"platform"}'
NEW=$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ROOT" -d "$PIPE")
assert "org provisioned"      "$NEW" '"org_slug":"initech"'
assert "…on the starter plan" "$NEW" '"plan":"starter"'
assert "…with an owner token" "$NEW" '"token":"tk_'
INI_OWNER=$(jget 'd["token"]' <<<"$NEW")
INI_ID=$(jget 'd["org_id"]' <<<"$NEW")
# usable IMMEDIATELY — no restart, no reload, no cache to invalidate
assert "owner works at once"  "$(g /api/org $INI_OWNER)" '"slug":"initech"'
assert "…isolated on arrival" "$(g /api/notes/$ACME_NOTE $INI_OWNER)" 'Forbidden'

# addressable by the SLUG the pipeline declared, not just the id the server minted
assert "GET by slug"     "$(g /api/orgs/initech $ROOT)" '"slug":"initech"'
assert "GET by id"       "$(g /api/orgs/$INI_ID $ROOT)" '"slug":"initech"'
assert "unknown ref 404" "$(g /api/orgs/no-such-company $ROOT)" 'not found'

# RE-RUNNING the pipeline must not mint a second Initech. An explicit slug is a
# natural key: 409, never `initech-1`.
RERUN=$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ROOT" -d "$PIPE")
assert "re-run refused"     "$RERUN" "already exists"
refute "no shadow company"  "$(g /api/orgs $ROOT)" '"slug":"initech-1"'
# ...even when the owner differs, which is the case the username check misses
RERUN2=$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ROOT" \
  -d '{"name":"Initech","slug":"initech","owner_username":"someone-else@initech.test"}')
assert "re-run w/ new owner refused" "$RERUN2" "already exists"
refute "still no shadow company"     "$(g /api/orgs $ROOT)" '"slug":"initech-1"'
# a slug DERIVED from the name still suffixes — two humans may really mean two
# companies, and there is no declared key to honour
DERIVED=$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ROOT" \
  -d '{"name":"Initech","owner_username":"admin@initech2.test"}')
assert "derived slug suffixes" "$DERIVED" '"org_slug":"initech-1"'

# plan changes are live: PATCH re-applies that plan's caps
assert "starter cap" "$(g /api/orgs/initech $ROOT)" '"limit":1000000'
UP=$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ROOT" -d '{"plan":"pro"}')
assert "plan upgraded"   "$UP" '"plan":"pro"'
assert "caps re-applied" "$UP" '"quotas_reapplied":true'
assert "pro cap live"    "$(g /api/orgs/initech $ROOT)" '"limit":10000000'
assert "rename"          "$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ROOT" -d '{"name":"Initech Holdings"}')" '"ok":true'
assert "…name changed"   "$(g /api/orgs/initech $ROOT)" 'Initech Holdings'
refute "…rename leaves the plan alone" "$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ROOT" -d '{"name":"Initech Holdings"}')" '"quotas_reapplied":true'
assert "bad plan refused"    "$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ROOT" -d '{"plan":"enterprize"}')" 'unknown plan'
assert "empty patch refused" "$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ROOT" -d '{}')" 'required'
assert "bad plan at create"  "$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ROOT" -d '{"name":"Hooli","plan":"gold","owner_username":"admin@hooli.test"}')" 'unknown plan'

# suspend/resume/quota address by slug too — the lifecycle a pipeline drives
assert "suspend by slug" "$(pj /api/orgs/initech/suspend $ROOT)" '"status":"suspended"'
assert "quota by slug"   "$(pj /api/orgs/initech/quota $ROOT '{"dimension":"ai.requests","limit":5,"window":"day"}')" '"ok":true'
assert "resume by slug"  "$(pj /api/orgs/initech/resume $ROOT)" '"status":"active"'

# an org owner still cannot reach ANY of it
assert "org owner ✗ create" "$(curl -s -X POST $B/api/orgs -H "Authorization: Bearer $ACME_OWNER" -d '{"name":"Sneaky","owner_username":"x@y.test"}')" 'Forbidden: instance:manage'
assert "org owner ✗ patch"  "$(curl -s -X PATCH $B/api/orgs/initech -H "Authorization: Bearer $ACME_OWNER" -d '{"plan":"enterprise"}')" 'Forbidden: instance:manage'

echo
echo "== 11. flag OFF → the surface disappears, single-tenant is unchanged ==========="
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
# Always SQLite here regardless of an outer DATABASE_URL: this section needs a
# virgin database to bootstrap into, which on Postgres would mean provisioning a
# second one. The flag-off parity check does not depend on the backend.
DIR2="$(mktemp -d)"   # declared empty above
TELEMACHUS_MULTITENANT=0 TELEMACHUS_DATA_DIR="$DIR2" DATABASE_URL="sqlite:///$DIR2/telemachus.db" \
  PORT=$((PORT+1)) racket server/main.rkt >/tmp/tmx-st.log 2>&1 &
SRV2=$!
B2="localhost:$((PORT+1))"
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$((PORT+1))) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 30000 ] && { echo "single-tenant server never came up"; cat /tmp/tmx-st.log; exit 1; }
done; exec 3>&- 2>/dev/null || true

assert "flag off advertised" "$(curl -s $B2/health)" '"multitenant":false'
BS2=$(curl -s -X POST $B2/api/bootstrap -d '{"username":"alice","password":"s3cret"}')
OP2=$(jget 'd["token"]' <<<"$BS2")
assert "single-tenant bootstrap" "$BS2" '"multitenant":false'
assert "orgs plane is 404"  "$(curl -s $B2/api/orgs -H "Authorization: Bearer $OP2")"  'not enabled'
assert "org plane is 404"   "$(curl -s $B2/api/org  -H "Authorization: Bearer $OP2")"  'not enabled'
assert "seed-tenants is 404" "$(curl -s -X POST $B2/api/admin/seed-tenants -H "Authorization: Bearer $OP2")" 'not enabled'
assert "classic members flow" "$(curl -s -X POST $B2/api/members -H "Authorization: Bearer $OP2" -d '{"username":"bob","role":"member"}')" '"token":"tk_'
assert "classic notes flow"   "$(curl -s -X POST $B2/api/notes   -H "Authorization: Bearer $OP2" -d '{"title":"hello"}')" '"title":"hello"'
# the implicit org still exists — same schema, same code path, one company
assert "one implicit org" "$(curl -s $B2/api/admin/status -H "Authorization: Bearer $OP2")" '"orgs":1'

echo
if [ $fail -eq 0 ]; then echo "multitenant-demo: PASS"; else echo "multitenant-demo: FAIL"; fi
exit $fail
