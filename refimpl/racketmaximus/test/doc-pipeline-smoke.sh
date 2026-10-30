#!/usr/bin/env bash
# test/doc-pipeline-smoke.sh — the document pipeline, end to end over HTTP (slice 57).
#
#   bash test/doc-pipeline-smoke.sh                      # deterministic: scripted mock model
#   TMACH_MODEL_URL=… bash test/doc-pipeline-smoke.sh   # against a live model
#
# The first-user path: upload an invoice and a form template, run `process-upload`
# by hand (DWF-7 — the same run endpoint a trigger will use), and find four
# derived documents beside the invoice: extracted fields, the filled form, and the
# form in two languages — each with the invoice's visibility and grants, each with
# a provenance row naming the run. Then a NON-conforming extraction, which must fail
# the run and write nothing (DWF-5).
#
# Without TMACH_MODEL_URL this boots test/mock-llm.rkt in CHAT mode: the
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
unset TMACH_PLUGINS TMACH_PLUGINS_LINKS TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS
export PORT="${PORT:-8841}"
MOCK_PORT="${MOCK_PORT:-8901}"

port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
if port_busy "$PORT"; then echo "port $PORT is in use — set PORT=<free port>" >&2; exit 1; fi

export TMACH_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TMACH_DATA_DIR/telemachus.db}"
export TMACH_BIND=127.0.0.1
S3_PORT="${S3_PORT:-8842}"
export TMACH_S3_PORT="$S3_PORT"      # section 7 uploads through the S3 endpoint
LIVE=1; MOCK=""
if [ -z "${TMACH_MODEL_URL:-}" ]; then
  LIVE=0
  if port_busy "$MOCK_PORT"; then echo "port $MOCK_PORT is in use — set MOCK_PORT=<free port>" >&2; exit 1; fi
  export MOCK_REPLY_FILE="$TMACH_DATA_DIR/reply.json"
  cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"vendor\":\"Acme Corp\",\"date\":\"2026-09-01\",\"total\":1250.5,\"items\":[{\"description\":\"Widgets\",\"amount\":1000},{\"description\":\"Shipping\",\"amount\":250.5}]}",
 "You classify a document": "{\"label\":\"report\",\"confidence\":0.42,\"rationale\":\"mock\"}",
 "professional translator": "VERTAALD: Purchase approval for Acme Corp",
 "*": "MOCK"}
JSON
  MOCK_PORT="$MOCK_PORT" racket test/mock-llm.rkt >"$TMACH_DATA_DIR/mock.log" 2>&1 &
  MOCK=$!
  export TMACH_MODEL_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions"
  export TMACH_MODEL=mock
  # #189 step 6: the SAME mock serves /v1/embeddings (a request carrying `input`
  # and no `messages`), answering a deterministic bag-of-words vector. That is
  # what lets section 5m drive the whole retrieval chain through the REAL
  # `embed-exchange` wire rather than a scripted seam — which is the gap #187
  # found on the streaming path, where nothing exercised it end to end anywhere
  # and the one defect that existed only there survived for a year.
  export TMACH_EMBED_URL="http://127.0.0.1:$MOCK_PORT/v1/embeddings"
  export TMACH_EMBED_MODEL=mock-embed
  # #192: and the same mock serves /v1/audio/transcriptions — detected on the
  # CONTENT TYPE (multipart/form-data), because the mock discards the request
  # line. The "transcript" is the file part decoded as text, so a fixture can put
  # a known sentence in the "audio" and section 9 can assert which recording came
  # back. Same reason as the embeddings branch: without it the multipart body and
  # the response reader are exercised by unit tests only, which is the gap #187
  # found on the streaming path.
  export TMACH_TRANSCRIBE_URL="http://127.0.0.1:$MOCK_PORT/v1/audio/transcriptions"
  export TMACH_TRANSCRIBE_MODEL=mock-whisper
fi

fail=0
assert(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1"
          else echo "  FAIL $1 — expected to contain: $3 — got: $2"; fail=1; fi; }
refute(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  FAIL $1 — must NOT contain: $3 — got: $2"; fail=1
          else echo "  ok   $1"; fi; }
