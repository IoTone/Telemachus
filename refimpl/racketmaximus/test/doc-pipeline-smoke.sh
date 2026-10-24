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
# A test run uses the SHIPPED plugin set. These are unset rather than merely
# unused: a developer working on a downstream plugin exports them in their own
# shell, and an inherited value would put someone else's plugin — and its load
# failure, since PLTCOLLECTS is reset just above — into this suite's assertions.
unset TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS
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
 "You classify a document": "{\"label\":\"report\",\"confidence\":0.42,\"rationale\":\"mock\"}",
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
# in milliseconds. Poll for up to 10 minutes live, 1 minute scripted. Do NOT
# lengthen the scripted budget to get a stalled run to finish: a queue that
# stops with nothing running is a BUDGET, not a slow engine, and a longer wait
# only hides it (see the ai.requests note in section 0).
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
# …and so does the default 200 REQUESTS/day, which this suite had been one slice
# away from for a long time and finally crossed: the knowledge-graph fan-out
# extracts over every indexed document, so each new fixture costs several more
# model calls, and at ~200 the queue stops with eleven children `queued` and
# nothing `running`. That reads exactly like a hung engine. Both raises are
# ASSERTED, for `run-tour.mjs`'s reason: a silent refusal must not be able to
# come back as a timeout somebody lengthens a poll budget to hide.
P /api/quota '{"dimension":"ai.requests","limit":1000000,"window":"day"}' >/dev/null
qlimit(){ G /api/usage | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next((q["limit"] for q in d["quota"] if q["dimension"]==sys.argv[1]),"-"))' "$1"; }
assert "the token budget was raised"   "$(qlimit ai.tokens.total)" "1000000"
assert "the request budget was raised" "$(qlimit ai.requests)"     "1000000"
assert "workflow arrived from the plugin" "$(G /api/workflows)" '"slug":"process-upload"'
assert "the four tools are registered"   "$(G /api/tools)" '"name":"doc_extract_fields"'
# The tool registries (index-tools, doc-tools, kg-tools) register on load and
# export nothing, so an import-pruning pass drops them without a compile error.
# The assertion above covers doc-tools and the one at the end of the file covers
# kg-tools; `repo_extract_text` had neither, so it gets one here.
assert "...and so is the indexer's"       "$(G /api/tools)" '"name":"repo_extract_text"'

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
RUNJSON_FORM="$RUNJSON"
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
# artifact-shaped results (slice 64): the run's form step names the document it made
assert "the form step's result is an artifact" "$RUNJSON_FORM" '"artifact":{'
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
echo "== 3b. PDF output (DWF-6): a workflow that binds format \"pdf\" ================"
# doc_render's `format` is a tool argument, not a pipeline input: a plugin (or
# this spec) binds it as a literal. Skipped where pandoc/tectonic are not on the
# server's PATH — the named refusal is asserted instead.
PDFWF='{"spec":1,"slug":"pdf-form","input":{"object_id":"string","template":"string"},"steps":[
  {"id":"form","uses":"tool:doc_render","with":{"template":"${input.template}","object":"${input.object_id}","format":"pdf",
   "data":{"vendor":"Acme Corp","total":1250.5,"buyer":{"name":"Globex"},"items":[{"description":"Widgets","amount":1000}]}}}]}'
