# Documentation generation

*Decided 11 Sep 2026 (DOCGEN‑1…6). **Built** 13 Sep 2026 (slice 60): `cli/telemachus-docs.rkt`, `server/routes.rkt`, the described permission catalog, `docs/reference/`, the CI drift gate, and `strings.json` in the catalogs. See **As built** at the end.*

The platform already knows what it is. Every tool declares an OpenAI-compatible
schema through `define-tool`; every workflow is a validated spec; the permission
catalog and the built-in roles are data; plugins announce their name, version and
what they carry at load. The documentation for all of that is currently either
absent or written by hand — and hand-written reference documentation is wrong the
week after it is written.

This design generates the reference from the source of truth, commits the output,
and gates drift in CI. It is the last unbuilt platform requirement in the FSD, and
it is what the **Backend APIs & protocols** and **SDK contract** items are blocked on.

## What is generated, from what

| Page | Source of truth | Already machine-readable? |
|---|---|---|
| `tools.md` — the tool catalog | `all-tool-schemas` (`domain/tools/dsl.rkt`) | **Yes.** name, description, parameters, permission |
| `workflows.md` — shipped + plugin workflows | `domain/flow/spec.rkt` + plugin `workflows` | **Yes.** the spec IS the contract (WF‑9) |
| `permissions.md` — catalog + role matrix | `domain/authz/permissions.rkt` | **Partly.** perms and roles are data; **no descriptions** |
| `api.md` — the HTTP surface | `route` in `server/main.rkt` | **No.** 84 `cond` clauses; no registry, no descriptions |
| `plugins.md` — seams a plugin may fill | plugin loader + the four seam contracts | **Partly.** manifest is data; seam contracts are prose |
| `sdk.md` — `define-tool`, `define-workflow`, blob store, onboarding provider, beta SDK | the modules' own doc comments | **No.** narrative, hand-written |

The first two are pure generation. The third and fourth force two small changes to
the source of truth so that it *becomes* generable — see **The two gaps**. The
last two are hybrid: a hand-written narrative with generated tables inside it.

## Pipeline

```
sources ──describe──▶ model (jsexpr) ──render──▶ docs/reference/*.md ──extract──▶ locales/*.json (doc.*)
   │                                                     │                                │
   │                                                     ▼                                ▼
   │                                          committed, reviewed in PRs         translated by the Manager
   │                                                     │                                │
   └──────────── CI: regenerate and diff ◀───────────────┘                render docs/reference/<locale>/
```

- **`telemachus-docs`** is a CLI in the `cli/` pattern, like `telemachus-localize`.
  `describe` evaluates the modules (as `build-l10n-review.py` already does for
  `beta.rkt`, so it runs inside `nix develop`) and emits one JSON model.
  `render` turns the model into Markdown. `check` regenerates and fails on a diff.
- **Output is committed**, not built at release: a PR that changes a tool's
  parameters shows the documentation change in the same diff, and a reviewer sees
  it. This is the same call the localization gate made (LOC‑4): the artifact lives
  in git, the tool keeps it honest.
- **Deterministic.** Same sources, byte-identical output — sorted keys, no
  timestamps, no environment. Otherwise the drift gate cries wolf.
- **No site generator.** Plain Markdown in `docs/reference/`, readable on GitHub
  and in an editor. An HTML site is a later, separate concern; pulling in a static
  site generator now would be exactly the dependency spice kitchen the project
  refuses.

## Localizable by construction

The localization design (§Documentation) asks for doc pages to be content with a
source locale and translated variants, tracked with the same source-hash
staleness as UI strings. Generated docs get that for free if the generator treats
prose and structure differently:

- **Structure is not translated.** Schemas, parameter names, route paths, role
  matrices, code blocks: rendered identically in every locale.
- **Prose is a message.** Every description the generator emits carries a stable
  id — `doc.tool.repo_extract_text.description`, `doc.perm.localization:review` —
  and the rendered page is itself a **JSON surface** for the extractor
  (`docs/reference/strings.json`, emitted alongside), exactly as
  `static/ui-strings.json` is for the console. So `extract` folds `doc.*` into
  `en.json`, the Manager drafts and reviews them like any other namespace, and
  `render --locale ja` writes `docs/reference/ja/` from the catalogs. A tool whose
  description changes goes **stale** in every language automatically.

One namespace, one Manager, one gate, three surfaces (Racket, console, docs).

## The two gaps it forces open

Generating the API reference and the permission catalog is impossible today for
the same reason: the truth is not declared, only enacted.

**Routes.** `route` is 84 `(and (GET? m) (equal? segs '("api" "x")))` clauses. A
generator can regex them, but it cannot learn the permission a route requires,
what it returns, or whether it is public — and a regexed reference is a lie that
looks authoritative. The fix is a **declarative route table**: each entry is
`(method path handler #:perm #:public? #:doc)`, `route` dispatches over it, and the
table is the documentation. Public-ness becomes *declared*, which also turns the
"this endpoint must stay public" comments scattered through `main.rkt`
(`/api/config`, `/api/branding`, `/api/i18n/catalog`, `/api/beta/asset/<id>`) into
something CI can assert. This is the concrete form of the FSD's "stable surface
between swappable frontends and backends."

