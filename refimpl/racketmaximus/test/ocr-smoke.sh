#!/usr/bin/env bash
# test/ocr-smoke.sh — issue #92's ACCEPTANCE CRITERIA, over HTTP, on a live server.
#
#   "Uploading a photo of a printed page and running a workflow with doc_text
#    returns the text without manual steps."
#
# test/ocr-tests.rkt proves the extractor. This proves the PATH: an upload
# through the repository front door, the indexing workflow as a real scheduler
# job, the text in `repo_text`, and search finding it. None of that is reachable
# from a unit test, and all of it is what an integrator actually drives.
#
#   bash test/ocr-smoke.sh
#   DATABASE_URL="postgres://…" bash test/ocr-smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."

export PLTCOLLECTS="$(pwd)/pkgs:"
# The SHIPPED plugin set, for the reason the other eight harnesses say: a
# developer exports these in their own shell and a downstream plugin would
# otherwise fail to load here and fail this suite with it.
unset TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS

port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
export PORT="${PORT:-8843}"
if port_busy "$PORT"; then echo "port $PORT is in use — set PORT=<free port>" >&2; exit 1; fi

if ! command -v tesseract >/dev/null 2>&1; then
  # Loudly. A silent skip is how the s3 path went unexercised for a year (#25).
  echo "ocr-smoke: SKIP (no tesseract on PATH — \`nix develop\` provides it)"
  exit 0
fi

export TELEMACHUS_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TELEMACHUS_DATA_DIR/telemachus.db}"
export TELEMACHUS_BIND=127.0.0.1
# The switch under test. Without it the instance behaves exactly as it did
# before this plugin existed, which section 1 asserts before turning it on.
export TELEMACHUS_OCR=1

fail=0
assert(){ case "$2" in *"$3"*) echo "  ok   $1";;
                       *) echo "  FAIL $1 — expected: $3 — got: $2"; fail=1;; esac; }
refute(){ case "$2" in *"$3"*) echo "  FAIL $1 — did NOT expect: $3"; fail=1;;
                       *) echo "  ok   $1";; esac; }