assert "pdf workflow published" "$(P /api/workflows "$PDFWF")" '"slug":"pdf-form"'
RUNP=$(P /api/workflows/pdf-form/run "{\"input\":{\"object_id\":\"$INVID\",\"template\":\"templates/approval.md\"}}")
RIDP=$(printf '%s' "$RUNP" | grep -oP '"id":"\K[^"]+' | head -1)
STP=''; for i in $(seq 1 120); do STP=$(G /api/runs/$RIDP); printf '%s' "$STP" | grep -qE '"status":"(done|failed|error)"' && break; sleep 0.5; done
if command -v pandoc >/dev/null && command -v tectonic >/dev/null; then
  assert "pdf run finished" "$STP" '"status":"done"'
  LISTP=$(G "/api/repo?prefix=inbox/acme.txt.form.pdf")
  assert "the form is a .pdf beside the source" "$LISTP" '"key":"inbox/acme.txt.form.pdf"'
  assert "…with the PDF content type" "$LISTP" '"content_type":"application/pdf"'
  PDID=$(printf '%s' "$LISTP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["objects"][0]["id"])')
  curl -s "$B/api/repo-obj/$PDID/content" -H "Authorization: Bearer $TOK" -o "$TELEMACHUS_DATA_DIR/form.pdf"
  assert "it is a PDF" "$(head -c 4 "$TELEMACHUS_DATA_DIR/form.pdf")" '%PDF'
  if command -v pdftotext >/dev/null; then
    assert "the PDF's text is the filled form" "$(pdftotext "$TELEMACHUS_DATA_DIR/form.pdf" -)" 'Vendor: Acme Corp'
  fi
else
  assert "pdf refused by name without the toolchain" "$STP" 'needs pandoc and tectonic'
fi
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
echo "== 5b. classification: a mixed inbox routed by TYPE (#87, CLS-1…12) ==========="
# The DWF-5 section above leaves a deliberately NON-conforming extraction reply
# behind, so this section restores the scripted answers it needs — the same thing
# section 6 does, and for the same reason.
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "You classify a document": "{\"label\":\"report\",\"confidence\":0.42,\"rationale\":\"mock\"}",
 "*": "MOCK"}
JSON
fi
# A letter, an invoice, a photograph and a report under ONE prefix — the case
# `process-upload` could not serve, because one schema cannot read all four and
# nothing told it which it was reading.
printf 'INVOICE 4471\nAcme Corp\nTotal due 1250.50\n' > "$TELEMACHUS_DATA_DIR/m-inv.txt"
printf 'Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme\n' > "$TELEMACHUS_DATA_DIR/m-let.txt"
printf 'not really a jpeg' > "$TELEMACHUS_DATA_DIR/m-pho.jpg"
printf 'Quarterly summary of levee inspections for the north reach.\n' > "$TELEMACHUS_DATA_DIR/m-rep.txt"
up(){ curl -s -X PUT "$B/api/repo/$1" -H "Authorization: Bearer $TOK" -H "Content-Type: $2" --data-binary @"$3"; }
MINV=$(up mixed/a.txt text/plain "$TELEMACHUS_DATA_DIR/m-inv.txt" | jq_ 'd["id"]')
MLET=$(up mixed/b.txt text/plain "$TELEMACHUS_DATA_DIR/m-let.txt" | jq_ 'd["id"]')
MPHO=$(up mixed/c.jpg image/jpeg "$TELEMACHUS_DATA_DIR/m-pho.jpg" | jq_ 'd["id"]')
MREP=$(up mixed/d.txt text/plain "$TELEMACHUS_DATA_DIR/m-rep.txt" | jq_ 'd["id"]')
assert "the workflow arrived from the plugin" "$(G /api/workflows)" '"slug":"classify-and-extract"'
assert "doc_classify is registered"           "$(G /api/tools)" '"name":"doc_classify"'

LABELS='[{"name":"invoice","description":"a bill for goods or services"},{"name":"letter","description":"correspondence addressed to a person"},{"name":"photo","description":"a photograph of a site or an asset"},{"name":"report","description":"a periodic summary"}]'
# phrases, never regular expressions (CLS-2); a content type matches by prefix
# when it ends in `/`, which is what classifies the photograph without reading it
CRULES='[{"label":"photo","content_type":"image/"},{"label":"invoice","all":["Invoice"],"any":["Total due","Amount due"],"none":["DRAFT"]},{"label":"letter","any":["Dear"]}]'
# the letter's schema is deliberately open: the scripted model answers every
# extraction with the invoice object, and what this section is about is the ROUTING
CSCHEMAS='{"invoice":'"$SCHEMA"',"letter":{"type":"object","additionalProperties":true}}'

