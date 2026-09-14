# Document Repository & S3 Endpoint — setup & test runbook

Operator-facing. How to stand the repository up, hand out S3 access, prove it
works with the clients your team actually uses, and read the failures. Design
rationale lives in
[../design/document-repository.md](../design/document-repository.md); this file is
the runbook. The workflow engine has its own:
[workflow-engine-runbook.md](workflow-engine-runbook.md) — the restart discipline
and process-management footguns documented there apply here unchanged.

**Everything below runs from `refimpl/racketmaximus/`.**

---

## 1. What you are deploying

Binary documents of any format — pdf, docx, png, svg, md, anything — with the
creator setting visibility, stored content-addressed, exposed three ways: the
console's **Repository** tab, a JSON API, and an **S3-compatible endpoint** that
`aws`, `rclone`, `boto3` and Cyberduck speak natively.

```
   aws · rclone · boto3 · Cyberduck        the console · /api/*
              │  SigV4                            │  Bearer token
              ▼                                   ▼
   ┌─────────────────────┐             ┌────────────────────┐
   │ S3 endpoint          │             │  JSON control plane │
   │ TELEMACHUS_S3_PORT   │             │  PORT (8835)        │
   │ (second listener,    │             │  serve/servlet      │
   │  web-kit/http1)      │             └─────────┬──────────┘
   └──────────┬──────────┘                        │
              └──────────────┬────────────────────┘
                             ▼
                 principal ──▶ can?   ◀── org gate, visibility,
                             │             grants, token scopes
                             ▼
                 repo_objects / repo_versions      (metadata, DB)
                             │
                             ▼
                 blob store  ─── $DATA_DIR/blobs/<org>/<ab>/<cd>/<sha256>
                 (rs3 plugin; content-addressed, dedup per org)
```

**Operational consequences:**

| Property | Comes from | What it means for you |
|---|---|---|
| One document, one copy | content addressing (SHA‑256) | identical uploads dedup **within an org**; two tenants never share bytes (that would be an existence oracle) |
| Overwrite = version | `repo_versions` | re-uploading a key keeps the old body; nothing is destroyed by a re-upload |
| Bucket **is** the team | DOC‑2 | a cross-team key is unrepresentable; `CreateBucket` is refused — teams come from the team API |
| Same authorization as the console | DOC‑1 | visibility, grants, the org gate and key scopes all apply to S3 requests; there is no second ACL system |
| Storage is metered | `storage.bytes` gauge | a quota refuses the upload **before** it is committed; deletes give the budget back |
| No 16-second stalls | `web-kit/http1` answers `Expect: 100-continue` in ~1 ms | the servlet never implements it and the AWS CLI waits 16 s per PUT — which is why S3 is a **second listener**, not a route |

---

## 2. Prerequisites

Nix is the toolchain — see the workflow runbook §2 for the full story. Everything
the repository needs is pinned in the flake, **including `poppler-utils`**
(`pdftotext`, used by content indexing) in both the dev shell and the built
package's PATH. There is nothing extra to install.

```sh
nix develop                              # dev shell, from the repo root
nix run github:IoTone/Telemachus/dev     # or run the packaged server directly
```

The `aws` CLI is only needed where you run the smoke test or a client — the
server itself never shells out to it.

---

## 3. Configuration

| Variable | Default | Notes |
|---|---|---|
| `TELEMACHUS_S3_PORT` | **unset = S3 off** | the S3 endpoint is surface area, and surface area is asked for. Set it (e.g. `8836`) to start the second listener |
| `TELEMACHUS_S3_REGION` | `us-east-1` | the region name signatures are checked against. It only has to **match what clients configure** — it does not have to mean anything |
| `TELEMACHUS_MAX_UPLOAD` | 32 MiB | single-request body ceiling on the JSON plane. The S3 plane streams and is not bound by it; `aws` switches to multipart above 8 MiB anyway |
| `TELEMACHUS_BLOB_STORE` | `rs3` | which registered blob backend holds the bytes |
| `TELEMACHUS_RS3_ROOT` | `$TELEMACHUS_DATA_DIR/blobs` | where `rs3` writes. **Back this up together with the database** — the DB holds metadata, this holds the documents |
| `TELEMACHUS_BIND` | `127.0.0.1` | both listeners bind the same address. Same guidance as the workflow runbook: a tailnet IP for a trial, never bare `0.0.0.0` without a front door |

