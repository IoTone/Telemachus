# Configuration reference

Every environment variable TMach reads, with its default. There is **no
config file**: an instance is configured entirely by its environment, and nothing
is written at runtime, which is what lets the container run with a read-only root
filesystem (issue #89).

`scripts/check-config-reference.sh` is a CI gate: every `TELEMACHUS_*` name that
appears anywhere in the source must appear in a table below. A variable the code
reads and this page does not mention is a build failure, because the one table an
operator configures a deployment from must not quietly fall behind the code.

Conventions used throughout:

- **Boolean** means `1`, `true`, `yes` or `on` is true; anything else, including
  unset and the empty string, is false.
- An **empty value is the same as unset** everywhere (`env*` treats `""` as
  absent), so `FOO=` in a compose file turns a variable off rather than setting
  it to the empty string.
- Where a numeric knob says *falls back to the default*, an unparseable or
  non-positive value is **never** taken as `0` — a zero would mean "cancel every
  job the instant it starts" or "poll in a hot loop", so the platform refuses to
  read a typo that way.

---

## Core and networking

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8835` | The HTTP port. The common convention, read when `TMACH_PORT` is unset. |
| `TMACH_PORT` | — | The HTTP port; wins over `PORT`. |
| `TMACH_BIND` | `127.0.0.1` | Listen address. **A container must set `0.0.0.0`** or it is unreachable from outside itself; the shipped image does. A non-loopback bind with no TLS is a startup warning (see *Startup checks*). |
| `TMACH_TLS` | off | Boolean. Terminate TLS in this process, and send HSTS. With no cert configured a self-signed one is generated into the data dir. |
| `TMACH_TLS_CERT` | `<data dir>/cert.pem` | PEM certificate path. |
| `TMACH_TLS_KEY` | `<data dir>/key.pem` | PEM private key path. |
| `TMACH_PUBLIC_URL` | derived from bind/port | The URL this instance is reached at, for links it generates. Set it behind a proxy, where the bind address is not what anyone types. |
| `TMACH_HOME` | `login` | What `/` serves: `login` (the console) or `beta` (the onboarding funnel). |
| `TMACH_TRUSTED_HEADER_PEERS` | — | Comma-separated addresses allowed to assert identity with `X-Telemachus-User`/`-Team`. Loopback is always trusted; nothing else is, including private-looking ranges (issue #40). Set this to a reverse proxy's address, and only that. |
| `TMACH_BOOTSTRAP_SECRET` | — | Allows `POST /api/bootstrap` from a non-loopback caller, compared in constant time via `X-Telemachus-Bootstrap`. Without it, bootstrap is loopback-only. |
| `TMACH_S3_PORT` | off | Turns on the S3-compatible front door, a **second** listener. Off by default: an S3 endpoint is surface area, and surface area should be asked for. |
| `TMACH_S3_REGION` | `us-east-1` | The region SigV4 signatures are verified against. |
| `TMACH_MAX_UPLOAD` | `33554432` (32 MiB) | Largest request body, in bytes. Also caps a worker's base64 document read and write, so a worker cannot get past the front door's ceiling. |

## Database and storage

| Variable | Default | What it does |
|---|---|---|
| `DATABASE_URL` | `sqlite:///<data dir>/telemachus.db` | `sqlite:///path` or `postgres://user:pass@host:port/db`. Both dialects are supported and both are tested in CI. |
| `TMACH_DATA_DIR` | `$XDG_STATE_HOME/telemachus`, else `$HOME/.local/state/telemachus` | Everything on disk: the SQLite file, blobs, generated certs, the tectonic cache. **Must be absolute** and writable; the container sets `/data`, which is its declared volume. |
| `TMACH_BLOB_STORE` | `rs3` | Which registered blob store holds document bytes. A name that is not registered **refuses to boot** — a typo used to write every document to local disk while the instance reported healthy. |
| `TMACH_RS3_ROOT` | `<data dir>/rs3` | Where the local filesystem blob store writes. A relative path **refuses to boot**: `serve/servlet` repoints the working directory while handling a request, so a relative root aims writes at the read-only Nix store. |
| `TMACH_UPLOAD_REAP_HOURS` | `168` (7 days) | How long an abandoned S3 multipart upload is kept. `never` disables; a nonsense or non-positive value falls back to the default. The clock is the **newest part**, not the create time, so a slow 2 GB upload is not reaped mid-flight. |
| `TMACH_BLOB_STAGE_REAP_MINUTES` | `60` | How long a blob may sit with nothing pointing at it before a sweep collects it (issue #122). An upload's bytes are written **before** admission — the size is not known until they are, and trusting a client-supplied `Content-Length` is not enforcement — so a refused or crashed upload leaves bytes with no row. **The floor is a correctness requirement, not tidiness:** the gap between the write and the version row is exactly when a legitimate blob has no row yet, so a shorter value risks collecting an upload in progress. `never` disables the sweep; `0`, a negative value or nonsense falls back to the default. A blob another object shares is never collected, whatever the age. |

## Secrets and authentication

| Variable | Default | What it does |
|---|---|---|
| `TMACH_SECRET_KEY` | — | Seals the three stored secrets that cannot be hashed (TOTP seeds, S3 and executor keys) with AES-256-GCM. 64 hex characters is the key itself; anything else is a passphrase, stretched with PBKDF2. **Unset means plaintext at rest**, which is supported and reported at boot — see `docs/ops/secrets-at-rest-runbook.md`. Not the same variable as `TMACH_SECRET`. |
| `TMACH_SECRET_KEY_OLD` | — | A previous key, read but never written, for `telemachus-secrets rewrap`. |
| `TMACH_SECRET` | a dev default (warned about at boot) | The general-purpose secret: the fallback pepper for API-token hashes, and the funnel's signing secret. **Rotating it signs everyone out**, which is why it is deliberately not the key that seals secrets at rest. |
| `TMACH_TOKEN_PEPPER` | `TMACH_SECRET`, else a dev default | Peppers the HMAC-SHA-256 token hashes specifically. |
| `TMACH_KDF` | argon2 when available | Set to `pbkdf2` to force PBKDF2 password hashing. |
| `TMACH_PBKDF2_ITERS` | `100000` | PBKDF2 iteration count when that KDF is in use. |
| `TMACH_MAX_SESSIONS` | `10` | How many browser sessions one identity may hold at once (issue #118). Reaching it **evicts the oldest**, audited as `user.session.evicted` — it never refuses a sign-in, because a full session table would otherwise become a lockout. `never` or `0` disables the cap; anything unparseable falls back to the default. Machine tokens (`api`, `worker`) are not sessions and are never counted or evicted. |
| `TMACH_WORKER_TOKEN_DAYS` | never | Lifetime of a **worker** token, in days, applied when one is minted or rotated (issue #60). Unset or `never` means no expiry, which is what every instance did before and what nothing anybody has deployed stops working because of — expiry is opt-in, as a retention rule is. **90 is the recommendation.** Adopting it needs workers that rotate: the reference worker does when `TMACH_WORKER_TOKEN_FILE` is set, and an operator can run `POST /api/executors/<id>/rotate-token` for one that cannot. A rotation OVERLAPS — the outgoing token keeps working for an hour — so there is no window in which a host is dead. An unparseable or non-positive value falls back to `never`, never to `0`. |
| `TMACH_ANCHOR_KEY` | — (off) | The **Ed25519 signing key for anchor receipts** (issue #66): 64 hex characters, which is a 32-byte seed. Unset means no receipts are emitted and nothing changes — a real default would start a receipt series on every instance that nobody retains, which reads as a working feature. **Unlike `TMACH_SECRET_KEY` this is NOT a passphrase and a passphrase is refused**, because stretching one would make the instance's published identity guessable and a forged receipt cannot be undone by rotating afterwards. Generate it with `racket cli/telemachus-anchor.rkt keygen` and keep it in a secret store; publish the public key (`… pubkey`) to whoever retains your receipts, since that is what lets them verify without being able to forge. Rotating it starts a NEW series — keep the old public key to verify old receipts. |
| `TMACH_ANCHOR_EVERY` | `86400` | How often the reaper emits an anchor receipt, in seconds, when an anchor key is configured. **The anchor's resolution is its cadence** — a chain rewrite inside the window since the last receipt is not detectable — so shorten it if that window matters. `never` emits only when asked (`POST /api/admin/anchor/emit`, or `telemachus-anchor emit`). An unparseable or non-positive value falls back to the default, never to `0`, which would emit on every tick and bury the series it protects. |
| `TMACH_LOGIN_LOCK_FAILURES` | — (off) | Lock an account outright after this many failed sign-ins inside 15 minutes (issue #116), answering **423** until an operator clears it with `POST /api/admin/users/:id/password`. **Off by default on purpose:** a lock only an operator can clear is a denial-of-service primitive against a known username. With it unset, sign-in is still throttled — three failures are free, then a doubling delay capped at 60 seconds, answered as a 429 with `Retry-After`. |

## Model access

| Variable | Default | What it does |
|---|---|---|
| `TMACH_MODEL_URL` | — | An OpenAI-compatible chat-completions endpoint. **Without it `/api/ai/chat` answers with a simulated upper-cased echo**, flagged `simulated: true`, and the document tools, knowledge graph and agent refuse outright. Said loudly at boot. |
| `TMACH_MODEL` | `local` | The model name sent to that endpoint. |
| `TMACH_MODEL_KEY` | — | Bearer token for the endpoint. |
| `TMACH_MODEL_CAPS` | unknown (permissive) | What the local model can do, e.g. `tools=false,json_schema=true`. Only an explicit `false` refuses a request; an undeclared capability is unknown and unknown is permissive, so nothing that works today starts failing. |
| `TMACH_MODEL_TIMEOUT` | `120` | Seconds bounding one non-streaming model request end to end. |
| `TMACH_MODEL_IDLE_TIMEOUT` | `60` | Seconds bounding the **gap between SSE events**, not the whole stream — a model still emitting may legitimately take minutes. |
| `TMACH_MODEL_RETRIES` | `1` | Retries on a timeout, an unreachable endpoint, a 429 or a 5xx — never on a 4xx. A retry costs tokens, so the default is one. A streaming call is never retried. |
| `TMACH_MODEL_<ROLE>` | — | Routes one model role to a named executor, e.g. `TMACH_MODEL_UTILITY`. Checked after the team's own setting. `utility` is the only role that ships: knowledge-graph extraction, field extraction, translation and localization drafts. |
| `TMACH_EXECUTORS` | `<impl>/executors.json` | Config file of named push backends. Names in this file are owned by it: a database row that would shadow one is refused. |

## Jobs, scheduling and shutdown

| Variable | Default | What it does |
|---|---|---|
| `TMACH_MAX_JOB_SECONDS` | `1800` | A job past this is cancelled, with a reason naming the knob. `never` disables; an unparseable or non-positive value falls back to the default, never to `0`. Enforced in the lease refresher, not the reaper. |
| `TMACH_DRAIN_SECONDS` | `25` | On SIGTERM or SIGINT, how long to let in-flight jobs finish before handing them back to the queue **un-charged** (no attempt spent). Must fit inside the orchestrator's own grace period: Kubernetes allows 30s by default, systemd 90s, `docker stop` only 10 — pass `-t`/`stop_grace_period`. `0` or `never` hands work back immediately. |
| `TMACH_BUILD_COMMIT` | from `.git`, else `dev` | The revision this instance is running, shown in the console footer and on `GET /api/whoami` and `/api/admin/status`. **`nix build` sets it** — a store path has no `.git` beside it, so a packaged install cannot work it out. Run from a checkout it is read from `.git` and you need not set it. It is never guessed: an unknown build reports `dev`. |
| `TMACH_STRICT_STARTUP` | off | Boolean. Turns the advisory startup checks into refusals — recommended for an unattended deployment. See *Startup checks* below. |

## Plugins and extensions

| Variable | Default | What it does |
|---|---|---|
| `TMACH_PLUGINS` | the built-in directory | A `:`-separated **list** of extra plugin directories, searched after the built-ins. A literal `-` entry drops the built-ins. It used to name the one directory to load, which silently removed every shipped plugin. |
| `TMACH_PLUGINS_LINKS` | off | Boolean. Load **symlinked** plugin directories. Off by default so a developer's local link can never join a test run or a generated document. |
| `TMACH_PLUGINS_STRICT` | off | Boolean. Refuse to start if any plugin failed to load, rather than starting without it. |
| `TMACH_MCP` | `<impl>/mcp.json` | MCP server config file. |
| `TMACH_OOP` | `<impl>/oop.json` | Out-of-process (sandboxed) plugin config file. |
| `TMACH_LOCALES` | `locales` | Directory of `*.json` catalogs. The export **writes** here, so point it at a writable copy in a test. |
| `TMACH_ZONEINFO` | `$TZDIR`, else `/usr/share/zoneinfo` | Directory of the IANA zone database (#137). Only for a deployment that ships its own copy; the packaged wrapper and the devShell both set `TZDIR` from the pinned `tzdata`, so this is normally unset. With no database found, every zone resolves to UTC — which is what the platform did before timezones existed, so nothing breaks, and nothing is in local time either. |
| `TMACH_EGRESS_ALLOW` | (empty) | Comma-separated IPv4 CIDRs (a bare address is `/32`) that a **trusted** outbound fetch may reach in private address space (#142) — a feed on your own network. It does NOT widen an untrusted fetch, which is public-only whatever this says, and `trusted` without an entry here still refuses every private address: the operator owns which networks are reachable, and a tenant naming a private URL would otherwise be reading this instance's cloud metadata. IPv6 CIDRs are refused at parse rather than silently ignored. |

## Matrix notifications (issue #133, the `matrix` plugin)

Both are the **operator's**, and the access token is deliberately not in the
database: a plugin cannot own a sealed column (FEED‑5), and a credential stored
unsealed is the failure that rule exists to prevent. So there is one bot
identity per instance — which is what a self-hosted notifier is — a tenant
admin never sees the token, and a team configures only *which room*. With
neither set the plugin registers no event sink and no job kind, so an instance
that does not use Matrix carries nothing extra in its emit path.

| Variable | Default | What it does |
|---|---|---|
| `TMACH_MATRIX_HOMESERVER` | (empty) | Base URL of the Matrix homeserver to notify through, e.g. `https://matrix.example.internal`. A self-hosted one is normally on a private network, so it also needs its CIDR in `TMACH_EGRESS_ALLOW` — the fetch goes out with #142's `trusted` policy, which refuses every private address the operator has not named. |
| `TMACH_MATRIX_TOKEN` | (empty) | Access token of the bot account the notifications are sent as. The bot must already be **in** each room: the plugin never joins one, so who may be told stays a decision made on the Matrix side. |

## What the model is told, and what is logged about it (issue #91)

| Variable | Default | What it does |
|---|---|---|
| `TMACH_REQUIRE_NO_CONTENT_LOGGING` | off | Boolean. When on, a model request to a backend that is **not on this host** is refused unless that executor's capability document carries `"no_content_logging": true`. Off by default on purpose: a real default would make an upgrade start refusing the calls this platform exists to make. Unset, an undeclared hosted backend is still used and every request is logged with `content_logging: "undeclared"`, so the gap is visible rather than assumed. |

**What it enforces is that somebody made the assertion, never the assertion
itself.** No software can check what a remote operator retains. What this
instance can do is refuse to send a team's document text off the box until its
own operator has declared, per executor, that the backend does not log content —
which turns an assumption nobody wrote down into a decision with a name attached
to it. A backend on loopback is outside the policy entirely: nothing left the
host, so there is nothing to declare.

Set the declaration where every other backend capability already lives — the
executor's `capabilities` document, which needs no migration and arrives
identically from `executors.json` and from `POST /api/executors`:

```sh
curl -X POST "$BASE/api/executors" -H "Authorization: Bearer $OP" \
  -d '{"name":"vendor","mode":"push","url":"https://api.vendor.example/v1/chat/completions",
       "capabilities":{"no_content_logging":true}}'
```

**Every model request that leaves the process is logged**, to `model_requests`,
readable at `GET /api/model-requests` with `audit:read`: the executor, which path
carried it (`push`, `stream` or `pull`), the model, the backend's **host** (never
its key and never its query), whether it was off this box, what it declared, a
keyed digest of the prompt, a message and character count, the token count and
the outcome — including the requests that failed and the ones this instance
**refused** to make. There is no prompt column and no reply column.

The digest is an **HMAC under `TMACH_SECRET_KEY`**, not a bare SHA‑256,
because a bare hash of a short prompt is reversible from a word list — a leaked
log plus a list of names would otherwise be a confirmation oracle over exactly
the identifiers redaction exists to protect. With no key configured it is a plain
SHA‑256 and the row's `digest_alg` says so. Rotating the key makes earlier
digests incomparable with later ones; there is nothing to re-wrap, since the
prompt was never kept, so the row records `digest_key_id` and a reader sees a new
key rather than concluding the text changed.

### Where a labelled document's text may go (#91 requirement 4)

**This one has no environment variable, deliberately.** It is a policy with two
tenant-visible tiers, so it lives in the database and is edited over HTTP —
`PUT /api/executor-policy` (`instance:manage`) and
`PUT /api/org/executor-policy` (`org:manage`) — and the switch that turns it on
is the existence of a document:

```sh
curl -X PUT "$BASE/api/executor-policy" -H "Authorization: Bearer $OP" -d '{
  "labels": {
    "confidential": {"executors": ["gpu-1"], "default_model": false, "allow_redacted": true},
    "restricted":   {"executors": ["gpu-1"], "allow_redacted": false}
  }}'
```

A document is governed when it carries the LAY‑4 object attribute
**`sensitivity`** — a field the team defines like any other, whose values the
policy's labels name. **With no policy document at either tier nothing is
refused**, whatever a document is labelled; once one exists, a label NO tier
mentions is refused outright, which is the state removing a label from the policy
leaves documents that still carry it in.

The list governs **unredacted** text: tokenised text (requirement 2's `redact`)
may go to a backend that is not on it, unless the label sets
`allow_redacted: false`. A backend on **loopback** is outside the policy
entirely, as above — so a single-box instance talking to ollama is unaffected —
and a **pull** executor has no endpoint, counts as off this box, and is governed.
The unnamed `TMACH_MODEL_URL` model has no executor name, so it is permitted
per label by `default_model` rather than by a reserved entry in the list. A name
in the list that no executor answers to is reported as `unknown_executors` on the
read rather than refused on the write, because a typo there fails closed.

A refused request is audited as `ai.egress.refused` in the trail of the
document's own team, carrying the label, the executor, the backend's host and the
reason — never the text and never the document's key.

## Encrypting document-derived content at rest (issue #83)

| Variable | Default | What it does |
|---|---|---|
| `TMACH_ENCRYPT_CONTENT` | off | Boolean. Seals `repo_text.content` and `repo_text.spans` with AES‑256‑GCM under `TMACH_SECRET_KEY`, using the same stored form and the same `<table>.<column>:<row-id>` AAD as the three replayable credentials. **Set without a secret key it REFUSES TO START** — a wrap with no key passes the value through by design, so the switch would write the plaintext it was enabled to prevent while reporting success. |

**It costs content search, which is why it is a separate switch.** The match is a
SQL `LIKE` over `repo_text.content`; sealed, it matches ciphertext and therefore
nothing. So `GET /api/search` drops that clause (a key or filename match still
works) and reports **`content_search: false`** on every reply — a search that
quietly stopped looking inside documents would read as "there is no such
document", and a caller must be able to tell those apart.

This is deliberately **not** `TMACH_SECRET_KEY`. That key seals the three
replayable credentials and is wanted on every instance; this decides whether
derived document content is sealed too, and it costs a capability. A deployment
holding regulated documents wants both. One that needs to search its documents
wants only the first.

Turning the switch **off again does not lose anything**: unsealing is not
conditional on it, so rows sealed while it was on still read. `racket
cli/telemachus-secrets.rkt status` lists the content columns **only when the
switch is on**, and `rewrap` seals them only then — otherwise a rotation would
silently remove search from an instance that had chosen to keep it.

**Database-level encryption is necessary but not sufficient.** RDS or EBS
encryption protects a stolen disk. It does not protect a `pg_dump`, a logical
replica, a backup copied to object storage, or anything read by a process that
already has the volume mounted — which is every path a tenant's extracted text
actually travels. This seals the column, so the ciphertext travels with the dump.

## Object-storage blob store (the `s3blobs` plugin, issue #82)

Document bytes in an S3-compatible bucket instead of on local disk. Selected with
`TMACH_BLOB_STORE=s3`; with the plugin present and that unset, nothing here
is read and the instance uses `rs3` exactly as before.

**These are not the S3 *listener*'s settings.** `TMACH_S3_PORT` and
`TMACH_S3_REGION` configure the S3 API this server *serves* (slice 52);
everything below configures the bucket it *writes to*. An instance can do both at
once, which is why the names differ.

| Variable | Default | What it does |
|---|---|---|
| `TMACH_S3_BLOB_ENDPOINT` | — | **Required.** `http(s)://host[:port]`. A bare `host:port` is refused rather than guessed at: assuming `https` would silently fail a plaintext MinIO on a LAN. |
| `TMACH_S3_BLOB_BUCKET` | — | **Required.** The bucket. Not created for you. |
| `TMACH_S3_BLOB_REGION` | `us-east-1` | Signing region. MinIO ignores it but it is still signed, so it must match whatever the endpoint expects. |
| `TMACH_S3_BLOB_PREFIX` | `blobs` | Key prefix. The layout is `<prefix>/<org>/<sha256>` — flat under the org, because a bucket's keyspace has no directory problem. The **org level is load-bearing**: global dedup across tenants is an existence oracle (DOC‑6). |
| `TMACH_S3_BLOB_ACCESS_KEY` | `AWS_ACCESS_KEY_ID` | Access key id. The `AWS_*` name is accepted as a fallback because that is how most platforms already inject credentials. |
| `TMACH_S3_BLOB_SECRET_KEY` | `AWS_SECRET_ACCESS_KEY` | Secret key. |
| `TMACH_S3_BLOB_SSE` | `kms` | `kms`, `s3` or `none`. Server-side encryption is **on by default**, and `none` has to be asked for. |
| `TMACH_S3_BLOB_KMS_KEY_ID` | the bucket's default key | Only with `SSE=kms`. Omitting it is a real configuration — the bucket's own default KMS key — not an error. |
| `TMACH_S3_BLOB_REQUIRE_ENCRYPTION` | on unless `SSE=none` | Checks the **response**, not the request: a PUT whose reply carries no `x-amz-server-side-encryption` is refused by name. That is what catches a bucket policy or a replication rule quietly dropping it. The object has already landed when this fires and is **left in place deliberately**, so you can inspect what the bucket did. |
| `TMACH_S3_BLOB_PATH_STYLE` | on | Path-style addressing (`/bucket/key`). **On by default, unlike the AWS SDKs**, because MinIO and Ceph RGW are the deployments this exists for and neither gets virtual-host DNS for free; AWS still accepts it. |
| `TMACH_S3_BLOB_RETRIES` | `3` | Attempts per operation. Only a 429 or a 5xx retries — a 4xx is our own request. Every operation is idempotent (the key *is* the content hash), so a retry needs no idempotency key. |
| `TMACH_S3_BLOB_TIMEOUT` | `120` | Seconds for one operation. |

**The boot check probes the store that is in use** (issue #119).
`blob-store-probe` does a real put, get, digest compare and delete through
whatever `TMACH_BLOB_STORE` selected, after plugins load, and **a failure
refuses to serve** — so endpoint reachability, credentials, bucket existence and
Get/Put/Delete permission are all verified before the instance accepts a
request. For the S3 store the put also asserts the bucket reported server-side
encryption, so the encryption posture is checked by the same probe.

For most of this feature's life that paragraph was a lie: the probe took a
filesystem path and wrote a file under the *local* blob root whatever this
variable said, so a bucket store with a wrong endpoint started healthy and
failed on the first upload. **The practical consequence of the fix is that an
object-store outage at boot now stops a restart**, where before it started and
failed per-upload. That is the right trade for a storage backend — an instance
that reports healthy and loses documents is the worse failure — but it is a
change in restart behaviour worth knowing about if your bucket and your app
restart together.

See [the IAM policy and migration notes](container.md#object-storage-for-document-bytes).

## OCR (the `ocr` plugin, issue #92)

Reading text out of photographs and scanned PDFs. **Off unless you turn it on**,
because enabling it replaces the platform's own PDF reader for the whole
instance — see [the OCR notes](#ocr-the-ocr-plugin-issue-92) below the table.

| Variable | Default | What it does |
|---|---|---|
| `TMACH_OCR` | off | Boolean (`1`/`yes`/`true`/`on`). Claims `image/jpeg,png,tiff,bmp,webp,x-portable-pixmap` **and `application/pdf`**, so a scan is OCR'd instead of reported `needs-ocr`. Set with no `tesseract` on PATH, the plugin **fails to load and says why** rather than answering `missing-tool` on every scan; `TMACH_PLUGINS_STRICT=1` turns that into a refusal to start. |
| `TMACH_OCR_LANGUAGES` | `eng` | Passed to tesseract as-is, so `eng+spa` for two. `tesseract --list-langs` is the authority on a box; the nixpkgs build bundles 129. |
| `TMACH_OCR_MAX_PAGES` | `20` | Pages of a scanned PDF to read. Enforced **in `pdftoppm`**, so a 400-page scan is not rendered and then discarded. Nonsense or non-positive falls back to the default, never 0. |
| `TMACH_OCR_TIMEOUT` | `120` | Seconds for one engine call, per page. The call runs under its own custodian, so a timeout takes the child and its pipes with it. |
| `TMACH_OCR_DPI` | `150` | Resolution a PDF page is rasterised at before OCR. Higher reads small print better and costs time and memory on every page. |

A PDF's **text layer is tried first** and only a PDF with none is rasterised: a
born-digital PDF carries exact text where OCR guesses, so the order is
load-bearing rather than an optimisation. Extracted text arrives with per-word
**page and region provenance** (LAY-5 spans), which `GET
/api/repo-obj/<id>/spans?at=<offset>` resolves — this is the first reader that
fills them.

## Multi-tenancy and hosted mode

| Variable | Default | What it does |
|---|---|---|
| `TMACH_MULTITENANT` | off | Boolean. Adds the org layer above teams and its two management planes. **Not an off switch**: isolation keeps being enforced when it is turned back off, so flipping it off on a populated instance only hides the management surface. |
| `TMACH_MODE` | — | `saas` turns off interactive bootstrap and turns on the provisioning endpoints. |
| `TMACH_PROVISION_TOKEN` | — | Bearer token the provisioning endpoints require in hosted mode. |
| `TMACH_SEED_OWNER_EMAIL` | — | First-boot owner seed in hosted mode; the activation token is printed to stdout. |
| `TMACH_SEED_OWNER_NAME` | — | Display name for that owner. |
| `TMACH_SEED_ORG` | — | Organisation name for the seeded owner. |
| `TMACH_SEED_PLAN` | `trial` | Plan applied to the seeded org, which sets its quota caps. |
| `TMACH_SEED_PROVISION_ID` | `seed` | Idempotency key for that seed. |

## Beta onboarding funnel

| Variable | Default | What it does |
|---|---|---|
| `TMACH_ONBOARDING` | — | First-boot default experience document, inline JSON. A published database experience then wins. |
| `TMACH_ONBOARDING_FILE` | — | The same, read from a file. |
| `TMACH_BETA_EMAIL_CAP` | `1` | Submissions allowed per email address in the velocity window. |
| `TMACH_BETA_DOMAIN_CAP` | `10` | Submissions allowed per email domain in the velocity window. |
| `TMACH_POW_BITS` | `16` | Proof-of-work difficulty the funnel demands of a submitter. |

## The reference worker (`cli/telemachus-worker.rkt`)

A **separate process** from the server, usually on another host — these are read
by the worker, not by the instance.

| Variable | Default | What it does |
|---|---|---|
| `TMACH_URL` | `http://127.0.0.1:8835` | The TMach instance to claim work from. The worker only ever connects **out**, so it works through NAT and a tailnet. |
| `TMACH_WORKER_TOKEN` | — | Required. The worker token shown once when the executor was created (scope `jobs:execute`). |
| `TMACH_WORKER_MODEL_URL` | — | An OpenAI-compatible endpoint; set it to run `infer.chat`. |
| `TMACH_WORKER_MODEL_KEY` | — | Bearer token for that endpoint. |
| `TMACH_WORKER_MODELS` | any | Comma-separated model names this host offers, for claim matching. Naming none means "any". |
| `TMACH_WORKER_LAYA_URL` | — | A loopback `laya_serve.py --port` (run it with `--batch-size 1`); set it to run `judge.typed`. The chat endpoint is then optional, so a Mac can be a judge host and nothing else. |
| `TMACH_WORKER_READY_URL` | — | A URL the worker GETs before **each** claim; 2xx means this host can take work. While it refuses, the worker reports `paused` once and claims nothing. What readiness *means* is the operator's: VRAM, memory, load, a maintenance flag. Unset disables the gate entirely. |
| `TMACH_WORKER_READY_INTERVAL` | `15` | Seconds between re-checks while standing down. An unparseable or non-positive value falls back to the default, never to `0`. |
| `TMACH_WORKER_TOKEN_FILE` | — | Where this worker keeps its token. The file is the durable home and `TMACH_WORKER_TOKEN` the bootstrap: a start reads the file when it exists and falls back to the variable. **Set it to let this host rotate its own credential** (issue #60) — a worker that cannot persist a new token must not rotate, so with this unset the worker says once that an operator has to rotate for it. Written `0600`, replaced atomically. |
| `TMACH_WORKER_TOKEN_CHECK` | `3600` | Seconds between `GET /api/workers/token` checks. One request an hour beside a claim every twenty seconds; the platform asks for a rotation a third of the token's life early, so hourly leaves many chances. An unparseable or non-positive value falls back to the default, never to `0`. |

---

## Startup checks

Before serving, an instance checks the things an unattended deployment gets
wrong silently (`server/startup.rkt`). **Errors always refuse to start:**

- **the blob store is not writable.** Probed by actually writing and reading
  back, because a missing directory, a root-owned one and a read-only mount
  cannot be told apart by a permission bit — and all three surface as a 500 on
  the first document save, long after a healthy-looking boot.
- **the database was migrated by a newer Telemachus.** Older code against a
  newer schema writes rows the newer build will misread. The remedy is to deploy
  that version, so carrying on would corrupt data rather than merely fail.
- **migrations are still pending** after the boot-time migration ran, which
  means one failed.

**Warnings by default, refusals under `TMACH_STRICT_STARTUP=1`** — both are
positions a working instance can legitimately hold:

- **no `TMACH_SECRET_KEY`.** Plaintext at rest is the supported
  trusted-database position, and the boot line already says which it is.
- **a non-loopback bind with no TLS.** Plaintext HTTP on `0.0.0.0` across a
  tailnet or a pod network is a real and reasonable deployment; doing it on the
  open internet without knowing is the thing worth saying.

## Where to go next

- `docs/ops/container.md` — the OCI image, compose, and Kubernetes.
- `docs/ops/secrets-at-rest-runbook.md` — adopting and rotating the sealing key.
- `docs/ops/multi-tenancy-runbook.md` — onboarding a company.
- `docs/ops/workflow-engine-runbook.md` — workflows in production.
