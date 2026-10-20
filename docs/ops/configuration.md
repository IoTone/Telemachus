# Configuration reference

Every environment variable Telemachus reads, with its default. There is **no
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
| `PORT` | `8835` | The HTTP port. The common convention, read when `TELEMACHUS_PORT` is unset. |
| `TELEMACHUS_PORT` | — | The HTTP port; wins over `PORT`. |
| `TELEMACHUS_BIND` | `127.0.0.1` | Listen address. **A container must set `0.0.0.0`** or it is unreachable from outside itself; the shipped image does. A non-loopback bind with no TLS is a startup warning (see *Startup checks*). |
| `TELEMACHUS_TLS` | off | Boolean. Terminate TLS in this process, and send HSTS. With no cert configured a self-signed one is generated into the data dir. |
| `TELEMACHUS_TLS_CERT` | `<data dir>/cert.pem` | PEM certificate path. |
| `TELEMACHUS_TLS_KEY` | `<data dir>/key.pem` | PEM private key path. |
| `TELEMACHUS_PUBLIC_URL` | derived from bind/port | The URL this instance is reached at, for links it generates. Set it behind a proxy, where the bind address is not what anyone types. |
| `TELEMACHUS_HOME` | `login` | What `/` serves: `login` (the console) or `beta` (the onboarding funnel). |
| `TELEMACHUS_TRUSTED_HEADER_PEERS` | — | Comma-separated addresses allowed to assert identity with `X-Telemachus-User`/`-Team`. Loopback is always trusted; nothing else is, including private-looking ranges (issue #40). Set this to a reverse proxy's address, and only that. |
| `TELEMACHUS_BOOTSTRAP_SECRET` | — | Allows `POST /api/bootstrap` from a non-loopback caller, compared in constant time via `X-Telemachus-Bootstrap`. Without it, bootstrap is loopback-only. |
| `TELEMACHUS_S3_PORT` | off | Turns on the S3-compatible front door, a **second** listener. Off by default: an S3 endpoint is surface area, and surface area should be asked for. |
| `TELEMACHUS_S3_REGION` | `us-east-1` | The region SigV4 signatures are verified against. |
| `TELEMACHUS_MAX_UPLOAD` | `33554432` (32 MiB) | Largest request body, in bytes. Also caps a worker's base64 document read and write, so a worker cannot get past the front door's ceiling. |

## Database and storage

| Variable | Default | What it does |
|---|---|---|
| `DATABASE_URL` | `sqlite:///<data dir>/telemachus.db` | `sqlite:///path` or `postgres://user:pass@host:port/db`. Both dialects are supported and both are tested in CI. |
| `TELEMACHUS_DATA_DIR` | `$XDG_STATE_HOME/telemachus`, else `$HOME/.local/state/telemachus` | Everything on disk: the SQLite file, blobs, generated certs, the tectonic cache. **Must be absolute** and writable; the container sets `/data`, which is its declared volume. |
| `TELEMACHUS_BLOB_STORE` | `rs3` | Which registered blob store holds document bytes. A name that is not registered **refuses to boot** — a typo used to write every document to local disk while the instance reported healthy. |
| `TELEMACHUS_RS3_ROOT` | `<data dir>/rs3` | Where the local filesystem blob store writes. A relative path **refuses to boot**: `serve/servlet` repoints the working directory while handling a request, so a relative root aims writes at the read-only Nix store. |
| `TELEMACHUS_UPLOAD_REAP_HOURS` | `168` (7 days) | How long an abandoned S3 multipart upload is kept. `never` disables; a nonsense or non-positive value falls back to the default. The clock is the **newest part**, not the create time, so a slow 2 GB upload is not reaped mid-flight. |

## Secrets and authentication

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_SECRET_KEY` | — | Seals the three stored secrets that cannot be hashed (TOTP seeds, S3 and executor keys) with AES-256-GCM. 64 hex characters is the key itself; anything else is a passphrase, stretched with PBKDF2. **Unset means plaintext at rest**, which is supported and reported at boot — see `docs/ops/secrets-at-rest-runbook.md`. Not the same variable as `TELEMACHUS_SECRET`. |
| `TELEMACHUS_SECRET_KEY_OLD` | — | A previous key, read but never written, for `telemachus-secrets rewrap`. |
| `TELEMACHUS_SECRET` | a dev default (warned about at boot) | The general-purpose secret: the fallback pepper for API-token hashes, and the funnel's signing secret. **Rotating it signs everyone out**, which is why it is deliberately not the key that seals secrets at rest. |
| `TELEMACHUS_TOKEN_PEPPER` | `TELEMACHUS_SECRET`, else a dev default | Peppers the HMAC-SHA-256 token hashes specifically. |
| `TELEMACHUS_KDF` | argon2 when available | Set to `pbkdf2` to force PBKDF2 password hashing. |
| `TELEMACHUS_PBKDF2_ITERS` | `100000` | PBKDF2 iteration count when that KDF is in use. |

## Model access

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_MODEL_URL` | — | An OpenAI-compatible chat-completions endpoint. **Without it `/api/ai/chat` answers with a simulated upper-cased echo**, flagged `simulated: true`, and the document tools, knowledge graph and agent refuse outright. Said loudly at boot. |
| `TELEMACHUS_MODEL` | `local` | The model name sent to that endpoint. |
| `TELEMACHUS_MODEL_KEY` | — | Bearer token for the endpoint. |
| `TELEMACHUS_MODEL_CAPS` | unknown (permissive) | What the local model can do, e.g. `tools=false,json_schema=true`. Only an explicit `false` refuses a request; an undeclared capability is unknown and unknown is permissive, so nothing that works today starts failing. |
| `TELEMACHUS_MODEL_TIMEOUT` | `120` | Seconds bounding one non-streaming model request end to end. |
| `TELEMACHUS_MODEL_IDLE_TIMEOUT` | `60` | Seconds bounding the **gap between SSE events**, not the whole stream — a model still emitting may legitimately take minutes. |
| `TELEMACHUS_MODEL_RETRIES` | `1` | Retries on a timeout, an unreachable endpoint, a 429 or a 5xx — never on a 4xx. A retry costs tokens, so the default is one. A streaming call is never retried. |
| `TELEMACHUS_MODEL_<ROLE>` | — | Routes one model role to a named executor, e.g. `TELEMACHUS_MODEL_UTILITY`. Checked after the team's own setting. `utility` is the only role that ships: knowledge-graph extraction, field extraction, translation and localization drafts. |
| `TELEMACHUS_EXECUTORS` | `<impl>/executors.json` | Config file of named push backends. Names in this file are owned by it: a database row that would shadow one is refused. |

## Jobs, scheduling and shutdown

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_MAX_JOB_SECONDS` | `1800` | A job past this is cancelled, with a reason naming the knob. `never` disables; an unparseable or non-positive value falls back to the default, never to `0`. Enforced in the lease refresher, not the reaper. |
| `TELEMACHUS_DRAIN_SECONDS` | `25` | On SIGTERM or SIGINT, how long to let in-flight jobs finish before handing them back to the queue **un-charged** (no attempt spent). Must fit inside the orchestrator's own grace period: Kubernetes allows 30s by default, systemd 90s, `docker stop` only 10 — pass `-t`/`stop_grace_period`. `0` or `never` hands work back immediately. |
| `TELEMACHUS_STRICT_STARTUP` | off | Boolean. Turns the advisory startup checks into refusals — recommended for an unattended deployment. See *Startup checks* below. |

## Plugins and extensions

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_PLUGINS` | the built-in directory | A `:`-separated **list** of extra plugin directories, searched after the built-ins. A literal `-` entry drops the built-ins. It used to name the one directory to load, which silently removed every shipped plugin. |
| `TELEMACHUS_PLUGINS_LINKS` | off | Boolean. Load **symlinked** plugin directories. Off by default so a developer's local link can never join a test run or a generated document. |
| `TELEMACHUS_PLUGINS_STRICT` | off | Boolean. Refuse to start if any plugin failed to load, rather than starting without it. |
| `TELEMACHUS_MCP` | `<impl>/mcp.json` | MCP server config file. |
| `TELEMACHUS_OOP` | `<impl>/oop.json` | Out-of-process (sandboxed) plugin config file. |
| `TELEMACHUS_LOCALES` | `locales` | Directory of `*.json` catalogs. The export **writes** here, so point it at a writable copy in a test. |

## OCR (the `ocr` plugin, issue #92)

Reading text out of photographs and scanned PDFs. **Off unless you turn it on**,
because enabling it replaces the platform's own PDF reader for the whole
instance — see [the OCR notes](#ocr-the-ocr-plugin-issue-92) below the table.

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_OCR` | off | Boolean (`1`/`yes`/`true`/`on`). Claims `image/jpeg,png,tiff,bmp,webp,x-portable-pixmap` **and `application/pdf`**, so a scan is OCR'd instead of reported `needs-ocr`. Set with no `tesseract` on PATH, the plugin **fails to load and says why** rather than answering `missing-tool` on every scan; `TELEMACHUS_PLUGINS_STRICT=1` turns that into a refusal to start. |
| `TELEMACHUS_OCR_LANGUAGES` | `eng` | Passed to tesseract as-is, so `eng+spa` for two. `tesseract --list-langs` is the authority on a box; the nixpkgs build bundles 129. |
| `TELEMACHUS_OCR_MAX_PAGES` | `20` | Pages of a scanned PDF to read. Enforced **in `pdftoppm`**, so a 400-page scan is not rendered and then discarded. Nonsense or non-positive falls back to the default, never 0. |
| `TELEMACHUS_OCR_TIMEOUT` | `120` | Seconds for one engine call, per page. The call runs under its own custodian, so a timeout takes the child and its pipes with it. |
| `TELEMACHUS_OCR_DPI` | `150` | Resolution a PDF page is rasterised at before OCR. Higher reads small print better and costs time and memory on every page. |

A PDF's **text layer is tried first** and only a PDF with none is rasterised: a
born-digital PDF carries exact text where OCR guesses, so the order is
load-bearing rather than an optimisation. Extracted text arrives with per-word
**page and region provenance** (LAY-5 spans), which `GET
/api/repo-obj/<id>/spans?at=<offset>` resolves — this is the first reader that
fills them.

## Multi-tenancy and hosted mode

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_MULTITENANT` | off | Boolean. Adds the org layer above teams and its two management planes. **Not an off switch**: isolation keeps being enforced when it is turned back off, so flipping it off on a populated instance only hides the management surface. |
| `TELEMACHUS_MODE` | — | `saas` turns off interactive bootstrap and turns on the provisioning endpoints. |
| `TELEMACHUS_PROVISION_TOKEN` | — | Bearer token the provisioning endpoints require in hosted mode. |
| `TELEMACHUS_SEED_OWNER_EMAIL` | — | First-boot owner seed in hosted mode; the activation token is printed to stdout. |
| `TELEMACHUS_SEED_OWNER_NAME` | — | Display name for that owner. |
| `TELEMACHUS_SEED_ORG` | — | Organisation name for the seeded owner. |
| `TELEMACHUS_SEED_PLAN` | `trial` | Plan applied to the seeded org, which sets its quota caps. |
| `TELEMACHUS_SEED_PROVISION_ID` | `seed` | Idempotency key for that seed. |

## Beta onboarding funnel

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_ONBOARDING` | — | First-boot default experience document, inline JSON. A published database experience then wins. |
| `TELEMACHUS_ONBOARDING_FILE` | — | The same, read from a file. |
| `TELEMACHUS_BETA_EMAIL_CAP` | `1` | Submissions allowed per email address in the velocity window. |
| `TELEMACHUS_BETA_DOMAIN_CAP` | `10` | Submissions allowed per email domain in the velocity window. |
| `TELEMACHUS_POW_BITS` | `16` | Proof-of-work difficulty the funnel demands of a submitter. |

## The reference worker (`cli/telemachus-worker.rkt`)

A **separate process** from the server, usually on another host — these are read
by the worker, not by the instance.

| Variable | Default | What it does |
|---|---|---|
| `TELEMACHUS_URL` | `http://127.0.0.1:8835` | The Telemachus instance to claim work from. The worker only ever connects **out**, so it works through NAT and a tailnet. |
| `TELEMACHUS_WORKER_TOKEN` | — | Required. The worker token shown once when the executor was created (scope `jobs:execute`). |
| `TELEMACHUS_WORKER_MODEL_URL` | — | An OpenAI-compatible endpoint; set it to run `infer.chat`. |
| `TELEMACHUS_WORKER_MODEL_KEY` | — | Bearer token for that endpoint. |
| `TELEMACHUS_WORKER_MODELS` | any | Comma-separated model names this host offers, for claim matching. Naming none means "any". |
| `TELEMACHUS_WORKER_LAYA_URL` | — | A loopback `laya_serve.py --port` (run it with `--batch-size 1`); set it to run `judge.typed`. The chat endpoint is then optional, so a Mac can be a judge host and nothing else. |
| `TELEMACHUS_WORKER_READY_URL` | — | A URL the worker GETs before **each** claim; 2xx means this host can take work. While it refuses, the worker reports `paused` once and claims nothing. What readiness *means* is the operator's: VRAM, memory, load, a maintenance flag. Unset disables the gate entirely. |
| `TELEMACHUS_WORKER_READY_INTERVAL` | `15` | Seconds between re-checks while standing down. An unparseable or non-positive value falls back to the default, never to `0`. |

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

**Warnings by default, refusals under `TELEMACHUS_STRICT_STARTUP=1`** — both are
positions a working instance can legitimately hold:

- **no `TELEMACHUS_SECRET_KEY`.** Plaintext at rest is the supported
  trusted-database position, and the boot line already says which it is.
- **a non-loopback bind with no TLS.** Plaintext HTTP on `0.0.0.0` across a
  tailnet or a pod network is a real and reasonable deployment; doing it on the
  open internet without knowing is the thing worth saying.

## Where to go next

- `docs/ops/container.md` — the OCI image, compose, and Kubernetes.
- `docs/ops/secrets-at-rest-runbook.md` — adopting and rotating the sealing key.
- `docs/ops/multi-tenancy-runbook.md` — onboarding a company.
- `docs/ops/workflow-engine-runbook.md` — workflows in production.