# "these two must not be equal", which `refute` cannot express: it is a grep, so
# refuting "22" against "0" passes for the wrong reason the moment one is a prefix
# of the other. Copied from server-smoke.sh, where it already existed — and a
# helper used before it was defined is a line bash reports on stderr while the
# suite goes on reporting PASS, which is the third time that shape has cost a run.
differ(){ if [ "$2" != "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 — both were: $2"; fail=1; fi; }
jq_(){ python3 -c 'import sys,json;print(eval(sys.argv[1],{"d":json.load(sys.stdin)}))' "$1"; }

racket server/main.rkt >"$TMACH_DATA_DIR/server.log" 2>&1 &
SRV=$!
cleanup(){ kill $SRV 2>/dev/null; [ -n "$MOCK" ] && kill $MOCK 2>/dev/null; rm -rf "$TMACH_DATA_DIR"; }
trap cleanup EXIT
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 40000 ] && { echo "server never came up"; cat "$TMACH_DATA_DIR/server.log"; exit 1; }
done; exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
P(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
# PUT and PATCH, which this file had neither of until #91 req 4 needed both.
# Grep for a helper before using one: an undefined name runs as an unknown
# command, nothing sets `fail`, and the suite reports PASS with the assertion
# silently absent — the shape this file's own `differ` comment records.
PU(){ curl -s -X PUT "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
PA(){ curl -s -X PATCH "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
# a 7B model takes ~50 s per extraction and ~30 s per translation; the mock answers
# in milliseconds. Poll for up to 10 minutes live, 1 minute scripted. Do NOT
# lengthen the scripted budget to get a stalled run to finish: a queue that
# stops with nothing running is a BUDGET, not a slow engine, and a longer wait
# only hides it (see the ai.requests note in section 0).
WAIT_TRIES=$([ $LIVE = 1 ] && echo 1200 || echo 120)
# The RUN's status, read as JSON — never `grep -oP '"status":"\K…' | head -1`, which
# is a substring of the whole document and happened to be the run's only because
# the top-level key sorted first. Requirement 6's report nests a per-document
# `status` inside a step's output, and the day it did every run in this suite read
# as "answered" and polled to the end of its patience. `ocr-smoke.sh` records the
# same lesson from the other direction.
wait_run(){ # <run id> -> sets RUNST (final status) and RUNJSON; never in a $(…), or they are lost
  RUNST=""; RUNJSON=""; for i in $(seq 1 $WAIT_TRIES); do
    RUNJSON=$(G "/api/runs/$1")
    RUNST=$(printf '%s' "$RUNJSON" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")')
    case "$RUNST" in done|error|canceled) break;; esac; sleep 0.5
  done; }

echo "doc-pipeline smoke — model: ${TMACH_MODEL:-?} at $TMACH_MODEL_URL ($([ $LIVE = 1 ] && echo live || echo mock))"
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
printf 'INVOICE\nAcme Corp\n2026-09-01\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n' > "$TMACH_DATA_DIR/inv.txt"
INV=$(curl -s -X PUT "$B/api/repo/inbox/acme.txt?visibility=private" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/inv.txt")
INVID=$(printf '%s' "$INV" | jq_ 'd["id"]')
assert "invoice is private" "$INV" '"visibility":"private"'
assert "shared with bob (view)" "$(P "/api/repo-obj/$INVID/share" "{\"user_id\":\"$BOBID\"}")" '"capability":"view"'
printf '# Purchase approval\n\nVendor: {{vendor}}\nTotal: {{total}}\n\n{{#each items}}- {{description}}: {{amount}}\n{{/each}}' > "$TMACH_DATA_DIR/tmpl.md"
assert "template uploaded" "$(curl -s -X PUT "$B/api/repo/templates/approval.md" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/markdown' --data-binary @"$TMACH_DATA_DIR/tmpl.md")" '"key":"templates/approval.md"'

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
python3 - "$TMACH_DATA_DIR/approval.docx" <<'PY'
import sys, zipfile
xml = ('<w:document><w:body><w:p><w:r><w:t>Vendor: {{ven</w:t></w:r><w:r><w:t>dor}}</w:t></w:r></w:p>'
       '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{{#each items}}</w:t></w:r></w:p></w:tc></w:tr>'
       '<w:tr><w:tc><w:p><w:r><w:t>{{description}}</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{{amount}}</w:t></w:r></w:p></w:tc></w:tr>'
       '<w:tr><w:tc><w:p><w:r><w:t>{{/each}}</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('[Content_Types].xml', '<Types/>'); z.writestr('word/document.xml', xml)
PY
DOCX_CT='application/vnd.openxmlformats-officedocument.wordprocessingml.document'
assert "docx template uploaded" "$(curl -s -X PUT "$B/api/repo/templates/approval.docx" -H "Authorization: Bearer $TOK" -H "Content-Type: $DOCX_CT" --data-binary @"$TMACH_DATA_DIR/approval.docx")" '"key":"templates/approval.docx"'
RUND=$(P /api/workflows/process-upload/run "{\"input\":{\"object_id\":\"$INVID\",\"schema\":$SCHEMA,\"template\":\"templates/approval.docx\",\"locales\":[]}}")
RIDD=$(printf '%s' "$RUND" | grep -oP '"id":"\K[^"]+' | head -1)
wait_run "$RIDD"; STD="$RUNST"; [ "$STD" = done ] || STD="$STD — $(printf '%s' "$RUNJSON" | head -c 300)"
assert "docx run finished" "$STD" "done"
LISTD=$(G "/api/repo?prefix=inbox/acme.txt.form.docx")
assert "the form is a .docx beside the source" "$LISTD" '"key":"inbox/acme.txt.form.docx"'
assert "…with the DOCX content type" "$LISTD" "\"content_type\":\"$DOCX_CT\""
DID=$(printf '%s' "$LISTD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["objects"][0]["id"])')
curl -s "$B/api/repo-obj/$DID/content" -H "Authorization: Bearer $TOK" -o "$TMACH_DATA_DIR/form.docx"
assert "the .docx opens and is filled" "$(python3 -c 'import sys,zipfile;print(zipfile.ZipFile(sys.argv[1]).read("word/document.xml").decode())' "$TMACH_DATA_DIR/form.docx")" 'Vendor: Acme Corp'

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
  curl -s "$B/api/repo-obj/$PDID/content" -H "Authorization: Bearer $TOK" -o "$TMACH_DATA_DIR/form.pdf"
  assert "it is a PDF" "$(head -c 4 "$TMACH_DATA_DIR/form.pdf")" '%PDF'
  if command -v pdftotext >/dev/null; then
    assert "the PDF's text is the filled form" "$(pdftotext "$TMACH_DATA_DIR/form.pdf" -)" 'Vendor: Acme Corp'
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
  printf 'a memo about nothing in particular' > "$TMACH_DATA_DIR/memo.txt"
  MEMO=$(curl -s -X PUT "$B/api/repo/inbox/memo.txt" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/memo.txt")
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
printf 'INVOICE 4471\nAcme Corp\nTotal due 1250.50\n' > "$TMACH_DATA_DIR/m-inv.txt"
printf 'Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme\n' > "$TMACH_DATA_DIR/m-let.txt"
printf 'not really a jpeg' > "$TMACH_DATA_DIR/m-pho.jpg"
printf 'Quarterly summary of levee inspections for the north reach.\n' > "$TMACH_DATA_DIR/m-rep.txt"
up(){ curl -s -X PUT "$B/api/repo/$1" -H "Authorization: Bearer $TOK" -H "Content-Type: $2" --data-binary @"$3"; }
MINV=$(up mixed/a.txt text/plain "$TMACH_DATA_DIR/m-inv.txt" | jq_ 'd["id"]')
MLET=$(up mixed/b.txt text/plain "$TMACH_DATA_DIR/m-let.txt" | jq_ 'd["id"]')
MPHO=$(up mixed/c.jpg image/jpeg "$TMACH_DATA_DIR/m-pho.jpg" | jq_ 'd["id"]')
MREP=$(up mixed/d.txt text/plain "$TMACH_DATA_DIR/m-rep.txt" | jq_ 'd["id"]')
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

printf 'Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme\n' > "$TMACH_DATA_DIR/r-let.txt"
printf 'Minutes of the site meeting, 14 October.\n' > "$TMACH_DATA_DIR/r-min.txt"
RLET=$(up rev/b.txt text/plain "$TMACH_DATA_DIR/r-let.txt" | jq_ 'd["id"]')
RMIN=$(up rev/c.txt text/plain "$TMACH_DATA_DIR/r-min.txt" | jq_ 'd["id"]')

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
echo "== 5d. the backlog: a backfill over a prefix (#87 req 5, CLS-24…28) ============"
# Everything above classifies ONE document somebody named. This is the prefix that
# was already there when the labels were decided — requirement 5, and the thing
# CLS-23 deliberately does not do: creating a trigger does not fire it on what
# already matches.
printf 'INVOICE 9001\nAcme Corp\nTotal due 42.00\n' > "$TMACH_DATA_DIR/b-inv.txt"
printf 'Dear Mr Jones,\n\nThe survey is enclosed.\n' > "$TMACH_DATA_DIR/b-let.txt"
printf 'nor is this a jpeg' > "$TMACH_DATA_DIR/b-pho.jpg"
BINV=$(up back/a.txt text/plain "$TMACH_DATA_DIR/b-inv.txt" | jq_ 'd["id"]')
BLET=$(up back/b.txt text/plain "$TMACH_DATA_DIR/b-let.txt" | jq_ 'd["id"]')
BPHO=$(up back/c.jpg image/jpeg "$TMACH_DATA_DIR/b-pho.jpg" | jq_ 'd["id"]')
# a document OUTSIDE the prefix, to prove the window is the window
BOUT=$(up outside/d.txt text/plain "$TMACH_DATA_DIR/b-inv.txt" | jq_ 'd["id"]')

assert "the backfill workflow arrived"       "$(G /api/workflows)" '"slug":"classify-backfill"'
assert "doc_list_unclassified is registered" "$(G /api/tools)" '"name":"doc_list_unclassified"'

backfill(){ # <prefix> -> RUNST / RUNJSON
  local r; r=$(P /api/workflows/classify-backfill/run \
    "{\"input\":{\"prefix\":\"$1\",\"labels\":$LABELS,\"rules\":$CRULES,\"backends\":[\"rules\"]}}")
  wait_run "$(printf '%s' "$r" | grep -oP '"id":"\K[^"]+' | head -1)"
}
# The ledger before and after: a RULES-ONLY backfill must spend NO MODEL BUDGET,
# which is what makes draining a real backlog affordable.
#
# Asserted on TOKENS, not on `ai.requests`, and the reason is worth knowing:
# `ai.requests` is incremented once per SCHEDULER JOB (main.rkt's one biller), so
# a five-step run moves it by five whether a model was reached or not. Only the
# tools' own `meter!` increments it per model call. At the tool level — where
# classify-tests asserts it — the count really is model requests; over HTTP
# through the engine it is jobs, and an assertion on it here would pass against a
# backfill that called the model for every document.
toks(){ G /api/usage | jq_ '[q["used"] for q in d["quota"] if q["dimension"]=="ai.tokens.total"][0]'; }
REQ0=$(toks)

backfill "back/"
assert "the backfill finished"               "$(ran)" done
assert "…it found three documents"           "$RUNJSON" '"count":3'
refute "…and said there was no more"         "$RUNJSON" '"truncated":true'
assert "the invoice was classified"          "$(G "/api/repo-obj/$BINV")" '"doc_type":"invoice"'
assert "the letter was classified"           "$(G "/api/repo-obj/$BLET")" '"doc_type":"letter"'
# CLS-9 again, and it is the backfill's best case: a photograph is the document a
# backlog has most of and the one no reader can open
assert "the photograph was classified"       "$(G "/api/repo-obj/$BPHO")" '"doc_type":"photo"'
refute "a document outside the prefix is untouched" "$(G "/api/repo-obj/$BOUT")" '"doc_type"'
assert "each one has its record beside it"   "$(G '/api/repo?prefix=back/')" '"key":"back/a.txt.classification.json"'
# ?attr= is the aggregate the whole slice exists to make possible
assert "…and LAY-4's filter finds them by type" "$(G '/api/repo?prefix=back/&attr=doc_type:photo')" '"key":"back/c.jpg"'

REQ1=$(toks)
assert "a rules-only backfill spent no model budget" "$REQ0" "$REQ1"

# CLS-25: the marker is the attribute the backfill itself wrote, so running it
# again is free — and CLS-26 is what makes that true, because the three records
# it just wrote have no type of their own and would otherwise be the next batch.
backfill "back/"
assert "the re-run finished"                 "$(ran)" done
assert "…and found nothing to do"            "$RUNJSON" '"count":0'
refute "…so no document was classified again" "$RUNJSON" '"step_id":"classify#0"'

# and the way to reclassify after changing the label set: clear the type, which
# makes exactly that document eligible again. There is no `force`, because the
# absence of the attribute is the only progress marker there is.
curl -s -X PATCH "$B/api/repo-obj/$BLET/attributes" -H "Authorization: Bearer $TOK" \
     -d '{"attributes":{"doc_type":""}}' >/dev/null
backfill "back/"
assert "a withdrawn type is backfilled again" "$(ran)" done
assert "…exactly one document"                "$RUNJSON" '"count":1'
assert "…and it has its type back"            "$(G "/api/repo-obj/$BLET")" '"doc_type":"letter"'

echo
echo "== 5e. how good is it? the evaluation harness (#87 req 6, CLS-29…33) =========="
# Everything above asserts that the classifier RAN. Requirement 6 is the question
# nobody could answer over HTTP until now: how OFTEN is it right, and which of its
# backends is carrying the load. The model answers "invoice" for anything it can
# read, so it is right about the invoice fixture and wrong about the letter — which
# is what puts a real figure in the `confused_with` column below.
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"You classify a document": "{\"label\":\"invoice\",\"confidence\":0.80,\"rationale\":\"mock\"}",
 "*": "MOCK"}
JSON
fi
printf 'INVOICE 7001\nAcme Corp\nTotal due 7.00\n' > "$TMACH_DATA_DIR/e-inv.txt"
printf 'Dear Ms Patel,\n\nThe inspection is booked.\n' > "$TMACH_DATA_DIR/e-let.txt"
printf 'still not a jpeg' > "$TMACH_DATA_DIR/e-pho.jpg"
EINV=$(up eval/a.txt text/plain "$TMACH_DATA_DIR/e-inv.txt" | jq_ 'd["id"]')
ELET=$(up eval/b.txt text/plain "$TMACH_DATA_DIR/e-let.txt" | jq_ 'd["id"]')
EPHO=$(up eval/c.jpg image/jpeg "$TMACH_DATA_DIR/e-pho.jpg" | jq_ 'd["id"]')

assert "the evaluation workflow arrived"  "$(G /api/workflows)" '"slug":"classify-eval"'
assert "doc_classify_eval is registered"  "$(G /api/tools)" '"name":"doc_classify_eval"'
# CLS-33 at the surface: the tool that MEASURES the classifier is a READ
assert "…and it is a read, not a write"   "$(G /api/tools)" '"name":"doc_classify_eval","permission":"files:read"'

# the rule set evaluated here describes invoices and photographs and NOT letters —
# a deliberate hole, because a report that cannot show one is not a report
ERULES='[{"label":"photo","content_type":"image/"},{"label":"invoice","any":["Total due"]}]'

evaluate(){ # <backends json> -> RUNST / RUNJSON
  local r; r=$(P /api/workflows/classify-eval/run \
    "{\"input\":{\"prefix\":\"eval/\",\"labels\":$LABELS,\"rules\":$ERULES,\"backends\":$1}}")
  wait_run "$(printf '%s' "$r" | grep -oP '"id":"\K[^"]+' | head -1)"
}
# the report is nested in the step's output, and every figure below is read out of
# it by name rather than grepped: `"fixtures":3` appears in a per-label row too,
# so a substring assertion here would pass against the wrong number
rep(){ printf '%s' "$RUNJSON" | python3 -c 'import sys,json
d=json.load(sys.stdin)
r=[s["output"]["result"] for s in d["steps"] if s["step_id"]=="measure"][0]
b={x["backend"]:x for x in r["backends"]}
for x in b.values(): x["by_label"]={l["label"]:l for l in x["labels"]}
print(eval(sys.argv[1],{"r":r,"b":b}))' "$1"; }

# THE FIRST RUN IS THE SETUP, and that is pinned rather than papered over: LAY-4
# refuses an undefined attribute key, so until the harness has declared
# `doc_type_expected` nobody can label a fixture at all.
refute "the expected-type field does not exist yet" "$(G /api/repo-fields)" '"key":"doc_type_expected"'
evaluate '["rules"]'
assert "an evaluation with no fixtures finished" "$(ran)" done
assert "…and reported an empty fixture set"      "$(rep 'r["fixtures"]')" 0
assert "…having declared the field to label with" "$(G /api/repo-fields)" '"key":"doc_type_expected"'

lbl(){ curl -s -X PATCH "$B/api/repo-obj/$1/attributes" -H "Authorization: Bearer $TOK" \
            -d "{\"attributes\":{\"doc_type_expected\":\"$2\"}}"; }
lbl "$EINV" invoice >/dev/null
lbl "$ELET" letter  >/dev/null
lbl "$EPHO" photo   >/dev/null

TOK0=$(toks)
evaluate '["rules"]'
assert "the rules evaluation finished"       "$(ran)" done
assert "…over the three labelled documents"  "$(rep 'r["fixtures"]')" 3
# the two figures that have to be read together: it was right about everything it
# answered, and it answered two thirds of the set. Either alone misleads.
assert "…the rule set was never wrong"       "$(rep 'b["rules"]["accuracy"]')" 1.0
assert "…and it answered two of three"       "$(rep 'b["rules"]["coverage"]')" 0.667
assert "…abstaining on the letter it has no rule for" "$(rep 'b["rules"]["by_label"]["letter"]["abstained"]')" 1
refute "…which is not counted as an error"   "$(rep 'b["rules"]["by_label"]["letter"]["wrong"]')" 1
# every label in the set is reported, including one nobody wrote a fixture for
assert "a label with no fixture is reported as a hole" "$(rep 'b["rules"]["by_label"]["report"]["fixtures"]')" 0
assert "a rules-only evaluation spent no model budget" "$TOK0" "$(toks)"

# CLS-33 over HTTP: the whole point is that measuring changes nothing
refute "the invoice fixture was NOT classified" "$(G "/api/repo-obj/$EINV")" '"doc_type":'
assert "…and its expected type is untouched"    "$(G "/api/repo-obj/$EINV")" '"doc_type_expected":"invoice"'
refute "no classification record was written"   "$(G '/api/repo?prefix=eval/')" '"key":"eval/a.txt.classification.json"'

evaluate '["llm"]'
assert "the model evaluation finished"       "$(ran)" done
assert "…it answered the two it could read"  "$(rep 'b["llm"]["answered"]')" 2
assert "…and was right about one of them"    "$(rep 'b["llm"]["accuracy"]')" 0.5
# the actionable half: WHAT it mistook the letter for
assert "…calling the letter an invoice"      "$(rep 'b["llm"]["by_label"]["letter"]["confused_with"]["invoice"]')" 1
# the photograph has no text, so the model was never reachable for it — an
# abstention about this backend, where a content-type rule answered it (CLS-9)
assert "…abstaining on the photograph"       "$(rep 'b["llm"]["by_label"]["photo"]["abstained"]')" 1
# CLS-32: the figure that says whether a review threshold could separate them
assert "…with the confidence of a wrong answer" "$(rep 'b["llm"]["mean_confidence_wrong"]')" 0.8
# a one-backend evaluation's chain IS that backend, which is why it says nothing
assert "the chain of one backend is that backend" "$(rep 'b["chain"]["correct"]')" \
                                                  "$(rep 'b["llm"]["correct"]')"
TOK1=$(toks)
differ "a model evaluation DID spend budget"  "$TOK0" "$TOK1"

# CLS-31: and with BOTH, the chain beats either of its parts — the figure an
# operator could not have worked out from the two columns beside it
evaluate '["rules","llm"]'
assert "the chained evaluation finished"     "$(ran)" done
assert "…rules were right about two"         "$(rep 'b["rules"]["correct"]')" 2
assert "…the model about one"                "$(rep 'b["llm"]["correct"]')" 1
assert "…and the chain about two, for free"  "$(rep 'b["chain"]["correct"]')" 2
assert "…because the model answered the letter the rules declined, and got it wrong" \
       "$(rep 'b["llm"]["by_label"]["letter"]["wrong"]')" 1

# CLS-29: a fixture labelled outside the set is excluded and SAID SO, never
# counted as a miss — the classifier is not to blame for somebody's typing
lbl "$EPHO" Photo >/dev/null
assert "a fixture label outside the set is refused by LAY-4" "$(lbl "$EPHO" Photo)" '"doc_type_expected":"Photo"'
evaluate '["rules"]'
assert "the evaluation still finished"       "$(ran)" done
assert "…scoring only the two it could"      "$(rep 'r["fixtures"]')" 2
assert "…and naming the excluded fixture"    "$RUNJSON" 'eval/c.jpg'
assert "…while the rule set keeps its record" "$(rep 'b["rules"]["accuracy"]')" 1.0
echo
echo "== 5f. what the model is NOT told: redaction (#91 req 1, RED-1…9) ============="
# Every block above sends a document's text to a model entire. This is the step
# that minimises it — and the artifact is a DOCUMENT, because "show me what you
# would have sent" is the only way a person can audit a redaction.
printf 'Dear Ms Patel,\n\nYour claim 44719823 was received on 2026-10-14. We wrote to Arun Patel\nat arun.patel@example.com and tried to reach him on +44 20 7946 0958.\nHis date of birth is 3 April 1981.\n' > "$TMACH_DATA_DIR/r-let.txt"
RLET=$(up red/letter.txt text/plain "$TMACH_DATA_DIR/r-let.txt" | jq_ 'd["id"]')

assert "the redaction workflow arrived"   "$(G /api/workflows)" '"slug":"redact-document"'
assert "doc_redact is registered"         "$(G /api/tools)" '"name":"doc_redact"'

DETS='["email","date","id_number","dictionary","phone"]'
redact(){ # <detectors json> <terms json> -> RUNST / RUNJSON
  local r; r=$(P /api/workflows/redact-document/run \
    "{\"input\":{\"object_id\":\"$RLET\",\"detectors\":$1,\"terms\":$2}}")
  wait_run "$(printf '%s' "$r" | grep -oP '"id":"\K[^"]+' | head -1)"
}
rout(){ printf '%s' "$RUNJSON" | python3 -c 'import sys,json
d=json.load(sys.stdin)
r=[s["output"]["result"] for s in d["steps"] if s["step_id"]=="redact"][0]
print(eval(sys.argv[1],{"r":r}))' "$1"; }

redact "$DETS" '["Patel","Arun Patel"]'
assert "the redaction finished"           "$(ran)" done
# two terms and five patterns
assert "…seven identifiers replaced"      "$(rout 'r["replaced"]')" 7
assert "…two of them dates"               "$(rout 'r["counts"]["date"]')" 2
assert "…one telephone number"            "$(rout 'r["counts"]["phone"]')" 1
# RED-3: the loose phone pattern does NOT win the ISO date or the SSN-shaped
# number. The redaction would be complete either way; requirement 5's report is
# what would be wrong, and it is the thing a reviewer reads.
assert "…and one account number, not three" "$(rout 'r["counts"]["id_number"]')" 1

# THE DOCUMENT a person can read, which is the artifact of this slice
assert "the redacted text is a document beside the source" \
  "$(G '/api/repo?prefix=red/')" '"key":"red/letter.txt.redacted.txt"'
RID=$(G '/api/repo?prefix=red/' | python3 -c 'import sys,json
print([o["id"] for o in json.load(sys.stdin)["objects"] if o["key"].endswith(".redacted.txt")][0])')
RTEXT=$(curl -s "$B/api/repo-obj/$RID/content" -H "Authorization: Bearer $TOK")
assert "…and it carries tokens"           "$RTEXT" '<PERSON_1>'
assert "…the prose around them intact"    "$RTEXT" 'Your claim <ID_1> was received on <DATE_1>.'
# the whole point, asserted one value at a time — a single grep makes this
# claim vacuously
refute "…the name is gone"                "$RTEXT" 'Patel'
refute "…the email is gone"               "$RTEXT" 'arun.patel@example.com'
refute "…the telephone number is gone"    "$RTEXT" '+44 20 7946 0958'
refute "…the date of birth is gone"       "$RTEXT" '3 April 1981'
refute "…and the claim number is gone"    "$RTEXT" '44719823'

# RED-6: NO ENDPOINT RETURNS THE MAP. The tool result reaches a step's stored
# output, the agent transcript and a console pane — three more copies than the
# sealed row has — so it carries the TOKENS and never the values. Asserted on the
# step's OUTPUT, which is what this slice produces.
assert "the step output reports the tokens" "$(rout 'r["tokens"]')" '<EMAIL_1>'
ROUT=$(rout 'r')
refute "…and never the email"             "$ROUT" 'arun.patel@example.com'
refute "…nor the name"                    "$ROUT" 'Arun Patel'
refute "…nor the telephone number"        "$ROUT" '7946 0958'
refute "…nor the date of birth"           "$ROUT" '3 April 1981'

# RED-9, AND IT IS A LIMIT RATHER THAN A LEAK, SO IT IS ASSERTED RATHER THAN
# WISHED AWAY: the dictionary terms are the CALLER'S OWN INPUT, and the engine
# stores every run's input in `workflow_runs.input` and hands it back on
# `GET /api/runs/:id` to anybody holding `workflows:read`. So the names somebody
# asked to have redacted are visible to their colleagues, which for a list of
# names is worth knowing about. It is FEED-13's line — a read returns the
# configuration as it was given, and an operator who cannot see what they typed
# cannot maintain it — and requirement 2 is where the terms move out of a run
# input and into a spec or a trigger. This assertion exists so that nobody later
# reads the four refutations above and concludes the whole run is clean.
assert "the run's INPUT carries the caller's own terms, by design" "$RUNJSON" '"terms":["Patel","Arun Patel"]'

# RED-1: a detector the caller invents is refused BY NAME, and the refusal says
# why rather than reading as a typo
redact '["email","ssn"]' '[]'
assert "an invented detector fails the run" "$RUNST" error
assert "…naming what this build detects"    "$RUNJSON" 'email, date, id_number, dictionary, phone'
assert "…and why the caller cannot write one" "$RUNJSON" 'rather than one the caller writes'

# RED-4: a document already containing a token is refused, because a token minted
# here could not be told from it — and putting values back would then write an
# identifier where the document never had one
printf 'see <PERSON_1> above\n' > "$TMACH_DATA_DIR/r-tok.txt"
RTOK=$(up red/tokened.txt text/plain "$TMACH_DATA_DIR/r-tok.txt" | jq_ 'd["id"]')
RT=$(P /api/workflows/redact-document/run \
  "{\"input\":{\"object_id\":\"$RTOK\",\"detectors\":[\"email\"],\"terms\":[]}}")
wait_run "$(printf '%s' "$RT" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "text already shaped like a token is refused" "$RUNST" error
assert "…by name"                                    "$RUNJSON" 'already contains text shaped like a redaction token'
echo
echo "== 5g. a STEP that redacts before it asks (#91 req 2, RED-10…14) =============="
# §5f redacts a document into another document. This is the half that matters for
# a pipeline: the step builds its prompt from the redacted text and puts the
# values BACK before anything is stored.
#
# A SPEC PUBLISHED HERE rather than a shipped one, which is `pdf-form`'s pattern
# above and for the same reason: `redact` is a TOOL argument, and adding an input
# to a published workflow is a breaking change for every caller of it.
#
# A HAND-WRITTEN SPEC USES THE WIRE GRAMMAR, `${steps.<id>.output.*}`, and NOT the
# macro's `(out text result)` sugar — the first version of this block wrote
# `${out.text.result}` and the publish refused it while naming every form it does
# accept, which is the validator being useful rather than a trap.
if [ $LIVE = 0 ]; then cat > "$MOCK_REPLY_FILE" <<'JSON'
{"extract structured data": "{\"who\":\"<PERSON_2>\",\"phone\":\"<PHONE_1>\",\"dob\":\"<DATE_2>\"}",
 "*": "MOCK"}
JSON
fi
printf 'Dear Ms Patel,\n\nYour claim 44719823 was received on 2026-10-14. We wrote to Arun Patel\nat arun.patel@example.com and tried to reach him on +44 20 7946 0958.\nHis date of birth is 3 April 1981.\n' > "$TMACH_DATA_DIR/g-let.txt"
GLET=$(up redstep/letter.txt text/plain "$TMACH_DATA_DIR/g-let.txt" | jq_ 'd["id"]')

GSCHEMA='{"type":"object","required":["who","phone","dob"],"properties":{"who":{"type":"string"},"phone":{"type":"string"},"dob":{"type":"string"}}}'
GWF='{"spec":1,"slug":"redacted-extract","input":{"object_id":"string"},"steps":[
  {"id":"text","uses":"tool:doc_text","with":{"object":"${input.object_id}"}},
  {"id":"fields","uses":"tool:doc_extract_fields","with":{"text":"${steps.text.output.result}","schema":'"$GSCHEMA"',
   "object":"${input.object_id}","redact":true,
   "redact_detectors":["email","date","id_number","dictionary","phone"],
   "redact_terms":["Patel","Arun Patel"],"run":"${run.id}","step":"fields"},"end":true}]}'
assert "the redacting spec published" "$(P /api/workflows "$GWF")" '"slug":"redacted-extract"'

GR=$(P /api/workflows/redacted-extract/run "{\"input\":{\"object_id\":\"$GLET\"}}")
wait_run "$(printf '%s' "$GR" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "the redacting run finished" "$(ran)" done

gout(){ printf '%s' "$RUNJSON" | python3 -c 'import sys,json
d=json.load(sys.stdin)
r=[s["output"]["result"] for s in d["steps"] if s["step_id"]=="fields"][0]
print(eval(sys.argv[1],{"r":r}))' "$1"; }

# THE ACCEPTANCE CRITERION: the stored extraction has the REAL values, though the
# model was shown only tokens. The scripted reply answers with the tokens it was
# given, which is what a model reasoning over redacted text does.
#
# `<PERSON_2>` and not `<PERSON_1>`, and the difference is RED-2 working: tokens
# are numbered in order of FIRST APPEARANCE, so `<PERSON_1>` is the "Patel" of
# "Dear Ms Patel" and `<PERSON_2>` is "Arun Patel" further down. The first version
# of this block asked for `<PERSON_1>` and got "Patel" back, correctly.
assert "the stored field is the real name"  "$(gout 'r["fields"]["who"]')" 'Arun Patel'
assert "…and the real telephone number"     "$(gout 'r["fields"]["phone"]')" '+44 20 7946 0958'
assert "…and the real date of birth"        "$(gout 'r["fields"]["dob"]')" '3 April 1981'
# requirement 2: the record says redaction was applied and which detectors ran
assert "the result says redaction was applied" "$(gout 'r["redaction"]["applied"]')" 'True'
assert "…naming the detectors"                 "$(gout 'r["redaction"]["detectors"]')" 'dictionary'
assert "…with counts per detector"             "$(gout 'r["redaction"]["counts"]["email"]')" 1
# the DERIVED DOCUMENT carries the real values too, because that is what a later
# step binds — and it carries no token at all
assert "the extracted document is beside the source" \
  "$(G '/api/repo?prefix=redstep/')" '"key":"redstep/letter.txt.extracted.json"'
GXID=$(G '/api/repo?prefix=redstep/' | python3 -c 'import sys,json
print([o["id"] for o in json.load(sys.stdin)["objects"] if o["key"].endswith(".extracted.json")][0])')
GXTEXT=$(curl -s "$B/api/repo-obj/$GXID/content" -H "Authorization: Bearer $TOK")
assert "…with the real values in it"       "$GXTEXT" 'Arun Patel'
refute "…and no token left behind"         "$GXTEXT" '<PERSON_'
# RED-12: and NO MAP WAS PERSISTED. The step redacts and rehydrates inside one
# call, so a stored map would be a concordance of identifiers kept for no reader.
# §5f's own `doc_redact` run is the only thing that stores one.
assert "the step persisted no token map" \
  "$(G "/api/repo-obj/$GLET/processing")" '"runs_complete":true'
echo
echo "== 5h. where a labelled document's text may go (#91 req 4, RED-24…33) ========="
# The teeth of #91. Requirements 1-3 built the means to minimise a prompt and the
# record of what was sent; this is the one that STOPS something.
#
# THE REFUSAL NEEDS A HOSTED BACKEND, and the mock model is on loopback — which
# the policy exempts by design (nothing left the box). So the governed backend
# here is a PULL executor: it has no endpoint, the platform does not know which
# model URL a worker will call, and the content leaves by the job row. That it
# has no worker costs this block nothing, because the policy refuses BEFORE the
# dispatch — which is itself the property being asserted.
HEXEC=$(P /api/executors '{"name":"gpu-far","mode":"pull","model":"mock"}')
assert "a pull executor to be governed" "$HEXEC" '"name":"gpu-far"'

# The label is a LAY-4 object attribute, so the team defines the field as it
# defines any other. PUT REPLACES the whole list, and the classifier's own three
# fields are already in it by now, so this appends rather than overwrites.
HFIELDS=$(G /api/repo-fields | python3 -c 'import sys,json
d=json.load(sys.stdin)
fs=[f for f in d["fields"] if f.get("key")!="sensitivity"]
fs.append({"key":"sensitivity","label":"Sensitivity"})
print(json.dumps({"fields":fs}))')
assert "the team defines a sensitivity field" "$(PU /api/repo-fields "$HFIELDS")" '"key":"sensitivity"'

printf 'Dear Ms Patel,\n\nYour claim 44719823 was received.\n' > "$TMACH_DATA_DIR/h-let.txt"
HOBJ=$(up sens/letter.txt text/plain "$TMACH_DATA_DIR/h-let.txt" | jq_ 'd["id"]')
assert "the document is marked confidential" \
  "$(PA "/api/repo-obj/$HOBJ/attributes" '{"attributes":{"sensitivity":"confidential"}}')" \
  '"sensitivity":"confidential"'

# The policy. `nope-gw` is deliberately a name no executor answers to: a typo
# here fails CLOSED, so it is REPORTED on the read rather than refused on the
# write — refusing it would make a policy unwritable before the backend it names
# exists, which is the ordinary order an operator sets one up in.
HPOL='{"labels":{"confidential":{"executors":["nope-gw"],"allow_redacted":true}}}'
HSAVED=$(PU /api/executor-policy "$HPOL")
assert "the instance policy is stored"      "$HSAVED" '"configured":true'
assert "…naming the attribute it reads"     "$HSAVED" '"attribute":"sensitivity"'
assert "…and reporting the name nothing answers to" "$HSAVED" '"unknown_executors":["nope-gw"]'
assert "an unknown policy field is refused" "$(PU /api/executor-policy '{"labels":{"a":{"executor":[]}}}')" \
  'unknown field'
assert "…and so is a label with no name"    "$(PU /api/executor-policy '{"labels":{"":{}}}')" \
  'cannot be empty'
assert "the policy survived the refusals"   "$(G /api/executor-policy)" '"nope-gw"'

# the team's bulk work now goes to the governed executor
assert "the utility role points at it" "$(PU /api/model-roles '{"roles":{"utility":"gpu-far"}}')" 'gpu-far'

# §5g left the mock answering "MOCK" to anything but an extraction prompt, so the
# classify step would fail for a reason with nothing to do with the policy — and
# the POSITIVE control below is a step that must SUCCEED. The needle is the
# classifier's own system prompt.
#
# MERGED INTO the reply file rather than written over it. These blocks share one
# mock and the sections AFTER this one read whatever the last block left, so
# replacing the file starved the knowledge graph's extraction 150 lines below —
# which reads as a broken extractor and is a fixture collision.
if [ $LIVE = 0 ]; then
  python3 -c 'import json,sys
p=sys.argv[1]
try:  d=json.load(open(p))
except Exception:  d={}
d["You classify a document"]=json.dumps({"label":"letter","confidence":0.90,"rationale":"mock"})
json.dump(d,open(p,"w"))' "$MOCK_REPLY_FILE"
fi

HWF='{"spec":1,"slug":"sens-classify","input":{"object_id":"string"},"steps":[
  {"id":"kind","uses":"tool:doc_classify","with":{"object":"${input.object_id}","backends":["llm"],
   "labels":[{"name":"letter","description":"a letter"}],"run":"${run.id}","step":"kind"},"end":true}]}'
assert "the classifying spec published" "$(P /api/workflows "$HWF")" '"slug":"sens-classify"'

HR=$(P /api/workflows/sens-classify/run "{\"input\":{\"object_id\":\"$HOBJ\"}}")
wait_run "$(printf '%s' "$HR" | grep -oP '"id":"\K[^"]+' | head -1)"
# THE ISSUE'S SECOND ACCEPTANCE CRITERION: refused.
assert "an unredacted step against a disallowed executor fails" "$RUNST" error
assert "…and the failure names the label"  "$RUNJSON" 'confidential'
assert "…and the backend it was headed for" "$RUNJSON" 'gpu-far'
assert "…and what the caller can do about it" "$RUNJSON" 'redact the step'
refute "…while quoting none of the text"   "$RUNJSON" 'Patel'

# AND AUDITED, in the trail of the team whose document it was. `audit-list` DOES
# NOT PROJECT `meta`, which this file's own notes record: the first version of
# this block asserted the label inside it and failed, and the two refutes beside
# it PASSED VACUOUSLY because the field was never in the response at all — #59's
# rule, where asserting over an API that never carried a field is worse than not
# asserting. What the meta holds (the label, the executor, the backend's host,
# and never the text or the KEY) is asserted over the ROW, in
# test/sensitivity-tests.rkt. What is HTTP's to answer is the rest of the entry.
HAUD=$(G /api/audit)
assert "the refusal is audited"             "$HAUD" '"action":"ai.egress.refused"'
assert "…as a refusal, not an ok"           "$HAUD" '"result":"refused"'
assert "…naming the document it was about"  "$HAUD" "\"resource_id\":\"$HOBJ\""
assert "…and the person whose run it was"   "$HAUD" '"actor_type":"user"'
refute "the trail carries none of the text" "$HAUD" '44719823'

# THE CONTROL THAT MAKES THE REFUSAL MEAN SOMETHING. Back to the loopback model:
# the same labelled document, the same policy, and the step runs — a feature that
# refused everything would pass every assertion above.
assert "the utility role is cleared" "$(PU /api/model-roles '{"roles":{"utility":null}}')" '"roles"'
HR2=$(P /api/workflows/sens-classify/run "{\"input\":{\"object_id\":\"$HOBJ\"}}")
wait_run "$(printf '%s' "$HR2" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a loopback backend is outside the policy entirely" "$RUNST" done

# OFF UNLESS CONFIGURED, over HTTP: with the document dropped from the policy the
# label is one NO tier mentions, which is the one absence this slice fails closed
# on — so it is refused again, and `DELETE`ing the policy altogether lets it run.
assert "the utility role points back at it" "$(PU /api/model-roles '{"roles":{"utility":"gpu-far"}}')" 'gpu-far'
assert "an empty policy is still a policy" "$(PU /api/executor-policy '{"labels":{}}')" '"configured":true'
HR3=$(P /api/workflows/sens-classify/run "{\"input\":{\"object_id\":\"$HOBJ\"}}")
wait_run "$(printf '%s' "$HR3" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a label no tier mentions is refused"  "$RUNST" error
assert "…and the refusal says so"             "$RUNJSON" 'does not list that label'

# RED-29: reading the policy is an operator's business — it is a list of this
# instance's own backends, and what a team member needs from it is in the refusal.
HMEM=$(P /api/members '{"username":"hmem","password":"pw-pw-pw1","role":"member"}' | jq_ 'd["token"]')
assert "a member cannot read the policy" \
  "$(curl -s $B/api/executor-policy -H "Authorization: Bearer $HMEM")" 'Forbidden: instance:manage'
assert "a member cannot write one" \
  "$(curl -s -X PUT $B/api/executor-policy -H "Authorization: Bearer $HMEM" -d "$HPOL")" 'Forbidden: instance:manage'

# RED-34 AND THE WAY THIS BLOCK FOUND IT. `PUT {"labels":{}}` above is still a
# CONFIGURED policy, so it refuses every label it does not mention — and leaving
# one behind, with a labelled document still in the team, made the knowledge
# graph 150 lines below stop being able to read that document. The platform was
# working; the instance tier simply had no way OFF, which is what `DELETE` is.
# A smoke block that changes GLOBAL state has to put it back (the last-owner
# lesson, from the other end of the file).
assert "the policy can be dropped entirely" "$(curl -s -X DELETE $B/api/executor-policy -H "Authorization: Bearer $TOK")" '"configured":false'
PU /api/model-roles '{"roles":{"utility":null}}' >/dev/null

# AND THE DOCUMENTS GO WITH IT, which is not tidiness. §8's knowledge graph
# extracts a BOUNDED batch per run, and this block's letter plus the
# classification record it derived displaced the team-visible `inbox/auto/` scans
# out of that batch — so the entity came back with only the private invoice
# mentioning it and carol, who can read only the scans, stopped seeing it. A
# section 250 lines away failing on a VISIBILITY rule, because this one added two
# documents. The suite's own note says it: every new fixture is more model calls
# in the next fan-out.
assert "the block removes its own documents" \
  "$(curl -s -X DELETE "$B/api/repo-obj/$HOBJ?cascade=1" -H "Authorization: Bearer $TOK")" '"deleted"'
# NOT a fourth run here, and the reason is worth the line: with the policy gone
# the labelled document is no longer governed, so a run against `gpu-far` is
# DISPATCHED to a pull executor that has no worker — and waits for ever, which
# reads as a stalled engine. That the drop really ungoverns the document is
# asserted in test/sensitivity-tests.rkt, where there is no queue to hang in.
echo

echo "== 5i. filling a PDF form somebody ELSE wrote (#88 req 2, FORM-1…9) ==========="
# doc_render fills a TEMPLATE this platform's user authored. This fills an
# AcroForm that arrived — the half of #88 with no workaround at all today.
#
# The toolchain is found at CALL time (DWF-6's rule), so a box without pdfcpu is
# a SUPPORTED box and this block skips there, loudly. CI's devShell carries both
# binaries, so the skip cannot hide a regression where it matters.
if ! command -v pdfcpu >/dev/null 2>&1; then
  echo "  skip  no pdfcpu on PATH — the form block needs it (CI's devShell has it)"
else
python3 -I test/make-acroform.py "$TMACH_DATA_DIR/request.pdf"
FOBJ=$(up forms/request.pdf application/pdf "$TMACH_DATA_DIR/request.pdf" | jq_ 'd["id"]')
python3 -I test/make-acroform.py --plain "$TMACH_DATA_DIR/plain.pdf"
FPDF=$(up forms/plain.pdf application/pdf "$TMACH_DATA_DIR/plain.pdf" | jq_ 'd["id"]')
printf 'an ordinary document, not a form\n' > "$TMACH_DATA_DIR/f-plain.txt"
FTXT=$(up forms/plain.txt text/plain "$TMACH_DATA_DIR/f-plain.txt" | jq_ 'd["id"]')

# DISCOVERY FIRST, because a caller cannot send values without it: the names are
# in somebody else's document and nothing else publishes them.
FF=$(G "/api/repo-obj/$FOBJ/form-fields")
assert "the form's text fields are found"   "$FF" '"name":"applicant"'
assert "…with their kind"                   "$FF" '"kind":"textfield"'
assert "…the checkbox too"                  "$FF" '"name":"urgent"'
assert "…and the choice field's options"    "$FF" '"options":["amer","emea","apac"]'
assert "…and whether flattening works here" "$FF" '"can_flatten"'

# A PDF WITH NO FORM IS AN ANSWER, not an error — whether a document is a form is
# exactly the question being asked, and failing here would make every ordinary
# PDF read as a broken server. A document that is not a PDF AT ALL is the other
# case and is a 400: "this is not a form" and "this cannot be read" are two
# different mistakes, and the first version of this block conflated them.
assert "a PDF with no form answers an empty list" \
  "$(G "/api/repo-obj/$FPDF/form-fields")" '"fields":[]'
assert "…while a document that is not a PDF cannot be read at all" \
  "$(G "/api/repo-obj/$FTXT/form-fields")" 'could not be read'

# No route runs a single tool, so the tool is reached through a one-step spec —
# `pdf-form`'s pattern, and for its reason: adding an input to a PUBLISHED spec
# breaks every caller, so this block publishes its own.
FWF='{"spec":1,"slug":"fill-acroform","input":{"object_id":"string","values":"object","flatten":"boolean"},"steps":[
  {"id":"fill","uses":"tool:doc_fill_form","with":{"object":"${input.object_id}","values":"${input.values}",
   "flatten":"${input.flatten}","run":"${run.id}","step":"fill"},"end":true}]}'
assert "the filling spec published" "$(P /api/workflows "$FWF")" '"slug":"fill-acroform"'

FR=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FOBJ\",\"values\":{\"applicant\":\"Arun Patel\",\"reference\":\"ACME-2026-0042\",\"urgent\":true,\"region\":\"apac\"},\"flatten\":false}}")
wait_run "$(printf '%s' "$FR" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "the form is filled"                 "$RUNST" done
assert "…as a document beside the source"   "$RUNJSON" 'forms/request.pdf.filled.pdf'
assert "…typed as a PDF"                    "$RUNJSON" 'application/pdf'
assert "…with nothing left unmatched"       "$RUNJSON" '"unmatched":[]'
assert "…and it says it did not flatten"    "$RUNJSON" '"flattened":false'

# THE VALUES REALLY LANDED, asserted over the DERIVED DOCUMENT's own fields
# rather than over the run's output — which is the only way HTTP can see inside
# the PDF, and it is the discovery endpoint doing the reading.
FILLED=$(G "/api/repo?prefix=forms/request.pdf.filled.pdf" | jq_ 'd["objects"][0]["id"]')
FFF=$(G "/api/repo-obj/$FILLED/form-fields")
assert "the applicant's name is in the field" "$FFF" '"value":"Arun Patel"'
assert "…and the reference"                   "$FFF" 'ACME-2026-0042'
assert "…and the choice moved"                "$FFF" '"value":"apac"'

# A FIELD THE FORM DOES NOT HAVE IS REPORTED, and this is the assertion the
# whole report exists for: pdfcpu takes a name no field carries, writes the
# output and exits 0, so without `unmatched` a misspelled field would hand back
# a document that looks filled with nothing saying which half was ignored.
FR2=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FOBJ\",\"values\":{\"applicant\":\"Lena Mori\",\"middle_name\":\"Q\"},\"flatten\":false}}")
wait_run "$(printf '%s' "$FR2" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a partial match still fills"         "$RUNST" done
assert "…and names what was not on the form" "$RUNJSON" '"unmatched":["middle_name"]'

# …while EVERY name wrong is a refusal rather than a report, because a report is
# no use to somebody addressing the wrong document. The refusal lists the fields
# the form has (CLS-15's shape).
FR3=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FOBJ\",\"values\":{\"nope\":\"x\"},\"flatten\":false}}")
wait_run "$(printf '%s' "$FR3" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "every field wrong is refused"        "$RUNST" error
assert "…and the refusal lists the real ones" "$RUNJSON" 'applicant'

# A choice field's options are known, so a value outside them is a typo this
# tool can see — and must not write: a /V the form's own reader cannot interpret
# renders blank while the document claims it was filled.
FR4=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FOBJ\",\"values\":{\"region\":\"antarctica\"},\"flatten\":false}}")
wait_run "$(printf '%s' "$FR4" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a value outside a field's options is refused" "$RUNST" error
assert "…and the refusal names the options"           "$RUNJSON" 'amer, emea, apac'

# THE ISSUE'S ACCEPTANCE CRITERION, both halves: flattened, and the unmatched
# list empty. "No fields any more" is what flattened MEANS to everything
# downstream; that the values survived into the page content is asserted in
# test/pdfform-tests.rkt, which can decompress the stream.
if command -v qpdf >/dev/null 2>&1; then
  FR5=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FOBJ\",\"values\":{\"applicant\":\"Arun Patel\",\"reference\":\"ACME-2026-0042\"},\"flatten\":true}}")
  wait_run "$(printf '%s' "$FR5" | grep -oP '"id":"\K[^"]+' | head -1)"
  assert "a flattened fill succeeds"        "$RUNST" done
  assert "…and says so"                     "$RUNJSON" '"flattened":true'
  assert "…with nothing unmatched"          "$RUNJSON" '"unmatched":[]'
  FLAT=$(G "/api/repo?prefix=forms/request.pdf.filled.pdf" | jq_ 'd["objects"][0]["id"]')
  assert "the flattened document has no editable fields" \
    "$(G "/api/repo-obj/$FLAT/form-fields")" '"fields":[]'
else
  echo "  skip  no qpdf on PATH — the flatten assertions need it"
fi

# A form is a PDF, and refusing by CONTENT TYPE rather than letting the engine
# report "no AcroForm fields" is the difference between "this is the wrong
# document" and "this document has no form" — two different mistakes.
FR6=$(P /api/workflows/fill-acroform/run "{\"input\":{\"object_id\":\"$FTXT\",\"values\":{\"applicant\":\"x\"},\"flatten\":false}}")
wait_run "$(printf '%s' "$FR6" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a document that is not a PDF is refused" "$RUNST" error
assert "…and the refusal says why"               "$RUNJSON" 'not a PDF'

# THE BLOCK REMOVES ITS OWN DOCUMENTS. §8's knowledge graph extracts a BOUNDED
# batch per run, and §5h's two leftovers once displaced the team-visible scans
# out of it — a visibility assertion 250 lines away failing because this section
# added documents. Three here (the form and two fills, versioned under one key),
# so the cascade is not optional.
assert "the block removes its own documents" \
  "$(curl -s -X DELETE "$B/api/repo-obj/$FOBJ?cascade=1" -H "Authorization: Bearer $TOK")" '"deleted"'
curl -s -X DELETE "$B/api/repo-obj/$FTXT?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
curl -s -X DELETE "$B/api/repo-obj/$FPDF?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
fi
echo

echo "== 5j. a branded, paged document out of HTML and CSS (#88 req 1, HPDF-1…8) ====="
# The documents a downstream customer actually receives: a logo, a table whose
# cells wrap, and "Page X of Y" — all of it the TEMPLATE's own CSS. The LaTeX
# path (DWF-6) renders text well and expresses none of that.
#
# Found at CALL time, so a box without weasyprint is a SUPPORTED box and this
# block asserts the named refusal there instead of skipping silently.
cat > "$TMACH_DATA_DIR/logo.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#334455"/></svg>
SVG
WLOGO=$(up brand/logo.svg image/svg+xml "$TMACH_DATA_DIR/logo.svg" | jq_ 'd["id"]')

# The template is a repository document, versioned and access-controlled, which
# is requirement 4 — and the logo is reached BY OBJECT ID, which is requirement
# 1's "images from repo objects by id". A scheme rather than a path, because
# every reference has to be resolvable BEFORE anything runs: each one is read as
# the caller and inlined, and then the renderer is allowed to fetch nothing else.
python3 - "$TMACH_DATA_DIR/report.html" "$WLOGO" <<'PY'
import sys
path, logo = sys.argv[1], sys.argv[2]
rows = "".join(
    "<tr><td>SKU-%04d</td><td class='wrap'>A deliberately long description that has to wrap "
    "inside its cell several times over, so the row grows taller than one line and the table "
    "has to break across a page boundary. Row %d.</td><td>%d.00</td></tr>" % (i, i, i * 7)
    for i in range(1, 41))
open(path, "w").write("""<!doctype html><html><head><meta charset="utf-8">
<title>{{title}}</title><meta name="author" content="{{author}}">
<style>
@page { size: A4; margin: 2.2cm 2cm 2.4cm 2cm;
  @top-left { content: element(brandhdr); }
  @bottom-center { content: "Page " counter(page) " of " counter(pages); font: 9pt sans-serif; } }
#brandhdr { position: running(brandhdr); font: 10pt sans-serif; }
body { font: 10.5pt/1.45 serif; }
table { width: 100%%; border-collapse: collapse; }
th, td { border: 1px solid #bbb; padding: 4pt 6pt; vertical-align: top; text-align: left; }
td.wrap { width: 55%%; }
</style></head><body>
<div id="brandhdr"><img src="repo:%s" width="16" height="16"> {{author}}</div>
<h1>{{title}}</h1>
<table><thead><tr><th>Item</th><th class="wrap">Description</th><th>Amount</th></tr></thead>
<tbody>%s</tbody></table></body></html>
""" % (logo, rows))
PY
WTPL=$(up templates/report.html text/html "$TMACH_DATA_DIR/report.html" | jq_ 'd["id"]')
printf 'the source this report is about\n' > "$TMACH_DATA_DIR/w-src.txt"
WSRC=$(up wk/source.txt text/plain "$TMACH_DATA_DIR/w-src.txt" | jq_ 'd["id"]')

WWF='{"spec":1,"slug":"brand-report","input":{"object_id":"string","template":"string","engine":"string","variant":"string"},"steps":[
  {"id":"doc","uses":"tool:doc_render","with":{"template":"${input.template}","object":"${input.object_id}",
   "format":"pdf","engine":"${input.engine}","pdf_variant":"${input.variant}",
   "data":{"title":"Acme Service Report","author":"Acme Operations"},
   "run":"${run.id}","step":"doc"},"end":true}]}'
assert "the branded-report spec published" "$(P /api/workflows "$WWF")" '"slug":"brand-report"'

WR=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WTPL\",\"engine\":\"weasyprint\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$WR" | grep -oP '"id":"\K[^"]+' | head -1)"

if ! command -v weasyprint >/dev/null 2>&1; then
  assert "with no engine on PATH the one call is refused by name" "$RUNJSON" 'needs weasyprint'
else
  assert "the branded report renders"        "$RUNST" done
  assert "…as a PDF beside the source"       "$RUNJSON" 'wk/source.txt.form.pdf'
  assert "…and says which engine answered"   "$RUNJSON" '"engine":"weasyprint"'
  WLIST=$(G "/api/repo?prefix=wk/source.txt.form.pdf")
  assert "…typed as a PDF"                   "$WLIST" '"content_type":"application/pdf"'
  WPID=$(printf '%s' "$WLIST" | jq_ 'd["objects"][0]["id"]')
  curl -s "$B/api/repo-obj/$WPID/content" -H "Authorization: Bearer $TOK" -o "$TMACH_DATA_DIR/report.pdf"
  assert "it really is a PDF"                "$(head -c 4 "$TMACH_DATA_DIR/report.pdf")" '%PDF'
  if command -v pdftotext >/dev/null 2>&1; then
    WTXT=$(pdftotext "$TMACH_DATA_DIR/report.pdf" - | tr -s '[:space:]' ' ')
    # THE ACCEPTANCE CRITERION, over HTTP: the data reached the template, the
    # table broke across pages, the running header repeats, and the page TOTAL is
    # right — `counter(pages)`, which is the thing the LaTeX path and Chromium
    # headless both cannot express.
    assert "the data reached the template"     "$WTXT" 'Acme Service Report'
    assert "…the table ran past one page"      "$WTXT" 'Page 2 of'
    assert "…the last row is there"            "$WTXT" 'Row 40'
    assert "…and the long cells wrapped"       "$WTXT" 'wrap inside its cell'
    differ "the page total is not one page" "$(printf '%s' "$WTXT" | grep -o 'Page 1 of [0-9]*' | head -1)" "Page 1 of 1"
  fi

  # ARCHIVAL OUTPUT. The variant is a closed vocabulary of ONE, because one is
  # what was put through a validator — veraPDF 1.30.2, 144 rules passed, on this
  # same document with its SVG logo. A raster logo fails clause 6.2.8 (the engine
  # marks images Interpolate true), which is why the fixture's logo is vector.
  WR2=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WTPL\",\"engine\":\"weasyprint\",\"variant\":\"pdf/a-2b\"}}")
  wait_run "$(printf '%s' "$WR2" | grep -oP '"id":"\K[^"]+' | head -1)"
  assert "an archival render succeeds"       "$RUNST" done
  assert "…and reports the variant"          "$RUNJSON" '"pdf_variant":"pdf/a-2b"'

  WR3=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WTPL\",\"engine\":\"weasyprint\",\"variant\":\"pdf/x-4\"}}")
  wait_run "$(printf '%s' "$WR3" | grep -oP '"id":"\K[^"]+' | head -1)"
  assert "a variant nobody validated is refused" "$RUNST" error
  assert "…and the refusal lists what is offered" "$RUNJSON" 'pdf/a-2b'

  # THE SANDBOX, over HTTP. weasyprint logs a resource it refused and EXITS 0, so
  # without reading its log this would hand a customer a report with a hole where
  # the logo was. A template may reach a repository document by id and nothing
  # else — no network, no local file.
  python3 - "$TMACH_DATA_DIR/evil.html" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '<!doctype html><html><head><meta charset="utf-8"><title>{{title}}</title></head>'
    '<body><img src="file:///etc/hosts" alt="local"><p>{{title}}</p></body></html>\n')
PY
  WEVIL=$(up templates/evil.html text/html "$TMACH_DATA_DIR/evil.html" | jq_ 'd["id"]')
  WR4=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WEVIL\",\"engine\":\"weasyprint\",\"variant\":\"\"}}")
  wait_run "$(printf '%s' "$WR4" | grep -oP '"id":"\K[^"]+' | head -1)"
  assert "a template reaching a local file is refused"  "$RUNST" error
  assert "…and the refusal says what a template may reach" "$RUNJSON" 'repo:<object id>'
  refute "…without quoting the file it wanted"          "$RUNJSON" 'root:'

  # AND THE HALF ONLY HTTP CAN ASSERT: each reference is read AS THE CALLER, so a
  # template cannot inline a document the RUNNER may not read. A template that
  # could reach any object by id would be a way straight past the repository's
  # own gate, since a template is data somebody else may have authored.
  #
  # THE RUNNER HAS TO BE BOB, and the first version of this case got it wrong:
  # it made the document bob's and ran as alice, who is the BOOTSTRAP OPERATOR —
  # and an operator passes everything team-tier, so the private document really
  # was read, exactly as designed, and the case failed against correct code. The
  # subject is alice's private document now and the run is bob's, a plain member.
  printf 'ALICEONLYNEEDLE kept private\n' > "$TMACH_DATA_DIR/w-priv.txt"
  WPRIV=$(curl -s -X PUT "$B/api/repo/alices/private.txt?visibility=private" \
            -H "Authorization: Bearer $TOK" -H "Content-Type: text/plain" \
            --data-binary @"$TMACH_DATA_DIR/w-priv.txt" | jq_ 'd["id"]')
  assert "alice's document really is private" \
    "$(G "/api/repo-obj/$WPRIV")" '"visibility":"private"'
  refute "…and bob cannot read it directly" \
    "$(curl -s "$B/api/repo-obj/$WPRIV/content" -H "Authorization: Bearer $BOB")" 'ALICEONLYNEEDLE'
  python3 - "$TMACH_DATA_DIR/peek.html" "$WPRIV" <<'PY'
import sys
open(sys.argv[1], "w").write(
    '<!doctype html><html><head><meta charset="utf-8"><title>{{title}}</title></head>'
    '<body><img src="repo:%s"><p>{{title}}</p></body></html>\n' % sys.argv[2])
PY
  WPEEK=$(up templates/peek.html text/html "$TMACH_DATA_DIR/peek.html" | jq_ 'd["id"]')
  WR5=$(curl -s -X POST "$B/api/workflows/brand-report/run" -H "Authorization: Bearer $BOB" \
          -d "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WPEEK\",\"engine\":\"weasyprint\",\"variant\":\"\"}}")
  wait_run "$(printf '%s' "$WR5" | grep -oP '"id":"\K[^"]+' | head -1)"
  assert "a template cannot inline a document the runner may not read" "$RUNST" error
  assert "…and says so by id, not by content" "$RUNJSON" 'not a document you can read'
  refute "…quoting none of it"                "$RUNJSON" 'ALICEONLYNEEDLE'
  # A `refute` FOR A PLAINTEXT AGAINST AN INLINED DOCUMENT PASSES VACUOUSLY, and
  # that is how the first version of this case hid its own failure: the engine
  # HAD read the private document and base64'd it into the HTML, and the refusal
  # quoted the data: URI — so the needle was right there, encoded, and the
  # refutation was green. Refute the ENCODED form beside the plain one.
  WB64=$(python3 -c 'import base64,sys;print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$TMACH_DATA_DIR/w-priv.txt")
  refute "…nor a base64 copy of it"           "$RUNJSON" "$WB64"
  curl -s -X DELETE "$B/api/repo-obj/$WPRIV?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
fi

# THE REFUSALS THAT NEED NO ENGINE, so they are asserted either way: the HTML
# engine needs an HTML template (its whole point is the template's own @page CSS,
# which Markdown does not carry), and the two knobs belong to a format and an
# engine respectively.
WR6=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"templates/approval.md\",\"engine\":\"weasyprint\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$WR6" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "a Markdown template is refused by the HTML engine" "$RUNST" error
assert "…and the refusal says why"                         "$RUNJSON" 'needs an HTML template'

WR7=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$WSRC\",\"template\":\"$WTPL\",\"engine\":\"netscape\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$WR7" | grep -oP '"id":"\K[^"]+' | head -1)"
assert "an unknown engine is refused"        "$RUNST" error
assert "…listing the ones there are"         "$RUNJSON" 'latex, weasyprint'

# THE BLOCK REMOVES ITS OWN DOCUMENTS, and leaving two behind is how this block
# first failed — §8's knowledge graph extracts a BOUNDED batch per run, so the
# two leftover templates displaced the team-visible `inbox/auto/` scans out of
# it and carol stopped being able to see Acme: a VISIBILITY assertion 60 lines
# away failing because this section added documents. §5h paid for the same
# lesson; every name below is one somebody forgot once.
for id in "$WTPL" "$WSRC" "$WLOGO" "$WEVIL" "$WPEEK"; do
  [ -n "$id" ] || continue
  curl -s -X DELETE "$B/api/repo-obj/$id?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
done
assert "the block removed its own documents" \
  "$(G "/api/repo?prefix=wk/source.txt")" '"objects":[]'
echo

echo "== 5k. a filled DOCX, converted to PDF (#88 req 3, OFFICE-1…5) ================"
# `doc_render` has filled DOCX templates since slice 59 and REFUSED to turn one
# into a PDF ever since, because LibreOffice is not a dependency this platform
# takes on. That refusal is still the DEFAULT; `engine: "libreoffice"` is how an
# integrator who installed it says so.
#
# Most of this block runs EVERYWHERE, and that is the point of checking the input
# before the binary: the external-reference refusal is the only sandbox this
# engine can have, and it is exercised on a box where LibreOffice cannot be
# installed at all — which includes this project's own development platform.
python3 - "$TMACH_DATA_DIR/office.docx" <<'PY'
import sys, zipfile
xml = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
       '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
       '<w:body><w:p><w:r><w:t>Service report: {{title}}</w:t></w:r></w:p>'
       '<w:p><w:r><w:t>For: {{author}}</w:t></w:r></w:p></w:body></w:document>')
types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
         '<Default Extension="xml" ContentType="application/xml"/>'
         '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
         '</Types>')
root = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>')
def rels(external):
    extra = ''
    if external:
        extra = ('<Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
                 'Target="%s" TargetMode="External"/>' % external)
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + extra + '</Relationships>')
def write(path, external=None):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('[Content_Types].xml', types)
        z.writestr('_rels/.rels', root)
        z.writestr('word/document.xml', xml)
        z.writestr('word/_rels/document.xml.rels', rels(external))
