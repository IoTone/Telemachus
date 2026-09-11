# Telemachus — working notes for Claude

Telemachus is a clean-MIT, team-oriented, self-hosted, privacy-first, Racket-first
platform for hosting AI tools & apps (the successor to the Python "Odysseus"). Pure
OSS: no open-core, no held-back tier. Concepts may be reused from Odysseus; **only
owner-authored Racket + owner-authored docs** may be carried over (see
`docs/provenance/` if present, and `docs/design/`).

## Layout

- Design docs at the repo root and under `docs/` (`docs/design/`, `docs/FeatureRequirements.md`).
- Implementation lives under `refimpl/<name>/`. The reference impl is
  **`refimpl/racketmaximus/`** (Racket 9.2 CS). A second impl may later target the
  same contracts — the durable product is the SDK contract, APIs, security model, protocols.
- Copyright: IoTone, Inc. (MIT).

## Build / test (run from `refimpl/racketmaximus/`)

**Nix is the toolchain. There is no second one.** `nix develop` from the repo root
pins Racket 9.2, exports `PLTCOLLECTS`, and adds postgres/sqlite/openssl/node.
`nix build` runs the unit suite in the sandbox; `nix flake check` adds the HTTP
smoke. Nix only sees **git-tracked** files, so `git add` a new source file before
building.

```sh
nix develop                              # from the repo root; then:
cd refimpl/racketmaximus
raco make server/main.rkt                # precompile before running/smoke (startup is slow otherwise)
raco test test/*-tests.rkt               # the unit suite
```

Run a one-off without entering the shell: `nix develop --command <cmd>`.

