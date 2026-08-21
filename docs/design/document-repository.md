# Document Repository — binary documents behind an S3 API

**Status:** slices 49–54 **built** — the repository, its console, the HTTP listener,
the S3 endpoint, presigned links, and content indexing (a PDF is searchable by what
it *says*). `aws s3 cp/ls/sync/rm`, `rclone` and any other
S3 client work against a live instance today. DOC‑14 is settled — search covers the
repository now, the fold is slice 55. The four questions at the end remain open.
**Depends on:** `can?` + the org gate (TEN‑2), the quota ledger, the plugin loader,
and the `documents` table from slice 26.
**Related:** [rbac-and-teams.md](rbac-and-teams.md) (visibility + grants),
[quotas.md](quotas.md) (QUOTA‑1 deferred storage — this cashes it in),
[workflow-engine.md](workflow-engine.md) (the natural home for extraction pipelines).

## The requirement

*"An internal document repository, not based on a pure text document. Access
controlled across a team, where the creator can set the visibility. Documents can be
any format: pdf, svg, png, jpg, docx, xml, txt, md. An S3-compatible store API as
the interface exposed, backed locally as a plugin (rs3)."*

Four demands, and only one of them is about storage:

1. **Bytes, not text.** A document is an opaque octet stream with a content type.
   Nothing may assume it is UTF‑8, small, or renderable.
2. **The creator sets visibility.** Not an administrator, not a default — the person
   who uploads decides who else in the team can see it.
3. **A standard protocol at the edge.** The interface is S3, so that `aws s3 sync`,
   `rclone`, `boto3` and Cyberduck are the client library and nobody writes one.
4. **A swappable local backend.** `rs3` stores the bytes on this machine; the seam
   admits something else later without the API changing.

Demand 3 is the one that forces a design, because **S3's authorization model and
Telemachus's do not overlap at all.** S3 knows an access key and a bucket policy. It
has no concept of a team, an owner, a visibility, or a resource grant — and no way
for a client to express one. Everything below follows from refusing to resolve that
by weakening `can?`.

## What already exists

More than expected. The gap is bytes and a protocol, not a security model.

| Piece | Where | What it gives the repository |
|---|---|---|
| `can?` | `domain/authz/authz.rkt` | org gate at step 0, `visibility` of `private`/`team`/`shared`, owner-ok, resource grants, token scopes — the *entire* access-control requirement, already built and tested |
| `documents` | migration `0008` | `team_id` + `owner_user_id` + `visibility` + timestamps. The right row shape; the wrong body column (`content TEXT`) |
| `resource_grants` | migration `0001` | per-user and per-team grants on `(resource_type, resource_id)` — how `shared` is expressed |
| `files:read` / `files:write` | `domain/authz/permissions.rkt` | **already in the catalog**, granted to `admin` and `member`, and referenced by no code anywhere. The vocabulary anticipated this subsystem |
| Asset store | `domain/beta/assets.rkt` | the shape of a blob store, at prototype scale — and a working demonstration of why base64‑in‑a‑column does not scale (see below) |
| Quota ledger | `domain/quota/quota.rkt` | signed amounts + a non-windowed window give a *gauge*, which is what stored bytes need |
| Plugin loader | `domain/agent/plugins.rkt` | `dynamic-require` with defaults; `init!` for registering anything |
| Provider registry | `domain/beta/beta.rkt` | the precedent for a named, env-selected, plugin-supplied implementation — exactly the `rs3` seam |

```
  TODAY                                     MISSING
  ────────────────────────────────────      ────────────────────────────────────
  can? ── org gate, visibility, grants      a place to put 40 MB of PDF
       └── already the whole ACL story

  documents ── team/owner/visibility        a body that is not TEXT
            └── right row, wrong column

  /api/*  ── JSON, bearer tokens            SigV4, XML, buckets and keys

  assets ── base64 in a column, 2 MiB       a content-addressed blob store
```

## What we verified in the code

Five findings that change the design, each measured against a running system rather
than assumed. The last one is a blocker.

**1. The server cannot accept a request body over 1 MiB — and fails silently.**
*(Fixed — see below.)*
`web-kit`'s `serve` never passes `#:safety-limits`, so Racket's default applies:
`max-request-body-length` is `(* 1 1024 1024)`
(`web-server-lib/web-server/safety-limits.rkt:77`). Measured against a live server:

```
1.5 MB body → 000   (connection dropped, no HTTP response at all)
0.5 MB body → 401   (reaches the handler, gets authorized normally)
```

A document repository is not possible without raising this. Worse, the failure mode
is a dropped connection — no status, no message, nothing in the log.

**Fixed ahead of the proposal**, because findings 1 and 2 are a live bug independent
of whether any of this is built: `web-kit`'s `serve` now takes `#:max-body-length`
and passes a `safety-limits` through, the server reads `TELEMACHUS_MAX_UPLOAD`
(default 32 MiB) and prints it at startup. Re-measured:

```
telemachus server on http://127.0.0.1:8876  (… · max upload: 32 MiB)
0.5 MB → 401      1.5 MB → 401      8 MB → 401      40 MB → 000
```

A 1.2 MB asset now uploads and round-trips at exactly 1 200 000 bytes. Note what did
*not* change: past the new ceiling the connection is still dropped rather than
answered `413`. Only DOC‑15's own listener fixes that.

