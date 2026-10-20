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
  uses a *simulated* uppercase-echo fallback. It is no longer SILENT about it
  (issue #64): the boot line warns, `/api/ai/chat` and the stream's final event
  carry **`simulated: true`** (the key is absent on a real call), and the console
  marks the reply. `chat-simulated?` in `executor.rkt` is the one seam that
  decides — read it, never re-derive it from `model-configured?`, or the endpoint
  will report "real" for a call the echo answered. A NAMED executor is never
  simulated: a pull worker answers it or `run-chat` refuses it by name. The doc
  tools, the knowledge graph and `/api/agent` still refuse outright, because an
  echo is useless to them.
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
- **A harness that drives a real model must raise its own AI budget first.** The
  shipped `ai.tokens.total` default is 2,000/day, and since the model-access
  consolidation `/api/agent` both admits on that dimension and meters the
  PROVIDER's token count — a tool-using run costs thousands where it used to bill
  50. So one agent step exhausts a fresh team's whole day, and every model-backed
  step after it is refused. `demo-validate.mjs`, `doc-pipeline-smoke.sh` and
  `pull-smoke.sh` all `POST /api/quota {"dimension":"ai.tokens.total","limit":
  1000000,"window":"day"}` for this reason; `run-tour.mjs` did not, and the
  2026-10-14 refresh caught it only because the tour asserts on the translation —
  it was one assertion away from committing a screenshot of a "quota exceeded"
  toast as the Translation app. Assert the raise, so a silent refusal cannot
  return. The same default is what stalls a downstream batch after its first
  document, so treat "it worked and then stopped" as a budget question first.

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

- **`required` is enforced from the config** (`field-problem`, which lives in
  `domain/fields/fields.rkt` since LAY‑4 and is re-exported from `beta.rkt` —
  the repository's object metadata uses the same vocabulary, so there is one
  implementation rather than two that drift).
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
- Three homes, do not mix them: funnel **copy** → the experience document; server
  **refusals** → `surface/messages.rkt` + `locales/*.json`; and, since Sept 2026,
  the console's own **chrome** ALSO lives in `locales/*.json`, under the `ui.`
  namespace — see "Localization Manager" below. There is no `const L` any more.
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
- **A bulk draft STOPS when the team is over its AI budget, and it looks like a
  hang.** Draft jobs are quota-admitted like every scheduler job: with the default
  `ai.tokens.total` of 2,000/day, the first two batches of the console's 170
  strings spent 4,571 tokens and the remaining 16 jobs sat `queued` with nothing
  `running`. That is the platform working. Before drafting a whole namespace,
  raise the team's budget (`POST /api/quota {"dimension":"ai.tokens.total",
  "limit":200000,"window":"day"}`, operator) — 170 UI strings cost roughly 20k
  tokens on qwen2.5:7b. The Localize tab says this when it queues a draft (the
  draft endpoint returns `budget` with an estimate; `l10nDraft` toasts it).
- **A draft that loses, invents, or mangles a placeholder is refused, not stored**
  (`draft-acceptable?` in `manager.rkt`). Two checks: the simple-placeholder set
  must match, AND the **brace count** must match. The second is what catches the
  stray `{}` / `{.}` qwen2.5:7b appends to sentences — the name check cannot see
  it, and the ICU renderer will not reject it either (it renders an empty name as
  `""`). Never replace this with "does it parse": the formatter is lenient by
  design and accepts exactly the drafts that need refusing. A bad draft in the
  review queue looking finished is worse than a missing one.
- **`nl` and `es-419` were produced with the tool** — drafted by qwen2.5:7b, every
  string reviewed (Dutch quality was rough: Chinese characters in one string, an
  untranslated `AlREADY INITIALIZED.`, `Notitie`→`Regel`; Spanish was mostly fine
  but mixed tú/usted — normalized to usted for system messages). The catalogs
  cover the SERVER messages only; the console's `const L` is a separate home
  (see "Three homes" above) and still ships `en`/`ja`, with a hardcoded switcher.
- **The console's strings are in the catalogs too.** `static/ui-strings.json` is
  the English source of truth for the console (a flat `{"ui.key": "text"}` object);
  the extractor treats a `.json` path as a **JSON surface** and folds it into the
  SAME `en.json` as the Racket surfaces, so one `extract` and one Manager cover
  everything. Japanese lives in `ja.json` under `ui.*`; `const L` is gone. The
  console fetches its strings pre-auth from **`GET /api/i18n/catalog?locale=`**
  (public — the sign-in screen needs them before any token), already resolved
  through the fallback chain server-side, so a 40%-translated locale still gets a
  complete UI in one fetch. A miss shows the bare key, visibly. The CI gate
  includes `static/ui-strings.json`; so does `scripts/build-l10n-review.py`, which
  reads the JSON now rather than scraping `index.html`, and refuses any console
  key that is in no review group.
- **`localizer-for` goes through `locales-dir`** too, so the runtime and the Manager
  see the same catalogs during a test run.
- **The CI gate now covers `en.json`'s FRESHNESS and `ja`'s staleness** (Oct 2026).
  `target-files` deliberately excludes `en.json`, so `locale-report` never had a
  row for "en" and **`--required en` could never fail** — a forgotten
  `telemachus-localize extract` was invisible. That is how issue #43's
  `bundle-ticket` doc string reached `docs/reference/strings.json` and never
  reached `en.json`: the Manager then imported a base ONE STRING SHORT and
  reported Japanese as 100% translated while an English-only string shipped.
  `--required en` now means **the source catalog is current** (`en-report` diffs
  `en.json` against the catalog the surfaces define); `--required en,ja` is what
  CI runs, so an edited English string whose Japanese was not updated fails and
  is named. **An ORPHAN is reported but never blocking**: an orphan only means
  something when the surface list is COMPLETE, and `nix/telemachus.nix`
  legitimately gates two surfaces — treating orphans as fatal there reported 528
  of them and broke `nix build`. `missing` and `changed` are sound under any
  surface list; those two block.
- **The export writes keys in `en.json`'s order, not sorted.** It is byte-stable
  run to run, so a translation diff is minimal — but the committed `ja.json` had
  once been sorted, so bringing it back under the tool renumbered every line
  (1,646 insertions for 36 real changes, one time). `ja.json` and `en.json` are
  key-for-key aligned now, which is what side-by-side review wants. Do not
  "tidy" a catalog by sorting it.
- **A human submission is NOT placeholder-checked.** `draft-acceptable?` guards
  machine drafts only; `l10n-submit!` takes what it is given, so the model is
  held to a standard the human is not. Check placeholder names AND brace counts
  by hand when submitting a batch over HTTP.
- **`POST /api/l10n/review/:id` takes the TRANSLATION id** (not the message id)
  and the body field is **`decision`**, not `action`. `GET /api/l10n/messages`
  caps `limit` at 200 — page with `offset` or an id map comes back short and the
  writes land on the wrong rows.
- **The server honours `TELEMACHUS_LOCALES`** (as the CLI does) because export
  WRITES into that directory. The smoke and e2e suites point it at a temp copy
  and use the pseudo-locale `qps` for "a locale with no catalog" — a real locale
  name there is a bug waiting for the day someone produces it, which is exactly
  what happened with `nl`.

```sh
raco test test/l10n-manager-tests.rkt    # 13 cases, no server
bash test/server-smoke.sh                # includes the HTTP block (see below)
```

**Test the ENDPOINTS, not just the model.** The bug that actually bit here lived in
the HTTP layer: `query-param` compared a string key with `assq` against
`url-query`'s *symbol* keys, so every filter silently fell back to its default and
a request for Dutch was answered with Japanese. A filter that is ignored rather
than refused is invisible to a model test.

## Chat: content parts and response formats (issue #18)

`domain/ai/content.rkt` is the ONE place both are decided, so the agent loop, the
chat endpoint, the stream and the pull wire cannot disagree.

- **A reply's content may be PARTS**, the OpenAI `[{type:"text",text:…}]` shape.
  `(if (string? c) c "")` used to read every reply, so a parts reply became an
  empty message and nobody complained. `content->text` joins text parts; content
  that carries parts and NO text is a named error, never a quiet `""` — that is
  the whole point, an empty answer must never be manufactured. Content that is
  absent/`null`/`[]` is still legitimately "" (a tool-call-only turn), which is
  why the agent parsers only raise when the turn has no tool calls either.
- **`prompt` on `/api/ai/chat` is a string OR parts.** `content-problem` refuses
  anything else up front (`text` and `image_url` only) — an unknown part shape
  otherwise reaches the provider as an opaque 400 that names nothing.
- **`response_format` rides to the model AND is checked here.** Most local servers
  ignore the field, so a schema request would otherwise come back as prose the
  caller parses as if it had conformed. `json_object` and `json_schema` go through
  `domain/tools/jsonschema.rkt` — the same validator, and the same
  `$.total: expected number, got string` refusal, as the pipeline's DWF‑5
  extraction. `outer-json` (a fence or a sentence around the JSON is fine) is
  shared with doc-tools for the same reason.
- **The simulated fallback refuses a format** rather than passing an upper-cased
  echo off as conforming JSON — same call as the doc tools' "no model configured".
- **Streaming judges the format at the END**: `run-chat-stream` returns
  `(values tokens text)` now, and the final SSE event carries `parsed` or
  `schema_error`. Raising after the answer has already streamed would be worse.
- **The wire carries it too**: `infer.chat`'s payload takes `response_format`, its
  validator accepts `reply` (a string) or `content` (parts), and the reference
  worker forwards the format. The `pull-router` box is
  `(name msgs temp rf)` — a 3-arg test double will fail with an arity mismatch.

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
- **TEN‑2d (slice 68): a company's hostname and branding.** `orgs.domain`
  (migration 0029, unique) is set by the SUPERADMIN only — `PATCH /api/orgs/<ref>
  {"domain": "acme.example"}`, `null` clears — because a company must not be able
  to claim another company's hostname, or the instance's. `request-org` in
  main.rkt resolves the Host header first (`org-by-domain`: lower-cased, a
  trailing `:port` dropped, a hostname and nothing else), then the caller's own
  org when the request carries a valid token, and only when multi-tenancy is on.
  Branding is one more `instance_settings` document, `branding:<org-id>`
  (`branding-for` = the company's if set, else the instance's, WHOLE — no
  per-field merge, so "unset" looks exactly like today). `PUT/GET/DELETE
  /api/org/branding` + `POST /api/org/branding/logo` for the org admin; the
  public `GET /api/branding` and the console's `<title>`/OG tags follow it, with
  `scope: org|instance` saying which one answered. The console needs no change:
  `loadBranding()` already sends the bearer, so a signed-in user gets their
  company's branding on any host. Slug-derived subdomains were rejected: a real
  customer has a real hostname with DNS and TLS in front of the box.
  `test/multitenant-demo.sh` section 8b; `test/tenancy-tests.rkt` (the upgrade
  test's "old world" is now every migration BEFORE 0016 — a later migration may
  touch `orgs`, and 0029 does).
- **TEN‑2h (slice 65): the `org_reader` role reads across the company.** It holds
  `org:read-data`, which `can?` maps onto the team-tier DATA reads only
  (`DATA-READ-PERMS` = notes/documents/files `:read`) in every team of its org —
  `org-data-reader?` in `can?`'s base check and in the cross-team reachability
  branch, which still refuses `private`. **`org:*` does NOT imply `org:read-data`**
  (`perm-matches?` special-cases it): org_admin and org_owner still do not read,
  so TEN‑2a stays the default. `?scope=org` on `GET /api/notes`, `/api/repo` and
  `/api/search` lists every team in the caller's org through the same per-row
  `can?` — a plain member asking for it sees nothing new. `PATCH
  /api/org/members/<id> {org_role}` grants/revokes any org role (never your own).
  `org-teams-of` in authz.rkt is the org's team list for such listings.

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

**The smoke runs with secrets SEALED** (issue #25): it exports a
`TELEMACHUS_SECRET_KEY` unless you set one, because since #19 SigV4 unwraps the
credential on every signed request and the presign path unwraps through
`s3-cred-newest` — the case a mock cannot prove. `awscli2` is in the devShell and
CI installs AWS CLI v2, so the suite no longer skips silently; a skip was how that
path went unexercised in the first place. Pass `TELEMACHUS_SECRET_KEY=` (empty) to
exercise the plaintext path instead.

The smoke EXPORTS `PORT` (default 8890): the server reads it from the environment,
and a merely-defaulted shell variable is not exported — the server then boots on
8835 and the readiness loop waits on 8890 for ten minutes before "server never
came up". Run the S3 and server smokes one at a time; both default to 8835-ish
ports and the sweep runs them sequentially for that reason.

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
- **`repo-get` RAISES on a permission failure while `repo-open` answers `#f` for
  a MISS.** Any caller that reads a document has to handle both, or a forbidden
  read surfaces as a 500 instead of a refusal. It has caught two callers already
  (LAY‑6's out-of-process `repo.*` capabilities, PULL‑9's worker read), which is
  why the note lives here rather than beside either of them. Where the two
  outcomes should be INDISTINGUISHABLE — "does not exist or is not yours" as one
  answer, the knowledge graph's rule — collapse them deliberately and say so.
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

## Document sharing (slice 56)

Three capabilities over the grants table that already existed. Design:
`docs/design/document-sharing.md` (DSH‑1…6, decided; all built — slice 59 added
the dialog's pickers and "Shared with me").

- **The share dialog's principal picker is `GET /api/share-targets`**: the team's
  active members plus the org's teams (`own: true` marks the caller's). Nothing
  outside the org is ever offered — DSH‑6 by construction, not by validation.
- **`GET /api/repo?shared=1`** is "handed to me": objects with a LIVE grant for
  the caller (user or acting team) that the caller does not own. A team-visible
  document is not "shared with me", and neither is your own.
- The dialog sends `expires_at` as `<date>T23:59:59Z` — "until this day",
  inclusive. Revoke is per principal (`principal_type` + `principal_id`).

- **A grant DELEGATES now.** `can?` used to take the permission from the caller's
  role and use a grant only to *reach* a private resource, so a member handed
  `manage` still could not share and a viewer given `edit` could not edit. A
  matching grant now confers the permission on that one resource, team tier only,
  still capped by token scopes. This is the single contract change of the slice —
  if a test that grants `documents:write` to a viewer starts passing, that is why.
- Capabilities are permission SETS granted row by row (`CAPABILITIES` in
  `repo.rkt`): view = `files:read`; edit = + `files:write`; manage = +
  `files:delete` + `files:manage`. Never a wildcard. Sharing again with the same
  principal REPLACES the set (narrowing drops rows) and renews the expiry.
- **Only `manage` re-shares** (DSH‑2): `repo-share!`, `repo-unshare!`,
  `repo-grants` AND `repo-set-visibility!` require `files:manage` on the object.
  Owner-ok covers the owner; a team admin has it by role for what the role reaches
  — a colleague's team-visible document, **never their private one** (private is
  private from admins too; only a grant or the owner opens it).
- `expires_at` is **epoch seconds** in the row, `NULL` = never; `has-grant?` adds
  `expires_at IS NULL OR expires_at > now`. Expired rows stay (audit trail) and are
  listed with `expired: true`. The API takes ISO‑8601 or epoch seconds
  (`expiry->seconds`), returns ISO‑8601 UTC. A past expiry is a 400, never a row.
- A principal must be **in the object's org**: a user by `users.org_id` OR an active
  membership in one of its teams (an operator's `org_id` is NULL — the membership
  clause is what lets you share with the operator); a team by `teams.org_id`. Else
  400 — the org gate would leave the row inert, and nobody should be told "shared".
- `{user_id}` on `POST /api/repo-obj/<id>/share` still means "this person, view".
  The full body is `{principal_type, principal_id, capability, expires_at}`.
