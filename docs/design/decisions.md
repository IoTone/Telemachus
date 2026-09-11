# Kickoff Decisions

The decisions needed to start building, compiled from the **Decisions to confirm**
sections of the five design docs. Each has a **recommendation** (bold) and an ID
so choices can be recorded tersely.

**Legend:** 🔑 = genuinely *gates kickoff* (decide now). Everything else has a safe
default that can be revisited when we build that subsystem.

**Fast path:** accept all recommendations, or override by ID (e.g. "defaults except
RBAC‑2 and SCHED‑5"). Choices get recorded in the **Decision log** at the bottom.

---

## A. Tenancy (cross-cutting)

| ID | Decision | Options — **rec** | Why it matters |
|---|---|---|---|
| 🔑 **TEN** | Isolation boundary | **Team = boundary, single implicit org** · vs multi-org now | Changes every isolation check + whether `org_id` exists in schema. Additive later is cheap; retrofitting multi-org isn't. |
| 🔑 **TEN‑2** | Multi-org tenancy (slice 45) | **Org above team, behind a flag** · vs instance-per-tenant only | ⚠️ **Supersedes TEN.** "Additive later is cheap" was the bet TEN made — TEN‑2 is that addition, cashed in. |

## B. RBAC & Teams

| ID | Decision | Options — **rec** | Why / when |
|---|---|---|---|
| 🔑 **RBAC‑1** | Built-in roles | **owner / admin / member / viewer** (+guest later) | Seeds the roles table + every permission check. |
| **RBAC‑2** | Custom per-team roles in v1 | **Yes (cheap given the tables)** · vs built-ins only | Low impact; tables support either. |
| **RBAC‑3** | Cross-team sharing | **Within-team shares only in v1** · cross-team later | Scopes the `resource_grants` check. |
| 🔑 **RBAC‑4** | API token scope model | **issuer-perms ∩ explicit scopes** · vs fixed catalog | Defines token issuance + enforcement; hard to change later. |
| 🔑 **RBAC‑5** | Operator vs owner | **Distinct instance `operator`** · vs first-team-owner is operator | Shapes first-run bootstrap. |

## C. Persistence (gates the first build)

| ID | Decision | Options — **rec** | Why / when |
|---|---|---|---|
| 🔑 **DB‑1** | Migration mechanism | **Thin runner in `db-kit`: ordered Racket steps, per-dialect SQL, `schema_migrations` table** · vs raw SQL files · vs external lib | First slice creates tables; this keeps sqlite→Postgres a swap. |
| 🔑 **DB‑2** | Primary key strategy | **UUID (text)** · vs integer autoincrement | UUIDs survive federation/merge and avoid sqlite/pg sequence divergence; touches every table. |

## D. Quotas *(can ride defaults — built after RBAC)*

| ID | Decision | Options — **rec** |
|---|---|---|
| **QUOTA‑1** | v1 metered dimensions | **AI-first: tokens / requests / concurrency / rate** (defer storage, tasks) |
| **QUOTA‑2** | On exceed | **Budgets → hard reject; rate/concurrency → enqueue-and-delay** |
| **QUOTA‑3** | Windows | **Daily + monthly budgets, 60s rolling rate; UTC** (team override later) |
| **QUOTA‑4** | Team vs user | **`min(team, user)` caps, meter both** |
| **QUOTA‑5** | Token estimate | **Heuristic (chars/4) in v1**, tokenizer later |
| **QUOTA‑6** | Default limits | **Conservative default policy + small/med/large presets** |

## E. AI Workload Scheduler *(can ride defaults — built after quotas)*

| ID | Decision | Options — **rec** |
|---|---|---|
| **SCHED‑1** | Executor kinds v1 | **`local-model` only**, contract ready for `remote-model` |
| **SCHED‑2** | Job requirements | **`{model, est_tokens}`**, add compute `class` when CPU/HPC land |
| **SCHED‑3** | Remote transport | **Defer — interface only** (RI is local; no wire yet) |
| 🔑 **SCHED‑4** | Job durability | **Persisted `jobs` table from the start** · vs in-memory *(mild gate: schema)* |
| **SCHED‑5** | Fairness | **Priority + FIFO in v1** (policy seam ready for weighted-fair) · vs weighted-fair now |
| **SCHED‑6** | Governor scopes | **global + per-executor + per-team** v1; per-user later |
| **SCHED‑7** | Preemption | **Cancelable always; preemptible later** |

## F. Localization *(gates only if we run the localization slice early — recommended)*

| ID | Decision | Options — **rec** | Why / when |
|---|---|---|---|
| 🔑 **LOC‑1** | Catalog format | **ICU-MessageFormat in JSON** · Fluent · gettext PO | Defines the localizer + CLI + every catalog file. ICU = power + ubiquity; Fluent = strongest for complex l10n; PO = deepest tooling. |
| **LOC‑2** | v1 surfaces enforced | **UI + API + tool descriptions** first; emails/docs/plugins phased | Scopes the bare-literal scanner. |
| **LOC‑3** | Message ids | **Named namespaced keys** (`documents.editor.save`) · vs source-hash | Catalog maintainability. |
| **LOC‑4** | Release gate | **Advisory in v1** (only `en` 100% is hard-required) · vs coverage-blocking now | How strict CI is at launch. |
| **LOC‑5** | AI drafting | **Opt-in per locale**, via a new **`translation` model role** (fallback `utility`) · vs on-by-default | Auto-draft behavior + which model. |
| **LOC‑6** | Doc generation | **Separate follow-up design doc** · vs fold in now | Keeps localization doc focused. |
| **LOC‑7** | Default locale owner | **Instance operator** (`instance:manage`) + an off switch for negotiation · vs per-team · vs browser-only | Decides what an anonymous visitor is answered in. Browser-only was the old behaviour and made a Japanese instance impossible. |

---

## What actually gates kickoff

Only the 🔑 rows: **TEN, RBAC‑1/4/5, DB‑1/2**, plus **LOC‑1/2/3** if we run the
localization slice early. The rest can ride defaults and be confirmed when we reach
that subsystem.

## Proposed first two build slices (once 🔑 are set)

1. **RBAC + persistence** — `db-kit` migration runner + `users / teams /
   memberships / roles / role_permissions / api_tokens / resource_grants /
   audit_log` tables + `AuthzService`, wired into the engine's `#:exec` permission
   check.
2. **`en` externalization + `telemachus-localize` CLI** — mostly independent;
   delivers the "flag unlocalized strings in CI" win early and proves the dogfood
   loop.

---

## Decision log

Status: **LOCKED 2026-08-13.** `→ default` = the recommendation above was accepted.

| ID | Recommendation (short) | Chosen |
|---|---|---|
| TEN | team-boundary, single org | ⚠️ **superseded by TEN‑2** (was: one legal entity, multitenancy a non-goal) [^1] |
| TEN‑2 | org above team, behind `TELEMACHUS_MULTITENANT` | ✅ built (slice 45) — several companies on one instance [^3] |
| TEN‑2a | org admin **manages but does not read** team data | ✅ built — least privilege; a company admin who needs data joins the team, audibly |
| TEN‑2b | `username` instance-global (email); `teams.slug` per-org | ✅ built — keeps `/api/login` unambiguous with no org selector |
| TEN‑2c | a user belongs to **exactly one** org | ✅ built — enforced at the `add-member!` seam |
| TEN‑2d | per-org branding / subdomain routing | ⬜ open — `orgs.slug` exists, routing does not |
| TEN‑2e | per-org model endpoints (BYO inference) | ⬜ open — executors are instance-scoped |
| TEN‑2f | provisioning is an **API** operation; explicit slug = natural key (`409` on re-run), derived slug suffixes | ✅ built — a pipeline must converge; a silent duplicate company is worse than a refused call |
| TEN‑2g | **no `DELETE /api/orgs`** — suspend is the terminal API state, erasure is a SQL maintenance procedure | ✅ decided — the cascade spans teams, users, tokens, blobs and audit |
| RBAC‑1 | owner/admin/member/viewer | ✅ default |
| RBAC‑2 | allow custom per-team roles | ✅ default |
| RBAC‑3 | within-team shares only (v1) | ✅ default |
| RBAC‑4 | token = issuer-perms ∩ scopes | ✅ default (first option) |
| RBAC‑5 | distinct instance operator | ⚙️ **amended** — first team owner **bootstraps as** operator, but operator is a **distinct super-admin tier** [^2] |
| DB‑1 | migrations runner in db-kit | ✅ default |
| DB‑2 | UUID (text) PKs | ✅ default |
| QUOTA‑1 | AI dims first | ✅ default |
| QUOTA‑2 | reject budgets / delay rate | ✅ default |
| QUOTA‑3 | daily+monthly+60s, UTC | ✅ default |
| QUOTA‑4 | min(team,user), meter both | ✅ default |
| QUOTA‑5 | chars/4 estimate | ✅ default *(assumed — not explicitly called)* |
| QUOTA‑6 | default policy + presets | ✅ default |
| SCHED‑1 | local-model only | ✅ default |
| SCHED‑2 | {model, est_tokens} | ✅ default |
| SCHED‑3 | defer remote transport | ✅ default |
| SCHED‑4 | persist jobs table | ✅ default |
| SCHED‑5 | priority+FIFO (v1) | ✅ default |
| SCHED‑6 | global+executor+team scopes | ✅ default |
| SCHED‑7 | cancelable, not preemptible | ✅ default |
| LOC‑1 | ICU-JSON catalogs | ✅ default |
| LOC‑2 | UI+API+tools first | ✅ default |
| LOC‑3 | named namespaced ids | ✅ default |
| LOC‑4 | advisory coverage (v1) | ✅ default |
| LOC‑5 | opt-in AI draft, translation role | ✅ default |
| LOC‑6 | separate doc-gen design | ✅ default |
| LOC‑7 | **instance** operator sets the default locale, and may turn per-request negotiation off | ✅ built — `Admin › Localization`; the sign-in screen belongs to no team and cannot be configured by the visitor |
| ONB‑1 | instance-per-tenant (hosted) | ✅ built (slice 19) |
| ONB‑2 | provider auth via **provision token**, no operator user | ✅ built |
| ONB‑3 | both `/api/provision` + boot-env seeding | ✅ built |
| ONB‑4 | magic-link activation | ✅ built |
| ONB‑5 | 2FA optional at activation | ✅ default |
| ONB‑6 | 72h activation TTL, resendable | ✅ built |
| ONB‑7 | suspend = `402` + read-only, data retained | ✅ built |
| ONB‑9 | the form is the config: `required` is **enforced** from it, an unconfigured field is **never demanded**, and `email` is the one **structural** field | ✅ built — both halves were bugs; validation vocabulary is `required`/`digits`/`minlength`/`maxlength` and deliberately **not** a regex on a public endpoint |
| ONB‑8 | funnel copy localizes via an `i18n` **overlay on the experience document**; translation is **presentation only** | ✅ built — an overlay matches fields by key and takes only `label`/`options`, so the submitted body and the anti-abuse config are identical in every language by construction |
| ONB‑8 | 30-day retention then deprovision + export | ⏳ control-plane |
| WF‑1 | workflow **spec is the contract**; `define-workflow` compiles to it | ✅ decided [^4] |
| WF‑2 | binding sublanguage **frozen** (references + fixed predicates, no eval) | ✅ decided |
| WF‑3 | borrow CNCF Serverless Workflow **vocabulary**, claim no conformance | ✅ decided |
| WF‑4 | durability unit = **one scheduler job per step** | ✅ decided |
| WF‑5 | human `approve` gate in v1 | ✅ decided |
| WF‑6 | visual interface **read-only** at v1 | ✅ decided |
| WF‑7 | `workflows:{read,write,run}`; org admins get `read` only (TEN‑2a) | ✅ decided |
| WF‑8 | plugin steps run in process, as tools do | ✅ decided — revisit as hardening |
| WF‑9 | the spec is a **public contract** (documented, versioned, publishable) | ✅ decided |
| WF‑10 | unknown fields in a submitted spec are **rejected** | ✅ decided |

See [saas-onboarding.md](saas-onboarding.md) for the full flow. ONB‑2 refines the
doc's "operator service token" to the simpler **provision token** so the seeded
instance holds exactly one user (the owner); provider actions
(provision/suspend/resume) authenticate with that per-instance secret.

## Documentation generation (DOCGEN) — **decided 11 Sep 2026: recommendations adopted**, see [documentation-generation.md](documentation-generation.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DOCGEN‑1** | Where generated docs live | **Committed under `docs/reference/`, drift-gated in CI** · vs built at release · vs on demand | The PR that changes a tool shows the doc change. |
| **DOCGEN‑2** | Making routes declarable | **A declarative route table `route` dispatches over** · vs annotating the `cond` · vs regexing it | Only a table gives permission, public-ness and description a home CI can assert. |
| **DOCGEN‑3** | Permission descriptions | **Beside the declaration; a missing one is a build error** · vs a parallel table | A parallel table drifts. |
| **DOCGEN‑4** | What gets localized | **Prose only, `doc.` namespace, a JSON surface for `extract`** · vs whole pages as documents | Structure is identical in every language. |
| **DOCGEN‑5** | Rendering | **Plain Markdown, no site generator** · vs an HTML site now | No new dependency; readable on GitHub today. |
| **DOCGEN‑6** | Determinism | **Byte-identical output from identical sources** | The drift gate is meaningless otherwise. |

## Knowledge graph (KG) — **decided 11 Sep 2026: recommendations adopted**, see [knowledge-graph.md](knowledge-graph.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **KG‑1** | Entity types | **Open vocabulary + shipped starter set; plugins may extend** · vs closed schema · vs fully open | Closed refuses real things; unbounded is unqueryable. |
| **KG‑2** | Scope | **Team-scoped, org gate at step 0** · vs instance-wide | A company's knowledge is not the product's. |
| **KG‑3** | Fact visibility | **Visible if ANY source mention is readable; snippets filtered per row** · vs all sources must be readable | All-sources hides a public fact because a private note repeats it. |
| **KG‑4** | Dedup | **`(type, name_norm)`; no cross-type merging in v1** · vs embedding-based entity resolution | Cross-type merging is where knowledge graphs die. |
| **KG‑5** | Query language | **None; `hops ≤ 2` from a named entity** · vs Cypher/Gremlin/SPARQL | No dependency, no parser, no injection surface, no demand. |
| **KG‑6** | Visualization | **Lists with citations; hand-drawn SVG neighbourhood later if used** · vs a graph-viz library now | A dependency and a week of tuning before anyone asks a question. |
| **KG‑7** | Extraction model | **`utility` role, opt-in per team (LOC‑5 precedent)** · vs always the chat model | Extraction is bulk and cheap-model-shaped. |

## Document sharing (DSH) — proposed, see [document-sharing.md](document-sharing.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DSH‑1** | What a person picks when sharing | **Three capabilities (view / edit / manage) that grant permission sets** · vs permission strings · vs a boolean | Explainable in one sentence; the grant row stays exact. |
| **DSH‑2** | Who may re-share | **Only `manage`** · vs any viewer | Keeps the set of people who can widen access small and auditable. |
| **DSH‑3** | Expiring grants | **v1, optional `expires_at`, expired rows kept** · vs later · vs never | Links already expire; a grant should not outlive a contract. |
| **DSH‑4** | Groups | **Deferred; user + team principals** · vs build groups now | A later principal type changes nothing here. |
| **DSH‑5** | Derived documents | **Inherit visibility + grants at creation, then independent** · vs live-linked · vs private-by-default | The only rule explainable in a sentence. |
| **DSH‑6** | Cross-team sharing | **Inside an org only; the org gate already guarantees it** | Cross-team without a tenancy hole. |

## Document workflows (DWF) — proposed, see [document-workflows.md](document-workflows.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DWF‑1** | Where triggers fire | **Inside `repo-put!`, after the version commits** · vs per-endpoint hooks | One seam covers console, shim and S3; three hooks drift. |
| **DWF‑2** | Whose principal a triggered run uses | **The uploader's** · vs the trigger creator's · vs a service account | A run reads only what its uploader could; outputs are owned by someone real. |
| **DWF‑3** | Re-firing | **Once per version; derived documents do not re-trigger unless opted in** · vs fire on every write | Otherwise a pipeline runs itself forever. |
| **DWF‑4** | Where outputs live | **Repository documents with a provenance row** · vs blobs in run state | Shareable, versioned, searchable; provenance is a click. |
| **DWF‑5** | Extraction output | **Validated against a caller-supplied JSON schema; refused on mismatch** · vs accept and flag | A wrong extraction that looks finished is worse than a failed step. |
| **DWF‑6** | Form rendering | **Markdown/HTML v1, DOCX via template; PDF deferred** · vs a PDF renderer now | Every PDF renderer is a dependency. |
| **DWF‑7** | Manual vs automatic | **Same `run` path; "Run workflow…" ships first** · vs triggers only | Test by hand, automate the same code. |
| **DWF‑8** | The first-user path | **A shipped `doc-pipeline` plugin, configured per trigger** · vs bespoke per customer | One workflow, many configurations. |

[^1]: **TEN.** A deployment serves one organization/legal entity that may contain
one or many **teams**. Isolating *different legal entities* on a shared instance is
explicitly **out of scope** — hosted multitenant offerings serve that need. No
`org_id` in the schema; the org is implicit. **Superseded by TEN‑2** — this is now
the behaviour with the multi-tenancy flag off, which remains the default.

[^3]: **TEN‑2.** `orgs` is a real table and `teams.org_id` is a real column, in
both modes: single-tenant is "exactly one org", not "no org", so the schema and
the authorization path are identical either way and there is no untested second
code path. `TELEMACHUS_MULTITENANT` switches *surface area* — the `/api/orgs`
(superadmin) and `/api/org` (org admin) management planes — not semantics. The
isolation itself is step 0 of `can?`: an unconditional deny before permissions,
owner-ok, token scopes and resource grants, so no sharing path can tunnel out of
an org. Superadmin (`instance:*`) and org admin (`org:*`) are distinct tiers,
neither reachable from a team role. See
[multi-tenancy.md](multi-tenancy.md); validated by `test/multitenant-demo.sh`
and `test/tenancy-tests.rkt`.

[^4]: **WF‑1.** Durability and legibility force the same artifact: a run that
resumes after a restart must record which step it stopped on, and an administrator
who never reads the source must still see what happens next. Both need the step
graph to be an inspectable data structure rather than a closure — so the spec gets
built whether or not it is ever serialized, and serializing it is then nearly free.
`define-workflow` is the authoring surface and ships in the same slice; the JSON is
a storage, execution and rendering format, **not** a second authoring surface.
Non-Racket authoring was explicitly **struck** as a requirement. See
[workflow-engine.md](workflow-engine.md).

[^2]: **RBAC‑5.** There is no separate operator-account setup step: the first user
created (first team's owner) is granted the instance **operator** capability at
bootstrap. But operator remains a **distinct tier** — `instance:*` permissions
(deployment settings, model endpoints, feature activation, cross-team, create/delete
teams) are grantable *only* via the operator flag and are **never** part of any team
role, so an ordinary team owner cannot hold them. `can(instance:*)` ⇔ `is_operator`.