> **Do not use linuxbrew/homebrew — it is a proven bad path and was removed from
> these notes.** Its glibc mismatch breaks `libcrypto` (so no SHA‑256, and the
> `openssl` binary won't run), and it is the "python spice kitchen" the
> deterministic-deps tenet exists to prevent. apt Racket is 8.2 and also unusable.
> If Nix is unavailable on a box, that box is not a build host.

- **Never `raco test test/*.rkt`** — the glob pulls in `test/mock-*.rkt`, which are
  mock *servers* that block forever. Use `test/*-tests.rkt`.
- After changing a module's **exports**, `raco make` the test files too, or a stale
  `.zo` throws "reference to a variable that is not exported".
- Migrations: `domain/db/migrations.rkt` (`all-migrations` list, applied at startup).
  Keep SQL dialect-neutral (SQLite now, PostgreSQL target): quote reserved words
  (`"window"`), portable epoch columns for time windows, `db-dialect`-aware clauses.
  `pkgs/db-kit/portable.rkt` is a drop-in for `(require db)` that rewrites `?`→`$n`
  on Postgres — always `(require db-kit/portable)`, not `(require db)`. Forgetting is
  invisible on SQLite and fails on Postgres with `syntax error at or near "AND"`.
- **Verify on Postgres, not just SQLite.** The unit suite AND both smoke suites
  honour a pre-set `DATABASE_URL`, so everything runs against either dialect. Unit
  fixtures come from `test/db-fixture.rkt`: `(fresh-db)` gives a migrated, isolated
  database — in-memory on SQLite, a private SCHEMA per fixture on Postgres (test
  files run concurrently and would otherwise share one). `(fresh-db #:shared k)` is
  for the rare test needing two connections over the SAME data (workflow
  durability); `close-db!` drops the schema. **Test files issue raw SQL too, so they
  need `db-kit/portable`, not `db`** — same rule as production code.
  ```sh
  DATABASE_URL="postgres://…" raco test test/*-tests.rkt
  ```
  ```sh
  initdb -D $PGDATA -U telemachus --auth=trust && \
    pg_ctl -D $PGDATA -o "-k /tmp/tmxpg -h 127.0.0.1 -p 55432" -l pg.log start
  createdb -h 127.0.0.1 -p 55432 -U telemachus tmx
  DATABASE_URL="postgres://telemachus@127.0.0.1:55432/tmx" bash test/server-smoke.sh
  DATABASE_URL="postgres://telemachus@127.0.0.1:55432/tmx" bash test/s3-smoke.sh
  ```
  Keep the socket dir SHORT (`-k /tmp/…`): the 107-byte `sun_path` limit rejects a
  scratchpad path. Drop and recreate the database between runs — bootstrap is
  first-run-only, and a stale one silently yields an empty token.

## Running the server

```sh
export DATABASE_URL="sqlite:///$PWD/data/telemachus.db"   # or postgres://user:pass@host:port/db
export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions   # OpenAI-compat (ollama)
export TELEMACHUS_MODEL=qwen2.5:7b
export TELEMACHUS_HOME=login              # or `beta` to serve the beta funnel at /
export PORT=8835                          # default; the server reads PORT / TELEMACHUS_PORT
racket server/main.rkt
```

- **`TELEMACHUS_MODEL_URL` is required for real model calls** — without it `run-chat`
  silently uses a *simulated* uppercase-echo fallback (a real gotcha: the LLM judge/agent
  will look "broken" — no model was ever called).
- The server **caches `static/index.html` at startup** — restart to pick up UI edits.
- Local model: ollama on `:11434`, `qwen2.5:7b` (tool-calling works; avoid qwen3.5
  "reasoning" models — the answer lands in a `reasoning` field). Warm it before e2e.

## e2e (Playwright) — `refimpl/racketmaximus/test/e2e/`

```sh
export PATH=~/.nvm/versions/node/v24.18.0/bin:$PATH   # box default node is v16 (too old)
node beta-tour.mjs        # drives a live server, writes catalog/beta/*.png + manifest.json
node build-catalog.mjs beta "<title>" "<subtitle>" "<footer>"   # → catalog/beta/catalog.html
```

- Use **plain Playwright** (`import { chromium } from '@playwright/test'`) — the
  `@playwright/test` *runner* hangs in this env (buffered, zero output).
- Launch chromium with `['--no-sandbox','--disable-dev-shm-usage']`.

## Environment constraints (this sandbox)

- **No root**; `sudo` is broken (`sudoers_audit` plugin fails). No Docker (no root).
  glibc 2.35 (too old for brew bottles generally — this is why brew is out). To run
  live Postgres, use a host with working sudo → `apt install postgresql`, or the
  `nix develop` shell, which already provides it — **do NOT use conda/brew** (see the
  deterministic-deps tenet: no "python spice kitchen").
- The **Bash tool** reaps `&`-backgrounded procs when the call returns and blocks
  foreground `sleep` — run long-lived servers via `run_in_background`, poll with a
  bounded `curl` loop.
- **`pkill` self-match footgun:** `pkill -f '<pat>'` also matches the *current*
  command's own line. `pkill -f server/main; raco make server/main.rkt` kills its own
  shell (exit 144). Kill in a **standalone** command, and prefer a bracket pattern
  (`[s]erver/main`) — but only when the literal doesn't appear elsewhere in the command.

## Beta onboarding subsystem

Skinnable, admin-configurable, plugin-owned funnel — see
`docs/design/beta-onboarding-experience.md`. Core captures leads + resists abuse +
stores the experience; the plugin owns fields/copy/theme/frontend. Three render tiers,
all through one anti-abuse gate: **A** built-in themeable shell, **B** custom plugin
bundle (`/beta/bundle/<plugin>/` + `window.Telemachus.beta` SDK), **C** sandboxed HTML
template (`/beta/template`). ENV seeds first-boot defaults (`TELEMACHUS_ONBOARDING`,
`TELEMACHUS_ONBOARDING_FILE`); a published DB experience then wins.

### Configuring the funnel's fields

The experience document's `fields` list IS the form — turning a field off means
removing it from the list, adding one means adding it. Two things used to make that
untrue and are now fixed (ONB‑9):

- **`required` is enforced from the config** (`field-problem` in `domain/beta/beta.rkt`).
  It used to render a `*` and nothing checked it.
- **An unconfigured field is never demanded.** A hardcoded rule required `name`
  whatever the form showed, so removing `name` gave a funnel nobody could submit.
- **`email` is structural** and cannot be removed — the velocity caps, disposable
  check and prospect dedup are all keyed on it (`structural-field?`).
- Adding a field needs **no migration**: any key outside `reserved-field-keys` lands
  in the `attributes` blob, and Admin > Beta renders prospect details generically.
- Validation vocabulary is `required` / `digits` / `minlength` / `maxlength` and is
  deliberately **NOT a regex** — it would be admin-authored and run against
  attacker-chosen input on a public endpoint. Same call as the frozen workflow
  binding sublanguage. A 13-digit 法人番号 is `digits` + min/max 13.
- `"minlength": "13"` (quoted) is accepted too — hand-written JSON will quote a
  number eventually, and silently dropping the rule is the worse failure.
- The refusal names the **localized** label, so the server localizes the experience
  BEFORE validating. Worked example: `examples/onboarding-jp-corporate.json`.
- Client-side gets `required`/`minlength`/`maxlength`/`inputmode` only — the server
  is the authority; duplicating messages would drift from `locales/*.json`.
- **Enforcing `required` is a behaviour change**: a caller that omitted a field the
  config marks required now gets a 400 where it used to succeed. `test/server-smoke.sh`
  was omitting `job_title` and had to be fixed.

### Localizing the funnel

The funnel's copy is operator-authored, so it is an **`i18n` overlay on the
experience document**, not a catalog — `{"i18n":{"ja":{"title":…,"fields":{"email":
{"label":…}}}}}`. Base config stays the default-locale copy, so no overlay = today's
behaviour exactly.

- **Translation is presentation only** (ONB‑8). An overlay matches fields BY KEY and
  takes only `label`/`options`; it can never rename a key, change a type, flip
  `required`, or reach `judge-system`/`theme`/`landing`/`template`. The submitted
  body is identical in every language, which is why `doBetaSignup()` fetches the
  field list with no locale.
- Resolution is `?lang=` → `X-Telemachus-Locale` → instance default. `?lang=` wins
  because a funnel is a page people are LINKED to — the switcher must leave a
  shareable URL. An unknown locale falls back **whole**, never half-translated.
- The switcher renders from `locales`, derived server-side from the document, so it
  cannot offer a language with no copy behind it. It vanishes when instance
  negotiation is off.
- The public slice ships ONE language — never the overlay table, never the judge prompt.
- Three homes, do not mix them: funnel **copy** → the experience document; funnel
  **chrome** → the console's `const L`; server **refusals** → `surface/messages.rkt`
  + `locales/*.json`. The third was bare English until the Aug 2026 sweep.
- The honeypot's fake success must use the SAME localized string as the real one.

```sh
bash test/e2e/funnel-l10n.sh    # 16 browser assertions; boots with TELEMACHUS_HOME=beta
```

## Localization (Admin > Localization)

Instance-wide default locale plus an off switch, `domain/i18n/policy.rkt` over the
same generic `instance_settings` table branding uses (`domain/settings/settings.rkt`
is now the shared accessor — use it for the next instance-wide setting).

- Resolution is `resolve-locale`: `X-Telemachus-Locale` → `Accept-Language` → the
  **instance default**. It used to end at a hardcoded `"en"`, which made a
  Japanese-default instance impossible. Never reintroduce a literal fallback here.
- **An unknown locale falls back to the instance default, not to English** — `fr`
  on a `ja` instance gets Japanese.
- `enabled: false` pins EVERY request to the default and makes the console drop its
  language switcher. It does not remove catalogs; flipping it back restores them.
- `available` is derived from the `locales/*.json` on disk, never stored, so the
  instance cannot advertise a language it cannot render. `default` is validated
  against it — an unknown one is a 400, not a silent substitution.
- **The read rides on the PUBLIC `GET /api/config`** and must stay public: the
  sign-in screen picks its language before anyone has a token. Write is
  `PUT /api/i18n`, `instance:manage`.
- Console: `loadI18n()` runs on every render pass (a signed-in user must see an
  operator turn the switcher off). A stored `tmx_lang` only wins while switching is
  enabled AND the catalog still ships.
- Settings are deliberately **not cached** — one indexed single-row lookup beside
  the token and permission queries the same request already runs. A cache would
  have to be keyed by connection to stay correct under `fresh-db`.
- Catalogue hashes in `locales/ja.json` are the **source** hash (sha1 of the
  English), i.e. what the translation was made against. Editing Japanese text does
  not change them; editing English marks the translation stale.
- **An empty target string is dropped at load** and falls through to English — so a
  blank looks like "not translated yet", never a blank UI. Four shipped that way
  until the Aug 2026 sweep.
- `test/server-smoke.sh` asserts on real Japanese text (`権限がありません`,
  `認証が必要です`) — changing those strings means changing those assertions.
- Review sheet: `python3 scripts/build-l10n-review.py` regenerates
  `build/l10n-ja-review.html` from the real sources (console `const L`,
  `locales/*.json`, and the funnel copy in `domain/beta/beta.rkt` — the last read by
  EVALUATING the module through `racket`, so run it inside `nix develop`). A string in no group, or a note for a key that no longer
  exists, is a build error — both by design.

## Localization Manager (the Localize tab)

The flagship: the platform building a real tool out of its own primitives. Design:
`docs/design/localization.md`.

**The catalogs on disk stay the shipping artifact.** `locales/*.json` is what the
runtime loads, what git diffs and what `telemachus-localize check` gates. Migration
`0024`'s two tables (`l10n_messages`, `l10n_translations`) are the WORKFLOW around
them — `POST /api/l10n/import` pulls the catalogs in, `POST /api/l10n/export` writes
approved strings back. Neither is on the request path.

- **`missing` and `stale` are DERIVED, never stored.** Missing is the absence of a
  row; stale is `source_hash_at <> l10n_messages.source_hash`. Editing the English
  therefore makes every translation pinned to the old hash stale with *nothing
  rewriting a status*. Storing either would let a row disagree with the base
  catalog, which is the one thing these tables must never do.
- **Instance-scoped, not team-scoped.** The design doc says team-scoped, but its own
  data shapes carry no `team_id` and the artifact is the instance's own catalog —
  two teams cannot both be right about `ja.json`. The shapes win.
- **A translator cannot approve their own string**, enforced in `l10n-review!`. A
  machine draft has no human author, so anyone with `localization:review` may
  approve it — which is the review the AI path needs.
- **The permission split is the contract**: a plain `member` has
  `localization:read` + `:translate` (translating is a team activity) but NOT
  `:review` or `:manage`. Approving a colleague's work and writing catalogs to disk
  are admin acts. `server-smoke.sh` pins all three.
- **Export refuses a locale with nothing approved.** `available` locales are derived
  from the files in `locales/`, so writing an empty catalog would put the language
  in the switcher with English behind it — the exact failure that derivation
  prevents. Partial catalogs are fine; the fallback chain covers gaps.
- **AI drafting** is job kind `l10n_draft`, one scheduler job per batch of 20, so a
  5,000-string draft is a cancellable queue rather than one hour-long job. Output
  lands as `machine`, never `approved`. Metered: a run of 8 strings charged 1,004
  `ai.tokens.total` against the team.
- **A draft that loses an ICU placeholder is refused, not stored.** `{user}` is an
  argument; a translation that renames it renders literal braces to an end user. A
  bad draft sitting in the review queue looking finished is worse than a missing
  one.

```sh
raco test test/l10n-manager-tests.rkt    # 13 cases, no server
bash test/server-smoke.sh                # includes the HTTP block (see below)
```

**Test the ENDPOINTS, not just the model.** The bug that actually bit here lived in
the HTTP layer: `query-param` compared a string key with `assq` against
`url-query`'s *symbol* keys, so every filter silently fell back to its default and
a request for Dutch was answered with Japanese. A filter that is ignored rather
than refused is invisible to a model test.

## Multi-tenancy (several companies on one instance)

Off by default. `TELEMACHUS_MULTITENANT=1` adds an **org** layer above teams plus two
management planes — see `docs/design/multi-tenancy.md` (decision TEN‑2, supersedes TEN).

Operator runbook: `docs/ops/multi-tenancy-runbook.md`.

- **superadmin** (`instance:*`, from bootstrap) runs the instance: `/api/orgs*`.
- **org admin** (`org:*`, `users.org_role_key`) runs one company: `/api/org*`.
  It **manages but does not read** team data (TEN‑2a).
- Isolation is **step 0 of `can?`** — an unconditional deny *before* permissions,
  owner-ok, token scopes and resource grants, so a share can't tunnel out of an org.
  The gate never reads the feature flag: turning the flag off on a populated
  instance hides the management planes and keeps enforcing, which leaves tenants
  nobody can administer. The flag is not an off switch.
- `teams.slug` is now unique **per org** (migration `0016-orgs` rebuilds the table on
  SQLite); `users.username` stays instance-global — use email.
- Org quotas nest above team quotas (`subject_type='org'`); admission needs both.
- **Onboarding a company needs no restart** — `POST /api/orgs` writes rows and the
  org, its team and its owner are live on the next request. Setting
  `TELEMACHUS_MULTITENANT=1` is the only restart the subsystem ever needs.
- Every `/api/orgs/<ref>` route takes an **id or a slug** (`org-resolve`); a pipeline
  holds the slug it declared, not the id the server minted.
- **Create is a converging operation** (TEN‑2f): an explicit `slug` is a natural key
  and a re-run is `409`; a slug *derived from `name`* still suffixes to `acme-1`.
  Getting this backwards mints duplicate companies silently.
- `PATCH /api/orgs/<ref>` renames and/or changes the plan — a plan change
  **re-applies that plan's caps**, so a hand-set quota survives only until the next
  plan write. Name-only patches never touch quotas.
- Always send `owner_password` on create: without it `password_hash` is NULL,
  `authenticate` refuses forever, and the 201's token is the account's ONLY
  credential (nothing mints a token for another user).
- The superadmin **cannot** add people to a customer org — `/api/org/members` is
  always the caller's own org, and the superadmin's is `system`. Chain off the
  owner token the create call returned.
- There is deliberately **no `DELETE /api/orgs`** (TEN‑2g) and **no console UI** —
  the whole surface is HTTP.

```sh
TELEMACHUS_MULTITENANT=1 bash test/multitenant-demo.sh   # 2 seeded companies + 1 provisioned, 84 assertions
raco test test/tenancy-tests.rkt                          # the authz core, no server
```

`POST /api/admin/seed-tenants` (superadmin) seeds Acme + Globex with **known dev
passwords** (`admin@acme.test` / `acme-admin1`, etc.) — demo fixture only, never prod.

## S3 endpoint (slice 52)

`TELEMACHUS_S3_PORT=8836` turns it on — a SECOND listener, on `web-kit/http1`, off by
default. `aws`, `rclone`, `boto3` and Cyberduck all work. Bucket = team slug,
path-style, region from `TELEMACHUS_S3_REGION` (default `us-east-1`).

- `domain/s3/sigv4.rkt` verifies signatures. **Built from the spec, not ported** —
  pinned to AWS's published vectors AND to real aws-cli requests captured on the wire.
- **S3 rules that differ from the generic SigV4 suite:** the path is used AS RECEIVED
  (no re-encode, no normalize — `web-kit/http1` keeps it raw for this reason), and the
  payload hash comes from `x-amz-content-sha256` so verification never needs the body.
- **Query values arrive percent-encoded.** Decode every one in the handler
  (`delimiter=%2F`!) — forgetting produces a plausible wrong answer, not an error.
- **`Range` is mandatory.** `aws s3 cp` downloads large objects as parallel ranged
  GETs; ignoring `Range` yields a corrupt file the client calls a success.
- Multipart is mandatory too (aws switches above 8 MiB). Parts arrive out of order,
  each is its own blob, assembled at Complete via `input-port-append` → `repo-put!`.
- Access keys are `repo_credentials`, secret stored **in the clear** — SigV4 needs it
  to verify. Scopes cap it (RBAC-4). Same trust boundary as `users.totp_secret`.
- Unimplemented sub-resources (`?acl`, `?policy`, …) answer **501**, never a silent
  success — a swallowed bucket policy is the worst failure this subsystem could have.
- **Presigned links** (slice 53): `POST /api/repo-obj/<id>/presign`. Signed with the
  CALLER'S own newest S3 key, so a link can never exceed that key and revoking the
  key kills the link. `X-Amz-Signature` is excluded from its own canonical query;
  every other `X-Amz-*` is included. Expiry is a second, separate clock check and has
  its own verdict (`'expired`) so the message can say "ask for a new link".

```sh
raco test test/sigv4-tests.rkt     # 64 cases, AWS's own vectors + presign rules
bash test/s3-smoke.sh              # 33 checks with the real aws CLI (skips if absent)
```

## HTTP/1.1 listener (`web-kit/http1`, slice 51)

`serve/servlet` stays the JSON control plane. `pkgs/web-kit/http1.rkt` is the data
plane — the thing that can move a 2 GB file.

- Bodies are an **input port**, not bytes. `Content-Length` and `chunked` both.
- **`Expect: 100-continue` is sent lazily, on the first read of the body.** A
  handler that refuses before reading (401/403/quota) means the client never sends
  the body at all. Measured: the AWS CLI gets its continue in **1 ms** here vs
  **16,016 ms** against `serve/servlet`, which never implements it. Do NOT "fix"
  this by sending the continue eagerly — that discards the whole point.
- Never peek at a request body port: peeking fires the continue. `body-state`
  carries started?/finished?/remaining for the keep-alive decision instead.
- The path and query stay **percent-encoded** — SigV4 signs what was sent.

```sh
raco test test/http1-tests.rkt    # 46 cases over raw TCP
```

## Document repository (binary documents, slices 49-50)

Any format in, byte-identical out, with the creator setting visibility. See
`docs/design/document-repository.md` (decisions DOC-1…DOC-17).

- `domain/repo/repo.rkt` is the ownable resource; **`can?` governs it with no new
  authorization code** — same `team_id`/`owner_user_id`/`visibility` triple as notes.
- Bytes live in a **content-addressed** store keyed by SHA-256, never in the DB.
  `domain/repo/blobs.rkt` is the seam; `plugins/rs3/` is the local filesystem one
  (`TELEMACHUS_BLOB_STORE`, default `rs3`). **The store is never handed a principal**
  — only a namespace and a digest — so a backend has no authorization to get wrong.
- The namespace is the **org id**, deliberately: global dedup across tenants is an
  existence oracle. Blob refcounts must be org-scoped too (DOC-6).
- `domain/authz/sha2.rkt` is SHA-256/HMAC-SHA256 over **libcrypto** — do NOT add it
  to `crypto.rkt`, whose contract is "no native deps". Pinned to NIST/RFC vectors.
- Uploads are a **raw `PUT` body**, not base64 in JSON. `TELEMACHUS_MAX_UPLOAD`
  (default 32 MiB) sets `web-kit`'s `#:max-body-length`; web-server's own default is
  1 MiB and it enforces it by **dropping the connection with no response at all**.
- **Timestamps differ by dialect** and S3 clients *parse* `LastModified`: SQLite
  gives `2026-08-21 04:16:09`, Postgres `2026-08-21 10:12:10.225696-07`. `iso8601`
  in `domain/s3/server.rkt` normalizes both — a malformed one makes every listing
  fail, not just look wrong.
- Every download is `Content-Disposition: attachment` + `nosniff` + a denying CSP
  unless the type is on a short inline allowlist. **SVG/HTML are never inline** —
  same origin as the console means stored XSS.
- `storage.bytes` is a **gauge**: `+size` on write, `-size` on delete, window
  `"total"` (the ledger's `window-clause` falls through to `1 = 1`).
- **Search covers repo objects** (`domain/apps/search.rkt`) by key, filename, AND
  extracted content (`repo_text`, slice 54), with the same per-row `can?` filter as
  notes.
- **The `documents` table is GONE** (migration `0022-fold-documents`, slice 55). A
  text document is a repo object: `content_type text/markdown`, title in the
  version's `filename` (verbatim), key `documents/<slug>-<id8>.md`, body a blob,
  text in `repo_text`. `domain/documents/documents.rkt` is a compatibility SHIM
  keeping the old five-function API — do not add features there; add them to the
  repository. The object kept the old document's id, so grants survived. Tests that
  create documents MUST set `current-blob-root` to a temp dir or they write blobs
  into the checkout's `data/`.
- **Content indexing (slice 54)**: run the `index-documents` workflow (plugin
  `doc-indexer`) — find-unindexed → map → extract, ≤40 docs/run, idempotent. Tools in
  `domain/repo/index-tools.rkt`; extractors in `domain/repo/extract.rkt` (txt/md,
  html/xml/svg tag-stripped, docx via `file/unzip`, pdf via `pdftotext` — pinned as
  nixpkgs `poppler-utils`). Gotchas: a tool handler may return a jsexpr list (the
  agent boundary stringifies; `map #:over` needs the real list); an UNREADABLE file
  is recorded as processed-with-nothing, never raised — one corrupt PDF must not
  wedge the team's indexing forever ('missing-tool still fails hard, deliberately);
  quota admission defers `flow.step` jobs too — an over-budget team stops indexing.

  ```sh
  raco test test/index-tests.rkt   # extractors + the whole pipeline via the scheduler
  ```

```sh
raco test test/repo-tests.rkt test/sha2-tests.rkt   # 99 cases, no server
bash test/server-smoke.sh                            # includes the repository block
```

## Workflow engine (plugins that process in steps)

Slice 46. A workflow is a **validated data spec** — that spec is the public
contract (WF‑9), and `define-workflow` is a macro that emits it, the same move
`define-tool` already makes for tools. See `docs/design/workflow-engine.md`.

- `domain/flow/spec.rkt` is **normative**: both the macro's output and a document
  posted to `/api/workflows` go through `validate-spec`. Never add a second path.
- **Unknown fields are rejected** (WF‑10), including a newer `spec` version and a
  step kind this build lacks. That refusal is the design, not a gap.
- The binding sublanguage is **frozen** (`domain/flow/bind.rkt`): references and
  seven predicates, no arithmetic, no eval. The escape hatch is "write a tool".
- Execution is a reducer: `flow-advance!` reads the run from the DB and enqueues
  the next step as a `flow.step` **scheduler job**, so durability, cancel, quota
  admission and the org gate are all inherited. Nothing lives in memory — a run
  survives a restart because the rows are the state.
- Ships `tool:<name>`, `choice` and `map` (fan-out). `agent`/`job:`/`flow:` deferred.
- A plugin may `(provide workflows)` or drop `workflows/*.json`; those specs are
  **materialized** into a team's `workflow_defs` on first lookup (`source:
  'plugin:<id>'`) — a plugin has no team at load time.
- `${principal.locale}` is `users.locale` (migration 0018), NOT `Accept-Language`.

Operator runbook: `docs/ops/workflow-engine-runbook.md`.

```sh
raco test test/flow-tests.rkt      # 20 cases, no server
bash test/server-smoke.sh          # includes publish → run → assert over HTTP
# needs a live model; refuses to start without one, on purpose:
TELEMACHUS_MODEL_URL=... bash test/translate-chat-demo.sh
```

## Branding (Admin > Branding)

Instance title, tagline and logo, editable by an operator. `domain/branding/branding.rkt`
over a generic `instance_settings` key/value table (migration `0023`), so the next
instance-wide setting needs code, not a migration.

- **`GET /api/branding` is PUBLIC** and must stay so — the sign-in screen renders the
  title/tagline/logo for someone who has no token yet. Writes are `instance:manage`.
- The logo reuses `onboarding_assets` and the existing public `/api/beta/asset/<id>`
  route. One asset mechanism, not two.
- An uploaded logo REPLACES the mark and the wordmark both; the console falls back to
  the Mentor mark plus `S.brand.title` when there is none. This is separate from the
  beta funnel's own theme — that is a public marketing page, this is the product name.

## Paths: anchor at definition, never at use

**`serve/servlet` repoints `current-directory` at the web server's own default web
root while it handles a request** — inside the read-only Nix store on a packaged
install. Any relative path resolved lazily, at write time, therefore aims at the
store. This shipped once: the blob root defaulted to `"data/blobs"` and the first
document save returned
`make-directory: ... /nix/store/.../web-server/default-web-root/htdocs/data/ Permission denied`.
Startup was healthy and every unit test passed.

Use `anchor-path` / `data-dir` from `config.rkt` for anything on disk. Three things
now guard it: roots are absolute by construction, `test/repo-tests.rkt` asserts
"blob roots are absolute and cwd-independent", and **`server/main.rkt` refuses to
boot with a relative blob root** (after plugins load, so it checks the store that
will actually be used).

## Validating the demo end to end

```sh
bash test/e2e/validate.sh                                        # fresh throwaway server
BASE_URL=http://<host>:8835 bash test/e2e/validate.sh --no-server   # a live box
DATABASE_URL="postgres://…" bash test/e2e/validate.sh            # honours a pre-set URL
```

31 assertions, no screenshots: sign-in + branding → bootstrap → notes → documents
create **and edit** → repository upload with byte-identical download → search →
workflows/jobs/usage → Admin > Branding round-trip → sign out/in. It also fails on
**any uncaught page/console error** and **any 5xx**, which is how a broken write path
gets caught even when no assertion names it. The screenshot *tours* do not assert and
will photograph a broken page — use this to gate a deploy.

## Git

- Commit/push only when asked. Branch before committing on the default branch.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
