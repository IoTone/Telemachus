#!/usr/bin/env bash
# test/doc-pipeline-smoke.sh — the document pipeline, end to end over HTTP (slice 57).
#
#   bash test/doc-pipeline-smoke.sh                      # deterministic: scripted mock model
#   TELEMACHUS_MODEL_URL=… bash test/doc-pipeline-smoke.sh   # against a live model
#
# The first-user path: upload an invoice and a form template, run `process-upload`
# by hand (DWF-7 — the same run endpoint a trigger will use), and find four
# derived documents beside the invoice: extracted fields, the filled form, and the
# form in two languages — each with the invoice's visibility and grants, each with
# a provenance row naming the run. Then a NON-conforming extraction, which must fail
# the run and write nothing (DWF-5).
#
# Without TELEMACHUS_MODEL_URL this boots test/mock-llm.rkt in CHAT mode: the
# extraction prompt is answered with a conforming object, the translation prompt
# with a marker — so the assertions are exact. With a live model, the content
# assertions are relaxed to "exists and conforms".
set -u
cd "$(dirname "$0")/.."
export PLTCOLLECTS="$(pwd)/pkgs:"
export PORT="${PORT:-8841}"
MOCK_PORT="${MOCK_PORT:-8901}"

port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
if port_busy "$PORT"; then echo "port $PORT is in use — set PORT=<free port>" >&2; exit 1; fi

export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/telemachus.db}"
export TELEMACHUS_BIND=127.0.0.1
S3_PORT="${S3_PORT:-8842}"
export TELEMACHUS_S3_PORT="$S3_PORT"      # section 7 uploads through the S3 endpoint
LIVE=1; MOCK=""
if [ -z "${TELEMACHUS_MODEL_URL:-}" ]; then
  LIVE=0
  if port_busy "$MOCK_PORT"; then echo "port $MOCK_PORT is in use — set MOCK_PORT=<free port>" >&2; exit 1; fi
  export MOCK_REPLY_FILE="$TELEMACHUS_DATA_DIR/reply.json"
  cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "professional translator": "VERTAALD: Purchase approval for Acme Corp",
 "*": "MOCK"}
JSON
  MOCK_PORT="$MOCK_PORT" racket test/mock-llm.rkt >"$TELEMACHUS_DATA_DIR/mock.log" 2>&1 &
  MOCK=$!
  export TELEMACHUS_MODEL_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions"
  export TELEMACHUS_MODEL=mock
fi

fail=0
assert(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"
          else echo "  FAIL $1 — expected to contain: $3 — got: $2"; fail=1; fi; }
refute(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  FAIL $1 — must NOT contain: $3 — got: $2"; fail=1
          else echo "  ok   $1"; fi; }
jq_(){ python3 -c 'import sys,json;print(eval(sys.argv[1],{"d":json.load(sys.stdin)}))' "$1"; }

racket server/main.rkt >"$TELEMACHUS_DATA_DIR/server.log" 2>&1 &
SRV=$!
cleanup(){ kill $SRV 2>/dev/null; [ -n "$MOCK" ] && kill $MOCK 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR"; }
trap cleanup EXIT
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 40000 ] && { echo "server never came up"; cat "$TELEMACHUS_DATA_DIR/server.log"; exit 1; }
done; exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
P(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
# a 7B model takes ~50 s per extraction and ~30 s per translation; the mock answers
# in milliseconds. Poll for up to 10 minutes live, 1 minute scripted.
WAIT_TRIES=$([ $LIVE = 1 ] && echo 1200 || echo 120)
wait_run(){ # <run id> -> sets RUNST (final status) and RUNJSON; never in a $(…), or they are lost
  RUNST=""; RUNJSON=""; for i in $(seq 1 $WAIT_TRIES); do
    RUNJSON=$(G "/api/runs/$1"); RUNST=$(printf '%s' "$RUNJSON" | grep -oP '"status":"\K[^"]+' | head -1)
    case "$RUNST" in done|error|canceled) break;; esac; sleep 0.5
  done; }