**2. That limit already makes an existing feature not work as documented.**
`assets.rkt` advertises a 2 MiB cap on brand images, but uploads arrive as base64
inside a JSON body — a 4/3 inflation. Anything over roughly **786 KiB decoded** is
dropped by the transport before `asset-store!` ever runs, so its own size check is
unreachable. This was a live bug, found while surveying, and finding 1's fix clears
it. It is also the argument against reusing that storage strategy.

**3. SHA‑256 is available under Nix — in the dev shell *and* in the built package.**
`domain/authz/crypto.rkt` hand-rolls HMAC‑SHA1 and PBKDF2 on the runtime's
`sha1-bytes` because minimal-racket ships no other hash, and SigV4 needs SHA‑256 and
HMAC‑SHA256. Measured:

| Runtime | `openssl/libcrypto` | HMAC‑SHA256 |
|---|---|---|
| `nix develop` | `#<ffi-lib>` | works — verified against the RFC test vector |
| the `nix build` closure, bare env | `#<ffi-lib>` | resolves; the Racket derivation carries openssl |

Nix is the toolchain. (The linuxbrew path is abandoned — it is where the GLIBC and
`libcrypto` breakage lives, and it has no SHA‑256 at all.) This removes about 150
lines of hand-rolled hash code from the plan. See DOC‑7.

**4. `Expect: 100-continue` is unimplemented, and it costs 16 seconds per upload.**
The AWS clients send `Expect: 100-continue` on every `PUT` and wait for the interim
response before sending a byte. `web-server-lib` contains no `100 Continue` handling
anywhere — grepped, under the Nix Racket 9.2 tree. Measured against a listener that
reproduces that behaviour:

```
PUT /mybucket/t.txt   Expect:true   headers@0.000s   first body byte@16.016s
```

**Sixteen seconds, for a 17-byte file.** It is not a client misconfiguration and
there is no opt-out: `aws s3 cp` (the CRT path) and `aws s3api put-object` (the
botocore path) both do it, and `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`
does not change it. Nor can the application fix it — by the time a handler runs,
`request-post-data/raw` has already blocked on the body that the client is refusing
to send. This is the single hardest constraint found, and it is the reason for
DOC‑15.

**5. The quota ledger can already express a gauge.** `window-clause` falls through
to `"1 = 1"` for any window that is not `day` or `minute`, so a dimension summed
over window `"total"` sums the whole ledger. Record `+size` on write and `−size` on
delete and `quota-used` returns bytes currently stored — no schema change, no second
metering path. See DOC‑11.

---

## The design

### DOC‑1 — S3 is a transport. `can?` is still the contract.

The single position everything else hangs from:

> **The S3 endpoint is a second front door onto the same authorization. It is never
> a second authorization system.** A request arriving over SigV4 is resolved to a
> Telemachus principal, and from that point it is indistinguishable from a request
> that arrived with a bearer token. Every read and write goes through `can?` with a
> resource hash, so the org gate, visibility, owner-ok, grants and token scopes all
> apply unchanged.

This is the same move `define-workflow` made (WF‑1): one normative implementation,
two surfaces onto it. The consequence to accept up front is that **some things S3
clients expect will be refused**, because they would express an authorization we do
not have — bucket policies, public ACLs, cross-account grants. That refusal is the
design, not a gap (compare WF‑10).

```
   aws-cli · rclone · boto3 · Cyberduck        the console · /api/*
              │  SigV4                                │  Bearer
              ▼                                       ▼
        ┌───────────────┐                    ┌────────────────┐
        │ S3 front door │                    │  REST handlers │
        │  XML · SigV4  │                    │  JSON · tokens │
        └───────┬───────┘                    └────────┬───────┘
                └──────────────┬─────────────────────┘
                               ▼
                    principal ──▶ can?  ◀── org gate, visibility,
                               │            grants, token scopes
                               ▼
                    repo_objects / repo_versions   (metadata, DB)
                               │
                               ▼
                    blob store seam  ─── put!/get/delete! by content hash
                               │
                 ┌─────────────┴─────────────┐
              rs3 (local FS)            future: MinIO, S3, NFS
```

### DOC‑2 — A bucket is a team. Path-style only.

| Option | |
|---|---|
| **Bucket ≡ team** ✅ | `s3://<team-slug>/<key>`. `ListBuckets` returns the teams the caller can reach — which the org gate already scopes correctly under multi-tenancy. `CreateBucket`/`DeleteBucket` return `NotImplemented`: teams are created through the team API |
| One bucket, team-prefixed keys | isolation becomes a string convention in a key, which is exactly the kind of thing that later gets bypassed |
| User-created buckets | a second namespace with its own lifecycle and its own authorization questions, for no gain |

Bucket ≡ team means **a key cannot name another team's object.** The boundary is
structural rather than checked, and the check still runs anyway.

Addressing is **path-style** (`https://host/bucket/key`). Virtual-host style
(`bucket.host`) needs wildcard DNS and a wildcard certificate, which is a poor fit
for a self-hosted instance on a tailnet. Every S3 client supports path-style
(`--endpoint-url` plus `addressing_style=path`); the runbook will carry the two-line
config for each. The signed region is a constant, `TELEMACHUS_S3_REGION`, default
`us-east-1` — SigV4 requires *a* region, it does not require it to mean anything.

### DOC‑3 — S3 credentials are a new credential kind, and the secret is recoverable

SigV4 is an HMAC over the canonical request keyed by the secret. **Verifying a
signature requires the verifier to hold the secret**, so the existing `api_tokens`
scheme — SHA‑1 of the token, prefix kept for display — cannot be reused. There is no
way to check an HMAC against a hash.