classify_run(){ # <object id> -> RUNST / RUNJSON
  local r; r=$(P /api/workflows/classify-and-extract/run \
    "{\"input\":{\"object_id\":\"$1\",\"labels\":$LABELS,\"rules\":$2,\"schemas\":$CSCHEMAS}}")
  wait_run "$(printf '%s' "$r" | grep -oP '"id":"\K[^"]+' | head -1)"
}
ran(){ [ "$RUNST" = done ] && echo done || echo "$RUNST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"; }

classify_run "$MINV" "$CRULES"
assert "the invoice run finished"            "$(ran)" done
assert "…routed to the invoice schema"       "$RUNJSON" '"step_id":"invoice_fields"'
refute "…and not to the letter's"            "$RUNJSON" '"step_id":"letter_fields"'

classify_run "$MLET" "$CRULES"
assert "the letter run finished"             "$(ran)" done
assert "…routed to the letter schema"        "$RUNJSON" '"step_id":"letter_fields"'

# CLS-9: `doc_text` RAISES for an image, which is why the classification comes
# FIRST — a content-type rule answers without reading a byte, and the run then
# ends with the type recorded and nothing extracted, because a photograph has no
# fields. A pipeline that read the text first could not reach this document at all.
classify_run "$MPHO" "$CRULES"
assert "the photograph run finished"         "$(ran)" done
refute "…nothing was extracted from it"      "$RUNJSON" '"step_id":"invoice_fields"'

# no rule describes the report, so the MODEL answers — and its confidence is its
# own, not a number this platform invented for it (CLS-3's converse)
classify_run "$MREP" "$CRULES"
assert "the report run finished"             "$(ran)" done

MLIST=$(G "/api/repo?prefix=mixed/&limit=50")
mid_of(){ printf '%s' "$MLIST" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(o["id"] for o in d["objects"] if o["key"]==sys.argv[1]))' "$1"; }
attr_of(){ printf '%s' "$MLIST" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(o["attributes"].get(sys.argv[2],"") for o in d["objects"] if o["key"]==sys.argv[1]))' "$1" "$2"; }
# CLS-7: the keys are doc_type*, with underscores — a dot is not a legal LAY-4
# attribute key, and loosening that vocabulary for three keys would change what a
# key is for the funnel and every ?attr= filter too
assert "the invoice's type is on the document" "$(attr_of mixed/a.txt doc_type)" invoice
assert "the letter's too"                      "$(attr_of mixed/b.txt doc_type)" letter
assert "and the photograph's"                  "$(attr_of mixed/c.jpg doc_type)" photo
assert "a rule match is confidence 1.00"       "$(attr_of mixed/a.txt doc_type_confidence)" "1.00"
assert "…and says which backend decided"       "$(attr_of mixed/a.txt doc_type_source)" rules
if [ $LIVE = 0 ]; then
  assert "the model's own label for the report" "$(attr_of mixed/d.txt doc_type)" report
  assert "…attributed to the model"             "$(attr_of mixed/d.txt doc_type_source)" llm
  # CLS-8: two decimals, fixed, because ?attr= is an equality filter
  assert "…with the model's confidence, to 2dp" "$(attr_of mixed/d.txt doc_type_confidence)" "0.42"
fi
# LAY-4's own filter now answers "every invoice in this prefix", which is the
# whole reason the answer is written there and not only into a record
assert "?attr= finds the invoice by type" "$(G "/api/repo?prefix=mixed/&attr=doc_type:invoice")" '"key":"mixed/a.txt"'
refute "…and only the invoice"            "$(G "/api/repo?prefix=mixed/&attr=doc_type:invoice")" '"key":"mixed/b.txt"'

# CLS-11: the record beside the source carries what three attributes cannot — the
# label set, the backend order, the version it read and how much of the text
assert "a classification record is beside the source" "$MLIST" '"key":"mixed/a.txt.classification.json"'
CREC=$(G "/api/repo-obj/$(mid_of mixed/a.txt.classification.json)/content")
assert "it names the label set"   "$CREC" '"labels":["invoice","letter","photo","report"]'
assert "it names the version"     "$CREC" '"version_id"'
assert "it says the text was not cut" "$CREC" '"truncated":false'

# a misconfigured rule is the operator's own mistake and is named, not ignored
classify_run "$MINV" '[{"label":"receipt","any":["x"]}]'
assert "a rule naming an unknown label fails the run" "$(ran)" "'receipt' is not one of the labels"
classify_run "$MINV" '[{"label":"invoice"}]'
assert "…and so does a rule with no condition"        "$(ran)" "no condition"

echo
echo "== 5c. a person in the pipeline: the review hook (#87 slice 2, req 4) =========="
# The issue's SECOND acceptance criterion: "Low-confidence items appear in the
# review queue and resume after a decision." Everything here is over HTTP,
# because the half that only HTTP can show is that the queue a person reads and
# the run that is parked on it are the same thing.
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "You classify a document": "{\"label\":\"invoice\",\"confidence\":0.42,\"rationale\":\"mock is unsure\"}",
 "*": "MOCK"}