echo "doc-pipeline smoke — model: ${TELEMACHUS_MODEL:-?} at $TELEMACHUS_MODEL_URL ($([ $LIVE = 1 ] && echo live || echo mock))"
echo
echo "== 0. bootstrap, a colleague, a budget ========================================"
TOK=$(curl -s -X POST $B/api/bootstrap -d '{"username":"alice","password":"demo-pass1"}' | jq_ 'd["token"]')
BOBJ=$(P /api/members '{"username":"bob","role":"member"}'); BOB=$(printf '%s' "$BOBJ" | jq_ 'd["token"]'); BOBID=$(printf '%s' "$BOBJ" | jq_ 'd["user_id"]')
CARJ=$(P /api/members '{"username":"carol","role":"member"}'); CAROL=$(printf '%s' "$CARJ" | jq_ 'd["token"]')
# the default 2,000 tokens/day would stall a pipeline in its queue (see CLAUDE.md)
P /api/quota '{"dimension":"ai.tokens.total","limit":1000000,"window":"day"}' >/dev/null
assert "workflow arrived from the plugin" "$(G /api/workflows)" '"slug":"process-upload"'
assert "the four tools are registered"   "$(G /api/tools)" '"name":"doc_extract_fields"'

echo
echo "== 1. a PRIVATE invoice shared with bob, and a form template ==================="
printf 'INVOICE\nAcme Corp\n2026-09-01\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n' > "$TELEMACHUS_DATA_DIR/inv.txt"
INV=$(curl -s -X PUT "$B/api/repo/inbox/acme.txt?visibility=private" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TELEMACHUS_DATA_DIR/inv.txt")
INVID=$(printf '%s' "$INV" | jq_ 'd["id"]')
assert "invoice is private" "$INV" '"visibility":"private"'
assert "shared with bob (view)" "$(P "/api/repo-obj/$INVID/share" "{\"user_id\":\"$BOBID\"}")" '"capability":"view"'
printf '# Purchase approval\n\nVendor: {{vendor}}\nTotal: {{total}}\n\n{{#each items}}- {{description}}: {{amount}}\n{{/each}}' > "$TELEMACHUS_DATA_DIR/tmpl.md"
assert "template uploaded" "$(curl -s -X PUT "$B/api/repo/templates/approval.md" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/markdown' --data-binary @"$TELEMACHUS_DATA_DIR/tmpl.md")" '"key":"templates/approval.md"'

echo
echo "== 2. run process-upload by hand: text -> fields -> form -> ja + nl ============="
SCHEMA='{"type":"object","required":["vendor","total","items"],"properties":{"vendor":{"type":"string"},"date":{"type":["string","null"]},"total":{"type":"number","minimum":0},"items":{"type":"array","minItems":1,"items":{"type":"object","required":["description","amount"],"properties":{"description":{"type":"string"},"amount":{"type":"number"}}}}}}'
RUN=$(P /api/workflows/process-upload/run "{\"input\":{\"object_id\":\"$INVID\",\"schema\":$SCHEMA,\"template\":\"templates/approval.md\",\"locales\":[\"ja\",\"nl\"]}}")
RID=$(printf '%s' "$RUN" | grep -oP '"id":"\K[^"]+' | head -1)
assert "run accepted" "$RUN" '"status":"running"'
wait_run "$RID"; ST="$RUNST"
[ "$ST" = done ] || ST="$ST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"
assert "run finished" "$ST" "done"
assert "the form step ran"        "$RUNJSON" '"step_id":"form"'
refute "the source branch did not" "$RUNJSON" '"step_id":"translate_source"'

echo
echo "== 3. four derived documents beside the invoice ================================"
LIST=$(G "/api/repo?prefix=inbox/")
for k in inbox/acme.txt.extracted.json inbox/acme.txt.form.md inbox/acme.txt.form.ja.md inbox/acme.txt.form.nl.md; do
  assert "exists: $k" "$LIST" "\"key\":\"$k\""
done
id_of(){ printf '%s' "$LIST" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(o["id"] for o in d["objects"] if o["key"]==sys.argv[1]))' "$1"; }
FID=$(id_of inbox/acme.txt.extracted.json); FORMID=$(id_of inbox/acme.txt.form.md); JAID=$(id_of inbox/acme.txt.form.ja.md)
FIELDS=$(G "/api/repo-obj/$FID/content")
assert "fields conform to the schema" "$FIELDS" '"vendor"'
FORM=$(G "/api/repo-obj/$FORMID/content")
assert "the form is filled" "$FORM" 'Vendor: '
refute "no placeholder survived" "$FORM" '{{'
if [ $LIVE = 0 ]; then
  assert "fields are the scripted object" "$FIELDS" '"total":1250.5'
  assert "form has the total" "$FORM" 'Total: 1250.5'
  assert "form lists the items" "$FORM" '- Shipping: 250.5'
  assert "the translation is of the FORM" "$(G "/api/repo-obj/$JAID/content")" 'VERTAALD'
fi
for id in $FID $FORMID $JAID; do
  OBJ=$(G "/api/repo-obj/$id")
  assert "private like the source ($id)" "$OBJ" '"visibility":"private"'
  assert "bob's inherited grant reads it" "$(curl -s "$B/api/repo-obj/$id" -H "Authorization: Bearer $BOB")" '"key":"inbox/'
  assert "carol has no grant" "$(curl -s "$B/api/repo-obj/$id" -H "Authorization: Bearer $CAROL")" 'Forbidden: files:read'
done
DER=$(G "/api/repo-obj/$JAID/derivations")
assert "provenance names the run"  "$DER" "\"run_id\":\"$RID\""
assert "…and the step"             "$DER" '"step_id":"translate"'
assert "…and the FORM as source"   "$DER" "\"source_object_id\":\"$FORMID\""
assert "the fields derive from the invoice" "$(G "/api/repo-obj/$FID/derivations")" "\"source_object_id\":\"$INVID\""
assert "the invoice derives from nothing"   "$(G "/api/repo-obj/$INVID/derivations")" '"derivations":[]'
assert "AI spend was metered" "$(G /api/usage)" '"dimension":"ai.tokens.total"'
# "Processed by" (DWF step 4): the invoice's derived documents and the run that made them
PROC=$(G "/api/repo-obj/$INVID/processing")
assert "processing lists the fields document" "$PROC" '"key":"inbox/acme.txt.extracted.json"'
assert "processing lists the form"            "$PROC" '"key":"inbox/acme.txt.form.md"'
assert "processing names the run"             "$PROC" "\"id\":\"$RID\""
assert "the form's panel says where it came from" "$(G "/api/repo-obj/$FORMID/processing")" '"derived_from":[{'
# "Shared with me" (DSH step 3): bob was handed the invoice; the outputs inherited it
assert "shared with me: the invoice"  "$(curl -s "$B/api/repo?shared=1" -H "Authorization: Bearer $BOB")" '"key":"inbox/acme.txt"'
assert "shared with me: its outputs"  "$(curl -s "$B/api/repo?shared=1" -H "Authorization: Bearer $BOB")" '"key":"inbox/acme.txt.form.md"'
# a DOCX template (DWF-6, step 5): the form comes back as a .docx
python3 - "$TELEMACHUS_DATA_DIR/approval.docx" <<'PY'
import sys, zipfile
xml = ('<w:document><w:body><w:p><w:r><w:t>Vendor: {{ven</w:t></w:r><w:r><w:t>dor}}</w:t></w:r></w:p>'
       '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{{#each items}}</w:t></w:r></w:p></w:tc></w:tr>'
       '<w:tr><w:tc><w:p><w:r><w:t>{{description}}</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{{amount}}</w:t></w:r></w:p></w:tc></w:tr>'
       '<w:tr><w:tc><w:p><w:r><w:t>{{/each}}</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('[Content_Types].xml', '<Types/>'); z.writestr('word/document.xml', xml)
PY
DOCX_CT='application/vnd.openxmlformats-officedocument.wordprocessingml.document'
assert "docx template uploaded" "$(curl -s -X PUT "$B/api/repo/templates/approval.docx" -H "Authorization: Bearer $TOK" -H "Content-Type: $DOCX_CT" --data-binary @"$TELEMACHUS_DATA_DIR/approval.docx")" '"key":"templates/approval.docx"'
RUND=$(P /api/workflows/process-upload/run "{\"input\":{\"object_id\":\"$INVID\",\"schema\":$SCHEMA,\"template\":\"templates/approval.docx\",\"locales\":[]}}")
RIDD=$(printf '%s' "$RUND" | grep -oP '"id":"\K[^"]+' | head -1)
wait_run "$RIDD"; STD="$RUNST"; [ "$STD" = done ] || STD="$STD — $(printf '%s' "$RUNJSON" | head -c 300)"
assert "docx run finished" "$STD" "done"
LISTD=$(G "/api/repo?prefix=inbox/acme.txt.form.docx")
assert "the form is a .docx beside the source" "$LISTD" '"key":"inbox/acme.txt.form.docx"'
assert "…with the DOCX content type" "$LISTD" "\"content_type\":\"$DOCX_CT\""
DID=$(printf '%s' "$LISTD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["objects"][0]["id"])')
curl -s "$B/api/repo-obj/$DID/content" -H "Authorization: Bearer $TOK" -o "$TELEMACHUS_DATA_DIR/form.docx"
assert "the .docx opens and is filled" "$(python3 -c 'import sys,zipfile;print(zipfile.ZipFile(sys.argv[1]).read("word/document.xml").decode())' "$TELEMACHUS_DATA_DIR/form.docx")" 'Vendor: Acme Corp'

echo
echo "== 4. no template: the SOURCE is translated; a re-run supersedes ==============="
RUN2=$(P /api/workflows/process-upload/run "{\"input\":{\"object_id\":\"$INVID\",\"schema\":$SCHEMA,\"template\":\"\",\"locales\":[\"nl\"]}}")
RID2=$(printf '%s' "$RUN2" | grep -oP '"id":"\K[^"]+' | head -1)
wait_run "$RID2"; ST2="$RUNST"; [ "$ST2" = done ] || ST2="$ST2 — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"
assert "second run finished" "$ST2" "done"
LIST2=$(G "/api/repo?prefix=inbox/")
assert "the source's translation, locale before the extension" "$LIST2" '"key":"inbox/acme.nl.txt"'
assert "the fields document was superseded, not duplicated" "$(G "/api/repo-obj/$FID")" '"version":2'

if [ $LIVE = 0 ]; then
  echo
  echo "== 5. a non-conforming extraction fails the run and writes nothing (DWF-5) ====="
  cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"total\":\"one thousand\",\"items\":[]}", "*": "MOCK"}
JSON
  printf 'a memo about nothing in particular' > "$TELEMACHUS_DATA_DIR/memo.txt"
  MEMO=$(curl -s -X PUT "$B/api/repo/inbox/memo.txt" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TELEMACHUS_DATA_DIR/memo.txt")
  MEMOID=$(printf '%s' "$MEMO" | jq_ 'd["id"]')
  RUN3=$(P /api/workflows/process-upload/run "{\"input\":{\"object_id\":\"$MEMOID\",\"schema\":$SCHEMA,\"template\":\"templates/approval.md\",\"locales\":[\"ja\"]}}")
  RID3=$(printf '%s' "$RUN3" | grep -oP '"id":"\K[^"]+' | head -1)
  wait_run "$RID3"
  assert "run failed"              "$RUNST" "error"
  assert "…because it was refused" "$RUNJSON" 'extraction refused'
  assert "…naming the mismatch"    "$RUNJSON" 'expected number, got string'
  assert "the fields step was retried once" "$(printf '%s' "$RUNJSON" | grep -o '"attempt":2' | head -1)" '"attempt":2'
  refute "nothing was written"     "$(G "/api/repo?prefix=inbox/memo")" 'extracted.json'
fi

echo
echo "== 6. a TRIGGER: an upload into inbox/auto/ runs the pipeline by itself (DWF-1…3) ==="
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "professional translator": "VERTAALD: Purchase approval for Acme Corp",
 "*": "MOCK"}
JSON
fi
assert "unpublished workflow refused" "$(P /api/doc-triggers '{"workflow_slug":"nope","match_prefix":"inbox/auto/"}')" 'not published'
TRG=$(P /api/doc-triggers "{\"workflow_slug\":\"process-upload\",\"match_prefix\":\"inbox/auto/\",\"match_types\":\"text/plain\",\"input\":{\"schema\":$SCHEMA,\"template\":\"templates/approval.md\",\"locales\":[\"ja\"]}}")
TID=$(printf '%s' "$TRG" | jq_ 'd["id"]')
assert "trigger created"  "$TRG" '"match_prefix":"inbox/auto/"'
assert "trigger listed with the team budget" "$(G /api/doc-triggers)" '"budget":{'
assert "a member cannot create one" "$(curl -s -X POST $B/api/doc-triggers -H "Authorization: Bearer $BOB" -d '{"workflow_slug":"process-upload"}')" 'Forbidden: workflows:write'
# bob uploads: the run is bob's
printf 'INVOICE\nAcme Corp\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n' > "$TELEMACHUS_DATA_DIR/auto.txt"
AUTO=$(curl -s -X PUT "$B/api/repo/inbox/auto/scan-001.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TELEMACHUS_DATA_DIR/auto.txt")
AUTOID=$(printf '%s' "$AUTO" | jq_ 'd["id"]')
assert "upload returned at once" "$AUTO" '"key":"inbox/auto/scan-001.txt"'
FIRES=$(G "/api/doc-triggers/$TID")
assert "the trigger fired"  "$FIRES" '"key":"inbox/auto/scan-001.txt"'
ARID=$(printf '%s' "$FIRES" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(f["run_id"] for f in d["fires"] if f["key"]=="inbox/auto/scan-001.txt"))')
assert "…with a run" "$ARID" "-"
wait_run "$ARID"; AST="$RUNST"; [ "$AST" = done ] || AST="$AST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"
assert "the triggered run finished" "$AST" "done"
assert "the run is the uploader's"  "$RUNJSON" "\"user_id\":\"$BOBID\""
ALIST=$(G "/api/repo?prefix=inbox/auto/")
for k in inbox/auto/scan-001.txt.extracted.json inbox/auto/scan-001.txt.form.md inbox/auto/scan-001.txt.form.ja.md; do
  assert "exists: $k" "$ALIST" "\"key\":\"$k\""
done
# DWF-3: the three outputs match the prefix; none of them re-fired the trigger
assert "one fire, not four" "$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["fires"]))')" "1"
# an upload outside the prefix, and a non-matching type inside it, stay quiet
curl -s -X PUT "$B/api/repo/inbox/manual/x.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TELEMACHUS_DATA_DIR/auto.txt" >/dev/null
curl -s -X PUT "$B/api/repo/inbox/auto/pic.png" -H "Authorization: Bearer $BOB" -H 'Content-Type: image/png' --data-binary @"$TELEMACHUS_DATA_DIR/auto.txt" >/dev/null
assert "still one fire" "$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["fires"]))')" "1"
# disable, upload, nothing; enable again
assert "disabled" "$(curl -s -X PATCH "$B/api/doc-triggers/$TID" -H "Authorization: Bearer $TOK" -d '{"enabled":false}')" '"enabled":false'
curl -s -X PUT "$B/api/repo/inbox/auto/scan-002.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TELEMACHUS_DATA_DIR/auto.txt" >/dev/null
assert "a disabled trigger is silent" "$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["fires"]))')" "1"
curl -s -X PATCH "$B/api/doc-triggers/$TID" -H "Authorization: Bearer $TOK" -d '{"enabled":true}' >/dev/null

echo
echo "== 7. the path a team will actually use: an S3 PUT fires it ===================="
if command -v aws >/dev/null 2>&1; then
  # a key with the DEFAULT scopes cannot start a workflow — the fire records why
  CRED=$(P /api/s3/credentials '{"name":"files-only"}')
  export AWS_ACCESS_KEY_ID=$(printf '%s' "$CRED" | jq_ 'd["access_key_id"]')
  export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CRED" | jq_ 'd["secret_access_key"]')
  export AWS_DEFAULT_REGION=us-east-1 AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  E="http://127.0.0.1:$S3_PORT"
  BUCKET=default        # the bucket is the team slug; bootstrap names the first team "default"
  aws --endpoint-url "$E" s3 cp "$TELEMACHUS_DATA_DIR/auto.txt" "s3://$BUCKET/inbox/auto/scan-s3-a.txt" --content-type text/plain >/dev/null 2>&1
  F1=$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(((f["error"] or "") for f in d["fires"] if f["key"]=="inbox/auto/scan-s3-a.txt"),""))')
  assert "S3 PUT with a files-only key: recorded, not run" "$F1" 'workflows:run'
  # a key issued with workflows:run fires the run
  CRED2=$(P /api/s3/credentials '{"name":"pipeline","scopes":["files:read","files:write","files:delete","workflows:read","workflows:run"]}')
  export AWS_ACCESS_KEY_ID=$(printf '%s' "$CRED2" | jq_ 'd["access_key_id"]')
  export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CRED2" | jq_ 'd["secret_access_key"]')
  aws --endpoint-url "$E" s3 cp "$TELEMACHUS_DATA_DIR/auto.txt" "s3://$BUCKET/inbox/auto/scan-s3-b.txt" --content-type text/plain >/dev/null 2>&1
  SRID=$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(((f["run_id"] or "") for f in d["fires"] if f["key"]=="inbox/auto/scan-s3-b.txt"),""))')
  assert "S3 PUT with workflows:run started a run" "$SRID" "-"
  wait_run "$SRID"; SST="$RUNST"; [ "$SST" = done ] || SST="$SST — $(printf '%s' "$RUNJSON" | head -c 300)"
  assert "…which finished" "$SST" "done"
  assert "the S3 upload's outputs sit beside it in the bucket" "$(aws --endpoint-url "$E" s3 ls "s3://$BUCKET/inbox/auto/" 2>/dev/null)" 'scan-s3-b.txt.form.ja.md'
else
  echo "  skip S3 section (no aws CLI)"
fi

echo
if [ $fail = 0 ]; then echo "doc-pipeline-smoke: PASS"; else echo "doc-pipeline-smoke: FAIL"; tail -30 "$TELEMACHUS_DATA_DIR/server.log"; exit 1; fi