```
repo_credentials
  id, user_id, team_id, name,
  access_key_id   TEXT UNIQUE   -- public half, shown in listings
  secret_enc      TEXT          -- see below
  scopes          TEXT          -- JSON array; same ∩ semantics as api_tokens (RBAC-4)
  status, expires_at, last_used_at, created_at
```

The secret is stored encrypted with a key from `TELEMACHUS_SECRET_KEY`, falling back
to plaintext with a startup warning when unset. State the trust level plainly:
**this is weaker than the bearer tokens**, and the precedent already exists —
`users.totp_secret` is a recoverable secret in the same database, for the same
reason (TOTP verification also needs the raw value). A credential is scoped exactly
like an API token, so a leaked S3 key is bounded by its scope list, not by the
issuer's full rights.

Credentials are managed in the Team tab beside API tokens, and the secret is shown
once.

### DOC‑4 — The creator sets visibility, in S3's own vocabulary

The default for a new object is the team's configured default (`team`, matching
notes and documents). The uploader overrides it two ways:

| Request header | Visibility | |
|---|---|---|
| `x-amz-meta-visibility: private\|team\|shared` | as named | the explicit control; wins if both are present |
| `x-amz-acl: private` | `private` | creator only |
| `x-amz-acl: authenticated-read` | `team` | "authenticated" scoped to this bucket = this team |
| `x-amz-acl: bucket-owner-read`, `bucket-owner-full-control` | `team` | the bucket owner *is* the team |
| `x-amz-acl: public-read`, `public-read-write`, `aws-exec-read` | **refused** — `400 InvalidArgument` | there is no anonymous read on a privacy-first instance. Failing loudly beats silently downgrading to `private` and letting someone believe a link is public |
| *(absent)* | team default | |

`GET` and `HEAD` return `x-amz-meta-visibility`, so a client can read back what it
set. Changing visibility later needs `documents:write` on the object, which
owner-ok already grants the creator.

`shared` is the honest edge: it means "private plus an explicit grant list", and S3
has no way to name a grantee that maps to a Telemachus user. Setting `shared` over
S3 therefore produces an object that behaves as `private` until someone is granted
access through the console or the REST API. Documented, not papered over.

### DOC‑5 — Bytes live in a content-addressed store behind a plugin seam

Metadata in the database, bytes in a store addressed by the SHA‑256 of their
content. Identical uploads collapse to one blob with a refcount; an overwrite that
changes nothing costs nothing.

The seam is a registry in the shape of the onboarding provider registry, so a plugin
supplies it and an environment variable selects it:

```racket
(register-blob-store! "rs3"
  (hasheq 'put!    (lambda (digest bytes) ...)     ; idempotent
          'get     (lambda (digest) ...)           ; -> input-port
          'delete! (lambda (digest) ...)
          'stat    (lambda (digest) ...)))         ; -> size or #f
```

`TELEMACHUS_BLOB_STORE` picks one; default `rs3`. **The store never sees a
principal, a team, a key or a filename** — only a digest and bytes. A blob backend
therefore cannot make an authorization decision, because it is never given one to
make, and a third-party or remote backend does not widen the trust boundary beyond
"can read the bytes it holds".

`rs3` — the shipped local implementation — writes
`$TELEMACHUS_DATA_DIR/blobs/<ab>/<cd>/<digest>`, two levels of fan-out so no
directory holds a million entries, with `fsync`-then-rename for atomic writes. It
ships as a normal plugin under `plugins/rs3/`.

### DOC‑6 — The content-address namespace is scoped per org

Global deduplication across tenants is an **existence oracle**: upload a file,
observe that it completed suspiciously fast or that the refcount rose, and you have
learned that another tenant holds that exact file. For a platform whose first
property is isolation, that is not an acceptable trade for disk.

Digests are therefore namespaced by org (`<org_id>/<digest>` at the store layer).
Dedup still works where it matters — within a company, across its teams — and stops
at the boundary the org gate already defends. Single-tenant instances have one org,
so nothing is lost there.

### DOC‑7 — SHA‑256 and HMAC‑SHA256 from libcrypto

`openssl/libcrypto` resolves under Nix in both the dev shell and the built package
(finding 3), and Nix is the toolchain. So SigV4's hashing is an FFI call to a library
already in the closure, dispatched exactly the way `passwords.rkt` prefers argon2
when it is present:

```racket
(define sha256    (if libcrypto (libcrypto-sha256)    (error 'sigv4 "…")))
(define hmac-sha256 ...)
```

Pin it to the RFC test vectors in the unit suite regardless — the vectors are the
cheap part and they catch an FFI signature mistake immediately.

A pure-Racket SHA‑256 stays *available* as a fallback if a no-FFI deployment ever
matters, but it is no longer on the critical path: dropping the linuxbrew toolchain
removed the only environment that needed it, and with it about 150 lines of
hand-rolled hash code.

### DOC‑8 — Uploads buffer, downloads stream

Two different constraints, and being honest about the asymmetry is better than
implying symmetry that is not there.

- **Down:** `response/output` hands us a port, so `GET` streams from the blob store
  in chunks and never holds an object in memory. `Range: bytes=` is supported and
  answers `206` — PDF viewers and video scrubbing depend on it.
- **Up:** `request-post-data/raw` buffers the whole body. So a single `PUT` is
  capped at `TELEMACHUS_MAX_UPLOAD` (proposed default **32 MiB**), and *that* is the
  number `safety-limits` is raised to. Concurrent uploads multiply against RAM,
  which the scheduler's per-team concurrency cap already bounds.