> **The one that will burn you.** S3 credential **secrets are stored in the
> database in the clear** — SigV4 verification requires the raw secret, so there is
> nothing else to store (same trust boundary as `users.totp_secret`). The database
> file is the security boundary. What bounds a leaked key is its **scope list**,
> so issue read-only keys where read-only is enough, and treat revocation as the
> incident response — it takes effect on the next request and kills every
> presigned link made with that key.

---

## 4. Standing it up

```sh
export TELEMACHUS_S3_PORT=8836
racket server/main.rkt
# …
# telemachus server on http://127.0.0.1:8835  (… · max upload: 32 MiB)
# s3 endpoint on http://127.0.0.1:8836  (path-style · region us-east-1 · bucket = team slug)
```

### Mint an access key

In the console: **Repository → S3 access keys → Create token** — the panel shows
the endpoint, the bucket name and the exact commands to paste. Or over the API:

```sh
TOK=…            # a bearer token with tokens:manage (an owner/admin)
curl -s -X POST localhost:8835/api/s3/credentials \
     -H "Authorization: Bearer $TOK" -d '{"name":"laptop"}'
# {"access_key_id":"TMX…","secret_access_key":"tk_…", "scopes":["files:read","files:write","files:delete"], …}
```

**The secret is in that response and nowhere else, ever.** Default scopes cover
what a sync client needs (`aws s3 sync --delete` requires `files:delete`). For a
read-only key: `-d '{"name":"backup","scopes":["files:read"]}'`.

Revoke: `DELETE /api/s3/credentials/<id>`, or the Revoke button. List:
`GET /api/s3/credentials` — access key ids and scopes only, never secrets.

---

## 5. Client cookbook