write(sys.argv[1])
write(sys.argv[1].replace('.docx', '-linked.docx'), 'https://cdn.example/logo.png')
PY
ODOCX_CT='application/vnd.openxmlformats-officedocument.wordprocessingml.document'
OTPL=$(up templates/office.docx "$ODOCX_CT" "$TMACH_DATA_DIR/office.docx" | jq_ 'd["id"]')
OLINK=$(up templates/office-linked.docx "$ODOCX_CT" "$TMACH_DATA_DIR/office-linked.docx" | jq_ 'd["id"]')
printf 'the source this office report is about\n' > "$TMACH_DATA_DIR/o-src.txt"
OSRC=$(up office/source.txt text/plain "$TMACH_DATA_DIR/o-src.txt" | jq_ 'd["id"]')
# §5j removes its own HTML template, so this block uploads the one it needs for
# the wrong-template refusal rather than reaching for a dangling id — which
# would fail the assertion for "no such template" instead of for the engine.
printf '<!doctype html><html><head><meta charset="utf-8"><title>{{title}}</title></head><body><p>{{author}}</p></body></html>\n' > "$TMACH_DATA_DIR/o-tpl.html"
OHTML=$(up templates/office-wrong.html text/html "$TMACH_DATA_DIR/o-tpl.html" | jq_ 'd["id"]')