- **Larger than the cap:** S3's own answer, multipart upload. `CreateMultipartUpload`
  / `UploadPart` / `CompleteMultipartUpload`, each part under the cap, assembled
  server-side on completion. `aws s3 cp` does this automatically above its threshold.
  This is how a 5 GB object works without streaming ingest.

True streaming ingest needs `web-kit`'s `serve` to expose the request's input port —
a real change, deferred to a later slice and noted rather than hidden.

### DOC‑9 — Overwrite creates a version; S3's `versionId` addresses it

A repository whose users are told to "just re-upload it" needs history. An overwrite
writes a new `repo_versions` row rather than mutating the current one — the same
move `flow-publish!` makes for workflow definitions.

```
repo_objects                          repo_versions
  id, team_id, owner_user_id            id, object_id, digest, size,
  key            (path within team)     content_type, etag,
  visibility     (private|team|shared)  created_by, created_at
  current_version_id
  created_at, updated_at
```

`GET ?versionId=<id>` fetches an old version; clients that know nothing about
versioning always see the current one. `ListObjectVersions` is deferred to v2.
`etag` is the content digest, which makes `aws s3 sync` skip unchanged objects for
free.

### DOC‑10 — Active content is served as an attachment, never inline

The requirement names **svg** explicitly, and SVG is a script-bearing document. So
are `text/html` and, in some browsers, `application/xml`. Serving one inline from
the application's own origin hands the uploader script execution in every viewer's
session — a stored XSS with the whole console behind it.

Every object response therefore carries `Content-Disposition: attachment`,
`X-Content-Type-Options: nosniff`, and a `Content-Security-Policy: default-src
'none'; sandbox`. Content types outside a small inline allowlist (images that are
not SVG, PDF, plain text) are additionally rewritten to
`application/octet-stream` on the wire. Preview of active content — if it is wanted
— belongs behind a separate origin, and that is a deliberate later decision rather
than a default anyone falls into.

### DOC‑11 — `storage.bytes` is a signed, non-windowed quota gauge

`+size` on write, `−size` on delete, dimension `storage.bytes`, window `"total"`.
`quota-check` then admits or refuses an upload before a byte is stored, and the org
limit nests above the team limit exactly as it does for AI spend. This cashes in the
"defer storage" note in QUOTA‑1 with no new mechanism.

Refusal returns HTTP `403` with a non-standard `QuotaExceeded` code. S3 has no
vocabulary for this condition; inventing a code and documenting it is more honest
than reusing `AccessDenied` for something that will clear when someone deletes a
file.

### DOC‑12 — The REST API stays the control plane

S3 is the **data plane**: put, get, list, delete, version. Everything S3 cannot
express stays on `/api/*` and in the console — granting a specific colleague access,
listing who has access, changing an owner, searching, and the audit trail. Two
surfaces with a clean split, rather than one surface that is bad at half its job.

### DOC‑13 — Unknown sub-resources are refused, not ignored

`PUT /bucket/key?acl`, `?policy`, `?lifecycle`, `?replication`, `?website`,
`?cors`, `?tagging` and friends answer `501 NotImplemented` with S3's own error
shape. Silently accepting and discarding a bucket policy would let an operator
believe an access rule is in force when it is not — the worst possible failure for
this subsystem. Same principle as WF‑10.

### DOC‑14 — Relationship to the existing `documents` table *(decided: fold, later)*

`documents` (slice 26) is a text-body app backing research and document translation.
The repository is the general case. The end state is one concept — a text document is
an object with `content_type: text/markdown` — but getting there is a real migration,
not a view: documents carry a `title` where objects carry a `key` (titles are neither
unique nor paths, so the fold needs a key derivation), and `documents` has no
`org_id`. `/api/documents` is public, so it is a breaking change whenever it happens.

**What was actually costing something was not the duplication — it was search.**
`search.rkt` indexed `documents` and had never heard of `repo_objects`, so a text
document was findable and an identically-named uploaded PDF was invisible. Same
person, two tabs, opposite behaviour, no explanation. And slice 54 — extract text and
index it — cannot be written without answering this, because it must either index
both (adding a second path and cementing the split) or fold first. Deferring past 54
is not deferring; it is choosing the split by default, in the place hardest to undo.

**Decided: index repository objects in search now, fold in its own slice.** Search
covers `repo_objects` by key and filename (bytes stay opaque until extraction), which
removes the user-visible inconsistency for a few dozen lines and does not pre-commit
the migration. The fold is slice 55.

The remaining implications, for whoever picks up 55:

| | |
|---|---|
| Two tabs, near-identical names | "Documents" and "Repository". Someone told to file the spec must choose, and the consequences are invisible: searchable? versioned? shareable by link? |
| Two permission families | `documents:*` and `files:*` sit in the same three roles. Customising a role means doing it twice |
| Asymmetric capabilities | Objects get versions, S3, presigned links, dedup, storage quota; documents get the translate/research apps. Neither is a superset |
| Monotonic waiting cost | The rows and the habits to migrate only grow |

---

### DOC‑15 — The S3 data plane needs its own HTTP listener

Three of the five findings — the 1 MiB body cap, the absence of `Expect:
100-continue`, and the inability to stream an upload — are all the same problem
wearing different hats: `web-kit`'s `serve` is `serve/servlet`, which reads the
entire body into memory before a handler runs, and never speaks the interim
response the client is waiting for. **No amount of S3 protocol code fixes any of
them**, because they are all resolved below the handler.

