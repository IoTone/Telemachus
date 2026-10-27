#!/usr/bin/env bash
# test/s3-blobstore-smoke.sh — the outbound S3 blob store over a real socket (#82).
#
# test/s3-client-tests.rkt proves the SIGNING, in process, against this tree's
# own verifier. This proves the WIRE: a real TCP connection, a real SigV4
# verifier on the far end, a streamed body with Content-Length, and a response
# parsed off the socket.
#
# THE SERVER IT TALKS TO IS THIS SERVER. Telemachus serves an S3 API of its own
# (slice 52), so the client is pointed at it. That is a deliberately strange
# arrangement and it buys two things no mock would: the far end is a real,
# independent SigV4 verifier that was written from the spec and pinned to AWS's
# own vectors, and it is the ONE target reachable with no Docker and no cloud
# account. What it cannot prove is server-side ENCRYPTION, because Telemachus
# does not implement SSE — so section 3 asserts the opposite and valuable thing:
# that `require-encryption` REFUSES a bucket which does not report it. MinIO in
# CI covers the SSE-present half.
set -uo pipefail
cd "$(dirname "$0")/.."

export PLTCOLLECTS="$(pwd)/pkgs:"
unset TMACH_PLUGINS TMACH_PLUGINS_LINKS TELEMACHUS_PLUGINS TELEMACHUS_PLUGINS_LINKS

port_busy(){ bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
export PORT="${PORT:=8852}"
S3_PORT="${S3_PORT:-8853}"
for p in "$PORT" "$S3_PORT"; do
  if port_busy "$p"; then echo "port $p is in use — set PORT / S3_PORT" >&2; exit 1; fi
done

export TMACH_DATA_DIR="$(mktemp -d)"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$TMACH_DATA_DIR/telemachus.db}"
export TMACH_BIND=127.0.0.1
export TMACH_S3_PORT="$S3_PORT"
# The credential's secret is SEALED at rest since #19, and SigV4 unwraps it on
# every signed request — so this exercises the sealed path, not a plaintext one.
export TMACH_SECRET_KEY="${TMACH_SECRET_KEY-$(printf '%064d' 7)}"

fail=0
assert(){ case "$2" in *"$3"*) echo "  ok   $1";;
                       *) echo "  FAIL $1 — expected: $3 — got: $2"; fail=1;; esac; }