# `brand-report` (published in 5j) already passes template, engine and
# pdf_variant through to doc_render — reused rather than published again, which
# is the point of having declared those as inputs.
OR=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$OSRC\",\"template\":\"$OTPL\",\"engine\":\"libreoffice\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$OR" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
if command -v soffice >/dev/null 2>&1 || command -v libreoffice >/dev/null 2>&1; then
  assert "the DOCX becomes a PDF"             "$RUNST" done
  assert "…beside the source"                 "$RUNJSON" 'office/source.txt.form.pdf'
  assert "…and says which engine answered"    "$RUNJSON" '"engine":"libreoffice"'
  OLIST=$(G "/api/repo?prefix=office/source.txt.form.pdf")
  assert "…typed as a PDF"                    "$OLIST" '"content_type":"application/pdf"'
  OPID=$(printf '%s' "$OLIST" | jq_ 'd["objects"][0]["id"]')
  curl -s "$B/api/repo-obj/$OPID/content" -H "Authorization: Bearer $TOK" -o "$TMACH_DATA_DIR/office.pdf"
  assert "it really is a PDF"                 "$(head -c 4 "$TMACH_DATA_DIR/office.pdf")" '%PDF'
  if command -v pdftotext >/dev/null 2>&1; then
    # a converter that wrote a blank page of the right size would pass every
    # assertion above, so the TEMPLATE's own filled text is what is asserted
    assert "the filled text survived the conversion" \
      "$(pdftotext "$TMACH_DATA_DIR/office.pdf" - | tr -s '[:space:]' ' ')" 'Service report: Acme Service Report'
  fi
