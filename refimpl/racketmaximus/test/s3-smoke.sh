#!/usr/bin/env bash
# test/s3-smoke.sh — drive the S3 endpoint with the REAL aws CLI (slice 52).
#
# The unit tests prove SigV4 against AWS's published vectors. This proves the thing
# that actually matters: that `aws`, the client people will use, works. Every check
# here is an operation a real workflow performs — copy up, copy down, sync, folder
# listing, multipart above the 8 MiB threshold, ranged download, delete — plus the
# refusals we promised (public ACLs, unimplemented sub-resources, bad credentials).
#
#   PORT=8890 S3_PORT=8891 bash test/s3-smoke.sh      (from refimpl/racketmaximus/)
#
# Skips with exit 0 if the aws CLI is absent, so it is safe in CI without one.
set -u
fail=0
assert(){ if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok   $1";
  else echo "  FAIL $1 — expected: $3 — got: $(printf '%s' "$2" | tr -d '\000' | head -c 300)"; fail=1; fi; }
ok(){ echo "  ok   $1"; }
bad(){ echo "  FAIL $1 — $2"; fail=1; }

command -v aws >/dev/null 2>&1 || { echo "s3-smoke: SKIP (no aws CLI)"; exit 0; }

: "${PORT:=8890}"
: "${S3_PORT:=8891}"
for p in "$PORT" "$S3_PORT"; do
  if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then exec 3>&- ; echo "port $p is already in use — set PORT / S3_PORT"; exit 1; fi
done