| Option | |
|---|---|
| **A purpose-built HTTP/1.1 listener in `web-kit`, mounted for `/s3/*` only** ✅ | request line + headers, `Expect: 100-continue`, keep-alive, `Content-Length` and chunked bodies exposed as an *input port*. Solves all three at once and leaves the JSON control plane on `serve/servlet` untouched. Bounded: the S3 data plane needs six methods and no cookies, sessions, or templating |
| Patch Racket's `web-server` request reader | the fix belongs upstream, but it forks a dependency and the body is still buffered |
| Front it with nginx or Caddy | terminates `Expect` and raises the body cap, and would be wanted for TLS anyway — but it is a second daemon, its own `client_max_body_size` and buffering rules, and one more thing an operator must get right |

Recommend the listener. It is the largest single piece of work in this proposal and
the estimate should say so plainly. It is also the piece that makes streaming ingest
possible later without another redesign, and `web-kit` is already the project's own
HTTP seam — this is what that seam is for.

**Built, and one design choice is worth recording.** `100 Continue` is emitted
**lazily — on the first read of the body, not when the headers are parsed.** A
handler that refuses before touching the body (401, 403, over quota) therefore
causes the client never to send it at all: the bytes of a rejected 2 GB upload stay
on the client, and because nothing was ever in flight the connection is still clean
enough to reuse. Eager emission — which is what a naive implementation does — throws
away exactly the property the mechanism exists for. Pinned by a test that offers a
`Content-Length: 2000000000` and asserts the 401 comes back with no body sent.

The same state that makes that possible answers "may this connection be reused?"
without peeking at the body port — a peek would fire the continue the handler
declined to ask for. A small unread remainder is drained so the connection survives;
past 64 KiB the server closes rather than spend unbounded time draining an upload it
already refused.

Raising `safety-limits` on the existing `serve/servlet` still happens regardless: it
is what fixes the asset-upload bug (finding 2), and it is one line.

### DOC‑16 — Build from the specification; read the Node servers, don't port them

The question of whether to port an existing TypeScript implementation resolves into
three distinct things, and only one of them should be a port.

**The specification is the source.** SigV4 is fully and publicly specified, and AWS
publishes an official [Signature Version 4 test suite][sigv4-suite] — for each case,
the canonical request, the string to sign, and the expected signature. That makes
correctness *objective*: the algorithm is roughly 250 lines and the vectors say
whether it is right. Building from the spec against those vectors is both faster
than translating TypeScript idioms into Racket and free of any licensing question.

**One implementation is worth reading closely.** [`scality/Arsenal`][arsenal],
Apache‑2.0, is the auth core of Zenko CloudServer — a production S3 server written
in TypeScript — and `lib/auth/v4/` is precisely the server side of SigV4 in about
nine files: `createCanonicalRequest.ts`, `constructStringToSign.ts`,
`headerAuthCheck.ts`, `queryAuthCheck.ts` (presigned URLs), `awsURIencode.ts`,
`timeUtils.ts`, `validateInputs.ts`, and a `streamingV4/` directory. It is the right
size to read in an afternoon, and its value is in the edge cases the specification
underplays — URI encoding rules, which headers are signed, clock-skew tolerance.

> **License, stated plainly.** Apache‑2.0 is permissive but it is **not** MIT: it
> carries attribution and NOTICE obligations, and a line-by-line port is a
> derivative work. Shipping one into this repository would mean that subtree is no
> longer purely MIT. Given the project already keeps `docs/provenance/`, the
> discipline exists — but the recommendation is to **read Arsenal for understanding
> and write from AWS's specification**, so the question does not arise. If a port is
> preferred anyway, that is a legitimate choice; it just needs a NOTICE file and a
> provenance entry, and it should be a deliberate decision rather than a drift.

**`s3rver` is not a reference for the hard part.** MIT-licensed and readable, but
[archived in September 2025][s3rver], and it does not verify signatures at all — it
accepts any credentials. It is useful as a *behavioural oracle* for XML response
shapes, not as an auth reference.

**The real deliverable is a differential harness.** Run a known-good S3 server and
Telemachus side by side, drive both with the same `aws-cli` and `rclone` commands,
and diff the responses. That is how compatibility gets established without copying
anyone's code, and it is a test suite rather than a one-time exercise. It also
catches exactly the class of problem that findings 4 and 5 belong to — the things
that are obvious the first time a real client talks to you, and invisible until then.

[sigv4-suite]: https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
[arsenal]: https://github.com/scality/Arsenal
[s3rver]: https://github.com/jamhall/s3rver

### DOC‑17 — What the real client actually sends

Captured from `aws-cli/2.35.6` against a listener that logged the raw bytes. This is
the conformance target, and it differs from what the documentation implies.

| Observation | Consequence |
|---|---|
| A 17-byte file → a single `PUT`, plain body, real SHA‑256 in `X-Amz-Content-SHA256` | no chunked decoding needed for the common case |
| A 12 MB file → straight to **multipart**, no single `PUT` at all | multipart is **not optional**; the CLI's threshold is 8 MiB. It moves into the first S3 slice |
| Parts arrived **out of order and concurrently** (`partNumber=2` before `partNumber=1`) | parts are independent rows assembled at `Complete`, never appended to a growing object |
| A failed `Complete` was followed by `DELETE ?uploadId` | abort is part of the happy path, not an edge case |
| `x-amz-sdk-checksum-algorithm: CRC64NVME` + `x-amz-checksum-crc64nvme`, **both in `SignedHeaders`** | they must be included in the canonical request even though we do not verify the CRC |
| `aws s3 ls` → `GET /` then `GET /bucket?list-type=2&prefix=&delimiter=%2F&encoding-type=url` | empty query values are part of the canonical string; responses must honour `encoding-type=url` |
| `X-Amz-Content-SHA256` of an empty body is the SHA‑256 of the empty string | it is a claim to be recomputed, never trusted |
| **No** `aws-chunked` / `STREAMING-*` payload on any request observed | implement the plain payload path first; answer `STREAMING-*` with `NotImplemented` until a client that needs it turns up. Arsenal's `streamingV4/` is the reference when one does |