**Permissions.** `"localization:review"` is a string in a role list. It needs one
line of description to be documentable, and the description belongs next to the
declaration, not in a parallel table that drifts: `(permission "localization:review"
"Approve or send back a colleague's translation")`. The role matrix is then
generated, and a permission with no description is a **build error**, the same
way a console key in no review group is.

Both are mechanical refactors with no behaviour change, and both are worth doing
even without this design.

## Data shapes (backend-neutral)

The model is a JSON document; no tables, nothing persisted. It exists only as the
generator's intermediate form and as the thing a second backend would have to
produce to be documented the same way.

```
model = {
  version:  "0.1.0",                        # app-version, the only non-source input
  tools:    [{name, description, permission, source, parameters:{...json-schema}}],
  workflows:[{slug, version, source, description, steps:[{id, kind, ...}]}],
  permissions: [{name, description, tier: team|org|instance}],
  roles:    [{name, tier, permissions:[...]}],
  routes:   [{method, path, permission|null, public: bool, description}],
  plugins:  [{name, version, tools:[...], workflows:[...], seams:[...]}],
}
```

Every `description` in the model is also emitted to `docs/reference/strings.json`
under its stable id, which is what makes the model the localization source too.

## Contract (any backend implements)

```
DocSource:                        # what a backend must be able to say about itself
  describe() -> model

DocGen:                           # the generator, backend-agnostic once it has a model
  render(model, locale) -> {path -> markdown}      # locale resolves prose via the catalogs
  strings(model) -> {id -> english}                # the JSON surface for `extract`
  check(model, committed_dir) -> {drift: [path…], exit_code}
```

`refimpl/racketmaximus` implements `describe` by evaluating its own modules. A
frontend or alternative backend documents itself by producing the same model.

## CI gate

```
telemachus-docs check                     # regenerate → diff against docs/reference → fail on drift
telemachus-localize check … docs/reference/strings.json --required en
```

Two gates, one shape: the reference must match the code, and its prose must be in
the catalog. A PR that adds a tool without a description fails the first; a PR
that changes a description makes its translations stale in the second, which is
advisory (LOC‑4) — the English is required, the rest is coverage.

## Bootstrapping plan

1. ✅ **Route table + permission descriptions** (the two gaps). Mechanical; no
   behaviour change; `server-smoke.sh` is the proof nothing moved.
2. ✅ **`telemachus-docs describe`** over tools, workflows, permissions, routes,
   plugins. Emit the model.
3. ✅ **`render`** for the four generated pages; commit `docs/reference/`; add the
   drift gate to CI.
4. ✅ **`strings.json`** + the `doc.` namespace (249 messages, in `en.json`);
   `render --locale` works from the catalogs. *Drafting `ja` with the Manager
   is a run of the tool, not code — it has not been done yet.*
5. ✅ `sdk.md` and `plugins.md` as narrative-plus-tables.

## As built

- **The route table is data** (`server/routes.rkt`, no database, no server):
  `(R method path handler-key #:auth #:perm #:feature #:doc)`. `main.rkt` binds
  keys to procedures in `HANDLERS` and refuses to boot if either side names
  something the other lacks — so an endpoint cannot exist undocumented, or be
  documented without existing. Patterns are literal segments, `:name`, and
  `*name` for the rest of the path; first match wins in list order, exactly as
  the old `cond` did. The permission an entry carries is what the handler
  ENFORCES; `auth` is how it authenticates (public, bearer, provision,
  superadmin, org-admin).
- **A permission with no description is a load error**, checked when
  `permissions.rkt` is instantiated over every built-in role's grants; the docs
  CLI checks every route's permission the same way.
- **Determinism cost one real decision**: a Racket `hasheq`'s iteration order is
  not stable across processes, so nothing in the generator calls `write-json` on
  a hash — `json-out` writes sorted keys, tables sort their rows, and two
  renders in two processes diff empty. The drift gate would otherwise cry wolf.
- **Materialization raced** once the console fired two lookups in parallel; the
  plugin-workflow insert is `ON CONFLICT DO NOTHING` now. The e2e gate found it.
- The generator EVALUATES the plugins (`load-plugins!`), so it runs inside
  `nix develop`; `init!` hooks that register a blob store or an onboarding
  provider are harmless there.

## Decisions (confirmed 11 Sep 2026)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DOCGEN‑1** | Where output lives | **Committed under `docs/reference/`, drift-gated** · vs generated at release · vs generated on demand | A committed reference shows doc changes in the PR that caused them. |
| **DOCGEN‑2** | How routes become declarable | **A declarative route table that `route` dispatches over** · vs annotating the `cond` · vs regexing it | Only the first gives permission, public-ness and description a home CI can check. |
| **DOCGEN‑3** | Where permission descriptions live | **Beside the declaration**, missing one is a build error · vs a parallel table | A parallel table drifts; a build error cannot. |
| **DOCGEN‑4** | What is localized | **Prose only, via a `doc.` namespace and a JSON surface** · vs whole pages as documents | Structure is identical in every language; only descriptions are messages. |
| **DOCGEN‑5** | Rendering | **Plain Markdown, no site generator** · vs an HTML site now | Readable on GitHub today; a site is a separate decision and a dependency. |
| **DOCGEN‑6** | Determinism | **Byte-identical output from identical sources; version is the only external input** | The drift gate is useless otherwise. |