cleanup(){ [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null; rm -rf "$TMACH_DATA_DIR"; }
trap cleanup EXIT

echo "s3-blobstore smoke  DATABASE_URL=$DATABASE_URL  s3=:$S3_PORT"
raco make server/main.rkt
racket server/main.rkt >"$TMACH_DATA_DIR/server.log" 2>&1 &
SRV=$!
tries=0; until port_busy "$PORT" && port_busy "$S3_PORT"; do
  tries=$((tries+1)); [ $tries -gt 600 ] && { echo "server never came up"; cat "$TMACH_DATA_DIR/server.log"; exit 1; }
  sleep 0.1
done

B="localhost:$PORT"
TOK=$(curl -s -X POST "$B/api/bootstrap" -d '{"username":"ops","password":"ops-pw-pw1"}' \
      | grep -oE '"token":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$TOK" ] || { echo "no bootstrap token"; cat "$TMACH_DATA_DIR/server.log"; exit 1; }

CRED=$(curl -s -X POST "$B/api/s3/credentials" -H "Authorization: Bearer $TOK" -d '{"name":"blobstore"}')
# Portable extraction: `grep -oP` is GNU-only and absent on macOS, which the
# other smokes get away with only because they run on Linux in CI.
AK=$(printf '%s' "$CRED" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_key_id"])')
SK=$(printf '%s' "$CRED" | python3 -c 'import sys,json;print(json.load(sys.stdin)["secret_access_key"])')
[ -n "$AK" ] && [ -n "$SK" ] || { echo "no S3 credential: $CRED"; exit 1; }

export TMACH_S3_BLOB_ENDPOINT="http://127.0.0.1:$S3_PORT"
export TMACH_S3_BLOB_BUCKET=default      # the team slug IS the bucket (slice 52)
export TMACH_S3_BLOB_REGION=us-east-1
export TMACH_S3_BLOB_PREFIX=blobs
export TMACH_S3_BLOB_ACCESS_KEY="$AK"
export TMACH_S3_BLOB_SECRET_KEY="$SK"
export TMACH_S3_BLOB_PATH_STYLE=1
# Sections 1-2 run with encryption OFF, which is the HONEST configuration for
# this far end: Telemachus's own S3 API does not implement SSE, so asking for it
# and requiring it would refuse every write — as it did on the first run of this
# suite, which is section 3's whole point. Section 3 turns it back on.
export TMACH_S3_BLOB_SSE=none

# Driven through the PUBLIC seam — blob-put!/blob-get/blob-size/blob-delete! with
# TMACH_BLOB_STORE=s3 — not by reaching into the registered hash. That is the
# exact path domain/repo/repo.rkt takes, so this exercises store selection too.
export TMACH_BLOB_STORE=s3
PLUG="$(pwd)/plugins/s3blobs/main.rkt"
BLOBS="$(pwd)/domain/repo/blobs.rkt"

cat > "$TMACH_DATA_DIR/drive.rkt" <<RKT
#lang racket/base
(require racket/port (file "$PLUG") (file "$BLOBS"))
(init!)   ; registers "s3"; TMACH_BLOB_STORE selects it
(printf "active-store ~a\n" (active-blob-store-name))
(define ns "org-smoke")
;; 3 MiB of non-repeating bytes: large enough that a buffering implementation
;; shows up, and the digest is computed the way the repository computes it.
(define payload
  (let ([o (open-output-bytes)])
    (for ([i (in-range (* 3 1024 1024))]) (write-byte (modulo (* i 2654435761) 256) o))
    (get-output-bytes o)))
(define-values (digest size) (digest-of-port (open-input-bytes payload)))
(printf "digest ~a size ~a\n" digest size)
(printf "stat-before ~a\n" (blob-size ns digest))
(blob-put! ns digest (open-input-bytes payload) size)
(printf "put ok\n")
(printf "stat-after ~a\n" (blob-size ns digest))
(define in (blob-get ns digest))
(define back (port->bytes in))
(close-input-port in)
(printf "roundtrip ~a\n" (if (equal? back payload) "IDENTICAL" "DIFFERENT"))
(printf "readback-size ~a\n" (bytes-length back))
;; Idempotent by construction — the name IS the content — so a second write must
;; be a no-op rather than an error, and must not re-send the bytes (it HEADs).
(blob-put! ns digest (open-input-bytes payload) size)
(printf "second-put ok\n")
;; A blob that was never written reads as a MISS, not an error: repo.rkt's
;; callers distinguish "gone" from "forbidden" on exactly that (DOC-5).
(printf "miss-get ~a\n"
        (blob-get ns "0000000000000000000000000000000000000000000000000000000000000000"))
(blob-delete! ns digest)
(printf "stat-after-delete ~a\n" (blob-size ns digest))
;; Delete is idempotent too: the blob reaper calls it on bytes another version
;; may already have released.
(blob-delete! ns digest)
(printf "second-delete ok\n")
RKT

echo "== 1. the store is registered and selectable ================================="
assert "the s3 store registers under the name 's3'" \
  "$(racket -e "(require (file \"$PLUG\") (file \"$BLOBS\")) (init!) (displayln (blob-store-names))" 2>&1)" \
  "s3"

echo "== 2. a 3 MiB blob round-trips over the wire ================================="
OUT=$(racket "$TMACH_DATA_DIR/drive.rkt" 2>&1)
echo "$OUT" | sed 's/^/     /' | head -20
assert "TMACH_BLOB_STORE selected it"    "$OUT" "active-store s3"
assert "stat before the write is a miss"      "$OUT" "stat-before #f"
assert "the streamed PUT is accepted"         "$OUT" "put ok"
assert "stat after the write reports the size" "$OUT" "stat-after 3145728"
assert "the bytes come back IDENTICAL"        "$OUT" "roundtrip IDENTICAL"
assert "…all of them, not a truncated stream" "$OUT" "readback-size 3145728"
assert "a second write is a no-op"            "$OUT" "second-put ok"
assert "a blob that was never written is a MISS, not an error" "$OUT" "miss-get #f"
assert "delete removes it"                    "$OUT" "stat-after-delete #f"
assert "a second delete does not raise"       "$OUT" "second-delete ok"

echo "== 2b. descriptors do not grow across many operations ======================"
# The client returns a live socket for a GET and must close BOTH of its ports.
# It did not: `out` was closed only on the error path, so every successful
# request leaked a descriptor — the measured mistake llm.rkt documents for
# http-sendrecv, repeated here. A count is the only honest check of the fix,
# because nothing about the code's shape makes the leak visible.
#
# /dev/fd exists on Linux and macOS. 40 full cycles is 160-odd requests, so a
# one-per-request leak is unmistakable against startup noise.
#
# THE COUNTER ITSELF WAS CONTROLLED, because "growth 0" from a blind measurement
# looks exactly like "growth 0" from a clean one: 40 TCP connection pairs left
# deliberately open moved the count by 80. It sees sockets. The threshold is 8
# rather than 0 because a run legitimately opens a few things lazily.
FDS=$(racket -e "
(require racket/port racket/file (file \"$PLUG\") (file \"$BLOBS\"))
(init!)
(define (fd-count)
  (with-handlers ([(lambda (_) #t) (lambda (_) -1)])
    (length (directory-list \"/dev/fd\"))))
(define bs (make-bytes 4096 90))
(define-values (d n) (digest-of-port (open-input-bytes bs)))
;; one warm cycle first, so lazily-opened things are not counted as a leak
(blob-put! \"org-fd\" d (open-input-bytes bs) n)
(let ([in (blob-get \"org-fd\" d)]) (void (port->bytes in)) (close-input-port in))
(blob-delete! \"org-fd\" d)
(define before (fd-count))
(for ([i (in-range 40)])
  (blob-put! \"org-fd\" d (open-input-bytes bs) n)
  (define in (blob-get \"org-fd\" d))
  (void (port->bytes in))
  (close-input-port in)
  (blob-size \"org-fd\" d)
  (blob-delete! \"org-fd\" d))
;; the GET body is closed by a thread, so give those a moment to finish
(sleep 1)
(define after (fd-count))
(printf \"fds before ~a after ~a growth ~a\n\" before after (- after before))
(printf \"verdict ~a\n\" (cond [(< before 0) \"UNKNOWN\"]
                               [(<= (- after before) 8) \"STABLE\"]
                               [else \"LEAKING\"]))" 2>&1)
echo "$FDS" | sed 's/^/     /' | tail -3
assert "descriptors are stable across 40 put/get/stat/delete cycles" "$FDS" "verdict STABLE"

echo "== 3. require-encryption has TEETH =========================================="
# Telemachus's own S3 endpoint does not implement SSE, so a bucket that reports
# no encryption is exactly the condition requirement 2 must refuse. If this
# passes silently, the flag is decoration.
ENC=$(TMACH_S3_BLOB_REQUIRE_ENCRYPTION=1 TMACH_S3_BLOB_SSE=kms \
      racket -e "
(require racket/port (file \"$PLUG\") (file \"$BLOBS\"))
(init!)
(define bs (make-bytes 1024 65))
(define-values (d n) (digest-of-port (open-input-bytes bs)))
(with-handlers ([(lambda (e) #t) (lambda (e) (printf \"REFUSED: ~a\n\" (if (exn? e) (exn-message e) e)))])
  ((hash-ref (hash 'put! void) 'put!) 0 0 0 0)
  (void))
(with-handlers ([(lambda (e) #t) (lambda (e) (printf \"REFUSED: ~a\n\" (if (exn? e) (exn-message e) e)))])
  (blob-put! \"org-enc\" d (open-input-bytes bs) n)
  (printf \"ACCEPTED (the flag did nothing)\n\"))" 2>&1)
assert "an unencrypted bucket is refused when encryption is required" "$ENC" "REFUSED"
assert "…and the refusal says what is wrong"                          "$ENC" "server-side encryption"

echo "== 4. the migration tool: rs3 -> bucket, re-hashing on the way ============="
# A local store with three good blobs and one ROTTEN one. The rotten blob is the
# positive control for the corruption check: rs3 takes a blob's digest from its
# PATH, so a file whose bytes have changed still looks correct to everything that
# does not hash it, and a migration that trusts the filename copies the rot to
# the bucket under a name that lies about it. Without this control that branch is
# never executed and "copied 3" would look like a complete success.
export TMACH_RS3_ROOT="$TMACH_DATA_DIR/rs3"
mkdir -p "$TMACH_RS3_ROOT"
SEED=$(racket -e "
(require racket/file racket/port (file \"$BLOBS\"))
(define root \"$TMACH_RS3_ROOT\")
(define (write-blob! org bs)
  (define-values (d n) (digest-of-port (open-input-bytes bs)))
  (define p (build-path root org (substring d 0 2) (substring d 2 4) d))
  (make-parent-directory* p)
  (call-with-output-file p #:exists (quote truncate) (lambda (o) (write-bytes bs o)))
  d)
(define a (write-blob! \"orgA\" #\"the first document\"))
(define b (write-blob! \"orgA\" #\"the second document\"))
(define c (write-blob! \"orgB\" (make-bytes 200000 88)))
;; and one whose bytes no longer match its name
(define bad (write-blob! \"orgB\" #\"honest bytes\"))
(define badp (build-path root \"orgB\" (substring bad 0 2) (substring bad 2 4) bad))
(call-with-output-file badp #:exists (quote truncate)
  (lambda (o) (write-bytes #\"ROTTEN bytes, same name\" o)))
(printf \"~a ~a ~a ~a\\n\" a b c bad)" 2>&1 | tail -1)
echo "     seeded: $(echo "$SEED" | cut -c1-16)…"

PLAN=$(racket cli/telemachus-blobs.rkt plan 2>&1)
assert "plan counts every blob on disk"   "$PLAN" "total: 4 blob(s)"
assert "…and groups them by org"          "$PLAN" "orgA: 2 blob(s)"

MIG=$(racket cli/telemachus-blobs.rkt migrate --verify 2>&1)
echo "$MIG" | sed 's/^/     /' | tail -8
assert "the three good blobs are copied"  "$MIG" "copied 3"
assert "the ROTTEN one is caught by re-hashing, not copied" "$MIG" "CORRUPT"
assert "…and counted separately"          "$MIG" "corrupt 1"
assert "…and the operator is told it is a data-loss question" "$MIG" "data-loss question"

# Resumable: a second run must copy nothing and skip what is already there. This
# is what a content-addressed key buys — a present object of the right length IS
# the right object, so there is nothing to reconcile.
MIG2=$(racket cli/telemachus-blobs.rkt migrate 2>&1)
assert "a second run copies nothing"      "$MIG2" "copied 0"
assert "…and skips what is already there" "$MIG2" "already present 3"

VER=$(racket cli/telemachus-blobs.rkt verify 2>&1)
assert "verify reads the good blobs back out of the bucket" "$VER" "verified 3"
assert "…and reports the one that was never copied"         "$VER" "missing 1"

echo "== 5. a REAL bucket, when one is offered ==================================="
# Sections 1-4 ran against this server's own S3 API, which is the only target
# reachable with no Docker and no cloud account — and which does not implement
# SSE, so it can only prove the REFUSAL half of requirement 2. Point
# S3_TEST_ENDPOINT at any S3-compatible bucket and this section proves the other
# half: that encryption actually arrives and the object reads back.
#
# NOT named after a vendor, deliberately. These were MINIO_* at first, which was
# wrong twice over: the variables are generic (AWS, Ceph RGW, s3mock and MinIO
# all work), and MinIO is the one target a reader CANNOT currently obtain — its
# images are no longer freely pullable. Naming the knob after it, and defaulting
# the credentials to `minioadmin`, pointed people at the single unavailable
# option.
#
# Skipped LOUDLY when unset, because a silently skipped section is how the
# aws-cli path went unexercised for a year (issue #25).
if [ -z "${S3_TEST_ENDPOINT:-}" ]; then
  echo "     SKIP — set S3_TEST_ENDPOINT, S3_TEST_BUCKET, S3_TEST_KEY, S3_TEST_SECRET."
  echo "     Sections 1-4 cannot prove encryption ARRIVES, only that its absence is refused."
elif [ -z "${S3_TEST_KEY:-}" ] || [ -z "${S3_TEST_SECRET:-}" ]; then
  # No vendor default: a wrong-but-plausible credential fails as SignatureDoesNotMatch,
  # which reads as a signing bug in this client rather than as missing configuration.
  echo "  FAIL S3_TEST_ENDPOINT is set but S3_TEST_KEY/S3_TEST_SECRET are not"
  fail=1
else
  OUT5=$(TMACH_S3_BLOB_ENDPOINT="$S3_TEST_ENDPOINT" \
         TMACH_S3_BLOB_BUCKET="${S3_TEST_BUCKET:-telemachus}" \
         TMACH_S3_BLOB_ACCESS_KEY="$S3_TEST_KEY" \
         TMACH_S3_BLOB_SECRET_KEY="$S3_TEST_SECRET" \
         TMACH_S3_BLOB_SSE="${S3_TEST_SSE:-s3}" \
         TMACH_S3_BLOB_REQUIRE_ENCRYPTION=1 \
         racket -e "
(require racket/port (file \"$PLUG\") (file \"$BLOBS\"))
(init!)
(define bs (make-bytes 65536 77))
(define-values (d n) (digest-of-port (open-input-bytes bs)))
(blob-put! \"org-s3test\" d (open-input-bytes bs) n)
(printf \"encrypted-put ok\n\")
(printf \"stat ~a\n\" (blob-size \"org-s3test\" d))
(define in (blob-get \"org-s3test\" d))
(define back (port->bytes in)) (close-input-port in)
(printf \"roundtrip ~a\n\" (if (equal? back bs) \"IDENTICAL\" \"DIFFERENT\"))
(blob-delete! \"org-s3test\" d)
(printf \"cleaned ~a\n\" (blob-size \"org-s3test\" d))" 2>&1)
  echo "$OUT5" | sed 's/^/     /' | tail -6
  # The PUT only succeeds under REQUIRE_ENCRYPTION=1 if the bucket reported the
  # header, so this single assertion is the encryption round trip.
  assert "a bucket that DOES encrypt accepts the write" "$OUT5" "encrypted-put ok"
  assert "…and the bytes come back identical"           "$OUT5" "roundtrip IDENTICAL"
  assert "…and the blob can be removed again"           "$OUT5" "cleaned #f"
fi

echo
if [ $fail = 0 ]; then echo "s3-blobstore-smoke: PASS"; else
  echo "s3-blobstore-smoke: FAIL"; tail -25 "$TMACH_DATA_DIR/server.log"; exit 1; fi