## The S3 surface

What a real client needs, and nothing more. Everything here is path-style,
SigV4-signed, XML-bodied.

| Operation | Route | |
|---|---|---|
| `ListBuckets` | `GET /` | the teams the caller can reach |
| `HeadBucket` | `HEAD /<bucket>` | |
| `ListObjectsV2` | `GET /<bucket>?list-type=2` | `prefix`, `delimiter`, `max-keys`, `continuation-token`. Only objects that pass `can?` are listed |
| `PutObject` | `PUT /<bucket>/<key>` | `Content-Type`, `x-amz-acl`, `x-amz-meta-*` |
| `GetObject` | `GET /<bucket>/<key>` | `Range`, `?versionId` |
| `HeadObject` | `HEAD /<bucket>/<key>` | size, etag, content type, visibility |
| `DeleteObject` | `DELETE /<bucket>/<key>` | |
| `DeleteObjects` | `POST /<bucket>?delete` | batch; `aws s3 sync --delete` needs it |
| `CopyObject` | `PUT` + `x-amz-copy-source` | metadata-only when the digest matches |
| Multipart | `POST ?uploads` · `PUT ?partNumber&uploadId` · `POST ?uploadId` · `DELETE ?uploadId` | DOC‑8 |
| Presigned URL | SigV4 query auth (`X-Amz-Signature`, `X-Amz-Expires`) | a time-boxed link the console hands the browser for download and preview |
| `GetBucketLocation` | `GET /<bucket>?location` | the CLI asks before it does anything |
| Everything else | | `501 NotImplemented`, S3 error shape (DOC‑13) |

Errors are S3's XML, with the mapping fixed up front:

| Condition | Code | HTTP |
|---|---|---|
| `can?` denies | `AccessDenied` | 403 |
| unknown bucket / not reachable | `NoSuchBucket` | 404 |
| unknown key, or hidden by visibility | `NoSuchKey` | 404 |
| bad signature / unknown access key | `SignatureDoesNotMatch`, `InvalidAccessKeyId` | 403 |
| clock skew > 15 min | `RequestTimeTooSkewed` | 403 |
| over the single-`PUT` cap | `EntityTooLarge` | 400 |
| over the storage quota | `QuotaExceeded` *(non-standard)* | 403 |
| refused sub-resource | `NotImplemented` | 501 |

A hidden object returns `NoSuchKey` rather than `AccessDenied`: for an object whose
visibility is `private`, its *existence* is part of what is private.

## What building 49 and 50 changed

Three things the proposal had wrong or under-specified, each surfaced by a test
rather than by review.

**The blob refcount has to be scoped to the org, not the instance.** DOC‑6 namespaces
*storage* per org; the first draft of the delete path counted references to a digest
across the whole `repo_versions` table. Two tenants holding identical bytes would
then pin each other's copies forever — the exact mirror of the leak the namespace
exists to prevent. Caught by the cross-org test asserting that Acme's delete frees
Acme's blob while Globex's survives.

**Sharing does not relabel a private document.** `shared` narrows a *team-visible*
document to a named list. A document that was already `private` gains a grant and
stays `private` — the grant is what widens it, not the label. Stated here because
the first version of the smoke test assumed otherwise.

**An overwrite must not carry the upload form's visibility.** In the console the
visibility select persists between uploads, so re-uploading an existing path
silently re-opened a private document — found by looking at a screenshot, not by a
test. The fix is in the UI rather than the API: when the typed path already exists,
the select is disabled and the form says *"this path exists — uploading saves a new
version and keeps its current visibility"*. The API keeps its rule that an explicit
visibility is honoured, because a deliberate change must still be possible.

One thing the proposal got right and is worth keeping: the blob store never sees a
principal. Writing `rs3` took about sixty lines precisely because there was no
authorization question to answer inside it.

Slice 51 added a fourth: **`Expect: 100-continue` is not a latency optimization, it
is an authorization one.** The 16-second stall is what made it look like a
performance bug; the actual value is that a server which answers before reading gets
to refuse an upload for free.

## What building 51 and 52 changed

**`Range` is a correctness requirement, not a performance one.** It was scheduled for
slice 53. Then a 30 MB multipart upload round-tripped as 55 MB: `aws s3 cp` fetches a
large object with *parallel ranged GETs*, and a server that ignores `Range` returns
the whole object for each one. The client assembles them and reports success. The
stored object was perfect; the download was garbage. Nothing but a real client finds
that.

**Query values arrive percent-encoded, and every one of them needs decoding — not
just the ones that look like paths.** The AWS CLI sends `delimiter=%2F`. Comparing
that raw against a single character silently disables folder grouping while still
returning a plausible listing: every key present, flat, no error. The rule is now
stated once at the top of the listing code, because the failure mode is a *plausible*
wrong answer rather than a crash.

**A default in two places is a default in neither.** `s3-cred-issue!` defaults its
scopes; the endpoint passed its own list, silently shadowing it, so widening the
default did nothing until the endpoint stopped repeating it.