JSON
fi
# a `waiting` run is a TERMINAL state for this section's purposes, and wait_run
# polls for the full timeout without it — it only breaks on done/error/canceled
wait_park(){ RUNST=""; RUNJSON=""; for i in $(seq 1 $WAIT_TRIES); do
    RUNJSON=$(G "/api/runs/$1")
    # the TOP-LEVEL status, read as JSON: every step carries one of its own, and a
    # grep for the first match is right only by key order (the trap ocr-smoke paid)
    RUNST=$(printf '%s' "$RUNJSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
    case "$RUNST" in done|error|canceled|waiting) break;; esac; sleep 0.5
  done; }
review_run(){ # <object id> <min_confidence> -> RUNID, and parks or finishes
  local r; r=$(P /api/workflows/classify-review-extract/run \
    "{\"input\":{\"object_id\":\"$1\",\"labels\":$LABELS,\"rules\":[],\"schemas\":$CSCHEMAS,\"min_confidence\":$2}}")
  RUNID=$(printf '%s' "$r" | jq_ 'd["id"]'); wait_park "$RUNID"; }
pending_id(){ G /api/reviews | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["reviews"][0]["id"] if d["reviews"] else "")'; }
decide(){ P "/api/reviews/$1/decide" "$2" >/dev/null; wait_park "$RUNID"; }
rattr(){ G "/api/repo-obj/$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attributes",{}).get(sys.argv[1],""))' "$2"; }

assert "the review workflow arrived from the plugin" "$(G /api/workflows)" '"slug":"classify-review-extract"'
assert "doc_set_type is registered"                  "$(G /api/tools)" '"name":"doc_set_type"'

printf 'Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme\n' > "$TELEMACHUS_DATA_DIR/r-let.txt"
printf 'Minutes of the site meeting, 14 October.\n' > "$TELEMACHUS_DATA_DIR/r-min.txt"
RLET=$(up rev/b.txt text/plain "$TELEMACHUS_DATA_DIR/r-let.txt" | jq_ 'd["id"]')
RMIN=$(up rev/c.txt text/plain "$TELEMACHUS_DATA_DIR/r-min.txt" | jq_ 'd["id"]')

# --- the gate (CLS-13). The threshold is a `choice` on the confidence, not a flag
# on the tool: only a STEP can park a run (LAY-1), and `lt` with a `number` input
# already spells "below a configurable confidence".
review_run "$RLET" 0.1
assert "a confident-enough run is never parked"  "$RUNST" done
refute "…and asks nobody"                        "$RUNJSON" '"step_id":"confirm"'
assert "…the backend is still named as deciding" "$(rattr "$RLET" doc_type_source)" llm
assert "the review queue is empty"               "$(G /api/reviews)" '"reviews":[]'