else
  # OFF UNLESS INSTALLED, and the message has to say where it is meant to come
  # from — the OCR plugin's rule, where "enabled with nothing on PATH" was once a
  # silent failure.
  assert "with no LibreOffice the one call is refused by name" "$RUNJSON" 'needs LibreOffice'
  assert "…and says where it belongs"                          "$RUNJSON" 'extraPath'
fi

# THE ONLY SANDBOX THIS ENGINE CAN HAVE, and it runs everywhere. WeasyPrint takes
# `--allowed-protocols data` and refuses a fetch by name; soffice has no such
# flag and no argument will give it one, so the constraint is applied to the
# INPUT: a template that DECLARES an external relationship — how Word stores a
# linked image — is refused before anything is converted.
OR2=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$OSRC\",\"template\":\"$OLINK\",\"engine\":\"libreoffice\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$OR2" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
assert "a template with an external reference is refused"  "$RUNST" error
assert "…naming the reference"                             "$RUNJSON" 'cdn.example'
assert "…and what to do instead"                           "$RUNJSON" 'Embed the image'

# The DEFAULT is unchanged: a DOCX template and format pdf with NO engine is the
# refusal slice 59 shipped — and it now names the way through rather than just
# the wall.
OR3=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$OSRC\",\"template\":\"$OTPL\",\"engine\":\"\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$OR3" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
assert "a DOCX with no engine is still refused"  "$RUNST" error
assert "…and the refusal names the way through"  "$RUNJSON" 'converted to PDF only by the libreoffice engine'