**Secrets are stored in the clear, and DOC‑3's "encrypt with `TELEMACHUS_SECRET_KEY`"
is withdrawn.** Encrypting with a key that lives in the environment of the same
process, on the same host, reading the same database moves the secret from one file
an attacker already has to another. `users.totp_secret` is recoverable for the same
reason. What actually bounds a leaked access key is its scope list. This is stated in
the module rather than implied.

## What building 53 changed

**A presigned link is signed with the caller's own S3 key, not an ephemeral one.**
The alternative — minting a hidden credential per link — creates rights nobody can
see in a listing and nobody can take away. As built, a link can never do more than
the key that signed it, and revoking that key kills every link made with it. The
smoke suite asserts exactly that, last, because it invalidates everything above it.

**`X-Amz-Expires` needed a tamper test, not a removal test.** Removing it trips the
expiry check before the signature is ever computed, so the removal case proves
nothing about signing. Stretching a 15-minute link to a week is the assertion that
matters.

**An expired link gets its own verdict.** It would be easy to collapse it into
`SignatureDoesNotMatch` — the signature is, after all, no longer acceptable. But the
fix differs: "ask for a new link" versus "fix your clock" versus "your key is wrong".
`presign-verify` returns `'expired` and the endpoint says so.

**The differential conformance harness was dropped, deliberately.** The plan was to
run a reference S3 server beside ours and diff the responses. The only offline
candidate is `s3rver`, which is archived and *does not verify signatures at all* — it
can oracle response shapes and nothing else, and our own vectors already pin those
harder than it could. Testing against the real `aws` CLI is the stronger version of
the same idea and it is what `test/s3-smoke.sh` does: 33 checks, every one an
operation a real workflow performs. Recorded here rather than quietly re-scoped.

## What building 54 changed

**The workflow engine paid for itself.** The indexing pipeline is two tools and a
13-line spec. Durability, retries, cancel, quota admission, the org gate, per-step
RBAC — all inherited, zero lines here. The one engine-adjacent change: a tool
handler may now return a jsexpr (not just a string), because `map #:over` needs a
real array and a whole-string binding preserves its type; the *agent* surface
JSON-encodes non-strings at its own boundary, so one handler serves both.

**A corrupt document must not wedge indexing forever.** The first version raised on
an unreadable file, which failed the run — and the next run would list the same
object and fail again, permanently, for the whole team. Found by the smoke suite,
whose earlier blocks happen to leave behind one byte of garbage labeled
`application/pdf`. Unreadable files are now recorded as processed-with-nothing
(an empty row matches no search; a re-upload makes the object eligible again).
`missing-tool` stays a hard failure on purpose: "install poppler" is a fix an
operator can make, and the run should be red until they do.

**Quota admission gates workflow steps too.** The smoke's quota check throttles
`ai.tokens.total` to zero, and the indexing run sat `running` with every step
`queued` — deferral working exactly as documented, in a place nobody expected it.
Worth knowing before a trial: a team over its AI budget also stops indexing.

## Alternatives considered

**WebDAV.** Mounts natively on macOS and Windows, which is genuinely attractive for
"internal document repository". But its authorization story is HTTP Basic plus
per-collection ACLs, its client behaviour varies wildly, and it has no equivalent of
presigned URLs. Worth revisiting as a *second* front door onto the same core — the
architecture admits it — but not as the first.

**Plain REST multipart upload, no S3.** Less work, and the console would be equally
good. Rejected because it fails demand 3: every user writes a client, no tool
already speaks it, and the backup story becomes bespoke. `rclone` and `aws s3 sync`
against a standard protocol *is* the feature.

**Run MinIO as a sidecar and proxy to it.** MinIO speaks S3 properly and we would
write no protocol code. Rejected on three counts: it is a second daemon and a second
datastore (against the whole shape of this platform — the workflow engine added
neither), its license is AGPL‑3.0 which is incompatible with this project's
clean-MIT commitment for anything we would ship or link, and the hard part is not
the protocol — it is mapping the protocol onto `can?`, which we would still have to
write.

**Use an existing Racket AWS client library.** Those are *client* libraries: they
sign requests, they do not verify signatures. There is nothing to reuse for the
server side.

**Port a Node/TypeScript S3 server wholesale.** Covered in DOC‑16. The short version:
the only implementation worth reading is Apache‑2.0 rather than MIT, only its auth
core (~9 files) is relevant, and the specification it implements is public with
official test vectors — so reading it and building from the spec dominates porting on
every axis except the first afternoon.

**Store blobs in the database.** What `assets.rkt` does, and finding #2 is what it
costs. Base64 inflates by a third, the row loads in full to read one byte, and
backups become unusable at document scale. The metadata belongs in the database; the
bytes do not.

## Build slices