# --- REVISE: the model is unsure AND wrong, which is the case the hook is for
review_run "$RLET" 0.6
assert "a low-confidence run PARKS"             "$RUNST" waiting
assert "…on the review step"                    "$RUNJSON" '"step_id":"confirm"'
assert "…and it is in the queue a person reads" "$(G /api/reviews)" '"step_id":"confirm"'
assert "…titled as a question about the document" "$(G /api/reviews)" "kind of document"
# the subject is the classifier's own answer, so the reviewer sees the guess and
# its confidence rather than being asked to start from the document
assert "…showing the guess that was not trusted" "$(G /api/reviews)" '"confidence":0.42'
# LAY-3: the subject is model-produced, so it has no author and anybody holding
# reviews:decide may decide it — four eyes here would be undecidable on a team of one
assert "…and needs no second pair of eyes"       "$(G /api/reviews)" '"four_eyes":false'
assert "the guess is on the document meanwhile"  "$(rattr "$RLET" doc_type)" invoice

REV=$(pending_id)
decide "$REV" '{"verdict":"revise","rationale":"a tenancy letter, not a bill","answers":{"doc_type":"letter"}}'
assert "the run RESUMED and finished"           "$RUNST" done
assert "…through the correcting step"           "$RUNJSON" '"step_id":"correct"'
# the assertion the second routing chain exists for: reading the label from the
# CLASSIFIER would have extracted a letter against the invoice schema
assert "…and extracted against the LETTER schema" "$RUNJSON" '"step_id":"letter_fields"'
refute "…not the invoice's"                       "$RUNJSON" '"step_id":"invoice_fields"'
assert "the metadata followed the decision"     "$(rattr "$RLET" doc_type)" letter
assert "…attributed to the review"              "$(rattr "$RLET" doc_type_source)" review
assert "…at confidence 1.00"                    "$(rattr "$RLET" doc_type_confidence)" "1.00"
assert "?attr= finds it under the corrected type" "$(G "/api/repo?prefix=rev/&attr=doc_type:letter")" '"key":"rev/b.txt"'
refute "…and not under the model's guess"         "$(G "/api/repo?prefix=rev/&attr=doc_type:invoice")" '"key":"rev/b.txt"'
assert "the queue is empty again"               "$(G /api/reviews)" '"reviews":[]'
# the document's own record names the decision, which is what ties an assertion
# about a document to the reviews chain (LAY-11) without a second mechanism
RRECID=$(G "/api/repo?prefix=rev/b.txt.classification.json" | jq_ 'd["objects"][0]["id"]')
RREC=$(G "/api/repo-obj/$RRECID/content")
assert "…and the record says which review decided it" "$RREC" "\"review_id\":\"$REV\""
assert "…with the verdict"                            "$RREC" '"verdict":"revise"'

# --- REJECT: the type is WITHDRAWN. CLS-6 settled that there is no doc_type of
# "unknown", so the only honest record of "none of these kinds" is the absence of
# an assertion — and leaving the model's wrong guess standing is what a hook that
# merely closed the review would have done.
review_run "$RMIN" 0.6
assert "the minutes park too"                   "$RUNST" waiting
assert "…with the model's guess recorded"       "$(rattr "$RMIN" doc_type)" invoice
decide "$(pending_id)" '{"verdict":"reject","rationale":"it is none of these kinds"}'
assert "the rejected run finished"              "$RUNST" done
assert "…through the withdrawing step"          "$RUNJSON" '"step_id":"withdraw"'
# asserted as the ABSENCE of the key rather than as an empty value: `assert` is a
# grep, and a grep for the empty string over a one-line body matches nothing — so
# "equals empty" FAILS against a correct server. One refute covers all three keys,
# since every one of them contains `doc_type`.
refute "the wrong type is GONE, not left wrong" "$(G "/api/repo-obj/$RMIN")" '"doc_type"'
assert "…on a document that is still there"     "$(G "/api/repo-obj/$RMIN")" '"key":"rev/c.txt"'
refute "?attr= no longer finds it"              "$(G "/api/repo?prefix=rev/&attr=doc_type:invoice")" '"key":"rev/c.txt"'
refute "…and nothing was extracted from it"     "$RUNJSON" '"step_id":"letter_fields"'