# …and the engine needs a DOCX, the mirror of the HTML engine needing HTML.
OR4=$(P /api/workflows/brand-report/run "{\"input\":{\"object_id\":\"$OSRC\",\"template\":\"$OHTML\",\"engine\":\"libreoffice\",\"variant\":\"\"}}")
wait_run "$(printf '%s' "$OR4" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
assert "the libreoffice engine refuses a non-DOCX template" "$RUNST" error
assert "…saying what it needs"                              "$RUNJSON" 'needs a DOCX template'

# The block removes its own documents (§5h's and §5j's lesson).
for id in "$OTPL" "$OLINK" "$OSRC" "$OHTML"; do
  [ -n "$id" ] || continue
  curl -s -X DELETE "$B/api/repo-obj/$id?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
done
assert "the block removed its own documents" "$(G "/api/repo?prefix=office/source.txt")" '"objects":[]'
echo

echo "== 5l. the feed work queue, and a proposal that does not act (#114 slices 5-6) =="
# A PLUGIN, not a core console tab — the owner's call on #114 question 2. So
# everything here rides seams that shipped: a plugin migration (#121), plugin
# routes (slice 63) and a bundle page (#20, #43).
assert "the feeds plugin loaded"            "$(G /api/plugins)" '"id":"feeds"'
refute "…with nothing failing"              "$(G /api/plugins)" '"plugin":"feeds"'
assert "…declaring its own table"           "$(G /api/plugins)" '"migrations"'
assert "its queue workflow arrived"         "$(G /api/workflows)" '"slug":"feed-triage"'
assert "…and its proposal workflow"         "$(G /api/workflows)" '"slug":"feed-propose"'
assert "its tools are registered"           "$(G /api/tools)" '"name":"feed_queue_put"'