| Slice | Contents | Done when |
|---|---|---|
| **49** ✅ | `web-kit` `#:max-body-length` + `TELEMACHUS_MAX_UPLOAD` (32 MiB), `domain/authz/sha2.rkt` over libcrypto pinned to the NIST/RFC vectors, `domain/repo/blobs.rkt` seam + the `rs3` plugin, migration `0019-repo` | **Done.** `test/sha2-tests.rkt` (25 cases), `test/repo-tests.rkt` (74 cases) |
| **50** ✅ | `domain/repo/repo.rkt`, the `/api/repo` + `/api/repo-obj` surface, and the console **Repository** tab: upload, download, visibility, per-person sharing, versions, storage gauge | **Done.** Verified in a browser and in `test/server-smoke.sh` (15 new assertions). *`repo_credentials` moved to slice 52 — it exists only for SigV4.* |
| **51** ✅ | `pkgs/web-kit/http1.rkt` (DOC‑15): request line, headers, lazy `Expect: 100-continue`, `Content-Length` and chunked request bodies **as an input port**, keep-alive with bounded draining, chunked or length-framed responses | **Done.** `test/http1-tests.rkt` (46 cases over raw TCP). Measured: the AWS CLI sees its `100 Continue` **1 ms** after the headers, against 16,016 ms on the servlet; a 200 MB body arrives in 0.5 s and is counted exactly, with no cap |
| **52** ✅ | `domain/s3/{sigv4,creds,server}.rkt`: SigV4 verification, S3 access keys, path-style routing, XML + the error table, ListBuckets / ListObjectsV2 with delimiter / Get / Head / Put / Delete / DeleteObjects, multipart, **and `Range`** — which turned out to be a correctness requirement, not a slice-53 nicety | **Done.** 47 SigV4 cases against AWS's published vectors and real captured requests; `test/s3-smoke.sh` runs 23 checks with the actual `aws` CLI, including a 30 MB multipart round-trip |
| **53** ✅ | Presigned URLs both directions (verify *and* sign), `CopyObject`, `ListObjectVersions`, `GET ?versionId`, and a **Link** button in the console | **Done.** `test/s3-smoke.sh` is now 33 checks with the real `aws` CLI; 64 SigV4 cases. *(The differential harness was dropped — see below.)* |
| **54** ✅ | `domain/repo/{extract,index-tools}.rkt` + the `doc-indexer` plugin: an `index-documents` workflow — find unindexed, fan out, extract. txt/md/csv, html/xml/svg (tag-stripped), docx (Racket's own unzip), pdf (`pdftotext`, pinned via nixpkgs `poppler-utils`) | **Done.** `test/index-tests.rkt` runs the whole pipeline through the real scheduler; smoke proves it over HTTP — a word that exists only in a document's bytes becomes a search hit |
| **55** | The DOC‑14 fold: `documents` becomes `repo_objects` with `text/markdown`, `/api/documents` a compatibility shim | One document concept, one permission family, one tab |

Slice 49 is the only one with irreversible schema commitments. Slices 51–53 can be
dropped entirely without stranding 50 — a working repository with a console and a
REST API, just no S3 — which is the test that the layering is real. That matters
here more than usual, because 51 is the slice most likely to be underestimated.

Slice 53 is the payoff for having built the workflow engine first: "extract text
from every new document and index it" is a `map` step over a tool, not new
machinery.

## Decisions

| id | Decision | Status |
|---|---|---|
| DOC‑1 | S3 is a transport onto `can?`, never a second authorization system | proposed |
| DOC‑2 | Bucket ≡ team; path-style addressing only; no `CreateBucket` | proposed |
| DOC‑3 | S3 credentials are a distinct kind with a recoverable secret, scoped like API tokens | proposed |
| DOC‑4 | Creator sets visibility via `x-amz-meta-visibility` / `x-amz-acl`; `public-*` refused | proposed |
| DOC‑5 | Content-addressed blob store behind a plugin seam; `rs3` is the local one | proposed |
| DOC‑6 | The content-address namespace is per org, to close the dedup existence oracle | proposed |
| DOC‑7 | Pure-Racket SHA‑256/HMAC‑SHA256, libcrypto as an optional accelerator | proposed |
| DOC‑8 | Downloads stream; uploads buffer under a cap; multipart for anything larger | proposed |
| DOC‑9 | Overwrite versions; `versionId` addresses history; etag is the digest | proposed |
| DOC‑10 | Active content served as an attachment with `nosniff`; never inline on the app origin | proposed |
| DOC‑11 | `storage.bytes` as a signed non-windowed gauge on the existing ledger | proposed |
| DOC‑12 | REST + console are the control plane; S3 is the data plane | proposed |
| DOC‑13 | Unknown S3 sub-resources return `NotImplemented`, never a silent success | proposed |
| DOC‑14 | New `repo_objects`; search covers both **now**, `documents` folds into it in slice 55 | ✅ decided |
| DOC‑15 | The S3 data plane gets its own HTTP/1.1 listener in `web-kit`; the JSON plane stays on `serve/servlet` | proposed |
| DOC‑16 | Build from AWS's specification against AWS's test vectors; read Arsenal, do not port it | proposed |
| DOC‑17 | The conformance target is what `aws-cli` actually sends, captured on the wire | proposed |

## Decisions to confirm

Three are genuine policy forks rather than engineering calls, and are worth a
decision before slice 49:

1. **DOC‑4 — refusing `public-read`.** It makes the platform's position explicit,
   but it will break a client that sets it habitually. The alternative is accepting
   it and downgrading to `private` with a warning header, which is friendlier and
   less honest.
2. **DOC‑8 — the 32 MiB single-`PUT` cap.** Higher is friendlier and costs RAM per
   concurrent upload; lower pushes more traffic through multipart, which not every
   client uses. 32 MiB is a guess that wants a real number from how your team
   actually uses this.
3. ~~**DOC‑14 — whether `documents` folds in now or later.**~~ **Decided:** search
   covers repository objects now (which is what was actually costing something), and
   the fold is its own slice, 55. See DOC‑14 above.
4. **DOC‑16 — port Arsenal, or build from the specification.** Porting is faster to
   start and slower to trust, and it puts Apache‑2.0 code in an MIT repository.
   Building from the spec against AWS's own vectors is the recommendation, but it is
   a real trade and it is yours to make.