# --- a reviewer's TYPO. Checklist answers are free strings (LAY-1), so the only
# place a mis-spelled type can be caught is the tool that records it — and it must
# refuse rather than store a type no trigger will ever match.
review_run "$RMIN" 0.6
decide "$(pending_id)" '{"verdict":"revise","rationale":"a letter","answers":{"doc_type":"Letter"}}'
assert "a type outside the set fails the run"   "$RUNST" error
assert "…naming what was wrong"                 "$RUNJSON" "not one of the types"
assert "…and what should have been said"        "$RUNJSON" "invoice, letter, photo, report"
assert "the decision itself stands"             "$(G '/api/reviews?status=decided')" '"status":"decided"'

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
echo "== 6b. a trigger on the TYPE, not the prefix (#87 req 3b, CLS-19…23) ==========="
# Requirement 3's two halves: record the type (slices 1 and 2) and let a trigger
# act on it. They are separated by a tool call, because at `repo-put!` the
# document has only just arrived and nothing has classified it — which is why a
# trigger that names attributes also wakes when a document's metadata CHANGES.
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "professional translator": "VERTAALD",
 "*": "MOCK"}
JSON
fi
nfires(){ G "/api/doc-triggers/$1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["fires"]))'; }

assert "a condition that could never match is refused" \
  "$(P /api/doc-triggers '{"workflow_slug":"process-upload","match_attrs":{"doc_type":3}}')" 'must be a string'
# CLS-7's reason, from the other side: `doc.type` is not a legal LAY-4 key, so a
# trigger naming it would simply never fire — refused instead
assert "…and so is an illegal attribute key" \
  "$(P /api/doc-triggers '{"workflow_slug":"process-upload","match_attrs":{"doc.type":"invoice"}}')" 'not a valid attribute key'

TTRG=$(P /api/doc-triggers "{\"workflow_slug\":\"process-upload\",\"match_attrs\":{\"doc_type\":\"invoice\"},\"input\":{\"schema\":$SCHEMA,\"template\":\"\",\"locales\":[]}}")
TTID=$(printf '%s' "$TTRG" | jq_ 'd["id"]')
assert "a trigger on the document TYPE is created" "$TTRG" '"match_attrs":{"doc_type":"invoice"}'

printf 'INVOICE 9002\nAcme Corp\nTotal due 42.00\n' > "$TELEMACHUS_DATA_DIR/t-inv.txt"
printf 'Dear Ms Smith,\n\nRegards,\nAcme\n' > "$TELEMACHUS_DATA_DIR/t-let.txt"
TINV=$(up typed/a.txt text/plain "$TELEMACHUS_DATA_DIR/t-inv.txt" | jq_ 'd["id"]')
TLET=$(up typed/b.txt text/plain "$TELEMACHUS_DATA_DIR/t-let.txt" | jq_ 'd["id"]')
# the arrival itself can match nothing: the documents have no type yet
assert "the uploads fired nothing" "$(nfires "$TTID")" "0"

# classify both with RULES — deterministic, and no model call at all
classify_run "$TINV" "$CRULES"
assert "the invoice classified"  "$(ran)" done
classify_run "$TLET" "$CRULES"
assert "the letter classified"   "$(ran)" done

assert "recording the type fired the trigger"  "$(nfires "$TTID")" "1"
TFIRES=$(G "/api/doc-triggers/$TTID")
assert "…on the INVOICE"                       "$TFIRES" '"key":"typed/a.txt"'
refute "…and not on the letter"                "$TFIRES" '"key":"typed/b.txt"'
TRRID=$(printf '%s' "$TFIRES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["fires"][0]["run_id"])')
wait_run "$TRRID"
assert "the run it started finished"           "$RUNST" done
assert "…and extracted the invoice's fields"   "$(G "/api/repo?prefix=typed/a.txt")" '"key":"typed/a.txt.extracted.json"'

# CLS-21: exactly-once per (trigger, version) is what BOUNDS the loop the second
# seam introduces — re-recording the same type cannot start a second run, and the
# pipeline the trigger ran wrote attributes of its own.
classify_run "$TINV" "$CRULES"
assert "re-classifying does not re-fire"       "$(nfires "$TTID")" "1"
# a NEW VERSION legitimately fires again, exactly as DWF-3 already said for uploads
up typed/a.txt text/plain "$TELEMACHUS_DATA_DIR/t-inv.txt" >/dev/null
classify_run "$TINV" "$CRULES"
assert "a new version of the document does"    "$(nfires "$TTID")" "2"

# CLS-23: the compatibility guarantee. The prefix trigger from section 6 matches
# `inbox/auto/`, and every document there has had attributes written to it by the
# pipeline — it must not have woken up for any of that.
assert "the prefix trigger is untouched by the new seam" "$(nfires "$TID")" "1"
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

if [ $LIVE = 0 ]; then
  echo
  echo "== 8. the knowledge graph: index, extract, ask — with the mention rule (KG-3) ====="
  # every invoice (the private one and the team-visible auto/ scans share the
  # line "Widgets 1000\nShipping 250.50") gets entities with snippets verbatim from
  # its text; every other document gets an empty, valid extraction. The longest
  # needle wins in the mock, so the specific one beats the generic one.
  cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract a knowledge graph": "{\"entities\":[],\"relations\":[]}",
 "Widgets 1000\\nShipping 250.50": "{\"entities\":[{\"type\":\"organization\",\"name\":\"Acme Corp\",\"description\":\"a vendor\",\"snippet\":\"Acme Corp\"},{\"type\":\"product\",\"name\":\"Widgets\",\"snippet\":\"Widgets 1000\"}],\"relations\":[{\"subject\":\"Acme Corp\",\"predicate\":\"sells\",\"object\":\"Widgets\",\"snippet\":\"Widgets 1000\"}]}",
 "*": "MOCK"}
JSON
  IDX=$(P /api/workflows/index-documents/run '{}'); IDXID=$(printf '%s' "$IDX" | grep -oP '"id":"\K[^"]+' | head -1)
  wait_run "$IDXID"; assert "index-documents ran" "$RUNST" "done"
  KG=$(P /api/kg/extract); KGID=$(printf '%s' "$KG" | grep -oP '"id":"\K[^"]+' | head -1)
  assert "extract queued" "$KG" '"status":"running"'
  wait_run "$KGID"; KGST="$RUNST"; [ "$KGST" = done ] || KGST="$KGST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"
  assert "index-knowledge ran" "$KGST" "done"
  ENTS=$(G "/api/kg/entities?q=acme")
  assert "Acme Corp is an entity"       "$ENTS" '"name":"Acme Corp"'
  assert "…one entity across three invoices" "$(printf '%s' "$ENTS" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["entities"]))')" "1"
  EID=$(printf '%s' "$ENTS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["entities"][0]["id"])')
  ENT=$(G "/api/kg/entities/$EID")
  assert "its relation, with a citation"  "$ENT" '"predicate":"sells"'
  assert "a mention names the invoice"    "$ENT" '"key":"inbox/acme.txt"'
  assert "search surfaces the entity"     "$(G "/api/search?q=acme")" '"type":"entity"'
  # the mention rule: bob (view on inbox/acme.txt) sees Acme through the invoice he can read
  # and through the team-visible auto/ scans; carol sees it ONLY through the team-visible scans
  assert "bob sees Acme"   "$(curl -s "$B/api/kg/entities?q=acme" -H "Authorization: Bearer $BOB")" '"name":"Acme Corp"'
  CAROLENT=$(curl -s "$B/api/kg/entities/$EID" -H "Authorization: Bearer $CAROL")
  assert "carol sees Acme too (team scans mention it)" "$CAROLENT" '"name":"Acme Corp"'
  refute "…but never the private invoice's mention" "$CAROLENT" '"key":"inbox/acme.txt"'
  assert "the agent tool answers with citations" "$(G "/api/tools")" '"name":"kg_query"'
  assert "a second extraction finds nothing new" "$(P /api/kg/extract | grep -c running)" "1"
fi

echo
if [ $fail = 0 ]; then echo "doc-pipeline-smoke: PASS"; else echo "doc-pipeline-smoke: FAIL"; tail -30 "$TELEMACHUS_DATA_DIR/server.log"; exit 1; fi