# An item shaped the way poll.rkt writes one: JSON under feeds/<slug>/.
printf '{"title":"flaky webhook test","number":41}\n' > "$TMACH_DATA_DIR/q-a.json"
printf '{"title":"certificate expiring","number":42}\n' > "$TMACH_DATA_DIR/q-b.json"
QA=$(up feeds/gh/acme-repo-41.json application/json "$TMACH_DATA_DIR/q-a.json" | jq_ 'd["id"]')
QB=$(up feeds/gh/acme-repo-42.json application/json "$TMACH_DATA_DIR/q-b.json" | jq_ 'd["id"]')

# THE QUEUE IS AN INDEX, NOT A POLICY: the priority, the due date and the skills
# are the caller's — a plugin that read "critical" out of somebody's GitHub label
# would be guessing at their conventions and would be wrong quietly.
QR=$(P /api/workflows/feed-triage/run "{\"input\":{\"object_id\":\"$QA\",\"priority\":30,\"due\":0,\"skills\":[\"ops\"]}}")
wait_run "$(printf '%s' "$QR" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
assert "triage put the first item on the queue" "$RUNST" done
QR2=$(P /api/workflows/feed-triage/run "{\"input\":{\"object_id\":\"$QB\",\"priority\":90,\"due\":1000000000,\"skills\":[\"Racket\",\"ops\"]}}")
wait_run "$(printf '%s' "$QR2" | grep -oP '\"id\":\"\K[^\"]+' | head -1)"
assert "…and the second"                       "$RUNST" done

QQ=$(G /api/x/feeds/queue)
assert "the queue serves both items"        "$QQ" 'acme-repo-41.json'
assert "…ranked, highest priority first"    "$(printf '%s' "$QQ" | jq_ 'd["items"][0]["key"]')" 'feeds/gh/acme-repo-42.json'
assert "…reporting its own ordering"        "$QQ" '"order":"priority DESC'
assert "…and the statuses it has"           "$QQ" '"statuses":["open","claimed","done","dropped"]'
assert "…with the skills normalized"        "$QQ" '"skills":["racket","ops"]'

# The skill filter means ONE skill: the delimiting commas are what stop `racket`
# matching `racketeering`, and the LIKE wildcards are what make it a filter at
# all — the unit suite found that one by failing.
assert "a skill filter narrows"             "$(G '/api/x/feeds/queue?skill=racket')" 'acme-repo-42'
refute "…to the items that carry it"        "$(G '/api/x/feeds/queue?skill=racket')" 'acme-repo-41'
assert "an unknown skill matches nothing"   "$(G '/api/x/feeds/queue?skill=welding')" '"count":0'

# The one write a person does from the screen.
assert "an item can be claimed" "$(P "/api/x/feeds/items/$QA/status" '{"status":"claimed"}')" '"status":"claimed"'
assert "…and the listing shows it"          "$(G /api/x/feeds/queue)" '"status":"claimed"'
assert "a status outside the vocabulary is refused" \
  "$(P "/api/x/feeds/items/$QA/status" '{"status":"urgent"}')" 'unknown status'
assert "…listing the ones there are"        "$(P "/api/x/feeds/items/$QA/status" '{"status":"urgent"}')" 'open, claimed, done, dropped'
# `done` leaves the actionable set, which is what makes the default listing useful
assert "marking it done"                    "$(P "/api/x/feeds/items/$QA/status" '{"status":"done"}')" '"status":"done"'
refute "…takes it out of the actionable queue" "$(G /api/x/feeds/queue)" 'acme-repo-41'
assert "…and ?status=all still shows it"    "$(G '/api/x/feeds/queue?status=all')" 'acme-repo-41'

# The screen itself: served to a signed-in caller, refused without a bearer.
assert "the queue screen is served"   "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/feeds/bundle/index.html" -H "Authorization: Bearer $TOK")" '200'
assert "…and not without a token"     "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/x/feeds/bundle/index.html")" '401'

# ---- slice 6: the proposal, and the gate ---------------------------------------
# FEED-10, confirmed by the owner on #114 question 3: the agent PROPOSES and a
# review step gates anything that would act.
if [ $LIVE = 0 ]; then
  python3 -c 'import json,sys
p=sys.argv[1]
try:  d=json.load(open(p))
except Exception:  d={}
d["You triage work items"]="## What this is\nA flaky webhook test.\n\n## Proposed action\nRe-run the job once, then close it.\n\n## Why this and not something else\nA re-run that goes green is cheap."
json.dump(d,open(p,"w"))' "$MOCK_REPLY_FILE"
fi

PR=$(P /api/workflows/feed-propose/run "{\"input\":{\"object_id\":\"$QB\"}}")
PRID=$(printf '%s' "$PR" | jq_ 'd["id"]')
RUNID="$PRID"; wait_park "$PRID"
# THE RUN PARKS ON A PERSON. A `review` step writes no job, so a parked run holds
# no concurrency slot however long the specialist takes (LAY-1).
assert "the proposal run parks rather than finishing" "$(G /api/runs/$PRID)" '"status":"waiting"'
assert "…and the proposal is a document beside the item" \
  "$(G '/api/repo?prefix=feeds/gh/acme-repo-42.json.proposal.md')" 'acme-repo-42.json.proposal.md'
PDOC=$(G '/api/repo?prefix=feeds/gh/acme-repo-42.json.proposal.md' | jq_ 'd["objects"][0]["id"]')
PTXT=$(curl -s "$B/api/repo-obj/$PDOC/content" -H "Authorization: Bearer $TOK")
assert "…carrying what the model proposed"  "$PTXT" 'Re-run the job once'
# The standing warning is in the DOCUMENT, because the person reading it in a
# month has no other way to know it was never carried out.
assert "…and saying plainly that nothing was done" "$PTXT" 'A PROPOSAL, not an action'

assert "a person is asked to decide"        "$(G /api/reviews)" '"step_id":"decide"'
assert "…with the question in their queue"  "$(G /api/reviews)" 'Should we do what this proposal says'
assert "…and the instructions saying nothing will happen automatically" \
  "$(G /api/reviews)" 'nothing will happen automatically'

# NOTHING ACTED, and that is the assertion the whole slice exists for: the queue
# is exactly as it was before the proposal run, and no new document appeared
# beyond the proposal itself.
refute "the proposal did not move the item on the queue" "$(G '/api/x/feeds/queue?status=all')" '"status":"dropped"'
assert "…which is still where triage left it"           "$(G '/api/x/feeds/queue?status=all')" '"priority":90'

# AND EVERY VERDICT ENDS THE RUN, because v1 has nothing that acts. When an
# acting tool exists it goes on the approve branch and nowhere else.
decide "$(pending_id)" '{"verdict":"approve","rationale":"yes, re-run it","answers":{"plan":"re-run then close"}}'
assert "an approval ends the run"           "$(G /api/runs/$PRID)" '"status":"done"'
assert "the review queue is empty again"    "$(G /api/reviews)" '"reviews":[]'
# LAY-11: the decision is in the chain, which is what makes "who approved this"
# answerable later rather than a matter of trust.
assert "the decision is in the review chain" "$(G /api/reviews/verify)" '"ok":true'

# The block removes its own documents (§5h's, §5j's and §5k's lesson).
for id in "$QA" "$QB"; do
  [ -n "$id" ] || continue
  curl -s -X DELETE "$B/api/repo-obj/$id?cascade=1" -H "Authorization: Bearer $TOK" >/dev/null
done
assert "the block removed its own documents" "$(G '/api/repo?prefix=feeds/gh/')" '"objects":[]'
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
printf 'INVOICE\nAcme Corp\nWidgets 1000\nShipping 250.50\nTotal 1250.50\n' > "$TMACH_DATA_DIR/auto.txt"
AUTO=$(curl -s -X PUT "$B/api/repo/inbox/auto/scan-001.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/auto.txt")
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
curl -s -X PUT "$B/api/repo/inbox/manual/x.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/auto.txt" >/dev/null
curl -s -X PUT "$B/api/repo/inbox/auto/pic.png" -H "Authorization: Bearer $BOB" -H 'Content-Type: image/png' --data-binary @"$TMACH_DATA_DIR/auto.txt" >/dev/null
assert "still one fire" "$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["fires"]))')" "1"
# disable, upload, nothing; enable again
assert "disabled" "$(curl -s -X PATCH "$B/api/doc-triggers/$TID" -H "Authorization: Bearer $TOK" -d '{"enabled":false}')" '"enabled":false'
curl -s -X PUT "$B/api/repo/inbox/auto/scan-002.txt" -H "Authorization: Bearer $BOB" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/auto.txt" >/dev/null
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

printf 'INVOICE 9002\nAcme Corp\nTotal due 42.00\n' > "$TMACH_DATA_DIR/t-inv.txt"
printf 'Dear Ms Smith,\n\nRegards,\nAcme\n' > "$TMACH_DATA_DIR/t-let.txt"
TINV=$(up typed/a.txt text/plain "$TMACH_DATA_DIR/t-inv.txt" | jq_ 'd["id"]')
TLET=$(up typed/b.txt text/plain "$TMACH_DATA_DIR/t-let.txt" | jq_ 'd["id"]')
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
up typed/a.txt text/plain "$TMACH_DATA_DIR/t-inv.txt" >/dev/null
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
  aws --endpoint-url "$E" s3 cp "$TMACH_DATA_DIR/auto.txt" "s3://$BUCKET/inbox/auto/scan-s3-a.txt" --content-type text/plain >/dev/null 2>&1
  F1=$(G "/api/doc-triggers/$TID" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(((f["error"] or "") for f in d["fires"] if f["key"]=="inbox/auto/scan-s3-a.txt"),""))')
  assert "S3 PUT with a files-only key: recorded, not run" "$F1" 'workflows:run'
  # a key issued with workflows:run fires the run
  CRED2=$(P /api/s3/credentials '{"name":"pipeline","scopes":["files:read","files:write","files:delete","workflows:read","workflows:run"]}')
  export AWS_ACCESS_KEY_ID=$(printf '%s' "$CRED2" | jq_ 'd["access_key_id"]')
  export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CRED2" | jq_ 'd["secret_access_key"]')
  aws --endpoint-url "$E" s3 cp "$TMACH_DATA_DIR/auto.txt" "s3://$BUCKET/inbox/auto/scan-s3-b.txt" --content-type text/plain >/dev/null 2>&1
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