TMP=$(mktemp -d)
export TELEMACHUS_DATA_DIR="$TMP/data"
export DATABASE_URL="sqlite://$TMP/s3.db"
export TELEMACHUS_BIND=127.0.0.1
export TELEMACHUS_S3_PORT="$S3_PORT"
racket server/main.rkt >"$TMP/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT
tries=0
until (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; do
  tries=$((tries+1)); [ $tries -gt 400000 ] && { echo "server never came up"; cat "$TMP/server.log"; exit 1; }
done
exec 3>&- 2>/dev/null || true

B="localhost:$PORT"
TOK=$(curl -s -X POST $B/api/bootstrap -d '{"username":"ops","password":"pw"}' | grep -oP '"token":\s*"\K[^"]+')
CRED=$(curl -s -X POST $B/api/s3/credentials -H "Authorization: Bearer $TOK" -d '{"name":"smoke"}')
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CRED" | grep -oP '"access_key_id":\s*"\K[^"]+')
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CRED" | grep -oP '"secret_access_key":\s*"\K[^"]+')
export AWS_DEFAULT_REGION=us-east-1
# aws-cli >= 2.23 adds CRC64NVME trailers by default; we verify the signature, not the
# checksum, and asking for the simpler framing keeps this about SigV4.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
E="http://127.0.0.1:$S3_PORT"
A="aws --endpoint-url $E"

assert "credential minted" "$CRED" '"access_key_id":"TMX'
assert "delete is in scope"  "$CRED" 'files:delete'

# ---- the basics -----------------------------------------------------------------
assert "ListBuckets shows the team as a bucket" "$($A s3 ls 2>&1)" "default"

head -c 40000 /dev/urandom > "$TMP/doc.pdf"
$A s3 cp "$TMP/doc.pdf" s3://default/reports/q3.pdf >/dev/null 2>&1
assert "PutObject" "$($A s3 ls s3://default/ --recursive 2>&1)" "reports/q3.pdf"
$A s3 cp s3://default/reports/q3.pdf "$TMP/back.pdf" >/dev/null 2>&1
cmp -s "$TMP/doc.pdf" "$TMP/back.pdf" && ok "GetObject round-trips byte-identically" \
  || bad "GetObject round-trips byte-identically" "bytes differ"

assert "HeadObject" "$($A s3api head-object --bucket default --key reports/q3.pdf 2>&1)" '"ContentLength": 40000'

# ---- folders: prefix + delimiter -------------------------------------------------
mkdir -p "$TMP/tree/a" "$TMP/tree/b"
echo one > "$TMP/tree/a/1.txt"; echo two > "$TMP/tree/b/2.txt"; echo three > "$TMP/tree/3.md"
$A s3 sync "$TMP/tree" s3://default/tree >/dev/null 2>&1
LS=$($A s3 ls s3://default/tree/ 2>&1)
assert "delimiter groups a folder"   "$LS" "PRE a/"
assert "delimiter groups the other"  "$LS" "PRE b/"
assert "…and a plain key still lists" "$LS" "3.md"

rm -rf "$TMP/tree2"
$A s3 sync s3://default/tree "$TMP/tree2" >/dev/null 2>&1
diff -r "$TMP/tree" "$TMP/tree2" >/dev/null 2>&1 && ok "sync down reproduces the tree" \
  || bad "sync down reproduces the tree" "trees differ"

# ---- multipart: aws switches to it above 8 MiB, so this is not optional ----------
head -c 30000000 /dev/urandom > "$TMP/big.bin"
$A s3 cp "$TMP/big.bin" s3://default/big.bin >/dev/null 2>&1
assert "multipart upload lands" "$($A s3 ls s3://default/ 2>&1)" "30000000 big.bin"
$A s3 cp s3://default/big.bin "$TMP/big-back.bin" >/dev/null 2>&1
cmp -s "$TMP/big.bin" "$TMP/big-back.bin" && ok "30 MB multipart round-trips byte-identically" \
  || bad "30 MB multipart round-trips byte-identically" "bytes differ"

# A large download is fetched as PARALLEL RANGED GETs. A server that ignores Range
# returns the whole object for each one and the client writes a corrupt file while
# reporting success — so this is a correctness test, not a performance one.
RNG=$($A s3api get-object --bucket default --key big.bin --range 'bytes=100-199' "$TMP/slice.bin" 2>&1)
assert "ranged GET answers 206 with Content-Range" "$RNG" '"ContentRange": "bytes 100-199/30000000"'
python3 - "$TMP" <<'PY' && ok "ranged bytes are the right bytes" || bad "ranged bytes are the right bytes" "mismatch"
import sys
t=sys.argv[1]
want=open(t+"/big.bin","rb").read()[100:200]
got=open(t+"/slice.bin","rb").read()
sys.exit(0 if want==got else 1)
PY

# ---- delete ----------------------------------------------------------------------
$A s3 rm s3://default/tree/3.md >/dev/null 2>&1
LS2=$($A s3 ls s3://default/tree/ --recursive 2>&1)
if printf '%s' "$LS2" | grep -qF "3.md"; then bad "DeleteObject removes the key" "still listed"; else ok "DeleteObject removes the key"; fi

rm -f "$TMP/tree/b/2.txt"
$A s3 sync "$TMP/tree" s3://default/tree --delete >/dev/null 2>&1
LS3=$($A s3 ls s3://default/tree/ --recursive 2>&1)
if printf '%s' "$LS3" | grep -qF "2.txt"; then bad "sync --delete prunes" "still listed"; else ok "sync --delete prunes"; fi

# ---- the refusals we promised ------------------------------------------------------
assert "public-read is refused, not downgraded" \
  "$($A s3api put-object --bucket default --key pub.txt --body "$TMP/tree/3.md" --acl public-read 2>&1)" \
  "InvalidArgument"
assert "?acl is NotImplemented, never a silent success" \
  "$($A s3api get-object-acl --bucket default --key big.bin 2>&1)" "NotImplemented"
assert "CreateBucket is refused — a bucket is a team" \
  "$($A s3api create-bucket --bucket newteam 2>&1)" "NoSuchBucket"
assert "an unknown access key" \
  "$(AWS_ACCESS_KEY_ID=TMXNOSUCHKEY000000AA $A s3 ls 2>&1)" "SignatureDoesNotMatch"
assert "a wrong secret is indistinguishable from an unknown key" \
  "$(AWS_SECRET_ACCESS_KEY=wrong $A s3 ls 2>&1)" "SignatureDoesNotMatch"
assert "no credentials at all" \
  "$(curl -s $E/ )" "AccessDenied"

# ---- slice 53: presigned URLs, CopyObject, versions --------------------------------
# The point of a presigned link is that it needs NO credentials, so it is fetched
# with plain curl and with the AWS environment deliberately cleared.
# by key, not "the first one" — the listing is ordered by key, so `head -1` picks
# whatever sorts first and the check then compares the wrong bytes
OID=$(curl -s "$B/api/repo" -H "Authorization: Bearer $TOK" | python3 -c "
import json,sys
print(next(o['id'] for o in json.load(sys.stdin)['objects'] if o['key']=='reports/q3.pdf'))")
PRE=$(curl -s -X POST "$B/api/repo-obj/$OID/presign?expires=900" -H "Authorization: Bearer $TOK")
URL=$(printf '%s' "$PRE" | grep -oP '"url":"\K[^"]+')
assert "presign returns a link" "$PRE" 'X-Amz-Signature='
CODE=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY curl -s -o "$TMP/pre.bin" -w '%{http_code}' "$URL")
assert "the link works with no credentials at all" "$CODE" "200"
cmp -s "$TMP/doc.pdf" "$TMP/pre.bin" && ok "presigned download is byte-identical" \
  || bad "presigned download is byte-identical" "bytes differ"

# tampering with a signed link must not work
TAMPER=$(printf '%s' "$URL" | sed 's/X-Amz-Expires=900/X-Amz-Expires=604800/')
assert "a stretched expiry is refused" \
  "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY curl -s "$TAMPER")" "SignatureDoesNotMatch"
SWAP=$(printf '%s' "$URL" | sed 's#/reports/q3\.pdf#/big.bin#')
if [ "$SWAP" = "$URL" ]; then bad "a link cannot be pointed at another key" "the URL never contained the key"; else
assert "a link cannot be pointed at another key" \
  "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY curl -s "$SWAP" | head -c 300)" "SignatureDoesNotMatch"
fi
# An expired link gets its own verdict, distinct from a bad signature, so the message
# can say what to do about it. Backdating X-Amz-Date is how a link ages instantly.
STALE=$(printf '%s' "$URL" | sed 's/X-Amz-Date=[0-9]*T[0-9]*Z/X-Amz-Date=20200101T000000Z/')
assert "an expired link says so, rather than blaming the signature" \
  "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY curl -s "$STALE")" \
  "This presigned URL has expired"

# CopyObject: content-addressed, so this moves no bytes
$A s3 cp s3://default/reports/q3.pdf s3://default/reports/q3-copy.pdf >/dev/null 2>&1
assert "CopyObject" "$($A s3 ls s3://default/reports/ 2>&1)" "q3-copy.pdf"
$A s3 cp s3://default/reports/q3-copy.pdf "$TMP/copy.pdf" >/dev/null 2>&1
cmp -s "$TMP/doc.pdf" "$TMP/copy.pdf" && ok "the copy has the same bytes" \
  || bad "the copy has the same bytes" "bytes differ"

# an overwrite versions rather than destroys, and ?versions can see both
head -c 5000 /dev/urandom > "$TMP/v2.pdf"
$A s3 cp "$TMP/v2.pdf" s3://default/reports/q3.pdf >/dev/null 2>&1
VERS=$($A s3api list-object-versions --bucket default --prefix reports/q3.pdf 2>&1)
assert "ListObjectVersions shows the current one" "$VERS" '"IsLatest": true'
assert "…and the one it replaced"                 "$VERS" '"IsLatest": false'
VID=$(printf '%s' "$VERS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
old=[v for v in d.get('Versions',[]) if not v['IsLatest'] and v['Key']=='reports/q3.pdf']
print(old[0]['VersionId'] if old else '')")
if [ -n "$VID" ]; then
  $A s3api get-object --bucket default --key reports/q3.pdf --version-id "$VID" "$TMP/old.pdf" >/dev/null 2>&1
  cmp -s "$TMP/doc.pdf" "$TMP/old.pdf" && ok "an earlier version is still fetchable by id" \
    || bad "an earlier version is still fetchable by id" "bytes differ"
else bad "an earlier version is still fetchable by id" "no prior version id"; fi

# Revocation is LAST on purpose: it kills the credential every check above uses, and
# every link signed with it. Running it earlier makes the rest of the suite fail for
# the wrong reason.
CID=$(printf '%s' "$CRED" | grep -oP '"id":\s*"\K[^"]+')
curl -s -X DELETE $B/api/s3/credentials/$CID -H "Authorization: Bearer $TOK" >/dev/null
assert "a revoked credential is refused" "$($A s3 ls 2>&1)" "SignatureDoesNotMatch"
assert "…and so is a link that was signed with it" \
  "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY curl -s "$URL")" "SignatureDoesNotMatch"

if [ $fail -eq 0 ]; then echo "s3-smoke: PASS"; else echo "s3-smoke: FAIL"; fi
exit $fail