cleanup(){ [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null; rm -rf "$TELEMACHUS_DATA_DIR"; }
trap cleanup EXIT

# ---- the fixture ---------------------------------------------------------------
# Generated, not committed: a .png nobody can diff is a poor fixture, and the
# expected text then lives in the same file as the assertion. racket/draw writes
# both PNG and PDF, so the "scan" costs no extra tool either.
cat > "$TELEMACHUS_DATA_DIR/gen.rkt" <<'RKT'
#lang racket/base
(require racket/draw racket/class)
;; The photo and the scan carry DIFFERENT words on purpose. They were identical
;; at first, and the search assertions then could not tell which document had
;; been read — two documents with byte-identical extracted text are one snippet
;; as far as a search result is concerned, so the scan's assertion failed while
;; the scan had in fact been OCR'd perfectly.
(define (page! lines)
  (define bm (make-bitmap 1000 300))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-background (make-color 255 255 255)) (send dc clear)
  (send dc set-text-foreground (make-color 0 0 0))
  (send dc set-font (make-font #:size 40 #:family 'modern))
  (for ([l lines] [i (in-naturals)])
    (send dc draw-text l 40 (+ 40 (* i 80))))
  bm)
(define dir (vector-ref (current-command-line-arguments) 0))
(define bm (page! '("Invoice ACME-4471" "Total 1250 EUR" "Due 2026-11-30")))
(send bm save-file (build-path dir "photo.png") 'png)
(define scan-bm (page! '("Statement GLOBEX-8832" "Balance 990 USD" "Paid 2026-09-15")))
;; an image-only PDF: no text layer at all, so the built-in reports needs-ocr
(define dc (new pdf-dc% [interactive #f] [use-paper-bbox #f] [as-eps #f]
                [width 1000] [height 300] [output (build-path dir "scan.pdf")]))
(send dc start-doc "scan") (send dc start-page)
(send dc draw-bitmap scan-bm 0 0)
(send dc end-page) (send dc end-doc)
(displayln "fixtures written")
RKT
racket "$TELEMACHUS_DATA_DIR/gen.rkt" "$TELEMACHUS_DATA_DIR" >/dev/null || {
  echo "ocr-smoke: could not generate fixtures" >&2; exit 1; }

echo "ocr-smoke DATABASE_URL=$DATABASE_URL"
raco make server/main.rkt
racket server/main.rkt >"$TELEMACHUS_DATA_DIR/server.log" 2>&1 &
SRV=$!
tries=0; until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 600 ] && { echo "server never came up"; cat "$TELEMACHUS_DATA_DIR/server.log"; exit 1; }
  sleep 0.1
done

B="localhost:$PORT"
TOK=$(curl -s -X POST "$B/api/bootstrap" -d '{"username":"ops","password":"ops-pw-pw1"}' \
      | grep -oE '"token":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$TOK" ] || { echo "no bootstrap token"; cat "$TELEMACHUS_DATA_DIR/server.log"; exit 1; }
G(){ curl -s "$B$1" -H "Authorization: Bearer $TOK"; }
P(){ curl -s -X POST "$B$1" -H "Authorization: Bearer $TOK" -d "${2:-{\}}"; }
PUT(){ curl -s -X PUT "$B/api/repo/$1" -H "Authorization: Bearer $TOK" \
            -H "Content-Type: $2" --data-binary @"$3"; }

# A run's own status, read as JSON rather than matched as a substring.
#
# THE TRAP, paid for once: `case "$RUN" in *'"status":"done"'*)` breaks as soon
# as ANY status in the document is done — and /api/runs/:id embeds every STEP,
# each with its own. So the loop exited while the run was still `running` with
# `find` finished and `extract#0` mid-OCR, and the next assertion read an index
# that had not been written yet. It passed for the photograph, whose OCR takes
# under a second, and failed for the rasterised PDF, which takes several: a
# timing-shaped failure that looked like a broken extractor.
#
# `grep -oP '"status":"\K[^"]+'` (what the other smokes use) happens to be right
# because the top-level key sorts before "steps", but -P is GNU-only and absent
# on macOS. python3 is already a dependency of every smoke here.
run_status(){ G "/api/runs/$1" | python3 -c \
  'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null; }

# <run id> <label> — polls the RUN, not its steps.
wait_run(){
  local id="$1" label="$2" st="" i=0
  while [ $i -lt 900 ]; do
    st=$(run_status "$id")
    case "$st" in done|error|canceled) break;; esac
    i=$((i+1)); sleep 0.2
  done
  assert "$label" "$st" "done"
  RUNST="$st"
}

echo "== 0. the plugin loaded, and says what it claims ============================="
PL=$(G /api/plugins)
assert "no plugin failed to load"        "$PL" '"failed":[]'
assert "the ocr plugin is listed"        "$PL" '"id":"ocr"'
assert "…and reports its extractors"     "$PL" 'image/jpeg'
assert "…including application/pdf"      "$PL" 'application/pdf'
assert "the boot line says it is enabled" "$(cat "$TELEMACHUS_DATA_DIR/server.log")" 'ocr: enabled'

echo "== 1. ACCEPTANCE: a photograph of a printed page reads ======================="
PHOTO=$(PUT "inbox/photo.png" "image/png" "$TELEMACHUS_DATA_DIR/photo.png")
assert "the photo uploaded"               "$PHOTO" '"key":"inbox/photo.png"'
PID=$(printf '%s' "$PHOTO" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)

# The upload returns immediately; extraction is a scheduler JOB (requirement 4).
refute "the upload did not block on OCR"  "$PHOTO" '"text"'

IDX=$(P /api/workflows/index-documents/run '{}')
assert "indexing run accepted"            "$IDX" '"status":"running"'
RUNID=$(printf '%s' "$IDX" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
wait_run "$RUNID" "the indexing run finished"

# There is no route that hands back extracted text on its own, so the assertion
# goes through the two that READ repo_text — which is the right test anyway: it
# is the path doc_text, doc_extract_fields and the console all take.
assert "the photo's text reached the index"  "$(G '/api/search?q=ACME-4471')" 'inbox/photo.png'
assert "…all three lines, not just the first" "$(G '/api/search?q=1250')" 'inbox/photo.png'
assert "…and the date"                        "$(G '/api/search?q=2026-11-30')" 'inbox/photo.png'

echo "== 2. the provenance LAY-5 reserved a column for, finally filled ============="
assert "a region is reported for an offset" "$(G "/api/repo-obj/$PID/spans?at=3")" '"bbox"'
assert "…naming the page"                   "$(G "/api/repo-obj/$PID/spans?at=3")" '"page":1'

echo "== 3. ACCEPTANCE: a scanned PDF, which used to be a dead end ================="
SCAN=$(PUT "inbox/scan.pdf" "application/pdf" "$TELEMACHUS_DATA_DIR/scan.pdf")
assert "the scan uploaded"                 "$SCAN" '"key":"inbox/scan.pdf"'
SID=$(printf '%s' "$SCAN" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
IDX2=$(P /api/workflows/index-documents/run '{}')
RUN2ID=$(printf '%s' "$IDX2" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
wait_run "$RUN2ID" "the second indexing run finished"
assert "the SCAN's own text was recovered" "$(G '/api/search?q=GLOBEX-8832')" 'inbox/scan.pdf'
assert "…and its other lines"                "$(G '/api/search?q=990')" 'inbox/scan.pdf'
# The regions prove it was RASTERISED and read, not picked out of a text layer:
# pdf-text-layer returns no spans, by design and asserted in test/ocr-tests.rkt.
assert "…with per-page regions"            "$(G "/api/repo-obj/$SID/spans?at=3")" '"bbox"'

echo
if [ $fail = 0 ]; then
  echo "ocr-smoke: PASS"
else
  echo "ocr-smoke: FAIL"
  # The indexer records its own account of a document it could not read —
  # "skipped <key> — unreadable as <type> (<reason>)" — in the step result, and
  # that sentence is the first thing worth reading when extraction came back
  # empty. extract-registered contains a raise as a bare 'failed, so the run is
  # the only place the reason survives.
  # What actually reached the index, from the suite's own database. The run
  # result says "indexed <key> (N characters)" and the search can still answer
  # nothing, so these two have to be read together.
  case "$DATABASE_URL" in
    sqlite:*) if command -v sqlite3 >/dev/null 2>&1; then
                echo "--- the ids this suite extracted ---"
  echo "PID=$PID"; echo "SID=${SID:-}"
  echo "raw PUT (photo): $PHOTO"
  echo "--- repo_text ---"
                sqlite3 "${DATABASE_URL#sqlite://}" \
                  "SELECT object_id, length(content), length(spans) FROM repo_text;" 2>&1
                echo "--- repo_objects ---"
                sqlite3 "${DATABASE_URL#sqlite://}" \
                  "SELECT id, key, team_id FROM repo_objects;" 2>&1
              fi;;
  esac
  echo "--- the indexing runs ---"
  G "/api/runs/$RUNID"; echo; G "/api/runs/$RUN2ID"; echo
  echo "--- server log ---"
  tail -30 "$TELEMACHUS_DATA_DIR/server.log"
  exit 1
fi