# IT IS THE LAST SECTION, AND IT WAS 5m FIRST. That move is the file's own
# recorded lesson — a smoke fixture that changes GLOBAL state breaks a distant
# block — and this one broke the knowledge-graph block 250 lines below it: this
# section DRAINS `index-documents`, so many more documents carry extracted text
# than before, and the KG extraction's own batch then spreads over a different
# set. What failed was "carol sees Acme too", in a block with nothing to do with
# retrieval. Draining is the right thing for this section to do and perturbing
# everything after it is not, so it goes last.
echo "== 8. retrieval: a question answered from the team's own documents (#189 step 6) ="
# THE ONLY PLACE THE EMBEDDING WIRE IS DRIVEN END TO END. Every unit test of
# #189 scripts `current-doc-embed`, which is the right trade for a suite that
# must not need `nomic-embed-text` — and it means `embed-exchange`'s own HTTP
# path, the request log's `operation: "embed"` row and the whole chain from a
# question to a cited passage are exercised HERE and nowhere else. #187's
# lesson: a path nothing drives end to end is where a defect lives undisturbed.
#
# The mock's vector is a bag of words, so "closest in meaning" degenerates to
# "shares the most words" — crude, deterministic, and enough to assert that a
# question about cephalopods retrieves the octopus document and not the bridge
# one. It is NOT a recall measurement; that is step 3's calibration and wants a
# live embedder, in English and Japanese.
if [ $LIVE = 0 ]; then
  printf 'Octopuses are cephalopods with eight arms and remarkable problem solving.\n' > "$TMACH_DATA_DIR/octo.txt"
  printf 'Suspension bridges carry their deck on cables hung between tall towers.\n' > "$TMACH_DATA_DIR/bridge.txt"
  OCTO=$(curl -s -X PUT "$B/api/repo/kb/octopuses.txt" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/octo.txt")
  OCTOID=$(printf '%s' "$OCTO" | jq_ 'd["id"]')
  curl -s -X PUT "$B/api/repo/kb/bridges.txt" -H "Authorization: Bearer $TOK" -H 'Content-Type: text/plain' --data-binary @"$TMACH_DATA_DIR/bridge.txt" >/dev/null
  assert "the knowledge-base documents uploaded" "$OCTO" '"key":"kb/octopuses.txt"'
  assert "the retrieval tool is registered"      "$(G /api/tools)" '"name":"repo_retrieve"'
  assert "the Embed Documents workflow arrived"  "$(G /api/workflows)" '"slug":"embed-documents"'

  # ?semantic=1 BEFORE anything is embedded: the half runs and matches nothing,
  # which must NOT be reported as unavailable (that is the difference between
  # "I looked and found none" and "I did not look").
  EARLY=$(G "/api/search?q=cephalopods&semantic=1")
  assert "semantic ran before any embedding" "$EARLY" '"semantic":true'
  refute "...and claimed no reason for it"   "$EARLY" '"semantic_reason"'
  refute "...and returned no passage yet"    "$EARLY" '"type":"passage"'

  # index, then embed — two workflows, because a step that errors fails the run
  # and `repo_embed_chunks` refuses with no endpoint on every instance today
  # (VEC-24). The order is load-bearing: the vectors are of the EXTRACTED text.
  #
  # BOTH WORKFLOWS ARE DRAINED, and finding that out cost a red run worth
  # recording: by this point the suite holds well over twenty-five documents —
  # every section above has left derived `.classification.json`, `.extracted.json`
  # and `.form.md` objects behind — and both listers are bounded (`LIST-BATCH` 40,
  # `EMBED-BATCH` 25) and ordered `updated_at ASC`, i.e. OLDEST FIRST. So the two
  # documents uploaded a moment ago are at the BACK of the queue and a single run
  # of each does not reach them. What that looked like was not an obvious cap but
  # a retrieval returning plausible, badly-ranked passages from other sections'
  # fixtures: the right answer was simply not in the index. Re-running until it
  # finds nothing is what the workflow is FOR (VEC-23: the drain has to
  # terminate), so draining is also the assertion.
  for i in 1 2 3 4 5 6; do
    RIX=$(P /api/workflows/index-documents/run '{"input":{}}')
    wait_run "$(printf '%s' "$RIX" | grep -oP '"id":"\K[^"]+' | head -1)"
    [ "$RUNST" = done ] || break
    printf '%s' "$RUNJSON" | grep -q '"result":\[\]' && break
  done
  assert "index-documents drained" "$RUNST" "done"
  for i in 1 2 3 4 5 6; do
    REMB=$(P /api/workflows/embed-documents/run '{"input":{}}')
    wait_run "$(printf '%s' "$REMB" | grep -oP '"id":"\K[^"]+' | head -1)"
    EST="$RUNST"
    [ "$EST" = done ] || { EST="$EST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"; break; }
    # the LAST run of a drain is by definition the one that found nothing, so
    # what it reports is "no documents" — keep the last run that did the work
    printf '%s' "$RUNJSON" | grep -q '"result":\[\]' && break
    EMBJSON="$RUNJSON"
  done
  assert "embed-documents drained"   "$EST" "done"
  assert "...and said what it stored" "$EMBJSON" "chunk vector"
  # VEC-23: the drain TERMINATES. A document whose extracted text is blank can
  # never acquire a vector row, so without the lister's blank filter it would be
  # offered by every run for ever and this loop would never see an empty find.
  assert "...and the last run found nothing left" "$RUNJSON" '"result":[]'

  # the whole point: a question in words the document does not contain verbatim
  SEM=$(G "/api/search?q=cephalopods%20with%20arms&semantic=1")
  assert "a passage came back"            "$SEM" '"type":"passage"'
  assert "...from the octopus document"   "$SEM" '"title":"kb/octopuses.txt"'
  assert "...carrying the object it cites" "$SEM" "\"object_id\":\"$OCTOID\""
  assert "...and the offsets to cite it"  "$SEM" '"start":0'
  assert "semantic is reported as having run" "$SEM" '"semantic":true'
  # the passage is FIRST, ahead of the keyword rows: a reader scanning the list
  # should meet the answer before the path matches
  assert "the passage leads the results" "$(printf '%s' "$SEM" | grep -oP '"type":"\K[^"]+' | head -1)" "passage"

  # a plain search is unchanged and says nothing about a half it was not asked for
  PLAIN=$(G "/api/search?q=cephalopods")
  refute "a plain search carries no semantic field" "$PLAIN" '"semantic"'
  assert "...and still matches the content"         "$PLAIN" '"kb/octopuses.txt"'

  # the TOOL itself, through a published one-step spec — there is no route that
  # invokes a tool directly, by design, so a workflow is how the agent-facing
  # half is reached over HTTP (`pdf-form`'s precedent). It answers STRUCTURE
  # (VEC-38), so the citation stays machine-readable through the step's output.
  RWF='{"spec":1,"slug":"retrieve-probe","input":{"question":"string"},"steps":[
    {"id":"ask","uses":"tool:repo_retrieve","with":{"question":"${input.question}","limit":2},"end":true}]}'
  assert "the retrieval spec published" "$(P /api/workflows "$RWF")" '"slug":"retrieve-probe"'
  RR=$(P /api/workflows/retrieve-probe/run '{"input":{"question":"cephalopods with arms"}}')
  wait_run "$(printf '%s' "$RR" | grep -oP '"id":"\K[^"]+' | head -1)"
  RST="$RUNST"
  [ "$RST" = done ] || RST="$RST — $(printf '%s' "$RUNJSON" | grep -oP '"error":"\K[^"]*' | head -1)"
  assert "the retrieval run finished" "$RST" "done"
  assert "the tool answered passages"  "$RUNJSON" 'passages'
  assert "...naming the document"      "$RUNJSON" 'kb/octopuses.txt'
  assert "...and the model it compared under" "$RUNJSON" 'mock-embed'

  # bob is a member with chat:use, so he may ask; the documents are team-visible
  assert "a colleague may retrieve too" "$(curl -s "$B/api/search?q=cephalopods%20with%20arms&semantic=1" -H "Authorization: Bearer $BOB")" '"type":"passage"'

  # and the request log recorded an EMBED operation, which is the proof the real
  # wire was used rather than a seam somebody scripted
  assert "an embedding request was logged" "$(G "/api/model-requests")" '"operation":"embed"'
fi


# ---- 9. voice notes: upload a recording, transcribe it, then find it (#192) ------
#
# LAST IN THE FILE, after §8, for the reason §8 is: a new document changes what
# every bounded lister above reaches, and this section adds one AND runs a
# workflow that writes text. The file's own recorded lesson — a fixture that
# changes GLOBAL state breaks a distant block — with the same remedy.
#
# This is the only place #192's wire is driven end to end: the multipart body
# really is composed, posted and parsed. The "audio" is a sentence in UTF-8,
# which is what makes the transcript assertable.
if [ $LIVE = 0 ]; then
  echo
  echo "== 9. voice notes (#192) =="
  printf 'the kiln reached cone six overnight and the glaze crawled on two pots\n' > "$TMACH_DATA_DIR/note.mp3"
  VN=$(curl -s -X PUT "$B/api/repo/voice/standup.mp3" -H "Authorization: Bearer $TOK" \
        -H 'Content-Type: audio/mpeg' --data-binary @"$TMACH_DATA_DIR/note.mp3")
  VNID=$(printf '%s' "$VN" | jq_ 'd["id"]')
  assert "the voice note uploaded as audio" "$VN" '"content_type":"audio/mpeg"'
  assert "...and requirement 2 needed no new route" "$VN" '"key":"voice/standup.mp3"'
  assert "the transcription tools are registered" "$(G /api/tools)" '"name":"doc_transcribe"'
  assert "the Transcribe Voice Notes workflow arrived" "$(G /api/workflows)" '"slug":"transcribe-documents"'

  # A recording has NO text until this has run, so Index Documents has nothing to
  # extract from it — which is why transcription is its own workflow and runs
  # first for a voice note (the opposite order from index-then-embed).
  BEFORE=$(G "/api/search?q=glaze%20crawled")
  refute "the recording is not findable before transcription" "$BEFORE" 'voice/standup.mp3'

  # Drained, for §8's reason: by this point the team holds well over twenty
  # documents and the lister is bounded and ordered oldest-first. Audio is the
  # only type it offers, so the window is small — but draining is also the
  # assertion that the pass TERMINATES (VEC-23).
  for i in 1 2 3; do
    RVN=$(P /api/workflows/transcribe-documents/run '{"input":{}}')
    wait_run "$(printf '%s' "$RVN" | grep -oP '"id":"\K[^"]+' | head -1)"
    [ "$RUNST" = done ] || break
    printf '%s' "$RUNJSON" | grep -q '"result":\[\]' && break
    LASTVN="$RUNJSON"
  done
  assert "transcribe-documents drained" "$RUNST" "done"
  # the LAST NON-EMPTY run is the one that did the work: the final run of a drain
  # reports "no documents", so asserting on $RUNJSON asserts on the empty one
  assert "...and it transcribed the recording" "$LASTVN" 'voice/standup.mp3'

  # The transcript IS the document's text (VOICE-9), so every reader that was
  # already there finds it with nothing further to run.
  FOUND=$(G "/api/search?q=glaze%20crawled")
  assert "the recording is findable by what was SAID" "$FOUND" 'voice/standup.mp3'
  # the SNIPPET is the transcript, which is what proves the text really is the
  # document's own rather than a key match on the filename
  assert "...and the match is in the transcript itself" "$FOUND" 'cone six'

  # the duration and the language the endpoint reported reached LAY-4 attributes
  VNO=$(G "/api/repo-obj/$VNID")
  assert "the spoken language was recorded"  "$VNO" '"voice_language":"en"'
  assert "...and the duration"               "$VNO" '"voice_duration":"4"'
  assert "...and which model answered"       "$VNO" '"voice_model":"mock-whisper"'

  assert "ai.transcriptions.total is metered and reported" \
    "$(G /api/usage)" '"dimension":"ai.transcriptions.total"'
  # and the request log recorded a TRANSCRIBE operation, which is the proof the
  # real multipart wire was used rather than a scripted seam
  assert "a transcription request was logged" "$(G "/api/model-requests")" '"operation":"transcribe"'
fi

echo
if [ $fail = 0 ]; then echo "doc-pipeline-smoke: PASS"; else echo "doc-pipeline-smoke: FAIL"; tail -30 "$TMACH_DATA_DIR/server.log"; exit 1; fi