- `repo-inherit!` (DSH‑5) copies the source's visibility + LIVE grants onto a
  derived document and writes a `repo_derivations` row; afterwards the two are
  independent. It needs `files:read` on the source and `files:manage` on the
  target (owner-ok for the run's principal). `GET /api/repo-obj/<id>/derivations`
  is the provenance read.
- `grant!` is now an **upsert** (`ON CONFLICT … DO UPDATE SET expires_at,
  granted_by`) — granting again renews. `test/fold-tests.rkt` seeds its pre-0025
  grant with raw SQL because the column does not exist yet in that database.
- The grants listing is ordered by `created_at`, which has second resolution — a
  test must find a principal's entry by id, never by position.
- Notes sharing took a free-form permission string; it is pinned to `notes:*` now,
  because a grant delegates.

```sh
raco test test/repo-tests.rkt          # case 7 + expiry parsing (151 cases in the file)
bash test/server-smoke.sh              # the "share:" block, 20 assertions
```

## Document pipeline (slices 57–58) — the first-user path

Upload a file, run `process-upload` (by hand, or let a **trigger** run it on
arrival), get fields + a filled form + translations back as documents beside the
source. Design: `docs/design/document-workflows.md` (DWF‑1…8, decided; all
five steps built, slices 57–59). Four core tools in
`domain/repo/doc-tools.rkt` (`doc_text`, `doc_extract_fields`, `doc_render`,
`doc_translate`), composed by `plugins/doc-pipeline/`; triggers in
`domain/repo/triggers.rkt` on the seam at the end of `repo-put!`.

### Triggers (slice 58)

- **One seam.** `repo-put!` ends by calling the hook in a box (`set-put-hook!`);
  requiring `triggers.rkt` installs `fire-triggers!`. Console upload, the
  documents shim and an S3 PUT all pass through it. The hook never raises into
  the upload — a fire that cannot start leaves `error` on its `doc_trigger_fires`
  row and a `doc.trigger.error` audit event.
- **The run is the uploader's** (DWF‑2), scopes and all. An S3 key issued with the
  default `files:*` scopes CANNOT start a workflow — the fire row says
  `workflows:run`. Issue the key with `workflows:read` + `workflows:run`. The
  smoke's section 7 pins both halves with the real `aws` CLI.
- **`#:derived?` on `repo-put!` is `#t` or the run id.** The tools pass the run id
  (`derive!`), because the derivation row is written AFTER `repo-put!` returns and
  the seam needs to know, right then, that this output came from a run this
  trigger started. Without it an opted-in trigger on `application/json` fired on
  its own extracted JSON 50 times in the unit test.
- **`fire_on_derived` = other pipelines' outputs, never its own** (`own-descendant?`).
  Off by default (DWF‑3).
- **Exactly once per version**: the `(trigger_id, version_id)` row is claimed
  before the run starts; a re-upload is a new version and fires again. Fires are
  ordered by `fired_ms` (epoch ms) — `CURRENT_TIMESTAMP` is seconds, and a test
  that asserts "newest first" on two fires in one second will flap.
- The arrival (`object_id`, `version_id`, `key`, `content_type`) WINS over the
  trigger's `input` on a clash.
- `GET /api/doc-triggers` carries `budget` (the team's `ai.tokens.total`): queued
  runs under a trigger are a team out of tokens, not a broken trigger.

```sh
raco test test/doc-triggers-tests.rkt      # matching, the seam, exactly-once, derived guard, scoped keys
```

### "Processed by", Automations, DOCX (slice 59)

- `GET /api/repo-obj/<id>/processing` (`object-processing` in `triggers.rkt`):
  derived documents, sources, and every run that touched the document — found
  through derivation rows, trigger fires, and a `LIKE '%"object_id":"<id>"%'`
  over `workflow_runs.input` (the JSON is written without spaces, so the pair is
  one substring). Each row is authorized on its own. Runs are ordered by
  `created_at`, which is second-resolution — do not assert "newest first" on
  runs started in the same second.
- The Automations card lives on the **Workflows** tab (`automationsCard`), with
  `trgCreate/trgToggle/trgDelete/trgHistory`; the create form's input textarea
  is prefilled with `PIPELINE_EXAMPLE_SCHEMA`.
- **PDF forms (DWF‑6, slice 68)**: `doc_render {format: "pdf"}` fills a
  Markdown or HTML template as before and hands the finished text to
  **pandoc → tectonic** (`render-pdf`), writing `<key>.form.pdf` as
  `application/pdf`. The toolchain is `find-executable-path`'d at CALL time —
  a box without it boots and every other format works; the one call fails with
  "needs pandoc and tectonic". `nix/telemachus.nix` puts both on the packaged
  wrapper's PATH; a bare `racket server/main.rkt` needs them installed. tectonic
  fetches TeX packages on its first run into `~/.cache/Tectonic` (the SERVER's
  home) — a fresh box needs the network once, or a pre-warmed cache; a 429
  from the bundle mirror is a retry, not a failure. A DOCX template is refused
  for PDF (no LibreOffice). `format` is a TOOL argument, not a pipeline input:
  a workflow binds it as a literal (`"with": {"format": "pdf", …}`, see the
  `pdf-form` spec `test/doc-pipeline-smoke.sh` publishes); the four
  `process-upload` inputs did not change. The unit test and the smoke exercise
  the real toolchain when it is on PATH and assert the named refusal otherwise.
- **DOCX**: `render-docx` unzips to a temp dir, runs `docx-prepare` on
  `word/document.xml` (re-joins placeholders Word split across runs; turns a
  marker-only table row into the `{{#each}}` marker so the rows between repeat),
  renders with XML escaping, and zips back with `file/zip` from inside the temp
  dir. A template that is not a zip, or a zip with no `word/document.xml`, is a
  named error. Tests build real .docx files with `file/zip`; the smoke with
  Python's `zipfile`.
- **The e2e gate boots the scripted mock model** (`test/mock-llm.rkt`, chat
  mode) when it boots its own server, so the pipeline scenario is deterministic
  and takes seconds; `VALIDATE_PIPELINE=1` opts a live box in. The scenario
  drives the console only: `repoRunWorkflow`, the run form by `S.wfKeys` index
  (input order is a hash's — never assume `#wfi_0` is `object_id`), `wfStart`,
  `repoOpenDetail` → `#rprocessed`, `repoFilter(true)` → `#rf_shared`,
  `trgCreate` → `trgHistory` → `#tg_history`.
- **Switching tabs in the gate is `goTab(page, tab, sel)`, never `go()` +
  `waitForSelector`.** `go()` re-renders asynchronously and `renderTab` paints a
  `…` placeholder first; on a tab the page is ALREADY showing, `waitForSelector`
  matches the old DOM and the next assertion can run against the placeholder.
  That is exactly how "localization card present in Admin" failed once in CI
  (slower runner) and never locally. `goTab` waits for a LATER `renderSeq`, no
  placeholder, and the selector.

- **The model is a parameter**: `current-doc-chat`. Tests script it; the HTTP
  smoke uses `test/mock-llm.rkt`'s CHAT mode (`MOCK_REPLY_FILE`, a `{"needle":
  "reply"}` map matched against the request text — needles are `"extract
  structured data"` and `"professional translator"`); set `TELEMACHUS_MODEL_URL`
  and the same smoke runs live. **With no model the tools refuse** ("no model
  configured") — the uppercase-echo fallback would otherwise fail every schema
  with "did not return a JSON object", which is true and useless.
- **Extraction is refused on mismatch, never flagged** (DWF‑5).
  `domain/tools/jsonschema.rkt` is a JSON Schema subset with one deliberate
  difference: an object with no `additionalProperties` is CLOSED. The refusal
  names the path (`$.total: expected number, got string`). The `fields` step
  retries once. The reply's outermost `{…}` is what gets parsed, so a fence or a
  sentence around the JSON is fine; no object at all is refused.
- **The renderer is strict**: a `{{placeholder}}` the data lacks is an error, not
  a blank. `{{#each}}` blocks nest; the outer scope is visible inside one; HTML
  templates escape. The template is a repository document, by id or by key.
- **Keys**: `<key>.extracted.json`, `<key>.form.<template ext>`,
  `<key>.form.<locale>.<ext>`; a translation of the SOURCE is
  `<key minus ext>.<locale>.<ext-or-txt>`. Re-runs version the same key.
- **A derived document is private from its first byte**: `derive!` passes the
  source's visibility to `repo-put!` and THEN `repo-inherit!` copies grants and
  writes the derivation row. Do not reorder that.
- **All four workflow inputs are required** by the engine (`check-input!`); `""`
  and `[]` mean "skip". The console's run form sends a PREFILLED empty (from
  "Run workflow…" on a document) instead of dropping it; an untouched blank on
  any other workflow is still omitted, as before.
- **The AI tools meter themselves** (`tenant-quota-record!`, both tiers): the
  scheduler bills a job's top-level `tokens_used`, and a tool step's result sits
  under `result`. `quota-check` reports `used: 0` when no limit is set — read the
  ledger with `quota-used … "total"` in a test. Raise `ai.tokens.total` before a
  batch (the smoke sets 1,000,000/day) or the queue stalls silently.
- **`doc_text` fails on an unreadable document** (unlike indexing, which records
  nothing): someone is waiting for fields, and silence would look like success.
- **`render-template` clashes with the beta template renderer's name** — main.rkt
  requires `doc-tools.rkt` with `(only-in …)` for registration only.
- **`translate!` takes `#:chat` as `(chat text sys)`**, positional; the doc tools
  adapt the keyword seam to it. `translate!` does not meter — the caller does.
- A viewer of a shared document may run the pipeline; the outputs are THEIRS. If
  the owner already ran it, the derived keys are the owner's private objects and
  the viewer's run fails with `forbidden: files:write` rather than clobbering.

```sh
raco test test/doc-pipeline-tests.rkt      # validator, renderer, refusals, the whole pipeline via the scheduler
bash test/doc-pipeline-smoke.sh            # deterministic, scripted mock model; ends with an S3 PUT firing a trigger
TELEMACHUS_MODEL_URL=… bash test/doc-pipeline-smoke.sh   # the same against a live model
```

## The route table and the generated reference (slice 60)

`server/routes.rkt` DECLARES every HTTP route: method, path pattern, handler key,
auth, permission, feature, one line of doc. `main.rkt`'s `HANDLERS` binds keys to
procedures of `(req . path-params)` and **refuses to boot** if the two disagree.
`docs/reference/` is generated from that table, the tool registry, the plugin
loader, the workflow specs and the permission catalog by `cli/telemachus-docs.rkt`
and is COMMITTED; CI runs `telemachus-docs check` and fails on drift.

- **Adding an endpoint = one entry in `routes.rkt` + one handler in `HANDLERS`**,
  then `racket cli/telemachus-docs.rkt render` and commit `docs/reference/`.
  Forgetting the render fails CI; forgetting either half refuses to boot.
- Patterns: literal segments, `:name`, `*name` (rest of path). First match wins in
  list order — keep `/api/workflows/schema` above `/api/workflows/:slug`.
- **Every permission needs a description** in `PERMISSION-DOCS`
  (`domain/authz/permissions.rkt`); a built-in role granting an undescribed one
  is a LOAD error, and the docs CLI checks every route's permission too.
- **Never `write-json` a hash in the generator**: `hasheq` iteration order is not
  stable across processes and the drift gate would cry wolf. `json-out` sorts.
- `docs/reference/strings.json` is a JSON surface for `telemachus-localize`:
  every description is a `doc.*` message (249). The CI localize gate includes it.
  `render --locale ja` writes `docs/reference/ja/` from the catalogs, English
  where a string is not yet translated. `doc.*` was drafted into Japanese with the Manager on 15 Sep 2026 (257 machine drafts, 142 corrected by hand — the 7B model mixes in French/Spanish/Chinese fragments and leaves English words; review every draft) and `docs/reference/ja/` is committed; re-render it after drafting more.
- The CLI evaluates the plugins (`load-plugins!`), so run it inside `nix develop`.

```sh
racket cli/telemachus-docs.rkt render      # regenerate docs/reference/
racket cli/telemachus-docs.rkt check       # the CI gate
```

## Knowledge graph (slice 61)

Entities and relations from the team's documents, every fact bound to the
document and version that said it. Design: `docs/design/knowledge-graph.md`
(KG‑1…7, all built). `domain/kg/kg.rkt` + `kg-tools.rkt`; plugin
`knowledge-graph` (workflow `index-knowledge`); `/api/kg/*`; the Knowledge tab.

- **Nothing enters without a source, and visibility is the source's** (KG‑3):
  `kg-entity`/`kg-find` return only what has a mention on an object the caller
  `can?` read, and each relation carries only ITS readable mentions. `#f` means
  "does not exist or you cannot see it" — indistinguishable on purpose.
- **The extractor refuses** a reply whose snippet is not a verbatim substring of
  the text, a relation to an entity not in the reply, or a nameless entity
  (`validate-extraction`). The step retries once. Same model seam as the pipeline
  (`current-doc-chat`); with no model it refuses loudly.
- **`kg_extract` reads `repo_text`** — run `index-documents` first. A document
  with no text is marked extracted-with-nothing (`kg_extractions`) so it is not
  listed forever; that fourth table is the one deviation from the design.
- A new version supersedes (old mentions go, orphans pruned); `repo-delete!`
  calls the delete hook (`set-delete-hook!` in repo.rkt) → `kg-forget!`.
- Dedup: `(team, type, normalize-name)` — lower-case, collapsed whitespace, a
  short suffix list. No cross-type merging (KG‑4).
- Search returns `type: "entity"` rows under the same rule; the agent's
  `kg_query` answers in text with `[key]` citations.
- KG‑7 (a `utility` model role) is not distinct yet — one configured model.

```sh
raco test test/kg-tests.rkt        # the mention rule, validation, supersession, the pipeline
```

## The developer e-book (`docs/book/`)

**The source is Markdown, one file per chapter** — `docs/book/en/*.md` — because a
translator must never have to edit LaTeX (issue #50). `docs/book/build.sh` inside
`nix develop` assembles those into one intermediate and writes two editions from
it: `tectonic` → the PDF, `pandoc` → a single self-contained HTML page
(`book.css` inlined). `bash build.sh` is English; `bash build.sh ja` builds from
`ja/`. The built PDF and HTML are committed beside the source; rebuild and commit
them together. The old `telemachus-for-developers.tex` is GONE — do not
reintroduce a hand-edited `.tex`, it would be a second source of truth for a book
that now has translations.

- **`chapters.json` is the spine**: the chapter ORDER, each chapter's art stem and
  its flags (`unnumbered`, `toc_after`). A translated title therefore cannot
  reorder the book or lose its sketch. Per-language metadata (title, subtitle,
  author, date) is `<lang>/book.yaml`; a CJK language adds `cjkmainfont` /
  `cjksansfont`. The LaTeX preamble is `template/book.latex`.
- **The heading id comes from the ART stem, not from the title** (`# Title {#ch-04-authz}`,
  injected by build.sh), so the HTML's `h1#<stem>::before` art rules survive
  translation — pandoc's title-derived ids would change in every language. Two
  chapters sharing one art stem is refused for that reason.
- **A missing translated chapter is omitted and LISTED**, so a partial translation
  still builds a readable book. Tectonic fetches TeX packages on first run (a 429
  from the bundle mirror is a retry, not a failure), cached under `~/.cache/Tectonic`.
- **Three checks on a translated chapter**, all of which have caught a real defect:
  a code span must be ASCII (it names a path or a command; a full-width character
  or a typographic quote in one otherwise surfaces as `Undefined control sequence`
  pointing into a deleted intermediate) — that one REFUSES; Cyrillic/Hangul/Arabic/
  Hebrew/Thai/Devanagari in the prose warns (the machine-assisted `ja` catalog
  leaked French, Spanish and Chinese, and the first sample chapter here shipped a
  Russian word); and a chapter carries the **sha1 of the English it was made
  against** on its first line, so editing the English marks it stale with nothing
  rewriting a status — same rule as `locales/ja.json` and `captions.ja.json`.
  `bash build.sh ja --record` stamps them and builds nothing.
- **`xeCJK`'s default family is FandolSong (Chinese) and it silently DROPS Japanese
  glyphs** — 権 vanished from 権限 with no error. `template/book.latex` sets
  `\setCJKmainfont` from `book.yaml`.
- **The CJK fonts ARE in the devShell now; they were not, and this note said they
  were.** Two separate problems sat behind one error message
  (`The font "Noto Serif CJK JP" cannot be found`). First, `flake.nix` never
  listed them. Second, adding them is not enough: **tectonic resolves fonts
  through Core Text on macOS, not fontconfig**, so a devShell font is invisible to
  it however much `fc-list` can see — and nixpkgs now ships Noto CJK as
  **variable-font collections** (`NotoSerifCJK-VF.otf.ttc`) whose family name
  XeTeX cannot resolve at all, by name or by face index. So the devShell takes the
  `-static` packages, and `build.sh` resolves them to a DIRECTORY and the template
  loads the faces **by path**: `[Path=…, Extension=.ttc, FontIndex=0]`, where
  index 0 is the JP face (1 KR, 2 SC, 3 TC, 4 HK — the wrong index is the same
  failure xeCJK's Chinese default produces, silently). `BoldFont` is named
  explicitly, because a face loaded by path gives fontspec no family to search and
  every heading would otherwise be a faux-bold smear. Serif and sans are resolved
  SEPARATELY: one directory for both built fine and was a trap, since fontspec
  loads a face lazily and no chapter has a sans CJK glyph yet.
  `TELEMACHUS_CJK_DIR` overrides the search; with no directory found the template
  falls back to the family name, which is what works on a box with the fonts
  installed system-wide.
- Translator-facing instructions and the term list (pinned to the console's own
  `locales/ja.json`, so the book and the product use the same words) are
  `docs/book/TRANSLATING.md`.
- **The character art**: `docs/book/art/telemachus-sketch.svg` is the master
  (hand-authored SVG: ink paths, a `feTurbulence` wobble, construction marks).
  **`art/vignettes.py` generates one scene per chapter** (`ch-NN-*.svg`) from a
  parts library in the master's coordinate space — head, five expressions, bust
  or full figure, arm poses, walking legs, the owl in three poses — plus a
  per-chapter prop; it reads `../chapters.json` and writes `chapter-art.css` (one
  `h1#<stem>::before` rule per chapter, SVG data URIs). `art/render.mjs` renders
  every SVG in the directory to PNG at 3× with the e2e directory's Playwright
  (`node docs/book/art/render.mjs` from the repo root). The PDF picks each
  chapter's PNG via `\chapterart{…}` before the `\chapter`; the HTML gets the
  SVGs through `book.css` + `chapter-art.css`. Change a scene in the generator,
  never in a generated SVG; then regenerate, render, rebuild.
- **Adding a chapter is four steps**: `en/NN-stem.md` (plain Markdown, `# Title`
  first line), a row in `chapters.json`, a scene in `art/vignettes.py` (the stem
  carries the number, so inserting one renames the stems after it — `git rm` the
  old pair), `python3 art/vignettes.py && node art/render.mjs`, then
  `bash build.sh`. Every translated copy of a chapter you edit goes stale and says
  so on the next build.
- **Props live in a 360×300 viewBox under `translate(-30 -40) scale(0.55)`**, so a
  prop's x must stay under ~700 and y between ~80 and ~600 or it is clipped. The
  proven slots: a main block at x 500–700, a held item at x 120–240 / y 150–230,
  and a small item beside the figure at x 364–434.
- Keep the Markdown plain — headings, lists, pipe tables, fenced code — so pandoc
  renders the same book in both editions. **Pipe tables, never width-aligned
  ones**: a CJK edition's column widths do not match the English.
- `\texttt{}` has no `…`: the typewriter font drops it with a warning and the
  character vanishes from the PDF. Spell it `...` inside code text.
- `KEEP=1 bash build.sh [lang]` leaves the assembled Markdown, the generated
  `.tex` and the TeX log (`docs/book/.book.<lang>.*`, gitignored). A LaTeX error
  names a line in the GENERATED file, so without it there is nothing to read.

## Localized prose docs (issue #50)

The top-level README ships in Japanese as `README.ja.md`, and the two link to each
other with a switcher line under the badges.

- **The feature-tour section of BOTH READMEs is generated**, between the
  `<!-- BEGIN/END FEATURE-TOUR -->` markers, by
  `refimpl/racketmaximus/test/e2e/refresh-screenshots.sh`. Hand-translating that
  region would have been silently reverted by the next refresh, which is the
  whole reason the captions live in a catalog instead.
- **Japanese captions are `docs/screenshots/captions.ja.json` and
  `docs/screenshots/beta/captions.ja.json`**, keyed by screenshot filename and
  carrying a **sha1 of the ENGLISH title + caption** — the same source-hash rule
  `locales/ja.json` lives by. Edit an English caption in `run-tour.mjs` /
  `beta-tour.mjs` and the hash stops matching.
- **A missing or stale caption falls back to English and is REPORTED by name.** A
  half-translated page that looks finished is worse than an obviously
  untranslated one; the script prints every fallback and tells you which file to
  fix.
- **`README_ONLY=1 bash refimpl/racketmaximus/test/e2e/refresh-screenshots.sh`** is
  the translator's mode: it rebuilds both READMEs from the committed manifests and
  caption catalogs with no browser and no image work. Use it after editing a
  caption catalog. **Do NOT reach for `SKIP_TOURS=1` for translation work** — if a
  `catalog/` happens to exist it re-promotes every PNG from that possibly stale
  run, which is 19 changed images that have nothing to do with the translation.
- The site publishes `README.ja.html`, and the English README is now emitted at
  **both** `readme.html` (what the landing page links) and `README.html` (what the
  link rewriter produces from a `../README.md` link, which four docs use). The
  Pages link check is what proves both resolve.
- **The `ja` catalog is COMPLETE and gated** (Oct 2026): 548/548, zero stale,
  reviewed string by string. The 36 that were outstanding were drafted with the
  Manager and hand-corrected — 15 of 23 machine drafts needed it, including
  `nunca` (Spanish) in two strings and `上的文本` / `可能是的` (Chinese) in two
  more. Twelve were STALE rather than missing, and three of those documented the
  **pre-#24 worker protocol**: `docs/reference/ja/api.md` told a Japanese reader
  to post `{result}` with no `claim_token`, which 409s on every write. CI now
  fails on that class (see the Localization Manager section).
- **#50 is complete: all 19 e-book chapters are translated** (14 Oct 2026), stamped
  against the English they were made against, and both `ja` editions are committed.
  The title page says what the edition IS — machine-translated, pending native
  review, English authoritative — rather than implying more than was done. The
  sample chapter `ja/00-read.md` was also one paragraph SHORT of its English: the
  source-hash rule catches a stale translation and cannot see an incomplete one, so
  a chapter copied across needs reading to the end.

## The published site (GitHub Pages)

`scripts/build-site.sh` assembles `build/site/` with pandoc — the book (both
editions, already built and committed), the README, the integrator's guide, the
generated reference (including `ja/`), the runbooks and the design documents.
`.github/workflows/pages.yml` runs it on a push to `main` that touches `docs/`,
the README or the builder, and deploys with `actions/deploy-pages`.

- **The site mirrors the REPOSITORY's layout**, `.md` becoming `.html`, so every
  relative link between documents resolves on the site exactly as in a checkout.
  Flattening the paths broke four links the first time it ran; the workflow now
  fails on any local link that does not resolve.
- `scripts/site/links.lua` rewrites a link to a source file (anything not
  published) into a GitHub blob URL, which is honest where a dead relative link
  would 404.
- **The measure lives on `body`**, not on `main`: a pandoc page has no wrapper
  element, so a rule keyed on `<main>` leaves every generated page full-bleed.
- CI needs only pandoc — no LaTeX, no Racket — because the book's PDF and HTML
  are committed artifacts. Rebuild them with `docs/book/build.sh` inside
  `nix develop` and commit them with the source.

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
  'plugin:<id>'`) — a plugin has no team at load time. The insert is `ON
  CONFLICT DO NOTHING`: the console fires the Workflows list and a "Run
  workflow…" lookup in parallel, and on a team that had never looked, both saw
  no row and the second insert 500ed on `UNIQUE(team_id, slug, version)`. The
  e2e gate caught it; the smokes, which look things up one at a time, never did.
- `${principal.locale}` is `users.locale` (migration 0018), NOT `Accept-Language`.

Operator runbook: `docs/ops/workflow-engine-runbook.md`.

```sh
raco test test/flow-tests.rkt      # 20 cases, no server
bash test/server-smoke.sh          # includes publish → run → assert over HTTP
# needs a live model; refuses to start without one, on purpose:
TELEMACHUS_MODEL_URL=... bash test/translate-chat-demo.sh
```

## Issue #54's remaining platform defects (built 12 Oct 2026)

- **LAY‑8 — a PDF with no text layer is `'needs-ocr`, not a successful empty
  extraction.** It used to be indistinguishable from a blank page: the row was
  written, the object was never listed again, and the real failure surfaced much
  later as a schema refusal on an empty document that named nothing. Scanned
  paperwork is the normal case for the documents this platform is for. The
  indexer's `else` branch already records any reason as processed-with-nothing,
  so there is no retry loop; `doc_text` refuses by name ("it is a scan, and needs
  OCR"). This is the prerequisite for any OCR work — without it nothing can tell
  which documents need it.
- **A misconfigured `TELEMACHUS_BLOB_STORE` refuses to boot.**
  `active-blob-store-name` falls back want → rs3 → builtin, so a typo quietly
  wrote every document to local disk while the instance reported healthy. Checked
  after plugins load, beside the relative-blob-root refusal, and the message
  lists what IS registered.
- **Quota limits are BIGINT** (migration `0035`, PostgreSQL only — SQLite's
  INTEGER is already 64-bit). `limit_value INTEGER` meant a limit above
  2,147,483,647 worked in development and threw a raw SQL error in production.
  Not hypothetical: `storage.bytes` is a byte count, so **any storage quota above
  2 GiB crossed it**. Validating the input instead would have refused a legitimate
  configuration.
- **A worker claim filters by kind in SQL.** It took the oldest 64 queued jobs of
  ANY kind and filtered in Racket, so a remote job behind a wall of in-process
  ones was invisible and the worker polled forever against work it could have
  run. `remote-kinds` (scheduler.rkt) feeds an `IN` clause, so the window bounds
  the scan rather than the answer. `test/pull-tests.rkt` pins it — and that test
  FAILS against the old code, which is the only reason it is worth having.
- **`.mjs`, `.map`, `.wasm`** (plus `.txt`, `.webmanifest`) are in `STATIC-MIME`.
  An unknown extension becomes `application/octet-stream`, and every response
  carries `nosniff`, so a Tier‑B bundle shipping ES modules or wasm was REFUSED
  by the browser rather than mistyped.
- **The `approve` gate the workflow-engine design named for a year does not
  exist and must not be built.** `docs/design/workflow-engine.md` specified an
  `approve` step kind and `POST /api/runs/<id>/approve/<step>` while `spec.rkt`'s
  own `planned_step_kinds` never listed it — the contradiction issue #54
  reported. The human gate shipped as **`review`** (LAY‑1…3), wider than that row
  described and with its own queue rather than a release endpoint. The design doc,
  its slice plan and decision WF‑5 all say so now.

## Cancelling running work, a run-time ceiling, worker reads (issue #54's four questions)

Built 12 Oct 2026 — SCHED‑8, SCHED‑9, PULL‑9, RBAC‑5b in `docs/design/decisions.md`.

- **A running job is cancellable, and the status that makes it safe is
  `canceling`.** `status` was doing two jobs at once: "is this work live" (the
  per-team cap counts it) and "may its result land" (`finish!` guards on
  `running`). Cancellation needs those to diverge, so a running job goes to
  `canceling` — `finish!` still names `running` alone, so the handler's answer
  matches no row and is discarded, while the cap counts `running` + `canceling`
  (`LIVE-IN`, used by BOTH claim paths). Flipping straight to `canceled` would
  have been a **quota-evasion path**: cancel N running jobs in a loop and the
  team gets N draining handlers plus N freshly claimed ones, with the cap
  reading as satisfied throughout. `settle-canceling!` frees the slot when the
  handler actually returns — guarded on the attempt's `claim_token`, so a
  reaped-and-re-claimed job is left alone.
- **Nothing is preempted, and the reason is specific.** Killing the handler
  thread would leave the SHARED db connection in an undefined state and could
  wedge the whole pool. The cooperative half is `job-canceled?`, for a handler
  that runs in steps; it is an optimization (CPU and tokens), never a
  correctness requirement, because the result is fenced out either way.
- **Who may cancel: owner-ok OR `jobs:cancel`.** A job's owner may always stop
  their own work, queued or running — the person whose team budget a runaway run
  is burning is exactly the person who should be able to stop it, and it is the
  rule notes and documents already live by. `jobs:cancel` (admin, and owner by
  `*:*`) is for stopping SOMEBODY ELSE's. The route stays ungated in
  `routes.rkt` and the finer check is in the handler, as the repo routes do.
- **A remote worker learns it was cancelled from its HEARTBEAT** — there is no
  handler to return, so that is the only channel back. `holder-check` answers
  `'canceled`, which is a 409 naming it, and the holder/token are checked FIRST
  so a stranger can never learn that somebody's job was cancelled. Posting to
  `/complete` or `/fail` afterwards is what SETTLES the row, which is how the
  slot comes back without waiting the lease out. `queued`/`done`/`error` still
  answer `'not-running` exactly as before — a pinned smoke assertion depends on
  it. **The reference worker now reads the heartbeat's status** and stops; it
  used to discard the response entirely, so a third-party worker needs the same
  change to honour a cancel.
- **The reaper SETTLES an expired `canceling` row, never re-queues it.**
  Cancellation is final, and re-running work somebody stopped is the one outcome
  nobody asked for. `reap-orphans!` does the same for a NULL-lease one.
- **SCHED‑9's ceiling is enforced in the LEASE REFRESHER, not in the reaper** —
  the plan recorded in `decisions.md` said the reaper and was wrong: that sweep
  only ever sees an EXPIRED lease, and an overrunning job's lease is being
  refreshed every 40 seconds, so the reaper could never see it. Past the ceiling
  `lease-tick!` flips the job to `canceling` with a reason naming the knob and
  STOPS refreshing; the reaper then settles it. This is the one case where a slot
  is freed before the work provably stopped — a handler that ignored both the
  ceiling and `job-canceled?` has proven it will not stop, and holding its slot
  for ever is the worse failure.
- `TELEMACHUS_MAX_JOB_SECONDS` defaults to **1800**, `never` disables it, and an
  unparseable or non-positive value falls back to the default — **never to 0**,
  which would cancel every job the instant it started.
- **The clock is `jobs.started_epoch` (migration `0038`), stamped in
  `claim-job!`.** `started_at` is TEXT `CURRENT_TIMESTAMP`, whose format differs
  by dialect — the trap `LastModified` and the session clocks both set. It goes
  in `claim-job!` because that is the ONE claim both paths make (issue #17); a
  second claim path appearing later would leave the column NULL and the ceiling
  would quietly stop applying to those jobs, so `test/scheduler-tests.rkt`
  asserts every claim stamps it.
- **`lease-tick!` is exported because the loop sleeps 40 seconds**: the
  interesting behaviour is what one tick DECIDES, not when it happens.
- **PULL‑9: a worker reads the documents ITS OWN job names.**
  `POST /api/workers/jobs/:id/document` — three conditions and no new
  authorization code: the caller holds this attempt (`claim_token`), the object
  id appears in **that job's own payload** (checked over every string value in
  it, because the payload's shape is the kind's business), and the read happens
  **as the job's own user**, so `can?` decides. A `forbidden` and a miss collapse
  to ONE answer, as in the knowledge graph. `as: "bytes"` (base64, capped at
  `TELEMACHUS_MAX_UPLOAD` — a worker is not a way past the front door's ceiling)
  or `as: "text"`, where a scan answers `{text: null, reason: "needs-ocr"}`
  rather than erroring, since that is the branch an OCR worker exists to take.
- **`audit!` takes `#:resource-type`/`#:resource-id`, not `#:target-*`.** The
  wrong keyword compiles fine and fails at the call.
- **RBAC‑5b: custom team roles are not in v1**, and `roles:manage`'s description
  says so — it is granted and nothing reads it. A permission with nothing behind
  it reads as an unfinished feature unless the text says otherwise.

```sh
raco test test/scheduler-tests.rkt test/pull-tests.rkt   # 25 cases: the cap property, the ceiling, the fence
bash test/pull-smoke.sh                                   # section 5, 13 assertions over HTTP
bash test/server-smoke.sh                                 # the four "cancel:" assertions
```

## Issue #54's last items: abandoned uploads, staged bytes, attempts (14 Oct 2026)

Decisions S3‑7, S3‑8, PULL‑10, LOC‑6 in `docs/design/decisions.md`.

- **An abandoned multipart upload is reaped** (`reap-uploads!` in
  `domain/s3/server.rkt`), seven days by default, `TELEMACHUS_UPLOAD_REAP_HOURS`
  (`never` disables; a nonsense or non-positive value falls back to the default,
  **never to 0**, which would reap an upload as its first part landed).
  Migration `0039-upload-age` adds `created_epoch` to `repo_uploads` AND
  `repo_upload_parts` — `created_at` is TEXT `CURRENT_TIMESTAMP` and differs by
  dialect, the trap migration 0038 names.
- **The clock is the NEWEST PART, not the create time.** A 2 GB upload over a bad
  link legitimately takes hours; reaping one that is still making progress would
  be a new bug in place of the old one. An upload that never sent a part falls
  back to its create time.
- **The sweep rides the pool's reaper seam, not the S3 listener.** `set-reaper!`
  stays ONE seam: main.rkt installs a lambda that runs `reap-leases!` every tick
  and `reap-uploads!` every ten minutes. It is deliberately not in the listener,
  which is **off by default** — an instance that staged parts and then turned it
  off would otherwise hold those bytes for ever.
- **Staged parts are CHARGED against `storage.bytes` on arrival and refunded in
  `drop-upload!`.** Charging only at Complete left the quota walkable by a client
  that never completes: `TELEMACHUS_MAX_UPLOAD` caps ONE part and nothing caps
  their number. `drop-upload!` is the one place an upload stops existing, so
  Complete, Abort and the reaper all refund and no path can forget; at Complete
  the refund lands AFTER `repo-put!` charged the assembled object, so the steady
  state equals a single-shot PUT. **`repo-usage` therefore exceeds the sum of the
  listing while an upload is in flight** — true, since the bytes are there, and
  visible, which a bypass is not.
- `release-blob!` was extracted from `drop-upload!`: a blob is deleted only when
  no part row and no version row in that ORG still point at it. A part refused on
  quota releases its staged blob through the same check — never `blob-delete!`
  directly, which would drop bytes another upload or object shares.
- **The claim response carries `attempt` and `max_attempts`** so a worker can tell
  it is on its last try. `attempt` is 0 on a first claim.
- `org-quota` and `org-usage` now include **`storage.bytes`**, which `repo-put!`
  has been enforcing at the org tier all along: an operator could set a company
  storage cap, see it nowhere and conclude it had not taken.
- **The lease reaper runs on EVERY pool tick**, not the idle one. The code comment
  and `pull-executors.md` both said idle, so a reader planned against a delay that
  is not there.
- **Plugin-contributed catalogs stay unbuilt** (LOC‑6) and `localization.md` says
  so now. `locales/*.json` is the shipping artifact *because* CI gates it; a
  catalog loaded from a plugin directory would carry none of that.
- ~~A worker cannot report ready/paused.~~ **Built as PULL‑11** — see below.
  ~~A releasable claim that does not spend an attempt.~~ **Built as PULL‑12**
  (#61). ~~Writable derived objects from a worker result.~~ **Built as PULL‑13**
  (#62) — see below. Still open: #59 (purge a finished job's payload), #60
  (worker-token expiry with a rotation overlap).

```sh
raco test test/upload-reap-tests.rkt   # 5 cases: the horizon, the part clock, the refund
bash test/s3-smoke.sh                  # the live multipart path, with the real aws CLI
```

## A worker says whether it is taking work (PULL‑11, issue #58)

Built 14 Oct 2026 — the last open item from #54. Executor health was derived
from `last_seen_at` alone, so a busy box, a drained one and a crashed one were
indistinguishable.

- **`worker_state` is a SECOND column, not a better `status`** (migration
  `0040-executor-state`, plus `state_epoch`). `status` answers "is this host
  alive", which only the platform can know; `worker_state` answers "is it taking
  work", which only the worker can. A paused host is **alive and refusing**.
  Folding them is the mistake SCHED‑8 had to undo on `jobs.status`, which
  answered "is this live" and "may its result land" at once and could not
  express a cancellation until they diverged. Nothing that switches on `status`
  changed.
- **`WORKER-STATES` is CLOSED**: `ready` / `busy` / `paused`, like
  `EXTRACT-REASONS` and `REVIEW-VERDICTS`. `draining` was left out — the job rows
  already say what a paused worker is still finishing.
- **`POST /api/workers/state` is the authoritative channel**, and `state` is also
  accepted on claim and heartbeat so the normal loop needs no extra request. The
  claim alone cannot carry `paused`, which is the whole point: a drained worker
  has stopped claiming and holds no job to heartbeat, so it would just go stale.
- **A call that names no state leaves the stored one ALONE.** No backfill, no
  default: a third-party worker written against the old wire keeps reading as
  "never reported" rather than asserting `ready` on every poll.
- **An unknown state is refused on `/api/workers/state` (400) and IGNORED on a
  claim.** Asymmetric on purpose — on the state endpoint the state IS the
  request; on a claim it rides along with the call that fetches work, and failing
  that over a cosmetic field would stop the queue.
- **A stale row's reported state is WITHDRAWN, not repeated.** `worker_state` and
  `state_at` are `null` unless `status` is `active`: a worker that said `busy` an
  hour ago and vanished is stale, and a field a reader learns to distrust is
  worse than no field. Same rule as QUOTA‑3's absent hold reason.
- The reference worker reports `ready` on each claim, `busy` on each heartbeat,
  and `paused` from a **plumber flush** on the way out — best-effort, because a
  host being torn down may have no network left and failing the shutdown over a
  status update is the worse failure.

```sh
raco test test/pull-tests.rkt   # the closed vocabulary, silence, the stale withdrawal
bash test/pull-smoke.sh         # section 6, 10 assertions over HTTP
```

## Containers, Postgres in CI, and an unattended boot (DEPLOY, issue #89)

Built 19 Oct 2026. Decision block **DEPLOY‑1…12** in `docs/design/decisions.md`;
operator docs are `docs/ops/container.md` and `docs/ops/configuration.md`.

```sh
nix build .#container && docker load < result   # LINUX ONLY (see below)
bash scripts/container-smoke.sh                 # 24 assertions, starts its own Postgres
bash scripts/check-config-reference.sh          # the config-doc drift gate
raco test test/migration-tests.rkt test/startup-tests.rkt
docker compose up                               # app + Postgres + a model stub
```

### The image

- **Built from the same derivation `nix build` produces** (`nix/container.nix`,
  `dockerTools.buildLayeredImage`) — no Dockerfile, so there is no second
  dependency pin to drift from the flake. **`packages.container` is Linux-only**
  (`optionalAttrs isLinux`): an image's contents are Linux store paths, so a Mac
  has to build it on a Linux host or a remote builder. `nix eval` on darwin
  reporting "does not provide attribute" is that, working.
- **`git add` a new Nix file before building.** Nix only sees git-tracked files —
  `nix/container.nix` evaluated to "does not provide attribute" until it was
  added, with a message that points at the wrong thing.
- **There is NO SHELL in the image**, and that is load-bearing: `docker exec … sh`
  does not work, debugging is `docker logs` plus the API, and the `HEALTHCHECK`
  must be the **exec** form (`["CMD" "curl" …]`). A `CMD-SHELL` healthcheck
  reports unhealthy for ever. The exec form hardcodes port 8835, so overriding
  `PORT` means overriding the healthcheck.
- **`/tmp` is deliberately not in the image.** Under `--read-only` the container
  cannot create one, so the caller passes `--tmpfs /tmp` (compose, the k8s
  manifests and the smoke all do). Omitting it fails at the first upload, not at
  boot.
- Non-root uid/gid **65532** (the distroless convention, so an existing
  `runAsUser` matches), `/data` the one declared VOLUME, `HOME=/data` because
  Racket wants a writable home and the package wrapper derives the data dir from
  it, and an SBOM at `/share/telemachus/sbom.json` (the Nix runtime closure,
  verifiable with `nix path-info -r`).
- **1.74 GB, and Racket is 750 MB of it.** glibc-locales is 233 MB and the
  OPTIONAL PDF toolchain (pandoc/tectonic/biber/librsvg) about 400 MB. A slim
  variant is possible — `doc_render`'s toolchain is `find-executable-path`'d at
  CALL time (DWF‑6) — and was not built: a second image to maintain for a 23%
  saving against a floor that dominates anyway.

### Graceful shutdown

- **The drain hangs off a PLUMBER FLUSH, not a break handler.** Measured:
  `serve/servlet #:command-line? #t` installs its own break handler and exits
  cleanly, so `with-handlers ([exn:break? …])` wrapped around `serve` **never
  fires** — a container stopped with `docker stop` exited 0 having drained
  nothing, which is indistinguishable from a clean shutdown. The flush runs on
  SIGTERM, on SIGINT and on a normal exit (also measured: Racket delivers both
  signals as `exn:break` and flushes run for both). Same seam
  `cli/telemachus-worker.rkt` uses to hand its job back. The break handler is
  kept too, and a `drained?` latch makes the pair idempotent.
- **The pool keeps a REGISTER of its own in-flight attempts**
  (`scheduler-inflight-count`, maintained in a `dynamic-wind` around
  `run-claimed!`). The jobs table cannot answer "which are mine": an in-process
  claim leaves `executor_id` NULL, so `status='running' AND executor_id IS NULL`
  is **every replica's** pool work, and requeueing by that query would steal a
  sibling's jobs the moment one replica restarted.
- **A drained job costs nothing** — neither `attempt` nor `releases` moves.
  Without the drain a restart left jobs `running` until the reaper requeued them
  with attempt+1, so three ordinary deploys could push a healthy job to `error`.
  `releases` is deliberately unused as well: its ceiling FAILS the job, so a
  crashlooping deployment would mark every job it touched broken. Nothing bounds
  a restart loop, on purpose.
- **The drained attempt cannot land its result** — `drain-scheduler!` clears the
  `claim_token` and `finish!` names it (issue #24), so the handler that finishes
  afterwards is fenced out. `test/scheduler-tests.rkt` asserts exactly that.
- `TELEMACHUS_DRAIN_SECONDS` defaults to **25**, to fit INSIDE the orchestrator's
  patience (k8s 30s, systemd 90s, `docker stop` only 10 — pass `-t`). A drain
  SIGKILLed halfway is worse than none. `0`/`never` hands work back at once; a
  typo falls back to the default.

### Startup checks (`server/startup.rkt`)

Its own module so the rules are unit-testable without a live server — peer.rkt's
move, for the same reason: a harness on localhost with a writable data dir
satisfies every check by construction and can only exercise the allowed side.

- **Always fatal**: the blob store is not writable (probed by actually writing
  AND reading back — a missing directory, a root-owned one and a read-only mount
  cannot be told apart by a permission bit, and all three surface as a 500 on the
  first document save); migrations still pending; **the database was migrated by
  a NEWER build** (old code against a new schema writes rows the new code
  misreads — the remedy is to deploy that version, so continuing corrupts data).
- **Warnings by default, refusals under `TELEMACHUS_STRICT_STARTUP=1`**: no
  secret key (plaintext at rest is the supported trusted-database position), and
  a non-loopback bind with no TLS (the demo box does exactly this across a
  tailnet). Making these fatal unconditionally would break every existing
  deployment.
- **`loopback-bind?` DELEGATES to peer.rkt's `loopback-address?`** rather than
  re-implementing it — the compiler caught the duplicate on the first build. A
  bind address only adds spellings a connected peer never arrives as
  (`localhost`, `[::1]`), which it normalizes first. Two predicates would drift
  and the TLS warning would start disagreeing with the identity-header gate about
  what is private.

### CI

- **A matrix over `db: [sqlite, postgres]`, `fail-fast: false`.** "It passed on
  SQLite" is the state that let two Postgres bugs reach the HTTP smokes.
- **Each HTTP smoke needs its OWN database on the Postgres leg.** `bootstrap!` is
  first-run-only, so three smokes sharing one database leave the second and third
  holding an **empty token**, failing in ways that say nothing about Postgres.
- The docs/localization/config gates run on the **sqlite leg only** — they read
  the source, not the database.
- **The e2e job stays single-dialect** and says why: it drives a browser and
  asserts on rendering and CSP, so doubling the slowest job buys a second opinion
  on the part of the stack with no SQL in it.
- **`test/migration-tests.rkt` upgrades from EVERY prefix** of the migration
  list, on both dialects — stronger than "from the previous release" and needing
  no old checkout, because the release tags' ids are a prefix of today's. 1.2s on
  SQLite, 4.5s on Postgres for all 44 points, so it does not sample: sampling is
  how the one migration that assumes a later table stays hidden. A from-empty run
  (which `nix build` already does) cannot catch that class at all.

### The configuration reference

`docs/ops/configuration.md` is **hand-written with a CI gate**
(`scripts/check-config-reference.sh`): 62 variables are read through plain
`getenv`/`env*` calls across the tree, so a registry would be a large refactor
for a page read once. The gate fails in BOTH directions — read-but-undocumented,
and documented-but-read-nowhere. It caught a stale row on its first run.
`TELEMACHUS_MODEL_<ROLE>` is built at runtime, so the script carries a
`RUNTIME_PREFIXES` allowlist with the reason. **No associative arrays**: macOS
ships bash 3.2, where `declare -A` becomes an indexed array and the subscript is
evaluated as arithmetic, failing under `set -u` on the key itself.

### MinIO is deliberately absent from compose

Issue #89 asks for it. Telemachus **serves** an S3 API but cannot yet **store**
blobs in a bucket — that is issue **#82**, unbuilt — so a MinIO container would
be a service nothing talks to, which reads as a broken example rather than a
staged one. The k8s manifests are `replicas: 1` for the same reason, and it is a
STORAGE limit, not a concurrency one: the scheduler is safe in several processes,
which is what the in-flight register exists for.

## Encrypting derived document content (ENC, issue #83 slice 1)

Built 20 Oct 2026. `TELEMACHUS_ENCRYPT_CONTENT`; seams in
`domain/repo/extract.rkt`; decisions **ENC‑1…7**.

```sh
export TELEMACHUS_SECRET_KEY=$(openssl rand -hex 32)
export TELEMACHUS_ENCRYPT_CONTENT=1
raco test test/content-encryption-tests.rkt   # 4 cases, read off the RAW row
```

- **It is a SEPARATE switch from `TELEMACHUS_SECRET_KEY`, and must stay one.**
  Sealing `repo_text.content` makes content search impossible — the match is a
  SQL `LIKE` over that column — so riding on the key, which every instance
  should set, would silently remove a capability from everyone.
- **Search DROPS the content clause and reports `content_search: false`.** A
  `LIKE` left over ciphertext returns no content matches, so a search quietly
  stops looking inside documents and the answer reads as "no such document". The
  flag is what distinguishes "not found" from "not looked for".
- **The switch with NO key refuses to start**, and it is the one startup problem
  that is fatal regardless of `TELEMACHUS_STRICT_STARTUP`: `secret-wrap` passes
  the value through without a key by design (#19), so that combination writes the
  plaintext it was turned on to prevent AND costs search, while reporting healthy.
- **Unsealing is never conditional on the switch.** A row sealed while it was on
  must open after it is off, or flipping it back loses every document's text.
- **`spans` is sealed too** — r1 names OCR page structures, and a bbox list with
  page numbers is a map of where the words are.
- **`rewrap` touches the content columns ONLY when the switch is on**, unlike the
  three credentials. Sealing content costs search, so an unconditional rotation
  would remove it from an instance that had deliberately kept it; `status` lists
  them separately because the switch being off is the documented default, not a
  leak.
- **A failed unseal must not quote the plaintext, the ciphertext OR the key.**
  The real failure is a rotated key or a restored dump, and a message echoing
  what it could not read puts in the log exactly what the column was sealed to
  keep out of the database.
- **Acceptance criterion 1 is NOT yet met in full.** `jobs.payload`/`result` hold
  the same text until #59's purge removes them, so a dump can still carry fixture
  text. That is slice 2 — roughly eight SQL seams including the pull wire, where
  the worker must receive plaintext.
- **`(require "/abs/path.rkt")` is a bad module path**; an absolute path needs
  `(require (file "/abs/path.rkt"))`.

## Deleting a document and everything it produced (DEL, issue #86 slice 1)

Built 20 Oct 2026. `domain/repo/repo.rkt`; `?cascade=`/`?detach=`/`?dry_run=` on
`DELETE /api/repo-obj/:id`, `DELETE /api/repo?prefix=`, and
`GET /api/repo-obj/:id/traces`. Decisions **DEL‑1…8**.

```sh
raco test test/repo-tests.rkt test/upload-reap-tests.rkt
bash test/server-smoke.sh    # the "cascade and prefix delete" block, 13 assertions
```

- **ONE blob-release rule now, and there were two.** `blob-referenced?` /
  `release-blob-if-unreferenced!` in repo.rkt is the only one; the S3 listener's
  `release-blob!` delegates. The old pair were each wrong differently:
  `repo-delete!` **never consulted `repo_upload_parts`**, so deleting an object
  whose digest a live multipart upload had also staged destroyed the bytes that
  upload needed (reachable on the normal dedup path — re-uploading an existing
  document is exactly when a part and a version share a digest); and
  `release-blob!` counted parts GLOBALLY, so one tenant's upload pinned another
  tenant's copy for ever. Reaching the listener's table from the repository is
  deliberate: a multipart upload BECOMES a repository object.
- **`detach` removes the derivation rows, it does not merely spare the child.** A
  derived document still recording a source that is now a tombstone is provenance
  that lies, and "Processed by" renders it.
- **A cascade is all-or-nothing on permission**, refused by name. A
  half-cascaded tree cannot be told from a finished one, and rerunning — the
  obvious recovery — is what partial failure makes unsafe.
- **`DELETE /api/repo?prefix=` is a DRY RUN unless `confirm=1`**, and an empty
  prefix is refused rather than read as "every object in the team". It deletes
  through `repo-delete-tree!` per object, so the permission check, the
  blob-release rule, the cascade and the storage refund are not reimplemented.
- **The closure walk is cycle-safe and deepest-first.** DWF‑3 stops a trigger
  firing on its own output, but a hand-run workflow can derive A from B and later
  B from A and nothing in the table forbids it. Deepest-first is correctness:
  releasing a parent's bytes before its children are gone lets a child's
  surviving version row keep them alive.
- **`traces` reports `audit` and that is NOT a trace to drive to zero** — an
  erasure deliberately keeps the audit log (TEN‑2g). The field exists so an
  operator can see that it is the one thing left.
- **`member` returns the tail from the element onward**, so in a deepest-first
  list a DEEPER element has a LONGER tail. An ordering assertion written the
  other way round fails against a correct ordering — it did here.
- **The grants table is `resource_grants`, not `repo_grants`**, and it is shared
  with notes, so a count needs `resource_type = 'repo'` as `repo-grants` does.
- **Building SQL conditionally while passing a fixed argument list is how a
  clause and its parameter come apart.** `blob-referenced?`'s `#:except-object`
  was written that way first and would have failed with an arity error on exactly
  the cascade path the argument exists for. Two statements, not one with an
  interpolated clause.
- **When adding a route, check the paren balance before compiling.** Three route
  entries in this slice and the last were written as `(R … #:doc "…"` with the
  closing paren missing; `racket-parens.p` names the line in ~7 ms, and
  `raco`'s own "indentation suggests a missing `)` before line N" is good here too.

## Purging a job's content (PURGE, issue #59)

Built 20 Oct 2026. `DELETE /api/jobs/:id/content`; `purge-job-content!` in
`domain/sched/scheduler.rkt`; migration `0044-job-purge`; decisions
**PURGE‑1…8** in `docs/design/decisions.md`.

```sh
raco test test/scheduler-tests.rkt   # the two purge cases
bash test/server-smoke.sh            # the "purge:" block, 10 assertions
```

- **It is the LEVER, not the policy.** The horizon and what evaluates it are
  #86's retention rules; a scheduled sweep calls `purge-job-content!` per row and
  needs nothing new. #59 was open as a *decision* and the answer came from a
  caller: an application honouring a deletion request can clear its own rows, and
  the document text stays in `jobs.payload` for ever.
- **`error` is cleared too**, not just payload and result: a handler's message can
  quote the input it choked on, so leaving it leaves the copy most likely to be
  read by a human.
- **The row is NOT deleted.** Status, timings, attempts, executor and audit
  references survive — the audit log is the record (QUOTA‑3, FLEET‑1), the job row
  need not be. A DELETE would also take FLEET‑1's lease-trail anchor and make a
  team's own history lie about how much work it ran.
- **`purged_at` exists because `'{}'` is ambiguous.** `payload` is `NOT NULL
  DEFAULT '{}'`, so a purge sets it to exactly what a job with no payload looks
  like. Without the marker nothing can show that a deletion request was honoured,
  a sweep cannot skip what it has done, and two concurrent purges cannot settle to
  one audit entry. The guard is `purged_at IS NULL … RETURNING id`.
- **Only `done`/`error`/`canceled`.** A queued or running job's payload is the
  input a handler is about to read; clearing it mid-flight fails the job as if it
  were corrupt. `canceled` IS purgeable — the work stopped, so its input can go.
- **Owner-ok OR `jobs:purge`**, cancel's shape with its own permission: stopping a
  colleague's work loses nothing, destroying what it recorded does. Admin holds
  it; a member needs neither for their own.
- **The audit entry carries no content.** The point of the call is that the
  content stops existing; a row quoting it would be the copy left behind.
- **`GET /api/jobs/:id` reports `purged_at` and has never reported `payload`.**
  So "the text is gone" is a ROW-level property and is asserted in
  `test/scheduler-tests.rkt` over `SELECT *`, not over the API — an HTTP
  assertion for it passes because the field was never there, which is worse than
  no assertion. The smoke pins the surface instead: if `payload` ever joins that
  response, it fails.
- **`test/server-smoke.sh` had no `refute`** until this slice, so a `refute`
  written in it ran as an unknown command — bash said "command not found" on
  stderr, nothing set `fail`, and the suite reported PASS with the assertion
  silently absent. It is defined now; check a helper exists before using it.

## Document bytes in a bucket (BLOB, issue #82)

Built 20 Oct 2026. `domain/s3/client.rkt` + `plugins/s3blobs/` +
`cli/telemachus-blobs.rkt`; decision block **BLOB‑1…9** in
`docs/design/decisions.md`. IAM policy and migration notes in
`docs/ops/container.md`.

```sh
export TELEMACHUS_BLOB_STORE=s3        # with the endpoint/bucket/keys set
raco test test/s3-client-tests.rkt     # 8 cases, no network
bash test/s3-blobstore-smoke.sh        # 23 assertions over a real socket
racket cli/telemachus-blobs.rkt plan   # then `migrate --verify`, then `verify`
```

- **The signer is NOT new code.** `domain/s3/sigv4.rkt` was built to VERIFY what
  clients send us, and every primitive a signer needs was already exported and
  already pinned to AWS's own vectors. The client composes them, so ONE
  implementation faces both directions — and `test/s3-client-tests.rkt` hands
  what it signs to our own verifier, with a tampered-request control so the test
  cannot pass vacuously. Never write a second SigV4 here.
- **The payload hash is FREE, and that is why a PUT can stream.** A signed S3 PUT
  must carry `x-amz-content-sha256`; normally you buffer the object to compute it
  or give up signing the payload. In a content-addressed store the digest IS that
  hash, so the body streams once, unbuffered, fully signed. It also means a blob
  whose bytes disagree with its digest is refused by the far end
  (`XAmzContentSHA256Mismatch`) rather than stored under a name that lies.
- **A raw socket, not `net/http-client`.** Its `#:data` takes bytes (buffer
  everything) or a procedure, which makes the request chunked — and S3 rejects
  chunked unless it is `aws-chunked` with per-chunk signatures, which sigv4.rkt
  deliberately does not implement.
- **Encryption is checked on the RESPONSE.** What we asked for and what the
  bucket did are different claims; a policy that strips the header is invisible in
  the request. The object has already landed when the check fires and is **left in
  place deliberately** — deleting it would destroy the evidence of what the bucket
  actually did.
- **`s3-host-header` is the ONE place the Host is computed.** It is a SIGNED
  header, so two copies drifting would fail every request with
  `SignatureDoesNotMatch` and nothing in the message would name which copy was
  wrong. `s3-object-url` calls it rather than recomputing.
- **The boot health check is `startup.rkt`'s existing probe.** It writes a blob,
  reads it back and deletes it, fatally — which through this store checks
  reachability, credentials, bucket existence, permissions and the encryption
  posture at once. Do not add a second health mechanism.
- **The migration moves NO database rows**, because `repo_versions` stores the
  digest and the store is addressed by it. That is what makes it resumable and
  safe on a live instance. It **re-hashes every blob**: rs3 takes the digest from
  the PATH, so a rotted file looks correct until something hashes it, and a
  corrupt blob is reported and left alone rather than copied under a name that
  lies about it.
- **`TELEMACHUS_S3_PORT`/`_S3_REGION` are the listener's; the blob store's names
  all carry BLOB.** One instance can legitimately serve an S3 API and write to a
  bucket at the same time.
- **Do not write a bare `TELEMACHUS_S3_BLOB` prefix in a comment.**
  `scripts/check-config-reference.sh` greps `TELEMACHUS_` tokens out of the
  source, so a prefix in prose reads to it as an undocumented variable — it
  reported exactly that, twice, while that note was being written.
- **MinIO's images are no longer freely pullable** (docker.io and quay.io both
  answer `unauthorized`; `:latest` unpublished, checked 20 Oct 2026), and
  `localstack/localstack:latest` now needs a licence. So the acceptance criterion
  as written in #82 cannot be met: CI drives the suite against THIS server's own
  S3 API instead, and section 5 uses a real bucket only when `S3_TEST_ENDPOINT`
  is set (vendor-neutral on purpose — these knobs were `MINIO_*` at first, which
  named the one target a reader cannot obtain). **The SSE round trip is unproven against a real bucket**; what is covered
  is the refusal when a bucket does not report encryption.
- Multipart is **not** built: a single signed PUT handles anything up to S3's
  documented 5 GiB ceiling, and multipart would need each part buffered to hash
  it, so the free-hash property does not extend to it. The case that reaches that
  ceiling is an inbound **S3-listener multipart upload**, which assembles and
  calls `repo-put!` — not the 32 MiB front door. A write above it fails rather
  than truncating, because Content-Length and the payload hash both go with the
  request; the specific `EntityTooLarge` code is AWS's documentation, not
  something measured here.

## Reading scans and photographs (OCR, issue #92)

Built 19 Oct 2026. `plugins/ocr/` + `tesseract`; decision block **OCR‑1…10** in
`docs/design/decisions.md`. The first thing that fills LAY‑5's spans.

```sh
export TELEMACHUS_OCR=1          # OFF by default — see below
raco test test/ocr-tests.rkt     # 8 cases, generated fixtures, no server
bash test/ocr-smoke.sh           # 19 assertions: a photo and a scan, end to end
```

- **It is OPT-IN, and that is not timidity.** Registering `application/pdf`
  REPLACES the platform's PDF reader for the whole instance (LAY‑7's purpose),
  so a reader that took over because a binary happened to be on PATH is the
  mistake the blob-store check exists to refuse. With the switch unset nothing
  registers and a scan still reports `'needs-ocr`: the full unit suite is
  **1135 tests, unchanged**.
- **Enabled with no `tesseract` on PATH, `init!` RAISES** — reported by the
  plugin-failure surface, escalated to a refusal to start by
  `TELEMACHUS_PLUGINS_STRICT=1`. Answering `'missing-tool` on every scan while
  the boot log says nothing is how a deployment concludes the feature is broken.
- **The text layer is tried FIRST; only a PDF with none is rasterised.** A
  born-digital PDF carries exact text where OCR guesses. The order is
  load-bearing, and the test pins it from the other side: a text-layer read must
  produce **no spans**, because spans would prove the page had been rasterised.
- **The text is built FROM the TSV, in one engine run.** Never a `txt` run for
  the text and a `tsv` run for the regions: the two can segment a page
  differently, and LAY‑5's offsets index into "the text this same call returned",
  so mixing them is a provenance record pointing at the wrong characters. The
  test asserts every span's `substring` is its own word.
- **The image goes in on STDIN**, as the built-in pipes to `pdftotext`. A temp
  file is not an option: handed a path, leptonica picks its decoder from the
  FILENAME, and a suffix-less temp file exits 1 with the PNG's own magic bytes
  appearing where a filename belongs — having failed to decode it, tesseract
  falls back to reading the file as a LIST OF IMAGE PATHS. Adding `.png` fixed
  that and the open still failed for a file Racket had written into the nix-shell
  `TMPDIR`, which `file` called a valid PNG and a shell read fine.
- **Orientation is `--psm 1`, not EXIF** — and that is better, not easier:
  leptonica does not apply an EXIF rotation, and a page scanned sideways has no
  EXIF to read. Content-based OSD covers both.
- **An image with no text is an honest EMPTY, never `'needs-ocr`** — that reason
  means "a reader that can do OCR would get further", and it just has. Returning
  it would offer the document to the indexer forever.
- `pdftoppm` (poppler-utils, already pinned) renders a scan's pages, so there is
  no `ocrmypdf` and no new Python application. The nixpkgs tesseract bundles
  **129 language files**, so `TELEMACHUS_OCR_LANGUAGES=eng+spa` needs no
  override; `tesseract --list-langs` is the authority.
- **Writing a test that polls `/api/runs/:id`: match the RUN's status, not a
  substring.** `case "$RUN" in *'"status":"done"'*)` breaks as soon as any
  status in the document is done, and the run JSON embeds every STEP with its
  own — so the loop exits while `extract#0` is mid-OCR and the next assertion
  reads an index that has not been written. It passed for the photograph, whose
  OCR takes under a second, and failed for the rasterised PDF, which takes
  several: a timing-shaped failure that looked like a broken extractor.
  `ocr-smoke.sh`'s `wait_run` reads the status as JSON. (`grep -oP
  '"status":"\K[^"]+'`, which the other smokes use, is right only because the
  top-level key sorts before `"steps"` — and `-P` is GNU-only.)
- **Two fixtures in one suite need DIFFERENT words.** The photo and the scan
  started out carrying identical text, and a search then could not say which
  document had been read — the scan's assertion failed while the scan had been
  OCR'd perfectly.

## A worker stops taking work while its model is down (PULL‑14, issue #93)

Built 18 Oct 2026. Both halves are **worker-side** — `cli/telemachus-worker.rkt`
only: no route, no migration, no wire field, so a third-party worker needs no
change and an unset `TELEMACHUS_WORKER_READY_URL` means none of it does anything.

- **PULL‑12 defined `busy` and nothing ever sent it.** The reference worker
  released only on shutdown, so a model outage went to `/fail` — and
  `worker-fail!` is **TERMINAL** (`status='error'`, no requeue). The live
  behaviour was therefore worse than issue #93 describes: one outage did not
  cost the job one of three attempts, it killed the job on its first try. Only a
  LEASE EXPIRY spends an attempt.
- **A model call that cannot be served RELEASES with reason `busy`.** Cannot
  connect, timed out, or 502/503/504. A **4xx, a 500, or a reply that cannot be
  read still FAILS** the job: those are the job's problem, and sending a
  genuinely bad job round the fleet only reaches "no executor would run it" ten
  workers later. `llm.rkt` already separates `malformed` from
  `network`/`timeout`, which is the seam this reads — never widen it to "any
  model error is the host's".
- **A timeout counts as the host's**, though #93 did not list it: a card another
  process is thrashing answers by timing out, which is the commonest shape of
  this outage.
- **`exn:fail:unavailable` is its own struct and its clause comes BEFORE
  `exn:fail?`** in `run-job`'s `with-handlers` — the first matching clause wins,
  so reordering them silently restores the old failing behaviour.
- **A release alone cannot cover a longer outage**, which is why the readiness
  gate exists: the cool-off is 30 s for the releasing worker and `MAX-RELEASES`
  (10) fails a job, so one host busy for five minutes failed every queued job it
  touched. `TELEMACHUS_WORKER_READY_URL` is GETted **before each claim**, 2xx =
  ready. What readiness means stays the operator's (VRAM, memory, load, a
  schedule), so the platform needs no knowledge of GPUs.
- **`paused` is reported ONCE per outage, not once per check.** A row every
  fifteen seconds tells an operator nothing the first one did not, and makes the
  executor's own history useless for finding when the outage began — PULL‑11e's
  rule. Coming back needs no post: the claim already carries `ready`.
- **`TELEMACHUS_WORKER_READY_INTERVAL` defaults to 15 s**, and an unparseable or
  non-positive value falls back to the default, **never to 0** — the platform's
  rule for every interval knob, and here a 0 would be a hot loop against the
  operator's own endpoint.
- **After a `busy` release the worker waits** (`BUSY-BACKOFF`, 30 s). The
  server's cool-off protects THIS job from THIS executor and says nothing about
  the next one, so without it a worker whose model is down claims the whole queue
  and releases all of it.
- **The readiness GET opens and closes its own connection**, not `http-sendrecv`
  — the measured descriptor leak documented above `http-post-json` in
  `domain/agent/llm.rkt`. This runs before every claim, so it is the call that
  would hit the 1024-descriptor limit fastest.
- `test/mock-llm.rkt` takes **`MOCK_STATUS`** so a caller can see what a worker
  does against a model endpoint that is refusing.

```sh
bash test/pull-smoke.sh   # section 8d, 14 assertions: the two releases, the two failures, the gate
```

## A worker writes back a derived document (PULL‑13, issue #62)

Built 15 Oct 2026 — the write counterpart of PULL‑9, and LAY‑6's asymmetry closed
for remote workers. `POST /api/workers/jobs/:id/derive`; `worker-derive!` in
`domain/exec/pull.rkt`; decision block PULL‑13 in `docs/design/decisions.md`.

- **There is no standalone put.** `source` must appear in the job's own payload —
  the derivation IS the warrant for the write. A worker token is not a key to the
  team's repository, for a write exactly as PULL‑9 said for the read.
- **The write happens as the JOB'S user**: `can?` (files:write), the storage
  quotas and the org gate decide, no new authorization code. A refusal from the
  write itself (an invalid key, a quota) comes back VERBATIM as the 403 — the
  target is the worker's own new object, not somebody's secret. A forbidden
  SOURCE and a missing one stay one answer (`no-such-document`), as in the read.
- **`derive!`'s rule to the letter**: `repo-put!` takes the source's visibility,
  THEN `repo-inherit!` copies the grants and writes the derivation row — never
  reorder — and `#:derived?` is set so an opted-in trigger cannot fire on a
  worker's own output.
- Bytes are base64 on the existing wire, capped at `TELEMACHUS_MAX_UPLOAD` — a
  worker is not a way past the front door's ceiling. Too big for that is what the
  S3 listener is for.
- Audited `job.document.derived` (actor the executor, team the job's): the
  derivation row cannot say a MACHINE wrote the document, or which one.
- The fence is the attempt (lease + `claim_token`), and a `canceling` job writes
  nothing — SCHED‑8's rule for results, applied to outputs.
- This is JUDGE‑8's missing half: a `judge.typed` worker can write its verdict
  back as a document beside the material it judged.

```sh
raco test test/pull-tests.rkt   # the fence, the anchor, inheritance, can?
bash test/pull-smoke.sh         # section 8b, 7 assertions over HTTP
```

## The worker fleet, seen (FLEET‑2, issue #70)

Built 15 Oct 2026. `GET /api/admin/workers`, `instance:manage` —
`domain/exec/fleet.rkt`. What each executor IS stays on `GET /api/executors`;
this is what the fleet is DOING.

- **Its own instance-wide route, not a wider `GET /api/jobs`.** That one is
  team-scoped by contract (`list-jobs` takes a team, `job-waiting` computes
  *that* team's hold reason); widening it to cross teams would make a team-tier
  route answer past the org gate, which is step 0 of `can?`.
- **`unclaimable` is the point of the whole read**: queued remote jobs no live
  executor's capabilities satisfy. A stalled fleet and a busy one look identical
  from a depth count. It asks **`executor-can-run?`**, extracted from
  `worker-claim!` — one policy, two askers. Never re-derive the matching rule
  here; the drift is invisible until it misleads.
- **A job a QUOTA holds is NOT unclaimable.** "Nothing can run it" and "nothing
  may run it yet" have different remedies, and conflating them sends an operator
  to buy hardware for a budget. QUOTA‑3's `waiting` already explains that case.
- **A claim now RECORDS what the worker declared** (`observe-capabilities!`),
  merged into `executors.capabilities` beside LAY‑9's `tools`/`json_schema`.
  `capabilities` was written once at create and was usually `{}` while the worker
  told us its kinds and models on every poll — an aspirational record cannot
  answer the question above. An EMPTY declaration leaves the stored value alone
  (a worker naming no models means "any"); the write is skipped when nothing
  changed, because this is the hot path. **Behaviour change** on
  `GET /api/executors`.
- **Two sources, and they must stay two.** Outcomes come from the jobs row —
  `executor_id` survives a terminal write, so the row names the executor that
  *finished* the job and can never name an earlier holder, because the requeue
  nulls it. Lease expiries come from FLEET‑1's trail, which names every holder.
  Reading outcomes from the trail too would double-count the last attempt.
  `started_epoch` is the clock; `finished_at` is TEXT and differs by dialect.
- **Migration `0041-job-queued-age`** adds `jobs.created_epoch`, stamped in
  `enqueue-job!`, no backfill. `created_at` is TEXT `CURRENT_TIMESTAMP` — the
  trap 0038/0039/0040 each name — so an age from it is wrong on one dialect. A
  pre-0041 job reports `oldest_queued_seconds: null`, never a guess.
- Counts over the window come from `meta LIKE '%"executor_id":"<id>"%'`, the
  trick `object-processing` uses: `jsexpr->string` writes no spaces, and the two
  dialects do not spell a JSON operator the same way.
- `?hours=` (default 24, clamped to 720, nonsense falls back) — a lifetime total
  would call a box unhealthy for ever over last month's failures. `unclaimable`
  scans at most 200 jobs and reports `scanned` and `truncated` beside the count.
- **HTTP only, deliberately.** The console's Workers and Queue cards and the
  operator drain are FLEET‑3/‑4.

```sh
raco test test/fleet-tests.rkt   # the entries, the two sources, the queue, unclaimable, the org gate
bash test/pull-smoke.sh          # section 7, 11 assertions over HTTP
```

## Draining a host, and the Workers card (FLEET‑3, issue #70)

Built 15 Oct 2026. `POST /api/executors/:id/drain` and `/resume`,
`instance:manage`, plus the console's **Workers** card, which replaced Compute.

- **`executors.admin_state` is a THIRD column** (migration `0042`), beside the
  derived `status` and the reported `worker_state`. Three questions, three
  answers, and all three can be true at once: alive / taking work / *should* it
  be taking work. **A drained box reporting `ready` is not a contradiction** —
  it is a healthy machine held back, which is what a drain creates. NULL reads
  as `active`; nothing is backfilled.
- **Intent is NOT withdrawn when the row goes stale**, unlike `worker_state`
  (PULL‑11e). A reported state is a claim the worker can no longer stand behind;
  intent is a standing instruction that does not decay. Withdrawing it would let
  a host return to rotation by going offline and coming back.
- **A drained worker keeps polling and is answered 204.** It therefore keeps
  being *seen* — the operator watches a live box taking nothing instead of one
  gone stale, which is the gap #58 opened. 204 is a meaning the wire already
  has, so a third-party worker is drainable with no change.
- **Draining leaves a held job running.** It says "start nothing new"; stopping
  work in flight is cancel (SCHED‑8). Releasing a claim without spending an
  attempt is #61, and this is the reason that issue matters.
- **`retired` is not an `admin_state`.** A retire revokes the token and is
  irreversible; the two differ in kind, and a shared vocabulary would invite a
  console to offer them as peers.
- **The drained check lives in BOTH `executor-can-run?` and `worker-claim!`'s
  short-circuit — do not "simplify" either away.** The predicate is
  authoritative, because it is what keeps FLEET‑2's `unclaimable` honest; the
  short-circuit is the same answer without scanning the queue, which keeps a
  drained fleet's polling free. Both carry a comment saying so.
- **The card replaced Compute rather than joining it.** The old table showed
  name, model and endpoint — a pull worker has no endpoint, so every worker drew
  an empty cell, and it displayed none of `status`, `worker_state` or
  `last_seen_at`, which the API already answered.
- **The worker token is parked in `S.wkToken` and shown until dismissed**, with
  the `telemachus-worker` command line beside it. A toast scrolls away and there
  is no second chance; the copy says so rather than implying a recovery that
  does not exist. The retire confirmation names draining as the reversible
  alternative, because the destructive button was the only one for so long.
- 42 new `ui.*` strings, hand-translated into `ja` in the same commit.
- **A config-file push executor must still appear on the card.** The fleet read
  lists DB rows only — what a drain or a retire can act on — so building the
  table from it alone made every `executors.json` entry vanish from the console.
  They are merged back in from `GET /api/executors` (`source: "config"`) and
  shown with no actions, since the file owns them. **The screenshot tour is what
  caught this**: `run-tour.mjs` asserts `gpu-sim` is visible, and it waited on
  the `Compute` heading, so replacing that card broke the tour in CI while
  `validate.sh` passed locally. A console change that renames or removes a card
  means grepping `test/e2e/*.mjs` and updating the shot's caption, the manifest,
  `captions.ja.json`'s hash and the README regions (`README_ONLY=1`).

```sh
raco test test/fleet-tests.rkt   # reversibility, liveness, the closed vocabulary, both audits
bash test/pull-smoke.sh          # section 8, 10 assertions over HTTP
bash test/e2e/validate.sh        # the card renders under the console CSP
```

## The queue, job by job (FLEET‑4, issue #70)

Built 15 Oct 2026. `GET /api/admin/queue`, `instance:manage`, plus the console's
**Queue** card (`#qcard`, beside `#wkcard`). The last of #70.

- **`waiting` and `runnable` are two answers and must never merge.** `waiting`
  is the platform holding admissible work behind a cap or budget — it clears on
  its own, and QUOTA‑3 says so on the job too. `runnable: false` means no live
  worker can run it at all, and only an operator clears that. One field would
  make a quota look like missing hardware.
- `waiting` comes from **`team-hold`, memoized per team** — the seam
  `GET /api/jobs` asks. It is a property of the team, so a cross-team listing
  asks once per team, not once per row. Absent when nothing holds the job.
- **`runnable` appears only on a queued REMOTE row.** No worker claims an
  in-process kind, and a running row has already been answered.
- **No `payload`, no `result`.** This read crosses every team and org on the
  instance; a queue is managed by kind, age, team and holder. The team-scoped
  `GET /api/jobs/:id` still carries them. An operator permission is not a reason
  to widen a payload.
- **`order` is reported, not assumed.** `status=queued` gives the claim's own
  `priority DESC, created ASC`, so row 1 really is next; anything else is
  newest-first. A list that looked like drain order while mixing in finished
  jobs would mislead about what runs next. `COALESCE(created_epoch, 0)` — a
  pre‑0041 row has none, and the dialects sort NULLs opposite ways under ASC.
- **Read-only.** `cancel-job!` is team-scoped and its rule is team-tier
  (SCHED‑8); an operator cancelling another company's job is its own decision.
- The kind dropdown is built from the fleet read, not from the current page — a
  filter assembled from the page would vanish the moment it was used.
- **Give a console card an `id` before asserting on it.** A `.card` locator with
  `hasText: 'Queue'` matched the WORKERS card, whose summary reads "queued for
  workers". Every other asserted card on this tab is found by id.
- **A test that sets process-global state restores it in a `dynamic-wind`.**
  `set-cap-for!` was overridden to prove the hold reason with the restore after
  the assertion; a failing check raises, so the restore never ran and a cap of 0
  leaked into every later test in the file, failing an unrelated one.

```sh
raco test test/fleet-tests.rkt   # drain order, the two answers, the filters, paging
bash test/pull-smoke.sh          # section 7b, 7 assertions over HTTP
```

## A releasable claim (PULL‑12, issue #61)

Built 15 Oct 2026. `POST /api/workers/jobs/:id/release` — the blameless
hand-back, and the last of #54's four deferred questions.

- **`attempt` is UNTOUCHED.** That is the issue: a worker that finds it lacks the
  model has told us about itself, and the old ways out (fail it, or go quiet and
  be reaped) each charged the job one of its three lives. Three blameless
  hand-backs retired a job nothing was wrong with.
- **Two bounds, because `attempt` can no longer be one.** `released_by` +
  `release_after` (30 s) stop the spin — the releasing executor is not offered
  THIS job again, while every other worker may take it in the same second, so one
  box short of VRAM cannot delay a fleet with capacity. `releases` stops the
  pathology: past `MAX-RELEASES` (10) the job fails, naming the hosts that let it
  go. Migration `0043-job-release`, all nullable, no backfill.
- **The cool-off is tested in the claim's WHERE clause**, not in Racket after the
  `LIMIT 64` — issue #54's trap, which would bound the answer instead of the scan
  and show a worker an empty queue it had just emptied itself.
- **An unknown reason is recorded as `other`, never refused.** PULL‑11f's
  asymmetry pointing the other way: here the RELEASE is the request and the
  reason rides along, so a 400 would leave the worker holding a job it has
  already said it cannot run. `RELEASE-REASONS` is `busy` / `unsupported` /
  `shutdown` / `other`.
- **A release during cancellation settles the job**, as `worker-fail!` does
  (SCHED‑8). Fenced by `claim_token` like every other post-claim write.
- **Audited before the write** (FLEET‑1's rule — the re-queue clears
  `executor_id`), and the FLEET‑4 queue row carries `releases`, because the field
  a reader would check is by design unchanged.
- **The reference worker releases on shutdown**, from the same plumber flush that
  reports `paused`, the release first in case the host dies between the two
  requests. A worker stopped mid-job was the most ordinary way an attempt got
  spent on nothing. `held` is cleared in a `dynamic-wind` at the call site so it
  is right however `run-job` exits.
- A third-party worker that never calls `release` behaves exactly as before.

```sh
raco test test/pull-tests.rkt   # the untouched counter, the cool-off, the ceiling, the fence
bash test/pull-smoke.sh         # section 6b, 7 assertions over HTTP
```

## The reaper leaves a record (FLEET‑1, issue #70)

Built 14 Oct 2026 — the first slice of the worker-fleet surface. A lease expiry
is the central failure event of the pull subsystem and was recorded **nowhere**.

- **The audit entry is written BEFORE the UPDATE.** The requeue sets
  `executor_id = NULL` — the job is nobody's again — so afterwards nothing in
  the `jobs` table says which machine dropped the work. A job one flaky box
  failed three times and a job three boxes each tried once were the same row.
  Never reorder this; there is nothing left to derive from.
- `job.lease.expired` per attempt (`result` `requeued` or `exhausted`), naming
  the executor in `meta`; `job.attempts.exhausted` once at the end carrying
  `holders`, oldest attempt first. Two actions because two readers: a count of
  the first is the fleet signal, the second is one job's story.
- **`team_id` is the JOB's team**, `actor_type` `system`. `audit-list` filters by
  team, so an entry without one is invisible to the people whose work stopped —
  QUOTA‑3's rule, and the gap `user.2fa.reset` still has.
- **No dedup**, unlike `quota.exhausted`: that is re-decided for every queued job
  on every tick; an expiry happens once per attempt, bounded by `MAX-ATTEMPTS`.
- **The stored error names the holders**, composed by reading the trail back
  (`lease-holders`, `exhausted-message`). "no executor completed it in 3
  attempts" was true and useless. An attempt with no executor reads as **in
  process**, never as a guessed name.
- **Do not write `(>= (add1 attempt) MAX-ATTEMPTS)`** when naming the negation of
  the original `(< attempt MAX-ATTEMPTS)`. It is off by one and costs every job
  an attempt; it is `(>= attempt MAX-ATTEMPTS)`. The existing MAX-ATTEMPTS case
  in `test/pull-tests.rkt` is what catches it.
- Still unaudited, deliberately and noted rather than folded in: a `canceling`
  job the reaper settles, and `reap-orphans!`'s boot sweep.

```sh
raco test test/pull-tests.rkt   # the trail, the ordering, the in-process case
```

## The beta judge's verdict is validated (JUDGE‑6, 14 Oct 2026)

From the issue #31 exploration (decisions JUDGE‑1…6 in
`docs/design/decisions.md`): the prospect judge was the ONE judgment call in the
platform that did not go through `domain/tools/jsonschema.rkt`.

- `VERDICT-SCHEMA` in `beta.rkt` goes through `validate-json`, the same validator
  DWF‑5's extraction uses. A model answering `"score": "high"` used to be scored
  0 and **silently reject the prospect**; it is now a refusal naming the path.
- **`parse-verdict` answers three distinct things** — the verdict (a hash), a
  LIST of problem strings, or `#f` for no object at all — because the caller says
  something different about each: nothing to read, read but malformed, usable. A
  caller that only asks `(hash? …)` still behaves correctly; one that treats a
  truthy answer as a verdict will now get a list.
- **The schema is OPEN** (`additionalProperties`), unlike the pipeline's closed
  object: the judge prompt is operator-authored and an operator may legitimately
  ask for a field we do not know about.
- **`valid` and `score` are both required, and that is a behaviour change.** A
  judge prompt producing only a score used to yield a verdict the decide path read
  as invalid — a silent rejection — and now yields a named refusal. One existing
  case in `test/beta-tests.rkt` was missing `valid` incidentally (it is about
  braces inside strings) and had to gain it.

**The rest of #31 is design, not code**, and the design was REVISED on 15 Oct
2026 (JUDGE‑7…12, issue #57) because its premise changed. `IoTone/poplog`'s
`packages/laya` self-hosts an open-weight decision model that takes JEV's own
`POST /v1/systemone` request, so:

- the first backend is laya, not a chat model behind a schema (that becomes the
  second, and is the only one that runs in CI);
- it needs **no new wire and no plugin** — a remote job kind `judge.typed` plus a
  pull worker on the Mac inherits quota, the org gate, cancel, the lease, the
  fence, PULL‑11's state, PULL‑12's release and all of FLEET‑1…4;
- **option and question order is part of the question** — measured: 1 of 6
  orderings agreed with the written order, one probability moved by 0.54. So
  ordered lists, never `hasheq`, and **never sorted**: this is the third place
  the hash-order trap appears here and the first where `json-out`'s sort would be
  actively wrong;
- `output_tokens` is always 0, so `ai.tokens.total` cannot bound it — a judgment
  needs its own dimension;
- a stored verdict must carry the checkpoint, the dtype and the batch policy, and
  LAY‑11 must hash it AS GIVEN: 50% of answers move in the 4th decimal with their
  batch-mates unless `batch_size=1`;
- **the request travels as COMPOSED BYTES** (JUDGE‑13): `questions` and a
  choice's `criteria` are JSON objects whose KEY order is part of the question,
  which no jsexpr can carry — `request_json` is written once by an ordered
  writer and never re-serialized, and the verdict is stored as received;
- **no new laya API is needed** (JUDGE‑14): `laya_serve.py --port` already
  speaks `POST /v1/systemone` + `GET /v1/health` on loopback with the flags
  JUDGE‑11 pins; the bridge is a pull worker on the same host, run with
  `--batch-size 1`.

The analysis is FINISHED (JUDGE‑1…14): the build plan, in order JUDGE‑9+13 →
‑8 → ‑10 → ‑11 → ‑7, is at the end of the decision block. Read it before anyone
writes an integration.

## The typed-judgment wire (JUDGE‑9 + JUDGE‑13, issue #57 slice 1)

Built 15 Oct 2026 — the first slice of the judge, and the one that was expensive
to retrofit. `domain/judge/wire.rkt`: question constructors
(`judge-noul`/`judge-choice`/`judge-score`, mirroring poplog's `ts_*`), the
request composer (`judge-request` → JEV's own `POST /v1/systemone` body), and
`verdict-problem`, the validator a remote kind's `#:validate` will wrap.

- **The request is COMPOSED BYTES.** `questions` and a choice's `criteria` are
  JSON objects whose KEY ORDER is part of the question, which no jsexpr can
  carry. `judge-request` answers a STRING, written once by `ordered-json`;
  nothing downstream may parse-and-re-serialize it. `json-out`'s sort rule is
  actively wrong here — keep this wire away from it.
- **An ordered object is `(jobj (list (cons key value) …))`** — a struct, not a
  bare list of pairs, because a pair whose cdr is a list IS a list and the two
  shapes would be told apart by luck.
- **`verdict-problem` takes both strings** (request, verdict), parses COPIES,
  and answers `#f` or ONE problem naming the path. It requires `model` (a
  judgment without its checkpoint is unauditable — JUDGE‑11), every question
  answered with its own type, and a choice pick that is one of the question's
  own options; it is OPEN to fields it does not know (`probabilities`, `action`,
  `order`, `legend` — laya says more than JEV).
- Nothing here touches the DB, the routes or the catalogs.

```sh
raco test test/judge-wire-tests.rkt   # 6 cases: order, bytes, determinism, the paths
```

## The typed-judgment seam (JUDGE‑8, issue #57 slice 2)

Built 15 Oct 2026. `domain/judge/judge.rkt`: `judge` (JUDGE‑1's one entry
point) enqueues remote kind **`judge.typed`** and waits, the pull-dispatch
pattern — so quota admission, the org gate, cancel, lease, fence, PULL‑12's
release and the FLEET surface are all inherited from the job row. No new route:
the worker wire is PULL's, and the kind is registered at boot in `main.rkt`
beside `infer.chat`.

- **Payload `{request_json}`, result `{verdict_json}` — both bytes, never
  re-serialized** (JUDGE‑13). The job row ends up holding exactly what crossed
  the wire, both directions.
- **Validation is split in two, deliberately.** The kind's `#:validate`
  (`judge-result-problem`) holds the WORKER to the half it controls:
  `verdict_json` is a string parsing to an object with a checkpoint and
  answers. The SEAM runs the full `verdict-problem request verdict` at the
  read, where the request is in hand — a worker cannot be failed over a
  question it never saw, and a well-shaped verdict that does not answer THIS
  request is refused by path, never handed to the caller.
- `judge` returns `(values verdict-jsexpr verdict-json)` — the values a caller
  branches on AND the received bytes JUDGE‑11 stores and hashes.
- **The dispatch is audited** (`judge.dispatched`, the job's team, naming the
  job and the request's size — JUDGE‑4: state left the process for another
  host; the entry says so without copying it).
- **The reference worker is the laya bridge** (JUDGE‑14):
  `TELEMACHUS_WORKER_LAYA_URL` (a loopback `laya_serve.py --port`, run it with
  `--batch-size 1`) adds `judge.typed` to its kinds; the chat endpoint becomes
  optional, so a Mac can be a judge host and nothing else. It POSTs
  `request_json` RAW (`http-sendrecv`, not `http-post-json`, which would
  re-encode) and returns the body as received.
- laya itself never runs in CI (JUDGE‑12): the tests drive the seam with a
  worker double that answers like laya, extra fields and all.

**JUDGE‑7 (slice 5): the chat-and-schema backend, behind the SAME validator.**
`judge-via-chat` — the only backend CI runs end to end, and the fallback for an
instance with no Apple Silicon host. Same request bytes (the model is SHOWN the
composed `request_json`), same `verdict-problem`, same kept document via the
shared `keep-judgment!`. `#:chat` is positional `(chat text sys)` (translate!'s
seam; tests script it); `#:model-name` is REQUIRED — a chat verdict still names
what answered, or it is unauditable. The reply is read with `outer-json` (prose
or a fence around the JSON is fine), a refusal is retried ONCE (the pipeline's
rule), and the verdict is CONSTRUCTED once — the model's answers plus the model
name — then held to the request. The chat path meters its own
`ai.judgments.total` (`tenant-quota-record!`): no job row means the scheduler's
biller never sees it; the TOKENS are the caller's chat seam's to meter. A
failed judgment bills nothing.

**JUDGE‑11 (slice 4): the kept judgment is a DOCUMENT.** `judge #:source <id>`
writes the settled verdict as `<source key>.judgment.json` (or `#:key`),
DERIVED from the judged material — derive!'s rule to the letter (visibility at
`repo-put!`, THEN `repo-inherit!`), written as the caller in-process so `can?`
and the storage quota decide; an unreadable source and a missing one are ONE
answer, refused BEFORE anything is enqueued. The content is the kept pair
`{request_json, verdict_json}` as composed/received — both strings come back
byte-identical, which is what LAY‑11 hashes, and the verdict's `model` string
(checkpoint+revision+dtype) rides inside. `judge` returns THREE values now
(verdict, verdict-json, doc-or-#f). The job row holds the same strings, but a
row is #59's to purge — the document is the home for a judgment somebody means
to keep, and "Processed by" finds it through the derivation row.

**JUDGE‑10 (slice 3): a judgment bills its own dimension.** `output_tokens` is
always 0 on this wire, so the token meter cannot see it. `judgments-in-result`
(judge.rkt) counts the verdict's `answers` — one per question answered, `#f`
for every other kind's result — and main.rkt's ONE biller (the `#:record!`
lambda both `run-claimed!` and `worker-complete!` call) records
**`ai.judgments.total`** at both tiers. The dimension is in `QUOTA-HOLD-DIMS`
(a set limit holds the team's queue, like tokens) and on `GET /api/usage`. No
default limit: a local judgment costs ~10 ms, and the hold only exists where
an operator set one. Remember `quota-check` reports `used: 0` with no limit
set — the smoke sets a limit before asserting the ledger.

```sh
raco test test/judge-tests.rkt   # the round trip, the two validation halves, the audit, the meter
bash test/pull-smoke.sh          # section 8c, 8 assertions over HTTP
```

## A deferred job says why (issue #55, built 14 Oct 2026)

An over-budget team's jobs stay `queued` — right, and until now invisible.
Decision QUOTA‑3 in `docs/design/decisions.md`.

- **The admission seam answers with a REASON, not a boolean.** `#:hold-reason` on
  `start-scheduler!` (`*hold-reason*`, `scheduler-hold-reason`) returns `#f` to
  admit or a hash to defer-and-explain, because one policy now has two askers:
  the claim, which must decide, and `GET /api/jobs`, which must explain. Two
  implementations of one policy would drift. **It must stay PURE** — the job
  listing calls it on every read — so the audit entry is a SECOND hook,
  `#:on-hold`, fired only where a claim was really deferred. `set-admit?!` and
  `scheduler-admit?` are gone; a caller passing `#:admit?` now gets an
  unknown-keyword error, which is the point.
- **`waiting` on a job is DERIVED, never stored.** A column would be a second
  copy of a decision the next tick re-makes — raise the budget and the row would
  still say "quota" for a job about to run. Same rule as `missing`/`stale` in the
  Localization Manager and executor health. No migration.
- **The order mirrors `claim-next!`**: the concurrency cap before the budget, so
  a team that is both at its cap and over its budget is told about the cap — the
  one that clears on its own.
- **The key is ABSENT, never `{"reason":"worker"}`,** when nothing holds the job.
  Nothing here can know whether a worker for a remote kind exists, and a reason
  nothing stands behind is how a reader stops trusting the field.
- `job-waiting` computes the reason **once per listing**, not per row: the answer
  is a property of the team. A sub-job is cap-exempt at claim, so it is asked
  with `#:sub? #t`.
- **The audit entry is once per window per (scope, subject, dimension)**, deduped
  by asking the AUDIT LOG (`at_us >= the window's start`) rather than a table of
  its own — the log is already the record, and an in-memory set would forget on
  restart and re-announce what the operator has read. Every pool tick re-tries
  every queued job, so a per-claim entry writes dozens in seconds. `team_id` is
  the DEFERRED job's team even when the ORG's budget holds it: `audit-list`
  filters by team.
- **`resets_at` is asked of the DATABASE** (`window-bounds` in `quota.rkt`),
  because it must agree with `window-clause`, and the two dialects do not mean
  the same thing by "day": SQLite's `date('now')` is UTC, PostgreSQL's
  `CURRENT_DATE` follows the server's timezone. The two smoke runs report
  boundaries **seven hours apart** on the same day and each is right about its
  own dialect — a value computed in Racket would be right on one and hours out on
  the other. Not on the admission path: `quota-check` is unchanged, and the two
  reporting sites (`GET /api/usage`, the hold reason) pay for it.
- **A sliding window answers nothing.** `"minute"` loses its oldest second every
  second, so there is no instant at which it resets; `"total"` never does. Both
  answer `null`, and the console only renders the sentence when the server named
  a boundary.
- Console: the Usage tab carries the ⏸ card (`quotaHeldCard`, from `held` on
  `GET /api/usage`) and a "Resets" column; the Jobs tab badges a held job
  (`jobWaitBadge`). An ORG-tier limit is not the team operator's to raise, so the
  card does not promise it.

```sh
raco test test/scheduler-tests.rkt   # the reason, the cap-before-budget order, the report
bash test/server-smoke.sh            # 8 assertions after "job quota-gated"
```

## Capability records, the accuracy report, the decision chain (LAY‑9…12)

Built 12 Oct 2026. **All twelve LAY items are now built**, each with its limits
written down in `docs/design/layered-operations.md` rather than implied.

**LAY‑9 — what a backend can actually do.** The capability document a pull
executor already carried for claim matching (`{kinds, models}`) is the same place
a push backend declares `tools` and `json_schema` — one document, not a second
mechanism. `model-exchange` takes `#:needs` and refuses **by name** before the
request leaves the process; `run-chat` asks for `json_schema` only when a format
was requested, the agent always asks for `tools`.

- **An undeclared capability is UNKNOWN and unknown is PERMISSIVE.** Only an
  explicit `false` refuses, so nothing that works today starts failing.
- **The local model declares its own** via `TELEMACHUS_MODEL_CAPS`
  (`"tools=false,json_schema=true"`). It has no executor row and is the path most
  calls take — without it the operator who most needs the warning gets none.

**LAY‑10 — the accuracy signal is a query.** `GET /api/reviews/stats` groups the
decisions LAY‑2 already records by workflow and step: approved / revised /
rejected, the approval rate, the mean time to decide.

- **Not per model, and the reason matters.** `jobs.executor_id` IS recorded — but
  only when a WORKER claims; the pool's in-process jobs leave it NULL. A
  per-model breakdown would cover the pull-executed subset *while looking
  complete*. The fix is to keep the model `model-exchange` already resolves and
  returns as its third value, which both call sites discard.
- `approval_rate` is an **inexact real**: `jsexpr?` takes exact integers and
  inexact reals, so an exact rational would pass a test and throw in `write-json`.

**LAY‑11 — the decision chain.** Each decision hashes its fields plus the previous
decision's hash, per team; `GET /api/reviews/verify` names the first break.

- **The canonical form is an ordered LIST, never a hash** — `hasheq` iteration
  order is not stable across processes, the trap `json-out` sorts to avoid.
- **State the claim narrowly.** It detects a record altered in place or removed
  from the middle. It does **NOT** detect a rewrite by anyone who can write the
  table, who can recompute every link after it — and that is the party an audit
  most defends against. Same shape as secrets at rest defending a DUMP and not a
  HOST. Closing it needs an external anchor; not built.

**LAY‑12 — where review appears.** Satisfied by LAY‑1…3 (the queue is a core,
permission-gated tab) and LAY‑6 (the canvas is an authenticated plugin bundle).
**This does not mean manual annotation is done** — annotation STORAGE was its own
item and nothing stores a region yet.

- Route order: `/api/reviews/stats` and `/verify` sit **above** `/api/reviews/:id`
  in the table, or the pattern swallows them. First match wins in list order.

```sh
raco test test/review-tests.rkt test/model-routing-tests.rkt   # the chain, the report, the refusals
bash test/server-smoke.sh                                       # 7 more assertions in the reviews block
```

## Team-defined object metadata, and where text came from (LAY‑4/‑5, 12 Oct 2026)

Migration `0036-object-metadata` adds both columns at once: `repo_objects.attributes`
and `repo_text.spans`.

**LAY‑4 — what the team ASSERTS about a document.** `repo_objects` carried org,
team, owner, visibility and key and nothing a team could define, so project /
location / period / status had nowhere to live and Layer 3 had nothing to
aggregate over.

- Definitions are a **team setting** (`repo-fields:<team>`, beside branding in
  `instance_settings`); values are a **blob** on the object. Adding a field needs
  no migration — the call the prospect attributes model already made.
- **The validation vocabulary is literally the funnel's.** `field-problem` moved
  to `domain/fields/fields.rkt` and `beta.rkt` re-exports it, so there is one
  implementation rather than two that drift. Still `required` / `digits` /
  `minlength` / `maxlength` and deliberately **not a regex**.
- **A key the team has not defined is REFUSED, not stored** — the call an unknown
  theme token makes. A value nothing can display or filter on is how a team
  concludes the model is broken.
- Setting attributes MERGES, so writing one field cannot drop another, and an
  empty value clears one. `required` is checked on the merged result, so clearing
  a required field fails.
- **`?attr=key:value` on `GET /api/repo` is repeatable and applied AFTER the
  per-row `can?`** — a filter can only narrow what a caller may see, never widen
  it. `query-params` (plural) exists for this: `query-param` answers with the
  first value, which is right for a scalar and wrong for a stackable filter.
- The knowledge graph is NOT a substitute: it extracts what a document *says*,
  this is what the team *asserts*, and for an inspection record the second is
  authoritative.

**LAY‑5 — where the extracted text came from.** The one decision with a deadline:
adding it later means re-processing every document ever ingested.

- **An extractor may answer with two values or three**, the third being spans of
  `{start, end, page, bbox}`. Provenance is ADDITIVE — `extract-text` still
  returns two values for every existing caller, `extract-text/spans` returns
  three, and every plugin extractor written before LAY‑5 keeps working. That
  arity-tolerance is what stops LAY‑7's contract from breaking.
- `start`/`end` are character offsets into the text the SAME call returned; the
  bbox is in the extractor's own page units and the platform carries it without
  interpreting it, because only the renderer knows whether they are PDF points or
  image pixels.
- **A malformed span is dropped and the text is kept.** Provenance is an
  enrichment; losing a region must never cost a team the document. Spans past
  `EXTRACT-CAP` are dropped too — they could never resolve.
- **No built-in fills it yet** (`pdftotext` would need `-bbox-layout`; the reader
  that will have regions is an OCR plugin). The column exists before anything
  fills it, which is the whole point — the seam was the expensive half.
- `GET /api/repo-obj/<id>/spans?at=<offset>` resolves an offset to a region, which
  is how a reviewer jumps from an extracted value to where it was read.

```sh
raco test test/object-metadata-tests.rkt   # 10 cases: the vocabulary, the filter, span hygiene
bash test/server-smoke.sh                  # the "== object metadata ==" block, 11 assertions
```

## A plugin can claim a FILE FORMAT (LAY‑7, built 12 Oct 2026)

`kind-of` in `extract.rkt` was a fixed `cond` over text / markup / docx / pdf, so a
plugin could add a tool, a route, a workflow and a job kind — but not a reader.

- **`register-extractor!` from a plugin's `init!`**, keyed by content type, with
  the ownership rules `register-job-kind!` already had: two plugins cannot claim
  one type, re-registering your own is fine (the loader may run twice in one
  process). Ownership comes from `current-plugin`, which lives in the scheduler
  because job kinds needed it first; both registries read it.
- **A registration REPLACES the built-in for that type.** That is the point —
  claiming `application/pdf` is how a local OCR engine takes over from
  `pdftotext`.
- **An extractor is IN-PROCESS Racket** with the platform's own contract,
  `(in content-type) -> (values text-or-#f reason-or-#f)`. Reaching a non-Racket
  engine is its own business and shelling out is the established way — the
  built-in PDF reader is a pipe to `pdftotext`. Shipping bytes TO a subprocess is
  the other seam (LAY‑6's `repo.get`), for a plugin that is a tool, not a reader.
- **`EXTRACT-REASONS` is a CLOSED vocabulary**: `unsupported` / `missing-tool` /
  `needs-ocr` / `failed`. `doc_text` branches on two of them for named refusals
  and the indexer records any of them as processed-with-nothing, so a plugin
  inventing a fifth would arrive as a refusal naming something nothing explains.
  Anything else collapses to `failed`.
- **A plugin that raises, or answers with the wrong shape, is `'failed`** — never
  an exception. One plugin must not wedge a team's indexing, which is the rule the
  indexer already lived by for a bad FILE.
- **The cap stays the platform's** (`EXTRACT-CAP`): this feeds a search index, not
  an archive.
- `GET /api/plugins` reports each plugin's `extractors`. Worked example: an RTF
  reader in `plugins/example-tools/` — RTF because the platform genuinely cannot
  read it, and an unreadable document is invisible to search.

```sh
raco test test/extractor-registry-tests.rkt   # 9 cases: replacement, ownership, containment
```

## Out-of-process plugins reach the repository (LAY‑6, built 12 Oct 2026)

A sandboxed plugin could reach `notes.create` and `notes.list` and nothing else,
so a Python OCR or CV pipeline could read no bytes and write no result — while an
in-process Racket tool read blobs freely. **The asymmetry was the bug**, and every
domain pipeline the platform is for is out-of-process.

- `repo.get` (`files:read`), `repo.text` (`files:read`), `repo.put` (`files:write`)
  in `domain/oop/host.rkt`, behind the same **double gate** the notes capabilities
  use: the plugin must have DECLARED the scope and the caller must hold the
  permission. Neither half alone.
- **Bytes are base64 over the existing pipe.** Not a path — that would couple a
  plugin to the local store and leak its layout, and the blob store is
  deliberately never handed a principal. Not a presigned URL — that needs the S3
  listener and a second credential. Capped at `TELEMACHUS_MAX_UPLOAD`: a plugin is
  not a way past the limit the front door enforces.
- **`repo.text` reports a scan as an ANSWER**, `{text: null, reason: "needs-ocr"}`,
  not an error — that is the branch an OCR plugin exists to take, and it should
  not have to match on an error string to find it. (The `'needs-ocr` reason itself
  is LAY‑8.)
- **`repo.put` with `derived_from`** passes the source's visibility to `repo-put!`
  and THEN inherits the grants — do not reorder — and sets `#:derived?` so an
  opted-in trigger cannot fire on the plugin's own output.
- **`GET /api/plugins` gained a `sandboxed` key** with each plugin's declared
  scopes. They were absent entirely, so after granting repository access there was
  no way to audit who holds `files:write`. Kept as its own key because
  `loaded-plugins` is what `docs/reference/` is generated from.
- **`raco make` exiting 0 does not mean the module loads.** A definition that
  references a helper defined *below* it compiles and then dies at module init
  with "cannot reference an identifier before its definition". Load the module,
  don't just build it.
- Worked example: `oop-plugins/doc-reader/`, registered in `oop.json`. The
  capability table is documented in `docs/integrators-guide.md` §7b.

```sh
raco test test/oop-tests.rkt   # 8 cases: the double gate, provenance, the ceiling, end to end
```

## Offboarding and password hygiene (issue #54, built 5 Oct 2026)

Before this, `/api/members` had only `POST` and `GET`: a team could be joined and
never left, no role could be changed, and a password change revoked nothing. You
could not offboard somebody — and the one thing a person does when they think
their password is known did not help.

- **A password change revokes every SESSION, including the one making the call**,
  so the caller signs in again. **This is a behaviour change**: `server-smoke.sh`
  changed alice's password and kept using the same token, and had to re-login —
  the same shape as enforcing `required` on the funnel's fields.
  Machine credentials (`api`, `worker`) are deliberately spared: they are not
  reachable with the password, they are listed and revocable on their own, and
  killing a customer's worker because somebody rotated a password is the worse
  failure. A fresh token is NOT issued in exchange — that would let a narrowly
  scoped API token trade itself for a full `*:*` session.
- **`DELETE /api/members/:id` deactivates and revokes.** The membership row stays
  (an audit needs to know the person was there, and what they own still points at
  the user); `status = 'inactive'` yields no role, and `user-permissions` already
  returned `'()` without one, so the deny is the path that existed rather than a
  new one. Their tokens **for that team** are revoked in the same call: removing
  somebody whose credentials go on working is not removing them.
- **The last owner can be neither demoted nor removed** (409). A team with no
  owner cannot grant anybody the permission to fix it.
- **`POST /api/admin/users/:id/password`** (`instance:manage`) is the way back in
  for someone locked out — there is no mail transport, so an operator-assisted
  reset is the honest answer rather than a reset-link flow that cannot be sent.
- **Every one of these audits**, and the admin reset is attributed to the ACTING
  operator's team: `audit-list` filters `WHERE team_id = ?`, so an entry with no
  team is invisible. (`user.2fa.reset` has the same gap and was left alone —
  noted, not fixed, in this slice.)
- `GET /api/members` lists only ACTIVE memberships now.

```sh
raco test test/membership-tests.rkt   # 5 cases: roles, the last owner, revocation
bash test/server-smoke.sh             # the "== members and passwords ==" block, 21 assertions
```

## Human review in a workflow (LAY‑1…3, built 4 Oct 2026)

A workflow can park on a person. `domain/review/review.rkt` owns the decision
record; `docs/design/layered-operations.md` has the reasoning.

- **A `review` step never becomes a job.** `start-review!` writes the step row
  `waiting`, opens the review and sets the run `waiting`; nothing is queued, so a
  parked run holds **no concurrency slot** however long the specialist takes (the
  smoke asserts the queue is empty while it waits). `flow-advance!` only acts on a
  `running` run, so "parked" needs no timer and no in-memory queue — the rows are
  the state, as they already were.
- **`resume-from-review!` is installed as review.rkt's resume hook**, the same
  seam shape `repo-put!` uses for triggers, so the review module never learns what
  a workflow is. The dependency runs one way: run.rkt → review.rkt.
- **The verdicts are FROZEN** (`REVIEW-VERDICTS` in `spec.rkt`): approve / revise /
  reject. Same call as the binding sublanguage — the console renders each one, and
  a spec that invented `escalate` would be a verdict nothing can show. `on` names
  a step per verdict and `approve` is required; a null branch ends the run.
- **Four eyes (LAY‑3) generalises `l10n-review!`'s rule.** `author_user_id` NULL
  means the subject was model-produced — nobody's work — so anyone with
  `reviews:decide` may decide it, which is the machine-draft case and what lets a
  one-person team run a pipeline. With `four_eyes: true` the author is the run's
  initiator, who is then refused (403, not 400: the request is fine, the person is
  wrong for this item).
- **A rationale is required for `revise` and `reject`, not for `approve`.**
  Demanding one for a plain approval buys a field full of "ok"; sending work back
  is the case Layer 3 has to explain later.
- **A decided review is terminal.** Deciding again is a 409. A wrong decision
  wants a superseding record, not a rewrite — the grants table's rule.
- **`reviews:read` + `reviews:decide` go to MEMBER**, unlike `localization:review`
  which is an admin act. Reviewing is the specialist's job here; integrity comes
  from four_eyes, not from the role.
- Checklist **shape** is validated by `spec.rkt` (it is part of the spec);
  **answers** are validated at decision time by `review.rkt`. Unknown answer keys
  are refused rather than dropped.
- Cancelling a parked run cancels its pending review — no question left hanging.
- `reviews.run_id` is nullable so a standalone review needs no migration later,
  but only a run opens one today.

```sh
raco test test/review-tests.rkt   # 9 cases: parking, all three verdicts, four eyes, cancel
bash test/server-smoke.sh         # the "== reviews ==" block, 16 assertions
```

## Layered operations (LAY‑1…12) — all built

`docs/design/layered-operations.md` — a gap analysis from a civil-engineering RFE.
**All twelve are built**; each one's sections above carry the detail, and each
one's LIMITS are written down in the design doc rather than implied. What this
document is still worth reading for is the boundary it draws: the platform grows
SEAMS, a domain supplies CONTENT through them, and the test of the design is that
no civil-engineering requirement needs a core change.

One thing it named is deliberately NOT built and must not be: the `approve` step
kind (see the issue #54 section). And LAY‑12 does not mean manual annotation is
done — annotation STORAGE was its own item and nothing stores a region yet.

## The integrator's guide (`docs/integrators-guide.md`)

The document a downstream team follows to put THEIR product on Telemachus: theme
the console (branding tokens), ship tools, serve their own screens
(`plugins/<id>/bundle/`), back them with their own routes (`/api/x/<id>/…`), add
job kinds, and skin the funnel. `plugins/integrator-demo/` is the worked example
— one tool, two routes, a namespaced job kind, and a bundle screen that reads
`GET /api/branding` and maps the same theme tokens, which is how a customer's
palette reaches their own screens. `test/server-smoke.sh` asserts all four seams,
so the example cannot rot silently.

The guide states the gaps rather than papering over them: a plugin cannot add a
tab to the core console, feature flags are per TEAM only (no instance-wide
switch), and there is no hot reload.

## Plugin routes and artifact results (slices 63–64, issue #15)

- **A plugin may `(provide routes)`**: `(list method path perm handler doc)` per
  entry, handler `(conn principal args) -> jsexpr` with `args` =
  `(hasheq 'params … 'query … 'body …)`. The loader validates each entry at load
  (a bad one fails THAT plugin, not a request later) and the server mounts them
  at **`/api/x/<plugin-id>/<path>`** — the prefix is platform-fixed, so a plugin
  can never shadow a core route or another plugin's. Always `with-auth`, then the
  named permission through `require-perm`; a `raise-user-error` is the caller's
  400. Matched AFTER the core table (`match-routes` over `PLUGIN-ROUTES`, built by
  `install-plugin-routes!` after `load-plugins!` in main). They appear in
  `docs/reference/api.md` under "Plugin routes" and in `GET /api/plugins`.
  `plugins/example-tools` ships `word-count` as the worked example; the smoke
  pins GET/POST, 401, 400 and the prefix.
- **A tool may return an artifact** (`domain/agent/artifact.rkt`): a hash with an
  `artifact` key `{kind, title, summary, content_type?, object_id?, version_id?,
  url?}` plus any keys a workflow step should bind. The three surfaces agree by
  construction: the model gets ONE line (`artifact->text`), the console gets the
  hash on the `tool_result` event and renders `artifactCard` (opens the document
  or follows the link), a workflow step keeps the whole value. Every
  document-pipeline output is one now (`obj-summary` in doc-tools.rkt), and
  `(out form result object_id)` still binds because the plain keys ride beside
  the artifact. `dispatch-tool` (string for the transcript) and
  `dispatch-tool/artifact` (text + the artifact for the event) share the checks.
- Kinds: document, table, text, link, image. An unknown kind is an error at
  construction — the console switches on it.
- **An out-of-process tool may answer with STRUCTURE** (issue #46): the protocol's
  `result` message takes an optional `result` jsexpr beside `text`. Returning only
  `text` made every such answer a JSON *string* by the time a workflow bound it,
  so a step needed an in-process shim to parse what the platform had just
  stringified. The platform never guesses that a string was meant to be JSON — the
  plugin says so by sending `result`.
- **A plugin may register a JOB KIND** (issue #21), through `init!` — the
  documented route, not a fourth `(provide …)`. The loader binds the plugin's id
  while `init!` runs, and the kind must be named **`x.<plugin-id>.<name>`**, the
  same platform-fixed prefix routes get; a violation fails THAT plugin's load.
  Re-registering your own kind is fine (the loader may run twice in one process);
  a name someone else owns is not. The registry records the owner, so
  `GET /api/plugins` and `plugins.md` report kinds per plugin — do not go back to
  a before/after diff in the loader, which makes a kind look like nobody's on a
  reload. A **remote** kind now REQUIRES `#:validate`: there is no in-process
  handler to be strict for it. A plugin kind inherits everything from the row
  (team, user, cap, quota admission, org gate, cancel, lease) and nothing from
  the plugin. Worked example: `x.example-tools.word-count`.
- **An authenticated page needs a TICKET to be opened** (issue #43). The bundle
  route wants a bearer and a browser navigation carries none, so
  `POST /api/x/<id>/bundle-ticket` mints a short-lived ticket bound to (principal,
  plugin); `?ticket=` opens the page and the response sets it as a cookie scoped
  to `/api/x/<id>/bundle/` so sub-resources load. Deliberately NOT a session
  cookie issued at sign-in: the JSON API keeps its no-cookie, no-CSRF-surface
  property. The console links a plugin with a `bundle/` directory from the Usage
  tab (`pluginOpen`, which opens the window BEFORE awaiting — a popup blocker
  refuses one opened after).
- **`query-param`'s default is `""`, and an empty string is TRUE in Racket.** `(or
  (query-param req 'x) fallback)` therefore never reaches the fallback — which is
  how every bundle sub-resource 401'd on its cookie the first time.
- **Two bundle directories, and the difference is who may read them** (issue #20).
  `plugins/<id>/landing/` is PUBLIC at `/beta/bundle/<id>/` (the funnel a prospect
  is linked to, `public, max-age=300`). `plugins/<id>/bundle/` is the
  AUTHENTICATED one at **`/api/x/<id>/bundle/*path`** — bearer required,
  `private, no-store` + `Vary: Authorization`. `bundle/` is reserved by the
  platform under every plugin's prefix and core routes match first, so a plugin
  cannot claim it. The bundle is code, one copy for everyone; anything per-org
  comes from the plugin's API routes. Assets ship IN the bundle — `CONSOLE-CSP`
  is same-origin, so a CDN script or font is blocked.
- **A `..` segment is a SYMBOL, not a string.** Racket's URL parser gives `'up`
  (and `'same` for `.`), so joining or matching a path as strings raised — the
  public bundle route answered **500** instead of its intended 404, invisible for
  a year because curl collapses `../` unless you pass `--path-as-is`. `request-path`
  in `pkgs/web-kit/main.rkt` normalizes both to `".."`/`"."`; keep traversal
  assertions on `--path-as-is`, and add the percent-encoded (`%2e%2e`) and nested
  (`a/../../`) forms — the plain one alone proves nothing.

## Pull-model executors (slice 66)

Inference hosts that claim work instead of being called. Design:
`docs/design/pull-executors.md` (PULL‑1…8, built). `domain/exec/pull.rkt`;
migration `0028-executors`; `/api/executors`, `/api/org/executors`,
`/api/workers/{claim,jobs/:id/heartbeat|complete|fail}`;
`cli/telemachus-worker.rkt`.

- **A remote kind has no in-process handler**: `register-job-kind! kind #f
  #:remote? #t #:validate f`. The pool's `claim-next!` skips remote kinds; only
  `worker-claim!` takes them. `infer.chat` is the shipped one — the wire
  `run-chat` speaks — validated to `{reply: string, tokens_used: number}`.
- **The worker token is an API token scoped `jobs:execute`, `ttl 'never`**,
  shown once on create. `with-worker` resolves the executor through the token's
  id (`executors.token_id`) — never through a request field. The operator's
  token passes `jobs:execute` (operators pass everything team-tier) and is still
  refused as "not bound to an executor"; the smoke pins that.
- **`run-chat #:executor <pull>` blocks on a sub-job** (`pull-dispatch!`, via
  the `pull-router` box executor.rkt exposes). The sub-job carries
  `parent_job_id` and is EXEMPT from the team cap at claim — two parents at cap
  2 would otherwise each wait for a sub-job nothing could claim. The team/user
  come from `current-job` (inside a scheduler job) or
  `current-request-principal` (on the request path, set by `with-auth`).
- **Leases**: `LEASE-SECONDS` 120, heartbeat at a third; `reap-leases!` runs on
  the pool's idle tick and re-queues with `attempt+1`, failing past
  `MAX-ATTEMPTS` 3. Complete/fail are accepted only from the current holder
  (`'not-holder` → 409). Tests expire leases by UPDATE, never by sleeping.
- **Issue #17: the pool leases too, and a claim is believed only if it took the
  row.** `claim-job!` in scheduler.rkt is the ONE claim — `UPDATE … WHERE id = ?
  AND status='queued' RETURNING id`, believed only when a row comes back, used by
  the pool and by `worker-claim!`. Never go back to `query-exec` here: it
  discards the row count, and the count is Postgres-only anyway (`RETURNING`
  works on both, SQLite ≥ 3.35). An in-process claim now carries the same 120s
  lease, refreshed by a thread around the handler (`with-lease`) and cleared on
  finish, so `reap-leases!` recovers a pool job whose process died — it used to
  require `lease_until IS NOT NULL` and a dead pool job held its team's
  concurrency slot forever. A terminal write is guarded on still being `running`
  (`finish!`), so a reaped run cannot land its result — or its bill — on the new
  attempt. `reap-orphans!` sweeps NULL-lease `running` rows at startup: that is
  the upgrade path from a build that claimed without a lease.
- **Issue #24: every claim is FENCED by a `claim_token`** (migration `0031`).
  `status='running'` plus `executor_id` could not tell one attempt from another —
  the same holder may be the one that re-claimed a reaped job — so `claim-job!`
  mints a token per attempt and returns it (`#f` when the claim lost). Every later
  write carries it: `finish!`, the lease refresher, and the worker's
  heartbeat/complete/fail. Requeue, retire and every terminal write CLEAR it, so a
  stale token can never match again. **The pool's `claim-next!` now returns
  `(cons id token)`**, and `run-claimed!` takes the token as its second argument.
  **Wire change**: `POST /api/workers/claim` returns `claim_token` and
  `/api/workers/jobs/:id/{heartbeat,complete,fail}` require it — a worker that
  drops it gets a 409, so a third-party worker must be updated in lockstep with
  the server. **SCHED‑8 added a second obligation to that same wire**: a worker
  must READ its heartbeat's status and stop when it is no longer 200. One that
  ignores it runs to completion after a cancel and then cannot land its result,
  which from the operator's side looks like a silent failure rather than a
  cancellation. The reference worker (`cli/telemachus-worker.rkt`) discarded the
  heartbeat response entirely until then.
- Executor health is derived: never-seen / active / stale (3× lease) / retired.
  Retire revokes the token and requeues a held job.
- **`notes-list` now requires `notes:read` up front** (found by this slice's
  smoke): a token scoped without it got `{"notes":[]}` instead of a 403.

```sh
raco test test/pull-tests.rkt        # claims, the org gate, atomicity, leases, dispatch
bash test/pull-smoke.sh              # a chat routed through the reference worker against the mock model
```

## Model roles (slice 67, KG‑7 / LOC‑5)

`domain/ai/roles.rkt`: a role resolves to an executor NAME — the team's setting
(`instance_settings` key `model-roles:<team>`, `PUT /api/model-roles`,
settings:manage) → `TELEMACHUS_MODEL_<ROLE>` from the environment → `#f`, the
local model. One role ships, **`utility`**: knowledge-graph extraction, the
pipeline's field extraction and translation, and the Localization Manager's
drafts go there when it is set; a person's chat never does. The tools set
`current-utility-executor` around their model call and `default-chat` in
doc-tools.rkt reads it (`run-chat #:executor`), so a pull executor on a GPU box
takes the bulk work without any tool knowing. `PUT` refuses an executor that
does not exist — a typo would silently send every extraction to the local
model. With a role set and no local model, the seam no longer refuses.

```sh
raco test test/roles-tests.rkt
```

## AI model access: one path, one registry (Oct 2026)

Three code paths used to build a model request. The agent built its own, so slice
66's pull executors and slice 67's model roles never reached it, and it metered an
ESTIMATE because it discarded the provider's `usage`. **`model-exchange` in
`domain/ai/executor.rkt` is now the only place a model request leaves the
process** — routing, the deadline, the bounded retry and the status check all live
there, so a feature that adds one of them cannot reach some callers and miss
others.

- **Response PARSING is deliberately not shared.** The agent's parser
  (`parse-agent-response`) takes any registered tool name; `chat-response->assistant-msg`
  goes through `function-call->tool-block`, which drops anything outside
  `tool-tags`. Folding them together would silently disable every plugin tool.
  `openai-llm` is GONE — it had no production caller, and `agent/run.rkt`
  duplicated it.
- **The agent is routable and meters real tokens.** `run-agent-flow` takes
  `#:executor` and returns `(values result tokens)`; `/api/agent` accepts
  `{"executor": …}` (operator-only, as `/api/ai/chat` already was). A live
  tool-using run measured **3,810 tokens where the old code billed 50** — so
  `/api/agent` now also admits on `ai.tokens.total`, which it never did: the
  under-count meant the budget was never reached and the missing check never
  showed. **Operator-visible change**: agent runs now exhaust a team's AI budget
  realistically, and the default is 2,000/day.
- **A pull executor cannot run the agent** — `infer.chat` carries a reply and a
  token count, not tool calls — so it is refused BY NAME rather than silently
  dropping every tool.
- **A named executor that is not a push backend is REFUSED.** It used to fall
  through to the local model while the response still reported the executor's
  name, and with no local model it fell through to the *simulated* upper-cased
  echo. A misroute that lies about where it ran is the worst shape this can take.

### Timeouts and retries

`http-sendrecv` takes no timeout and nothing wrapped these calls, so an endpoint
that accepted the connection and never answered hung the calling thread for
ever. In a scheduler job the lease reaper requeued the WORK after 120s, but the
thread kept its team's `ai.concurrency` slot — a flapping endpoint drained the
pool while `/health` still said ok.

- `TELEMACHUS_MODEL_TIMEOUT` (120s) bounds a non-streaming request end to end.
  `TELEMACHUS_MODEL_IDLE_TIMEOUT` (60s) bounds the **gap between SSE events**, not
  the stream: a model still emitting may legitimately take minutes.
  `TELEMACHUS_MODEL_RETRIES` (1) — a retry costs tokens, so the default is one.
  An unparseable or zero value falls back to the default, never to 0.
- **The request runs under its own custodian**, and a timeout shuts that custodian
  down: killing the thread alone would leave the socket open.
- **Retry on a timeout, an unreachable endpoint, a 429 or a 5xx — never on a 4xx**,
  which is our own malformed request and would only spend the budget again.
  **A streaming call is never retried**: the caller has already been handed tokens
  and replaying would duplicate them in front of the reader.
- A **200 whose body is not JSON** (a proxy answering for the model) is a named,
  retryable error instead of an opaque read failure deep in the parser.

### One registry of named backends

The in-memory registry in `domain/exec/federation.rkt` is the single lookup a push
call resolves through, and it is filled from two places: `executors.json` at boot
(`source` `'config`) and the `executors` table's push rows (`source` `'db`).

- **DB push rows are loaded at boot** (`load-push-executors!`). They used to be
  registered only at CREATE time, so a restart silently turned a working backend
  into a name that resolved nowhere while `executor-known?` still said it existed.
- **`executors.json` owns its names**: a create that would shadow one is refused,
  and a clash found at boot is SKIPPED, counted and logged. Overriding the file
  from the database was the old behaviour and made a name resolve differently
  before and after a restart.
- **Retiring a push executor unregisters it immediately.** The row alone left it
  taking traffic until the next restart.
- A row whose sealed key will not open is skipped with a named warning rather than
  raising — one unopenable executor must not stop the instance booting, and the
  operator who rotated `TELEMACHUS_SECRET_KEY` needs to be told which.
- `GET /api/executors` lists each executor **once** (the DB row is the richer
  answer; the registry only contributes what `executors.json` owns) and every row
  carries `source`.

```sh
raco test test/model-transport-tests.rkt   # real sockets: a stall, a 503, a 4xx, a stalled stream
raco test test/model-routing-tests.rkt     # the refusals, the agent's real token counts, restart survival
```

Still deferred, deliberately: a second wire protocol (OpenAI chat completions is
what llama.cpp, ollama, vLLM and most gateways speak), per-backend capability
records, per-org provider credentials, and embeddings. **A team admin can point a
model role at any executor name**, including another org's, because
`executor-known?` does not filter by org — routing on `/api/ai/chat` and
`/api/agent` is operator-only, so this is the one gap left in that area.

## Tokens, `/health`, security headers, meta tags (issues #11–#13)

- **Tokens expire** (#13). `api_tokens.expires_at` carried nothing for a year;
  `issue-token!` now sets it (epoch seconds as text in the pre-existing TEXT
  column) and `resolve-token` refuses an expired row — the ONE place a bearer
  becomes a principal. Defaults: a session (login, bootstrap, member-add) 30
  days, a console-issued API token 90 days; `POST /api/tokens {"ttl": seconds |
  "never"}` overrides. A NULL expiry is "never", so tokens issued before the fix
  keep working — nobody is locked out by the upgrade. The listing reports
  `expires_at` and shows `status: "expired"` for a lapsed row that still says
  `active` in the table.
- **The token hash is peppered HMAC-SHA-256, stored `v1:<hex>`** (the prototype
  was bare SHA-1 with a compiled-in salt). The pepper is `TELEMACHUS_TOKEN_PEPPER`
  → `TELEMACHUS_SECRET` → a dev default the server WARNS about at boot. A legacy
  40-hex row still resolves and is rehashed on first use (`token-row`), so an
  upgrade signs nobody out; rotating the pepper signs everyone out at once, on
  purpose. `resolve-token` rechecks the stored hash in constant time after the
  indexed lookup — `constant-time=?` lives in `crypto.rkt` and SigV4 shares it.
- **`/health` is `{ok, multitenant}` and nothing else** (#11). Version, KDF, TLS and the
  codename moved to `GET /api/admin/status` (instance:manage). Do not put them
  back: the beta instance is a public front door.
- **The console runs under a per-request NONCE** (#11 part 2, then issue #27;
  `console-csp`): same-origin everything, `object-src 'none'`, `base-uri 'self'`,
  `frame-ancestors 'self'`, `form-action 'self'`, `img-src` also `data: blob:`,
  and **`script-src 'self' 'nonce-…'` — no `'unsafe-inline'`**, which is the
  directive that lets an injected script tag run. `style-src` keeps
  `'unsafe-inline'` on purpose: ~250 style attributes remain and injected CSS is a
  far smaller prize. Every other response still gets the baseline CSP with
  `'unsafe-inline'` — a plugin bundle page may carry inline script of its own.
- **All 141 inline handlers are delegated now** (issue #27), because a nonce
  cannot authorize an `onclick` attribute. A render writes
  `data-h-click="${H((el,ev)=>doThing(row.id))}"`; `H` parks the closure and
  returns its index; one document listener per event type dispatches. `this` is
  `el`, `event` is `ev`, and a handler returning `false` still gets
  `preventDefault()` — an `<a href="#">` would otherwise start jumping to the top.
  Arguments are real values instead of escaped strings, which also killed a
  quoting-bug class. **`data-h-…` must live in a TEMPLATE literal**: one handler
  sat inside `${live?'data-h-click="…"':'disabled'}`, a single-quoted string, so
  `${H(…)}` never interpolated and the funnel's submit button shipped dead. The
  browser test caught it; `test/console-tests.rkt` now pins both that and "no
  inline handlers", so the policy cannot silently regress. **The e2e gate proves the
  console runs under the policy**: a CSP violation is a console error and the
  gate fails on those. A Tier-B bundle that loads a CDN font or script is blocked
  by this policy — bundle assets must be served from the bundle.
  **Playwright under the policy:** `page.evaluate` works (it goes through CDP),
  but `page.waitForFunction` evaluates its predicate as a STRING and dies with
  "Refused to evaluate a string as JavaScript" — use a locator wait
  (`locator(sel, {hasText}).waitFor()`, `filter({hasNotText})`) instead. The
  funnel e2e (`test/e2e/funnel-l10n.sh`, now in CI) was the one that had it.
- **The funnel's chrome follows the funnel's locale.** The shell loads the
  `ui.*` catalog for the instance default before it knows about `?lang=`;
  `betaLandingView` re-fetches it (`loadCatalog`, `S.catLocale`) when the server
  answers in another locale. Without that the copy was Japanese and the sign-in
  link and "verifying…" stayed English — invisible to every server-side test,
  which is why the funnel e2e is in CI now.
- **Baseline security headers on every response** (#11), added in `handle` via
  `with-security-headers`: nosniff, `Referrer-Policy: strict-origin-when-cross-origin`,
  `X-Frame-Options: SAMEORIGIN` (the Tier-C funnel iframe is same-origin), and
  HSTS ONLY when `TELEMACHUS_TLS` is on — behind a TLS-terminating proxy, set it.
  A route that sets one of these itself wins. A console CSP is a separate audit
  (inline scripts); the download path already sends its own denying one.
- **The shell carries a meta description and Open Graph tags** (#12), rewritten
  per request from branding like the `<title>`: description = the tagline when
  set (whitespace-normalized), else a product default; `og:image` = the logo
  asset id when set. Same procedural `regexp-replace*` rule as the title — a
  string replacement would expand `&`.

## The sign-in screen: a repaint must not be empty

- **`authView()`'s inputs are always EMPTY, and the sign-in screen DOES get
  repainted while signed out.** `setLang()` and `applyBrand()` both call
  `render()`, so switching language after typing a username wiped it — an empty
  login field, mid-sign-in. Paint it through **`paintAuth()`**, which carries
  `lu`/`lp`/`lc`/`bu`/`bp` and the caret across the swap. Never go back to
  `app.innerHTML = authView()` at a call site.
- **`render()` fetches in TWO ROUNDS, and the shape is the dependency graph.**
  It used to be five sequential calls — `loadBranding`, `loadI18n`,
  `loadCatalog`, `refreshMe`, `/api/features` — which is invisible on localhost
  and was the whole of what made signing in feel slow. Round one is
  `Promise.all([loadBranding(), loadI18n(), refreshMe()])`: all three are
  independent, branding and the config are public, and whoami reads neither.
  Round two is what genuinely depends on round one — `loadCatalog` needs the
  locale `loadI18n` resolves, `/api/features` needs the principal `refreshMe`
  resolves — so those two go together. Measured at 300ms/call: sign-in 2283ms →
  1316ms, reload-with-token 1566ms → 633ms.
  - **Do not move a locale-SENSITIVE call into round one.** `api()` sends
    `X-Telemachus-Locale: S.lang`, so branding and whoami now go out with the
    PREVIOUS pass's locale. Neither reads it (branding is operator-authored;
    whoami is ids, permissions and policy numbers, and its `locale` field comes
    from the database, not the header) — but the next call added there might.
  - The theme still lands before the first paint: the whole round is awaited
    before anything reaches `#app`.
  - `stale()` is checked once per ROUND now rather than once per call. That is
    still every await boundary, which is what the generation counter needs.
- **The button enters a pending state (`ui.signingin`) the instant it is
  clicked**, because two rounds is still a visible beat on a real box. That is
  ALSO the double-submit guard: two `doLogin()` calls would mint two sessions and
  race two renders. `S.signingIn` is cleared in a `finally`, or a throw leaves
  the button disabled for ever with no way back but a reload.
- The auth→shell swap and the first paint after the blank window are faded
  (`.tmx-enter`, 150ms), with `@media (prefers-reduced-motion: reduce)` turning
  it off. `fadeIn` forces a reflow before re-adding the class, or a node that
  already carries it keeps the finished animation and nothing fades.
- **A browser test that switches language on the sign-in screen must put
  `localStorage.tmx_lang` back.** A stored choice legitimately wins over the
  instance default, so leaving one set silently broke the gate's later "console
  repaints in Japanese" assertion — the failure appears in an unrelated step.

## Session timeouts (issue #38, slice 70)

`domain/authz/session-policy.rkt` — an **idle** timeout and an **absolute** cap,
which is what the OWASP Session Management Cheat Sheet asks for. Migration
`0032-session-policy`; decisions SESS‑1…8 in `docs/design/decisions.md`.

- **Two clocks, because they answer different attacks.** Idle limits an
  unattended desk; absolute limits a stolen token that is being *used*, which
  never idles out. Shipped defaults are 30 minutes and 8 hours — the least
  disruptive ends of OWASP's own bands (15‑30 low risk, 4‑8 for a full-day
  worker). `null` on a field means no limit on that axis, spelled explicitly so
  "I did not set this" and "I turned this off" cannot look the same.
- **Only `kind = 'session'` is governed.** Migration 0032 added `kind`,
  `created_epoch` and `last_used_epoch` to `api_tokens`. A machine token is idle
  by design and idling one out is a silent outage, so `api` and `worker` are
  exempt. **`#:kind` on `issue-token!` defaults to the EXEMPT value**, so a caller
  who forgets it mints a token that behaves as tokens did before. `name` cannot
  stand in for the kind: a login is named "login" but a member added to a team
  gets a session with no name at all.
- **The epoch columns exist because `created_at` and `last_used_at` are TEXT
  `CURRENT_TIMESTAMP`, whose format differs by dialect** (SQLite
  `2026-08-21 04:16:09`, Postgres `…225696-07`). A rule comparing those would be
  invisible on one and wrong on the other — the same trap `LastModified` set in
  the S3 listing. Epoch seconds, like `expires_at` and the quota windows.
- **Two layers: an instance document and `session-policy:<org-id>`**, both in the
  `instance_settings` table branding and localization already share, so the org
  layer needed no migration. **An org may TIGHTEN and may never loosen** (SESS‑4):
  the effective value is the stricter per axis, and an org asking for a week of
  idle time gets the instance's thirty minutes rather than an error. This is
  deliberately asymmetric with branding, where the org's document wins whole —
  branding is cosmetic, this is a control and the instance owns the floor.
- **Enforced in `resolve-token` and nowhere else**, the one place a bearer becomes
  a principal. A lapsed row is revoked with a REASON (`expired-idle` /
  `expired-absolute`) so `GET /api/tokens` can show an operator why a session
  ended, and so a lapsed session cannot be revived by using it.
- **A corrupt stored document reads as the shipped posture, not as "no limits".**
  `normalize` fills every field from the defaults: a control must fail CLOSED.
- **The upgrade signs nobody out.** Existing rows default to `kind = 'api'` with
  NULL clocks, so nothing is enforced on them; they still expire on
  `expires_at`. Existing rows include customers' machine credentials, and
  breaking those is worse than letting old browser sessions run out.
- **The console's countdown is driven by the last REQUEST, never by pointer
  activity** (`S.lastReq`, stamped in `api()`). The server measures requests, so a
  mouse-driven timer would show a live session the server had already expired.
  "Stay signed in" issues a real request, which is exactly what refreshes the
  server's clock. The banner is wired with `addEventListener`, not `data-h-click`,
  because it lives in the static shell rather than in a render pass.
- **A live workflow run keeps a session alive** while its view is open: that poll
  is the console's only recurring request. Nothing else polls, so an idle console
  really does go idle.
- **The Admin card talks minutes and hours; the wire talks seconds.** An empty box
  means null, not zero.
- `GET`/`PUT /api/session-policy` (`instance:manage`);
  `GET`/`PUT`/`DELETE /api/org/session-policy` (`org:read` / `org:manage`).
  `GET /api/whoami` carries the caller's own effective policy, which is what the
  console counts down against.
- **The deliberate 400 for a bad policy is pinned in `server-smoke.sh`, NOT in the
  e2e gate** — that gate fails on any console error and a 400 logs one. Same call
  the branding theme's refusal made.

```sh
raco test test/session-policy-tests.rkt   # 19 cases: validation, tightening, both clocks, resolve-token
bash test/server-smoke.sh                 # the "session policy:" block, 13 assertions
TELEMACHUS_MULTITENANT=1 bash test/multitenant-demo.sh   # section 8c, the org layer
```

## Who may call: the peer gate (issues #40, #41)

- **Identity headers are a LOOPBACK convenience, not a login.** `current-principal`
  falls back to `X-Telemachus-User` / `-Team` when there is no bearer — and until
  this gate, an instance bound to a network address handed a full principal to
  anyone who could reach it, ahead of RBAC, scopes, the org gate and session
  policy, none of which run before a principal exists. `domain/authz/peer.rkt`
  owns the rule (`peer-trusted?`), so it is unit-testable without a live server;
  `TELEMACHUS_TRUSTED_HEADER_PEERS` names a reverse proxy that may assert
  identity, and nothing is trusted for looking private (10.x is somebody else's
  network).
- **`POST /api/bootstrap` is loopback-only too**, or gated by
  `TELEMACHUS_BOOTSTRAP_SECRET` (`X-Telemachus-Bootstrap`, compared in constant
  time). Before this, a fresh instance on a LAN belonged to whoever called first.
  The refusal names both paths — a bare 403 on a fresh instance reads as a broken
  build.
- The smokes run on localhost, so they exercise the ALLOWED side; the refusal is
  pinned in `test/peer-tests.rkt` instead. A smoke on the same host can never be
  a stranger, which is exactly why the gap survived so long.

## Plugins: directories, pages and failures (issues #44, #45, #48)

- **`TELEMACHUS_PLUGINS` is a `:`-separated LIST, searched after the built-in
  directory.** It used to name the ONE directory to load, so pointing it at a
  plugin of your own silently removed doc-pipeline and every other shipped one. A
  literal `-` entry drops the built-ins for a deployment that means to.
- **A plugin's pages come from where the loader loaded it** (`plugin-dir`), not
  from `impl-root/plugins`: a plugin outside the checkout used to serve its tools
  and routes while 404-ing every page it had. The directory is kept beside the
  listing, never inside it — the listing is JSON on an API and the server's
  filesystem layout is nobody's business. The listing does carry `bundle: true/false`.
- **A plugin that fails to load is REPORTED**: `plugin-failures`, `failed` on
  `GET /api/plugins`, a `WARNING: N plugin(s) FAILED` block at boot, and
  `TELEMACHUS_PLUGINS_STRICT=1` to refuse to start. It used to be one log line
  among sixty, which is how a stale `plugins/*/compiled/*.zo` after the 9.3 bump
  left `example-tools` missing and the instance "healthy".
- **Two plugins with one id: the first wins and the second is a failure**, rather
  than a silent shadow.
- `raco make server/main.rkt` does NOT reach a plugin's entry module (it is
  `dynamic-require`d), so a Racket upgrade leaves stale `plugins/*/compiled/`
  bytecode that fails to load. `rm -rf plugins/*/compiled` after a version bump.
- **A SYMLINKED plugin directory is OPT-IN: `TELEMACHUS_PLUGINS_LINKS=1`.**
  Symlinking a downstream plugin into `plugins/` is the normal way to develop one,
  and the only way for a plugin that requires Telemachus modules by relative path
  (`../../domain/authz/authz.rkt`) to resolve them — `TELEMACHUS_PLUGINS` cannot,
  because the relative path only lands on `domain/` from two levels under
  `refimpl/racketmaximus/`. But `plugins/` is inside the checkout, so an
  always-on link would join every test run and every generated document. Three
  things now keep a local link from leaking:
    1. `load-plugins!` takes `#:skip-links?`, and `server/main.rkt` skips links
       unless `TELEMACHUS_PLUGINS_LINKS` is set.
    2. `cli/telemachus-docs.rkt` ALWAYS skips them — `docs/reference/` is
       committed and CI fails on drift, so one developer's link would otherwise
       write a customer's routes into the repository and break the gate for
       everyone without it. This was observed: fixing the link's `PLTCOLLECTS` made
       it load, and the drift gate immediately reported `api.md plugins.md
       strings.json`.
    3. All nine server-booting harnesses `unset TELEMACHUS_PLUGINS
       TELEMACHUS_PLUGINS_LINKS` beside the `export PLTCOLLECTS` line they already
       had. They are unset rather than merely unused because a developer exports
       them in their own shell, and `server-smoke.sh` asserts `"failed":[]` — with
       `PLTCOLLECTS` reset the downstream plugin's own collections are gone, so it
       fails and the suite fails with it.
- **A downstream plugin also needs its OWN collections on `PLTCOLLECTS`**, or it
  fails with `collection not found` while the instance otherwise looks healthy.
  The devShell sources an optional, gitignored `.env.local` AFTER setting
  `PLTCOLLECTS`, so it can append; see `.env.local.example`. The plugin's link
  itself is gitignored — it belongs to its own repository.

## Secrets at rest (issue #19)

`domain/authz/secretbox.rkt` — AES-256-GCM over libcrypto EVP, the same FFI seam
`sha2.rkt` uses, pinned to NIST's GCM vectors. Operator runbook:
`docs/ops/secrets-at-rest-runbook.md`.

- **Three values cannot be hashed** and so are sealed instead:
  `users.totp_secret`, `repo_credentials.secret_key`, `executors.secret_key`.
  Everything else (passwords, API tokens) stays a hash.
- **The claim is narrow and deliberate: it defends a DUMP, not a HOST.** The key
  is in the environment, so anyone running as the server can read it; a backup,
  a replica or a volume snapshot travels without it. The old note in `creds.rkt`
  argued encryption "moves the secret from one file an attacker already has to
  another" — true of a host, false of the dump, which is the case that happens.
- **`TELEMACHUS_SECRET_KEY` is NOT `TELEMACHUS_SECRET`.** Rotating the pepper
  signs everyone out (a fine emergency action); if it also sealed secrets, that
  same action would destroy them. 64 hex = the key; anything else is a
  passphrase, stretched with PBKDF2, never truncated.
- **No key configured = plaintext, and that is supported** — it is the "trusted
  database" position, now visible (`secrets:` in the boot line and in
  `GET /api/admin/status`) rather than inherited.
- **Storage is `enc:v1:<key-id>:<nonce>:<ct+tag>`; anything else is plaintext
  and reads as-is**, so adopting a key needs no migration. `cli/telemachus-secrets.rkt`
  (`status` / `keygen` / `rewrap`) seals existing rows and rotates
  (`TELEMACHUS_SECRET_KEY_OLD` reads, the current key writes). Never do this at
  boot: a mistyped key would seal every row with a key nobody has.
- **The AAD is `<table>.<column>:<row-id>`**, so a ciphertext moved between rows
  does not open. Adding a new stored secret means adding a row to `SECRETS` in
  the CLI as well as wrapping at the seam.
- **A sealed value that will not open RAISES.** Never make it fall back to "" —
  an empty TOTP seed silently disables someone's second factor.
- **A TOTP seed is the one credential its owner cannot rotate by using it**, so
  it is revocable now: `DELETE /api/2fa` (self) and `DELETE
  /api/admin/users/:id/2fa` (`instance:manage`), both audited `user.2fa.reset`.
- **Recovery codes are the way back in** (issue #26, migration `0030`). Ten
  single-use codes, issued BY `enable-2fa!` itself — handing out a second factor
  without one is how people lock themselves out. They are **hashed** (`hash-token`
  over `recovery:<normalized>`), because unlike the seed a code is compared, not
  computed from; rotating the token pepper therefore retires outstanding codes
  along with outstanding tokens. Matching forgives case and dashes (they are typed
  off paper). Spending is the same statement as matching (`UPDATE … WHERE used_at
  IS NULL RETURNING id`), so two sign-ins cannot both spend one; a spent row is
  KEPT so "already used" stays distinguishable. `reset-2fa!` deletes them with the
  seed. `POST /api/2fa/recovery-codes` re-issues (replaces, never tops up — a set
  on paper should be the whole truth); `GET` returns only `remaining`.
- The key is memoized by its **raw value**, not by the variable name — a cache
  keyed on the name pins whatever was set first, which breaks any test that sets
  a key and any process handed a rotated environment.

```sh
raco test test/secretbox-tests.rkt        # NIST vectors + the stored-form rules + the three seams
```

## The audit log's ordering key (issue #47)

`at` is `CURRENT_TIMESTAMP` — one-second resolution on SQLite — and `id` is a
random UUID, so entries written in the same second came back in an order unrelated
to what happened. `audit_log.at_us` (migration `0033-audit-seq`) is epoch
MICROSECONDS, and `audit-stamp!` bumps it so it strictly increases within the
process: milliseconds were tried first and a loop of five writes landed in the
same one. `audit-list` orders `at DESC, at_us DESC, id DESC` — `at` first because
it is right for rows written before the column existed.

**`test/fold-tests.rkt` builds a half-migrated database** (the world before the
0022 fold) and runs TODAY'S code against it, so any later migration the code
depends on has to be in its `also-required` list. A real instance never sees a
partial schema; that test does.

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

### The console's theme (integrator theming)

The branding document carries a `theme`, and it is **the funnel's token vocabulary**
(`brand brandInk bg surface ink muted radius mode fontBody`) on purpose: a customer's
palette is written once and worn by both. Per-org for free — it is the same
`branding:<org-id>` document, so TEN‑2d's Host routing themes a company's console
before anyone signs in.

- **Tokens are values, never declarations**, so each is validated against a narrow
  pattern (hex colour, `<n>px`, an enumerated font/mode) rather than escaped.
  **An unknown token is a 400**, not a silent drop — a token that does nothing is
  how a customer concludes the theming is broken.
- **Contrast is ENFORCED server-side** (`theme-problem`), not warned about like the
  funnel editor does: this is the screen people sign in on, and an instance that
  themed its own sign-in link into invisibility has no way back through the UI.
  WCAG AA — 4.5:1 for text/muted/panel/button label, 3:1 for brand on ground.
- **The button label is checked against the MIXED ground, not `brand`.** The console
  paints `--accent2` as `color-mix(brand, <the dark side>, 50%)`; `BUTTON-MIX` in
  branding.rkt must stay equal to that percentage, or the gate judges a colour
  nothing draws.
- **Which side is "dark" is MEASURED, not read from `mode`** (`darker` by luminance):
  an operator who sets light colours while `mode` still says dark should get a
  legible button, not a refusal about a token they did not think they set.
- **The read side is forgiving where the write side refuses**: an invalid stored
  token falls back to the shipped one, because `GET /api/branding` is the PUBLIC
  sign-in screen and must never 500.
- `applyTheme` in the console maps tokens → CSS custom properties on every render
  pass (branding is public, so the sign-in screen is themed too); `--panel2`,
  `--line`, `--accent2/3` are DERIVED with `color-mix`, so a theme stays the few
  decisions an integrator actually wants to make. A browser without `color-mix`
  drops those and keeps the stylesheet's values.
- The e2e gate proves the mapping end to end (live preview, then a reload reading
  the stored theme). **The server's 400 for an illegible theme is pinned in
  server-smoke, NOT in the e2e gate** — that gate fails on any console error, and a
  deliberate 400 logs one.

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

No screenshots: sign-in + branding → bootstrap → notes → documents create **and
edit** → repository upload with byte-identical download → search → **the document
pipeline** (upload → "Run workflow…" → derived documents → "Processed by" → an
Automation firing on an upload; against the scripted mock model, see slice 59)
→ workflows/jobs/usage → Admin > Branding round-trip → sign out/in. It also fails on
**any uncaught page/console error** and **any 5xx**, which is how a broken write path
gets caught even when no assertion names it. The screenshot *tours* do not assert and
will photograph a broken page — use this to gate a deploy.

## Working with `gh`

- **`gh run list --json databaseId --template` prints the id in SCIENTIFIC
  NOTATION** (`3.9375597644e+10`), because the template renderer treats it as a
  float. Passing that to `gh run watch` fails with `HTTP 404` and `gh` still
  exits 0, so a watch that never watched looks exactly like a watch that passed.
  Use `--jq '.[0].databaseId'` instead, which prints the integer.
- `gh issue view <n>` without `--json` fails on this repo with a Projects-classic
  deprecation error from the GraphQL API. `--json number,title,body,comments`
  with a `--template` works.

## Git

- Commit/push only when asked. Branch before committing on the default branch.
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