Every client needs the same three things: the endpoint URL, **path-style
addressing**, and the region matching `TELEMACHUS_S3_REGION`. The bucket is your
**team slug** (shown in the console's S3 panel).

### aws CLI

```sh
export AWS_ACCESS_KEY_ID=TMX…
export AWS_SECRET_ACCESS_KEY=tk_…
export AWS_DEFAULT_REGION=us-east-1
# aws-cli ≥ 2.23 defaults to CRC64 trailer framing that S3-compatible servers
# (this one included) answer with NotImplemented — this reverts to plain bodies:
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required

aws --endpoint-url http://HOST:8836 s3 ls s3://default/
aws --endpoint-url http://HOST:8836 s3 cp report.pdf s3://default/reports/
aws --endpoint-url http://HOST:8836 s3 sync ./docs s3://default/docs --delete
```

`cp` of anything over 8 MiB automatically uses multipart, and downloads use
parallel ranged GETs — both are implemented, both are in the smoke test.

### rclone

```ini
# ~/.config/rclone/rclone.conf
[telemachus]
type = s3
provider = Other
access_key_id = TMX…
secret_access_key = tk_…
endpoint = http://HOST:8836
region = us-east-1
force_path_style = true
```

```sh
rclone ls telemachus:default
rclone sync ./docs telemachus:default/docs
```

### boto3

```python
import boto3
from botocore.config import Config

s3 = boto3.client("s3",
    endpoint_url="http://HOST:8836",
    aws_access_key_id="TMX…", aws_secret_access_key="tk_…",
    region_name="us-east-1",
    config=Config(s3={"addressing_style": "path"},
                  request_checksum_calculation="when_required"))
s3.upload_file("report.pdf", "default", "reports/report.pdf")
```

### Cyberduck

New connection → **S3 (HTTP)** → server `HOST`, port `8836`, access key / secret
from the console. Tick *path-style requests* if the profile offers it.

### Presigned links (no client, no account)

The console's **Link** button on any document, or:

```sh
curl -s -X POST "localhost:8835/api/repo-obj/<id>/presign?expires=900" \
     -H "Authorization: Bearer $TOK"
# {"url":"http://HOST:8836/default/reports/report.pdf?X-Amz-Algorithm=…","expires_in":900,…}
```

Anyone with the URL can download for `expires` seconds (max 604800 = 7 days) with
no credentials at all. The link is signed with **the caller's own newest S3 key**:
it can never do more than that key, and revoking the key kills the link. The
response is always `Content-Disposition: attachment` — a browser downloads, it
never renders, which is the stored-XSS defence (DOC‑10) holding on the link path.

---

## 6. Verification

### The smoke test — run this after any deploy

```sh
bash test/s3-smoke.sh          # boots its own server on a temp DB; ~33 checks
# s3-smoke: PASS
```

It exercises, with the **real `aws` CLI**: cp both directions byte-compared,
sync up/down/--delete, folder listing, HeadObject, a 30 MB multipart round-trip,
ranged GET with byte comparison, presigned links (works with no credentials;
tampered expiry refused; expired link says so), CopyObject, object versions, and
every refusal — public ACLs, `?acl`, CreateBucket, bad/revoked credentials.
Skips cleanly (exit 0) if `aws` is absent, so it is CI-safe.

### By hand, against a live instance

```sh
# the endpoint answers, and refuses anonymous requests properly
curl -s http://HOST:8836/            # <Error><Code>AccessDenied</Code>…

# a credentialed ListBuckets shows exactly your team
aws --endpoint-url http://HOST:8836 s3 ls

# upload → download → compare is the only test that matters
head -c 1000000 /dev/urandom > /tmp/x.bin
aws --endpoint-url http://HOST:8836 s3 cp /tmp/x.bin s3://default/x.bin
aws --endpoint-url http://HOST:8836 s3 cp s3://default/x.bin /tmp/y.bin
cmp /tmp/x.bin /tmp/y.bin && echo byte-identical
```

### The unit tiers

```sh
raco test test/sigv4-tests.rkt    # 64 cases: AWS's published vectors + captured aws-cli requests + presign rules
raco test test/repo-tests.rkt     # 74: round-trips, visibility, versions, dedup, org isolation, quota gauge
raco test test/http1-tests.rkt    # 46: the listener — 100-continue, chunked, keep-alive, over raw TCP
raco test test/index-tests.rkt    # 17: extractors + the indexing pipeline through the real scheduler
raco test test/fold-tests.rkt     # migration 0022 against a database with pre-fold documents
bash test/server-smoke.sh         # the JSON plane, incl. repository + search + indexing blocks
```

---

## 7. The security model, on one page

- **A bucket is a team.** The path's first segment must be *your* team's slug;
  any other answers `NoSuchBucket` — not `AccessDenied`, because the existence of
  other teams is itself private.
- **Every request becomes an ordinary principal** and goes through `can?`: the
  org gate first, then visibility (`private`/`team`/`shared`), owner-ok, resource
  grants, and the credential's scopes. There is no S3-side ACL system to keep in
  sync.
- **The creator sets visibility**, including over S3: `x-amz-meta-visibility:
  private|team|shared`, or `x-amz-acl: private` / `authenticated-read`.
  **`public-read` is refused** (`400 InvalidArgument`) rather than silently
  downgraded — a link someone believes is public and is not would be worse.
- **Unimplemented sub-resources answer 501**, never a silent success: `?acl`,
  `?policy`, `?lifecycle`, `?cors`, `?tagging`, … A swallowed bucket policy —
  an operator believing an access rule is in force when nothing stored it — is
  the worst failure this endpoint could have.
- **A wrong secret and an unknown access key are indistinguishable**
  (`SignatureDoesNotMatch` for both), and signature comparison is constant-time.
- **SVG/HTML never render from this origin.** Every download is an attachment
  with `nosniff` and a denying CSP; active types are additionally served as
  `application/octet-stream`. "Any format" is about storage, not about what a
  browser can be talked into executing.
- **Audit:** credential create/revoke, every write, visibility change, share and
  delete land in `audit_log`.

---

## 8. Storage quotas

`storage.bytes` is a **gauge** on the ordinary quota ledger: `+size` on write,
`−size` on delete, window `total`.

```sh
# cap the team at 10 GB
curl -s -X POST localhost:8835/api/quota -H "Authorization: Bearer $TOK" \
     -d '{"dimension":"storage.bytes","limit":10737418240,"window":"total"}'
```

An over-budget upload is **refused before the object is committed** — over S3 it
surfaces as `400 InvalidRequest` with *"storage quota exceeded: N of M bytes
used"*. Deleting documents frees budget immediately. Current usage is on the
Repository tab header and in `GET /api/repo` under `usage`.

Org limits nest above team limits exactly as they do for AI spend
(`subject_type: "org"`); admission requires both.

---

## 9. Content indexing (search inside documents)

Uploaded documents are searchable **by path immediately** and **by content after
indexing**. Indexing is the `index-documents` workflow (plugin `doc-indexer`):
find what is unindexed → fan out → extract. txt/md/csv, html/xml/svg
(tag-stripped), docx, and pdf via `pdftotext`.

Run it from the console's **Workflows** tab, or:

```sh
curl -s -X POST localhost:8835/api/workflows/index-documents/run \
     -H "Authorization: Bearer $TOK" -d '{}'
```

Operational facts your team should know:

- **≤ 40 documents per run**, oldest first, and it is idempotent — re-run until a
  run fans out over nothing to drain a backlog. A nightly cron of the `curl`
  above is the whole "pipeline".
- **An overwrite re-indexes exactly that document** on the next run (staleness is
  keyed to the current version). Deleting a document removes its text.
- **A corrupt or mislabeled file cannot wedge indexing**: it is recorded as
  processed-with-nothing and the run continues. The one hard failure is
  `pdftotext is not installed` — deliberate, because that is a fix you can make
  (it is already pinned in the Nix package; you only see this off-Nix).
- **Quota admission gates indexing too.** A team over its `ai.tokens.total`
  budget has its workflow steps *deferred* — the run sits `running` with steps
  `queued`. That is deferral working as designed, in a place nobody expects it.
- Extracted text is **derived and disposable** (`repo_text`): it is not part of
  backup-critical state, and a re-run rebuilds it.

---

## 10. Failure modes

Ordered by how often they will actually happen.

| Symptom | Cause | Fix |
|---|---|---|
| `NotImplemented` on every upload from aws-cli ≥ 2.23 | CRC64 **trailer** framing (`STREAMING-*` payloads) | `export AWS_REQUEST_CHECKSUM_CALCULATION=when_required` — plain bodies verify fine, checksum headers included |
| `SignatureDoesNotMatch` | wrong secret, **revoked key**, or the client's region ≠ `TELEMACHUS_S3_REGION` | re-check all three; an unknown key reports identically on purpose |
| `RequestTimeTooSkewed` | client clock more than 15 min off | fix the clock — the message says so, distinct from a bad signature |
| "This presigned URL has expired. Ask for a new link." | exactly that | mint a new link; expiry is deliberate and separate from signature failure |
| `NoSuchBucket` for a bucket that "exists" | the slug belongs to another team, or a typo | the bucket is *your* team's slug — check the console's S3 panel |
| A downloaded large file is corrupt but the client said success | a proxy in front stripped/ignored `Range` — the server itself answers `206` correctly | test without the proxy; `aws s3 cp` fetches big objects as parallel ranged GETs, so Range handling is **correctness**, not tuning |
| `400 InvalidRequest: storage quota exceeded…` | the gauge is at its limit | delete something or raise the limit (§8) |
| Uploads over the JSON plane fail at exactly 32 MiB with a dropped connection | `TELEMACHUS_MAX_UPLOAD` — the servlet drops, it cannot 413 | raise the variable, or use the S3 plane, which streams |
| PDFs never become content-searchable; runs error with "pdftotext is not installed" | off-Nix host without poppler | use the Nix package (pinned) or install `poppler-utils` |
| Indexing run sits `running`, steps `queued`, forever | quota deferral (§9) | check `GET /api/usage`; raise or wait |
| an upload into a triggered prefix did nothing, and the trigger's history says `workflows:run` | the S3 key was issued with the default `files:*` scopes, and a triggered run executes as the uploader with the key's scopes (DWF‑2) | issue the key with `"scopes":["files:read","files:write","files:delete","workflows:read","workflows:run"]` — `POST /api/s3/credentials`; the fire is recorded on the trigger (`GET /api/doc-triggers/<id>`), the upload itself landed |
| `?acl` / `?policy` / lifecycle tooling errors with 501 | not implemented, by design | manage sharing in the console or `POST /api/repo-obj/<id>/share {principal_type: user\|team, principal_id, capability: view\|edit\|manage, expires_at?}` — S3 has no vocabulary for this instance's ACLs |
| S3 port answers nothing at all | `TELEMACHUS_S3_PORT` unset — off is the default | set it and restart |

---

## 11. Backup & upgrade

- **Two things hold state, and they travel together:** the database
  (`repo_objects`, `repo_versions`, `repo_credentials`, grants, quotas) and the
  blob directory (`$TELEMACHUS_DATA_DIR/blobs/`). A database backup without the
  blobs is a card catalog for a burned library. Blobs are content-addressed and
  immutable once written, so incremental backup tools handle the directory well.
- `repo_text` (extracted search text) is derived — excluded from backups at no
  cost; one indexing sweep rebuilds it.
- **Migration `0022` folded the old `documents` table into the repository.** It
  runs automatically at startup, moves each body into the blob store, keeps every
  id (grants and links survive), and drops the table. `/api/documents` still
  works — it is a shim. First startup after upgrading a database that has many
  documents will spend a moment writing blobs; that is the fold happening.
- Roll forward only, as with all migrations.
