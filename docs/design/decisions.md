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
| TEN‑2d | per-org branding / hostname routing | ✅ built 15 Sep 2026 (slice 68) — `orgs.domain` (superadmin-assigned, unique) picks the company from the Host header; `branding:<org-id>` under `instance_settings`; unset = the instance's, whole |
| TEN‑2e | per-org model endpoints (BYO inference) | ✅ built 15 Sep 2026 — `executors.org_id` (PULL‑6): `POST /api/org/executors` binds one to the caller's company, offered only to its teams |
| TEN‑2f | provisioning is an **API** operation; explicit slug = natural key (`409` on re-run), derived slug suffixes | ✅ built — a pipeline must converge; a silent duplicate company is worse than a refused call |
| TEN‑2g | **no `DELETE /api/orgs`** — suspend is the terminal API state, erasure is a SQL maintenance procedure | ✅ decided — the cascade spans teams, users, tokens, blobs and audit |
| TEN‑2h | cross-team reading is the `org_reader` role holding `org:read-data` (team-visible only; `org:*` does not imply it) | ✅ decided 15 Sep 2026 — the downstream's "org scoped data routes" without reversing TEN‑2a: reading a company's data is a deliberate, auditable assignment |
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
| **KG‑7** | Extraction model | **`utility` role, opt-in per team (LOC‑5 precedent)** · vs always the chat model | Extraction is bulk and cheap-model-shaped. ✅ built 15 Sep 2026 (slice 67): `domain/ai/roles.rkt`, `PUT /api/model-roles`; the pipeline and the Manager's drafts share the role. |

## Document sharing (DSH) — decided 12 Sep 2026, see [document-sharing.md](document-sharing.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DSH‑1** | What a person picks when sharing | **Three capabilities (view / edit / manage) that grant permission sets** · vs permission strings · vs a boolean | Explainable in one sentence; the grant row stays exact. |
| **DSH‑2** | Who may re-share | **Only `manage`** · vs any viewer | Keeps the set of people who can widen access small and auditable. |
| **DSH‑3** | Expiring grants | **v1, optional `expires_at`, expired rows kept** · vs later · vs never | Links already expire; a grant should not outlive a contract. |
| **DSH‑4** | Groups | **Deferred; user + team principals** · vs build groups now | A later principal type changes nothing here. |
| **DSH‑5** | Derived documents | **Inherit visibility + grants at creation, then independent** · vs live-linked · vs private-by-default | The only rule explainable in a sentence. |
| **DSH‑6** | Cross-team sharing | **Inside an org only; the org gate already guarantees it** | Cross-team without a tenancy hole. |

## Document workflows (DWF) — decided 12 Sep 2026, see [document-workflows.md](document-workflows.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DWF‑1** | Where triggers fire | **Inside `repo-put!`, after the version commits** · vs per-endpoint hooks | One seam covers console, shim and S3; three hooks drift. |
| **DWF‑2** | Whose principal a triggered run uses | **The uploader's** · vs the trigger creator's · vs a service account | A run reads only what its uploader could; outputs are owned by someone real. |
| **DWF‑3** | Re-firing | **Once per version; derived documents do not re-trigger unless opted in** · vs fire on every write | Otherwise a pipeline runs itself forever. |
| **DWF‑4** | Where outputs live | **Repository documents with a provenance row** · vs blobs in run state | Shareable, versioned, searchable; provenance is a click. |
| **DWF‑5** | Extraction output | **Validated against a caller-supplied JSON schema; refused on mismatch** · vs accept and flag | A wrong extraction that looks finished is worse than a failed step. |
| **DWF‑6** | Form rendering | **Markdown/HTML v1, DOCX via template; PDF via `format: "pdf"` (pandoc → tectonic, slice 68)** · vs a PDF renderer in-process | The renderer is the two tools the e-book already pinned; looked up at call time, so a box without them refuses that one call by name. |
| **DWF‑7** | Manual vs automatic | **Same `run` path; "Run workflow…" ships first** · vs triggers only | Test by hand, automate the same code. |
| **DWF‑8** | The first-user path | **A shipped `doc-pipeline` plugin, configured per trigger** · vs bespoke per customer | One workflow, many configurations. |


## Session timeouts (SESS) — decided 27 Sep 2026 (issue #38), built as slice 70

Following the OWASP Session Management Cheat Sheet, which asks for two clocks and
not one. `domain/authz/session-policy.rkt`, migration `0032-session-policy`,
enforced in `resolve-token`.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **SESS‑1** | How many clocks | **Both an idle timeout and an absolute cap** · vs idle only · vs absolute only | They answer different attacks. Idle limits an unattended desk; absolute limits a stolen token that is being kept warm, which never idles out. OWASP asks for both. |
| **SESS‑2** | What the clocks apply to | **Interactive sessions only** (`api_tokens.kind = 'session'`) · vs every token | A machine token is idle by design; idling out a weekly batch job would be a silent outage. `name` could not stand in for this, because a member added to a team gets a session with no name. |
| **SESS‑3** | Where the layers live | **An instance document plus a per-org document in `instance_settings`** · vs a column · vs instance only | Issue #38 asks for a system default and an org policy. Branding already proved the `key` / `key:<org-id>` shape for the org layer (TEN‑2d), so the second layer needs no migration. |
| **SESS‑4** | Who wins between them | **An org may TIGHTEN and may never loosen; the effective value is the stricter per axis** · vs the org's document wins whole (branding's rule) · vs instance only | The instance operator owns the compliance posture of the box. If an org admin could raise their own idle window the instance floor would be advisory, and one compromised org admin would remove it. Deliberately asymmetric with branding, which is cosmetic. |
| **SESS‑5** | The shipped default | **30 minutes idle, 8 hours absolute** · vs off by default · vs OWASP's high-value 2-5 minutes | The issue asks for a *default*, so "off" fails it. These are the least disruptive ends of OWASP's own bands (15-30 low-risk, 4-8 for a full-day worker). An operator who needs the high-value numbers sets them in one call. |
| **SESS‑6** | The upgrade | **Pre-existing rows default to `kind = 'api'` and have NULL clocks, so nothing is enforced on them** · vs backfilling them as sessions | Existing rows include customers' machine credentials and worker tokens. Breaking those is a worse upgrade than letting pre-upgrade browser sessions run to their 30-day expiry. Same call issue #13 made with a NULL expiry: an upgrade locks nobody out. |
| **SESS‑7** | Enforcement point | **`resolve-token`, and the row is revoked with a reason** · vs a scheduled sweep · vs client-side only | It is the one place a bearer becomes a principal, so there is no path around it. OWASP: server-side invalidation is "the most relevant and mandatory". The status becomes `expired-idle` or `expired-absolute` so an operator can see why a session ended. |
| **SESS‑8** | Telling the user | **The console counts down from the last REQUEST and warns before signing out** · vs a silent bounce to the sign-in screen · vs a timer driven by pointer activity | OWASP asks that the user be able to see it coming. Counting pointer activity would be actively wrong: the server measures requests, so a mouse-driven timer would show a live session the server had already expired. |

## Pull-model executors (PULL) — decided 15 Sep 2026, see [pull-executors.md](pull-executors.md)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **PULL‑1** | Where pull work lives | **The existing `jobs` table, claimed over HTTP** · vs a separate queue | One queue: one cap, one quota, one cancel, one audit. |
| **PULL‑2** | Worker identity | **An API token scoped `jobs:execute`, bound to an executor row** · vs a new credential type · vs mTLS | Scopes, expiry and revocation already exist. |
| **PULL‑3** | Lost workers | **Leases + heartbeats; expiry re-queues with a bounded attempt count** · vs run-once-and-fail | A vanished host must neither lose nor double-run a job. |
| **PULL‑4** | Placement | **Capability match (`kinds`, `models`) at claim** · vs named routing only | SCHED‑2 gets a consumer. |
| **PULL‑5** | Synchronous model calls | **Enqueue `infer.chat` and wait, bounded by the caller's lease** · vs make tools asynchronous | Every existing tool keeps working. |
| **PULL‑6** | Per-org executors (TEN‑2e) | **`executors.org_id`; null = instance-wide** · vs instance-wide only | The org gate, again. |
| **PULL‑7** | Transport | **HTTPS long-poll, JSON** · vs WebSocket · vs a bus | Works through NAT and a tailnet; nothing to deploy beside the server. |
| **PULL‑8** | Token formats | **Opaque now; PASETO only if a host must verify without the database** · vs signed now | The server checks the database on every call anyway. |

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

## Layered operations (LAY) — proposed 3 Oct 2026; **LAY‑1/‑2/‑3 adopted and built 4 Oct 2026**, see [layered-operations.md](layered-operations.md)

Driven by an RFE from a prospective civil-engineering and disaster-response
customer. The question each decision answers is *what must the PLATFORM grow* —
the domain specifics (OCR engine, damage classification, inspection checklists,
submission forms) are plugins and workflow content by construction.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **LAY‑1** | A workflow waiting for a person | **A `review` step kind and a `waiting` run status** · vs a separate review app beside the engine · vs leaving review out of the run | Their core sequence has two human gates and neither can exist in a workflow today, so the run's history omits the review that actually happened. `flow-advance!` is already a durable reducer over rows: a run that is not advanced *is* a parked run, so this needs no timer and no in-memory queue. |
| **LAY‑2** | Where a decision is recorded | **Its own rows (verdict, rationale, actor, time), referenced from the run step; the audit log records that it happened** · vs the audit log alone · vs a status column on the step | "What is waiting for me?" and "why was this rejected in March?" are ordinary questions an append-only event log answers badly. This record IS their Layer 3 requirement to preserve who decided what and why. |
| **LAY‑3** | Who may approve | **Generalise the Localization Manager's rule: an author may not approve their own work; a machine draft has no author** · vs per-workflow configuration now · vs no restriction | The rule is built and tested in `l10n-review!` and is exactly the RFE's "mandatory dual-review". It is currently one tab's rule about strings; it should be the platform's rule about review. |
| **LAY‑4** | Team-defined object metadata | **Operator-defined fields with the beta funnel's non-regex vocabulary, landing in an `attributes` blob** · vs columns per field · vs the knowledge graph | Their Solution 4 is unmet: `repo_objects` carries no project, location, period or status, so Layer 3 has nothing to aggregate. The funnel's design was chosen because fields are admin-authored and input is attacker-chosen — the same holds here. The KG extracts what a document *says*; this is what the team *asserts*. |
| 🔑 **LAY‑5** | Extraction provenance | **Keep page/region/cell at ingest** · vs text only, add coordinates later | The one decision with a deadline. It turns review from "source left, output right" into "click the value, jump to the highlighted region", which is the largest lever on their stated goal of reducing specialist workload. Cheap to design in; adding it later means re-processing every document ever ingested. |
| **LAY‑6** | Repository access for out-of-process plugins | **Add `repo.get` / `repo.text` / `repo.put` behind the existing scope check and `can?`** · vs passing bytes inline in the call · vs in-process adapters per pipeline | The host exposes exactly `notes.create` and `notes.list`, so a Python OCR or CV plugin can read nothing and write nothing. An in-process Racket tool has no such limit — the asymmetry is the bug, and every domain pipeline in this RFE is Python. |
| **LAY‑7** | Extractors | **A registry a plugin can claim a content type in** · vs extending the built-in `cond` · vs a separate ingestion service | `kind-of` is a fixed dispatch over text/markup/docx/pdf. Their "model-replaceable architecture" names PDF extraction and image classification as the swappable parts — precisely what this seam does not cover. With a registry, OCR, EXIF and keyframe sampling are all one kind of object. |
| **LAY‑8** | A PDF with no text layer | **A `'needs-ocr` reason beside `'missing-tool` and `'unsupported`** · vs leaving it as an empty successful extraction | Today a scan is recorded as successfully indexed with empty text, so it is indistinguishable from a blank page and the failure surfaces much later as a schema refusal naming nothing. Must land before OCR, or nobody can tell which documents need it. |
| **LAY‑9** | Model capability | **Record per executor whether it does tool calls and honours `json_schema`** · vs discovering it at call time | Japanese models lead comparable international models on general benchmarks but lag on function-calling and applied tasks (Nejumi Leaderboard4, W&B Japan). The agent and the extraction pipeline both depend on exactly that axis, so a model swap is not a drop-in and the platform should say so before a run fails. |
| **LAY‑10** | Measuring AI reliability | **A report over the decisions LAY‑2 already records** · vs an evaluation subsystem · vs an external benchmark only | Their "framework to determine the reliability and acceptable scope of AI outputs" sounds like a platform and is a query. The same rows are also a supervised dataset for fine-tuning a domain model — which is why LAY‑1/‑2 pay three times. |
| **LAY‑11** | Tamper-evidence | **Hash-chain the decision records** · vs trusting append-only convention · vs external signing | For an administrative audit the difference between a record and evidence is whether alteration can be detected. Built on primitives that exist: SHA‑256 content addressing and `sha2.rkt`'s HMAC. |
| **LAY‑12** | Where review appears in the console | **The queue is a core, permission-gated surface; domain canvases stay plugin bundles** · vs all of it in a plugin · vs all of it in core | Every team with a human gate needs the queue, so it is platform. Drawing regions on an inspection photograph is domain work, and the authenticated bundle already serves custom screens. The platform owes the queue, the record and the storage — not a crack-width widget. |
| **LAY‑13** | Where a human annotation lives | **Its own table, `repo_annotations`, bound to a VERSION** · vs a flag on LAY‑5's `repo_text.spans` · vs an attribute on the object | A span is a function of the bytes: an extractor reports it and a new version replaces the set wholesale. A person's observation is not — it was true about the bytes they were looking at — so it survives and names the version it was drawn on. `version_id` is NOT NULL: a region with no version is a region on unknown bytes, and the one thing an annotation must not do is claim to mark a place in a document it never saw. `stale` is DERIVED against the object's current version, never stored, so re-uploading the same bytes cannot leave a row disagreeing with the object (the Localization Manager's `missing`/`stale` rule, and QUOTA‑3's `waiting`). |
| 🔑 **LAY‑14** | Who may annotate | **Anyone who may READ the document** · vs `files:write` · vs a new `annotations:write` permission | This is the decision of the slice. Requiring write would mean a specialist handed a document to review could not mark it up — and `view` (DSH‑1) is exactly what sharing for review GIVES them, so the asymmetry would fall on the one case the feature exists for. Nothing about the document changes: bytes, versions and extracted text are untouched, and the row carries whose observation it is. LAY‑1…3 already lets a reviewer record a verdict and a rationale on work they cannot write to; this is the same act at a finer grain. The cost is stated rather than hidden: a colleague may annotate your team-visible document, and you cannot edit what they wrote. |
| **LAY‑15** | Who may change one | **Only the author may EDIT; the author or a `files:manage` steward may DELETE** · vs the document's owner may edit · vs anyone with read may delete | Editing is deliberately a NARROWER power than deletion, which is the opposite of the usual shape and is the point: a steward may remove an annotation from their document, and may not put words in somebody's mouth. A correction to somebody else's observation is your own annotation — the grants table's superseding-record rule and the review queue's terminal decision. Somebody else's annotation answers 403, not 404: the request is fine, the person is wrong for it (LAY‑3's four-eyes refusal takes the same line). |
| **LAY‑16** | How it relates to LAY‑11's chain | **A reference to the decision, not a chained record of its own** · vs chaining annotations too · vs no link | An annotation is an observation; a decision is what somebody is accountable for, and that is what LAY‑11 hashes. A second chain over observations would imply a tamper-evidence claim the storage cannot make and nobody asked for. So an annotation may name the review that cited it, and `annotations-for-review` reads those back PER OBJECT under that object's own `can?` — a review may legitimately cite a region in a document the reader cannot see, and this must not be the way around that. |
| **LAY‑17** | What an annotation may NOT be | **No place, no annotation — and one bbox rule, shared with LAY‑5** · vs free-form comments · vs a second geometry validator | Without a region or a range it is a comment on the document as a whole, which a note (or a review rationale) already is, and a table of place-less rows would make "what is marked on page 3" answer with things that belong nowhere. The bbox check is extracted from `span-problem` as `bbox-problem` and shared, because deriving it twice is `executor-can-run?`'s drift: the two copies would disagree about an edge only one caller's tests would see. The kinds are CLOSED (`note` needs a body, `highlight` does not — that behavioural difference is the bar for a second member); `redaction` was left out because it would imply enforcement, and enforcement is #91. |

## Issue #54's open questions — **decided and BUILT 12 Oct 2026**

The four items in issue #54 that were questions rather than defects. Recorded
here because an unanswered question in a tracker decays into a guess; each one
below names what it implies, so the build is a build and not another decision.
All four shipped the same day; where the build corrected the recorded plan, the
entry says so, because a plan that was quietly wrong is worth more than a plan
rewritten to look right.

| # | Decision | Recommendation · alternatives | What it implies |
|---|---|---|---|
| **SCHED‑8** | A running job is cancellable | **Yes, gated by a role** · vs cancelable-only-while-queued (today) | `POST /api/jobs/:id/cancel` declares **no permission at all** today, and `cancel-job!` refuses anything not `queued`, which is SCHED‑7's "cancelable, not preemptible". Both change. There is no `jobs:*` permission a person can hold — `jobs:execute` is worker-only and reaches no team data — so this needs a new one. And nothing preempts a Racket thread mid-tool-call, so the honest design is **cooperative**: a cancel flag the run loop checks at step boundaries, and for a worker-claimed job the heartbeat response carrying the cancellation. "Best effort, checked between steps" is the claim; anything stronger would be untrue.  **Built**: a third status, `canceling`. A queued job is canceled outright; a running one goes to `canceling`, which splits the two jobs `status` had been doing at once — "is this work live" (the per-team cap counts `running` + `canceling`) and "may its result land" (`finish!` still names `running` alone, so the handler's answer matches no row and is discarded). Flipping straight to `canceled` would have been a **quota-evasion path**, not an accounting wobble: cancel N running jobs in a loop and the team gets N draining handlers plus N freshly claimed ones with the cap satisfied throughout. The slot is released by `settle-canceling!` when the handler actually returns. The gate is **owner-ok OR `jobs:cancel`**, not the role alone as recorded: the person whose team budget a runaway run is burning should be able to stop it, and owner-ok is why notes and documents work that way too — `jobs:cancel` is for stopping SOMEBODY ELSE's. Cooperative half: `job-canceled?`, polled at a step boundary. Nothing is preempted, and the reason is specific — killing a handler mid-query would leave the SHARED db connection in an undefined state and could wedge the whole pool. |
| **SCHED‑9** | The platform caps run time | **Yes, a default the operator can override** · vs trusting the worker's own limit · vs no cap | The cap must exceed `LEASE-SECONDS` (120) by a wide margin or it fights the reaper, which already re-queues an expired lease up to `MAX-ATTEMPTS`. An in-process job is NOT bounded today: `with-lease` refreshes while the handler runs, so a wedged tool runs for ever holding its team's `ai.concurrency` slot — the same shape as the model-call hang that `TELEMACHUS_MODEL_TIMEOUT` fixed one level down. Enforce it in `reap-leases!`'s existing sweep rather than a new timer, and fail the job with a NAMED reason, not a generic error.  **Built**, and the recorded plan was wrong about WHERE. "Enforce it in `reap-leases!`'s existing sweep" cannot work: that sweep sees only an EXPIRED lease, and an overrunning job's lease is being refreshed every 40 seconds, so the reaper would never see it. The enforcement point is the refresher itself (`lease-tick!`, extracted so a test can drive one tick instead of waiting out the sleep): past the ceiling it flips the job to `canceling` with a reason naming the knob and STOPS refreshing, and the reaper then settles the row. `TELEMACHUS_MAX_JOB_SECONDS`, default 1800, `never` to disable; an unparseable or non-positive value falls back to the default, never to 0, which would cancel every job as it started. The clock is `jobs.started_epoch` (migration `0038`) — `started_at` is TEXT `CURRENT_TIMESTAMP`, whose format differs by dialect, the trap `LastModified` and the session clocks both set. It is stamped in `claim-job!` because that is the ONE claim both paths make. This is the one case where a slot is freed before the work provably stopped: a handler that ignored both the ceiling and `job-canceled?` has proven it will not stop, and holding its slot for ever is the worse failure. |
| **PULL‑9** | What a worker may read | **Job-bound document reads** · vs no-data isolation (today) | A worker sees only its payload now. Job-bound means it may read the objects **its own claimed job references**, and nothing else — the fence is the job's own inputs, and the credential is the `claim_token` it already carries, so the read dies when the claim does. This is what lets an OCR or CV worker fetch the file it was given instead of having bytes pushed through the payload. It is a real widening of what a worker host can see: today a compromised worker learns nothing, afterwards it learns the documents it was handed.  **Built** as `POST /api/workers/jobs/:id/document`, with a **third** condition beside the two recorded: the read happens as the JOB'S OWN USER, so `can?` decides exactly as it would for that person — visibility, grants and the org gate included, and no new authorization code. A document the job's user cannot see is invisible to the worker running that job, and "does not exist" and "not yours" are one answer, as in the knowledge graph. `as: "bytes"` (base64, capped at `TELEMACHUS_MAX_UPLOAD` — a worker is not a way past the ceiling the front door enforces) or `as: "text"`, where a scan answers `{text: null, reason: "needs-ocr"}` rather than erroring, since that is the branch an OCR worker exists to take. |
| **RBAC‑5b** | Custom team roles | **Not in v1** · vs ship them now | Closes the question. `roles:manage` exists as a permission with nothing behind it, which is the kind of thing that reads as an unfinished feature rather than a deliberate omission — say so where the permission is described. The four built-in roles stay the vocabulary.  **Built**: `roles:manage`'s description now says it is reserved for team-defined roles, which are not in v1, and that nothing reads it yet — a deliberate omission rather than an unfinished feature. |

## A schedule at an hour somebody recognises (SCHED‑15…18, issue #140, **BUILT 22 Oct 2026**)

#135 shipped an interval, which cannot say "07:00 on weekdays": 24h from an
arbitrary create time drifts to whatever minute the row happened to be written.
#137 made the question answerable; this answers it, and completes what #114 asked
for.

| # | Decision | Chosen | Why / limits |
|---|---|---|---|
| 🔑 **SCHED‑15** | The cadence vocabulary | **`interval` / `daily` / `weekly`, CLOSED** · vs cron · vs a general recurrence rule | Cron is a sublanguage: five fields with ranges, steps and lists is a parser, and this codebase has twice frozen one deliberately (the workflow bindings, the funnel's validation vocabulary). A time of day plus a set of weekdays covers both callers that were waiting — #114's morning briefing, #121's periodic plugin work — with no grammar at all. `at_minute` is one integer (minutes after LOCAL midnight), which needs no parsing and survives a dialect with no time type; `days_of_week` is a comma-separated subset of 0‑6, Sunday = 0, as `local-fields` and POSIX both number it. An operator who must paste a real crontab line gets a translation layer above this, never a second scheduler. `interval` stays the default, so every row #135 created is untouched. |
| 🔑 **SCHED‑16** | Whose 07:00 | **The zone is STORED ON THE SCHEDULE, defaulted from the creator's** · vs resolving the owner's zone at firing time · vs UTC | A schedule is a standing instruction. If its author travels and changes their profile, "07:00 before the morning meeting" must not silently move for everybody else — and a schedule nobody edited changing its behaviour is the worst kind of surprise. Defaulted from the creator's effective zone (#137) so nobody has to think about it, and refused if it names a zone the instance has no data for: "07:00" means nothing without saying whose, and a typo'd zone quietly given UTC fires at the wrong hour for ever. The resolution happens in the HANDLER, so `schedules.rkt` stays free of the settings layer. |
| 🔑 **SCHED‑17** | A local time that does not exist | **Pass the day over and RECORD it (`dst-gap`)** · vs firing at a different time that morning · vs firing anyway at the pre-transition offset | TZ‑5 answers `nonexistent` and says the caller decides; this is the caller deciding. `daily 01:30 Europe/London` has no 01:30 on the spring-forward morning: firing at some other time that day is a schedule that silently moved, and inventing the instant is a lie about what happened. The day is skipped, the row says why, and the next day fires normally. The REPEATED hour needs no rule here — TZ‑5 already yields the first of the two occurrences, which is the one to fire. |
| **SCHED‑18** | Where "next" comes from | **One `next-firing`, used by the create, the tick, the resume and the patch** · vs separate arithmetic per call site | SCHED‑11's "skip, do not catch up" then falls out of the arithmetic instead of being enforced on top of it: the answer is always STRICTLY after the instant asked about, so a box down for a week gets the next matching local time and not the 1,440 it slept through. It is also why a patch RECOMPUTES the due time — leaving the stored one would fire once at the old hour and only then obey the edit, which reads as the edit not having taken. `interval_seconds` is reported only for the cadence it drives: the column is NOT NULL from 0051, so a daily row carries a nominal 86400, and a number nothing computes with is how a reader comes to believe the wrong thing (LIVE‑IN's lesson pointed the other way). |

## Whose clock it is (TZ‑1…6, issue #137, **BUILT 22 Oct 2026**)

Every date computation in the tree was `(seconds->date secs #f)` — UTC,
uniformly. Right for a stored timestamp, useless for anything a person expects at
a particular hour, and the prerequisite #114 ran into: #135 can poll every 15
minutes, but nothing could mean "07:00 on weekdays" because nobody had said whose
07:00.

| # | Decision | Chosen | Why / limits |
|---|---|---|---|
| **TZ‑1** | What is stored | **An IANA zone NAME on `users.timezone`** (migration 0052) · vs a stored UTC offset · vs a per-request header | An offset is wrong for half the year in most of the world, and a schedule asks about the FUTURE, where only the rule can answer. `users.locale` (0018) is the sibling column and this is its shape: nullable, no backfill, absence means "fall back a layer". The org and instance defaults are `instance_settings` documents and need no migration — what 0023 exists for. |
| 🔑 **TZ‑2** | How the layers combine | **user → org → instance → UTC, and they DO NOT TIGHTEN** · vs the instance owning a floor · vs the user owning it outright | A timezone is not a control: nobody is protected by being forced into the wrong clock, so a person's choice wins over their company's and the company's over the instance's. That is branding's rule (TEN‑2d), deliberately NOT SESS‑4's — a session timeout and a feature switch govern whether something is PERMITTED, and this governs how a number is rendered. UTC as the last resort is stated rather than implied: a box with no zone data behaves exactly as it did before. `timezone-report` names the layer that answered, the feature switch's `disabled_by` rule — "why is this showing me Tokyo" should not need three documents diffed by hand. |
| **TZ‑3** | Where the data comes from | **The tz database on disk, with `TZDIR` declared in the Nix closure** · vs the Racket `tzinfo` package · vs a table in the source | `tzinfo` is not in the pin and adding a package fetch to a sandboxed build is its own problem. Available zones are DERIVED FROM DISK — `available` locales' rule — so a tzdata upgrade needs no release, and an instance cannot offer a zone it has no data for. **The container is why `TZDIR` is set explicitly**: the image has no `/usr/share/zoneinfo` and no shell to debug with, so a fallback to the system path would work on every developer's box and resolve everything to UTC in production. The devShell pins it too, for the same reason. |
| 🔑 **TZ‑4** | Reading the files | **Built from the spec, pinned to the IANA database as the oracle** · vs trusting the transition table · vs a port | tzdata is built "slim": the transition TABLE stops where a zone's rule became regular (Europe/London's last entry is in the 1990s) and everything after is a POSIX TZ string in the file's FOOTER. A reader that walks only the table answers today's question with a rule from thirty years ago — and a scheduler asks exclusively about the future, so the footer is the normal path here, not an edge case. The POSIX offset sign is INVERTED (`PST8` is UTC‑8), which is a sixteen-hour error that still looks like a plausible time of day. Every expected value in `test/timezone-tests.rkt` came from Python's `zoneinfo` reading the same tzdata and is carried as a literal: a test that recomputed the answer would agree with any bug. The cases are the ones a 60-minute northern reader gets wrong — Lord Howe's **30-minute** DST step, Chatham's **45-minute** offset, and a 2030 instant that only the footer can answer. |
| 🔑 **TZ‑5** | A local time that does not exist, or happens twice | **`local->epoch` answers `ok` / `nonexistent` / `ambiguous`, and the CALLER decides** · vs picking one silently · vs raising | Twice a year an hour is skipped and an hour repeats, so "07:00 local" is not always one instant. Returning a best guess is how a report arrives an hour late for half the year. The repeated hour yields the FIRST occurrence (firing early and once beats firing twice); the skipped hour is named, and #135's tick records it as a skip rather than inventing an hour. Two probes either side of the day, because the offset depends on the instant while the instant is what is being solved for — a single round-trip check cannot tell the repeated hour apart at all, and the first version silently reported `ok` for London's second 01:30. |
| **TZ‑6** | What a timezone touches | **Presentation and scheduling only** · vs storing local times | Stored timestamps stay UTC, every one of them: ONB‑8's line (translation is presentation) applied to time. `format-local` renders with the offset attached; `${principal.timezone}` joins `${principal.locale}` in the workflow bindings, defaulted so every existing caller is unchanged. |

## A recurring job — the platform's clock (SCHED‑10…14, issue #135, **BUILT 22 Oct 2026**)

Nothing ran work on a timer. `jobs` had no deferred-start and no recurrence; a
thread in a plugin's `init!` has no team and no user; `set-reaper!` is the
platform's private seam. FEED‑3 predicted the shape and this is it, so FEED‑3's
slice 1 and #121's second case are both unblocked.

| # | Decision | Chosen | Why / limits |
|---|---|---|---|
| **SCHED‑10** | What a schedule IS | **A row that ENQUEUES an ordinary job** · vs a second execution path · vs an external cron | The enqueued job inherits the team, the user, quota admission, the org gate, cancel, the lease, the fence, SCHED‑9's ceiling and the whole FLEET surface from `jobs`, so `job_schedules` holds a principal, a kind and a cadence and nothing about running anything. `user_id` is NOT NULL: a schedule with no user is a system principal, and this platform has none — a job runs as `(user-principal conn user team)`, so there is always somebody `can?` can answer about. An unregistered kind is refused at CREATE, where a person is reading the answer, rather than enqueueing work nothing can run for ever (#113's shape on a timer). |
| 🔑 **SCHED‑11** | A missed tick | **Skip, and record it** · vs catch up · vs fire once per missed interval | The next due time is computed from NOW, so a box down for a day fires once, not 1,440 times against a budget sized for one. Resuming a paused schedule follows the same rule, where the catch-up would be a burst proportional to how long somebody left it off. The skip is RECORDED on the row (`skipped`, `last_skip_reason`, `last_skip_epoch`) rather than derived, because nothing re-computes it — the moment has passed, and a schedule that quietly did nothing for a week is this feature's worst failure. |
| 🔑 **SCHED‑12** | Two replicas ticking | **One guarded `UPDATE … RETURNING`, believed only if a row comes back** · vs a lock · vs a leader election | `claim-job!`'s rule (#17). The guard names the due time this process READ, so of two replicas holding the same row exactly one UPDATE matches and the loser does nothing. Advancing the due time BEFORE deciding whether to fire is deliberate: a crash between the claim and the enqueue costs one SKIPPED tick rather than a duplicate run, and of the two directions a failure can take, firing twice is the one nobody can undo. `claim-schedule-tick!` is exported FOR the test — a test over a hand-copied UPDATE agrees with any change to the real one, and two serial tick calls cannot see the guard at all, because the first advances the due time. |
| **SCHED‑13** | An overrunning run | **One at a time per schedule: skip while the previous job is outstanding** · vs stacking runs · vs a per-schedule concurrency setting | `queued` counts as outstanding, not only the two LIVE statuses, and it has to: this is what BOUNDS the queue. Admission defers at CLAIM, never at enqueue, so without the rule an over-budget team's schedule enqueues a job every tick for ever and nothing upstream pushes back. A skip is NOT audited — an overrunning schedule would write an entry every tick, PULL‑11e's "once per outage, not once per check" — while a FIRING is (`job.schedule.fired`, the schedule's own team, so `audit-list` can see it): a job that appeared with nobody present to start it is otherwise a job with no explanation. |
| **SCHED‑14** | Cadence, and who may set one | **An interval with a 60-second FLOOR, gated on `jobs:schedule`** · vs cron · vs an operator-tunable floor | Cron is a parser plus a timezone question, and the two dialects already disagree about what "day" means (QUOTA‑3); an interval covers both waiting callers. The floor is a constant rather than a knob because the tick rides `set-reaper!` at 30 seconds, so a shorter interval could not be honoured anyway. `jobs:schedule` is an admin permission, not a member's: a schedule commits the team's budget to spending on a timer with nobody watching, which enqueueing one job is not. Reading a schedule is held to the same permission as writing one, because its payload is the input of every job it fires — and the payload is sealed like `jobs.payload`, listed in `CONTENT-SECRETS` where that one is not, since a schedule is configuration that outlives key rotations and a sealed column `rewrap` does not walk is silently unrotatable. The PRINCIPAL is not patchable: changing whose authority a timer spends is a new schedule, not an edit. |

## Issue #54's remaining items — **decided and BUILT 14 Oct 2026**

What was left on issue #54 after the 12 Oct batch: three defects, two questions
it raised about them, and seven documents that disagreed with the code.

| # | Decision | Recommendation · alternatives | What it implies |
|---|---|---|---|
| **S3‑7** | An abandoned multipart upload is reaped | **Seven days, clocked on the NEWEST PART** · vs never (today) · vs a fixed age from Create | Nothing collected the rows or the blobs a disconnected client left behind, so the bytes were invisible to the team and never reclaimed. The horizon is generous because a 2 GB upload over a bad link legitimately takes hours, and the clock is the newest part's arrival rather than the create time — reaping an upload that is still making progress would be a new bug in place of the old one. The sweep rides the pool's existing per-tick reaper seam (throttled to ten minutes; a seven-day horizon does not need a scan five times a second) and NOT the S3 listener, which is off by default: an instance that staged parts and then turned the listener off would otherwise hold those bytes for ever. `TELEMACHUS_UPLOAD_REAP_HOURS`, `never` to disable, and an unparseable or non-positive value falls back to the default rather than to 0 — which would reap an upload the instant its first part landed. Each reap is audited (`repo.upload.reaped`), because "where did my upload go" needs an answer. |
| **S3‑8** | Staged parts are charged from the first part | **Charge on arrival, refund when the upload goes away** · vs charge only at Complete (today) | Charging only at Complete leaves the quota **walkable by a client that never completes**: `TELEMACHUS_MAX_UPLOAD` caps one part and nothing caps their number, so an unbounded amount of disk could be staged under a satisfied quota. The honest reading is that `storage.bytes` is a gauge over bytes the platform is HOLDING, and it is holding them. The refund lives in `drop-upload!` — the one place an upload stops existing, so Complete, Abort and the reaper all get it and no path can forget — and at Complete it lands after `repo-put!` has charged the assembled object, so the steady state is exactly what a single-shot PUT leaves. The cost is that `repo-usage` exceeds the sum of the listing while an upload is in flight. That is true, visible, and better than a bypass. |
| **PULL‑10** | A worker learns which attempt it is on | **`attempt` + `max_attempts` on the claim** · vs leaving it to the worker's own bookkeeping | A job that will not be re-queued deserves a different decision from one that will: retry a flaky model call now rather than failing, or fail loudly with the reason rather than spending an hour on work about to be retried anyway. The worker could not tell. Both fields ride on the claim response, which is where every other fact about the attempt already is. |
| **LOC‑6** | Plugin-contributed catalogs | **Not built, and the document is corrected** · vs adding the loader hook | `docs/design/localization.md` promised a plugin ships its own namespaced catalog; the loader reads none and `GET /api/i18n/catalog` keeps only `ui.`-prefixed keys, so one could not shadow a core string even if loaded. Leave it. `locales/*.json` is the shipping artifact *because* `telemachus-localize check` gates it in CI, and a catalog loaded from a plugin directory would carry none of that — a half-translated plugin would then look exactly like a half-translated product. A plugin that needs its own strings ships them in its own bundle. If this is ever built, the gate comes with it. |

**Seven documents disagreed with the code and now do not.** Each correction says
what changed rather than quietly rewriting history, because a plan that was
wrong is worth more than a plan edited to look right:

- `pull-executors.md` and `scheduler.rkt`'s own comment both said the reaper runs
  on the pool's **idle** tick. It runs on **every** tick, so a reader was
  planning against a delay that is not there.
- The multi-tenancy runbook said model endpoints are instance-wide. **Org-bound
  executors exist** (`POST /api/org/executors`, and the org gate in the claim);
  what is still instance-wide is the *credential* and the routing, which is the
  open BYOK half.
- `rbac-and-teams.md` described one implicit org. The **org tier is built**.
- `saas-onboarding.md` opened on the cross-legal-entity non-goal that TEN‑2
  **reversed**; one instance per tenant is now a choice, not a constraint.
- `document-repository.md` said secrets are stored in the clear and DOC‑3's
  sealing was withdrawn. Issue #19 **re-reversed that**: the withdrawal's
  argument defends a HOST and the threat is a DUMP.
- `documentation-generation.md` said the Japanese reference had not been
  drafted. It was, on 15 Sep 2026, and it is committed.
- `TelemachusMigration.md` said "this document stays in this repo" meaning
  Odysseus. It lives here; the sentence survived the move.

## The simulated echo says it is simulated (MODEL‑1) — **decided and BUILT 14 Oct 2026** (issue #64)

With `TELEMACHUS_MODEL_URL` unset, `run-chat` falls back to a deterministic
upper-cased echo of the prompt. The fallback is right — the platform is demoable
with nothing running — but it was **silent**, so a caller got a plausible-looking
reply from a model that was never called. It is the gotcha `CLAUDE.md` has warned
about for a year and it keeps being rediscovered from the other end, as "the
judge is broken".

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| 🔑 **MODEL‑1a** | Refuse, or mark? | **Keep the echo and MARK it** · vs refuse outright, as the document tools do · vs an env var to opt in | The echo has a job: `e2e/validate.sh`, `server-smoke.sh` and a first look at a fresh checkout all run with no model, and refusing would make the console's chat tab dead on arrival for exactly the person evaluating the product. The callers that already refuse are the ones where an echo is *useless* — the doc tools' schema would fail on it anyway, the knowledge-graph extractor's snippet check would reject it, the agent has no tool calls to parse. Chat is the one place the echo is still a demo rather than a lie, provided it admits what it is. |
| **MODEL‑1b** | Who decides | **`chat-simulated?` in `executor.rkt`, reading the same `backend` seam `run-chat` decided with** · vs each endpoint testing `model-configured?` itself | One policy, two askers — the call, which must decide, and the endpoint, which must explain. Two implementations drift, and the drift would be invisible: the endpoint would report "real" for a call the echo answered. Exactly the shape QUOTA‑3 settled for a held job's reason. It is PURE, so an endpoint may ask on every request. |
| **MODEL‑1c** | A named executor | **Never simulated** | A named executor is answered by a pull worker or refused by name. Reporting it as an echo would send an operator looking for a missing model when what is missing is a backend — and "a misroute that lies about where it ran is the worst shape this can take" is already the rule here. |
| **MODEL‑1d** | The shape on the wire | **`simulated: true`, and the key is ABSENT on a real call** · vs `simulated: false` | QUOTA‑3's rule again: a field that is there only when it says something. It also means a client written before this cannot read a missing key as a claim. |
| **MODEL‑1e** | Where else it is said | **At BOOT, and in the console beside the reply** · vs the response alone | The operator standing in front of a fresh instance is the one who most needs to know, and they are not reading JSON — so the boot line warns, in the shape the plugin failures already use. The console shows it on the reply's meta line as well as the model badge, because the badge is in the tab header and a reader scrolling a transcript is not looking at it. |

The badge was not quite silent: `chatView` already rendered `· simulated` when
`GET /api/ai/model` said `configured: false`. It was the **one console string
that never reached the catalogs** — hardcoded English, so a Japanese operator
read exactly the word that mattered most in the language they had not chosen.
`ui.simulated` and `ui.simulatedwhy` now carry it.

Deliberately NOT changed: a simulated call still **meters** `estimate-tokens`
against the team's budget. Billing for work no model did is arguable, but the
demo's quota behaviour is the thing the Usage tab is being demonstrated with,
and a second decision does not belong inside this one.

## A worker says whether it is taking work (PULL‑11) — **decided and BUILT 14 Oct 2026** (issue #58)

The last open item from #54. Executor health was derived from `last_seen_at`
alone — never-seen / active / stale / retired — so a box that was busy, or that
an operator had deliberately drained before maintenance, looked exactly like an
idle one, and a crashed worker looked exactly like a paused one.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| 🔑 **PULL‑11a** | Reported state vs derived health | **A SECOND column, `executors.worker_state`, beside the derived `status` — not a better answer in the same field** · vs letting a reported state override `status` · vs widening the `status` vocabulary | They answer different questions. `status` asks "is this host alive", which only the platform can know, and `worker_state` asks "is it taking work", which only the worker can. A paused host is **alive and refusing**, and both halves of that are worth saying. Folding the two into one field is precisely the mistake SCHED‑8 had to undo on `jobs.status`, which was answering "is this work live" and "may its result land" at once and could not express a cancellation until they diverged. Keeping `status` untouched also means nothing that switches on it changes behaviour. |
| **PULL‑11b** | The vocabulary | **Closed: `ready` / `busy` / `paused`** · vs free text · vs adding `draining` | A closed vocabulary for the reason `EXTRACT-REASONS` and `REVIEW-VERDICTS` are closed: an operator surface switches on these, so a worker inventing a fifth would arrive as a state nothing can explain. `draining` was considered and left out — the job rows already say what a paused worker is still finishing, so it would be a state the database can already answer. |
| **PULL‑11c** | Where it is reported | **`POST /api/workers/state` as the authoritative channel, AND an optional `state` on claim and heartbeat** · vs the claim alone · vs the dedicated endpoint alone | The claim alone cannot carry `paused`, which is the whole point of the issue: a drained worker has stopped claiming and holds no job to heartbeat, so it would simply go stale. The dedicated endpoint alone would double a busy worker's request count for a field that fits on a call it already makes every poll. Both, then — one mechanism with a convenience, not two mechanisms. |
| **PULL‑11d** | Silence | **A call that names no state leaves the stored one ALONE** · vs defaulting a claim to `ready` | A third-party worker written against the old wire must keep reading as "never reported". Defaulting a claim to `ready` would make every such worker assert something it never said, and a worker that is in fact paused and polling occasionally would be reported as ready. |
| 🔑 **PULL‑11e** | A stale worker's last word | **Withdrawn, not repeated: `worker_state` is `null` unless the row is otherwise live** · vs reporting the last state with its timestamp and letting the client judge | A worker that said `busy` an hour ago and then vanished is **stale**, not busy. Repeating its last word is a claim nothing stands behind, which is the rule QUOTA‑3 settled for a held job's reason — the key is absent rather than guessed, because a field a reader learns to distrust is worse than no field. The timestamp is dropped with it for the same reason. |
| **PULL‑11f** | An unknown state | **Refused on `/api/workers/state` (400), IGNORED on a claim** · vs refusing both · vs ignoring both | Asymmetric on purpose. On the state endpoint the state *is* the request, so there is nothing to do but refuse. On a claim it is a field riding along with the call that fetches work, and failing that call over a cosmetic field would stop the queue — the kind of refusal that turns a reporting nicety into an outage. |

Migration `0040-executor-state` adds `worker_state TEXT` and `state_epoch
BIGINT`, nullable, with **no backfill** — an executor that has never reported
reads exactly as it did before. Epoch seconds beside `last_seen_at`, which is
already epoch; the TEXT `CURRENT_TIMESTAMP` columns on this table differ by
dialect, the trap migrations 0038 and 0039 both name, and this value is compared
against a staleness horizon.

The reference worker (`cli/telemachus-worker.rkt`) reports `ready` on each
claim, `busy` on each heartbeat, and `paused` from a plumber flush on the way
out — a worker stopped by Ctrl‑C, a `systemd` stop or a drain before maintenance
otherwise just goes quiet, and quiet is what a crashed one looks like. That last
report is **best-effort**: a host being torn down may have no network left, and
failing the shutdown over a status update would be the worse failure.

**Still open after this, deliberately.** ~~A worker cannot report that it is
READY or PAUSED.~~ **Built as PULL‑11 (issue #58), above** — it was a wire change
on both sides and got its own slice rather than being bolted onto a defect
sweep. Still unbuilt: a purge for finished jobs' payloads and results (#59),
worker-token expiry with a rotation overlap (#60), a releasable claim that does
not spend an attempt (#61), and writable derived objects from a worker result
(#62) — all four were questions on #54 rather than defects, and each needs a
decision of its own before code.

## The reaper leaves a record (FLEET‑1) — **decided and BUILT 14 Oct 2026** (issue #70)

The first slice of the worker-fleet surface, and the only one worth building
before the views that read it: there was nothing to build a view *from*. A lease
expiry — the central failure event of the pull subsystem — was recorded nowhere,
and the requeue actively destroyed the one fact a reader needs.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **FLEET‑1a** | Where the record lives | **The audit log, written in `reap-leases!` BEFORE the UPDATE** · vs a `job_attempts` table · vs deriving it later from the jobs row | The requeue sets `executor_id = NULL` — it has to, the job is nobody's again — so **after** the UPDATE there is nothing left to derive from. A job one flaky box failed three times and a job three healthy boxes each tried once are the same row, and which it was is the first question an operator asks. The audit log is already the record, already correctly ordered (`at_us`, issue #47) and already the thing `audit-list` reads; a second table would be a copy of a decision the log can hold. |
| **FLEET‑1b** | Whose entry it is | **The JOB's `team_id`, with `actor_type` `system`** · vs the executor's org · vs no team | `audit-list` filters `WHERE team_id = ?`, so an entry carrying no team is invisible to exactly the people whose work stopped. This is the gap QUOTA‑3 had to close for a deferred job and the one `user.2fa.reset` still has. The executor's org would be the wrong answer for the same reason the org was wrong for a quota hold: the deferred work belongs to a team. |
| **FLEET‑1c** | Two actions, not one | **`job.lease.expired` per attempt, `job.attempts.exhausted` once at the end** · vs one action with a `result` · vs one at the end carrying the history | They are read by different people at different times. The per-attempt entry is the fleet signal — this box drops jobs — and wants one row per event so a count is a count. The verdict is the job's story and wants to name every holder in one place, so a reader looking at a failed job does not have to assemble it. The per-attempt entry's `result` still distinguishes `requeued` from `exhausted`, so neither reader needs the other's rows. |
| **FLEET‑1d** | No dedup | **One entry per expiry, unconditionally** · vs QUOTA‑3's once-per-window rule | QUOTA‑3 needed dedup because `quota.exhausted` is re-decided for every queued job on every pool tick, which writes dozens in seconds. An expiry happens once per attempt and is bounded by `MAX-ATTEMPTS`, so the volume is the volume and suppressing any of it would lose the count that makes the signal useful. |
| 🔑 **FLEET‑1e** | What the stored error says | **Name the holders, read back out of the trail just written** · vs leaving the old wording · vs recording holders on the job row | "no executor completed it in 3 attempts (leases expired)" was true and told an operator nothing — and the difference between one bad box three times and three boxes once each is the difference between retiring a host and looking at the job. The message is composed by reading the `job.lease.expired` entries back, which is the closed loop that makes FLEET‑1a worth its cost: the trail is not write-only. An `attempt` with no executor reads as **in process**, never as a guessed name. |
| **FLEET‑1f** | The in-process case | **`executor` is `null`, and the message says "in process"** · vs omitting the entry for a pool job · vs inventing a name like `pool` | The pool leases too (issue #17) and `reap-leases!` recovers its jobs as well, so a pool job whose process died is exactly as interesting. `null` rather than a name, for QUOTA‑3's reason: a field nothing stands behind is worse than an absent one. |

**What this does NOT do.** A `canceling` job that the reaper settles is still
unaudited — the cancellation itself is audited (`job.cancel`, SCHED‑8), so the
missing entry is the narrower fact that a holder ignored it past the ceiling.
`reap-orphans!`, which sweeps NULL-lease rows at boot, is likewise silent. Both
are the same class and neither is a lease expiry; noted here rather than folded
in, so the slice stays the one thing it claims to be.

**The one place the refactor nearly changed behaviour.** The condition was
`(< attempt MAX-ATTEMPTS)` → requeue. Naming the negation reads better as
`(>= (add1 attempt) MAX-ATTEMPTS)`, which is **off by one** and costs every job
an attempt. It is `(>= attempt MAX-ATTEMPTS)`, and `test/pull-tests.rkt`'s
existing MAX-ATTEMPTS case is what says so.

## The fleet read (FLEET‑2) — **decided and BUILT 15 Oct 2026** (issue #70)

`GET /api/executors` answers what each executor *is*. `GET /api/admin/workers`
answers what the fleet is *doing*: which box holds which job, how often each one
drops work, how deep the queue is, how long its oldest job has waited, and the
figure the platform could not express at all — how many queued remote jobs no
live worker is able to run.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **FLEET‑2a** | Where the instance-wide read lives | **Its own `instance:manage` route** · vs `?scope=instance` on `GET /api/jobs` · vs a per-team fleet view | `GET /api/jobs` is team-scoped by contract: `list-jobs` takes a team and `job-waiting` computes *that team's* hold reason. Widening it to cross teams would make a team-tier route answer past the org gate, which is step 0 of `can?` and the one thing nothing is allowed to tunnel through. An instance-wide question gets an instance-wide route. (`?scope=org` on `GET /api/notes` is not a counter-example: TEN‑2h gave it a *permission*, `org:read-data`, and still filters every row through `can?`.) |
| **FLEET‑2b** | Stored counters | **Every number derived, none stored** · vs counters on the executor row | The rule `missing`/`stale`, `waiting` (QUOTA‑3) and executor health itself already live by. A stored count is a second copy of something the rows answer, and on the day the two disagree it is the copy an operator believes. Nothing here is on a hot path: this is one operator read, not a request-path computation. |
| 🔑 **FLEET‑2c** | What a worker can run | **The claim's own declaration, merged into `executors.capabilities` on every claim** · vs the operator's create-time document · vs a new `observed_capabilities` column | This is the decision that makes FLEET‑2's headline figure mean anything. `capabilities` was written once at create and was usually `{}`, while the worker declared its kinds and models on **every poll** — so the platform was told the truth continuously and recorded the intention. A capability record that is aspirational cannot answer "can anything here run this job". Merged into the same document LAY‑9 reads for `tools` and `json_schema` rather than a second place to look, and an EMPTY declaration leaves the stored value alone, because a worker naming no models means "any", not "none" — PULL‑11d's silence rule. **Behaviour change**: `capabilities` on `GET /api/executors` now reflects what the worker last said. |
| 🔑 **FLEET‑2d** | What "unclaimable" counts | **Only jobs no live executor's capabilities satisfy — never a job a quota or a cap holds** · vs any job that is not progressing | "Nothing *can* run it" and "nothing *may* run it yet" are different answers with different remedies, and conflating them would send an operator to buy a machine when the answer was a budget. QUOTA‑3 already explains the second case on the job itself. The predicate is `executor-can-run?`, extracted from `worker-claim!` and asked by both — one policy, two askers, the shape QUOTA‑3 settled for admission, because two implementations of one matching rule drift and the drift is invisible until it misleads. |
| **FLEET‑2e** | Which executors count as an answer | **`active` pull rows only** · vs including `stale` | A stale box may come back, but it is running nothing now, and an operator asking "can this queue drain" means the fleet that exists. A stale row's *reported* state is withdrawn here exactly as it is on `GET /api/executors` (PULL‑11e). |
| **FLEET‑2f** | The window | **24 hours by default, `?hours=`, clamped not refused** · vs lifetime totals · vs a fixed window | A lifetime total is the wrong number: a machine that failed forty jobs last month and none today is healthy, and the total says otherwise for ever. The audit log also grows without bound. A nonsense `?hours=` on a READ answers with the default rather than a 400 — there is nothing to get wrong by guessing, and an operator should not have to decode a refusal to see their fleet. |
| 🔑 **FLEET‑2g** | Two sources for the counts | **Outcomes from the jobs row, lease expiries from FLEET‑1's trail** · vs one source for both | They cover different attempts and together cover all of them. `jobs.executor_id` survives a terminal write, so the row names the executor that *finished* a job — and the requeue nulls it, so the row can never name an earlier holder. FLEET‑1's `job.lease.expired` entries name every holder that dropped it. Reading outcomes from the trail as well would double-count the final attempt; reading expiries from the row is impossible. `started_epoch` (migration 0038) is the clock, because `finished_at` is TEXT `CURRENT_TIMESTAMP` and differs by dialect. |
| **FLEET‑2h** | The queue's age | **A new `jobs.created_epoch`, migration 0041, no backfill** · vs computing an age from `created_at` | `created_at` is TEXT `CURRENT_TIMESTAMP`, whose format differs by dialect — the trap migrations 0038, 0039 and 0040 each name — so an age derived from it is invisibly wrong on one of the two. A job queued before the migration reports `null`, never a number derived from nothing. |
| **FLEET‑2i** | Counting the meta | **`meta LIKE '%"executor_id":"<id>"%'`** · vs a JSON operator · vs a column on `audit_log` | The trick `object-processing` already uses to find the runs that touched a document: `jsexpr->string` writes no spaces, so the pair is one substring. SQLite and PostgreSQL do not spell a JSON operator the same way, and a column on `audit_log` for one caller's filter is the wrong shape. |

**Bounded, and it says so.** `unclaimable` scans at most 200 queued remote jobs
and reports `scanned` and `truncated` beside the count, the way the claim bounds
its own window to 64. A report that silently answered about a prefix of the queue
would be worse than one that says it stopped.

**Still FLEET‑3 and ‑4**: the operator-side drain (`admin_state`, reversible,
where today the only lever is a retire that revokes the token), the console's
Workers and Queue cards, and the create flow that shows the worker token once.
FLEET‑2 is HTTP only — deliberately, so the shape can be read before a card is
drawn against it.

## Draining a host, and the Workers card (FLEET‑3) — **decided and BUILT 15 Oct 2026** (issue #70)

The operator's own lever, and the console surface that reads FLEET‑2. Until this
the only way to take a flaky machine out of rotation was
`DELETE /api/executors/<id>`, which revokes the worker token — so a ten-minute
drain meant re-provisioning the host afterwards.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **FLEET‑3a** | Where intent lives | **A THIRD column, `executors.admin_state`** (migration 0042) · vs a fourth value in `worker_state` · vs folding it into `status` | Three questions, three answers, and all three can be true at once: `status` is derived and asks "is this host alive", `worker_state` is reported and asks "is it taking work", `admin_state` is the operator's and asks "do we *want* it taking work". **A drained box reporting `ready` is not a contradiction** — it is a healthy machine being held back, which is exactly the state a drain creates, and folding intent into either of the others would lose precisely that. The same argument PULL‑11a made for the second column and SCHED‑8 made for splitting `jobs.status`. |
| **FLEET‑3b** | Reversibility | **Drain/resume, token untouched** · vs retire-and-recreate | A retire revokes the worker token and is irreversible, which is the wrong tool for "take this box out for ten minutes" — and it was the only tool. `retired` is deliberately **not** an `admin_state` value: the two operations differ in kind, and a vocabulary that contained both would invite a console to offer them as peers. |
| 🔑 **FLEET‑3c** | What a drained worker sees | **It keeps polling and is answered 204** · vs refusing its token · vs telling it to stop | A drained host that keeps polling keeps being *seen*, so the operator watches a live box taking nothing instead of one that has gone stale — which is the whole gap issue #58 opened and this would otherwise reopen from the other side. 204 is also a meaning the wire already has, so a **third-party worker needs no change to be drainable**. Revoking the token instead would make a reversible act look exactly like a retire to the worker. |
| **FLEET‑3d** | Work already in flight | **Left running** · vs cancelling it · vs waiting for the lease to lapse | Draining says "start nothing new". Stopping work in flight is what cancel is for (SCHED‑8), and an operator who means that should have to say it. Releasing the claim without spending an attempt is **#61**, and this slice is the reason that issue matters. |
| 🔑 **FLEET‑3e** | Intent is NOT withdrawn when the row goes stale | **`admin_state` is reported whatever the health** · vs PULL‑11e's withdrawal rule | PULL‑11e withdraws a stale worker's reported state because it is a claim the worker can no longer stand behind. Intent is the opposite kind of fact: it is a **standing instruction**, it does not decay, and a drained box that went quiet is still drained — and still drained when it comes back. Withdrawing it would mean a host silently returned to rotation by going offline and coming back. |
| **FLEET‑3f** | Who may drain | **`instance:manage` only** · vs also the org admin who may retire their own executor | Draining is day-to-day operation of the instance's compute. The asymmetry with retire is deliberate rather than an oversight, and is worth revisiting when an org runs a fleet of its own. |
| **FLEET‑3g** | The claim's double check | **The predicate refuses a drained executor AND the claim short-circuits before touching the queue** · vs one or the other | `executor-can-run?` is authoritative, because it is what keeps FLEET‑2's `unclaimable` honest — a drained host must never read as a reason the queue can drain. The short-circuit in `worker-claim!` is the same answer reached without scanning anything, which is what keeps a drained fleet's polling free. Both, with a comment saying so, because removing either looks like a simplification. |
| **FLEET‑3h** | The console card | **Replace "Compute" outright** · vs adding a second card | The old card showed name, model and endpoint — and a pull worker has no endpoint, so every worker drew an empty cell while a box that had died an hour ago drew identically to one mid-job. It displayed none of `status`, `worker_state` or `last_seen_at`, all of which the API already answered. Leaving it beside a correct card would leave the misleading one on screen. |
| **FLEET‑3i** | The worker token in the UI | **Parked in `S` and shown until dismissed** · vs a toast · vs showing it again on request | It is in the create response and never again. A toast scrolls away, and there is no second chance — so it is a panel with the worker's command line beside it and a button that says the operator has it. Nothing can show it twice, and the copy says so rather than implying a recovery that does not exist. |

**The retire confirmation names the reversible thing instead.** `ui.wkretireconfirm`
says the token is revoked for good, that a held job returns to the queue, and
that draining is what to do for a temporary removal — because the destructive
button was the only one for so long that reaching for it is the habit.

**Still FLEET‑4**: the Queue view (per-job ages, hold reasons, lease countdowns,
filters by kind/status/executor). The Workers card carries the queue's three
summary numbers; the job-by-job view is its own slice.

## The queue, job by job (FLEET‑4) — **decided and BUILT 15 Oct 2026** (issue #70)

`GET /api/admin/queue`, `instance:manage`, and the console's **Queue** card.
FLEET‑2's summary answers "is the queue moving"; this answers "what is in it,
and what is each row waiting for".

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **FLEET‑4a** | A second route | **Its own paged route** · vs more keys on `/api/admin/workers` · vs `?scope=instance` on `GET /api/jobs` | The fleet read is a bounded dashboard that must stay cheap enough to poll; this needs filters, paging and a total, and folding them together would make every dashboard read pay for a page of jobs nobody asked for. Widening the team-tier `GET /api/jobs` is refused for FLEET‑2a's reason: it would make a team-scoped route answer past the org gate. |
| 🔑 **FLEET‑4b** | Two different answers to "why is this not running" | **`waiting` AND `runnable`, never merged** · vs one "blocked" field | They have different remedies and different owners. `waiting` is the platform holding admissible work behind a cap or a budget — it clears on its own, and QUOTA‑3 already says so on the job itself. `runnable: false` means no live worker can run the job at all, and nothing clears that but an operator. A single field would make a quota look like missing hardware, which is the mistake FLEET‑2d refused in the summary; the row-level view has to keep the same line. |
| **FLEET‑4c** | Where `waiting` comes from | **`team-hold`, memoized per team** · vs a second implementation · vs per row | The same admission seam `GET /api/jobs` asks (QUOTA‑3). It is a property of the TEAM, so a cross-team listing asks it once per team rather than once per row — QUOTA‑3's "once per listing", scaled to a listing that spans teams. Absent when nothing holds the job, never `{"reason":"worker"}`. |
| **FLEET‑4d** | Where `runnable` is reported | **Only on a QUEUED remote row** · vs every row | On an in-process kind no worker claims, so the field would be about nothing; on a running row the question is already answered. A field that is present but meaningless is how a reader learns to distrust the rest. |
| 🔑 **FLEET‑4e** | What it carries | **No `payload`, no `result`** · vs the full job row | This read crosses every team and every org on the instance, and a queue is managed by kind, age, team and holder — not by reading a team's prompts. The team-scoped `GET /api/jobs/:id` still has them under that team's own gate. Narrow by default is the discipline LAY‑11 and the funnel's public slice already follow; an operator permission is not a reason to widen a payload. |
| 🔑 **FLEET‑4f** | Ordering, and saying which one | **The claim's own order for `status=queued`, newest-first otherwise, and `order` reports which** · vs always newest-first · vs always the claim's order | Asked for the queued rows, the list is `priority DESC, created ASC` — the claim's `ORDER BY` — so position 1 really is the next job a free worker takes. That is only true of that one filter, and a list that LOOKED like the drain order while mixing in finished jobs would mislead about what runs next. So the answer says which ordering it is, and the card prints it. `COALESCE(created_epoch, 0)` because a pre‑0041 row has none and the two dialects sort NULLs opposite ways under ASC — zero is also right for drain order, a pre‑0041 job being the oldest thing there. |
| **FLEET‑4g** | Cancel | **Read-only** · vs an operator cancel across teams | `cancel-job!` is team-scoped and the permission rule is team-tier (owner-ok OR `jobs:cancel`, SCHED‑8). An operator stopping another company's job is a decision of its own, and not one to make inside a listing because the listing happened to show the row. |
| **FLEET‑4h** | Filters | **Equality on columns, AND-ed, clamped paging** · vs a query language | An operator asks "which kind", "whose", "which box". A filter that is IGNORED rather than refused is the `query-param` `assq` defect that answered a request for Dutch with Japanese, so an empty string means "no filter" and anything else reaches a column test. A bad `limit` or `offset` is clamped: this is a read, and nobody should have to decode a 400 to see their queue. |

**The kind dropdown is built from the fleet read**, not from the rows on the
current page — a filter assembled from the page would vanish the moment it was
used.

**A test that sets process-global state restores it in a `dynamic-wind`.**
`set-cap-for!` was overridden to prove the hold reason, and the restore sat after
the assertion: a failing `check-equal?` raises, the restore never ran, and a cap
of 0 leaked into every later test in the file, failing an unrelated one. The
cascade cost more time than the wrong expectation that started it.

## A releasable claim (PULL‑12) — **decided and BUILT 15 Oct 2026** (issue #61)

The last of the four questions #54 left as decisions. A worker that claimed a job
and then found it could not run it had two ways out and both blamed the job: fail
it, or go quiet and let the lease reap it. Each spent one of three attempts for
something that was the HOST's problem, and three of them retired a job nothing
was ever wrong with.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **PULL‑12a** | What a release costs the job | **Nothing: `attempt` is untouched** · vs a half-attempt · vs a separate attempt budget | This is the whole issue. "I claimed this and then found I lack the model" is a fact about the worker, and charging the job for it is how a healthy job reached `error` after three blameless hand-backs. Keeping one counter and spending it more slowly would still conflate the two, because what differs is not the weight but *whose* problem it was. |
| 🔑 **PULL‑12b** | What bounds a release loop | **A per-executor cool-off plus a release COUNT, in the row** · vs the attempt counter · vs nothing | With `attempt` deliberately untouched, nothing else would stop a worker that claims and releases in a tight loop. Two bounds, because they answer different shapes of the problem: `release_after` + `released_by` stop the spin (the releaser is not offered this job again for 30 s), and `releases` stops the pathology (past 10 the job fails, naming the hosts that let it go — work no worker will run needs a person, and saying so beats recycling it in silence). |
| 🔑 **PULL‑12c** | Who the cool-off applies to | **Only the executor that released it** · vs holding the job for everyone | A global hold would let one box short of VRAM delay a fleet that has capacity — a misbehaving worker's problem becomes every team's latency. Naming the releaser means every other worker may take the job in the same second. It remembers only the LAST releaser, which is enough: two bad boxes alternating still increment `releases`, and the ceiling ends it. |
| **PULL‑12d** | Where the exclusion is tested | **In the claim's WHERE clause** · vs filtering in Racket after the query | Issue #54's lesson, and the same trap: filtering after `LIMIT 64` bounds the ANSWER instead of the scan, so a worker whose own releases fill the window would see an empty queue it had just emptied itself. |
| **PULL‑12e** | An unknown reason | **Recorded as `other`, never refused** · vs a 400 | The asymmetry PULL‑11f drew, pointing the other way. On `/api/workers/state` the state IS the request, so an unknown one is refused. Here the RELEASE is the request and the reason rides along — refusing the call would leave the worker holding a job it has already said it cannot run, until the lease lapses and the job is charged an attempt for it. The same collapse `EXTRACT-REASONS` makes for an unknown extractor reason. |
| **PULL‑12f** | A release during cancellation | **Settle, never re-queue** · vs re-queueing | What `worker-fail!` already does, for SCHED‑8's reason: cancellation is final, and re-running work somebody stopped is the one outcome nobody asked for. |
| **PULL‑12g** | Visibility | **Audited before the write, and `releases` on the queue row** · vs the row alone | FLEET‑1's rule exactly: the re-queue clears `executor_id`, so after the write nothing says which host let go. A box that releases everything is precisely what an operator needs to find, and `attempt` — the field a reader would look at — is by design unchanged, so the queue view carries `releases` instead. |

**The reference worker releases on the way out.** A worker stopped mid-job is the
most ordinary way an attempt used to be spent on nothing: the lease lapsed two
minutes later and the job was charged for a Ctrl‑C. It now posts `release` with
`reason: "shutdown"` from the same plumber flush that reports `paused` (#58), the
release first in case the host dies between the two requests, and both
best-effort. FLEET‑3's drain is the other half of this: an operator drains a box,
its in-flight job comes back un-charged, and another worker takes it at once.

**A third-party worker needs no change.** `release` is a new endpoint; a worker
that never calls it behaves exactly as before.

## A worker writes a derived document (PULL‑13) — **decided and BUILT 15 Oct 2026** (issue #62)

The write counterpart of PULL‑9, and the asymmetry LAY‑6 closed for out-of-process
plugins, closed for remote workers: an OCR or CV worker could read the bytes its
job named and had nowhere to put the text layer or the annotated page it produced.
Its only channel back was the job's `result` — a jsexpr the kind validates, not a
document anything can search, share or run a pipeline on.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **PULL‑13a** | What warrants the write | **The output must DERIVE from a document the job's payload names — there is no standalone put** · vs any write the job's user could make | A worker token is not a key to the team's repository; it opens the documents the job it is running is about. PULL‑9 drew that line for the read, and a write anchored to nothing would erase it: the warrant for `files:write` here is the derivation itself. A kind that genuinely needs a free-standing write is a kind whose handler should run in-process or as an out-of-process plugin (LAY‑6), where the scope was declared. |
| 🔑 **PULL‑13b** | Who the write belongs to | **The job's own user, with `can?`, the storage quotas and the org gate deciding** · vs the executor as a principal | PULL‑9's rule, unchanged: no new authorization code. The worker acts for the person whose job it runs, so a viewer's job cannot write where a viewer could not, and the bytes are charged to the right team's `storage.bytes`. An executor-as-principal would need its own grants, its own quota subject and its own org story — three new mechanisms to misalign. |
| 🔑 **PULL‑13c** | What the output inherits | **`derive!`'s rule to the letter: the source's visibility at `repo-put!`, THEN `repo-inherit!` copies grants and writes the derivation row** · vs team-visible output · vs no inheritance | A private scan's text layer must be private from its first byte — inheritance after a visible write is a window, and DSH‑5 already decided the order. The derivation row is also the provenance `object-processing` reads, so a worker's output shows up beside a pipeline's in "Processed by". |
| **PULL‑13d** | Triggers on the output | **`#:derived?` is set, so an opted-in trigger never fires on a worker's own output** · vs letting it fire | The loop that bit the pipeline once already (DWF‑3): a trigger on `text/plain` firing on the OCR text it caused. `fire_on_derived` still means what it means — OTHER pipelines' outputs. |
| **PULL‑13e** | How refusals come back | **A refusal from the write itself (files:write, an invalid key, a storage quota) comes back VERBATIM; a forbidden source and a missing one stay ONE answer** · vs collapsing everything · vs naming everything | Two different questions. The source is somebody's existing document, so "does not exist" and "not yours" must stay indistinguishable or the payload becomes an existence oracle — PULL‑9's rule. The target is the worker's own new object, and a worker that cannot tell a quota from a typo'd key retries the unretryable. |
| **PULL‑13f** | The ceiling | **Bytes ride base64 on the existing wire, capped at `TELEMACHUS_MAX_UPLOAD`** · vs multipart · vs a presigned URL | LAY‑6's call, for LAY‑6's reasons: a worker is not a way past the front door's ceiling, a path would couple it to the blob store's layout, and a presigned URL needs the S3 listener and a second credential. An output too large for the inline wire is what the S3 listener is FOR — the job's user can hold an S3 key. |
| **PULL‑13g** | Visibility of the act | **Audited: `job.document.derived`, actor the executor, team the job's** · vs the derivation row alone | The derivation row says the document came from the source; it does not say a MACHINE wrote it, or which one. FLEET‑1's rule: the audit entry carries the job, the executor and the key, filed under the job's team so the people whose repository grew can see why. |

**The fence is the attempt**, as everywhere on this wire: lease + `claim_token`,
checked first, and a `canceling` job writes nothing — a canceled job's outputs
must not land, which is the same rule SCHED‑8 set for its result.

**This is JUDGE‑8's missing half**: a `judge.typed` worker can now write the
verdict back as a document beside the material it judged, inheriting its
visibility, before anyone builds the judge itself.

## A worker stops taking work while its model is down (PULL‑14) — **decided and BUILT 18 Oct 2026** (issue #93)

Reported from a workstation that shares its GPUs with other work: another program
holds the card for hours, the worker claims a job, the model call fails, and the
job is failed or released in a loop. The only way out was stopping the worker
from outside.

PULL‑12 built the blameless hand-back and defined `busy` — "it took the job and
has no capacity after all (out of VRAM)" — and **nothing ever sent it**. The
reference worker released only on shutdown. So the live behaviour was worse than
the issue describes: `worker-fail!` is TERMINAL (`status = 'error'`, no requeue),
so one model outage did not cost the job one of three attempts, it killed the job
on its first try.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **PULL‑14a** | Which model failures are the HOST's | **Cannot connect, timed out, or 502/503/504 → release `busy`** · vs failing all of them · vs releasing all of them | The split is "could this job ever be answered here" versus "is this job answerable at all". A 4xx is our own malformed request and a 500 is the model failing on THIS input: both are the job's problem and must still fail it, or a bad job rides the queue for ever being handed from worker to worker. A timeout is included deliberately though the issue did not list it — a card another process is thrashing answers by timing out, which is the single most common shape of this outage. |
| 🔑 **PULL‑14b** | A reply that cannot be read | **Stays a failure** · vs releasing it | `llm.rkt` already separates `malformed` from `network`/`timeout`, and a model answering with something unreadable is broken, not busy. Releasing it would send a genuinely bad job round the fleet until `MAX-RELEASES` failed it with "no executor would run it" — true, and ten workers' time later than the honest answer. |
| 🔑 **PULL‑14c** | Whether a release is enough | **No: a readiness gate as well** · vs the release alone | The release handles ONE job. The cool-off is 30 s for the releasing worker and `MAX-RELEASES` fails a job after 10, so one host busy for five minutes fails every queued job it touches. A worker that cannot serve must stop CLAIMING, not keep claiming and handing back. |
| 🔑 **PULL‑14d** | Who decides readiness | **An operator-supplied URL the worker GETs; 2xx means ready** · vs the platform probing VRAM · vs a worker-side heuristic | The platform needs no knowledge of GPUs, and should not grow any: the check can look at VRAM, memory, load, a lock file or the clock, and all of those are the operator's business. `TELEMACHUS_WORKER_READY_URL` unset means the mechanism does nothing, so no deployment and no third-party worker changes behaviour. |
| **PULL‑14e** | What a not-ready worker reports | **`paused`, ONCE per outage** · vs on every check · vs nothing | PULL‑11's state exists for exactly this: a host that is alive and refusing. Quiet is what a CRASHED worker looks like, which is the gap #58 opened and this closes for an outage. Once per outage, because a row every fifteen seconds tells an operator nothing the first one did not — and makes the executor's own history useless for finding when the outage began. Coming back needs no post: the claim already reports `ready`. |
| **PULL‑14f** | After a `busy` release | **The worker waits before claiming again** · vs claiming immediately | The server's cool-off keeps THIS job away from THIS executor and says nothing about the next one, so without a pause a worker whose model is down claims the whole queue and releases all of it — which past `MAX-RELEASES` fails those jobs for good. With a `READY_URL` set the gate takes over; the backoff is what keeps the unset case sane. |
| **PULL‑14g** | The readiness poll's transport | **Its own connection, opened and closed** · vs `http-sendrecv` | The measured descriptor leak behind the note above `http-post-json`: `http-sendrecv` abandons the socket under the response port and collection does not reclaim it. This runs before EVERY claim, so it is the one call in the worker that would reach the 1024-descriptor limit fastest. |

**A third-party worker needs no change.** Both halves are worker-side: no route,
no migration, no wire field. A worker that never reads `READY_URL` and fails on a
503 behaves exactly as it does today.

## Containers, Postgres in CI, and an unattended boot (DEPLOY) — **decided and BUILT 19 Oct 2026** (issue #89)

An integrator who runs everything as OCI containers on managed Postgres could not
adopt TMach without doing the packaging themselves: deployment was Nix-only,
there was no image and no compose file, and CI proved SQLite alone although
`DATABASE_URL` has taken a Postgres URL for months. The failures that packaging
exposes are the quiet kind — an instance that boots healthy and then cannot write
a document, or runs old code against a schema a newer replica already migrated.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **DEPLOY‑1** | How the image is built | **`dockerTools` from the same derivation `nix build` produces** · vs a Dockerfile · vs a Dockerfile that installs the Nix package | What ships is then what the unit suite ran inside, and there is no second build path to drift from the flake. A Dockerfile would be a second dependency pin, which is the deterministic-deps tenet applied to the thing customers actually run. The cost is that the image is Linux-only to BUILD, which is a real limit on a Mac and the reason `packages.container` is wrapped in `optionalAttrs isLinux` rather than failing obscurely. |
| 🔑 **DEPLOY‑2** | What the image contains | **The package, `curl`, a CA bundle, `/etc/passwd` — and NO shell** · vs a shell for debuggability · vs busybox | A shell is the first thing an attacker looks for and nothing in the image needs one. The consequence is real and documented: `docker exec … sh` does not work, so debugging is `docker logs` and the API. It also forces the HEALTHCHECK into the exec form, which hardcodes the port — accepted, because the alternative is shipping a shell to expand one variable. |
| 🔑 **DEPLOY‑3** | Where anything writable lives | **One volume, `/data`, and `/tmp` supplied by the caller** · vs a writable root · vs several volumes | The image is built to run under `--read-only`, and `/tmp` is deliberately NOT in it: a container under `--read-only` cannot create one, so the caller passes a tmpfs and the omission fails loudly at the first upload rather than silently writing into a layer. `HOME=/data` because Racket wants a writable home and the package's wrapper derives the data dir from it. |
| 🔑 **DEPLOY‑4** | What a startup check refuses over | **Three errors; two warnings that strict mode promotes** · vs refusing on all five · vs warning on all five | Refusing on all five would break every existing deployment, including the demo box, which serves plaintext HTTP on `0.0.0.0` across a tailnet — a real and reasonable posture. So "no secret key" (the supported trusted-database position, issue #19) and "no TLS on a public bind" are advice by default and refusals under `TELEMACHUS_STRICT_STARTUP`. The three that are always fatal are the ones no configuration could want: a blob store that cannot be written, migrations still pending, and a database migrated by a NEWER build. |
| 🔑 **DEPLOY‑5** | The newer-schema check | **An ERROR, naming the unknown migrations** · vs a warning · vs not checking | The dangerous direction, and nothing else in the system notices it: old code against a new schema writes rows the new code will misread. A half-rolled-back deployment is exactly how it happens. The remedy is to deploy the newer build, so carrying on corrupts data rather than merely failing — which is what makes it fatal rather than advisory. |
| 🔑 **DEPLOY‑6** | Which in-flight jobs a drain owns | **A register the pool keeps in memory** · vs `status='running' AND executor_id IS NULL` | The jobs table cannot answer this. An in-process claim leaves `executor_id` NULL, so that query is EVERY replica's pool work — and requeueing by it would steal a sibling's in-flight jobs the moment one replica restarted, which is precisely the deployment an image invites. The register is the shape the reference worker's `held` box already uses for one job, maintained in a `dynamic-wind` so it is right however the handler exits. |
| 🔑 **DEPLOY‑7** | What a drained job costs | **Nothing: neither `attempt` nor `releases` moves** · vs spending an attempt · vs counting it as a release | Without the drain, a restart left jobs `running` until the reaper requeued them with attempt+1 — so three ordinary deploys could push a healthy job to `error`. PULL‑12's rule, applied to the server. `releases` is deliberately not used either, although it is the bound on a worker's release loop: its ceiling FAILS the job, so a crashlooping deployment would mark every job it touched broken. Nothing bounds a restart loop here, on purpose — the honest outcome of a box that cannot stay up is a queue that does not move, not a queue full of jobs blamed for it. |
| **DEPLOY‑8** | How the signal is caught | **A plain `exn:break?` handler** · vs an FFI signal handler · vs `STOPSIGNAL SIGINT` | Measured rather than assumed: Racket delivers BOTH SIGTERM and SIGINT as `exn:break`, and plumber flushes run, so `docker stop`, `systemctl stop` and Ctrl‑C all reach the same handler with no FFI and no image-level signal override. The drain default (25s) is chosen to fit INSIDE the orchestrator's patience — Kubernetes allows 30s, systemd 90s, `docker stop` only 10 — because a drain that is SIGKILLed halfway is worse than none. |
| **DEPLOY‑9** | How the dialects are proved | **A CI matrix, both legs always run** · vs a nightly Postgres job · vs a second workflow | "It passed on SQLite" is exactly the state that let two Postgres bugs reach the HTTP smokes. `fail-fast: false`, so one dialect's failure does not hide the other's. Each HTTP smoke gets its OWN database on the Postgres leg, because `bootstrap!` is first-run-only — three smokes sharing one database leave the second and third holding an empty token and failing in ways that say nothing about Postgres. The e2e job stays single-dialect: it drives a browser and asserts on rendering and CSP, so doubling the slowest job would buy a second opinion on the part of the stack with no SQL in it. |
| **DEPLOY‑10** | "Upgrade from the previous release" | **Upgrade from EVERY prefix of the migration list** · vs checking out the previous tag · vs from-empty only | Stronger and cheaper. The release tags' migration ids are a prefix of today's, so "stop after N and come forward" IS the upgrade an operator on any past version performs — and it needs no checkout of two-month-old code that would not build. A from-empty run (which `nix build` already does) cannot catch the failure this is for: a migration written against today's tables rather than the tables as they were at its own point in history. Measured at 1.2s on SQLite and 4.5s on Postgres for all 44 points, so there is no reason to sample — and sampling is how the one bad migration stays hidden. |
| **DEPLOY‑11** | The configuration surface | **One hand-written page with a CI gate** · vs a generated reference · vs a registry refactor | 62 variables are read through plain `getenv`/`env*` calls scattered across the tree; declaring them in a registry would be a large refactor for a page that an operator reads once. So the page is written by hand and `scripts/check-config-reference.sh` fails the build in BOTH directions — a variable the code reads and the page omits, and a variable the page documents and nothing reads. It caught a stale row on its first run. |
| **DEPLOY‑12** | MinIO in the compose file | **Left out, with the reason written down** · vs including it · vs silence | Issue #89 asks for it. TMach SERVES an S3 API but cannot yet STORE blobs in a bucket — an S3-compatible blob-store backend is issue #82, unbuilt — so a MinIO container today would be a service nothing talks to. That reads as a broken example rather than a staged one, and the acceptance criterion's MinIO half genuinely depends on #82 rather than on this slice. |

**Kubernetes is plain YAML, not a chart** (the issue allows either): a chart's
`values.yaml` would be a second configuration surface to keep in step with
`docs/ops/configuration.md`, and the manifests are readable as-is. They set
`replicas: 1`, and that is a STORAGE limit rather than a concurrency one — the
PVC is ReadWriteOnce and `rs3` is a local directory, so a shared blob store
(#82) is what raises it. The scheduler itself is safe in several processes, which
is exactly what DEPLOY‑6 is for.

**The image is 1.74 GB, and Racket is 750 MB of it** — the runtime floor. The
optional PDF toolchain (pandoc, tectonic, biber's perl, librsvg's gtk) is about
400 MB more, and it is `find-executable-path`'d at CALL time (DWF‑6), so a slim
variant without it is possible and would save roughly a quarter. Not built here:
it is a second image to keep in step for a 23% saving against a floor that
dominates either way.

## Encrypting derived document content at rest (ENC) — **decided and BUILT 20 Oct 2026** (issue #83, slice 1)

Only replayable credentials were sealed (#19). The text extracted from a
document — the thing a tenant's regulated content actually becomes — sat in
`repo_text.content` in plaintext, as did the OCR page structure beside it. A
dump, a replica or a volume snapshot carried it.

Slice 1 is `repo_text` (content and spans): the DURABLE copy. `jobs.payload` and
`jobs.result` hold the same text transiently and are slice 2; #59's purge already
removes them on demand, so the two halves compose — durable content sealed,
transient content purged.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **ENC‑1** | Is it the secret key's switch? | **A SEPARATE switch, `TELEMACHUS_ENCRYPT_CONTENT`** · vs seal whenever a key exists · vs always | Sealing this column makes CONTENT SEARCH impossible — the match is a SQL `LIKE` over it. Riding on `TELEMACHUS_SECRET_KEY`, which is wanted on every instance, would silently remove a capability people use from every instance that took the recommended posture. #83 r3 permits exactly this shape ("or be an explicit opt-in per instance"). |
| 🔑 **ENC‑2** | What search does when sealed | **Drop the clause and SAY so (`content_search: false`)** · vs leave the clause in · vs refuse the query | Leaving a `LIKE` over ciphertext in place returns no content matches, so a search quietly stops looking inside documents and the answer reads as "there is no such document". Dropping the clause keeps key and filename matching useful; the flag is what lets a caller tell "not found" from "not looked for". Reported on every reply, not only when off, so a client branches rather than guesses. |
| 🔑 **ENC‑3** | The switch set with no key | **REFUSE TO START, unconditionally** · vs warn · vs seal with a derived default key | `secret-wrap` passes the value through when no key is configured — deliberately, so adopting a key needs no migration (#19). So this combination writes exactly the plaintext the operator turned the switch on to prevent, reports healthy, AND costs content search. It is the only startup problem in `startup.rkt` that is fatal regardless of `TELEMACHUS_STRICT_STARTUP`, because there is no reading of it under which the instance is doing what was asked. |
| 🔑 **ENC‑4** | Unsealing when the switch is off | **Always unseal; never conditional** · vs honour the switch on read | A row sealed while the switch was on must still open after it is turned off, or flipping it back would lose every document's extracted text. `secret-unwrap` returns an unwrapped value as-is, so the unconditional path is safe on plaintext rows too. |
| **ENC‑5** | Spans as well as content | **Sealed too** · vs content only | r1 names "OCR page structures", and a bbox list with page numbers is a map of where the words are. Sealing the text and leaving its geometry is half a measure. |
| **ENC‑6** | What `rewrap` touches | **Content columns ONLY when the switch is on** · vs always, like credentials | For the three credentials, "a key exists" means they should be sealed and `rewrap` sealing them is the point. Content is different: sealing it costs search, so an unconditional sweep would silently remove a capability from an instance that had deliberately kept it. `status` lists them separately for the same reason — the switch being off is the documented default, not a leak. |
| **ENC‑7** | What a failed unseal may say | **Not the plaintext, the ciphertext, or the key** · vs echo the value | The real failure is operational (a rotated key, a restored dump), and a message quoting what it could not read would put in the log precisely what the column was sealed to keep out of the database. r4's test asserts all three absences. |

### Slice 2 — `jobs.payload` and `jobs.result` (r2's encryption half), 20 Oct 2026

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **ENC‑8** | How the work was found | **Write the acceptance criterion as a WHOLE-DATABASE SCAN first, and let it name the leaks** · vs enumerate the SQL sites and audit the list | There are eleven sites, and the dangerous half is the WRITES: a missed read usually raises, a missed write stores plaintext in silence. Auditing one's own enumeration is the check that passes because it never looked in the right place. `test/dump-leak-tests.rkt` walks every table and column the schema HAS, with a CONTROL case proving the scanner finds the needle when encryption is off — without which the encrypted case proves nothing. It named `jobs.payload` and `jobs.result` precisely. |
| 🔑 **ENC‑9** | The worker wire | **A worker always receives PLAINTEXT; `worker-claim!` unseals** · vs ship ciphertext and give workers a key · vs a second wire | A worker holds no key and could not decrypt. The protection here is of the DATABASE — a dump, a replica, a snapshot — which is #19's narrow claim applied to content. The wire is therefore unchanged and a third-party worker needs no change; `pull-smoke` passes with the switch on. |
| 🔑 **ENC‑10** | Three reads that SWALLOW | **Unseal before parsing, and say so at each** · vs rely on "a missed unseal raises" | It does not raise at three sites. `run-claimed!` wraps the parse in a handler returning `(hasheq)`, so a missed unseal hands the kind an EMPTY payload and the job runs on nothing. PULL‑9's and PULL‑13's warrant checks do the same and answer `'not-in-job`, refusing a worker a document its own job names — safe, and wrong. The leak scan cannot see either, which is why `dump-leak-tests.rkt` also asserts a job's RESULT is still correct with encryption on. |
| **ENC‑11** | What the suite does when sealed | **`server-smoke` is MODE-AWARE and skips loudly** · vs let it fail · vs drop the assertions | Three assertions depend on content search (two document searches and LAY‑7's plugin-extractor demonstration), and one asserts the no-key posture a key contradicts. Four red lines an operator has to triage into "expected" and "not" is worse than a suite that names which capability is off. The skip is loud, and the default mode still RUNS all four. |
| **ENC‑12** | `requirements` | **NOT sealed** · vs seal everything on the row | It is the kind's matching criteria — models and capabilities — which a claim filters on in SQL and which carries no document content. |

**Acceptance criterion 1 is now met for the paths a job and a document take**, and
the test says exactly what that covers: a scan can only find a leak in a table the
fixture WROTE TO.

### Slice 3 — run bindings and translations, 20 Oct 2026. **r1 is complete.**

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **ENC‑13** | Which columns, decided how | **By extending the scan to drive a REAL workflow, not by enumeration** · vs sealing the list this slice started from | The list was `workflow_runs.input`, `workflow_steps.input`/`output` and `cursor_json`. The scan found **`workflow_runs.output` as well** — a fifth column that was never on it. That is the second time the method beat the enumeration (slice 2 was the first). |
| 🔑 **ENC‑14** | `translations.source_text` / `result_text` | **Sealed — they ARE platform-retained derived content** · vs out of scope with notes | This was classified with `notes` at first, as user-facing app content, and that was WRONG: `doc_translate` calls `translate!`, which writes a document's extracted text into `source_text` on **every pipeline translation**. The scan did not catch it either, because the probe workflow did not translate — found by reading the call chain after the scan went green. A scan sees exactly what its fixture does and no more. |
| 🔑 **ENC‑15** | Where the line is | **Content the platform retains BY ITSELF is sealed; a tool's deliberate product is not** · vs seal every table · vs seal none of the user-facing ones | `notes.title` keeps the text because the probe's workflow calls `create_note` — the note exists only because a workflow was TOLD to write one, and it lives in the store the Notes tab reads and searches. Sealing it is ENC‑2's trade applied to a far more visible capability. **So #83's acceptance criterion as literally written is not achievable**: any tool can write content anywhere. What is achievable, and is what the test asserts, is that no column the platform fills by itself retains it. |
| **ENC‑16** | `cursor_json`, which the scan cannot see | **Sealed anyway** · vs skip it because nothing observes a leak | A completed run wipes it to `'{}'`, so the scan only ever observes it empty. Mid-run it holds the bound values, and a dump taken then is precisely the case this protects. A limit of the test is not a reason to leave the column. |
| **ENC‑17** | What "Processed by" loses | **Narrower than it looks; and it SAYS so** · vs accept a silently short list | `object-processing` finds runs three ways — derivation rows, `doc_trigger_fires`, and a `LIKE` over the run's input. Only the third breaks, so what is lost is a hand-started run that produced no derived document. `runs_complete` on the reply reports it. |
| **ENC‑18** | Where the unsealing lives | **The two row projections, `row->run` and `row->step`** · vs at each caller | Thirteen write sites but only TWO reads: every caller goes through those projections. One place to get right instead of a dozen — which is also why the write sites are the ones the scan has to police. |

**Verified functionally, not only by absence:** `doc-pipeline-smoke` passes with
the switch ON — the whole upload → extract → fields → render → translate →
trigger path with every binding sealed — and the leak test asserts a run reaches
`status = 'done'` **before** it scans, because a broken engine writes fewer
columns and would pass a scan for entirely the wrong reason.
- **`translations.source_text` / `result_text`**, which are derived content by
  r1's wording and are searched by `search.rkt` — the same ENC‑2 trade, decided
  the same way, but a separate column pair.

### FEAT‑1…6 — a feature switch above the team (issue #63)

Feature flags were per TEAM only, and `docs/integrators-guide.md` stated the gap
rather than papering over it: an operator could not turn a feature off for the
whole instance, and on a multi-tenant box could not turn one off for one company.
Every new feature therefore shipped either on for everyone or off until each team
opted in.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| **FEAT‑1** | May a lower layer loosen? | **No — TIGHTEN ONLY, as SESS‑4** · vs the org's document wins whole, as branding's | A feature switch governs whether an endpoint ANSWERS, which makes it a control rather than a decoration. An instance switch a team can override is not a switch. Branding is the deliberate opposite — a company's look should replace the instance's — and the two now read alike in their own terms. |
| **FEAT‑2** | What the refusal looks like | **409, naming the layer** · vs store it and let resolution ignore it | A `feature_settings` row saying `enabled = 1` under an instance that says no would be a setting that lies to the next person who reads it. Turning a feature OFF stays allowed at every layer, including under a layer that already has: that is a team recording its own intention. |
| **FEAT‑3** | Absence | **Means enabled, at every layer** · vs seed the full set | An instance that has configured nothing behaves exactly as it did before this existed — no migration, no backfill. Only an explicit `false` blocks; a stored `true` is a layer saying it does not object, which is not the same as not having decided. (`hash-ref`'s default is `#f` and a stored `false` is also `#f`, so the KEY's presence is asked first.) |
| **FEAT‑4** | Where the upper layers live | **`instance_settings`, beside branding, localization, session policy, model roles, repo fields and retention** · vs a new table | The home the notes have said to use for the next instance-wide setting since branding introduced it. No migration at all for this slice. |
| **FEAT‑5** | How the answer is explained | **`disabled_by` on `GET /api/features`, naming the FURTHEST layer that objects** · vs a boolean | "Why is this tab missing" is the question, and three documents to diff by hand is a poor answer — `retention-sources`' rule and branding's `scope`. The furthest layer comes first because it is the one the reader cannot change from where they are standing: a team admin seeing `instance` knows not to look in their own settings. |
| **FEAT‑6** | An unknown feature | **Refused, not stored** | A flag that silently does nothing is how an operator concludes the switch is broken — the call an unknown theme token and an unknown retention field both make. Validated against `known-features` at every layer, including the existing per-team route, which did not check at all before. |
| **FEAT‑7** (#177) | The operator's layer in the console | **An Admin card** · vs leave it to HTTP | The instance switch is the one that means "this deployment does not do that", and it was the only layer with no UI — so the least reversible decision was the hardest to make. The org layer stays HTTP-only, as TEN‑2g decided for the whole company plane. |
| **FEAT‑8** (#177) | How many states the instance card offers | **Two: allowed and off** · vs three (not decided / allowed / off) | The issue asked for three, and three is wrong HERE. The document stores only `false`; absence and a stored `true` both mean "this layer does not object", and at the instance tier there is nothing above to object to — so an explicit `true` computes nothing, and a control that wrote one would offer an operator a setting with no effect, which is exactly what FEAT‑6 refuses for an unknown key. "Allow" therefore REMOVES the key. A `true` written by hand over HTTP still reads as allowed and is normalized away the first time it is toggled. The THREE states belong to the team card (FEAT‑9). |
| **FEAT‑9** (#177) | The team card under a layer that says no | **No Enable control at all, and the deciding layer is a column** · vs a button that 409s | FEAT‑1 is tighten-only and FEAT‑2 makes the attempt a refusal, so a button whose only outcome is an error is a control that cannot work. Disable STAYS available under a layer that already says no, because that is a team recording its own intention and it survives the instance switch being flipped back. Three statuses: on; off by this team; off by a layer above. |
| **FEAT‑10** (#177) | The instance write | **The whole document, every time** · vs a per-feature route | `PUT /api/instance-features` replaces the document because `feature-problem` validates it as a unit, and there is no per-feature route at this tier. A card that sent only the switch that moved would wipe every other switch the operator had set, silently. Pinned in `test/console-tests.rkt`. |
| **FEAT‑11** (#177) | Which tabs are gateable | **Five, and they are exactly the five routes carry a `#:feature` for** · vs widen `known-features` for the UI | Twelve tab names go through the console's feature filter and only `chat`, `agent`, `translate`, `search` and `workflows` can ever match; the other seven have no `#:feature` on any route, so a key for one would switch nothing off — FEAT‑6's own objection. Widening the set means gating the routes first, which is a product decision per feature. `reviews`, `localize`, `beta` and `admin` are added after the filter and are gated by permission instead. |

**A team's own `off` survives the instance flipping back on**, which is asserted
rather than left implicit: re-enabling instance-wide must not silently re-enable a
team that had opted out, because the team's row is its own decision and nobody
revoked it.

**Nothing that already asked `feature-enabled?` had to change.** The three layers
resolve INSIDE that predicate, so every gate that was already asking — the
endpoints, `require-feature`, the console's tab list, the workflow engine's own
check — is covered without being touched. The smoke asserts this by pinning the
UNCHANGED refusal wording (`Forbidden: search`) rather than a new message.

### IDEM‑1…9 — idempotency keys (issue #90)

`POST /api/workflows/<slug>/run` was not idempotent: a client that timed out and
retried started a SECOND run on the same object. For an integrator driving
TMach from a queued worker — the shape the issue describes — a retry is not
an unusual event, it is the normal one.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| **IDEM‑1** | What is replayed | **The stored RESPONSE and its stored STATUS CODE** · vs recompute the answer | The point of a retry is that the client never saw the first answer. Recomputing would mean deciding, per endpoint, what "the same answer again" is — and for a run that has since finished it is a DIFFERENT answer, which is exactly the confusion a retrying client cannot afford. The stored bytes are the only thing certainly equal to what the first call said. 202 comes back as 202. |
| **IDEM‑2** | The key's scope | **(team, key)** · vs (team, key, endpoint) | One key is one request. A client that sends the same key to two endpoints has made a mistake and a 409 says so; scoping per endpoint would accept it silently and leave two records claiming one key. The endpoint is in the FINGERPRINT, so the mistake is detected rather than tolerated. |
| **IDEM‑3** | The fingerprint | **Canonicalized — keys sorted recursively — then hashed** · vs `jsexpr->string` of the payload | `hasheq` iteration order is not stable across processes, so a fingerprint over a raw hash would differ between two replicas and a load-balanced instance would 409 a client's HONEST retry. The same trap that makes `json-out` sort and AUD‑13 hash a list. A LIST's order stays meaningful — it is the caller's sequence, not a hash's. |
| **IDEM‑4** | When the row is written | **AFTER the work succeeds** · vs before · vs two-phase | A row written first makes a crash mid-request permanent: the client retries, gets a stored answer for work that never happened, and nothing ever runs. Written last, a crash leaves no key, the retry does the work, and the worst case is the double execution that was the PRE-EXISTING behaviour. The remaining window needs a two-phase record and is not built — named here rather than discovered. |
| **IDEM‑5** | A failed request | **Not stored** · vs store every outcome | The retry that follows a 500 is the retry this feature exists for. Freezing the 500 would turn the key into a way to guarantee failure. |
| **IDEM‑6** | Past the 24h window | **A MISS, never a conflict** | After a day the client is not retrying, it is making a new request, and refusing it would be worse than performing it. A conflict there would make a key permanently poisonous. |
| **IDEM‑7** | The concurrent retry | **`ON CONFLICT DO NOTHING`; the first answer stands** | Two retries can both pass the lookup before either stores — a retrying client often sends twice in the same second. The loser must not FAIL a request it has already performed. |
| **IDEM‑8** | r2's `dedupe: true` | **Derives a key from (slug, definition VERSION, input)** · vs from the object id alone | The version is in the derivation deliberately: an EDITED workflow legitimately re-runs, which is the whole reason r3 exposes the version on the run. The object id and version r2 names are already IN the input for this pipeline (`process-upload` binds `object_id`), so hashing the input covers them without the endpoint having to know a particular workflow's shape. An explicit key always wins — the client's own idea of what its retry is beats ours. |
| **IDEM‑9** | A replay is VISIBLE | **`idempotent_replay: true` on the replayed body** | A silent replay and a fresh success are otherwise indistinguishable, and an integrator debugging a double-send needs to know which happened. It is added to the stored body on the way out, so the stored bytes stay exactly the first answer. |

**r4 is satisfied, with a deviation worth stating**: keys are purged on their OWN
24-hour window (on the reaper seam, the fourth thing there) rather than by a
team's retention rule. A key past the window is not retained data — it can never
be replayed — and a team that configured no retention policy would otherwise
accumulate them for ever. The stored response may name a document, so keeping it
longer than it can be used is a copy with no purpose.

**Which endpoints are covered, and the two refusals.** `POST
/api/workflows/<slug>/run` and `POST /api/jobs` are covered. The issue also names
two the implementation declines:

- **Token create is NOT covered, on purpose.** Its response carries a bearer
  token shown once, and replaying it means STORING that credential in the clear
  in a second table for 24 hours. #19's rule is that a token is stored as a
  peppered hash and never as itself; an idempotency feature must not be the one
  exception. A client that retries a token create gets two tokens and can revoke
  one, which is a far better outcome than a credential at rest.
- **The raw-body object PUT is NOT covered.** Its payload is an input PORT of up
  to 32 MiB, and fingerprinting it means buffering it — which is the exact cost
  the `web-kit/http1` data plane exists to avoid (DOC: bodies are a port, not
  bytes). Fingerprinting the key plus the length instead would replay a DIFFERENT
  document that happened to match, which is worse than not offering the feature.
  Re-PUTting is already a new VERSION rather than a duplicate object, and the
  blob is deduped by digest, so the damage a retry does there is bounded.
- Webhook create is #85's and unbuilt, so there is nothing to make idempotent yet.

### AUD‑1…9 — who read a document (issue #84, slice 1)

`audit_log` recorded create / update / delete / share / visibility for repo
objects and recorded READS nowhere. "Who viewed this document, when, from where"
is the question a regulated deployment is actually asked, and the platform could
not answer it at all.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| **AUD‑1** | Where the read is recorded | **At `repo-open`, the ONE seam that produces bytes** · vs at each of the nine call sites | Every door arrives there: the console download and the API GET, the S3 listener's GetObject / HeadObject / CopyObject source, LAY‑6's out-of-process `repo.get`, PULL‑9's worker read, the indexer, and `doc_text` inside a workflow step. Nine call sites would be nine chances to forget, and the tenth — written later — would be silent. `repo-put!`'s trigger hook is there for the same reason. The claim is TESTED, not asserted: a read through a door that was never taught to audit anything still appears. |
| **AUD‑2** | How the door is known | **A `current-read-context` parameter** · vs a new argument on `repo-open` | Nine signatures would change and a caller that forgot would read as the wrong door. The default is `"internal"`, which is honest — a read from a path that set no context is not an API read, and guessing `"api"` would put a client in the record that never existed. `READ-DOORS` is a CLOSED vocabulary, like `WORKER-STATES`: an export groups by it. |
| **AUD‑3** | What counts as a content read | **`repo-open` only; metadata GETs are not audited** · vs every `repo-get` | `repo-get` answers a listing, a share dialog, a "Processed by" panel. Auditing it would bury the reads that matter under rows about rendering a table — and r1's "API GET" is the GET that returns the document. The absence is ASSERTED in `server-smoke.sh` (the entry count does not move) so it is a decision rather than an oversight. |
| **AUD‑4** | A refused read | **Recorded, with the same shape, and the exception re-raised unchanged** · vs record only successes | r4, and it is the event an auditor is looking for. It has to be CAUGHT rather than inferred, because `repo-get` RAISES on a permission failure while answering `#f` for a miss. The entry is written even where the API deliberately collapses the two into one answer (the knowledge graph's rule, PULL‑9's, the derive warrant's): the caller is told one thing, the record keeps them apart. |
| **AUD‑5** | Actor, when a machine asked | **Principal stays the job's user; `actor_type`/`actor_id` name the machine** · vs one field | Two different questions. `can?` answered for the person, and an auditor needs to see that an executor or a run asked on their behalf, and which one. r1 says exactly this: "actor = the run, with the triggering actor recorded". `tool-run!`'s `#:run` is the one place a step invokes a tool, so it is the one place that carries it. |
| **AUD‑6** | The object key | **Never in the entry; ids only** · vs record the key for readability | r2. A key is operator-authored and routinely carries a name, a case number or a national id (`inbox/tanaka-hiroshi/…`). The entry stores the object and version ids and lets the key be joined from `repo_objects` under the access control that table already has. Both halves are asserted: the key is absent AND the id still resolves, or the rule would have cost the record its usefulness rather than only its risk. ENC‑20 took the same line for the trigger-failure entry. |
| **AUD‑7** | The byte range | **The REQUESTED range header, verbatim, beside the object's size** · vs the satisfied range | `aws s3 cp` issues parallel ranged GETs, and what an auditor needs is what each client ASKED for. The satisfied range is derivable from the request and the size, both of which the entry carries; the request's own words are what the client is accountable for. |
| **AUD‑8** | Who may read the RECORD | **`files:manage` on the object** · vs `files:read` | Who has looked at a document is information about the PEOPLE, not about the document: a colleague with a view grant must not be able to enumerate everyone else who opened it. `manage` is already what DSH‑2 requires to re-share or to change visibility — the permission that means "you decide who sees this" — so it is the right one for "you may see who did". On a PRIVATE object the refusal comes one step earlier and names `files:read`, which is the honest answer. |
| **AUD‑9** | `org_id` on the entry | **Denormalized onto the row** · vs joined through the team | The export is by org and date range (r3), a team can in principle be re-parented, and the audit log is the one table that must still read when the rows it describes are gone — DEL‑7 keeps it through an erasure, so it cannot depend on a join to a deleted team. |

**r5 (no sampling) is satisfied by construction** and is worth saying out loud:
nothing samples, nothing batches, and there is no knob that could. r6's ceiling is
met — one insert per read, and the two indexes migration 0046 adds serve the
reads an auditor makes rather than the write path.

**Slice 2 built r3** — the chain and the export, AUD‑10…16 below.

### AUD‑10…16 — the chain and the export (issue #84 r3, slice 2)

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| **AUD‑10** | When the chain is linked | **In a SWEEP on the reaper seam, every 60s** · vs at insert time | Two reasons and the first is a REQUIREMENT. r6 caps a read at "no more than one indexed insert", and linking at insert means a SELECT for the org's head before every write — on the path of every audited read, which is now every document read. The second is correctness: at insert time it would **FORK**, because two concurrent writers both read the same head and both claim it as their predecessor, and no lock fixes that across replicas. One sweep walking in `at_us` order cannot fork. |
| **AUD‑11** | The window that creates | **Reported, not hidden**: `audit-chain-status` gives `sealed`/`unsealed`, and verify and export BOTH seal first | Entries written since the last seal are real and unprotected. An operator's own command must never report an unsealed tail as if something were missing, and a reader must be able to see how large the gap is rather than discover it. |
| **AUD‑12** | What the digest covers | **Every column, named one by one, including `at_us`** · vs the id and a timestamp | A field NOT in the digest could be edited without breaking the chain, so the list IS the statement of what is protected — adding a column to `audit_log` means adding it here and bumping `CHAIN-VERSION`, which re-seals rather than silently protecting less. `at_us` is in it because a re-timestamping is a reordering, and the order is the evidence. |
| **AUD‑13** | The canonical form | **An ordered LIST, never a hash** | The FOURTH appearance of this trap: `hasheq` iteration order is not stable across processes, so hashing a hash makes the chain disagree with itself on another machine. (`json-out` sorts for it; JUDGE‑13's wire refuses re-serialization for it; LAY‑11's chain is a list for it.) `meta` is likewise exported VERBATIM as the stored string — parsing and re-emitting it would reorder its keys and the digest covers the stored bytes. |
| **AUD‑14** | What verify checks | **The hash AND the link** · vs the hash alone | A row whose `chain_prev` was rewritten to skip a deleted predecessor would otherwise verify — and that is precisely what somebody who understood the scheme would try. It has its own test, and that test fails against a hash-only verify. |
| **AUD‑15** | An entry with no org | **Chained in its own bucket, `-`** · vs left unchained | A single-tenant instance's entries all have no org, and so do instance-level events everywhere. Leaving them unchained would make them deletable without trace — on the one deployment shape where the whole log is in that bucket. |
| **AUD‑16** | The export's shape | **JSONL, streamed to the response port, chain fields included** · vs a JSON array · vs the chain stripped | One object per line appends and streams; an org's year of document reads is not something to hold in memory. The chain fields are IN it deliberately: a copy kept elsewhere can be verified against itself, and that external copy is the nearest thing to the external anchor this design is missing. The export is itself audited (`audit.exported`) — taking a copy of the log off the box is exactly the event a later reader wants to find. |

**The claim is the narrow one, stated as LAY‑11 states it.** The chain detects an
entry altered in place, an entry removed from the middle, and a rewritten link.
It does **NOT** detect a rewrite by anyone who can WRITE the table, who can
recompute every link after the row they changed — and that is the party an
administrative audit is most meant to defend against. Same shape as secrets at
rest, which defends a DUMP and not a HOST. Closing it needs an external anchor:
publishing the head hash somewhere the database's owner does not control. That is
a deployment decision rather than a schema one, and it is not built — but the
export is what makes it POSSIBLE without further code, which is the most this
slice can honestly claim.

**The acceptance criterion is tested at its stated scale**: 10,000 events seal
and verify, and three separate tamperings each break it and are each NAMED — a
field edited in place, an entry deleted from the middle, and `chain_prev`
rewritten to cover the deletion.

### ENC‑19…22 — the ERROR columns, and the logs (issue #83 r4, slice 4)

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| **ENC‑19** | Are the four `error` columns content? | **Yes — sealed like payload and result** (`jobs`, `workflow_runs`, `workflow_steps`, `doc_trigger_fires`) · vs leave them, as diagnostics | An error is `(exn-message e)` from an ARBITRARY handler, and this platform's own tools quote what they choked on BY DESIGN: the strict renderer names the placeholder, DWF‑5's extraction names the path, the knowledge-graph extractor refuses a snippet that is not a verbatim substring of the text. #59 had already written the reason down — it clears `error` on a purge because "a handler's message can quote the input it choked on" — and the column stayed plaintext until that purge, which for a failed job may be never. |
| **ENC‑20** | The audit log's copy | **The message is NOT copied into `audit_log.meta`** · vs seal the audit log · vs leave it | A failing trigger wrote `(exn-message e)` into the audit meta, and the audit log is the ONE table a retention sweep deliberately never clears (DEL‑7: the log IS the record). That copy therefore outlived every other, including the fire row #59 purges. Sealing the log instead would fight #84 r3's export. So: ONE home for the diagnostic (the fire row, sealed and purgeable), one for the event (the audit entry, ids only) — #59's own rule that "the audit entry carries no content", and #84 r2's rule that ids go in the log and the key is joined separately. |
| **ENC‑21** | A stored message that will not open | **Reads as `(the stored message could not be decrypted)`** · vs raise, as payload and result do | Asymmetric on purpose. A payload that will not open must raise: a handler running on an unreadable payload is worse than a refusal. An error is read by a PERSON debugging a failure, and a rotated key should cost them the diagnostic, never the job's STATUS — raising would take the whole listing down with it. |
| **ENC‑22** | What proves r4 | **A failure probe plus a captured-log scan, both positive-controlled** · vs inspect the code | The three existing leak cases could not see this at all: every job they run SUCCEEDS, so the scan walked four `error` columns finding nothing and said so. The new control fails a job AND a workflow step quoting the needle and asserts the scanner finds it in all three columns with the switch off; the acceptance case then asserts `'()` with it on, plus `current-output-port`/`current-error-port` captured and searched — a message sealed in the database and printed to the console is not protected, and a container's logs are the copy most likely to be read by a person and shipped onward. The audit‑meta assertion in `doc-triggers-tests.rkt` was controlled the same way: restoring the old meta fails it. |
| 🔑 **ENC‑23** | A credential declared through `define-sealed-column` | **`#:credential` — sealed whenever a key exists, never gated on the content switch** · vs the default conditional seal · vs a direct `secret-wrap` at each site | Found while building #114's feed credential, and it was LIVE: the macro's default seal is conditional on `TELEMACHUS_ENCRYPT_CONTENT`, which is correct for #83's content columns — sealing extracted text costs content search, so it waits to be asked for — and wrong for a replayable credential. #85's `webhooks.secret` was the first credential declared through the macro and inherited the gate, so on an instance with a key and the content switch off, **which is the documented default**, the signing secret was written IN THE CLEAR while `CREDENTIAL-SECRETS` and the module's own comment said it was sealed unconditionally. `rewrap` sealing it after the fact hid it further. The three credentials #19 sealed call `secret-wrap` directly and were never affected, which is why nothing caught it. Both directions are now pinned in `test/sealed-column-tests.rkt`: a credential column seals with a key alone, and in the SAME environment a content column does not — without that control the fix would have been indistinguishable from sealing everything, which would silently remove content search from every instance with a key. This is #119's shape: the gap was between what a note claimed and what the code did. |

**The functional half is asserted first**, as ENC‑18's note says: the failure must
still be RECORDED (`status = 'error'` on both the job and the run) and still be
READABLE through the API, needle and all. "No text anywhere" would otherwise pass
for a build that had stopped recording failures, which is the same answer for the
opposite reason — and sealing a diagnostic into illegibility would be a different
bug wearing this one's clothes.

**r6 is a documentation claim and is now made**: `docs/ops/secrets-at-rest-runbook.md`
§2b says why volume encryption is necessary and not sufficient — a running
database decrypts for anyone it answers, so `pg_dump`, a read replica, a restore
onto a shared-key host and any account with `SELECT` all travel in plaintext
however the disk is encrypted. The two layers compose; the column is the one that
survives being `SELECT`ed.
- **A blind index**, the alternative to losing search. A keyed token hash would
  keep matching without storing plaintext, and it leaks token frequency and
  co-occurrence; r3's "an index that does not store plaintext" arguably permits
  it, and it is a design with its own threat model rather than a flag.

## Deleting a document and everything it produced (DEL) — **decided and BUILT 20 Oct 2026** (issue #86, slice 1)

Deletion was per object. `DELETE /api/repo-obj/:id` removed versions, text and
bytes — and left every DERIVED object behind: the extracted JSON, the filled
form, each translation, separate objects under their own keys, each still
readable and still billed. A tenant asked for a document to be deleted and the
document's contents stayed in the repository three times over.

This is slice 1 of #86: cascade (r1), prefix (r2), the blob-reference guarantee
(r6) and the verification read (r7). Legal hold (r4), the retention rule engine
(r3) and tenant erasure (r5) are each their own slice.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **DEL‑1** | One blob-release rule | **ONE predicate, org-scoped on versions AND parts** · vs the two that existed | There were two implementations and each was wrong differently. `repo-delete!` counted versions in the org and **never consulted `repo_upload_parts`** — a staged part IS a blob in its upload's org namespace, so deleting an object whose digest a live upload had also staged destroyed the bytes that upload needed, and Complete Multipart then assembled from nothing. Reachable on the ordinary dedup path: re-uploading a document that already exists is exactly when a part and a version share a digest. Meanwhile `release-blob!` counted parts GLOBALLY, so one tenant's in-flight upload pinned another tenant's identical bytes for ever. Reaching the S3 listener's table from the repository is deliberate: a multipart upload BECOMES a repository object, so the two tables describe one lifecycle and a predicate that sees half of it is the bug above. |
| 🔑 **DEL‑2** | Cascade or detach | **Both, and detach REMOVES the derivation rows** · vs delete only · vs leave derivatives alone | Leaving them alone is the bug. But a derived document whose source is a tombstone, still recording that source, is a provenance record that LIES — and "Processed by" renders it. So detach is not "do nothing to the child": it is "stop claiming the parent". |
| 🔑 **DEL‑3** | A cascade that cannot delete everything | **ALL-OR-NOTHING on permission, refused by name** · vs skip what you cannot delete · vs best effort | A half-cascaded tree cannot be told apart from a finished one, and the obvious recovery — run it again — is what a partial failure makes unsafe. The caller detaches instead. |
| 🔑 **DEL‑4** | Prefix delete's default | **DRY RUN, `confirm=1` to act** · vs delete immediately · vs no prefix delete | The most destructive call in the API. A mistyped prefix is indistinguishable from a correct one at the point of use, and `?prefix=` with an empty value would mean "every object this team has" — which is refused outright rather than honoured. |
| **DEL‑5** | How a prefix delete deletes | **`repo-delete-tree!` per object** · vs bulk SQL | Slower, and it reuses the per-object permission check, the blob-release rule, the cascade and the storage refund rather than reimplementing all four. Roots are computed first and already-deleted objects skipped, because a derivative under the same prefix goes with its source. |
| **DEL‑6** | Walking the derivation graph | **Cycle-safe, deepest-first** · vs assume a tree | DWF‑3 stops a trigger firing on its own output, so the TRIGGER path cannot loop — but a hand-run workflow can derive A from B and later B from A, and nothing in the table enforces acyclicity. Deepest-first is required for correctness, not tidiness: releasing a parent's bytes before its children are gone lets a child's surviving version row keep them alive, leaving a tombstone pointing at bytes nobody can reach. |
| 🔑 **DEL‑7** | The verification read | **`GET /api/repo-obj/:id/traces`, and `audit` is NOT a trace** · vs trusting the DELETE's 200 | "I called DELETE and got a 200" is not evidence that a deletion request was honoured; a count per table a trace could hide in is. `audit` is reported precisely so an operator can see that it is the one thing deliberately left — an erasure keeps it (TEN‑2g, #86 r5) — rather than chasing it to zero. |
| **DEL‑8** | One audit event or many | **One for the tree** · vs one per object | The question an auditor asks is "was this deletion request honoured", and that is a question about the tree. The event names the key, the counts and the bytes. |

### Slice 2 — the retention rule engine (r3) and the hold flag, 20 Oct 2026

This is where **#83's "purge job payloads after N days" and #59's per-job lever
become ONE answer**. #59 built the lever and deliberately left the policy open;
#83 asked for a horizon; #86 r3 asked for the rule set. The sweep calls
`purge-job-content!` and `repo-delete-tree!` and implements neither again.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **DEL‑9** | An unknown age | **`IS NOT NULL` — unknown means NEVER STALE** · vs `COALESCE(epoch, 0)` | The first version used `COALESCE(epoch, 0)`, which reads a version written before migration 0045 as **infinitely old**. The migration backfills nothing, so the first instance to configure a policy would have **deleted every document it already had**. Positive-controlled: against that version the test fails on "a version with NO KNOWN AGE is never stale". The same applies to `jobs.created_epoch`, which 0041 also added without a backfill — and it is the line FLEET‑4 already took by reporting `null` rather than guessing. |
| 🔑 **DEL‑10** | Does anything apply by default? | **NO. An unconfigured instance deletes nothing** · vs #83's literal "default 7 days" | A real default means an upgrade silently begins deleting every existing instance's job payloads on a timer. 7 days is the documented recommendation and the value you get when you switch payload purging on without naming a horizon. Deliberate deviation from #83's wording, for the reason CLAUDE.md keeps giving: a change that breaks every existing deployment is not a default. |
| 🔑 **DEL‑11** | The hold arrives WITH the engine | **Build the flag and the veto now; r4's surface later** · vs ship the engine first | A rule that deletes on a schedule is a one-way door, and a hold is the only thing that can stop one. Shipping the engine first leaves every instance that configures a rule in between with no way to exempt a document under litigation — the single case holds exist for. r4's prefix holds, release workflow and its own trail are still its own slice. |
| 🔑 **DEL‑12** | How the layers combine | **The SHORTEST per field; `null` loses** · vs longest wins · vs most specific wins outright | SESS‑4's rule, where "tighter" means shorter. The instance sets a ceiling, an org may shorten it for its own data, a team may shorten further for its own — and a team cannot extend past its company's obligation. `retention-sources` reports WHICH layer won, because "why is my data going after 30 days" is the question an operator asks and three documents to diff by hand is a poor answer. |
| **DEL‑13** | Who the sweep acts as | **The team's own owner/admin** · vs a privileged system principal | Every deletion still passes `can?`, so a rule cannot remove what the team itself could not. There is deliberately no "system deletes anything" principal. |
| **DEL‑14** | A hold vs a deliberate delete | **A hold blocks the RULE, not the steward** · vs block all deletion | Blocking the object's own steward would mean a hold nobody could release by deleting the document on purpose. The retention engine is the thing that cannot be argued with; a person with `files:delete` can be. |
| **DEL‑15** | 0 days | **Refused outright** · vs fall back to a default | Every interval knob here falls back rather than reaching 0, because 0 means "immediately". A retention of 0 days deletes a document on arrival, and there is no safe horizon to substitute — so it is an error, not a fallback. An unknown FIELD is refused too (the theme-token call): a rule that does nothing while an operator believes data is being deleted is the worst way to be wrong. |
| **DEL‑16** | The sweep's cadence | **Hourly, on the existing `set-reaper!` seam** · vs its own thread · vs every tick | These rules are expressed in DAYS; a sweep running more often would re-scan the same teams to decide the same nothing. It rides the seam `reap-uploads!` already uses, with its own handler so one unreachable object cannot take the lease reaper down — and the lease reaper is the one thing on that tick that must never be skipped. |

**`?lifecycle` on the S3 listener still answers 501**, and r3's "expose the same
via `?lifecycle` as a thin mapping, or document why not" is answered with: not
yet, and the reason is that the mapping is not thin. S3 lifecycle is expressed
over key prefixes with transitions between storage classes; these rules are
expressed over a team's objects, its DERIVED objects, and its job payloads — two
of which have no S3 equivalent at all. A partial mapping that silently ignored
`delete_derived_after_days` would be worse than the honest 501 DOC‑13 already
gives.

**Still r4 and r5:** the hold's PREFIX surface and release workflow, and org
erasure. `?lifecycle` on the S3 listener still answers 501 by
design (DOC‑13) and r3's mapping question is open with it.

## Purging a job's content (PURGE) — **decided and BUILT 20 Oct 2026** (issue #59)

`jobs.payload` holds whatever a kind needs, and for `infer.chat` and the document
pipeline that is the document's own text; `result` holds the model's reply.
Nothing ever removed them. Issue #59 sat open as a DECISION — what the horizon
is, per-instance or per-team, what stays auditable — and the decision it was
waiting for arrived from a caller rather than from us: an application honouring a
user's deletion request can clear its own rows, and the text stays here, in a
table nobody reads once the run has finished.

**This slice is the LEVER, not the policy.** The horizon, whether it is per-team
or per-instance, and what evaluates it are #86's retention rules; a scheduled
sweep would call exactly this function. Building the lever first means the sweep
has something to call and the policy is still open — which is what the issue's
own status note asked for.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **PURGE‑1** | What a purge destroys | **`payload`, `result` AND `error`** · vs payload only · vs payload + result | A handler's error message can quote the input it choked on, so leaving `error` would leave the one copy of the text most likely to be read by a human. |
| 🔑 **PURGE‑2** | Is the row deleted? | **No — status, timings, attempts, executor and audit references all survive** · vs `DELETE FROM jobs` | The audit log is the record of what happened (QUOTA‑3, FLEET‑1); the job row need not be. A DELETE would also remove FLEET‑1's lease-trail anchor and make a team's own history lie about how much work it ran. A purged job stays accountable while its content does not. |
| 🔑 **PURGE‑3** | Why a `purged_at` column | **A marker, because `'{}'` is ambiguous** · vs clearing the fields and nothing else | `payload` is `NOT NULL DEFAULT '{}'`, so a purge sets it to exactly what a job with no payload looks like. Without a marker, "purged" and "never had anything" are the same row — nothing can show an operator that a deletion request was honoured, a retention sweep cannot skip what it has already done, and two concurrent purges cannot be made to settle to one audit entry. |
| 🔑 **PURGE‑4** | Which statuses | **`done`, `error`, `canceled` only** · vs any status · vs done only | A queued or running job's payload is the INPUT a handler is about to read or is reading; clearing it mid-flight fails the job in a way that looks like corruption. The caller cancels first, which is why this sits beside `cancel-job!`. **`canceled` IS purgeable**: the work stopped, so the input it was given can go. |
| **PURGE‑5** | Who may | **Owner-ok, OR `jobs:purge` for somebody else's** · vs reusing `jobs:cancel` · vs any team member | Exactly cancel's shape (SCHED‑8), with its own permission because the authorities differ: stopping a colleague's work loses nothing, and destroying the input and output it recorded does. Granted to admin, not member — a member needs neither for their own. |
| **PURGE‑6** | Already purged | **`purged: false`, not an error** · vs 409 · vs a second success | The caller asked for the content to be gone and it is. But a caller reconciling a deletion request, and a sweep counting what it cleared, both need to know whether THIS call did it. The guard is `purged_at IS NULL … RETURNING id`, which is also what makes two concurrent purges produce one audit entry. |
| **PURGE‑7** | What the audit entry holds | **The action, actor and job id — NO content** · vs recording what was purged | The point of the call is that the content stops existing; an audit row quoting it would be the one copy left behind. |
| **PURGE‑8** | A missing job vs another team's | **One answer, 404** · vs 403 for a job that exists elsewhere | Distinguishing them turns the endpoint into a probe for job ids across teams. The same collapse the knowledge graph and PULL‑9's document read make. |

**Deliberately still open** (and #59 stays closed on the lever, not the policy):
the scheduled sweep and its horizon. #83 requirement 2 proposes 7 days by
default; #86 requirement 3 puts `purge-job-payloads-after` in a per-team/org
retention policy evaluated by a scheduled job. Those two want one answer, not
two, and it belongs with #86's policy engine — the sweep then calls
`purge-job-content!` per row and needs nothing new here.

Also not built: **encryption** of payload and result while they still exist,
which is #83 requirement 2's other half. A purge removes content after the fact;
encryption protects it before. They are complementary and the second is a larger
slice (it reaches `repo_text`, derived JSON, and the search index that reads
them).

## Document bytes in a bucket (BLOB) — **decided and BUILT 20 Oct 2026** (issue #82)

The only blob backend was `rs3`, plaintext files on local disk. That is what kept
the Kubernetes example at `replicas: 1` (a `ReadWriteOnce` volume one pod can
mount), kept MinIO out of `compose.yaml`, and left integrators handling regulated
data with no way to put bytes in storage they already back up and audit. The seam
for a second backend has existed since DOC‑5 and nothing had used it.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **BLOB‑1** | Where the SigV4 signer comes from | **Compose `domain/s3/sigv4.rkt`'s existing primitives** · vs a second signer for outbound use · vs an AWS SDK | That module was built from the spec to VERIFY what clients send us and is pinned to AWS's own published vectors by 64 cases. Reusing it means ONE implementation faces both directions, so a canonicalisation bug breaks our server and our client together and loudly, instead of two subtly different implementations that agree with nobody. `test/s3-client-tests.rkt` makes the argument concrete: it hands what the signer produces to our own verifier, in process, and also checks a tampered request FAILS so the test cannot pass vacuously. |
| 🔑 **BLOB‑2** | How the payload hash is obtained | **It is the blob's digest — free** · vs buffering the object to hash it · vs `UNSIGNED-PAYLOAD` over TLS | A signed S3 PUT must carry `x-amz-content-sha256`. Normally that forces a choice between buffering a 2 GB object and not signing the payload at all. In a CONTENT-ADDRESSED store the digest we are handed IS that hash, by construction, so the body streams once, unbuffered, fully signed — requirement 5 falls out rather than being engineered. It also integrity-checks every write for nothing: bytes that disagree with our digest are refused by the far end as `XAmzContentSHA256Mismatch` instead of being stored under a name that lies. |
| **BLOB‑3** | The HTTP client | **A raw socket** · vs `net/http-client` · vs `web-kit/http1` (the server) | `http-conn-send!`'s `#:data` takes bytes (buffer everything) or a procedure, which makes the request CHUNKED — and S3 rejects chunked unless it is `aws-chunked` with per-chunk signatures, which sigv4.rkt deliberately does not implement for want of a client that uses it. A socket is what allows Content-Length plus a streamed body. |
| 🔑 **BLOB‑4** | Is encryption checked, or merely requested? | **The RESPONSE is checked** · vs trusting the request headers · vs a bucket-policy-only approach | What we asked for and what the bucket did are different claims, and a policy or replication rule that strips the header is invisible in the request. `TELEMACHUS_S3_BLOB_REQUIRE_ENCRYPTION` refuses a PUT whose reply carries no `x-amz-server-side-encryption`. The bucket-policy deny is documented **as well**, because the two catch different failures. |
| **BLOB‑5** | The object has already landed when that fires | **Refuse loudly and LEAVE it** · vs delete it · vs ignore | The response is the only source of truth, so there is no checking before writing. Quietly deleting an object we have just been told we do not understand would destroy the evidence an operator needs to see what their bucket actually did; the message says the object exists and why it was left. |
| **BLOB‑6** | Addressing style | **Path-style by DEFAULT** · vs virtual-host, as the AWS SDKs default | MinIO and Ceph RGW are the deployments this exists for and neither gets virtual-host DNS for free, while AWS still accepts path-style. The Host header is SIGNED, so this is not cosmetic — and it is computed in ONE place (`s3-host-header`), because two copies would drift and every request would fail `SignatureDoesNotMatch` with nothing naming which copy was wrong. |
| **BLOB‑7** | Where the boot health check lives | **Nowhere new — `startup.rkt`'s existing probe** · vs a store-specific health hook | That probe already writes a blob, reads it back and deletes it, and treats failure as fatal. Routed through this store it verifies endpoint reachability, credentials, bucket existence, Get/Put/Delete permission AND the encryption posture, because the probe PUT goes through BLOB‑4's assertion. Requirement 5's health check is therefore composition, not code, and there is no second mechanism to keep in step. |
| **BLOB‑8** | Retries | **429/5xx only, bounded, deterministic backoff** · vs retry everything · vs none | A 4xx is our own request and retrying spends the same error again — llm.rkt's rule for the model transport. Every operation here is idempotent (the key IS the content hash), so retries need no idempotency key (#90) to be safe. A GET that has begun handing bytes to its caller is never retried. |
| **BLOB‑9** | The migration's shape | **A CLI that re-hashes everything** · vs a schema migration · vs trusting the filename | NO ROW MOVES: `repo_versions` stores the digest and the store is addressed by it, so the same rows describe the blobs wherever they live — which is what makes this copyable at all, resumable, and safe to run on a live instance. Re-hashing is not belt-and-braces: `rs3` takes a blob's digest FROM ITS PATH, so a rotted file looks correct to anything that does not hash it, and a copy that trusted the name would propagate the rot under a name that lies about it. A corrupt blob is reported and left alone, because its row points at a digest nothing can satisfy and that is a data-loss question, not a copy-tool decision. |

**What is NOT built, and why** — rather than implied:

- **Multipart upload (requirement 4's second half).** A single signed PUT streams
  any object up to S3's documented 5 GiB single-request ceiling, which is 160×
  the default `TELEMACHUS_MAX_UPLOAD`. Multipart would mean buffering each part
  to hash it, so BLOB‑2's free-hash property does not extend to it and it is real
  work rather than a flag.
  **Where this actually bites**, since the front door's 32 MiB cap suggests
  otherwise: the S3 LISTENER assembles a multipart upload and hands the result to
  `repo-put!` (`op-complete-multipart`, assembling the parts with
  `input-port-append`), so an inbound multipart upload is exactly how a blob larger
  than the cap reaches the store. Above 5 GiB such a write fails. AWS documents
  `EntityTooLarge` for it and that has NOT been observed here — a 5 GiB upload is
  not something this suite does — so the claim worth making is the one that
  follows from the design rather than from a vendor's table: the request carries
  Content-Length AND the digest as its payload hash, so a rejected or truncated
  write cannot be mistaken for a complete one. It fails; it does not silently
  store a short object under a name that says otherwise.
- **Client-side envelope encryption (requirement 3)**, which the issue itself
  marks optional. It is the one item here that changes the DATA at rest, so it
  wants its own slice beside #83 (encrypting extracted text and payloads) rather
  than being bolted to a transport.
- **Instance-role and web-identity credentials (requirement 1).** Static keys are
  read, and the `AWS_*` names are accepted so a platform that already injects
  them needs no duplication. IMDS and web-identity are each a token exchange with
  its own refresh clock, and getting a refresh wrong fails hours after boot.
- **A MinIO container in CI (the acceptance criterion), because it is no longer
  possible.** MinIO's images are not freely pullable: `docker.io/minio/minio` and
  `quay.io/minio/minio` both answer `unauthorized` and `:latest` is unpublished
  (checked 20 Oct 2026). `localstack/localstack:latest` now requires a licence
  too. So CI runs the suite against THIS server's own S3 API — a real,
  independent SigV4 verifier over a real socket — and the suite's section 5 uses
  a real bucket when `S3_TEST_ENDPOINT` is set, skipping loudly when it is not.
  Those knobs are deliberately NOT named after a vendor: they were `MINIO_*`
  first, which pointed a reader at the single unavailable option and defaulted
  the credentials to `minioadmin` besides.
  **The SSE round trip is therefore unproven against a real bucket**, and the
  refusal half (a bucket that does not report encryption) is what is covered.

## Reading scans and photographs (OCR) — **decided and BUILT 19 Oct 2026** (issue #92)

An integrator running TMach headless as a document-processing service feeds
it phone photographs and scanned PDFs. Those were the two inputs the platform
could not read: `image/*` was `'unsupported` and a PDF with no text layer was
`'needs-ocr` (LAY‑8) — both the right answer, and both a dead end. LAY‑8 was
built as this slice's prerequisite, because until a scan could be *told apart*
from a blank page nothing could decide which documents needed an engine.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **OCR‑1** | Where the engine lives | **An in-process Racket extractor that shells out** · vs the out-of-process JSON-RPC plugin the issue suggests · vs a new job kind | LAY‑7 already settled this and its own comment names the case: "a plugin wrapping YomiToku or PaddleOCR is a few lines of Racket around a subprocess", and the built-in PDF reader is a pipe to `pdftotext`. LAY‑6's out-of-process seam is for a plugin acting as a TOOL, bytes shipped to it. Building this over JSON-RPC would mean a second extractor mechanism for one format, with the platform's cap, timeout, `'failed` containment and ownership rules all re-implemented on the far side. |
| 🔑 **OCR‑2** | How a scan stops being a dead end | **Claim `application/pdf`, which REPLACES the built-in reader** · vs a retry queue for `'needs-ocr` rows · vs a second pass in the indexer | Registering a type the platform already reads replaces its reader — LAY‑7's stated purpose. So requirement 5 needs no new machinery at all: no retry table, no state to reconcile, no second code path that can disagree with the first. |
| 🔑 **OCR‑3** | Text layer or pixels | **`pdftotext` FIRST; rasterise only a PDF with no layer** · vs always OCR for one code path · vs trust the content type | A born-digital PDF carries exact text where OCR guesses, and rasterising it is both slower and worse. The ORDER is load-bearing rather than an optimisation, and `test/ocr-tests.rkt` pins it by asserting a text-layer read produces **no spans** — spans would prove the page had been rasterised. |
| 🔑 **OCR‑4** | On by default? | **OFF unless `TELEMACHUS_OCR` is set** · vs on whenever `tesseract` is on PATH · vs a per-team setting | OCR‑2's power is the hazard: a reader that takes over PDF extraction for the whole instance because a binary happens to be installed is the shape of mistake the blob-store check refuses to make. #92 asks for "selectable per instance via config", so selection is explicit and the default is today's behaviour exactly. Measured consequence: the full unit suite is **1135 tests, unchanged**, because nothing registers without the switch. |
| **OCR‑5** | Enabled but unusable | **`init!` RAISES, so the plugin is reported failed** · vs register anyway and answer `'missing-tool` · vs log a warning | The operator asked for OCR. Answering `'missing-tool` on every scan while the boot log says nothing is how a deployment concludes the feature is broken. A raise is reported by the plugin-failure surface (#48) and `TELEMACHUS_PLUGINS_STRICT=1` escalates it to a refusal to start, which is what an unattended deployment wants. |
| 🔑 **OCR‑6** | Where the text comes from | **Built FROM the TSV rows, one engine run** · vs a `txt` run for text and a `tsv` run for regions | LAY‑5's offsets index into "the text this same call returned". Two runs can segment a page differently, so text from one and spans from the other is a provenance record that quietly points at the wrong characters — wrong in a way no test that checks only "is there text" would see. `test/ocr-tests.rkt` asserts every span's `substring` is its own word. |
| **OCR‑7** | Orientation | **`--psm 1`, content-based OSD** · vs reading EXIF · vs both | Strictly better than EXIF, not merely easier: leptonica does not apply an EXIF rotation, and a page fed through a scanner sideways has no EXIF to read. Detecting rotation from the content covers both cases with one flag. |
| **OCR‑8** | How the image reaches the engine | **STDIN** · vs a temp file path | `tesseract - -` the way the built-in pipes to `pdftotext`. A temp file also did not work: handed a path, leptonica picks its decoder from the FILENAME, so a suffix-less temp file exits 1 with the PNG's own magic bytes appearing where a filename belongs (having failed to decode it, tesseract falls back to reading the file as a list of image paths). Stdin has none of these questions and leaves nothing behind when a job is cancelled mid-read. |
| **OCR‑9** | An image with no text | **An honest EMPTY, never `'needs-ocr`** · vs `'failed` · vs `'unsupported` | `'needs-ocr` means "a reader that can do OCR would get further", and here that reader has just run — returning it would offer the document to the indexer forever. A photograph of a wall genuinely has no text, and that is a successful read of nothing. |
| **OCR‑10** | Bounding the work | **Pages capped in `pdftoppm`, a per-page timeout under its own custodian** · vs capping after rendering · vs no bound | This is the one extractor whose cost scales with its input. `-l` bounds the work in the renderer rather than rendering 400 pages to read 20, and the timeout's custodian takes the child and its pipes with it — killing the waiting thread alone leaves the subprocess alive, the measured mistake `llm.rkt` documents for HTTP. |

| **OCR‑11** | Is the engine in the OCI image? | **No; the plugin ships, the engine does not** · vs bundle all languages · vs a second `container-ocr` image | Measured: `tesseract` with its 129 bundled language files is a **1.1 GiB** closure against a 1.74 GB image — **+63%** for a feature that is off by default. English only is **129 MiB** (+7%), so the recipe an integrator wants is an override with the languages they actually use, and `docs/ops/container.md` carries it. A second image was rejected for the same reason DEPLOY‑12 rejected the slim variant: another artifact to keep in step, here for a trade in the opposite direction. The consequence is explicit rather than discovered — `TELEMACHUS_OCR=1` on the stock image fails to load and says why (OCR‑5). |

**What is NOT built, and why** — rather than implied:

- **Requirement 2's per-page derived JSON object** (page, text, confidence as a
  document beside the source). The extractor seam is
  `(in content-type) -> (values text reason spans)`: it cannot write a document,
  and widening it so one reader can would hand every plugin extractor the ability
  to write into the repository. The provenance half IS built — per-word page and
  bbox through LAY‑5's spans, which this is the first reader to fill — but
  per-word CONFIDENCE is dropped by `clean-spans`, whose shape is `start`/`end`/
  `page`/`bbox`. A derived object wants a tool or a workflow step, not this seam.
- **HEIC**, which needs `libheif` to become a PNG first. Claiming a type we would
  answer `'failed` for is worse than leaving it `'unsupported`, which is true.
- **A max-PIXELS bound** (requirement 6 asks for pages AND pixels). Pages, a
  per-page timeout and the team's existing job quota all bound it today; a pixel
  ceiling needs the image decoded to be measured, which is most of the cost.
- **A two-page TIFF fixture** (requirement 7). Tesseract pages multi-page TIFF
  natively and the page-numbering path is covered by a two-page PDF, but
  `racket/draw` cannot WRITE multi-page TIFF, so the fixture would need a
  committed binary — which is what the generated-fixture rule exists to avoid.

## A deferred job is visible (QUOTA‑3) — **decided and BUILT 14 Oct 2026** (issue #55)

Deferring an over-budget team's jobs is right and stays. Being **silent** about
it was the defect: the queue stopped with nothing `running`, nothing in the audit
log and no reason on the job, which is indistinguishable from a hang. The
operating notes' own warning that "a batch extraction stops after the first jobs
and looks like a hang" was being read as a bug report rather than as a budget.

| # | Decision | Recommendation · alternatives | What it implies |
|---|---|---|---|
| **QUOTA‑3** | A held job says which limit holds it | **Derive the reason; record the deferral once per window** · vs a column on `jobs` · vs failing the job | The reason is **DERIVED, never stored**. A column would be a second copy of a decision the next tick re-makes: raise the budget and the row would still say "quota" for a job about to run, which is worse than saying nothing — the same rule `missing`/`stale` live by in the Localization Manager, and the same reason executor health is computed rather than written down. It also means no migration. The admission seam therefore answers with a REASON instead of a boolean (`#:hold-reason` on `start-scheduler!`, `*hold-reason*`, `scheduler-hold-reason`), because one policy now has two askers — the claim, which must decide, and `GET /api/jobs`, which must explain. A boolean check plus a separate "why is this queued" reader would be two implementations of one policy, and they would drift. The seam must stay PURE: the job listing calls it on every read, so the audit entry is a second hook (`#:on-hold`) that fires only where a claim was really deferred. **The order mirrors `claim-next!`** — the concurrency cap before the budget — so a team that is both at its cap and over its budget is told about the cap, the one that clears on its own. **`waiting` is ABSENT, never `{"reason":"worker"}`,** when nothing is holding the job: the platform cannot know whether a worker for a remote kind exists, and a reason nothing stands behind is how a reader stops trusting the field. **The audit entry is once per window per (scope, subject, dimension)**, deduped by asking the audit log itself (`at_us >= the window's start`) rather than a table of its own — the log is already the record, a second store could disagree with it, and an in-memory set would forget on restart and re-announce what the operator has read. A sliding or unbounded window has no start, so those are floored at one entry an hour instead of pretending a boundary exists. `team_id` on the entry is the DEFERRED job's team even when the ORG's budget is what holds it, because `audit-list` filters by team and an entry carrying the org would be invisible to exactly the people whose work stopped. |

**`resets_at` is asked of the database, not computed in Racket.** `window-bounds`
in `quota.rkt` issues the dialect's own query because the answer must agree with
`window-clause`, which does not mean the same thing on both backends: SQLite's
`date('now')` is UTC while PostgreSQL's `CURRENT_DATE` follows the server's
timezone. The two smokes report boundaries seven hours apart on the same day for
that reason, and each is right about its own dialect — a reset time computed in
Racket would have been right on one and hours out on the other. Making the two
dialects agree on what a "day" is would be a separate change with a migration's
worth of consequences for every existing ledger row.

**A sliding window deliberately answers nothing.** `"minute"` loses its oldest
second of usage every second, so there is no instant at which the budget resets;
naming one would be a worse answer than naming none. `"total"` never resets.

## Typed judgments: JEV, and laya (JUDGE) — **explored 14 Oct 2026** (issue #31), **revised 15 Oct 2026** (issue #57)

Issue #31 asked whether to use TypeSafe AI's JEV, a hosted "System One" decision
model (`POST https://api.typesafe.ai/v1/systemone`). **Only JUDGE‑6 is built** —
the one item that turned out to be a defect rather than a design question. The
recommendation on the rest is deliberately not "integrate it" or "do not": it is
that the platform is missing a *seam*, that JEV is a good second backend for that
seam, and that it cannot be the first one.

**Read the revision at the end of this section first** (JUDGE‑7…12, 15 Oct 2026).
`IoTone/poplog`'s `packages/laya` self-hosts an open-weight model that takes the
same request, which supersedes JUDGE‑2 and JUDGE‑3 and replaces JUDGE‑5.

What it is, from its own documentation: you send a `state` (a string, object or
array) and a map of typed `questions`, and get back one answer per question, keyed
by your own question ids. Three types, and the shape is the whole product —
`noul` (a yes/no question answered 0..1), `choice` (one of up to 255 options, with
the full probability distribution), and `score` (an ordered rubric of 2–10 levels,
answered as a probability-weighted value). `choice` and `score` also carry a
`confidence` 0..1, and the response carries `usage` as input and output token
counts. It is not autoregressive and it is not a chat model: it cannot write a
translation, fill a schema or drive the agent loop.

**The finding that matters is that we already sell ourselves this guarantee.**
`domain/tools/jsonschema.rkt` plus "refuse rather than flag" is how this platform
gets a typed answer out of an untyped model: ask for a closed schema, validate,
refuse by path (`$.total: expected number, got string`), retry once. JEV moves
that guarantee from our side of the wire to the provider's. So the real question
is not "shall we call this API" but "is a **typed judgment** a first-class call in
this platform, distinct from a chat completion" — and the answer is yes, because
we make such calls already and each one reimplements the typing by hand.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **JUDGE‑1** | A typed-judgment seam | **Define one — `judge`, taking a state and typed questions, answering bounded values with a confidence** · vs keep hand-rolling each judgment · vs call JEV directly from the one caller that wants it | The platform makes judgment calls in at least three places and types each one differently: the beta prospect judge, LAY‑2's review decisions, and any triage that would route a document to a workflow. A seam makes the local backend and a hosted one interchangeable, which is the contract-first tenet applied to a call we are already making. It is the move `domain/repo/blobs.rkt` made for bytes and `register-extractor!` made for file formats. |
| 🔑 **JUDGE‑2** | The FIRST backend is local | **A chat model behind a closed JSON schema, in core, with no network dependency** · vs JEV first · vs nothing until JEV ships | JEV is proprietary, API-only and **cannot be self-hosted** — no Hugging Face weights, no on-premises option, the model runs on TypeSafe's infrastructure in the United States with no documented EU region. Making it the first backend would put a hosted third party on the critical path of a product whose tenets are clean MIT, self-hosted and privacy-first, and whose buyers chose it to avoid exactly that. The local backend also costs almost nothing to write: `jsonschema.rkt` validates, `outer-json` tolerates a fence, `response_format` already rides to the provider, and `content.rkt` already refuses a reply that cannot be read. |
| **JUDGE‑3** | Where JEV lives | **A plugin that registers a tool and, if it earns it, a second judge backend** · vs a second wire inside `model-exchange` · vs a push executor row | `model-exchange` is now the ONE place a model request leaves the process, and it speaks OpenAI chat-completions; "a second wire protocol" is recorded as deliberately deferred. JEV is a second wire — but it is also not a *chat* call, so it does not belong behind that seam at all. A plugin registering a tool is the shape the platform already has for a deployment-specific backend (RSCH‑1 made the same call for a search backend), it keeps a proprietary dependency out of a clean-MIT core, and `GET /api/plugins` then reports who holds it. |
| 🔑 **JUDGE‑4** | Egress and data policy | **Off by default, per-team feature flag, and the state that leaves is named in the audit entry** · vs on wherever configured | A judgment's `state` is the document's text. Sending it to `api.typesafe.ai` is a third-country transfer for an EU tenant, zero data retention is reported as an **enterprise-only** option, and the public documentation names no SOC 2. This is milder than RSCH‑3 — the endpoint is operator-configured, not model-chosen, so it is not an SSRF surface — but it is the same question the model URL already asks, and the honest answer is the one the tenet gives: it is an operator's choice, made explicitly, never a default. Multi-tenant instances need it per org, because one tenant's data-policy agreement is not another's. |
| **JUDGE‑5** | Metering | **Bill `usage.input_tokens + usage.output_tokens` against `ai.tokens.total`, like every other model call** · vs a dimension of its own | The response carries both counts, so the real number is available — which is more than the agent had before the executor work, where an estimate of 50 stood in for a measured 3,810. Output tokens are reported as unmetered by the vendor and input at a published per-million rate; bill both to us anyway, because the budget dimension is about what a team spent OUR platform's attention on, and a free output is still a call that happened. |
| **JUDGE‑6** | The beta judge should go through the validator regardless | **Yes, and this is worth doing whether or not JEV is ever called** · vs leaving it | `parse-verdict` in `domain/beta/beta.rkt` was a hand-rolled lenient parser — it found the outermost `{…}`, stripped trailing commas and handed back whatever was inside — and its caller fell back to `{valid: #f, score: 0, reasoning: "judge output not parseable"}`. It was the one judgment call in the platform that did **not** go through `domain/tools/jsonschema.rkt`, so a model answering `"score": "high"` was scored 0 and silently rejected a prospect, where the document pipeline would have refused by path. **BUILT 14 Oct 2026**, the one piece of this exploration that was a defect rather than a design: `VERDICT-SCHEMA` goes through the same validator, and `parse-verdict` now answers three distinct things — the verdict, a LIST of problems, or `#f` for no object at all — because the caller says something different about each. The refusal names the path. The schema is deliberately **open** (`additionalProperties`), unlike the pipeline's closed object: the judge prompt is operator-authored and an operator may legitimately ask for a field we do not know about. `valid` and `score` are both required, and **that is a behaviour change**: a judge prompt producing only a score used to yield a verdict the decide path read as invalid — a silent rejection — and now yields a named refusal. Same call as enforcing `required` on the funnel's own fields. |

**What this does NOT justify.** JEV cannot replace the model seam: it generates
nothing. It cannot replace `draft-acceptable?`, which counts braces and compares
placeholder names and is right to be deterministic — a model asked whether a
translation is good is a worse check than arithmetic on the string. And it cannot
replace `validate-extraction`, whose rule is that a snippet be a verbatim
substring of the text; that is a fact about two strings, not a judgment.

**Before anyone commits to a number**: access is reported as waitlisted early
access with no free tier, and the retention, residency and rate-limit figures in
circulation disagree with each other. Read the live pricing page and the DPA.

### Revisited 15 Oct 2026: laya changes the premise (JUDGE‑7…12, issue #57)

`IoTone/poplog`'s [`packages/laya`](https://github.com/IoTone/poplog/tree/dev/packages/laya)
is an out-of-tree Pop‑11 library that answers `typesafe`'s `ts_eval` with
**Laya**, an open-weight decision model, on Apple Silicon through MLX — no key,
no network after the first download, ~8–10 ms a question. It is built, measured
and merged, with its own `RESEARCH.md`.

**The sentence JUDGE‑2 rests on is no longer true.** It says JEV "is
proprietary, API-only and **cannot be self-hosted**", and concluded that the
seam's first backend had to be a chat model behind a closed JSON schema. Laya
takes the same `POST /v1/systemone` request — a `state` plus a map of
`noul`/`choice`/`score` questions — and returns the same answers. A self-hosted
typed-judgment backend exists, and it is a real decision model rather than a chat
model wearing a schema.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **JUDGE‑7** | Which backend is first | **Laya behind the seam; the chat-and-schema backend becomes the SECOND** · vs JUDGE‑2's order · vs laya only | Supersedes JUDGE‑2. A chat model behind `jsonschema.rkt` is still the right fallback — it is the only backend that runs in CI and on a box with no Apple Silicon — but it should not be the reference implementation of a typed judgment when a typed-judgment *model* can be self-hosted. JUDGE‑6 already shipped that fallback's shape for the beta judge, so the second backend is partly built. |
| 🔑 **JUDGE‑8** | How it is reached | **A remote JOB KIND and a pull worker — no new wire, no plugin** · vs a push executor with a second protocol · vs JUDGE‑3's plugin · vs in-process | Supersedes JUDGE‑3, in a cheaper direction. JUDGE‑3 was right that `model-exchange` is single-wire OpenAI chat-completions and that `/v1/systemone` is not a chat call — and the notes already defer a second wire protocol deliberately. Laya shows we need none: register `judge.typed` with `#:remote? #t` and a `#:validate`, and a small worker on the Mac calls `laya_serve.py --stdio` (0.11 ms) or its loopback HTTP. TMach's side is a kind registration and a validator. It inherits, with no new code: quota admission, the org gate, cancel and `canceling` (SCHED‑8), the lease and the `claim_token` fence (#24), the reported state (PULL‑11), the blameless release (PULL‑12), and every one of FLEET‑1…4's visibility surfaces. A push executor would also mean TMach reaching OUT to a Mac on somebody's desk; a pull worker means the Mac reaches in and needs no inbound port, which is PULL‑1's whole argument. |
| 🔑 **JUDGE‑9** | How a question is represented | **Ordered lists, never hashes — and NEVER sorted** · vs a jsexpr hash · vs sorting for stability | Measured, in `RESEARCH.md` §3.1: on one checkpoint **1 of 6 orderings** of three options agreed with the written order, and one option's probability moved by **0.54**. Option order is part of the question. Poplog hit this as a live defect (G3/G4): its hash-ordered JSON sent `billing, technical, sales, legal, hr` out as `technical, hr, billing, sales, legal` and got different answers, and it had to add an insertion-ordered `json_object` to `LIB JSON` to fix it. **Racket's `hasheq` has exactly the same hazard**, and this platform already knows it twice — `json-out` sorts so the docs gate cannot cry wolf, and LAY‑11's canonical form is "an ordered LIST, never a hash". This is the third instance with the **opposite remedy**: sorting here would change the answer, so order must be *preserved*, not normalized. A reader who knows `json-out` will reach for sorting; the seam has to make that impossible. |
| 🔑 **JUDGE‑10** | Metering | **Its own dimension, `ai.judgments.total`** · vs JUDGE‑5's `ai.tokens.total` | Supersedes JUDGE‑5. Laya generates nothing — a single forward pass — so `output_tokens` is **always 0**, and input tokens for one question are a handful. Metered against `ai.tokens.total` a judgment is effectively free, and free means unbounded: exactly the shape of the agent's under-count, where "a live tool-using run measured 3,810 tokens where the old code billed 50 — so the budget was never reached and the missing check never showed". The quota ledger is dimension-keyed, so a new dimension needs **no migration**. |
| 🔑 **JUDGE‑11** | What a stored verdict must carry | **Checkpoint commit, dtype and batch setting — and LAY‑11 hashes it AS GIVEN** · vs the answer alone · vs recomputing to verify | `ts_last_model` is `aac6fef/laya-mlx@20aed815… float16`, and the README says to record it beside any result you keep, because both change probabilities. Worse for an audit: §3.2 measures **50.2% of answers differing in the 3rd–4th decimal depending on their batch-mates**, exact only at `batch_size=1` (~1.7× for 16 questions). So a judgment is reproducible only if the checkpoint, the precision, the question order AND the batch policy are all pinned — and LAY‑11's decision chain must hash the verdict as it was given and **never** re-ask the model and compare, because a legitimate re-ask can differ. This also promotes the LAY‑10 finding from a nicety to a requirement: `model-exchange` already resolves the model and returns it as a third value that both call sites discard. A typed judgment without its checkpoint is unauditable. |
| **JUDGE‑12** | Where it can run | **Never in-process, never in CI** · vs vendoring it | Laya is MLX on Apple Silicon, macOS 14+; this platform builds under Nix and runs on Linux. So the CI-testable backend is the chat-and-schema one, or a scripted double — the shape `test/mock-llm.rkt` already provides for chat and `tests/fake_laya_server.py` provides on the Pop‑11 side. Pinning a worker to one developer's Mac is also the R2 mistake in miniature; it belongs to an operator's fleet, which is what FLEET‑3's drain and PULL‑11's reported state are for. |

**What does not change.** JUDGE‑1 (one seam, `judge`, taking a state and typed
questions) stands as written. JUDGE‑4 stands and matters more, not less: the
state leaving the process now leaves for another HOST, so "off by default,
per-team, per-org, and the state that leaves is named in the audit entry" is the
whole of the privacy story. JUDGE‑6 is built. And the limits still hold — this
replaces neither the model seam, nor `draft-acceptable?`, nor
`validate-extraction`.

**Two things to measure before building, not after.** Whether the hosted Jev is
order-sensitive is still unknown (poplog's G3/G4 fixed the client either way);
and `judge.typed`'s validator has to be written against a real laya answer, which
carries more than Jev's — every answer has `probabilities` and `action`, and a
`score` answer has `legend`.

### Finished 15 Oct 2026: the wire, the bridge, and the build plan (JUDGE‑13…14)

The revision above left one question genuinely open: JUDGE‑9 says the question
and option order is part of the question, and the platform's own plumbing is
built to destroy exactly that. `/v1/systemone`'s `questions` and a choice's
`criteria` are JSON **objects** whose key order carries meaning (poplog had to
add an insertion-ordered `json_object` to `LIB JSON` to fix it — their G3/G4),
while `jobs.payload` is a jsexpr: a `hasheq` has no key order, `jsexpr->string`
would scramble it, and `json-out` would sort it, each silently.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **JUDGE‑13** | How an ordered request survives the platform | **The job payload carries the request as COMPOSED BYTES (`request_json`), written once by an ordered-object writer at enqueue; every hop after that treats it as a string; the worker forwards it verbatim; the verdict is stored as RECEIVED (`verdict_json`)** · vs an ordered association-list shape every worker must serialize · vs trusting arrays to be enough | Order preservation becomes a property of CONSTRUCTION rather than of every hop's care — one writer, and no re-serialization anywhere on the path, so no hop can scramble what it never parses. Validation parses a copy to check; the bytes that travel are the bytes composed. It is JUDGE‑11's "hash the verdict as given" applied symmetrically to the request, and together they make the stored pair (request_json, verdict_json) exactly what crossed the wire — which is what an audit replays and what LAY‑11 chains. Arrays alone are NOT enough: `score` criteria are an array, but `questions` and choice `criteria` are objects on JEV's own wire, and we do not get to redesign it (that compatibility is the whole point of laya). |
| 🔑 **JUDGE‑14** | What laya must expose | **Nothing new.** `laya_serve.py --port` already speaks `POST /v1/systemone` + `GET /v1/health` on loopback; the bridge is a TMach pull worker on the same host · vs a Telemachus-specific API on laya · vs embedding laya in the worker | Verified against `packages/laya` at `dev`: the HTTP transport exists, loopback by default, with `--model`, `--revision`, `--dtype`, `--device` and `--batch-size` flags — everything JUDGE‑11 needs to pin is a startup flag, and G1 already made the response's `model` the real checkpoint (`aac6fef/laya-mlx@20aed81… float16`). The worker forwards `request_json` as the body, returns the answer as received, and maps `GET /v1/health` onto PULL‑11's ready/paused report. Run laya with **`--batch-size 1`**: exact answer-independence, ~1.7× latency on a 16-question request, and the one configuration under which a stored verdict is reproducible at all. If the laya API ever grows for this, it grows conveniences, not contract — the contract is JEV's, and matching it is laya's reason for existing. |

**The validator's target shape is pinned** (from laya's served answers and its own
test double): `{model, answers: {qid: {type, noul|choice|score, confidence,
probabilities?, action?, order?, legend?}}, usage: {input_tokens, output_tokens:
0}}`. The validator checks that every question asked is answered with its own
type and that `model` names a checkpoint, and is OPEN to fields it does not know
— the call JUDGE‑6 made for the beta verdict, for the same reason: the answer
side may legitimately say more than we asked.

**The build plan, in order** — each slice useful alone, the first the one that is
expensive to retrofit:

1. **JUDGE‑9 + 13** — `domain/judge/wire.rkt`: an ordered-object JSON writer
   (association lists in, object text out, never through `json-out`), the request
   composer (state + typed questions → `request_json`), and the verdict
   parser/validator above. Pure, no server, CI-testable in full.
2. **JUDGE‑8** — the seam and the kind: `judge` (JUDGE‑1's one entry point)
   enqueues remote kind `judge.typed` carrying `request_json`; `#:validate` from
   slice 1 (a remote kind requires one). The reference worker grows a handler
   that forwards to `TELEMACHUS_LAYA_URL` and answers verbatim. Everything else —
   quota admission, the org gate, cancel, lease, fence, release, drain, the fleet
   view — is inherited from the row, which is why this is a kind and not a wire.
3. **JUDGE‑10** — metering: `ai.judgments.total`, one per question, charged by
   the kind's completion path the way `infer.chat` bills `tokens_used`; no
   migration (quota dimensions are rows).
4. **JUDGE‑11** — storage: the verdict kept AS RECEIVED beside the request, the
   `model` string (checkpoint + revision + dtype) on it, and — now that PULL‑13
   exists — optionally written as a DOCUMENT derived from the judged material,
   inheriting its visibility and grants, which is where JUDGE‑4's privacy rule
   and the repository's existing authorization meet.
5. **JUDGE‑7** — the second backend: chat-and-schema behind the same seam and the
   same validator, the only backend CI can run end to end (JUDGE‑12); laya's
   paths are CI-tested against a scripted `/v1/systemone` double. JUDGE‑6's beta
   judge may then route through the seam instead of its own call.

**Still open, deliberately:** whether the hosted Jev is order-sensitive
(unmeasurable from here and moot while laya is the backend), and KG‑7's `utility`
role growing a `judge` sibling — not until two things want different judges.

## Research, bring-your-own-key, data-policy routing (RSCH / BYOK / ZDR) — **proposed 13 Oct 2026**

Three questions raised while testing. **None of the three is built.** They are
recorded together because the first is a feature the requirements already claim,
and the other two are terms from the hosted-gateway world that land on seams this
platform already has — one of them almost entirely.

### RSCH — a research surface

`docs/FeatureRequirements.md` marks **Research** done by redefining it as the
documents / repository app, and `research:use` is granted to member, admin and
owner while **nothing reads it** — described as "Use the research surfaces",
which asserts a surface that does not exist. The ancestor feature is specified:
`docs/odysseus-Features.md` §1.2, a cancellable Think → Search → Extract →
Synthesize loop producing a cited Markdown and HTML report.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **RSCH‑1** | Where the loop lives | **A shipped plugin with its own workflow** · vs a core console tab beside Chat and Translate · vs nothing | Almost everything the loop needs is built: the scheduler gives it a cancellable background job with SCHED‑8's cancel and SCHED‑9's run-time ceiling for free, the workflow engine gives it the step loop and survives a restart because the rows are the state, `doc_render` writes the report, and quota admission meters it against `ai.tokens.total`. What is missing is **one tool pair**: there is no `web_search` or `web_fetch` in the registry — `domain/tools/convert.rkt` only normalizes the NAME `web_search` when translating somebody else's tool schema inbound, which is easy to mistake for an implementation. The search backend is deployment-specific (a self-hosted SearxNG, a vendor API), so it belongs behind a plugin-registered tool rather than in core — the call LAY‑7 made for extractors. |
| **RSCH‑2** | Where the report lands | **A repo object** — `research/<slug>-<id8>.md`, `text/markdown`, returned as an artifact of kind `document` · vs a `research_*` table · vs blobs in a directory | Migration `0022-fold-documents` already folded `documents` into the repository, so a text report inherits visibility, sharing, search over extracted text, derivations and `storage.bytes` with no new code. The on-disk variant is what forced Odysseus to write a `tidy_research` action to GC orphans — a second lifecycle to maintain for a document the repository already knows how to own. |
| 🔑 **RSCH‑3** | Egress | **A per-team feature flag, and a fetcher that refuses private address space with DNS resolved ONCE and the connection pinned to the resolved address** · vs trusting the URLs the model chose · vs search snippets only, no fetch | Today every outbound request goes to an endpoint the **operator** configured — the model URL, `executors.json`, an MCP server. A research loop would be the first thing to fetch a URL a *model* picked out of a *search result*, which turns the server into an SSRF proxy onto its own network: the cloud metadata endpoint, the database, the ArangoDB on 8529. "Nothing is trusted for looking private" is the call `domain/authz/peer.rkt` already made for inbound identity; this is the same rule pointed outward. Resolving the name twice is the rebinding hole — but "resolve once and connect to the address" is the WRONG fix and #142 (EGR‑3) replaced it: connecting to a literal breaks TLS verification and SNI, and round-robin alone makes a prior resolution disagree with the peer. The connection is made by NAME and the socket's real PEER is vetted before a byte is written, which is the same property without the cost. This is the row that gates the feature for a privacy-first, self-hosted product. |
| **RSCH‑4** | Citations | **A claim whose source is not in the fetched set is REFUSED, not footnoted** · vs trusting the model's bibliography | `validate-extraction` in the knowledge graph already refuses a reply whose snippet is not a verbatim substring of the text, and the step retries once. Reuse it: a fabricated citation is the worst output this feature can produce, and it is also the one that looks most finished. KG‑3's "nothing enters without a source" is the same principle one layer up. |
| **RSCH‑5** | The `research:use` permission | **It gates the surface when the surface ships; until then its description says nothing reads it** · vs leaving the text as it is · vs removing the permission | RBAC‑5b's treatment of `roles:manage`, for RBAC‑5b's reason: a permission with nothing behind it reads as an unfinished feature unless the text says otherwise. Removing it would be worse — it is in two built-in roles and in the committed `docs/reference/permissions.md`, so dropping it breaks the published catalog for no gain. Note the cost of the edit: the description is a `doc.*` message, so it moves `strings.json`, `en.json`, `ja.json` and both rendered reference trees, and the localize gate will name it. |

### BYOK — whose provider key pays

A routing gateway (OpenRouter is the common one) puts a single OpenAI-compatible
endpoint in front of many providers. **BYOK** means storing your own upstream
provider keys in the gateway, so inference bills your provider account under your
own agreements and committed spend while the gateway charges for routing rather
than for tokens. Nothing about the gateway is special to us — it is an
OpenAI-compatible push backend, so `TELEMACHUS_MODEL_URL=https://openrouter.ai/api/v1/chat/completions`
already works today, and so does a push executor row. What BYOK names in this
platform's own vocabulary is **per-org provider credentials**, listed in these
notes as deliberately deferred. It turns out to be mostly built, and the gap is
not where the note implies.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **BYOK‑1** | Where a tenant's key lives | **The per-org push executor row that already exists** · vs a new `provider_credentials` table · vs instance-wide keys only | `POST /api/org/executors` (TEN‑2e) already lets an org admin register a push backend with its own `url`, `model` and `key`; `executors.org_id` scopes the row and the key is sealed by secretbox under the AAD `executors.secret_key:<row-id>`. There is no table to add and no new credential type — PULL‑6 is what pays for this. The deferral in the notes overstates the remaining work. |
| 🔑 **BYOK‑2** | The registry loses the org — and BYOK is what makes that expensive | **Key the backend registry by (org, name), refuse a model role naming an executor outside the caller's org, and add the missing `UNIQUE(org_id, name)`** · vs leaving routing operator-only and documenting the gap (today) | `domain/exec/federation.rkt` keys the in-memory registry by **bare name**, and `register-executor!` REPLACES by name; `executors.name` carries no unique constraint at all, only an index. `load-push-executors!` loads every push row `ORDER BY name` regardless of `org_id`, so two orgs that both call their gateway `openrouter` collapse to ONE entry and whichever row loads last silently wins. These notes already record the lesser half of this — "a team admin can point a model role at any executor name, including another org's, because `executor-known?` does not filter by org" — and judged it acceptable because routing on `/api/ai/chat` and `/api/agent` is operator-only. But **`PUT /api/model-roles` is `settings:manage`**, a team admin, and it resolves a bare name. With instance-wide keys that is a misroute. With per-org keys it is one tenant's prompts sent through another tenant's gateway and billed to their provider account. The org gate cannot catch it: step 0 of `can?` never runs, because a registry lookup is not a `can?` call. |
| **BYOK‑3** | Provider-specific routing fields | **An operator-set `extras` document on the executor row, merged into the request body and reported by `GET /api/executors`** · vs a named OpenRouter driver · vs a fixed allowlist of fields | `model-exchange` already takes `#:extras`. The fields a gateway wants — provider order, data-collection policy, fallbacks — are its vocabulary and will change without us. Pass them through verbatim, which is right here even though an unknown *theme* token is a 400: the difference is who renders them. A theme token we draw ourselves; these go to a third party that owns the schema. Operator-set, never team-set, and reported so an auditor can see what the instance is asking for. |
| **BYOK‑4** | What a gateway costs us in observability | **Record it; build nothing** · vs parsing the gateway's per-request provider field into the job row | Routing through a gateway means `audit_log` and `jobs.executor_id` name the **gateway**, and which upstream provider actually served the request lives only in the gateway's dashboard. LAY‑10 already declined a per-model accuracy breakdown because `jobs.executor_id` is NULL for in-process jobs; this makes the same column less informative from the other end. The fix is the one LAY‑10 named: keep the model `model-exchange` already resolves and returns as its third value, which both call sites discard. |

**On the fee, deliberately not recorded as a number**: the official BYOK doc's
percentage renders as an unfilled template, a "1,000,000 free BYOK requests per
month" allowance has already come and gone, and third-party integration guides
still repeat both it and a 5% figure. Check the live pricing page before anyone
promises a number. The operational detail that matters more: a failing BYOK key
can **fall back to the gateway's own account** unless that is explicitly turned
off per key — a failure mode to close during setup, not to discover on an invoice.

### ZDR — data-policy routing

**Zero data retention** means a provider stores nothing from a request beyond
serving it: no abuse-monitoring copy, no logs. It is distinct from "does not train
on your data" — an endpoint may retain for legal or abuse-scanning reasons and
train on what it retained, so the two are separate policies and a gateway exposes
them separately. **ZDR routing** is the gateway enforcing it as a routing
CONSTRAINT: the request is sent only to endpoints that qualify, and otherwise
fails. This maps cleanly onto LAY‑9's capability record — with one default
inverted, which is the whole of the decision.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **ZDR‑1** | Where a data policy lives | **The `executors.capabilities` document, new keys** · vs a column · vs a separate table | It is the same document the pull claim matcher and LAY‑9 already read (`{kinds, models}`, plus `tools` and `json_schema`), and `GET /api/executors` already reports it. A second mechanism for a third kind of fact about a backend is exactly what LAY‑9 avoided by reusing the claim-matching document. |
| 🔑 **ZDR‑2** | What an undeclared policy means | **Unknown means it RETAINS; a requirement is satisfied only by an explicit `true`** · vs LAY‑9's unknown-is-permissive | LAY‑9's rule is right for `tools` and `json_schema`: the cost of being wrong is one named refusal instead of an opaque 400 three layers down, and nothing that works today should start failing. It is **exactly wrong** for retention, where being wrong means prompts landed somewhere the operator promised they would not. So this needs a second predicate, not another key on `#:needs`: `capability-refusal` and `local-capability-refusal` refuse only on an explicit `#f`, so a missing `retention` key sails straight through. Same call `normalize` makes in session policy — a corrupt stored document reads as the shipped posture, not as "no limits" — because a control must fail CLOSED. And the refusal must be **by name, before the request leaves the process**, never a fallback to a backend that does retain: a named executor that is not a push backend used to fall through to the local model while the response still reported the executor's name, and a misroute that lies about where it ran is the worst shape this can take. |
| **ZDR‑3** | Who sets the requirement | **An instance floor that an org may TIGHTEN and may never loosen** · vs per-team · vs per-request | SESS‑4's rule for SESS‑4's reason: the instance operator owns the compliance posture of the box, and if an org admin could lower the floor it would be advisory. `session-policy:<org-id>` already proved the two-layer shape over `instance_settings`, so the org layer needs no migration. The per-request override is the one to refuse outright — a prompt is not the place to relax a data policy. |
| **ZDR‑4** | How narrowly the claim is stated | **"The model call retains nothing", and nothing more** · vs an instance-level "we retain nothing" posture | The platform retains plenty by design: `repo_text` holds extracted content, a job's payload and result hold the prompt and the answer, `audit_log` holds the trail, `l10n_translations` holds strings, and a research loop's search backend has its own policy entirely — the gateways carve plugins and web search out of their own ZDR guarantee for exactly this reason. Stating it as an instance property would be false. Same discipline as secrets-at-rest defending a DUMP and not a HOST, and LAY‑11's chain detecting an altered record and not a rewrite: a narrow true claim is worth more than a broad one a customer's auditor breaks in one question. |

**If these are adopted, the order is BYOK‑2 → ZDR‑2 → RSCH‑3.** BYOK‑2 is a
tenancy defect that exists now and gets worse the moment a second org registers a
backend; ZDR‑2 is small and makes a compliance claim possible; RSCH‑3 is the
expensive one, because an SSRF-safe fetcher is the whole cost of the research
surface and the rest of that loop is assembly.

## External feeds and a prioritised work queue (FEED) — **proposed 22 Oct 2026** (issue #114)

An external customer requirement: pull work items from systems they already run,
and answer "what should somebody do first today" — including "nothing, an agent
can do this one". **Slices 1–3 are built** — FEED‑3 as #135/#140, FEED‑4 as
#142, and FEED‑5/‑6/‑12/‑13 as the configuration plane below; the adapter that
lands items (slice 4) is next and is what the owner's first answer unblocks.
Full reasoning and the slice plan are in
[external-feeds.md](external-feeds.md); this is the record.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **FEED‑1** | What a pulled item is | **A repo object**, `feeds/<slug>/<external-id>` · vs a `feed_items` table · vs a blob directory | Visibility, grants, retention, cascade delete, search over extracted text, the audit trail, the trigger seam and "Processed by" all arrive free, and `0022-fold-documents` already established that a text document IS a repo object. Every alternative re-implements six subsystems. Same call RSCH‑2 makes for a research report. |
| **FEED‑2** | Whose authority a fetch runs under | **A feed names a team AND a user; everything it writes is that person's** · vs a system principal | There is no system principal and this is not a gap: a job carries `team_id`/`user_id` and runs as `(user-principal conn user team)`, the retention sweep acts as the team's own owner (DEL‑13), and DWF‑2 says the run is the uploader's. It is also the whole answer to "who can see a pulled item" — whatever `can?` says, with no new authorization code. |
| 🔑 **FEED‑3** | How recurring work happens | **A due time on a row, swept on `set-reaper!` into an ENQUEUE** · vs a thread in `init!` · vs an external cron | A thread has no team, no principal and no request context — `can?` has nobody to answer about and the org gate no tenant to scope to. Enqueuing inherits quota admission, the org gate, cancel, the lease, the fence, SCHED‑9's ceiling and the FLEET surface. Three sub-rules, each a way to get it wrong: a missed tick does **not** backfill (a box down a week must not fire 672 polls; a feed is a cursor, not a ledger); two replicas cannot both fire, because the claim is an `UPDATE … WHERE next_due <= ? RETURNING` believed only when a row comes back (issue #17's one-claim rule); and an overrunning run is **skipped and reported**, not stacked. #121's reporter wants this too — one prerequisite, not two.  **Built** as #135 (SCHED‑10…14), exactly this shape; all three sub-rules hold and each is positive-controlled. |
| 🔑 **FEED‑4** | Egress, and how it reconciles with RSCH‑3 | **One fetcher, two policies, and the policy belongs to the CALLER — `'untrusted` by default** · vs RSCH‑3's blanket refusal of private address space · vs trusting every configured URL | RSCH‑3 refuses private address space because a research loop fetches a URL a MODEL chose from a SEARCH RESULT — an SSRF proxy onto the server's own network. #114 asks for feeds **"in our network"**, which that rule would refuse outright. Both are right because **the rule attaches to who chose the URL, not to where it points**: a configured feed is the same trust as `TELEMACHUS_MODEL_URL` or an MCP server, a model-chosen URL is not. The default is `'untrusted` so a new caller is safe by omission — the opposite of LAY‑9's unknown-is-permissive, for ZDR‑2's reason: being wrong means a request reached somewhere it should not, so this fails CLOSED. |
| **FEED‑5** | Where a feed's credential lives | **A sealed column, and a row in `CREDENTIAL-SECRETS`** · vs plaintext · vs the environment | `define-sealed-column` (#110 r1) with AAD `feeds.secret:<feed-id>`. The registry entry is the half people forget: a sealed column missing from it is silently skipped by `telemachus-secrets rewrap`, so a key rotation leaves it unopenable — #83's own notes say so.  **Built**, and the registry entry was not the only trap: `define-sealed-column`'s seal is conditional on `TELEMACHUS_ENCRYPT_CONTENT`, which is right for content and WRONG for a credential, so the macro has a `#:credential` form now (ENC‑23) and the column uses it. |
| 🔑 **FEED‑6** | What a failed fetch records | **Host, path and status — never the query, a header or the body** · vs the exception as it comes | Sealing the stored secret is not enough: **a token in a query string is in the URL**, and a failing request's URL is the first thing an error wants to quote. #83 r4 sealed four `error` columns because this platform's tools quote what they choked on, and #123 stopped a 500 carrying `exn-message`; an outbound client is a new copy of the same hazard. Redact on the way INTO the exception, not out of it — by then it is formatted.  **Built** in #142's fetcher as `safe-url`, which also closed a live copy of this: `webhook_deliveries.last_error` stores what that module raises, and the `bad-url` refusal quoted the whole URL. The test is a LEAK test over every copy that outlives the call — the message, the exception's own `url` field and the stored row — because a first version that redacted only the field passed a check written on only the message. |
| **FEED‑7** | How a re-fetch avoids duplicating | **A per-item content hash in the plugin's own table; an unchanged item writes nothing** · vs exactly-once delivery · vs versioning every poll | `repo-put!` on an existing key writes a new VERSION, so polling would version an unchanged item every time and both the storage cost and the "updated" signal would lie. Idempotence is the property, not exactly-once — the shape `doc_trigger_fires` already uses. Possible because #121 shipped plugin-owned tables. |
| 🔑 **FEED‑8** | Where the ranked queue lives | **The plugin's own typed table and route** · vs ordering and range filters on `repo-list` | **A correction to my own first reading of this issue**, which said the queue was "a read, not a subsystem". It is not: `repo-list` orders by `team_id, key` and nothing else, `?attr=` is exact-match applied in RACKET after the page, an attribute value may only be a string or null, and there is **no JSON SQL anywhere in the tree** in either dialect — so sorting a page already chosen by key sorts the wrong 100. A core implementation needs typed storage and a dialect-specific query, which is a schema decision with the `meta LIKE` trap attached. The plugin's table is an index over documents that stay the source of truth, and it is buildable today. |
| **FEED‑9** | What bounds the polling | **A `feed.fetches` dimension, in `QUOTA-HOLD-DIMS`** · vs unmetered · vs storage only | Storage and tokens are already metered; the polling is not. In `QUOTA-HOLD-DIMS` so an over-budget team's feed STOPS rather than hammering a source — which protects the customer's own systems as much as the instance, and matters when the source is someone else's API with its own rate limit. |
| 🔑 **FEED‑10** | Whether an agent may act | **It writes a PROPOSAL; a `review` step gates the act** · vs an optional gate · vs unattended action | Nothing prevents an acting tool today — `register-tool!` takes an arbitrary handler — so the requirement is not to build the capability but to GOVERN it. LAY‑1…3 exists so a machine's output can be a proposal with a recorded, hash-chained decision and a four-eyes rule. The blast radius of a mistaken devops action is outside this system, where none of the platform's guarantees reach, and an optional gate becomes an off switch the first week somebody is in a hurry. |
| **FEED‑12** | Whether configuration ships before the adapter | **Yes, with a PROBE — and the row says `polling: false`** · vs waiting for slice 4 · vs a kind nothing pulls, silently | The credential and its rotation are the half that has to be right before a byte is fetched, and they can be got right now. The risk of shipping configuration first is a feed somebody configures and nobody polls, so two things answer it: `polling` is in every read, and `POST /api/feeds/:id/probe` fetches once, synchronously, storing only the outcome — #85's ping, for #85's reason. A probe creates no document, which is what keeps "am I configured right" free of storage quota and of versioning an item twice. `FEED-KINDS` is CLOSED and holds one member, so a kind nothing pulls is refused by name rather than stored (#113's shape). |
| 🔑 **FEED‑13** | How a credential is presented, and where it may NOT live | **`bearer` / named `header` / `query`, the secret sealed — and USERINFO IN THE URL IS REFUSED** · vs bearer only · vs accepting whatever is in the URL | `query` is the uncomfortable one and it is supported deliberately: a great many real sources authenticate that way, and refusing it does not make them safer — it pushes the operator into pasting the token into the `url` field, where it is stored UNSEALED and returned by every read. So the token gets a sealed home and is appended at request time, alongside whatever query the operator configured rather than instead of it. `https://user:pass@host/` is the opposite case and is refused outright: it is unambiguously a credential, there is a sealed place for it, and silently moving it would leave the operator unsure which home was in use. A query string cannot be told from configuration by inspection, which is exactly why FEED‑6's redaction is what protects it. Basic auth is a pre-encoded `header`, not a fourth mode. |
| **FEED‑11** | v1 scope | **FEED‑1…9 plus FEED‑10's proposal half** · vs the full acting tier | Slices 1 and 2 (recurring jobs, the egress seam) are platform work that #121's reporter and RSCH both wait on; 3–6 are a plugin. Acting without a gate, a core-console queue and a second adapter are all out.  **Revised on building slice 3**: the feed TABLE is core, not the plugin's, because FEED‑5's sealed column is — `define-sealed-column` and `CREDENTIAL-SECRETS` are platform machinery and a plugin-owned sealed column would be exactly the silently-unrotatable case FEED‑5 is about. A plugin-registrable sealed column is the seam that would move it and is not built; it is named here rather than implied. |

**The first of the three answers arrived on 23 Oct 2026** and named six sources
rather than one — GitHub issues, CERT advisories against pinned BOM
dependencies, Kuma uptime alerts, Discord, Matrix and OTel. Slice 4 is built on
it (FEED‑14…22 below), and the answer's real consequence is that the adapter
REGISTRY is built now rather than after the fourth source. Still open and still
not blocking: whether a plugin screen is acceptable for the queue or it must be
the core console, and whether FEED‑10's gate is acceptable for v1.

## A worker token expires, and a rotation overlaps (PULL‑15) — **decided and BUILT 22 Oct 2026** (issue #60)

The last of issue #54's four deferred questions. A worker token was minted with
`ttl 'never` on purpose — the session timeouts are deliberately not applied to
machine credentials (SESS‑1), because idling one out is a silent outage — and
the cost was that the longest-lived credential this platform issues is the one
held by a box in somebody else's rack, with `jobs:execute` on it for ever.

Expiry alone only moves the outage: at the horizon every worker stops at once.
So the expiry ships WITH the overlap and with a way for a host to renew itself,
and the three parts are one decision.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| 🔑 **PULL‑15a** | The default lifetime | **No expiry unless configured** (`TELEMACHUS_WORKER_TOKEN_DAYS`, 90 recommended) · vs a shipped 90 days · vs refusing `never` | The retention rule's call (DEL‑9): a real default means an upgrade silently starts expiring credentials on every instance, including the third-party workers that cannot rotate themselves. The recommendation lives in the configuration reference, where an operator adopting it can read what adopting it requires. An unparseable or non-positive value falls back to `never`, never to `0` — which would expire a token as it was minted and take every executor down on the next deploy. |
| 🔑 **PULL‑15b** | How an expiry avoids an outage | **Two live tokens per executor for an overlap window** · vs one token and a flag day · vs a keyring | Two slots (`executors.prev_token_id`, migration 0055) is what makes an unattended rotation possible: the new token is minted before the old lapses, and a host still presenting the one it is replacing keeps working. A keyring was rejected — it lets a leaked credential survive indefinitely behind "but something might still hold it", and makes "how many live credentials does this host have" unanswerable. A third rotation revokes the oldest outright. |
| **PULL‑15c** | The overlap's length | **One hour, a CONSTANT** · vs a knob · vs the outgoing token's own remaining life | The platform asks for a rotation a third of the token's life early, so a healthy worker never depends on the overlap — it is the margin for a host that rotated and then restarted before it had persisted the new token. A longer window only extends the life of a credential being retired, which is the opposite of the point. The outgoing token's expiry is SHORTENED to the window, never extended: a token with a year left does not get a year more because something replaced it. |
| 🔑 **PULL‑15d** | Who may rotate | **The worker itself, and the operator** · vs the operator alone | The worker is the case that makes an expiry survivable without a person: it holds a valid credential for this executor, so it may trade it for the next one — PULL‑9's read and PULL‑13's write run on the same warrant. The operator plane (`POST /api/executors/:id/rotate-token`) is for a third-party worker that cannot rotate itself, and for a token believed leaked. |
| 🔑 **PULL‑15e** | How a worker learns | **`GET /api/workers/token`, and the platform decides** · vs a field on the claim · vs the worker computing it | An idle worker's claim answers **204, which carries no body**, so the host that most needs telling — no work, and a token that lapses tonight — is the one a claim field cannot reach. `rotate` is the platform's answer rather than the worker's arithmetic, so every worker in every language takes the same decision and the window can move without redeploying a fleet. One read an hour beside a claim every twenty seconds. |
| 🔑 **PULL‑15f** | A worker with nowhere to keep a token | **It must NOT rotate, and says so once** · vs rotating anyway · vs refusing to start | A worker that rotates and forgets would go on working on the outgoing credential until the overlap ended — a rotation it asked for, turned into the outage the overlap exists to prevent. So `TELEMACHUS_WORKER_TOKEN_FILE` is written FIRST and the in-memory token is swapped only if that succeeded; with no file configured the worker says once that an operator has to rotate for it. Refusing to start would break every existing deployment, which configures no file. |
| **PULL‑15g** | Bounding an unsolicited rotation | **Five minutes, and never against a rotation the platform ASKED for** · vs no floor · vs a flat floor | A buggy loop would otherwise mint a credential per poll. The exception is the whole rule: a floor that could refuse the renewal the platform is requesting is a scheduled outage with a rate limiter in front of it. The smoke found exactly that — a short test lifetime puts a token inside its renewal window while it is still younger than the floor, and the reference worker was told to rotate and then refused. The operator plane passes no floor at all: a leak is not a reason to wait five minutes. It is a **429 with `Retry-After`**, not a 409 — nothing is in conflict, the caller is asking too often, and a worker written to back off on 429 already does the right thing. |
| **PULL‑15h** | Whose credential the new token is | **The OLD ROW's user, team and scopes** · vs the rotating caller's | Rotation replaces a credential; it must not quietly re-attribute it to the operator who pressed the button, or the next audit entry about that host would name the wrong person and `can?` would answer about the wrong team. |
| **PULL‑15i** | What a retire does now | **Revokes BOTH slots** · vs the current one | A retire that left the previous token alive would leave a live `jobs:execute` credential for a host the operator has just taken away. |

Not built, and deliberately: nothing warns an operator that an executor's token
is approaching its horizon with no rotation in sight. The information is there
(`GET /api/executors` carries both slots, the token listing carries the expiry)
and a fleet-level "this host will stop in three days" belongs with FLEET‑2's
report rather than in the slice that creates the horizon.

## An external anchor for the two hash chains (ANCHOR) — **decided and BUILT 22 Oct 2026** (issue #66)

Two chains now make the same narrow claim and leave the same gap. LAY‑11 chains
each **review decision** per team; AUD‑10…16 chains each **audit entry** per org.
Both detect a row altered in place, a row removed from the middle, and a
rewritten link. Neither detects a rewrite by anyone who can **write** the table,
because they can recompute every link after the row they changed — and that is
the party an audit is most meant to defend against. The same shape as secrets at
rest (#19), which defends a DUMP and not a HOST.

Issue #66 says the choice of anchor **is** the feature and the code after it is
small, so the decision is recorded before any of it:

> Nothing here should be built before deciding what the anchor is — a second
> instance, an operator-held log, a timestamping service, a file in a different
> trust domain — because the choice is the whole feature.

| # | Question | Decision · alternatives | Why |
|---|---|---|---|
| 🔑 **ANCHOR‑1** | What the anchor IS | **The platform EMITS a signed receipt; it never CALLS a notary** · vs an RFC 3161 timestamping authority · vs a public ledger · vs a second TMach instance | A notary is a network dependency and a disclosure, and this platform is self-hosted, privacy-first and has to work air-gapped. The head hash itself is low-information, but the *existence and cadence* of a team's decisions is not nothing to hand a third party. It is also the wrong shape: a specific remote would be one mechanism per remote in the core, when the thing the core can uniquely provide is a receipt that is meaningful **wherever** it ends up. So the platform produces the artifact and **where it is retained is the deployment's decision** — a second instance, a git repository, an object store in another account, a mail archive, a sheet of paper in a safe. That is exactly the decision #66 says this issue is really about, and it is the operator's, not the platform's. |
| 🔑 **ANCHOR‑2** | One mechanism or two | **ONE receipt covers BOTH chains** · vs an anchor per chain | #66's own second comment asks for this and names the risk: the two chains "should share one mechanism rather than growing two". A receipt is a list of `(chain, scope, head, entries)` rows — the review chain per team, the audit chain per org including the no-org bucket — so a third chain later adds a **row**, not a mechanism. Their scopes differ (team vs org) and that difference lives in the row rather than in two code paths. |
| 🔑 **ANCHOR‑3** | What makes SILENCE detectable | **The receipt series is itself CHAINED** (`seq` + `prev_hash`) · vs each receipt standing alone | This is the property that the export — today's nearest thing — does not have, and without it the whole feature is defeated by *not publishing*. A writer who controls delivery simply stops emitting, and a missing receipt is indistinguishable from an instance that was quiet. With a strictly increasing sequence and each receipt naming its predecessor's hash, a **gap in the retained series is visible without the server**, and so is a replayed sequence number carrying different heads — which is what deleting receipt rows and re-emitting looks like from the retainer's side. |
| 🔑 **ANCHOR‑4** | How a receipt is signed | **Ed25519, private key NOT in the database** (`TELEMACHUS_ANCHOR_KEY`) · vs HMAC with a shared secret · vs unsigned | HMAC buys almost nothing here: a verifier who holds the key could have produced the receipt, so the receipt means nothing to anyone but the operator who could have forged it — no better than unsigned retention. Asymmetric is what makes a receipt evidence to a party that is **not** the operator (an auditor, a customer, a regulator): the public key is published and verification does not confer the ability to sign. It is a SEPARATE key from `TELEMACHUS_SECRET_KEY` for #19's reason inverted — rotating the sealing key must not invalidate the anchor series, and rotating the anchor key must not touch a single sealed column. |
| 🔑 **ANCHOR‑5** | Who can verify, and with what | **A CLI that needs neither the server nor the database** (`cli/telemachus-anchor.rkt verify`) · vs an API endpoint · vs a console card | An anchor is worthless precisely when it is most needed — when the instance is the suspect. A verifier that asks the instance whether the instance is honest is not a verifier. So the check runs over a retained file, offline, against a public key supplied on the command line. |
| 🔑 **ANCHOR‑6** | Whether a receipt may carry its own public key | **Yes, for convenience — and the CLI REFUSES to call it verified without an expected key** · vs carrying it and trusting it · vs omitting it | A key taken from the file it is being used to verify proves nothing: a forger supplies both. Carrying it is still useful (it says which key *claims* to have signed, so a mismatch is diagnosable), so it rides in the receipt and the verifier reports `signed_by` while declining to report `verified` until `--public-key` is given. The honest failure is to say what was not checked rather than to imply a check that could not happen. |
| **ANCHOR‑7** | The default | **OFF unless a key is configured** · vs emitting unsigned receipts by default | DEL‑9's and PULL‑15a's call: a real default means an upgrade silently starts emitting on a timer on every instance, and here it would also mint a key nobody retained — a receipt series with no reader, which is worse than none because it reads as a feature that is working. With no `TELEMACHUS_ANCHOR_KEY` nothing is emitted and nothing changes. |
| **ANCHOR‑8** | When the heads are read | **After a SEAL** · vs whatever is in the table | The audit chain is sealed by a sweep, not at insert (AUD‑10), so its head is only well-defined once sealed — which is why `audit-chain-status` reports the unsealed window at all. A receipt naming an unsealed head would anchor a value the next sweep legitimately changes, and an honest instance would then fail its own verification. Emission seals first. |
| **ANCHOR‑9** | Where receipts live on the box | **A table, which is NOT the anchor** · vs only a file · vs only the response | `anchor_receipts` exists so the sequence can be continued across restarts and so an operator can fetch what they have not yet retained. It is in the same database as the chains it measures, so a writer can delete from it too — which is the whole point: **the retained copy is the anchor, the table is a queue.** Said out loud, because a table called `anchor_receipts` invites the belief that having it is the protection. |
| **ANCHOR‑10** | What the digest covers | **The chain rows, the sequence, the predecessor, and the emitting instance** · vs the heads alone | A receipt that signed only head hashes could be replayed into another instance's series, or re-dated. The signed payload is an ordered list — never a hash, the trap that `json-out` sorts for and that JUDGE‑13's wire refuses re-serialization for — carrying `ANCHOR-VERSION`, the sequence, the previous receipt's hash, the emission time and the rows in a fixed order. A field not in it could be changed without breaking the signature, so the list is the statement of what is protected. |

**What this detects, and what it does not** — stated narrowly, because the point
of the issue was that the chains' own claim had been stated too widely:

- It detects a rewrite of either chain **after a receipt was retained**: the
  recomputed head will not match the retained one, and no amount of relinking
  inside the database changes a hash somebody else is holding.
- It detects **suppression** — a gap in the retained sequence, or a reused
  sequence number carrying different heads.
- It does **not** detect a rewrite that happened **before the first receipt**, or
  one inside the window since the last receipt. The anchor's resolution is its
  cadence.
- It does **not** work at all if the retained copy was never collected or has
  been lost. The platform cannot verify that somebody else kept something, and
  does not pretend to: `GET /api/admin/anchor/receipts` reports what has been
  emitted, never what has been retained.
- A **host** compromise still forges *future* receipts, because the signing key
  is on the host. It cannot forge the ones already in somebody else's hands.
  #19's DUMP-not-HOST line, one layer up.

Not built, deliberately: automatic delivery to anywhere. No SMTP, no git push,
no bucket write — that is ANCHOR‑1's whole argument, and a plugin or a cron line
with `curl` is the right shape for a specific remote. Also not built: a console
card, for #116's reason (it would need `ui.*` strings in two catalogs and a tour
update, which is its own slice), and anchoring the **feed** or **webhook**
tables, which keep no chain to anchor.

## The first feed adapter: GitHub issues (FEED‑14…22) — **decided and BUILT 23 Oct 2026** (issue #114 slice 4)

The owner answered the blocking question on
[#114](https://github.com/IoTone/Telemachus/issues/114#issuecomment-6361023239),
and the answer was not one source but **six**, in order: a GitHub issue tracker,
CERT advisories for pinned BOM dependencies found by scanning their own source,
Kuma uptime alerts, feeds from Discord servers they operate, Matrix chat
notifications, and OTel server notifications. All six are devops.

That list is the design input, and it changes one thing: **a second adapter is
no longer hypothetical, so the registry is built now rather than after the
fourth `cond` arm.** Five of the six are "JSON over HTTP with a different item
shape"; the sixth (Matrix) is a push surface and is issue #133. GitHub issues is
the one this slice builds, because the owner named it first and because it is
the only one of the five whose wire this repository can exercise in CI against
its own API shape.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| 🔑 **FEED‑14** | How a source shape is added | **A REGISTRY entry — `register-feed-adapter!`, keyed by kind, with LAY‑7's ownership rule** · vs a `cond` in the poller · vs one adapter per slice | Six named sources is the evidence a registry needs; one was not. A `cond` over six item shapes inside the fetch loop is exactly the shape #110 r1 kept finding, and it would put the next source's parser inside the code that spends the team's quota and writes its documents. `FEED-KINDS` is **derived from the registry**, never a second list — the `available` locales rule — so a kind this build cannot pull cannot be configured in the first place, and a plugin can add one under `x.<plugin-id>.<name>` exactly as it adds a job kind or an extractor. |
| **FEED‑15** | What `http.json` does now | **It stays PROBE-ONLY, and polling it is a named refusal** · vs guessing the item shape · vs removing the kind | A generic adapter would have to find the items in an unknown body and guess which field is the identity — and guessing is what DWF‑5 refuses on the model's own output, for the better reason: a wrong guess here writes somebody else's data under an identity that is not theirs, and the dedup hash then makes it permanent. So `http.json` is reachable by `probe` and refused by `poll`, with the message naming the kinds that CAN be polled. Removing the kind was rejected because a probe is the honest first step of configuring any of the five. |
| **FEED‑16** | What an item's `external-id` is | **`<owner>-<repo>-<number>`** · vs the bare issue number · vs GitHub's global `id` | The bare number collides the moment the configured URL is a search or a cross-repo endpoint, and a collision writes two different issues over one key — which the dedup hash then reports as a document that changes every poll. The global `id` cannot collide and cannot be found by a person: "which document is issue #114?" has to be answerable without a join. The composed id is unique, stable and legible, and it is sanitized to the key vocabulary rather than trusted — a repository name is somebody else's string. |
| **FEED‑17** | What gets stored | **The source's payload VERBATIM as `application/json`, with the item's title in the version's `filename`** · vs a reshaped summary · vs a text rendering beside the JSON | FEED‑1 says the source's own payload, and an adapter that reshaped it would be a lossy translation with nothing to check it against. But `application/json` has no extractor, so a pulled item would be invisible to search — and `0022-fold-documents` already settled where a document's title goes: the version's `filename`, which search covers along with the key. So the title is searchable, the payload is exact, and a second document per item (the shape that would make both true by duplication) is not written. |
| **FEED‑18** | Where the dedup hash lives | **A CORE `feed_items` table** · vs the plugin's own, as FEED‑7 said | FEED‑11's revision applies again: the poller is core because the fetcher, the quota and the repository writes are, so the table it reads on every item belongs beside it. The hash is of the payload bytes **as the adapter composed them**, so "unchanged" means what this instance would store is unchanged — not what the source's own `updated_at` claims, which several of the six sources touch without changing anything. An unchanged item writes no version and moves `last_seen_epoch`. |
| 🔑 **FEED‑19** | How the cursor advances | **Only over items that LANDED, and the window stays INCLUSIVE** · vs advancing to the poll's start time · vs no cursor | A cursor advanced to "now" at the end of a poll loses every item that arrived while the pages were being processed, and loses an item outright if its write was refused — by a storage quota, which is a case that will happen. So the cursor is the newest `updated_at` among items actually stored, and the next request asks for `since` **inclusive**, so the newest item comes back and the dedup hash absorbs it. The cost is one re-read per poll; what it buys is that a crash mid-page costs a re-read and never a gap. FEED‑3's "a feed is a cursor, not a ledger" is about missed TICKS, not about skipping items. |
| **FEED‑20** | How an item's attributes pass LAY‑4 | **The adapter DECLARES the fields it writes and the poll adds them to the team's definitions** · vs writing attributes unvalidated · vs dropping undefined keys | LAY‑4 refuses a key the team has not defined, deliberately, because a value nothing can display or filter on is how a team concludes the model is broken. With no answer here every pulled item's attributes would be refused — and silently dropping them is the worse failure, because slice 5's queue reads exactly those keys. The declaration is additive and **never overwrites a team's own label** for a key it already defined, every key is namespaced `feed_*`, and the poll **refuses by name** if adding them would exceed LAY‑4's 40-field cap rather than truncating to fit. |
| **FEED‑21** | How a feed comes to be polled | **`poll_seconds` on the feed, which owns a `job_schedules` row of kind `feed.poll`** · vs a separate schedule the operator wires by hand · vs a poller thread | FEED‑3 already built the only correct runner, so this is plumbing and the question is only who writes the row. The feed owns it: `polling` is then **derived** from that row rather than stored, which is the rule `missing`/`stale` and executor health already live by, and an operator cannot end up with a feed whose schedule says something else. It widens nothing — `feeds:manage` and `jobs:schedule` sit in the same role — and because the kind and the payload are **platform-set**, the feed plane cannot be used to schedule arbitrary work for a caller who holds only one of the two. |
| **FEED‑22** | Whether a poll can be run by hand | **Yes: `POST /api/feeds/:id/poll`, synchronous and bounded** · vs the schedule only | FEED‑12's argument one step further. An operator configuring a feed needs to see it work, and "wait fifteen minutes and read `last_error`" is the loop that makes a feed nobody trusts. It is bounded — at most `FEED-MAX-PAGES` requests and a per-item byte cap — because a repository with 40,000 open issues must not be one request, and because the manual path runs on a request thread rather than in a job. |

Metering is FEED‑9 unchanged, with one thing worth stating: `feed.fetches` is
charged **per HTTP request, not per item**. The dimension exists to protect the
*source's* rate limit as much as this instance, and a page of 100 items costs
the source one request.

Not built, deliberately: the other five adapters (each is a registry entry and
a parser, and the one with a protocol rather than a shape is #133's), the ranked
queue (slice 5, and FEED‑8 says it is the plugin's), and anything that acts
(FEED‑10's gate first).

## Matrix notifications as an optional component (MTX‑1…9) — **decided and BUILT 23 Oct 2026** (issue #133)

The whole ask: *"We find matrix to be useful for sending notifications to teams
securely. Since we can run this on our own infrastructure, we feel this works as
an integration tool."* So this is a **transport**, and the interesting decisions
are about what it is not allowed to be.

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **MTX‑1** | Where it lives | **A plugin, `plugins/matrix/`** · vs core · vs an out-of-process bridge | The issue says "optional component" and the seams for this all shipped: a plugin owns tables (#121), routes (slice 63), a job kind (#21) and now an event sink. Nothing about Matrix belongs in the core of a platform that may never speak it. |
| 🔑 **MTX‑2** | How a second subscriber reaches the events | **The event sink becomes a REGISTRY of named sinks** · vs displacing webhooks · vs a hook of its own in each emitter | `events.rkt`'s own header promised that "the next consumer plugs in here rather than growing a box of its own" — and the box was **single-slot and taken by webhooks**, so the promise was not keepable. Sinks are named (re-adding your own replaces it, because the loader may run twice), and **each is wrapped separately**: with one shared handler the first sink to raise would swallow the rest, which is the failure nobody notices until the day it matters. Positive-controlled. |
| 🔑 **MTX‑3** | Where the access token lives | **The ENVIRONMENT, as the operator's — never the database** · vs a sealed column · vs a plaintext column | A plugin **cannot** own a sealed column: FEED‑5 recorded that gap deliberately, because a plugin-owned sealed column is absent from `CREDENTIAL-SECRETS` and is therefore silently unrotatable. Storing it unsealed to get round that is the exact failure that rule exists to prevent. So the homeserver and the bot token are `TELEMACHUS_MATRIX_*`, the same trust as `TELEMACHUS_MODEL_URL`, and a team configures only *which room*. Three consequences, stated rather than discovered: one bot identity per instance (which is what a self-hosted notifier is), **a tenant admin never sees the token** (a property, not a limitation), and per-team credentials wait for the seam FEED‑5 named. |
| **MTX‑4** | Whether the platform joins a room | **No — the bot is invited by a person** · vs joining by id on subscribe | Being invited keeps "who may be told" a decision made on the Matrix side, where it belongs, and makes a mistyped room a named error instead of a bot turning up somewhere. It also means an **alias is refused**: an alias is resolved by the homeserver and can be repointed at another room by whoever controls it, which would silently redirect a team's notifications. |
| 🔑 **MTX‑5** | What the sink does | **ENQUEUES ONLY; a job sends** · vs posting from the sink | The sink runs inline in the emitter's thread, so sending from it would let a homeserver that has stopped answering hold a workflow run open for the timeout. A job inherits quota admission, the org gate, the lease, the fence, cancellation and the FLEET surface — and `jobs.payload` is sealed (ENC‑8…12), so the composed line is encrypted at rest with nothing added here. **The job row IS the pending state**, so the plugin needs no table for it. |
| **MTX‑6** | How a re-delivery avoids a duplicate | **The Matrix transaction id IS the job's id** · vs a sent-table · vs accepting duplicates | A homeserver ignores a repeat of a `txnId` it has already seen on that access token, so a job the lease reaper re-queued, or the second of this plugin's own two attempts, cannot post the line twice. The idempotency is the protocol's rather than a table of ours — the same instinct FEED‑18 applies to a content hash. |
| **MTX‑7** | How hard it tries | **Twice, a second apart, and then the room row records the failure** · vs webhooks' ten attempts with backoff · vs one attempt | Webhooks' retry schedule lives in a table built for it; duplicating that inside a plugin would be a second delivery subsystem. A notification is for PEOPLE, and a missed chat line is not a lost event — the audit log and the webhook path both still have it. So the limit is stated in the README rather than implied: **if you need delivery guarantees, use a webhook.** |
| 🔑 **MTX‑8** | What a room is told | **Ids, status and a link — never content** · vs a readable summary with the document's title | #85 r2, and it matters MORE here: a webhook goes to a server, a room is read by **people** who may hold no `can?` on the subject, and Matrix rooms are routinely bridged somewhere else again. One composer, so there is no call site that can forget; the workflow SLUG earns its place because "run 3f2a finished" tells nobody which thing finished. Positive-controlled with a fixture carrying a patient name, a note body and a prompt. |
| **MTX‑9** | Which permission | **`webhooks:manage`** · vs a `matrix:manage` of its own | It is the same question — where may this instance send notifications — and **a plugin cannot add a permission to the catalog**, which is #113's rule working rather than a limitation: `matrix:manage` would be a permission no role grants and `GET /api/roles` never mentions. |

One correction from CI, worth the line because it is a rule and not a slip:
**`init!` registers the job kind unconditionally and the SINK conditionally.**
The first version put both behind the switch, and `docs/reference/plugins.md` is
generated from the loaded plugins and gated on drift — so the reference said
something different on a box with a homeserver configured than on one without,
the committed copy had been rendered with the variables set, and the drift gate
failed in CI while the whole suite passed locally. A generated, committed
reference has to be a property of the BUILD. What the opt-in exists to protect
is the emit path, which is the sink.

Two limits worth recording because they are not obvious:

- **The path goes out with the room id's `!` and `:` LITERAL.** The client-server
  API's examples percent-encode the room id, and this plugin cannot: #142's
  fetcher parses the URL and rebuilds the path from it, which decodes whatever
  encoding was applied one layer up. Both characters are legal in a path
  (RFC 3986) and Synapse accepts them — but a `/` would be rebuilt as a path
  separator and address a different endpoint, so a room id containing one is
  **refused**. Teaching the fetcher to carry a raw path was the alternative, and
  it would weaken the one place every outbound request is normalized.
- **No end-to-end encryption.** This sends through the client-server API, and E2EE
  would need a device, key management and a megolm session — a different piece of
  work. The README says so, next to the reminder that a notification carries ids
  and a link rather than content, which is what makes a plaintext room an
  acceptable destination in the first place.

## Which KIND of document is this? (CLS‑1…12) — decided and BUILT 23 Oct 2026 (issue #87 slice 1)

A trigger matches on a key prefix and a content type. An integrator whose inbox
carries letters, invoices, forms, photographs and reports under one prefix
therefore had nowhere to put the one decision the rest of the pipeline depends
on — which schema to read this document against — and had to approximate it with
`doc_extract_fields` and an enum, which bills a model call to answer a question a
keyword often settles for nothing.

`doc_classify` is the step that assigns a type. `domain/repo/classify.rkt` holds
the rules, the label set and the model's refusals and is pure of the repository;
`doc-tools.rkt` owns the document, the attributes and the derived record.

| # | Decision | Why |
|---|----------|-----|
| CLS‑1 | **The backends are a CHAIN, not a choice.** `backends` is an ordered list and the first that answers wins; the default is `rules` then `llm`. | Rules cost nothing, spend no tokens and answer the same way every time. The model is the fallback for the documents no rule describes — which is the opposite of the order a caller gets by reaching for the model first. |
| CLS‑2 | **The rules backend has NO REGEX.** Phrases (`all` / `any` / `none`, case-insensitive), a content type (exact, or a prefix ending in `/`), and a key suffix. | The requirement asks for regex rules. A rule is written by an ADMINISTRATOR and run against the text of a document the administrator does not control, so an operator-authored regexp is a denial of service with the operator's own configuration as the weapon — catastrophic backtracking over a 200,000-character extraction, on the upload path. The same call `domain/fields/fields.rkt` made for the funnel's validation vocabulary and `domain/flow/bind.rkt` made for the binding sublanguage. `doc_extract_fields`'s schema does support `pattern`, and that is not the same thing: it runs against the MODEL's reply, which this platform asked for and bounded. **Page count is not here either**: no extractor reports one, and deriving it from the span list would be a number nothing measured. |
| CLS‑3 | **A rule MATCH is the confidence** — 1.0, with the rule's position in the rationale. | The requirement says the rules backend "short-circuits when confident". A deterministic rule has no degrees: it matched or it did not. Attaching 0.85 to it would be a number nothing computed, the objection that keeps `interval_seconds` off a daily schedule's read. |
| CLS‑4 | **First match wins, in list order, and a rule needs at least one condition.** | The route table's rule, for the route table's reason. A rule with no condition matches every document, which makes every rule after it dead code while still reading as configuration — refused, not tolerated, like an unknown setting. |
| CLS‑5 | **The model's reply is held to the label set by the SAME validator DWF‑5's extraction uses**, with the names as an `enum` and the object CLOSED; refused by path, retried once. | A label outside the set is never coerced to the nearest one and never recorded as "unknown". The schema being closed is what refuses an invented key, exactly as an extraction's does. |
| CLS‑6 | **When no backend answers, it REFUSES.** It does not write `doc_type = "unknown"`. | A stored type is an assertion a trigger acts on, and "nobody could tell" is not one. The message names the backends that were asked, because the remedy is a rule or a model and the operator is one field away from either. |
| CLS‑7 | **The attribute keys are `doc_type`, `doc_type_confidence`, `doc_type_source`** — not the issue's `doc.type`. | A dot is not a legal attribute key: LAY‑4's `field-key?` is `^[a-z][a-z0-9_]{0,39}$`, a vocabulary the object metadata, the beta funnel and every `?attr=` filter share, and loosening it for three keys would change what a key is everywhere. Namespaced for FEED‑20's reason, and declared on the team additively through the shared `repo-fields-declare!`. |
| CLS‑8 | **The confidence is stored to two decimals, fixed.** | LAY‑4 values are strings and `?attr=` is an equality filter, so a value whose spelling follows the model's precision could not be filtered on at all. |
| CLS‑9 | **A document this platform cannot READ is still classifiable**, and that is why `text` is optional on the tool. | `doc_text` raises for a scan, a photograph and a missing `pdftotext`, correctly — somebody is waiting for fields. But the photograph and the scan are exactly what a content-type rule exists for, so the text is best-effort here and an unreadable document simply has none; the model backend then refuses by name. It is also why `classify-and-extract` classifies BEFORE reading: the first version read the text first and could not reach the documents that most needed routing. |
| CLS‑10 | **The model sees the opening, capped at 8,000 characters, and the record says how much was read.** | A document's TYPE is evident from its first page. Truncating is right here and wrong for `doc_translate`, which refuses a document over its cap: a truncated classification is still a classification of that document, where half a translation is a document that lies about being finished. |
| CLS‑11 | **The classification is also a derived document**, `<key>.classification.json`. | The three attributes carry the CURRENT type; the record says which label set it was chosen from, by which backend, against which version. A re-run versions the same key, so the history is the version list rather than a second mechanism. **The attributes are written FIRST and the record second** — written the other way round, a refused attribute write would leave a document beside the source saying the type was decided when nothing had recorded it. |
| CLS‑12 | **`chat:use` is demanded when the request NAMES the model backend**, not when the chain happens to reach it. | A permission that depended on whether a rule matched would admit a member for one document and refuse them for the next, with nothing in either answer to say why. |

Two things changed outside the slice, both additive. `repo-fields-declare!` moved
FEED‑20's additive declaration and its forty-field cap into `repo.rkt`, because it
now has two askers and deriving the cap arithmetic twice is `executor-can-run?`'s
drift. And `define-workflow`'s `(in x)` learned a path — `${input.x.y}` has always
been in the binding grammar and the macro could only spell the one-segment form,
so a workflow routing on a type had to take each schema as its own input.

**There is no `switch` step kind, and there must not be.** The issue writes the
routing as `switch(doc.type)`; `choice` chains into exactly that, and adding a
kind is a spec-version change — WF‑10 refuses an unknown one, deliberately — for
sugar over two lines. The chain also makes the fall-through explicit, which a
switch would hide. A `choice` with no `#:else` does **not** end the run: it falls
through to the next step in list order, so the branch that is meant to end the run
has to be the LAST step. `classify-and-extract`'s own test found that, by sending
a photograph into the letter branch where `doc_text` fails on an image.

Not built, deliberately, and each is the issue's own numbering: **an embedding
nearest-label backend (req 2c)** — this build has no embedding wire, store or
meter, so it is its own slice rather than a flag, and the backend refusal says so
by name rather than reading as a typo; **trigger conditions on metadata (req 3's
second half)**, **the low-confidence review hook (req 4)**, **batch backfill
(req 5)** and **the evaluation harness (req 6)**. The first acceptance criterion
is met: `classify-and-extract` runs end to end on a mixed fixture set, in
`test/classify-tests.rkt` and over HTTP in `test/doc-pipeline-smoke.sh` §5b. The
second — low-confidence items in the review queue — is req 4, and waits.

## A person in the pipeline: the review hook (CLS‑13…18) — decided and BUILT 24 Oct 2026 (issue #87 slice 2)

Slice 1 built the classifier and left the issue's second acceptance criterion
open: *"Low-confidence items appear in the review queue and resume after a
decision."* Requirement 4 asks for a review hook — below a configurable
confidence the run creates a review record instead of proceeding, and the
decision updates the metadata and resumes the workflow.

Almost all of that already existed. `review` has been a step kind since LAY‑1,
`reviews` is a real table with a queue, a verdict vocabulary, four‑eyes and a
hash chain, and `resume-from-review!` has always set the run running again down
the branch the verdict names. What was missing was the two ends: the authoring
surface could not SPELL a review step, and a decision had nowhere to LAND.

| # | Decision | Why |
|---|----------|-----|
| CLS‑13 | **The threshold is a `choice`, not a flag on the tool.** `(lt (out classify result confidence) (in min_confidence))`, with `min_confidence` a declared `number` input. | Only a STEP can park a run — LAY‑1's whole mechanism is that a `review` step writes no job and the run simply stops being advanced — so a tool that wanted to "send this for review" would have to reach into the review subsystem from inside a tool call, and would then own a decision the workflow is the right place to make. The binding grammar already has `lt` and the spec already has a `number` input type, so "below a configurable confidence" needs no new grammar. The same answer `switch(doc.type)` got in slice 1. |
| CLS‑14 | **`define-workflow` learns `(review …)`** — one keyword per verdict, and an ABSENT verdict ends the run. | The step kind shipped in LAY‑1 and the macro could not emit it, so for a year every workflow that parked on a person had to be hand-written JSON — which is why the review hook needed the authoring surface before it needed anything else. `#:approve` is required here because `validate-spec` requires it there; `#:end` is REFUSED, because where a review goes depends on the verdict and leaving a verdict out is how you end the run on it. No spec change: the emitted document is one `validate-spec` already accepted. |
| CLS‑15 | **A person's label is held to the SAME label set as the model's**, refused by name, never coerced to the nearest. | CLS‑5 applied to a human. A checklist answer is a free string by LAY‑1's design, so "Invoice", "invoices" and a trailing space are each one keystroke away — and every one of them is a document type no trigger and no `?attr=` filter will ever match. The refusal lists the types the run offered, because the reviewer is one keystroke from right. The run FAILS rather than storing it; the decision itself stands, because the decision was made and it is the recording that could not be. |
| CLS‑16 | **An approval RE‑RECORDS the type** with `doc_type_source = "review"` and confidence `1.00`; a **rejection WITHDRAWS it**. | The attributes are where this platform says HOW a type was decided, and a person looking at the document is the strongest form of that — leaving `llm` and `0.42` behind would make an approved document indistinguishable from one nobody had looked at, which a backfill (req 5) or a trigger could not tell apart, and would offer the same document for review again on the next pass. The withdrawal is the other side: CLS‑6 settled that there is no `doc_type` of `"unknown"`, so the only honest record of "none of these kinds" is the ABSENCE of an assertion. LAY‑4 clears an attribute by merging an empty value, so the withdrawal is the same write with nothing in it. The backend's own guess is not lost — it is the previous version of `<key>.classification.json`, which is where CLS‑11 put the history. |
| CLS‑17 | **`doc_set_type` is its own tool, and the write path is shared with `doc_classify`.** | Two different questions: "what kind of document is this" needs a backend, a token budget and `chat:use`, and "record what was decided" needs none of them and must work on a team with no model at all. Folding them would mean a request that carries both a label and a backend list, where only one can be honoured. What they DO share is `record-type!` — the attributes-then-record order is a rule (CLS‑11), and two copies of a rule is `executor-can-run?`'s drift, the argument `repo-fields-declare!` already made one line below it. |
| CLS‑18 | **Two routing chains, because the binding grammar has no coalesce** — and that is a real limit, stated rather than worked around. | A revision CHANGES the label, so afterwards the type lives in the correcting step's output and not in the classifier's, and the grammar has no default, no coalesce and no arithmetic by design (WF‑2). Nothing can say "the label from whichever of these two steps ran". So `classify-review-extract` carries one `choice` chain per source and SHARES the extraction steps, which keeps the duplication to one step per type rather than a second copy of the pipeline. The documented escape hatch is a tool — one that reads the type back off the document — and that is the better answer the day a third chain is needed. |

Two things changed outside the slice, both additive and both found by reading
the code the hook sits on.

**`${principal.timezone}` was a binding nothing could use.** #137 added it to
`make-context`, to `bind.rkt`'s own header and to these notes, and NOT to
`valid-ref?` — so the one documented way to reach a person's clock from a
workflow was rejected at publish time, and `define-workflow` had no spelling for
it at all. Both halves are fixed. This is #113's shape in the binding grammar:
something advertised, granted and enforced nowhere.

**The resumed step now binds `review_id`.** A step after a review could name the
verdict, the rationale, the answers and who decided, and not the decision
itself — so a document's classification record could not point at the review that
settled it. `doc_set_type` writes it, which is what ties an assertion about a
document to the reviews chain (LAY‑11) with no second mechanism.

Not built, deliberately, and each is the issue's own numbering: **the embedding
nearest-label backend (req 2c)** and **the evaluation harness (req 6)**;
**trigger conditions on metadata (req 3's second half)** and **batch backfill
(req 5)** are the two blocks that follow. With this slice **both of #87's
acceptance criteria are met** —
`test/classify-review-tests.rkt` drives all three verdicts through the real
engine and `test/doc-pipeline-smoke.sh` §5c drives the queue over HTTP.

## A trigger on the TYPE, not the prefix (CLS‑19…23) — decided and BUILT 24 Oct 2026 (issue #87 req 3b)

Requirement 3 has two halves. The first — "classification result stored as object
metadata" — shipped in slice 1. The second is the point of it: *"so triggers can
match on it: extend trigger conditions to include metadata equality."* Without
that half, the type is a thing an operator can filter on by hand and nothing
acts on, and `triggers.rkt`'s opening complaint — matching on a key prefix and a
content type only — stands.

The matching itself is four lines. What made this a slice is that **a metadata
condition cannot be evaluated when a document arrives.** At `repo-put!` the
document has just landed and nothing has classified it, so a trigger watching
`doc_type` would wait for ever on the one seam the subsystem had.

| # | Decision | Why |
|---|----------|-----|
| CLS‑19 | **`match_attrs` is EQUALITY ONLY**: a JSON object of key → value, all of which must match, at most ten. | A trigger condition is operator-authored and evaluated on the write path of every document the team stores, which is the argument that froze the funnel's validation vocabulary and the workflow binding sublanguage. The vocabulary is `?attr=`'s, so an operator who can list documents by type triggers on the same thing in the same words. A non-string value and an empty one are REFUSED rather than coerced: LAY‑4 values are strings, so either is a condition that can never hold, and a trigger that silently never fires is the hardest thing on this surface to diagnose. The keys go through LAY‑4's own `field-key?` — now exported for this second asker — so `doc.type`, the spelling the issue asks for, is refused for CLS‑7's reason rather than accepted and never matched. |
| CLS‑20 | **A SECOND SEAM: `repo-set-attributes!`.** A trigger that names attributes also fires when a document's metadata changes. | The only alternative is polling, and the platform has no primitive for it that a team's own data could reach. `repo-set-attributes!` is the one place in the tree where object metadata changes, so it is the one place that needs the hook — the argument `repo-put!`'s post-write seam already made. Like that one it never fails the write: the attributes landed, whatever a subscriber makes of them. |
| CLS‑21 | **Exactly-once stays per (trigger, version)**, unchanged. | This is what BOUNDS the loop the second seam introduces: a workflow that re-records the type on the document that started it writes attributes, reaches the seam, and finds the fire row already claimed. A re-upload is a new version and legitimately fires again, exactly as DWF‑3 already said. Nothing new was needed for this, which is the argument for having put the idempotency key on the version in the first place. |
| CLS‑22 | **An ABSENT attribute never matches.** | That is what makes `doc_type` usable before anything has classified a document: at upload the condition is simply false, and the trigger waits. The alternative — treating absence as the empty string — would make `{"doc_type": ""}` fire on everything, and `""` is already refused for being "not set". |
| CLS‑23 | **A trigger wakes for the attributes it NAMES, and only when they MOVE.** One guard does both jobs. | The compatibility guarantee first: every trigger anybody has configured matches on a prefix and a content type, both fixed for the life of a version, so firing them on an attribute edit would be a behaviour change for every existing deployment — somebody correcting a typo in a `project` field would start pipelines. And the narrower half: a write that moves `project` must not wake a trigger whose unrelated `doc_type` condition merely happens to hold, because that is not news. So `repo-set-attributes!` reports the keys it actually MOVED, not the keys it was handed, and a write that changes nothing fires nothing. |

**A trigger is not a backfill.** Creating one does not fire it on the documents
that already match — requirement 5 is the backfill, and it is still unbuilt. The
seam reports transitions, so the honest reading of "a trigger fired" is "this
document became an invoice", not "this document is one".

**I wrote two guards where one sufficed, and the control is what showed me.**
`(positive? (hash-count want))` beside the changed-keys test is strictly
redundant — an empty `want` cannot contain any changed key — and inverting it
changed no test at all. #110 r1's lesson: a guard duplicating the next one is how
a reader comes to believe the next one is missing. It is gone.

**Three of the first eight controls did not bite, and the reason is worth
keeping**: once a trigger has fired on a version, exactly-once hides every later
mistake about WHEN it would have fired. The cases that test the seam's own
conditions therefore have to use a trigger created AFTER the document already
matches, which is the one state in which nothing else is deciding.

Still unbuilt on #87, by the issue's own numbering: **the embedding nearest-label
backend (req 2c)** and **the evaluation harness (req 6)**. The batch backfill
(req 5) is the block below.

## CLS‑24…28 — the backlog: a classification backfill (issue #87, req 5)

> Slices 1 and 2 classify ONE document somebody named. This is the prefix that
> was already there when the labels were decided — and the thing CLS‑23 says a
> trigger deliberately is not.

| # | Decision |
|---|---|
| CLS‑24 | **A backfill is a workflow, not a mode of the tool.** `doc_list_unclassified` + `map`, which is `index-documents` with one tool swapped. |
| CLS‑25 | **"Unclassified" is the absence of `doc_type`** — no table, no migration, and a re-run is free. |
| CLS‑26 | **A derived document is never listed**, or the next batch is the classifications the last one wrote. |
| CLS‑27 | **The scan pages past a page that yielded nothing**, and `repo-count` is what tells a short page from the last one. |
| CLS‑28 | **There is no `force`**, because the marker is the only thing a forced run could advance through. |

**A backfill is a workflow, not a mode of the tool** (CLS‑24). The requirement
says "batch mode", and a `batch: true` flag on `doc_classify` would be one tool
call doing unbounded work: no per-document retry, no cancel granularity, no
quota admission between documents, and a step output that is a list of N results
nothing can route on. `map` has been the engine's fan-out primitive since slice
46 and `doc-indexer`'s `index-documents` is this exact spec with one tool
swapped — find what has not been done, fan out, do each one, capped. So this
slice adds one tool and one spec and nothing to the engine at all.

**"Unclassified" is the absence of `doc_type`, not a table** (CLS‑25). The
marker is the thing the backfill itself writes, which is why a finished run
followed by another run classifies nothing, why no migration was needed, and why
there is nothing to keep in step with anything. The indexer's equivalent is a
`repo_text` row keyed to a version; here the assertion is about the DOCUMENT and
not about a particular set of bytes, so a re-upload does not make it eligible
again — its type is still asserted, and CLS‑16 already settled who may change
one.

**A document another run derived is never listed** (CLS‑26). `doc_classify`
writes `<key>.classification.json` beside its source and that record has no
`doc_type` of its own — so without this guard the next backfill would classify
the records the last one wrote, write records about THOSE, and never converge.
The indexer's `extractable?` filter is the same guard against the same shape.
The test is the `repo_derivations` row rather than a key suffix, because
`.extracted.json`, the filled forms and the translations are all somebody's
output too and a suffix list would have to be kept in step with seven tools.

**The scan keeps paging past a page that yielded nothing, and `repo-count` is
what makes that terminate honestly** (CLS‑27). `repo-list` applies `can?` per
row AFTER the SQL `LIMIT`, and this batch also skips anything already
classified, so a page can legitimately contribute zero ids while hundreds of
documents wait behind it. A lister that stopped at the first empty page would
report "nothing to do" and an operator would believe it — and the documents it
never reached would be exactly the ones behind a colleague's private folder.
`repo-count` is the same key window WITHOUT the per-row filter, which is the
only thing that can tell a short page from the last page; the disclosure it
makes is a count and no identity, within one team, behind `files:read`. Both
halves are positive-controlled, with a case for the authorization filter and a
case for the batch's own.

**`truncated` reports BOTH ways of stopping.** The window still having rows in
it, and the page having found more than a batch so the surplus was dropped. A
version reporting only the first says `truncated: false` to an operator whose
last page held thirty documents and whose batch kept twenty-five. It is
deliberately not a count of what remains: answering that means scanning the whole
team under `can?`, which is the work itself, and FLEET‑2's `unclaimable` reports
the same pair for the same reason.

**A batch is 25, where the indexer's is 40, and the difference is the model.**
Every document here may be a model request, and the shipped `ai.requests` default
is 200/day — so 40 would make five runs exhaust a team's day, which is the trap
recorded as "it worked and then stopped". `backends` is an input for the same
reason: `["rules"]` is free and deterministic and is the way to drain a real
backlog, and a document no rule describes is then refused BY NAME on that one
document while every other document still lands.

**There is no `force`** (CLS‑28). It is the obvious next flag and it cannot work:
the absence of `doc_type` is the only progress marker there is, so a forced run
has nothing to advance through and its second run would re-do its own first
batch for ever. The way to reclassify after changing the label set is to clear
the type — LAY‑4 clears an attribute by merging an empty value — which makes
exactly those documents eligible again and is a decision somebody makes on
purpose. Pinned over HTTP as well as in the unit suite.

**`ai.requests` counts scheduler JOBS at the job tier and model calls at the tool
tier**, and that is worth writing down because it cost an assertion here.
main.rkt's one biller records one `ai.requests` per job whatever the job did, so a
five-step run moves it by five with no model involved; only the tools' own
`meter!` increments it per model call. CLS‑1's rule — "a rules answer bills
nothing, and the REQUEST count is what proves it" — therefore holds at the tool
level, where `classify-tests.rkt` asserts it, and not over HTTP through the
engine, where the smoke asserts tokens instead. Not changed here: the meaning
would change every team's metering, and it is the ambiguity rather than either
number that is wrong.

**A backfill is what CLS‑23 deliberately does not do.** Creating a trigger does
not fire it on the documents that already match; this is the thing that does, and
it wakes those triggers on the way — a document that *becomes* an invoice is the
honest reading of a fire either way.

Still not built, by the issue's own numbering: **the embedding nearest-label
backend (req 2c)**, which needs an embedding wire, store and meter this build
does not have and belongs in its own issue. The evaluation harness (req 6) is the
block below.

## CLS‑29…33 — how good is it? the evaluation harness (issue #87, req 6)

> Every slice above asserts that the classifier RAN. This is the question none of
> them could answer: how often is it right, and which of its backends is carrying
> the load. It is the last piece of #87 this build can hold.

| # | Decision |
|---|---|
| CLS‑29 | **The ground truth is an object attribute**, `doc_type_expected`, and a fixture labelled outside the label set is EXCLUDED and reported, never scored as a miss. |
| CLS‑30 | **A backend that declines ABSTAINED; it was not wrong** — so accuracy is over what it answered and `coverage` is beside it, and an error is a third outcome. |
| CLS‑31 | **The chain's own answer is reported, DERIVED from the per-backend outcomes** — no second pass and no second implementation of the chain rule. |
| CLS‑32 | **The mean confidence of right and wrong answers is reported**, because that pair is what tells an operator whether CLS‑13's review threshold can separate them. |
| CLS‑33 | **An evaluation WRITES NOTHING** — no attributes, no record, no report document, and the tool is `files:read`. |

**The ground truth is an object attribute, and the fixture set is the
repository** (CLS‑29). `doc_type_expected` is one namespace along from the three
keys the classifier's own answer lands in (CLS‑7). The alternative is a manifest
of (object id, label) pairs passed to the call, and the difference is what
happens over a year: a manifest is a file somebody has to keep in step with the
repository, where an attribute makes the fixture set a thing the team curates in
place, grows one document at a time, and can list with
`?attr=doc_type_expected:invoice` for nothing. The field is DECLARED by the
harness itself, additively, through the same `repo-fields-declare!` that
`record-type!` uses — LAY‑4 refuses an undefined key, so without that nobody
could label a fixture at all and the harness would answer "no fixtures" for a
reason the operator could not act on. Declaring is not asserting: no document is
touched.

**A fixture's own label is held to the label set** — CLS‑5 and CLS‑15 pointed at
the third party who can get it wrong. "Invoice", "invoces" or a trailing space is
one keystroke away, and a fixture labelled that way is a document no backend can
ever agree with, so an accuracy figure computed over it blames the classifier for
somebody's typing. It is excluded from the counts and named in `excluded` with the
reason. Refusing the whole run was the other option and is worse: one typo would
make the report unobtainable.

**A backend that declines abstained, and that distinction is what the report
turns on** (CLS‑30). The rules backend is DESIGNED to answer only when a rule
matched — CLS‑1 puts it first in the chain precisely because it is certain when
it speaks — so scoring silence as an error would make a careful rule set look
worse the more careful it was, and would send an operator to loosen exactly the
rules that are carrying the load. So accuracy is reported over what a backend
ANSWERED and `coverage` over the fixture set, and both are needed: a backend that
answers one document perfectly is 100% accurate and useless. An **error** is a
third outcome rather than a kind of abstention, because a model that refused
twenty of twenty-five fixtures is the finding, and a report calling that
"abstained" would read as a cautious backend instead of a broken one.

**Each backend is run SEPARATELY, which is the thing production never does.**
Requirement 6 asks for accuracy "per backend", and in a chain the second backend
is only ever asked about the documents the first declined — so a chain run
measures the rules backend fully and the model backend on a biased remainder.
`classify-attempt` runs one backend on one document, and `backends` is an input
so an operator can ask for `["rules"]` and `["llm"]` and read the two columns
against each other.

**The chain is reported too, and it costs nothing** (CLS‑31). What production
runs is the chain, so a report of the backends alone leaves the operator
composing the answer in their head — and the composition is exactly "the first
backend that answered", which is already in hand. The `chain` row is computed
from the per-backend outcomes rather than measured again: no extra model request,
and the same answer `classify` would have given by construction rather than by a
second copy of the rule. In the unit suite it is already showing something
neither column does — rules answered one of three and was right, the model
answered two and was right about one, and because rules go first the chain got
both.

**The two confidence means are what calibrate the review hook** (CLS‑32).
`classify-review-extract` parks a run below `min_confidence` (CLS‑13), and that
knob is only worth setting when wrong answers arrive less confidently than right
ones. If both means sit at 0.9 the threshold cannot separate them, and that is a
fact about the backend no accuracy figure can express. Two numbers, per backend,
`null` when the bucket is empty.

**An evaluation writes nothing, and that is the decision the whole tool turns
on** (CLS‑33). `doc_classify` records a type on the document and that is right
for a classification; this is a MEASUREMENT of the classifier, and three separate
things go wrong the moment it writes. It would overwrite the type on a document a
run had already classified, so measuring would destroy what was measured. It
would move `doc_type`, which since CLS‑23 WAKES A TRIGGER — so evaluating a
fixture set would start pipelines over the fixtures. And its second run would be
scoring its own first run's output. So the permission is `files:read`: an
evaluation is a read of the repository that happens to spend model budget.

There is no report DOCUMENT either, for a smaller reason: a derived document needs
a source to derive FROM (DSH‑5), and a report is about a SET rather than about any
one of its members. A measurement of a moment belongs in the answer; the fixture
set is what persists.

**One step, and no `map`** — the opposite shape from the backfill one block above,
for a reason worth stating. `map` is right there because the work is a thing done
to each of N documents, each able to fail and retry on its own. An evaluation
produces ONE AGGREGATE over the set and the engine has no reduce step kind, so a
`map` here would scatter the report across N child outputs with nothing to add
them up. The tool does the bounded walk and the spec exists to make it REACHABLE:
no route runs a single tool, so a workflow is how an operator starts one from the
console and how its cost is quota-admitted like any other job.

**A ratio with nothing in its denominator is `null`, never 0.** Zero reads as "it
got everything wrong" where the truth is "it was never asked", and the two have
opposite remedies — the objection that keeps `interval_seconds` off a daily
schedule and a withdrawn `worker_state` off a stale executor. Every label in the
set gets a row for the same family of reasons: a type nobody wrote a fixture for
is a hole in the fixture set, and omitting it would report a clean sheet for a
label that was never tested.

**`(* 1000.0 0)` is an EXACT 0 in Racket**, so a ratio of nothing-out-of-something
came back as `0` where every other figure in the same column was a decimal. Both
are legal jsexprs, which is why nothing failed — and a report whose numbers change
type with their value is one a reader has to second-guess. `review.rkt`'s
`approval_rate` has the same shape and was left alone.

**A row's `answers` is keyed by SYMBOLS, because the report is a jsexpr.**
`jsexpr->string` refuses a string key, and the first version of this failed three
steps away inside the engine with a message naming neither the tool nor the field.

**`(last pipeline:workflows)` in a test is a landmine, and this slice stepped on
the one req 5 left.** `classify-backfill-tests.rkt` registered the plugin's last
workflow and looked the backfill up by slug; appending a fifth workflow made it
register the EVALUATION, so `flow-def-by-slug` answered `#f` and the failure named
a materialization that was working perfectly. Both suites find their workflow by
slug now.

With this, #87 is complete except for **the embedding nearest-label backend
(req 2c)**, which needs an embedding wire, store and meter this build does not
have and belongs in its own issue.

## WHK‑1…4 — a delivery is claimed before it is sent (issue #85, found 25 Oct 2026)

> Reported by a flake: two assertions in `server-smoke.sh`'s webhook block failed
> on one CI run and passed on a re-run, on a branch whose `server-smoke.sh` was
> byte-identical to `main`. The fixture was not the problem. **The platform could
> send one delivery twice.**

| # | Decision |
|---|---|
| WHK‑1 | **A sender takes the row before it sends**, believed only if a guarded UPDATE comes back — issue #17's rule, which the delivery sweep never had. |
| WHK‑2 | **The claim moves `next_attempt_epoch` forward and leaves the row `pending`** — no `sending` status, so no lease and nothing to reap; a dead sender self-heals. |
| WHK‑3 | **The synchronous ping's delivery is born owned**, so the sweep cannot take the row out from under the caller. |
| WHK‑4 | **The smoke's scripted failure is keyed on the EVENT, not on a call counter** — the fixture's own half of the same hazard. |

**What was actually wrong.** `deliver-one!` read the row with
`SELECT … WHERE d.status = 'pending'` and then POSTed, with nothing in between
that said "this attempt is mine". Two things made that collide in practice rather
than in principle: the delivery sweep rides the reaper seam at
`WEBHOOK-SWEEP-EVERY = 1` **second**, and `POST /api/webhooks/:id/ping` inserts a
delivery and then delivers it **synchronously** in the same request. So the
window between the insert and the POST was crossed by a sweep routinely, and on a
loaded runner reliably. Both senders selected the same row; both sent it. The
receiver saw one `x-telemachus-delivery` id arrive twice, and the row's final
state was whichever write landed last — a delivery that had SUCCEEDED could be
recorded as awaiting a retry, and one that had been refused recorded as
delivered. That is the pair of smoke assertions that failed: `last_status_code`
read 200 where the ping had been answered 500, and the delivery was no longer
`pending` so `redeliver!` did not refuse it.

**And it is worse than a race on one box.** The sweep runs in every process, so a
two-replica instance — which this platform supports, and whose scheduler has an
in-flight register precisely because it does — was liable to double-deliver
**every ordinary event**, not just a ping. #85's own module header promises "a
delivery record with backoff"; a record that can disagree with what the receiver
got is not one.

**The claim is #17's rule, arriving late** (WHK‑1). `claim-job!` has been a
guarded `UPDATE … RETURNING id` believed only when a row comes back since the
scheduler grew a second claim path; SCHED‑14's schedule tick and #114's feed
poller both reuse the shape. The delivery sweep was the one piece of recurring
work that selected and acted. `attempts` is compared as well as set, so the UPDATE
is a compare‑and‑swap: two senders that read the same row cannot both win it.

**The claim is the due time, not a status** (WHK‑2). A `sending` status was the
obvious alternative and it is the wrong trade here: a row whose sender dies
mid-POST would be stuck in it for ever, so it would need a LEASE and a second
sweep to unstick — the machinery SCHED‑8 built for jobs, where a handler runs for
minutes and there is something to preempt. A delivery is one POST with a
ten-second timeout. Moving `next_attempt_epoch` out to this attempt's backoff
makes the failure **self-healing**: a sender that vanishes leaves a row that
simply comes due again on its own schedule, with no status anybody has to learn
and nothing to reap. It is SCHED‑14's own argument — advance the due time BEFORE
deciding to fire, so a crash costs a skipped tick and never a duplicate.

The attempt is therefore **counted at the claim**, which is also the honest
reading: an attempt that was started was made. The failure path consequently
stops touching `next_attempt_epoch` — the claim already set it. **That part is a
one-home argument and not a behaviour fix, and the positive control is what
established it**: re-applying `backoff-seconds attempts` yields the same number,
because the attempt has not changed, so a second write differs only by the
seconds the POST took. The control could not bite, and the test says so where
somebody might otherwise trust it to — `canonical-json`'s sort rule carries the
same note for the same reason. Two copies of one rule is still worth removing;
claiming it was a defect would not have been.

**The ping does not race, it owns** (WHK‑3). Leaving the ping to contend for its
own row would have been correct — exactly one POST either way — and would have
made the answer to "does my webhook work" occasionally "somebody else is finding
out", which is useless to the person asking and flaky for the suite that asserts
it. `enqueue-event! #:claim <webhook-id>` mints THAT subscription's row already
claimed, carrying its first attempt and a future due time, so no sweep can see it
as due. Every other subscription's row is born pending and due, and the sweep
delivers those — pinned in its own case, because a `#:claim` that claimed the
whole fan-out would silently delay everybody else's delivery by a minute.

**The attempt number has two origins and an unconditional `add1` is wrong.** A
sender that claimed read the row before its own claim, so the attempt it is
making is one more than it read; the ping's row was born carrying it. Written as
a plain `add1` — which is what the first version of this fix did — the ping's
delivered row reported **two attempts for one POST**, and the test that counts the
receiver's calls is what said so. There is a smoke assertion on `"attempts":1`
now as well, because that number is what an operator reads.

**The fixture's half** (WHK‑4). The receiver's scripted 500 fired on
`state["calls"] == 1` while the subscription covered `ping,object.created`, so any
other delivery arriving first would eat it. The double-send is fixed at the
source, so the ordering is deterministic again — keying the failure on the EVENT
is what stops a future event from reproducing the same confusing failure, two
assertions away from anything to do with it. `ocr-smoke.sh`'s rule, in a fixture:
match the thing you mean, not the thing that happens to be first.

**Not changed, deliberately.** The sweep's one-second interval stays: the first
retry is a minute away, and #85's acceptance asks for a first attempt "within 2
seconds", so a slower sweep would make the backoff a lie. The race was never the
interval's fault — an hourly sweep would have the same defect and would hide it
for a year.

## RED‑1…9 — what the model is not told (issue #91, requirement 1)

> A workflow could send a document's text to a model and nothing MINIMISED it: a
> letter naming a person, their telephone number and their date of birth went
> entire, to whatever executor the team had configured. This is requirement 1 and
> requirement 5. Requirements 2, 3 and 4 — `redact: true` on the AI steps with
> rehydration, executor request logging, and the per-org policy that blocks
> unredacted text from reaching a disallowed executor — are later slices.

| # | Decision |
|---|---|
| RED‑1 | **The detectors are a closed, platform-authored set and the caller chooses only WHICH run** — a named detector, never a pattern the caller writes. |
| RED‑2 | **A token is stable within one document and deliberately NOT across documents**, because a token that meant the same person everywhere is a pseudonym, and a pseudonym is a join key. |
| RED‑3 | **Overlaps are settled by the longest match, and ties by a fixed platform order** — loosest detector last. |
| RED‑4 | **Text that already contains a token-shaped string is REFUSED**, not escaped or renumbered. |
| RED‑5 | **The token map is sealed whenever a key exists**, never gated on the content switch, and it is in `CREDENTIAL-SECRETS`. |
| RED‑6 | **No route returns a token map** — requirement 1's "never leaves the instance" by construction rather than by a check. |
| RED‑7 | **Opening a map needs `files:read` on the SOURCE**, and a refusal and a miss are one answer. |
| RED‑8 | **The redacted text is a DOCUMENT beside the source**, because "show me what you would have sent" is the only way to audit a redaction. |
| RED‑9 | **What this does not protect, stated**: the caller's own dictionary terms are run input, and a run is readable by anybody with `workflows:read`. |

**The detectors are named, not written** (RED‑1). The requirement says "regex
(emails, phones, SSN-like, policy/account numbers, dates)", and those are the
CLASSES to detect rather than a facility for writing patterns. An
operator-authored regexp evaluated against the text of a document the operator
does not control is a denial of service with the operator's own configuration as
the weapon — the call `classify.rkt` made for its rules (CLS‑2), `fields.rkt`
made for the funnel's validation vocabulary and `bind.rkt` made for the workflow
bindings. Here it costs the caller nothing at all: nobody wants to write an email
pattern, they want emails found. So the patterns are reviewed in one place, each
written with no nested quantifier, and the caller names detectors from a closed
list. The refusal says *why* it is closed, because "let me write my own" is the
obvious next request. The dictionary detector is the one thing the caller supplies
anything for, and what it supplies is **literal strings** — a term with regexp
metacharacters in it is a term, pinned by a case.

**An NER backend is requirement 1's optional third detector and is not built.**
It needs a model seam of its own and would make redaction cost a model request,
which is the thing redaction exists to make safe — so it is its own slice and the
refusal names it rather than letting it read as a typo.

**A token is stable within one document and nowhere else** (RED‑2). The same value
gets the same token here, which is the whole reason a span becomes a token rather
than a black box: the model can see that one person appears in three places and
reason about it. It is deliberately **not** stable across documents, and that is
the privacy decision of the slice — a token that meant the same person everywhere
would be a pseudonym, and a pseudonym is a join key. Hand two redacted documents
to a model, or to anybody, and they would learn the two concern the same person,
which is exactly the disclosure this step exists to prevent. The numbering is per
class in order of first appearance, so the output is a function of the document.

**The dictionary's token is keyed on the TERM, not the matched text**, which is
what makes RED‑2 true for it: a term matches case-insensitively, so "Lee" and
"LEE" are one person, and keying on the matched text gave them two tokens — the
model shown two people where the caller named one. Found by the test.

**Overlaps are settled by the longest match, ties by a fixed platform order**
(RED‑3), never by the order the caller named the detectors — the same document
redacted by two callers who asked for the same work must not come back
differently. **The detector list IS the priority order and runs from the most
specific pattern to the loosest.** `phone` is last because it is loose by a wide
margin — a digit, then seven to nineteen digits-and-separators, then a digit — and
with it ranked first, as the first version had it, the fixture letter's
`2026-10-14` came back as `<PHONE_1>` and its `078-05-1120` as `<PHONE_3>`. The
redaction was complete and nothing leaked; the **quality report** was wrong, about
a letter whose dates requirement 5 exists to count.

**Text already containing a token is refused** (RED‑4). The token is what the
model is asked to reason about and what requirement 2 will replace BACK, so a
literal `<PERSON_1>` already in the text makes the reply ambiguous between a span
this redaction replaced and a string that was always there — and rehydration would
then put a real name where the document never had an identifier. That is the one
failure mode of this feature that INVENTS data rather than losing it, so it is
refused by name. A per-redaction nonce in the token was the alternative and it
makes every token unreadable to the model, which is the thing tokens exist to be.

**The map is sealed whenever a key exists** (RED‑5). `#:credential`, and the flag's
name is about #85's signing secret while the property it names is "seal whenever a
key is configured" — this is the clearest case of needing that property which is
not a credential. The column holds `<PERSON_1> -> Arun Patel` for every person in
every redacted document: a concordance of exactly the identifiers the step took out
of a model request. Gated on `TELEMACHUS_ENCRYPT_CONTENT`, whose documented default
is OFF, the ordinary instance would store them in the clear — a feature doing the
opposite of its name on the default configuration, which is #119's shape. It is in
`CREDENTIAL-SECRETS` for that reason and for a second one the schedule-payload note
already states: a sealed column `rewrap` does not walk is silently unrotatable, and
here an unopenable map is a redacted document that can never be rehydrated again.

**The whole-database scan is what checks it, not a list of sites.** `#83`'s own
lesson — the scan beat the enumeration twice — so `dump-leak-tests.rkt` gained a
redaction probe and the pair that makes it mean something: with **no key** the
scanner finds the map in the clear, and with a key and the content switch OFF it
does not.

**Nothing serves the map** (RED‑6). `routes.rkt` gained nothing in this slice, and
that is how "never leaves the instance" is kept — by construction rather than by a
check somebody has to remember. Rehydration will read it in process, inside the
step that is about to put a value back. The same rule applies to what IS served:
the tool's result carries the TOKENS and never the values, because a tool result
reaches a workflow step's stored output, the agent's transcript and a console pane,
which is three more copies than the sealed row has.

**Opening a map needs `files:read` on the source** (RED‑7), and nothing more,
because the map is a strict subset of that document's own text — a caller who may
read the document may already read every value in it, so a stricter rule would
protect nothing and would stop the pipeline's own steps from rehydrating. A refusal
and a miss are **one answer**, collapsed in one place so a caller cannot tell them
apart by choosing a different function: that somebody redacted a document you
cannot see would itself say the document exists and that it had identifiers in it.

**The redacted text is a document** (RED‑8), not a field on a response. It is the
artifact a person has to be able to read before they trust the step, and it is what
requirement 2's steps will take as their input. So it lands beside the source as
`<key>.redacted.txt` through `derive!` — private from its first byte with the
source's own grants, and a `repo_derivations` row saying which run made it. The
document goes first and the row second, which is CLS‑11's order read the other way
round: the row is the only copy of the map, so a row written before a refused
`derive!` would leave a map to a redaction nobody can see.

**A document whose text cannot be read is a REFUSAL, not an empty redaction.**
`doc_classify` can classify a photograph from its content type (CLS‑9) and this
cannot: a redaction of nothing is a document that reads as safe to send, which is
the one answer this step must never give. So it goes through `doc_text`, which
refuses by name — including the scan that needs OCR.

**What it does not protect** (RED‑9). The dictionary's terms are the caller's own
input, and a workflow stores every run's input in `workflow_runs.input` — sealed at
rest only under the content switch, and handed back by `GET /api/runs/:id` to
anybody holding `workflows:read`. So the names somebody asked to have redacted are
visible to their colleagues, and for a list of names that is worth knowing rather
than discovering. It is FEED‑13's line: a read returns the configuration as given,
because an operator who cannot see what they typed cannot maintain it. Requirement
2 is where the terms stop being a run input and become part of a spec or a trigger.
Both the unit suite and the smoke assert it, so that the refutations beside them
cannot be read as "the run is clean".

**A harness that greps for the word "failure" always agrees with you.** The
positive-control harness read its verdict by scanning output for "failure", and
`dump-leak-tests.rkt` prints "(control, failures) the needle is in: …" as ordinary
diagnostic output — so every control against that file reported that it bit,
including the RED‑5 one, which is the only check that the map is sealed at all. The
verdict is read off `raco test`'s summary line now. And one control that genuinely
did not bite was found by the same fix: the longest-match case used two spans
beginning at **different** offsets, so the position sort settled it and the length
comparator never ran.

## RED‑10…14 — a step that redacts before it asks (issue #91, requirement 2)

> Requirement 1 redacts a document into another document. This is the half a
> pipeline needs: `doc_extract_fields`, `doc_classify`, `doc_translate` and
> `POST /api/ai/chat` take `redact`, build their request from the redacted text,
> and put the values BACK before anything is stored. The issue's own acceptance
> criterion is this slice's test: *the stub receives only tokens, and the stored
> extraction contains the real values.*

| # | Decision |
|---|---|
| RED‑10 | **Rehydration is ONE regexp pass with a lookup**, never a replacement per map entry. |
| RED‑11 | **A token the model invented is left verbatim and REPORTED** — never guessed at, never fatal. |
| RED‑12 | **The map is not persisted when redaction is internal to a step** — it exists for one tool call. |
| RED‑13 | **`redact` takes a string prompt and refuses content PARTS**, because a parts prompt may carry an image no detector can read. |
| RED‑14 | **The streaming endpoint refuses `redact` rather than ignoring it** — a token can be split across two SSE events. |

**One pass, not one per entry** (RED‑10). The obvious implementation walks the map
calling `string-replace` for each pair, and it is wrong as soon as a document has
ten of anything: replacing `<PERSON_1>` first rewrites the first eight characters
of `<PERSON_11>` and leaves `<a name>1>` behind. Sorting longest-token-first fixes
that collision and leaves the general hazard — a *value* that itself contains a
token-shaped string would be rewritten by a later pass. One pass over the token
pattern, deciding each match by lookup, cannot do either. Both halves are pinned,
and the control fails four cases.

**An invented token is left verbatim and reported** (RED‑11). `<PERSON_7>` where
only three people were replaced maps to nobody, and the two alternatives are both
worse: guessing the nearest token would put a real person's name into an answer
about somebody who was never mentioned, and failing the step would throw away a
whole extraction over one hallucinated string in a rationale. Left alone it is
VISIBLY wrong to the person reading the stored field, and `unknown_tokens` comes
back so a caller can refuse it if they would rather.

**The values go back BEFORE the schema is applied.** The schema is the CALLER's
and describes real values, so a `pattern` or a `maxLength` on a telephone number
would refuse `<PHONE_1>` — and the refusal would quote the token, which is both a
confusing error and a token in a log. `extract-fields` therefore returns THREE
values now (the third is the unknown-token list), which is a breaking change to an
internal export and cost two existing call sites a line each.

**The map is not persisted here, and that is the point of doing it inside the
step** (RED‑12). `doc_redact` stores its map because its output is a redacted
DOCUMENT that something later may have to rehydrate against. An internal
redaction redacts and rehydrates within one tool call, so a stored map would be a
concordance of identifiers kept **for no reader at all** — and that column is the
most sensitive thing in the schema. The record notes that redaction was applied
and which detectors ran, which is what requirement 2 asks for; the values were
never written down. Asserted over `repo_redactions` in both the unit suite and the
smoke.

**`doc_classify` redacts for the MODEL and matches its RULES on the real text**,
and it is the one place requirement 2 cannot simply swap the input. A rule is
deterministic, local and never leaves the process, so matching it on tokens buys
nothing and costs correctness — a rule keyed on an account-number prefix would
match `<ID_1>` and nothing else. `classify` gained `#:llm-text`, defaulting to
`#:text`, so every existing caller is unchanged. With a **rules-only** chain
nothing is redacted at all and the record says `applied: false`: reporting
otherwise would claim a protection that was never needed, because no model saw
the document.

Only a classification's **rationale** can carry a token back — the label is held
to the label set by an `enum` (CLS‑5), so a token there is refused before
rehydration is reached.

**`doc_translate`'s row and its document deliberately differ.** `translate!`
stores `source_text` and `result_text`, and with redaction on those hold the
REDACTED pair — which is what crossed the wire, is strictly less content at rest
than before, and is the honest record of the request. The derived document is the
rehydrated translation, because that is what a reader wants. The tool result says
redaction was applied, so the two are not a mystery.

**`redact` takes a string prompt and refuses content parts** (RED‑13). A parts
prompt may carry an IMAGE, and none of these detectors can read one — so
redacting the text while sending a picture of the same letter untouched would be a
redaction that claimed more than it did. A 400 that says so beats a half-measure
nobody can see.

**The stream refuses it rather than ignoring the field** (RED‑14). A token can be
split across two SSE events — `<PERSON` in one and `_1>` in the next — so putting
the values back would mean buffering the whole answer before emitting any of it,
which is the one thing a stream exists not to do. Half-rehydrated text reaching a
reader is worse than a refusal: they would see a name beside a token with no way
to tell which parts had been put back. The refusal names the endpoint to use.

**The published pipelines are untouched, and the smoke publishes its own spec.**
`redact` is a TOOL argument, so a workflow binds it as a literal — `pdf-form`'s
pattern, for `pdf-form`'s reason: adding an input to a published spec is a
breaking change for every caller of it. A hand-written spec uses the WIRE grammar
(`${steps.<id>.output.*}`) and not the macro's `(out text result)` sugar, which
the first version of that block got wrong and the validator refused while naming
every form it accepts.

**Two of eleven controls did not bite, and both were real test gaps.** The
rule/model split had no case where a rule depended on text redaction would
destroy, so matching rules on the redacted text passed everything; and nothing
exercised a schema that a token would fail, so swapping validate-and-rehydrate
passed too. Both cases exist now. A third found its own trap on the way: with
`phone` as the only detector, the fixture letter's ISO date is also a phone match,
so `<PHONE_1>` there is `2026-10-14` — the case uses a one-line text instead, and
says why.

## RED‑15…23 — the model-request log (issue #91, requirement 3)

Requirement 3 reads like a narrowing of something that exists: "executor request
logging stores prompt hash, model and token counts, never prompt text". **There
was no model-request log at all.** `ai.requests` is a counter in the quota
ledger; it answers how much a team spent and can never answer what was sent,
where it went, whose call it was, or whether it was refused. So the first half of
this slice is the log, and the second is the one thing a platform can honestly
enforce about somebody else's machine.

**RED‑15 — the table is defined by what is not in it.** `model_requests`
(migration `0062`) has no prompt column, no reply column and no excerpt. The
digest is the only thing that stands for the content, and the row carries the
executor, the transport, the model, the backend's host, whether it was off this
box, what it declared, a message count, a character count, the token count and
the outcome. The two counts are kept deliberately and are the only weak signals
here: they are what tells a forty-token question from a whole document, and
neither reads back as content.

**RED‑16 — THREE PATHS LEAVE THIS PROCESS, NOT ONE.** `model-exchange`'s own
header calls itself "the ONE place a model request leaves this process", and that
is true of the non-streaming push and local calls it carries. It is not true of
content crossing the network: `run-chat-stream` calls `openai-llm-stream`
directly, and a PULL executor's content leaves by the job row to a worker on
another host. A log covering only `model-exchange` would be silent about exactly
the two paths an operator would most want to check, so all three are logged and
`transport` says which — `push`, `stream`, `pull`. **The SIMULATED echo is not
logged**, and that is the sharper half of the same rule: nothing left the
process, and a row for it would make the log answer "yes, this was sent" about a
call nobody made, which is the worst thing a log of this kind can do.

A `pull` row claims **no endpoint**. The platform does not know, and must not
guess, which model URL a worker will call; so the row says nothing about it, and
consequently reads as not-on-this-box, which is the honest answer for content
that left by a job row.

**RED‑17 — the logger is a BOX, because executor.rkt has no database.** That
module's own `pull-router` is a box for the same reason, and `server/main.rkt`
installs a writer that knows the connection and the principal (from
`current-job` inside a scheduler job, from `current-request-principal` on the
request path — the two sources the pull router already reads). **A failure in the
logger never fails the model call**, the trigger seam's rule: an unwritable log
is an operational problem and losing somebody's answer is theirs. A call with no
team context is still logged, with a NULL team — it happened, and dropping it
would make the log quietly incomplete for exactly the platform-internal calls
nobody can attribute.

**RED‑18 — "PROMPT HASH" IS THE RIGHT SHAPE AND A BARE SHA‑256 IS THE WRONG
PRIMITIVE FOR IT.** A short prompt is reversible from a word list:
`sha256("Arun Patel")` is the same digest on every machine in the world, so a
bare hash here would make this table a confirmation oracle over exactly the
identifiers requirement 1 exists to keep out of a model request — a leaked log
plus a name list and the question "was this person in a document you sent" is
answered. The digest has to be comparable **by this instance and by nobody
else**, which is what a keyed MAC gives and a hash does not. `secret-digest`
lives in `secretbox.rkt`, beside the key rather than in the module that wants
it: exporting the key bytes so a caller could HMAC with them would make that
module one of two homes for the key, and the whole argument for `secret-wrap`
living there is that there is only one.

With no key configured it is a plain SHA‑256 and the row's `digest_alg` says so.
That is the honest failure — an instance in the documented plaintext-at-rest
posture still gets a digest it can compare with itself, and a digest that
silently changed meaning with the environment would be worse than one that
reports which it is. **Rotating the key makes earlier digests incomparable with
later ones**, and there is nothing to re-wrap because the prompt was never kept,
so `digest_key_id` records which key answered and a reader sees a new key rather
than concluding the text changed.

**RED‑19 — the row is what the request WAS, so a failure and a REFUSAL are rows
too.** A 502 from somebody else's gateway, and a call this instance would not
make, are precisely what somebody auditing a hosted backend came to read; a log
that recorded only successes would agree with every happy path. `status` is
`ok` / `error` / `refused`, and `error_kind` is a short closed label and **never
an exception message** — #83 r4 sealed four `error` columns because this
platform's own refusals quote what they choked on by design, and the diagnostic
already has a sealed home on the job row.

**RED‑20 — `no_content_logging` IS AN ASSERTION NOTHING CAN VERIFY, AND WHAT IS
ENFORCED IS THAT SOMEBODY MADE IT.** No software can check what a remote
operator retains. What this instance can do is refuse to send a team's document
text to a backend that is not on this box until its own operator has declared,
per executor, that the backend does not log content —
`TELEMACHUS_REQUIRE_NO_CONTENT_LOGGING=1` is that switch, and the refusal is
raised before the body is composed, because a check that fired after the POST
would be a report rather than a policy. Off by default, every default-bearing
knob's rule: a real default would make an upgrade start refusing the calls this
platform exists to make. Unset, an undeclared hosted backend is still used and
the row records `content_logging: "undeclared"`, so the gap is **visible rather
than assumed** — `worker_state`'s withdrawal rule, pointed the other way.

The declaration rides in the LAY‑9 capability document, so it needs **no
migration and no new code to set**: it arrives identically from `executors.json`
and from `POST /api/executors`, and `observe-capabilities!` merges a worker's
poll additively, so a declaration survives one. An absent LAY‑9 capability means
UNKNOWN and unknown is permissive, which is right for "can you tool-call" and is
not what this field means — here the ABSENCE is the thing being reported, so it
gets its own value rather than a silent pass.

**RED‑21 — "hosted" is the loopback predicate, not a new one.** A fourth copy of
"which hosts can only this machine reach" would drift from the three that
already agree, so `loopback-bind?`'s normalizing wrapper is hoisted into
`peer.rkt` as `loopback-host?` and all three ask it. A backend on `127.0.0.1` is
not hosted — nothing left the box — and that is what keeps the ordinary
single-box instance talking to ollama outside the policy entirely. A
private-looking address IS hosted, because "10.x is internal" is an assumption
about somebody else's network (peer.rkt's own rule), and **an endpoint nobody can
parse is hosted too**: the policy exists for the backends nobody can place, so an
unreadable one must not be exempted by its own unreadability.

**RED‑22 — the log is `audit:read`.** It is the team's own trail of its own
calls and the question it answers is an audit question, so it rides the
permission that already means that — admin and both company stewards, never a
plain member. The digest is information about CONTENT, which is why a member does
not hold it: #84's rule, where who-read a document sits behind `files:manage`
because it is information about people. The stored endpoint is the **host only**,
never the key and never the query, because this string is what a reviewer reads
(FEED‑6's line).

**RED‑23 — two CLOSED vocabularies, and this time the writer enforces them.**
`READ-DOORS` and `QUESTION-TYPES` were each declared, commented as closed, and
referenced by nothing — #113's shape, gated afterwards by a static source scan.
The scan was right there because a `read-context` is built on the path of every
read, so raising would turn a typo'd door into a 500 on a document download.
**Here a raise is right**, and the difference is the one property this writer has
that the constructor does not: its caller already swallows a failure (RED‑17), so
an invented status costs a row and a line on stderr naming it, and cannot cost
anybody their answer. That is cheaper than a scan and stronger than one.

### What this cost, and what the controls found

Fifteen controls, and **all fifteen bite** — including the two that matter most:
moving the policy check to after the pull dispatch fails the assertion that the
router was never asked (not the one about the exception), and making the digest
a plain SHA‑256 fails the case that says two instances must not agree about the
hash of a name.

- **Two of them only bite because the slice was widened after the first pass,
  and both gaps were real.** `timeout` and `unreachable` were declared in
  `ERROR-KINDS` and nothing produced them — the slice's own version of #113 —
  until the classifier read `llm.rkt`'s `exn:fail:model-retryable` reason, which
  is the seam PULL‑14 already branches on; and the logger's handler was a
  catch-all, so a control narrowing it to `exn:fail?` could not bite until a
  case raised something that is not a failure and asserted it escapes. A model
  deadline shuts its request's custodian down and the shutdown drain stops the
  server with a break, so a logger that caught either would have turned a stop
  into a hang.

- **`rackunit`'s `test-case` hands its body's last value back when the body has
  internal definitions**, and `putenv` answers `#t` — so a test-case that
  restored an environment variable last printed a bare `#t` into the suite's
  output, which reads like a leak and is not one. Restore through a wrapper that
  answers void.
- **`test/pull-smoke.sh` had no `refute`**, the fourth file in this tree to be
  caught by that: a `refute` written without one runs as an unknown command,
  nothing sets `fail`, and the suite reports PASS with the assertion silently
  absent. Grep for a helper before using it.
- **The whole-database leak scan has nothing new to say here, and that is the
  property.** `model_requests` has no content column at all, so the strong form
  of #83's pair cannot be written — there is nothing to switch off that would
  make the scanner find a prompt. What `dump-leak-tests.rkt` establishes instead
  is that the scan is LIVE in that fixture and that no `model_requests` column is
  among its hits; the row-by-row scan over `SELECT *` in
  `test/requestlog-tests.rkt` is what catches a column added later, and is where
  one would land.

## RED‑24…33 — where a labelled document's text may go (issue #91, requirement 4)

Built 26 Oct 2026 — the last requirement of #91 and the one the issue was about.
Requirements 1 and 2 built the means to minimise what a model is told; requirement
3 built the record of what was sent. **Neither one stops anything.** This is the
per-org list of executors allowed to see a labelled document's text, and the
refusal when the executor is not on it.

No migration, no new vocabulary, no new attribute mechanism:
`domain/ai/sensitivity.rkt` (the policy, two `instance_settings` documents) plus a
box in `executor.rkt` filled by `server/main.rkt`, and the label is the LAY‑4
object attribute `sensitivity`.

```sh
raco test test/sensitivity-tests.rkt   # 21 cases, twenty controls
bash test/doc-pipeline-smoke.sh        # the "== 5h." block, 24 assertions
```

- **RED‑24 — THE LABEL IS A LAY‑4 OBJECT ATTRIBUTE, which is why this is a small
  slice.** LAY‑4 is already "what the team ASSERTS about a document", a team
  defines the field and its options exactly as it defines `project` or `status`,
  and `?attr=sensitivity:confidential` lists them for nothing. The policy names
  labels; the team's own field definition is what makes a label settable. The two
  can drift, and the refusal REPORTS the drift — it names the labels the policy
  does list — rather than hiding it. The key is fixed, like `doc_type` (CLS‑7): a
  policy that named its own key would let two documents be sensitive in two
  different vocabularies, and `?attr=` is an equality filter over one key.

- **RED‑25 — OFF UNLESS CONFIGURED, AND THE TWO ABSENCES ARE NOT THE SAME THING.**
  With no policy document at either tier nothing is refused, whatever a document
  is labelled — every default-bearing knob in this tree makes that call, and here
  the alternative is worse than usual: a team already using an attribute called
  `sensitivity` for something of its own would find every AI step refused by an
  upgrade it did not ask for. Once a policy exists, a document with **no label**
  is still allowed, because nobody asserted anything; a document carrying a label
  **no tier mentions** is REFUSED. That is deliberately the opposite of LAY‑9's
  "an absent capability is unknown and unknown is permissive", and the difference
  is who is silent: in the first case the team, in the second the policy, about a
  mark the team has made. The only way to reach the second is to remove a label
  from a policy while documents still carry it, and quietly un-protecting exactly
  those documents is the worse failure.

- **RED‑26 — THE GATE IS AT THE THREE PLACES A REQUEST LEAVES, AND THE LABEL
  ARRIVES BY PARAMETER.** RED‑16 is why: `model-exchange`'s own header calls
  itself the one place content leaves and it is not — `run-chat-stream` calls
  `openai-llm-stream` directly and a pull executor's content leaves by the job
  row — so `content-logging-refusal` had to be written into all three by hand one
  requirement ago. `egress-refusal` is now ONE function the three sites share, and
  it asks the policy about `current-egress-document`. The alternative was to gate
  in each tool, where the document is: four gates, and the first new asker
  unprotected with nothing to say so.

- **RED‑27 — ONE BINDER, FOUR ASKERS, so the forgetting happens somewhere a
  person has to act.** `with-document-egress` in doc-tools.rkt replaces the
  `current-utility-executor` parameterize each of the four model-calling tools
  already carried one copy of, and binds the document beside it. A new tool that
  forgets to call it is unprotected — the same shape either way — but the thing
  it forgot is a function somebody calls on purpose rather than a check they have
  to remember to copy, which is the argument `record-type!` and
  `repo-fields-declare!` both make. In `doc_classify_eval` it is bound **per
  fixture**, not once around the fold: the label is a property of each document,
  and a single binding would govern a labelled fixture by an unlabelled one's
  answer. `doc_extract_fields` now resolves its source BEFORE the model call
  rather than after — it used to read it only to derive the output from.

  **What is outside the policy, stated rather than implied**: a tool handed text
  with no document (`doc_extract_fields` with `text` and no `object`,
  `POST /api/ai/chat` with a free prompt, the agent's tool results) carries no
  label. Requirement 4 governs documents, and any caller can paste content it
  read elsewhere — the same line #83 had to draw about what sealing can promise.

- **RED‑28 — THE DECISION LIVES IN THE DOMAIN, NOT IN main.rkt.**
  `make-egress-policy` is what the server puts in the box, because the acceptance
  test drives a real tool through a real `run-chat` and has to install the same
  decision the server does — a test with its own copy would agree with any change
  to this one, which is `executor-can-run?`'s drift in the one place this slice
  could least afford it. The request context comes in as a THUNK: the principal
  is a parameter in `server/kit.rkt`, and a domain module requiring kit would
  instantiate the connection pool, which is how #123's rule was earned.
  **The org is the DOCUMENT's**, not the caller's — on a cross-team share the two
  differ, and reading it off the principal would let a reader's company decide
  where another company's document may be sent.

- **RED‑29 — A REFUSAL IS AUDITED, AND THE PERMISSION TO READ THE POLICY IS AN
  OPERATOR'S.** The issue's second acceptance criterion is "refused **and
  audited**": `ai.egress.refused` carries the label, the executor, the backend's
  HOST and the reason, and never the text or the object KEY — which routinely
  carries a name, and this log is chained, exported off the box and kept through
  an erasure (AUD‑2, DEL‑7). The entry names the DOCUMENT's team, the eighth
  appearance of the `#:team-id` shape in these notes. A FAILED AUDIT WRITE DOES
  NOT RESCUE THE REQUEST — the refusal stands and the failure goes to stderr;
  letting a labelled document travel because the record of refusing it could not
  be stored would be the one failure this exists to prevent. Reading the policy
  is `instance:manage` / `org:read`, as the session policy's is: it is a list of
  this instance's own backends, and what a team member needs from it is in the
  refusal they already got.

- **RED‑30 — THE ALLOWLIST IS FOR UNREDACTED TEXT**, which is requirement 4 read
  as written ("prevents **unredacted** text from reaching any executor not on the
  list"). Tokenised text may travel to a backend that is not on it, because making
  exactly that safe is what requirements 1 and 2 are for — otherwise the two
  halves of this issue would contradict each other. An operator who disagrees
  sets `allow_redacted: false` on the label, which puts the list back in charge
  of everything. A **loopback** backend is outside the policy entirely, the
  exemption `content-logging-refusal` makes one requirement earlier and for its
  reason: nothing left the box, so there is nothing for an allowlist to allow —
  which keeps the ordinary single-box instance talking to ollama out of the
  feature's way. A **pull** executor has no endpoint and therefore counts as
  hosted (RED‑21), which is right, because its content leaves by the job row.

- **RED‑31 — TIGHTEN WHERE BOTH TIERS SPEAK.** SESS‑4's rule, with a
  qualification that is what makes it usable on a multi-tenant instance: for a
  label both documents mention, the permitted executors are the INTERSECTION and
  both flags are ANDed, so a company narrows what the instance allows and can
  never widen it. A label only ONE tier mentions is that tier's to decide — were
  an unmentioned label a denial, the instance operator would have to enumerate
  every company's own vocabulary before any company could permit anything, and
  the labels are the company's.

- **RED‑32 — THE UNNAMED CONFIGURED MODEL IS A BOOLEAN, NOT A RESERVED NAME.** A
  hosted `TELEMACHUS_MODEL_URL` has no executor name, so it cannot be on a list
  of names; a reserved member spelled `"default"` would collide with an executor
  an operator legitimately called that, and the collision would be invisible. So
  `default_model` is its own field, false by default — which costs the ordinary
  single-box instance nothing, because a loopback default model never reaches the
  list at all.

- **RED‑33 — A TYPO IN THE LIST FAILS CLOSED, SO IT IS REPORTED AND NOT REFUSED.**
  An executor name no executor answers to is simply never matched, so the label's
  text goes nowhere; the read reports it as `unknown_executors`. That is the
  opposite call to `PUT /api/model-roles`, where a typo silently sent every
  extraction to the local model and so had to be refused on the write — and
  refusing it here would make a policy unwritable before the backend it names
  exists, which is the ordinary order an operator sets one up in. **A policy that
  cannot be READ refuses**, which is the opposite of `log-model-request!`'s
  swallowed failures and deliberately: a log that does not write costs an
  operator a record, a control that does not run costs somebody their document.
  Only a request carrying a label ever asks, so a broken database cannot stop
  every model call on the instance.

- **RED‑34 — THE INSTANCE TIER NEEDS A WAY OFF, AND `PUT {"labels": {}}` IS NOT
  ONE.** An empty labels object is an operator saying "govern nothing", and it is
  still a CONFIGURED policy — so by RED‑25 it refuses every label it does not
  mention, which is every label. Without `DELETE /api/executor-policy` an
  operator who turned the feature on could never turn it off, and every labelled
  document in the instance would be refused for ever. **A smoke fixture is what
  found it**: §5h left an empty policy and a labelled document behind, and the
  knowledge-graph section 150 lines later stopped being able to read that
  document. The platform was working exactly as designed; the hole was that
  nothing could undo it. The org tier already had its `DELETE`, which is how the
  asymmetry went unnoticed.

### What the controls found

Twenty controls, and the two that did not bite first time were both real gaps:

- **`default_model` was ANDed across the tiers and nothing exercised it.**
  Patching that one `and` to an `or` left all 21 cases passing — this slice's own
  #113, a rule nothing holds. The tiers case asserts both flags now, and the
  refusal that follows from the second.
- **A control that fails to COMPILE has not bitten.** Removing the binder's
  argument left `src` referenced nowhere and the run failed with a Racket error
  rather than a red assertion, which proves nothing about the test. Rewritten to
  bind `#f` instead, which compiles and then fails the cases that matter.
- **An unroutable address blackholes rather than refusing**, so proving a request
  was NOT stopped by letting it try costs the whole `TELEMACHUS_MODEL_TIMEOUT`.
  The push and stream cases assert the refusal, which happens before any socket;
  the "an unlabelled request is not governed" half is asserted against
  `egress-refusal` directly.
- **`doc_classify`'s tool result calls the answer `label`, not `doc_type`** —
  `doc_type` is the attribute it writes. Two cases asserted the wrong key and
  failed for a reason with nothing to do with the policy.
- **`audit-list` does not project `meta`, and that bit for the second time in
  this tree.** The smoke's first version asserted the label inside it — which
  failed — while the two `refute`s beside it, for the text and the document's
  key, **passed vacuously**, because the field is not in that response at all.
  #59's rule: asserting over an API that never carried a field is worse than not
  asserting. A meta's contents are asserted over the ROW.
- **A smoke block inherits the previous block's MOCK REPLY FILE**, and §5h first
  wrote over it rather than merging into it — which starved an extraction two
  sections later and read as a broken extractor.
- **A block that changes GLOBAL state has to put it back.** Leaving a configured
  policy and a labelled document behind is what produced RED‑34 above; the
  last-owner fixture in `server-smoke.sh` is the same lesson from the other end.

## FORM — filling a PDF form somebody else wrote (issue #88 requirement 2)

Decided and built 26 Oct 2026. `doc_render` (DWF‑6) fills a TEMPLATE this
platform's own user authored; requirement 2 is the other direction — an AcroForm
that ARRIVED, from a ministry, an insurer or a customer's procurement system —
and it is the half of #88 with **no workaround today**: the LaTeX path cannot
touch an existing form's fields at all, whereas a branded layout can at least be
approximated. So it is built first, which inverts the issue's own numbering.

`domain/repo/pdfform.rkt` (the engine, pure of the repository), `doc_fill_form`
in `doc-tools.rkt`, and `GET /api/repo-obj/:id/form-fields`. **No migration, no
new environment variable, no new permission.**

- **FORM‑1 — TWO BINARIES, each for the half it is good at.** `pdfcpu` lists and
  fills: its `form list --json` export already describes every field with its
  kind, value and options, which IS the shape requirement 2 asks a discovery
  endpoint to return, and a trimmed copy of it is the fill input — so nothing has
  to be composed in FDF, which is what made `pdftk` the usual answer and would
  have brought a JVM with it. `qpdf` flattens
  (`--generate-appearances --flatten-annotations=all`), because **pdfcpu 0.15 has
  no flatten of any kind** and qpdf's pass builds the appearance streams a filled
  field needs and then draws the annotations into the page content, which is what
  "flattened" means to everything downstream. Both are small, both are already in
  the pin, and neither is a Python application.
- **FORM‑2 — found at CALL time, and SEPARATELY.** DWF‑6's rule for pandoc and
  tectonic: a box with neither binary still boots and every other tool keeps
  working, and the failure is a named error on the one call that asked. Looked up
  separately because a box with pdfcpu and no qpdf can fill a form perfectly
  well — only `flatten: true` is refused there, and the discovery read says so in
  `can_flatten` rather than letting a caller find out from a refusal.
- **FORM‑3 — THE UNMATCHED LIST IS COMPUTED HERE, and it has to be.** Measured:
  pdfcpu accepts a field name no field on the form carries, writes the output and
  **exits 0**. So requirement 2's "reports unmatched fields" cannot be delegated
  to the tool, and without computing it a caller who misspelled one field would
  be handed a document that looks filled with nothing saying which half of their
  request was ignored. The control for this is the first one in the harness.
- **FORM‑4 — a PARTIAL match is reported and EVERY name wrong is refused.**
  Filling four of nine fields now is an ordinary thing to do, so `unmatched` is a
  report. Every name wrong is somebody addressing the wrong document or using the
  wrong vocabulary, and a report is no use to them — so that is a refusal, and it
  **lists the fields the form does have** (CLS‑15's shape, where the refusal
  names what was on offer rather than guessing).
- **FORM‑5 — a value is held to its FIELD's kind, and a choice field to its own
  options.** A checkbox takes a boolean; a radio group, combo box or list box
  takes one of the options the form itself declares. The second is the one worth
  the code: a `/V` the form's own reader cannot interpret renders as **blank**
  while the document claims it was filled, which is the failure shape this whole
  area has to avoid. The set is known, so guessing is not needed — CLS‑5's
  argument about a label, applied to a field.
- **FORM‑6 — a read-only field is REFUSED, not skipped.** `/Ff` bit 1 is the
  form's author saying this field is not the filler's to set. Filling it silently
  would be a lie either way: write it and the document disagrees with its own
  design, skip it and the caller believes it landed.
- **FORM‑7 — a PDF with no form answers an EMPTY LIST; a document that is not a
  PDF is a 400.** Whether a document is a form is exactly what the discovery
  endpoint is being asked, so failing there would make every ordinary PDF read as
  a broken server. A non-PDF is a different mistake and gets a different answer —
  and the smoke's first version conflated them, asserting the empty list against
  a text file and failing against a correct server. `doc_fill_form` refuses by
  **content type** before the engine is reached for the same reason: without that
  guard a text document comes back as `xref table: no header version available`,
  which names pdfcpu's internals rather than the caller's error. That is what the
  control showed.
- **FORM‑8 — every pdfcpu call carries `-c disable` and `--offline`.** Without
  the first it CREATES a configuration directory under the server's `HOME` on
  first use — which in the container is `/data`, the one declared volume, and
  under `--read-only` there is no writable home at all. The second is
  requirement 1's sandbox applied to a form: a PDF may name a remote resource,
  and nothing here needs the network. **Not `-q`**, which suppresses the stdout
  the JSON export is written to — the first run of the suite reported "the form
  export was not a JSON object" against a perfectly good PDF for exactly that
  reason.
- **FORM‑9 — the subprocess is BOUNDED, and `render-pdf`'s is not.** These parse
  somebody else's bytes on the request path, so a hostile or merely broken PDF
  must not hold a request thread for ever; `run-bounded` kills the process
  after 60 seconds and the refusal says so. It is exported because what matters
  is what ONE run DECIDES, not when it happens (`lease-tick!`'s rule). It is
  **not** retrofitted onto `render-pdf` in this slice: tectonic legitimately
  spends a minute fetching TeX packages on a cold cache, so a bound there needs
  its own number and its own thought. Named rather than quietly left.
- **The flattened output is a derived DOCUMENT**, `<key>.filled.pdf` through
  `derive!` — the source's visibility at `repo-put!`, THEN `repo-inherit!`, and a
  `repo_derivations` row, so "which form produced this, and from what" is a click
  (DWF‑4). Re-filling versions the same key rather than littering.

**Not built at this slice, by the issue's own numbering**: requirement 1 (an
HTML/CSS Chromium or WeasyPrint engine with paged media, PDF/A‑2b and a metadata
block), requirement 3 (DOCX → PDF through LibreOffice headless) and
requirement 6's byte-for-byte determinism flag. Requirement 4 — a template as a
versioned, access-controlled repository object with the derivation recorded — is
satisfied for this half by `derive!`, since the form being filled IS a repository
object. Requirement 5's "stored as a derived object with `application/pdf` and a
SHA‑256" is satisfied by the content-addressed store, which keys every blob by
its SHA‑256 already.

### What the controls found

Ten controls, nine on the engine and one through HTTP, and all ten bite:

- **A control that reports its own verdict agrees with you.** The harness reads
  the verdict off `raco test`'s summary line — `dump-leak-tests.rkt`'s lesson,
  where a file printing "the needle is in: …" as ordinary output made every
  control look like it bit.
- **A restore must invalidate the bytecode**, `plugins/*/compiled` included. The
  harness walks the tree and removes every `compiled/` directory before each run,
  because `shutil.copy2` puts the original file back looking OLDER than the `.zo`
  built from the mutated one (the Matrix slice paid for this).
- **The checkbox needed an appearance dictionary before anything could toggle
  it.** The first fixture had no `/AP`, and pdfcpu answered
  `corrupt form field: missing entry "AP"` — which is a property of the FORM, not
  of the request, so the message says which and the suite asserts the refusal
  against a fixture built deliberately without one.
- **The flatten assertion had to decompress to mean anything.** "No fields any
  more" passes against a version that simply threw the answers away, so the case
  also reads the filled text back out of the page content — through qpdf's own
  QDF mode, since the stream is compressed. Dropping that half because the
  literal is not findable in the raw bytes would have left the case passing
  against a flatten that lost the data.
- **The fixture is HAND-BUILT, not produced by pdfcpu's own `create`.** A form
  filled by the same program that wrote it proves only that the program agrees
  with itself, and the documents this tool exists for come out of Acrobat,
  LibreOffice and a government website. There are two copies of the fixture — one
  in Racket for the unit suite, one in Python for the smoke, which drives the
  platform over HTTP and has no Racket to hand. Two fixtures, not two rules: the
  rule they exercise has one home.

## HPDF — a branded, paged document out of HTML and CSS (issue #88 requirement 1)

Decided and built 26 Oct 2026, on top of FORM above. `domain/repo/htmlpdf.rkt`
(the engine, pure of the repository) plus two arguments on `doc_render` —
`engine` and `pdf_variant`. **No migration, no new environment variable, no new
route, no new permission.**

This is the requirement a downstream customer actually sees: an invoice, a
report or a certificate with a logo, a table whose cells wrap, running headers
and a page count. The LaTeX path (DWF‑6) renders text well and expresses none of
it.

- **HPDF‑1 — WeasyPrint, AND CHROMIUM DECLINED.** The issue offers either. Six
  measurements decided it, and the first two are the requirement itself:
  - **CSS paged media.** The acceptance criterion is "a logo, a wrapped table and
    Page X of Y". WeasyPrint implements `@page`, `position: running()` and
    `counter(page)`/`counter(pages)` natively — measured at 6 pages with a
    running header on every one and the same total in every footer. Chromium
    headless implements **none** of those: running headers come from
    `--header-template` over CDP, which is a second templating language that is
    not CSS, and `counter(pages)` has no equivalent at all. The issue's own
    acceptance criterion is therefore an argument for WeasyPrint.
  - **PDF/A.** `--pdf-variant pdf/a-2b`, and the output was put through
    **veraPDF 1.30.2: 144 rules passed, 0 failed**. Chromium cannot emit PDF/A,
    so requirement 1's flag would have been unimplementable.
  - **No scripting engine.** WeasyPrint runs no JavaScript at all. A template may
    be operator- or customer-authored, and this is a self-hosted, privacy-first
    platform: "the renderer *cannot* execute a template's script" is a stronger
    property than any sandbox configured around a browser that can.
  - **The sandbox is a FLAG, not a configuration.** `--allowed-protocols data`
    refuses `file:` and `http:` by name — measured, with the control: **without
    it, `file:///etc/hosts` really is fetched.**
  - **Determinism, already** (requirement 6 — see HPDF‑7).
  - **Closure, measured on both sides.** WeasyPrint's own closure is 1,506 MiB,
    which is not the number that matters: **82 of its 105 store paths are
    already in the image**, because pandoc, tectonic and poppler-utils brought
    cairo, pango, harfbuzz and the font stack along since DWF‑6. The MARGINAL
    cost is **173 MiB**, 116 MiB of which is the Python interpreter — about 10%
    of the image. Chromium is a browser, in an image whose size the container
    notes already guard twice, to render an invoice. **Measure the marginal
    closure, not the standalone one, before declining a dependency on size**:
    the standalone figure here is nine times the truth, and declining on it
    would have been declining on a number that means nothing.

  The deterministic-deps tenet's objection — that WeasyPrint is a Python
  application — is answered by **how it arrives**: a pinned nixpkgs derivation in
  `flake.lock`, exactly as pandoc and tectonic are. The tenet is about ad-hoc
  package managers and a shared `site-packages`, not about a program that happens
  to be written in Python. (`weasyprint` is not a top-level nixpkgs attribute, so
  `callPackage` cannot find it by name and `flake.nix` passes
  `pkgs.python3Packages.weasyprint` in at both call sites.)
- **HPDF‑2 — `latex` is NAMED, so the second engine is an addition.**
  `format: "pdf"` has meant pandoc → tectonic since DWF‑6; `RENDER-ENGINES` is a
  closed `("latex" "weasyprint")` with `latex` the default, so an existing caller
  keeps the renderer it has and nothing that works today changes. The binary is
  found with `find-executable-path` at CALL time — DWF‑6's and FORM‑2's rule — so
  a box without it boots and only an `engine: "weasyprint"` call is refused.
- **HPDF‑3 — the HTML engine REQUIRES an HTML template**, and that is the point
  rather than a gap. What it adds over the LaTeX path is the template's **own**
  CSS; a Markdown template carries none, and converting Markdown to HTML first
  would hand the caller a document whose paged media somebody else invented.
  Refused by name, naming the template's content type.
- **HPDF‑4 — a template reaches a repository document as `repo:<object id>`, and
  that is what makes the sandbox complete.** Requirement 1 asks for "images from
  repo objects by id". A scheme rather than a path, because every reference has
  to be resolvable **before** anything runs: each one is read **as the caller**
  (so `can?` decides whether a template may inline it) and rewritten to a `data:`
  URI, after which `data` is the only protocol the renderer is allowed to fetch.
  A template that could reach any object by id would be a way straight past the
  repository's own gate, since a template is data somebody else may have
  authored. Capped at 20 documents and 16 MiB, refused before the engine starts.
- **HPDF‑5 — THE EXIT CODE IS NOT THE VERDICT.** WeasyPrint logs a resource it
  could not load as an `ERROR` and **exits 0**, leaving a document with a hole
  where the logo was. A report that looks finished and is not is the failure this
  whole area exists to avoid, so the log is parsed and a refused or failed
  resource is a **refusal**, naming what a template may reach and never quoting
  what it wanted. This is the one thing about this engine that has to be handled
  rather than trusted, and the control for it is the second in the harness.
- **HPDF‑6 — ONE PDF variant, because one was validated.** WeasyPrint accepts a
  dozen; `PDF-VARIANTS` holds `pdf/a-2b` alone — the one requirement 1 names and
  the only one whose output was put through a validator. Offering a member nobody
  checked would be a conformance **claim** wearing a flag's clothes. A member is
  added by validating it.

  **And the limitation is measured, not guessed**: with a RASTER logo the same
  document fails exactly one veraPDF rule — ISO 19005‑2 clause 6.2.8 test 3,
  because WeasyPrint marks an image `/Interpolate true` and PDF/A forbids it.
  With an **SVG** logo it is compliant (144/0), because an SVG is drawn as paths.
  So the remedy is real and is stated in the tool's own description: for an
  archival document, use a vector logo. veraPDF is a ~300 MB Java validator and
  is deliberately **not** a dependency of the suite — what the test asserts is
  that the flag reached the engine and that an ordinary render does *not* claim
  PDF/A, which is the half that can regress.
- **HPDF‑7 — there is NO `deterministic` flag, because there is nothing to pin.**
  Requirement 6 asks for byte-identical re-renders behind a flag. WeasyPrint 69
  **embeds no creation date** and derives the document `/ID` from the content, so
  the same template and data already give byte-identical output — verified across
  two different `SOURCE_DATE_EPOCH` values, which is what establishes that there
  is no clock in it rather than merely that two runs a second apart agree. A flag
  would be a knob that did nothing, which is #113's shape, so the property is
  **asserted** instead and the absence of the flag is written down.
- **HPDF‑8 — the metadata block is the TEMPLATE's own.** WeasyPrint reads
  `<title>`, `<meta name="author">` and the rest, and `--custom-metadata` carries
  them into the PDF — so `{{title}}` in `<title>` composes with `doc_render`'s
  existing `data` argument and requirement 1's "metadata block (title, author,
  created)" needs no second argument. A `metadata` parameter would have been a
  third place to say the same thing, and would have had to be injected into the
  head by string surgery.
- **The output key is unchanged**: `<key>.form.pdf` through `derive!`, as
  `format: "pdf"` has always written. Same document, different engine — so
  "Processed by", the derivation row and a re-run's versioning all behave exactly
  as before.

**Requirement 3 (DOCX → PDF through LibreOffice headless) is NOT built, and the
reason is verifiability rather than effort.** `libreoffice` is unsupported on
this project's own development platform — `nix build` on `aarch64-darwin` fails
in the derivation's own `assert`, so the happy path cannot be exercised here at
all — and it is roughly a gigabyte, which for the OCI image is the trade the
container notes already declined twice (all tesseract languages for 63%, a slim
variant for 23%). Shipping a conversion whose success path nothing has run is
#119's shape exactly: a capability recorded as working on the strength of a
claim. When it is built it should follow the OCR plugin's pattern — opt-in, not
in the image, added through `extraPath` — and be verified on a Linux host.
**Requirement 6 is satisfied by HPDF‑7** without a flag; requirements 4 and 5
were already satisfied by `derive!` and the content-addressed store. So #88 has
one requirement outstanding.

### What the controls found

Eight controls on the engine and 29 assertions over HTTP:

- **Seven of the eight bit first time. The eighth did not, and the CONTROL was
  wrong rather than the test**: it injected the clock into an HTML **comment**,
  which is not rendered and therefore cannot reach the PDF. Moved into visible
  content, it fails the determinism case immediately. A control has to change
  what the renderer *draws*.
- **A `refute` for a plaintext against an inlined document PASSES VACUOUSLY**,
  and that is how the smoke's authorization case hid its own failure: the engine
  had read a private document and base64'd it into the HTML, the refusal quoted
  the `data:` URI — so the needle was right there, encoded, and the refutation
  was green. The block refutes the **encoded** form beside the plain one now.
- **THE RUNNER OF AN AUTHORIZATION FIXTURE MUST NOT BE THE OPERATOR.** That same
  case first made the private document bob's and ran the workflow as alice, who
  is the bootstrap operator — and an operator passes everything team-tier, so the
  document really was read, exactly as designed, and the case failed against
  correct code. The subject is alice's private document now and the run is bob's,
  a plain member.
- **Leaving two documents behind broke a visibility assertion 60 lines away.**
  §8's knowledge graph extracts a bounded batch per run, so the two leftover
  templates displaced the team-visible `inbox/auto/` scans out of it and carol
  stopped being able to see Acme. §5h paid for this exact lesson one slice
  earlier; the cleanup list now names every document the block creates.
- **`pdftotext` breaks a laid-out line wherever the renderer did**, so the first
  version of the acceptance case asserted a phrase the table had wrapped across
  two lines and failed against a perfectly good document. Whitespace is
  normalized before any text assertion.
- **The XMP packet is a compressed stream.** Asserting `pdfaid` over the raw
  bytes passes vacuously against a build that dropped the variant flag
  altogether; the case decompresses with qpdf's QDF mode, as the AcroForm suite
  does one directory along.

## OFFICE — a filled DOCX, converted to PDF (issue #88 requirement 3)

Decided and built 26 Oct 2026, which closes #88. `domain/repo/docxpdf.rkt` plus
one more member of `RENDER-ENGINES`. **No migration, no environment variable, no
route, no permission, and nothing added to the shipped image.**

`doc_render` has filled DOCX templates since slice 59 and has refused to turn one
into a PDF ever since, on the grounds that LibreOffice is not a dependency this
platform takes on. **That refusal is still the default.** What changes is that an
integrator who installed it can ask: `engine: "libreoffice"`.

- **OFFICE‑1 — OFF UNLESS INSTALLED, and NOT in the image.** `soffice` is found
  with `find-executable-path` at call time, so a box without it behaves exactly
  as it did before this slice. It is roughly a gigabyte, which for the OCI image
  is the trade `container.md` has already declined twice (all tesseract
  languages for 63%, a slim variant for 23%), so it belongs in `extraPath` as the
  OCR engine does — **and the refusal says so**, because "needs LibreOffice" with
  no indication of where it is meant to come from is how an integrator concludes
  the feature is broken. That is the OCR plugin's own rule.
- **OFFICE‑2 — THE SANDBOX IS NOT A FLAG HERE, AND THAT IS THE HONEST DIFFERENCE
  FROM THE HTML ENGINE.** Requirement 3 asks for "the same sandbox and timeout"
  as requirement 1. The timeout is the same (`run-bounded`, 180s for a whole
  office suite starting up). The sandbox cannot be: WeasyPrint takes
  `--allowed-protocols data` and refuses a `file:` or `http:` URL **by name**,
  and soffice has no equivalent — no command-line argument will give it one. So
  the constraint is applied to the **INPUT** instead: a template that DECLARES an
  external relationship — which is how Word stores a linked image or an OLE
  object — is refused by name, naming the target, before anything is converted.
  That is the shape of the HTML engine's guarantee, achieved the only way
  available here.

  **And it is not a proof, which is stated where somebody might otherwise trust
  it.** A field code (`INCLUDEPICTURE`) or a reference this check does not know
  about is not covered. Headless soffice does not update document links on load,
  but that is the ENGINE's behaviour and not something this platform enforces —
  which is the whole reason the engine is opt-in and absent from the image.
  Overclaiming here would be #119's shape: a protection recorded as working on
  the strength of a sentence.
- **OFFICE‑3 — the check matched by looking for `TargetMode="External"` anywhere
  in a relationship element, so it FAILS CLOSED.** A shape the expression does
  not understand is treated as external and refused, which is the safe
  direction; the opposite reading would convert a template whose links nobody had
  looked at. Read off the `.rels` parts of the package, which is where OOXML
  declares them.
- **OFFICE‑4 — THE INPUT IS CHECKED BEFORE THE BINARY IS LOOKED FOR.** A template
  that will not be converted whatever is installed should say so on every box —
  and that ordering is also what makes the refusal testable where LibreOffice
  **cannot** be installed, which is this project's own development platform. Six
  of the suite's eight cases and all but two of the smoke block's ten assertions
  therefore run everywhere.
- **OFFICE‑5 — a PRIVATE PROFILE PER CALL, and it is not optional.** Two
  independent reasons. The container's `HOME` is `/data`, the one declared
  volume, and under `--read-only` there is no writable home at all, while soffice
  insists on one. And two conversions sharing a profile collide: the second finds
  "another instance is already running", which is the classic way this tool fails
  under any concurrency whatsoever. `-env:UserInstallation=file://<temp>` per
  call fixes both, and the suite converts twice in succession to say so.
- **The exit code is not the verdict here either, for a DIFFERENT reason than the
  HTML engine's**: soffice exits 0 having converted nothing at all when it
  dislikes the input, printing its complaint and writing no output file. So the
  OUTPUT is what is checked — the file's existence and its `%PDF-` header — not
  the status.
- **The template is filled exactly as it always was**, and only the finished
  document is handed to the converter: the same order `render-pdf` uses for
  pandoc, and what keeps the DOCX template language one implementation.
  `<key>.form.pdf` through `derive!`, as every other PDF.

### How it was verified, and why that mattered

**LibreOffice is unsupported on `aarch64-darwin`** — `nix build` fails inside the
derivation's own `assert` — so the conversion could not be exercised on the
development box at all. The previous slice recorded requirement 3 as unbuilt for
exactly that reason. It is built now because it was **verified on `red5buntu`**,
the x86_64 Linux test lab box ([[red5buntu-test-lab]]): 658 MiB of substitutable
closure, then the unit suite with `soffice` on PATH (8 cases, up from 7 — the
conversion case replaces the missing-binary one) and the whole
`doc-pipeline-smoke.sh` including §5k's conversion branch. The PDF's text was
read back with `pdftotext` and contains the template's filled content, because a
converter that wrote a blank page of the right size would pass every other
assertion.

**CI does not install LibreOffice and should not**, so §5k's conversion branch is
skipped there and the refusal branch runs instead. That is a gap stated rather
than papered over: this engine's happy path is covered by a hand-run on a Linux
host, and the suite says which case it is skipping and why.

### What the controls found

Six controls, all biting, and one of them is about the controls themselves:

- **A CONTROL'S PATCH THAT DOES NOT APPLY IS NOT A CONTROL.** The harness
  reported "patch did not apply" for the `TargetMode` test because the Racket
  regexp literal was mis-escaped in the harness — printed plainly, and easy to
  read past as if the control had passed. Re-run with the right literal it fails
  two cases. A harness has to say the difference between "did not bite" and "did
  not run".
- **THREE SMOKE ASSERTIONS PASSED FOR THE WRONG REASON, and the one after them
  is what showed it.** The strict template renderer runs BEFORE any engine is
  reached, so the fixture's `{{customer}}` — a placeholder the reused spec's
  `data` does not bind — failed the step with "template references {{customer}}
  but the data has no customer", and "a template with an external reference is
  refused" was green because the run had indeed errored. Assert the REASON beside
  the status, every time; the fixture binds the names the spec actually passes.
- **`assert` IS A GREP AND THE RUN JSON ESCAPES ITS QUOTES**, so a needle
  containing a double quote can never match: `engine "libreoffice"` is
  `engine \"libreoffice\"` in the body. Assert the prose around it.

## QUEUE — the feed work queue, and a proposal that does not act (issue #114 slices 5–6)

Decided and built 27 Oct 2026, which closes the last two slices of #114's own
plan. `plugins/feeds/` — one table, three tools, two workflows, two routes and a
screen — plus ONE platform change: `derive!` moved out of `doc-tools.rkt` into
`repo.rkt` as `repo-derive!`, because this plugin is its second asker.

**A PLUGIN, NOT A CORE CONSOLE TAB**, and that was the owner's answer to #114
question 2 on 27 Oct. FEED‑8 had assumed as much, so the design did not move;
what the answer settles is that a plugin owns its own tables, routes and screens
today — plugin migrations (#121), plugin routes (slice 63), a bundle page (#20,
#43) — while a tab inside the core console is a platform change a plugin cannot
make, and is now a separate decision nobody waits on.

- **QUEUE‑1 — a TYPED TABLE, because the queue's question is not one
  `repo-list` can answer.** Ordering by priority, comparing a due date and
  filtering by status: LAY‑4 attribute values are strings, there is no JSON SQL
  in both dialects, and a core implementation would mean typed storage plus a
  dialect-specific query — a schema decision with the `meta LIKE` trap attached.
  `x_feeds_items` keeps typed columns and the DOCUMENTS stay the source of truth.
  The `x_feeds_` prefix is not decoration: the loader enforces it on a plugin's
  DDL, which is what makes "a list of SQL strings" safe to accept as data.
- **QUEUE‑2 — IT IS AN INDEX, NOT A POLICY.** The priority, the due date and the
  skills are ARGUMENTS the customer's own triage passes, in a workflow, from
  whatever their labels mean. A plugin that derived a priority from the word
  "critical" in a GitHub label would be guessing at somebody else's conventions
  and would be **wrong quietly** — and the github adapter writes `feed_labels`
  as the team's own string precisely so nothing downstream has to interpret it.
- **QUEUE‑3 — THE DOCUMENT IS AUTHORIZED, NOT THE ROW.** A queue row is a
  pointer and confers nothing: every listing re-reads each object under `can?`,
  after the SQL window, as `repo-list` does — with CLS‑27's consequence, that a
  page can contribute fewer rows than it selected and the count is "what you may
  read" rather than "what is there". `repo-get` raises on a refusal and answers
  `#f` for a miss, collapsed here into one answer in one place, as the knowledge
  graph and the worker's document read both do.
- **QUEUE‑4 — THE ORDER IS THE FEATURE, and the NULL due date is the half that
  would have broken silently.** `priority DESC`, then the soonest due date, then
  oldest-known-first. `due_epoch` is NULL for an item with no deadline and **the
  two dialects sort NULLs opposite ways under ASC**, so it is `COALESCE`d to a
  far horizon: without that, an item with no deadline comes first on one engine
  and last on the other. The route also REPORTS the ordering, because "the first
  actionable task" is a promise about the first element and a reader cannot see a
  sort.
- **QUEUE‑5 — the priority range is CLOSED (0–100) and a value outside it is
  clamped, not refused.** An open-ended number invites one workflow to pass 10
  and another 1,000,000, after which the ranking depends on who wrote the
  workflow rather than on what is urgent. Clamped rather than refused because
  this is triage: a caller who passes 1,000 means "most urgent", and failing
  their run over it would be pedantry. A non-number is the default, never an
  error.
- **QUEUE‑6 — skills are stored DELIMITED (`,racket,ops,`), and that is what
  makes a skill filter mean one skill.** `LIKE '%racket%'` over a bare list
  matches `racketeering`; the leading and trailing commas are the fix. A JSON
  array would have been the obvious shape and there is no JSON SQL in both
  dialects. **The wildcards are what make it a LIKE at all** — the first version
  built `,racket,` with no `%`, which is an equality test, so every skill filter
  answered nothing. The unit case found it.
- **QUEUE‑7 — the status vocabulary is CLOSED**, and each member earned its place
  by behaving differently: `open` is offered, `claimed` is somebody's, and `done`
  and `dropped` leave the actionable set, which is what makes the default listing
  useful. Refused on the way in and on the way out.
- **QUEUE‑8 — a status change is scoped to the ROW's own team as well as to the
  document.** An object id is instance-global, so without the team clause a
  caller could name another company's row — `org-team-resolve`'s lesson. This is
  defence in depth: no code path here produces a row whose team disagrees with a
  reader's, which is exactly why it needed a test of its own (below).
- **QUEUE‑9 — `derive!` IS NOW `repo-derive!`, with two askers.** DWF‑4's order —
  the source's visibility at the `repo-put!`, and only THEN `repo-inherit!` for
  the grants and the derivation row — lived in `doc-tools.rkt` behind a comment
  saying "do not reorder that". A second asker makes a comment insufficient, so
  the rule moved into `repo.rkt` and `derive!` delegates. The same consolidation
  `repo-fields-declare!`, `bbox-problem` and `executor-can-run?` each got.

### Slice 6: a proposal is a document, and nothing acts on it

FEED‑10, confirmed by the owner as the answer to #114 question 3 rather than
overridden. Three things about the shape:

- **It writes a DOCUMENT, not a row.** `<key>.proposal.md` derived from the item
  means "Processed by" finds it, the derivation row says which item it is about,
  and it inherits the item's visibility from its first byte. A proposal is the
  kind of thing somebody reads, disagrees with and keeps.
- **The document carries a standing note that nothing was carried out**, because
  the person reading it in a month has no other way to know. The tool's result
  carries `acted: false` for the same reason — a reader should not have to infer
  it from the absence of something.
- **EVERY VERDICT ENDS THE RUN**, because v1 has nothing that acts. There is no
  acting tool, and nothing prevented one before this slice — `register-tool!`
  takes any handler — so the requirement was never to build the capability but to
  govern it. When an acting tool exists it goes on the `approve` branch and
  nowhere else, and a unit case asserts that branch is `null` today so the day
  somebody adds one is the day it is noticed. Four eyes is OFF: the subject is
  model-produced, so LAY‑3's NULL-author case applies and a team of one can still
  finish the run.

### What the controls found

Ten controls. Eight bit first time; the two that did not were both real, and the
second is the more interesting:

- **THE TEAM CLAUSE ON THE WRITE WAS UNTESTED WHILE LOOKING TESTED.** The case
  "another team's queue is not this team's" passes with the clause removed,
  because `can?` refuses the caller the DOCUMENT before the SQL is reached. So
  QUEUE‑8's guard had no test — #113's shape inside a test file. It has its own
  case now, on a row built by hand, because no code path produces that state:
  that is what defence in depth means, and a guard with no reachable caller is
  decoration until something exercises it.
- **THE VISIBILITY CASE ASSERTS AN END STATE ONLY, AND SAYS SO NOW.** Patching
  `repo-derive!` to put the proposal at `team` visibility leaves the case green,
  because `repo-inherit!` copies the source's visibility afterwards and corrects
  it. The put's `#:visibility` closes the WINDOW between the two statements, and
  no test at that level can observe a window. Stated in the test rather than left
  for a reader to assume the assertion covers it — the alternative was a stronger
  claim than the test supports.
- **`raco make` EXITING 0 DID NOT MEAN THE PLUGIN LOADED**, the documented trap,
  and #48's plugin-failure surface is what made it loud: the first boot printed
  `plugin: feeds: FAILED — invalid workflow spec: step 'decide': checklist[0]:
  needs a non-empty 'label'`. A checklist item's field is `label`, not `title`.
  One line in sixty before #48; a named failure now, and the reason that slice
  was worth building.

## ENVN — the operator's own names (issue #128 job 2)

Decided and built 27 Oct 2026. `tmach-env` in `config.rkt`, every read in the
tree moved onto it, and a gate that makes a missed one impossible. **No
migration, no new variable, and nothing anybody has deployed stops working.**

Job 1 renamed the PROSE and deliberately left the variables alone. The reason
stands: a variable is a contract with every deployment that already exists — a
compose file, a systemd unit, a Kubernetes secret, somebody's shell history — and
a flag day on 94 of them would be an outage distributed across every installation
at a time of our choosing rather than theirs.

- **ENVN‑1 — A DUAL READ, WITH NO FLAG DAY AND NO DEADLINE.** `TMACH_<name>` is
  the name; the old spelling still answers; the new name wins when both are set;
  an empty value is absent under either, so setting the new one to `""` falls
  through rather than masking the old. There is deliberately no horizon after
  which the old names stop: a deprecation with a date is a promise to break
  somebody later, and the cost of keeping two reads is one `cond` arm.
- **ENVN‑2 — THE SUFFIX IS THE ARGUMENT, and that is the whole design.**
  `(tmach-env "PORT")`, never `(tmach-env "TMACH_PORT")`. With the full name at
  the call site a reader cannot tell a dual read from a single one, and — far
  worse — **a missed site goes on working**, because the old name is the
  fallback. It surfaces only for the one operator who sets the new name and
  nothing else, which is the worst possible audience for it. Composing the name
  in exactly one place is what turns that from unlikely into impossible.
- **ENVN‑3 — THE GATE FORBIDS THE SPELLING, not a list of helpers.** No module
  mentions an operator variable's full old name on a non-comment line (comment
  lines may explain the fallback; `config.rkt` and the test that proves it are
  the two named exceptions). **This rule replaced two narrower ones, and the
  narrowing was defeated both times** — see below.
- **ENVN‑4 — the numeric helpers take the VALUE, not the name.** `pos-env`,
  `env-int` and `env-num` are now `(pos-env (tmach-env "OCR_TIMEOUT") 20)`. So
  every operator variable is spelled exactly ONCE in the Racket tree, and neither
  gate has to know which helpers forward to the accessor — a gate that enumerated
  them would agree with whoever last added one.
- **ENVN‑5 — the boot line lists the old names actually read**, once, in the
  shape the plugin failures already use. An operator migrating a compose file
  gets the list; one who has finished sees nothing. It is a NOTE and not a
  WARNING because nothing is wrong: the old names are supported, and shouting
  about a supported configuration is how an operator learns to ignore the boot
  output. A SET rather than a counter — a variable read on every request would
  dominate a tally, and what the reader wants is the list.
- **ENVN‑6 — the harnesses set the NEW names, and one test proves the old ones.**
  A suite that set only the old names would exercise the fallback on every run
  and the primary read never, which is how a dual read rots into a single one
  pointing the wrong way. So all 104 test writes and 380 harness, Nix, compose
  and manifest occurrences were flipped, and `test/env-names-tests.rkt` keeps the
  old spelling deliberately — it is the only file that may.
- **ENVN‑7 — an `unset` clears BOTH spellings.** The harnesses unset
  `PLUGINS`/`PLUGINS_LINKS` because a developer exports them in their own shell;
  with a fallback in place, unsetting only the new name would let the old one
  leak a downstream plugin into every harness. A regression this change would
  have INTRODUCED, caught by reading the diff rather than by a test.
- **ENVN‑8 — the page documents the current spelling only.** Listing all 94
  variables twice would double the page an operator reads in order to say
  nothing; the compatibility window is stated once, at the top, and the gate's
  job is that each variable's CURRENT name is documented.
- **ENVN‑9 — eight copies of the same helper became one.** `env*` in
  `server/kit.rkt` plus seven local `env` definitions all read a variable and
  treated `""` as absent. That property is load-bearing beyond tidiness: CI's
  sqlite leg sets `DATABASE_URL` to the empty string, and #123 records a test
  that passed everywhere except there because of it.

**Not in this change, each for its own reason.** The `X-Telemachus-*` request
headers (a second dual-read question, on a surface where the *client* chooses the
spelling), the `cli/telemachus-*` command names (operator muscle memory and every
systemd unit's `ExecStart`), and `data/telemachus.db` (a path inside a volume, so
renaming it is a migration rather than an alias). Four surfaces half-done would
have been worse than one verified. **Job 3 is written** — the three families that
must never be renamed are now stated in `docs/ops/configuration.md` where an
operator will meet them: `define-sealed-column`'s AAD context strings,
`CHAIN-VERSION` and `telemachus.digest.v1`, because changing any of them stops
existing rows opening and existing exports verifying.

**ENVN‑10 — the PROSE job, and why it was its own slice (#128).** Job 1 renamed
the displayed name, job 2 renamed the variables in CODE, and nothing renamed the
documents an operator FOLLOWS. For a week `docs/ops/configuration.md` was a
gated page listing 94 `TMACH_*` rows while six runbooks beside it named 96
`TELEMACHUS_*` variables — and that asymmetry is worse than a stale row, because
the page nobody can break was the reference and the pages anybody could break
were the instructions. 96 names across `docs/ops/*.md` and
`docs/deploy-tailnet.md`, verified name by name against the reference page
BEFORE the swap: all 28 distinct names already had a `TMACH_` row, so the
rename could not invent a variable that does not exist.

**ENVN‑11 — what operator prose may say, gated.** A legacy name in a document
somebody follows is refused by `scripts/check-config-reference.sh`, in the same
run and therefore with no change to `ci.yml` (the `telemachus-docs check
--locale` rule: derive it rather than make CI remember). What is refused is a
name an operator could **copy into a compose file**, so `TELEMACHUS_BIND` fails
and the glob `TELEMACHUS_*` and the placeholder `TELEMACHUS_<name>` do not —
they are ways of TALKING about the family, which the compatibility section has
to do to be about it. **The gate found its own author**: the first version of
that section used `TELEMACHUS_BIND` as its worked example. It fails in BOTH
directions, or the allowance rots into a list of excuses — the second half
asserts the compatibility section still EXISTS, because deleting it would leave
a gate enforcing silence about a fallback every existing deployment depends on.
The READMEs and the screenshot catalogs are in scope, and the catalogs are where
the message points: the feature-tour region is generated, so a name fixed in
`README.md` by hand is reverted by the next refresh.

**Deliberately NOT renamed, and stated rather than discovered.** The design
documents under `docs/design/` keep the spelling they were written with: a
decision recorded in August named the variable that existed in August, and
rewriting the record would make it say something that was not true when it was
made — the names still work, so nothing a reader does from them fails. The
**e-book** was left for its own slice, not out of reluctance, and that slice is
ENVN‑12 below.

**ENVN‑12 — the e-book, the integrator's guide, and these notes (#128 job 3).**
The last three documents that still TAUGHT the old spelling. Fourteen names
across three chapters in two languages, every one verified against a `TMACH_`
row in `configuration.md` before the swap, as ENVN‑10 did.

- **A chapter edit is a translation edit.** The source-hash rule makes every
  translated copy of an edited chapter stale, so the English and the Japanese
  move together or the next build reports three stale chapters. `build.sh ja
  --record` is a WHOLE-BOOK operation — it restamped all nineteen — and the only
  thing that stops it silently blessing somebody else's stale translation is that
  the other sixteen were already in step. That is checked in the diff, not
  assumed: exactly three stamps changed.
- **The book gained a sentence it never had.** It is the narrative an operator
  reads front to back, and nothing in it said the old names still answer — so a
  reader with a working compose file had no way to learn from the book that it
  keeps working. One paragraph in chapter 02, in both languages, pointing at
  `configuration.md` for the list.
- **The integrator's guide went with them**, because it is the document a
  DOWNSTREAM team follows — the same class as a runbook, and the front door for
  everybody building on this platform.
- **`CLAUDE.md` was swapped by hand where a blanket `sed` would have lied.**
  Ninety-three of its ninety-six mentions are the live name of a variable and
  became `TMACH_*`; five are statements ABOUT the old spelling — the dual-read
  rule itself, the gate's allowance for the glob and the placeholder, and the two
  pieces of narrative naming `TELEMACHUS_BIND` and `TELEMACHUS_HOME` as things a
  draft and a stale manifest once said. A prefix substitution would have rewritten
  the compatibility rule into a statement that `TMACH_*` falls back to `TMACH_*`,
  which is not merely wrong but unfalsifiable by any gate, because the gate is
  looking for the old prefix and there would be none left to find.
- **The gate was widened in the same change, and controlled in all four places.**
  `scripts/check-config-reference.sh` now covers the book's chapter sources in
  both languages, `TRANSLATING.md` and the integrator's guide. ENVN‑11's rule is
  unchanged and is what makes that safe: the compatibility paragraph's
  `TELEMACHUS_*` is a glob, not a name anybody can set, so the gate ignores it.
  Each new entry was positive-controlled by planting a legacy name and checking
  the refusal NAMES THAT FILE — a gate that fails without saying where is a gate
  somebody disables.

**What is left of #128 is a release decision, not a code change**: when the
`TELEMACHUS_*` aliases are dropped. That has no deadline by ENVN‑1 and is tracked
on #204, so the rebrand closes on the documents.


### What the gate found, three times

Every narrowing chosen for convenience was defeated, and the fix each time was to
make the rule LESS clever:

- **IT FOLLOWED A SYMLINK INTO THE NIX STORE.** `nix build` leaves a `result`
  symlink in the implementation directory; `find-files` follows it; the gate read
  a PACKAGED COPY OF THE SOURCE from before the change and duly reported
  offenders that were already fixed. `grep` over the repository said zero, the
  gate said twelve. `#:follow-links? #f`, and the root anchored with
  `define-runtime-path` rather than `current-directory` — this file's own
  "anchor at definition, never at use" rule, which a blob root resolving into the
  store had already paid for once.
- **IT ENUMERATED THE HELPERS IT KNEW ABOUT.** The first rule matched `getenv`,
  `env` and `env*`; three more (`pos-env`, `env-int`, `env-num`) read a full
  literal and the sweep missed all three. What found it was the OTHER gate:
  `scripts/check-config-reference.sh` reported six variables as documented but
  read nowhere, by name. Two gates checking adjacent properties caught what
  neither would alone.
- **IT MATCHED FULLY-QUOTED LITERALS ONLY.** Three suites then failed on
  operator-facing MESSAGES that still named the old variable inside a longer
  format string — `"…(TELEMACHUS_MAX_JOB_SECONDS=~a)"`. A message naming a
  variable is the text an operator acts on, so it must name the current
  spelling; 64 lines across 30 files were renamed and the pattern broadened.

## EMB — an embedding wire, a label store, and a meter (issue #163)

Split out of #87 requirement 2c, which asked for a nearest-label classification
backend and was told no four times over: this build had no embedding wire, no
store, no meter and no capability. `classify.rkt` refused the backend **by
name** rather than falling through, so the gap was visible from the API for as
long as it existed — which is what made this an issue somebody could pick up
rather than a silent absence.

| | Question | Decision | Why |
|---|---|---|---|
| **EMB‑1** | Where the request goes | **Its own endpoint and its own model** (`TMACH_EMBED_URL` / `_MODEL` / `_KEY`) · vs deriving `/v1/embeddings` from `TMACH_MODEL_URL` | An embedding model is a DIFFERENT model — `nomic-embed-text`, `bge-m3`, never a chat model — so the NAME cannot be shared, and once the name is separate the URL may as well be. Deriving it assumes the two live on one server AND would send the chat model's name to an endpoint that cannot use it. |
| **EMB‑2** | One seam or two | **The POLICY is shared; the body is not** | The egress refusal, the content-logging policy, the request log and the transport error classification ask the same question of an embedding as of a chat, and RED‑16 is why that is a real risk: `model-exchange`'s own header called itself "the ONE place a model request leaves this process" while two other paths had their own. An embedding sends document text to a backend; it must not become the fourth. What is NOT shared is the body, the response shape, and what a token means. |
| **EMB‑3** | The LAY‑9 capability #163 asked for | **Configuration IS the capability** · vs an `embeddings` entry in the capability document | That request was premised on embeddings riding the chat endpoint. With an endpoint of their own there is nothing for a declaration to add, and a declared capability that can disagree with whether the endpoint is set is a second answer to one question (`executor-can-run?`'s drift). An unset endpoint is refused BY NAME before anything leaves — the property the capability was wanted for. The day an embedding is ROUTED, that executor's document is where it belongs. |
| **EMB‑4** | A named executor | **Refused by name** · vs serving it from the instance endpoint | An executor's document declares one endpoint and it is its chat endpoint. Serving the call elsewhere while the caller believes it went to the executor is the misroute-that-lies this module refuses everywhere else. Model ROLES point at executors, so this is reachable the moment somebody sets the utility role — a refusal, not an impossibility. |
| **EMB‑5** | What the request log says | **A new `operation` column** (migration 0063, closed vocabulary, enforced) · vs a fourth `transport` value | push/stream/pull answer "by what ROUTE", which is a different question — and `stream` is already a push. `tokens_used` means a different unit on an embed row (an INPUT count, no output), so a mixed log with no way to tell them apart is two units in one column. NULLABLE with no backfill: every row written before 0063 was a chat and `COALESCE(operation,'chat')` says so at the read, rather than a backfill claiming the rows had been classified when nothing classified them (migration 0045's lesson). |
| **EMB‑6** | The meter | **`ai.embeddings.total`, its own dimension** · vs `ai.tokens.total` | JUDGE‑10's answer to JUDGE‑10's shape. An embedding has an input count and no output at all; folding it into the completion budget would also make a nearest-label classification silently eat the budget the `llm` backend needs — the one it exists to avoid spending. In `QUOTA-HOLD-DIMS` for JUDGE‑10's reason, and with **no default limit**, so on an instance nobody configured it holds nothing. `ai.requests` is charged too: the dimension counts calls to a model and this is one. |
| **EMB‑7** | What the store holds | **Label vectors ONLY, and saying so is the design** · vs document vectors too | #163's first open question. A vector per label is a handful of arrays that change when an operator edits the label set and that nothing has to search, because classification compares against every one. A vector per DOCUMENT is a different subsystem wearing the same words: no vector type in either dialect, no index that would make a nearest neighbour anything but a full scan, and no JSON SQL in the tree. Picking the cheap home now decides that badly and expensively, because by then something depends on it. So this store **cannot** serve document similarity, which forces semantic search to answer the storage question rather than inherit an answer nobody made. |
| **EMB‑8** | When a vector is stale | **A model change invalidates EVERYTHING; a label edit invalidates ONE** | Vectors from two checkpoints are not comparable — RED‑18's discontinuity, which `digest_key_id` records for the request log — and mixing them does not raise: it produces a cosine between two unrelated coordinate systems, which is a number, and therefore a confident classification nobody can tell is nonsense. So the model name is stored BESIDE the vectors and a mismatch discards the document whole. The per-label `hash` is the sha1 of the text it was made from, the rule `locales/ja.json` and the caption catalogs already live by. |
| **EMB‑9** | Sealing the store | **Not sealed** · vs under `TMACH_ENCRYPT_CONTENT`, as #163 guessed | That switch seals content the platform retains BY ITSELF. A label vector is a function of the label's `name`, `description` and `examples` — operator-authored configuration, which arrives as a tool argument, is stored unsealed in the workflow spec that passes it, and is echoed back by the evaluation harness. Sealing a function of that text two keys away from the text protects nothing, and would put a column `rewrap` does not walk into the schema, which is how a sealed value becomes silently unrotatable. A DOCUMENT vector would be the opposite answer. |
| **EMB‑10** | What `confidence` means | **The MARGIN to the runner-up, scaled** · vs the top similarity | The decision in the backend. Cosine against a label is uncalibrated: ordinary English documents score 0.6–0.9 against everything, so reporting the best similarity would report 0.82 for a document that matched nothing in particular and would park nothing for review. The GAP carries the information. A document equally close to two labels scores ~0, which is exactly the case CLS‑13's review threshold exists to catch. With one label there is no runner-up and so no margin: it DECLINES rather than reporting 1.0 for a comparison never made. |
| **EMB‑11** | The default chain | **`rules`, `llm` — unchanged** · vs inserting `embed` | KNOWN and DEFAULT are two lists, and conflating them is a behaviour change wearing a one-word diff: an embedding needs an endpoint the ordinary instance has not configured, so defaulting to it would make every existing `doc_classify` call on every existing instance try to embed. Naming it is how you ask. In the ORDER it sits between the two, which is where it belongs once named — rules are free and certain (CLS‑1), and an embedding is one short request against a small model where `llm` is a full generation against a large one. |

**Does anything else want embeddings first?** #163's fourth question, answered:
**no, and search is why.** Semantic search is the obvious next caller and it
needs DOCUMENT vectors, which EMB‑7 deliberately does not provide — so it cannot
quietly inherit this store's shape, and it will have to decide the question this
slice declined. The classifier was the right first caller precisely because it
needs only label vectors.

**What it cost the classifier**, as #163 predicted: one arm in the ordered chain,
the label set embedded once and cached, cosine against each label, and the same
`confidence` contract the other two answer with. The evaluation harness (#87
req 6) measures it per backend and in the chain with **no change at all**.

## VEC — where a document vector lives (issue #189, evaluated 28 Oct 2026)

#189 asked for a story and an evaluation, not a build. The full write-up, with
every measurement behind these rows, is **`docs/design/vector-store.md`**; this
is the decision table. **Nothing here is built** — the build plan is at the end
of that document, and the issue stays open on it.

The question exists because EMB‑7 refused to answer it: `embedstore.rkt` holds
label vectors and says in its own header that a vector per DOCUMENT is a
different subsystem wearing the same words, so that the next asker would have to
decide rather than inherit. This is that decision.

| | Question | Decision | Why |
|---|---|---|---|
| **VEC‑1** | What a vector is OF | **A CHUNK, with character offsets into `repo_text.content`** · vs a document | A vector averaged over fifty pages is a vector of nothing, and #183's own requirement is that an answer CITES — which needs a passage, not a file. LAY‑5 already has the vocabulary for "this text came from here" (`start`/`end` into the text the same extraction returned), so a chunk's offsets are the existing shape rather than a second one. |
| **VEC‑2** | Where they live | **A typed table, ONE ROW PER CHUNK** · vs pages of many vectors · vs a settings blob · vs LAY‑4 attributes | Measured: 32 vectors per row moves 10,000 vectors from 74/85 ms to 56/62 ms and the file from 39.2 to 29.3 MiB — 20% of the time, 25% of the disk, for a row that can no longer be deleted, superseded or cited on its own. The curve is flat past 32, so the ceiling on that trade is known and it is small. A settings blob is EMB‑7's shape and does not scale; LAY‑4 values are strings and there is no JSON SQL in either dialect (QUEUE‑1's finding). |
| **VEC‑3** | Sealing | **Sealed under `TMACH_ENCRYPT_CONTENT`, as BYTES, and LISTED in `CONTENT-SECRETS`** · vs unsealed · vs sealed always | A document vector is a function of `repo_text.content`, which that switch seals — and embedding inversion recovers much of the source text, so an unsealed vector column beside a sealed `repo_text` would undo #83 on exactly the instance that asked for it (#119's shape). EMB‑9 predicted this answer in writing. **As bytes** because `secret-wrap` is a STRING API: through it the same 29.3 MiB costs **2,240 ms and 52.1 MiB** against **44 ms and 29.3 MiB** for `aes-256-gcm-decrypt` on raw bytes — 51× and 1.8×. **Listed** for the `job_schedules.payload` reason: a vector store outlives key rotations, and a sealed column `rewrap` does not walk is silently unrotatable. |
| **VEC‑4** | An ANN index | **None, and a stated threshold** · vs pgvector + sqlite-vec | The caller that is waiting — #183's whole documentation corpus — is **1,159 chunks**, which the scan answers in **8 ms**. pgvector's HNSW really is 500× at 100,000 (1.7 ms vs 868 ms) and costs **272 s to build**, an index as large as the table, and maintenance on every write. Revisit at **50,000 chunks for one team**, where the scan crosses half a second — a number, not "if it gets slow", and the store reports its own per-team count so an operator can see it coming. |
| **VEC‑5** | sqlite-vec | **UNREACHABLE from this platform, and that is measured** | `db/sqlite3` exports `sqlite3-connect` and `sqlite3-available?` and no extension-loading entry point; `select load_extension(…)` through `db` answers **"not authorized"**, which is SQLite's reply when `sqlite3_enable_load_extension` was never called. The identical SQLite 3.53.3 in the same closure loads `vec0` from the CLI and answers `vec_version()`. So the limit is Racket's binding, and reaching it means our own FFI to libsqlite3 beside `db`'s, with its own connection to the same file, outside `db-kit/portable` and outside the pool, on the request path. |
| **VEC‑6** | Therefore pgvector | **Declined, because it cannot be the only path** | SQLite gets no index (VEC‑5) and a sealed instance gets none either, since the engine must read the vector to compare it. So an extension does not REPLACE the scan — it adds a second retrieval path above one that has to exist anyway, on the dialect whose deployments are largest. Availability was not the objection and my first framing of it was wrong by three orders of magnitude: nixpkgs has pgvector 0.8.7 for pg 15–18 at **685 KiB** and sqlite-vec 0.1.9 at a **343 KiB** closure. |
| **VEC‑7** | An external store | **Declined** (Qdrant, Weaviate, Chroma, a managed pgvector) | A second network service that nothing else in the deployment needs, for a workload measured in milliseconds — the trade `container.md` already declines twice, for LibreOffice and for MinIO. And it puts document-derived vectors, which invert back towards the text, on a wire this platform does not control, in a product whose first adjective is self-hosted. |
| **VEC‑8** | Staleness | **The model name travels WITH the vectors; a mismatch discards them whole** | EMB‑8 unchanged and for its reason: vectors from two checkpoints are not comparable and mixing them does not raise — it yields a cosine between unrelated coordinate systems, which is a number, and therefore a confident answer nobody can tell is nonsense. A new version of a document supersedes its chunks wholesale, as `repo_text` already does. |
| **VEC‑9** | Authorization | **Team-scoped in SQL, then `can?` per row AFTER the scan** | `search.rkt`'s rule, and CLS‑27's consequence: a window bounded in SQL and a filter applied per row, so a hit confers nothing and the count is "what you may read". A nearest-neighbour query must not become the one read that skips the gate. |
| **VEC‑10** | The stored width | **float32 at the model's native dimension** · vs int8 · vs Matryoshka truncation | Both are real levers and both are measured — at 10,000 vectors, 768‑dim float32 scans in 122 ms, int8 in 72 ms, 256‑dim float32 in 40 ms, 256‑dim int8 in 21 ms, with storage falling 4× and 12× — and neither is adopted, because the cost is RECALL and recall cannot be measured without a live embedding endpoint. Naming them with their savings is the useful half; picking one on arithmetic alone would be the EMBED‑MARGIN‑SCALE mistake, a constant nobody calibrated. |

**Two things worth taking away from this even if none of it is built:**

**`cosine` is 8× slower than a document scan can afford**, and that is not a
defect — over boxed `vector`s it takes 1,272 ms at 100,000 comparisons where an
`flvector` dot product takes 150 ms, because every component is a heap-allocated
flonum and the loop recomputes both norms every time. For EMB‑7's handful of
labels that is exactly right. For a scan it would be the whole cost, so the scan
needs its own primitive rather than a faster `cosine`.

**The sealing layer has never been asked to move anything large, and the string
API is why it would look slow.** The biggest sealed value in the tree today is
200 KB of extracted text, 18 ms through `secret-wrap`. At 29 MiB the same path is
2.24 s — base64 in, UTF‑8 out, UTF‑8 in, base64 out — while the cipher itself
runs at about 665 MiB/s. The first measurement of this slice said "sealing makes
a 10,000-vector scan take 2.3 seconds" and it was true and it was about the
wrong thing; batching it into pages did not help, which is what said so.

## FLEETD — the fleet as the DEFAULT for an unrouted chat (issue #175)

#173 made `@fleet` reachable and deliberately did not flip the default, on the
grounds that an outright flip changes where every existing single-box instance
runs its chat. #175 is the owner's answer to the question that left open —
*"yes, it should be default"* — and the shape below is what makes that safe
rather than a behaviour change nobody asked for.

**The flip is a FALL-BACK, not a redirection.** On an instance with no pull
workers nothing matches, `fleet-default-executor` answers `#f`, and the call
runs on the local model exactly where it ran before. So behaviour changes only
on a deployment that HAS a fleet, which is precisely where #175 wants it to.

| | Question | Decision | Why |
|---|---|---|---|
| **FLEETD‑1** | Should the default flip | **Yes, as a fall-back: `@fleet` when a live worker can take an `infer.chat`, else the local model** · vs an outright default · vs opt-in per team | An outright default makes `fleet-can-run?` refuse on every instance with no workers, which is most of them, and chat stops working. A fall-back is indistinguishable from today's behaviour wherever there is no fleet, so there is no instance for which this is a regression — and on a multi-GPU deployment the box that should be doing the least stops being the one that answers every chat. |
| **FLEETD‑2** | Where the default is resolved | **In the ENDPOINT, under two names (`ex-asked` / `ex`)** · vs inside `run-chat` | `run-chat` has ten production callers and the agent is not one of them only because `model-exchange` is. Putting the default there would flip the document tools, the knowledge graph, the beta judge and the localization drafter at once — and those already have a routing mechanism of their own in model ROLES (KG‑7/LOC‑5), which an operator sets once. It would also reach the AGENT's own `run-chat` siblings, where a pull executor is refused BY NAME because the wire carries no tool calls, so an agent run that works today would start failing. The person's chat is the surface that had no way to the fleet but an operator-only pin, so the person's chat is what flips. |
| **FLEETD‑3** | The permission | **`instance:manage` stays bound to NAMING a host, never to the default** | Routing to specific compute is an operator act and must remain one; a default that demanded it would apply to nobody. Hence the two names: `ex-asked` is what the body said and is what the permission and `executor-known?` are about, `ex` is what the call uses. Collapsing them would either make the default operator-only or make pinning free. |
| **FLEETD‑4** | A fleet that is alive but PAUSED | **The default declines; a NAMED `@fleet` request still queues** | **The platform's own choice falls back; the caller's request is honoured or refused.** A caller who named the fleet gets a queue because a paused host may be ready in fifteen seconds — `fleet-can-run?`'s own argument and #172's line between `unclaimable` and `held_by_paused`. A DEFAULT that queued there would make an interactive chat wait out `WAIT-SECONDS` where the local model answers in two. So the default asks the stricter question, `#:ready-only? #t`, through the SAME walk with a keyword rather than a second copy of the matching loop. |
| **FLEETD‑5** | …and the test is `paused`, not `ready` | **A host with no reported state is still a candidate** | `worker_state` is optional on the wire (PULL‑11) and a claim that carries no `#:state` leaves it NULL, which is where every third-party worker written against the old wire sits. Withholding the default from a host that has reported nothing would withhold it from most of a mixed fleet. The first version of the test asserted `"ready"` and the suite corrected it to `'null`. |
| **FLEETD‑6** | The sensitivity policy | **No guard, deliberately, and the reason is written down** | An explicit `@fleet` that a policy refuses is a named 403 (RED‑24); a DEFAULT the policy would refuse must simply not be taken — the same asymmetry as FLEETD‑4. It cannot arise here: `POST /api/ai/chat` carries a free prompt and no document, which RED‑24 puts outside the policy entirely. A check that cannot bite is how a reader comes to believe the next one is missing (CLS‑23's lesson), so the fallback is NAMED as the thing to add the day this default reaches a tool that carries a document. |
| **FLEETD‑7** | What the reply says | **`executor: "@fleet"`, `fleet_default: true`, and `model: null`** | The endpoint used to report `executor: "local"` whenever the body named nothing, which after the flip would be a call the fleet answered described as local — the misroute-that-lies this module refuses everywhere else. `model` is `null` because the platform sent no model name and a worker answers with the first it declared, so reporting this box's own model would be a guess; that is the rule `endpoint` already follows on a `pull` row in the request log (RED‑16). `fleet_default` is present only when the PLATFORM chose, never `false` — QUOTA‑3's rule for a field that is there only when it says something, and what lets an operator see the flip taking effect. |
| **FLEETD‑8** | The knob, and its tier | **`TMACH_FLEET_DEFAULT`, instance-wide, default ON** · vs per team, as #173's note said | This contradicts a recorded note on purpose. What a TEAM chooses between executors is a model role and that already exists; what this answers is whether this DEPLOYMENT's fleet serves interactive chat, which is a property of its topology, like `TMACH_MULTITENANT`. And a per-team setting with no route to write it is #113's shape — a stored value nothing can set — so the team tier arrives with its route, when somebody wants one. Unparseable falls back to ON, the rule every default-bearing knob here follows; falling back to off would be a knob that silently did the opposite of its spelling. |
| **FLEETD‑9** | The stream | **NOT flipped, and this is the limitation to read before expecting the console to change** | `run-chat-stream` refuses `@fleet` by name because the pull wire cannot stream (#173), and flipping the default there would either start refusing every streamed chat or require buffering a worker's whole answer and emitting it as "a stream", which is RED‑14's objection inverted. **The console's chat streams**, so the console keeps running on the local model: the flip is visible to API callers and not yet in the product. Making it visible needs a worker wire that can carry partial tokens — a new remote kind, which is the same thing the agent needs, and it is #175's remaining half. |
| **FLEETD‑10** | The agent and research | **Still local, still refused BY NAME** | Unchanged from #173 and from #175's own analysis: `infer.chat` carries `{reply, tokens_used}` and has no representation for a tool-calling turn, so distributing the agent is a new remote kind rather than a routing change. A default that reached it would turn a working agent run into a named refusal, which is FLEETD‑2's reason for resolving this in the endpoint. |

| **FLEETD‑11** | How a caller asks for THIS BOX | **`"executor": "local"` declines the default** · vs no way at all | Before the flip `pick-executor` folded `"local"` into `#f`, so "say nothing" and "say local" were one request and both ran here. With the default flipped there would be NO WAY to ask for this node — and **the smoke is what found it**, by making its own "the simulated echo is not logged" assertion pass vacuously: the echo it was about had quietly become a fleet job that nothing was going to claim, which wedged the team's concurrency cap and failed thirty assertions in five later sections. `""` is deliberately NOT a pin — that is an absent field spelled badly, and reading it as one would let a client's empty string decide where the call runs. It needs no permission, because declining to route is not routing to specific compute. |

**What this does NOT claim.** The measured win in the #169 validation — 24
unpinned jobs across three hosts with four running at once, against the one box
every routed chat would have pinned to — is about the QUEUE, which has fanned
out since #173. What this slice adds is that a person's chat reaches that queue
without an operator pinning it, on the non-streaming endpoint. The streamed
path, the agent and research are named above rather than quietly included.

## VEC, continued — the arithmetic and the bytes seal (issue #189, steps 1–2, built 28 Oct 2026)

VEC‑1…10 evaluated and decided; this is the first half of the build plan at the
end of `docs/design/vector-store.md`. **Steps 1 and 2 only** — the two
prerequisites the plan called out as having their own tests and no behaviour
change. `domain/ai/vectors.rkt` is new; `secret-wrap/bytes` and
`secret-unwrap/bytes` join `secretbox.rkt`; `define-sealed-column` gains a
`#:bytes` form. **No migration, no route, no environment variable, no
permission, and nothing in production calls either of them yet.**

| | Question | Decision | Why |
|---|---|---|---|
| **VEC‑11** | Where the norms go | **The store is NORMALIZED at write, so the read is a bare dot product** · vs normalizing at read | For unit vectors the cosine IS the inner product, so normalizing once per chunk removes both square roots and both norm loops from every later comparison. `cosine` computes N+1 norms for one query against N stored vectors where one would do — that is half the 8×, and the other half is the boxing. It also moves the case that has no answer to the one place that can refuse it: a zero vector cannot be normalized, so the WRITE path declines the chunk and says why. |
| **VEC‑12** | The primitive | **`flvector`, and it is a DOT PRODUCT that is only a similarity when both sides are unit** | Re-measured with the real module, aarch64‑darwin, 100,000 × 768: boxed `cosine` **1,314 ms**, `flvector` dot **168 ms**, and the whole scan — decode plus dot plus a bounded top‑k — **784 ms**, which lands on the prototype's 759 ms end-to-end row rather than its 564 ms bare-decode one. At 10,000 the scan is **76 ms**, at 1,000 **8 ms**. The honesty matters: on un-normalized input `vec-dot` answers the inner product, usefully for nothing, which is exactly why the invariant is enforced at the write and asserted (`vec-unit?`) rather than described. |
| **VEC‑13** | Float width at rest | **float32 stored, flonum in the register, LITTLE-ENDIAN PINNED** | An embedding server answers float32, so float64 at rest would double the disk for digits the embedder never produced; Racket has no `f32vector` arithmetic worth the name, so the decode widens. The endianness is pinned rather than `(system-big-endian?)` because these bytes go into a file that is dumped, restored and replicated, and a dump decoded on the other byte order yields plausible numbers with no model name to catch it. **The test cannot catch an UNPINNED pin** — only an inverted one — because every machine anybody runs this on is little-endian, and the test says so where somebody might trust it. |
| **VEC‑14** | `cosine`'s future | **Unchanged, and kept** · vs replaced by the fast path | They compute different things and say so: one is the general similarity of two arbitrary vectors, the other the inner product of two unit ones. A shared implementation would have to be the general one — the slow one — and EMB‑7's label store compares a query against at most `MAX-LABELS` vectors, where 1,272 ms per hundred thousand comparisons is 12 µs per classification. `executor-can-run?`'s drift argument is about two copies of ONE rule; it does not reach two functions with different contracts. A unit case pins that they agree where their domains overlap, which is what makes this a decision rather than a duplication. |
| **VEC‑15** | A row of the wrong width | **`#f`, never a raise; skipped by the scan and COUNTED** | By the time a mismatch is seen at read it is a row that survived a model change (the store is keyed by model, EMB‑8/VEC‑8), so it is a survivor rather than a surprise — and it must not take somebody's query down. The count comes back beside the hits because a scan that silently returned fewer results would be a recall problem nobody could see, which is the shape `truncated` already answers for CLS‑27. The width is read off the BYTES, so a foreign row costs a remainder rather than a decode. |
| **VEC‑16** | Top‑k | **One pass with an insertion bounded by k** · vs scoring N and sorting | At 100,000 chunks the arithmetic is 168 ms; allocating and sorting 100,000 scored pairs to take ten of them would add allocation of the same order for an answer the loop already has. |
| **VEC‑17** | Where the authorization is NOT | **`vec-nearest` is handed rows and knows nothing about who asked** | VEC‑9 stands: the window is bounded in SQL and `can?` is applied per row AFTER the scan. The same reason the blob store is never handed a principal — a seam with no authorization cannot get it wrong. |
| **ENC‑24** | Sealing bytes | **A second stored FORM, not a second key, cipher or AAD rule** | `secret-wrap` is a STRING API, and on 29.3 MiB of packed float32 that costs **2,240 ms and 52.1 MiB** against **44 ms and 29.3 MiB** for `aes-256-gcm-decrypt` on the raw bytes — 51× and 1.8×, and **none of it is the cipher**, which runs at about 665 MiB/s. It is base64 in, UTF‑8 out, UTF‑8 in, base64 out: four whole-buffer conversions, two of which inflate the stored value by a third. Everything the string path has ever sealed is text, so the cost was invisible until something asked it to move a vector. Same `current-secret-key`, same AES‑256‑GCM, same 12-byte nonce, same `aad-for`. |

**THE SNIFF IS THE PREFIX *AND* THE SHAPE, and that is forced by what the
plaintext is.** `wrapped-secret?` can test a text prefix safely — a TOTP seed
does not begin `enc:v1:` — but a packed float32 vector may contain any byte at
all, so "is this row sealed?" cannot be answered by a prefix. `wrapped-bytes?`
requires eight magic bytes, then eight bytes that must be **lowercase hex** (the
key id), then room for a nonce and a GCM tag. A plaintext blob passing all three
by chance is about one in 2^75; the remedy if that ever matters is a column
saying which rows are sealed, which is step 4's to decide, where the table is.

**The `#:bytes` form carries the CONTENT gate, not `#:credential`'s
unconditional one**, which is VEC‑3 arriving in code: a document vector is a
function of `repo_text.content`, embedding inversion recovers much of the source
text, and an unsealed vector column beside a sealed `repo_text` would undo #83
on exactly the instance that asked for it. The form exists so that the AAD is the
same `sealed-context` every other sealed column is bound by — the 51× was in the
conversions and there was no reason for it to cost a second spelling of the
compatibility surface. **Both directions are pinned**: a content column waits to
be asked, where ENC‑23's credential seals on a key alone, and the unseal is
unconditional in both.

**WHAT IS DELIBERATELY NOT DONE YET**, because there is no column: the vector
column is **not** in `CONTENT-SECRETS` in `cli/telemachus-secrets.rkt`. VEC‑3
says it must be listed, and a sealed column `rewrap` does not walk is silently
unrotatable — so that line belongs in the same commit as the `CREATE TABLE`,
step 4, and is named here so it cannot be forgotten there.

**NOTHING CALLS EITHER MODULE, AND THAT IS THE PLAN'S OWN ORDERING RATHER THAN
AN OVERSIGHT.** #110 r4's rule is that an export in `domain/` with no consumer is
a claim the next reader has to assume is load-bearing; the exception it states is
an export with a test behind it, which both of these have — fourteen cases for
the arithmetic, eight for the seal, twenty-two controls between them and all of
them biting. Step 3 is the chunker, which is the one decision in this subsystem
with no measurement behind it, because measuring recall needs a live
`nomic-embed-text`; steps 4 and 5 are the table and the read. The arithmetic and
the seal have no such dependency, which is why they land first.

## QVIZ — a picture of the AI queue (issue #184) — DESIGNED, NOT BUILT

#184 asks for "a short design in `docs/design/`, with the retention question
answered, before any rendering code", which is what this is:
`docs/design/ai-queue-visualization.md`. No migration, no route, no console
code. Read it before building any of it.

**The retention question has a third answer, and it is the useful one.** The
issue offers client-side sampling (a live view, nothing on reload) or a decision
to retain counters. The `jobs` table already carries two of the three series —
`created_epoch` (migration 0041) for arrivals and `started_epoch` (0038) for
claims — and the third needs **one column, not a store**: `finished_at` is TEXT
`CURRENT_TIMESTAMP` and its format differs by dialect, so bucketing on it is
wrong on one engine and invisible on the other, the trap 0038, 0039, 0040 and
0041 each name in their own comment. `jobs.finished_epoch` is the fifth instance
of that shape.

What that buys is the part worth recording: **there is no retention decision to
make at all.** How far back the picture reaches is bounded by what already
bounds those rows — #59's per-job purge keeps the row, #86's retention rules
delete it on the team's own horizon — so an operator who asked to keep seven
days gets seven days of flow, with no new policy, no new sweep and nothing to
configure. It survives a reload and a restart, which a sampled series does not,
and it cannot disagree with the queue read because it is the same table. A
counter table would be a second copy of a decision the rows already carry, which
is the issue's own second constraint read back to it.

| | |
|---|---|
| **QVIZ‑1** | The three flow series are derived from `jobs`; completions need `finished_epoch`, and then there is no retention question |
| **QVIZ‑2** | Inline SVG drawn by hand, not a chart library — `script-src 'self'`, and all four pictures are shapes this codebase already draws |
| **QVIZ‑3** | The attempt path is ALREADY recorded: FLEET‑1 writes the holder per attempt before the requeue nulls `executor_id` |
| **QVIZ‑4** | No payload, no result, no tooltip exception — the queue read crosses every team |
| **QVIZ‑5** | It lives on #179's Health screen and COMPOSES the Workers and Queue cards rather than re-rendering their figures |
| **QVIZ‑6** | `instance:read`, and the refresh is explicit and defaults to off — a self-refreshing screen holds a session open (#38) |
| **QVIZ‑7** | The minute grid is fixed, so a flat run of zeros is visibly a flat run of zeros |
| **QVIZ‑8** | The window is a control and is named on screen — #178's lesson, already paid for on the Workers card |
| **QVIZ‑9** | Declined: a chart library, a counter table, a timeline for every job, an OpenMetrics rendering, and any write |

**QVIZ‑3 is the one that changed what the slice costs.** Priority 4 asks for
attempts and releases "as a path, not a counter", which read like a new table
until FLEET‑1's rule was re-read: the reaper writes `job.lease.expired` naming
the executor **before** the UPDATE, precisely because the requeue clears
`executor_id` and afterwards nothing in `jobs` says which machine dropped the
work, and `job.attempts.exhausted` carries `holders` oldest-first. So the path
is an audit read by resource id. What it needs that does not exist is a way to
ask for ONE job's trail: `audit-list` filters by team and does not project
`meta`, where the executor's name lives — the gap #59 and the anchor slice each
paid for once.

**QVIZ‑6 is a security answer wearing a convenience's clothes.** The console
polls nothing today except a live workflow run, and #38's idle clock counts from
the last REQUEST — so a dashboard that refreshed itself every ten seconds would
hold a session open for as long as the tab was left on screen, which is an
idle-timeout control switched off by a feature that looks like polish.

## HEALTH — one screen for "is this instance healthy" (issue #179, built 29 Oct 2026)

Everything an operator needs existed and was scattered across five HTTP reads,
and the console showed the FLEET and the QUEUE while **nothing showed the server
itself**. `GET /api/admin/status` gains five facts; the console gains a Health
tab. No migration, no new route, no new permission.

| | |
|---|---|
| **HEALTH‑1** | The screen COMPOSES the Workers and Queue cards; it does not re-render their figures |
| **HEALTH‑2** | `instance:read`, not `S.me.is_operator` — the permission #124 created for exactly this |
| **HEALTH‑3** | Nothing polls. The refresh is a button, because a self-refreshing screen switches off the idle timeout |
| **HEALTH‑4** | The status read gains the dialect, the schema's applied/pending, the blob store's NAME and the drain window |
| **HEALTH‑5** | No probe result: `instance:read` must not perform a write, and a serving instance has already passed the boot probe |
| **HEALTH‑6** | Uptime is DERIVED from the build's start time — one clock, not two |
| **HEALTH‑7** | The budgets are the caller's OWN team's, and the card says so |
| **HEALTH‑8** | The boot call moved to its own last-sorting file, because load order stopped being implicit |

**HEALTH‑1 is the decision the slice turns on.** The issue asks for a fleet
section and a queue section, and both already exist on the Admin tab. Drawing
those numbers again here would be two renderings of one answer that can disagree
about an edge nobody is looking at — `executor-can-run?`'s drift, LIVE‑IN's
shape — so `healthView` calls `workersCard` and `queueCard` with the same two
responses, and the test asserts BOTH halves: that it calls them, and that the
file contains none of `unclaimable`, `held_by_paused`, `oldest_queued_seconds`
or `leases_expired` itself.

**HEALTH‑3 is a security answer wearing a convenience's clothes**, and it is
QVIZ‑6 arriving one slice early. #38's idle clock counts from the last REQUEST,
and the console polls nothing but a live workflow run — so a dashboard that
refreshed itself every ten seconds would hold a session open for as long as the
tab was left on screen. That is an idle timeout disabled by something that looks
like polish. The screen says when it was read and offers a button.

**HEALTH‑5 — the probe is the one field a dashboard obviously wants and must not
have.** `blob-store-probe` writes a blob, reads it back and deletes it, so a
field here is a PUT, a GET and a DELETE against somebody's bucket on every
refresh — and the route is `instance:read`, which must not perform a write. The
honest signal already exists and is stronger: **startup refuses to serve on a
failed probe, so an instance that is ANSWERING has already proven its store
once.** A field asserting that from this module would be a claim about
main.rkt's behaviour made somewhere else, which is #119's shape, so the console
says it in prose and no field can go stale. What this does NOT tell an operator
is whether the store has gone away since boot; that is stated rather than
implied.

**HEALTH‑4's pending list names the ids rather than counting them**, because
migration runs at boot — so a pending one means one FAILED, and the id is the
only part of that an operator can act on. Unlike `schema-problem`, which must
ignore a plugin's `x.` ids to decide whether to boot, this is a REPORT and a
reader wants to see them, so they are counted in `applied` and excluded from
nothing.

**The server's own drain LATCH is deliberately not reported.** It lives for at
most `TMACH_DRAIN_SECONDS` and the process exits immediately after, so a field
for it would be blank in every reading anybody ever takes. What an operator
about to restart actually wants is **how long a stop will take**, which is the
knob; a HOST's drain is a different thing and has been on the Workers card since
FLEET‑3.

**HEALTH‑8 — the boot call moved, and the reason is a bug that had not happened
yet.** `render()` was the last line of `13-kg.js`, which worked only because it
is async and yields at its first `await`, giving the remaining `<script>` tags
time to parse before it reached `renderTab()`'s dispatch table. That is a real
dependency on a detail of the event loop, and it breaks the moment a view is
added in a file that sorts AFTER the one that boots — the tab exists, the
function does not, and the console dies at load with a `ReferenceError` that
only a browser sees. #179 added the first such file. `99-boot.js` sorts after
every numbered one, which is what `test/console-tests.rkt` requires of the load
order, and the test pins that exactly one file calls `render()` at top level.

**`all-migrations` IS A LIST, NOT A THUNK**, and `(all-migrations)` is "not a
procedure" at request time rather than at compile time. What made it diagnosable
in one read was #123: the 500 carries a request id and the message goes to
stderr beside it, where before this year the body would have carried the whole
exception and the log nothing.

## ED — one editor, two surfaces (issue #180, built 29 Oct 2026)

`static/console/15-editor.js`. Notes and Documents share it. No migration, no
new route, no new permission — and **no new write path**: every endpoint this
uses has existed as long as the route table.

| | |
|---|---|
| **ED‑1** | ONE component, used by Notes AND Documents; the funnel's template editor stays out, with a reason |
| **ED‑2** | The enabling half was not an editor: there was no way to EDIT at all |
| **ED‑3** | No CDN and no vendored library — a stated Markdown subset, the one this platform's own documents are written in |
| **ED‑4** | Safety is the ORDER: escape first, then rules over escaped text emitting a closed set of tags |
| **ED‑5** | A link's scheme is allowlisted, and an entity-encoded one cannot survive the escape |
| **ED‑6** | Line numbers turn soft wrap OFF, because a gutter that is subtly wrong is worse than none |
| **ED‑7** | The view preferences are per-viewer and stored; the TEXT lives in `S` |
| **ED‑8** | The textarea keeps the ids the fields it replaced had (`nb`, `dc`) |
| **ED‑9** | Export is a Blob and an `a[download]`, and the CSP question is answered in the browser |
| **ED‑10** | "Save to the repository" is one existing endpoint, because a text document IS a repository object |

**ED‑1 is the decision the issue asks for up front**, and its own words are the
argument: "three bare textareas becoming three different editors is the outcome
to avoid." So Notes and Documents share one component. **The funnel's template
editor is deliberately not folded in**: its content is HTML rather than
Markdown and it already has a live preview of its own
(`renderLandingShell(cfg,'preview')`), so including it would mean one component
serving two languages and two previews — which is how a shared thing becomes
three again with extra steps.

**ED‑2 — THE CONSOLE COULD NOT EDIT A NOTE, AND HAD NEVER BEEN ABLE TO.** The
body was an `<input>`, not even a textarea; Documents was a 4-row textarea; and
both could be created and deleted and never changed. `PUT /api/notes/:id` and
`PUT /api/documents/:id`, with a body-bearing `GET` beside each, have existed as
long as `routes.rkt` — **#113's shape on this side of the wire**, a capability
the server has always offered that no surface reached. An editor for a field
somebody can only ever fill in once is worth very little, so the edit path lands
with the editor rather than after it. The e2e gate had been editing a document
over the API directly since the blob-write fix, which is how the gap stayed
invisible: the write path was proven and the way to reach it was not.

**ED‑4 — WHAT MAKES THE PREVIEW SAFE IS THE ORDER, NOT A SANITISER.** The
source is HTML-escaped first; the block and inline rules then run over
already-escaped text and emit a closed set of tags. Nothing from the source is
ever passed through as markup, so there is no sanitiser to get wrong — a
`<script>` in a note is `&lt;script&gt;` before any rule sees it, and the
blockquote rule has to match `&gt;` rather than `>`, which is the tell that the
rules really do run after the escape. The console's `script-src 'self'` is the
backstop and explicitly not the defence: a preview that relied on it would be
one policy change away from a stored XSS.

**AND IT IS TESTED AT RUNTIME, BECAUSE A SOURCE ASSERTION CANNOT ESTABLISH
THIS.** A Markdown renderer is effectively a sanitiser and "does it escape" is a
question about what it COMPUTES. `test/e2e/demo-validate.mjs` §3c calls the real
function on the real page with the inputs somebody would actually try — an
`<img onerror>`, a `<script>`, `[click](javascript:…)`, the entity-encoded
variant, a fenced block whose asterisks must stay literal — and asserts the
output. That is the strongest form available here and it is where the claim
lives; `test/console-tests.rkt` pins only the structure.

**ED‑6 — A TIE, NOT A PREFERENCE.** A wrapped logical line occupies several
visual rows, so a gutter of logical numbers stops aligning with the screen the
moment one line wraps, and a gutter that is subtly wrong is worse than no
gutter. With wrapping off the textarea is auto-sized to its line count instead,
so it has **no internal vertical scroll to synchronise** and the two columns line
up with no scroll handler at all — which is as well, because a `scroll` event
does not bubble and the delegated dispatcher (#27) could not have carried one.

**ED‑7 — the preferences are stored and the TEXT is not.** `preview`, `wrap`,
`mono` and `nums` are per-viewer conveniences, so they go in `localStorage` with
every read and write wrapped: the accessor throws in a private window and comes
back empty with cleared site data, and a toolbar that would not render because a
preference could not be read is a poor trade. The text lives in `S`, so a render
pass does not lose what has been typed — `paintAuth()`'s rule, for the same
reason — and `edRead` prefers the DOM and falls back to that, which covers both
a value set programmatically and `preview: only`, where the textarea is
`display:none` but still holds the text.

**ED‑8 — the ids did not change, and that was a choice.** `page.fill('#nb', …)`
and `#dc` appear in `demo-validate.mjs`, the screenshot tour and the funnel
harness. Renaming a field to tidy it would have broken three harnesses with
nothing on the other side.

**ED‑10 — "save to the repository" needed no code.** A text document IS a
repository object since migration `0022-fold-documents`: `content_type
text/markdown`, the title in the version's filename. So the issue's "ideally
save to the repository as a document, which is one `repo-put!` away" is in fact
zero away — it is `POST /api/documents`, the endpoint the Documents tab already
uses.

**Leaving a tab abandons an edit in progress**, the way `go()` already drops a
run poll: keeping it would leave a Save button on a card whose note is no longer
on screen.

**The screenshots are not refreshed here.** The Notes caption describes
visibility and RBAC rather than the body field, so it is still accurate; the
image is merely dated, and refreshing it needs a live model and regenerates both
READMEs' feature-tour regions. Re-stamping a `captions.ja.json` hash for a
caption whose text did not change would be churn with no reader.

## PAL — a command palette, and the first keyboard route into the console (issue #182, built 29 Oct 2026)

`static/console/16-palette.js`. Cmd/Ctrl+K opens a palette over the current
view; `?` lists what is bound. No migration, no route, no permission.

| | |
|---|---|
| **PAL‑1** | It hooks the ONE delegated listener, before the element lookup |
| **PAL‑2** | The modifier is DETECTED and the label follows the detection |
| **PAL‑3** | A bare `?` does nothing while something is being typed into; a held modifier works everywhere |
| **PAL‑4** | `Esc` falls THROUGH when nothing of the palette's is open |
| **PAL‑5** | The palette and the shell share ONE tab list |
| **PAL‑6** | Records come from `GET /api/search`, so an unreadable one cannot be offered |
| **PAL‑7** | The action map holds only functions that already exist, and is small on purpose |
| **PAL‑8** | The overlays live in the static shell, not in a render pass |

**PAL‑1 — the issue asks for this by name and the reason is #27's.** 01-base.js
registers exactly one document listener per event type; a second one for a
global shortcut is where the handler-leak and double-fire risks that dispatcher
exists to remove would start over. `paletteKey` is called from inside it and
**before** the `closest('[data-h-keydown]')` lookup, because a global shortcut
is not about an element and an element-scoped dispatch cannot carry one. It
answers whether it took the key. The test asserts the ORDER of the two, not
merely that both are present.

**PAL‑3 is the asymmetry, and it is deliberate.** `Cmd/Ctrl+K` works
everywhere, including inside a text field, because a held modifier is
unambiguous. A bare `?` fires only when focus is not in a field — otherwise it
eats a question mark, which is the one way a help shortcut can leave a console
worse than it was. This console ships in Japanese and already learned the
neighbouring lesson from `isComposing` (#174), so the e2e gate types `a ? in a
note` into the editor and asserts BOTH halves: the overlay stayed shut and the
character really arrived.

**PAL‑4 — `Esc` is already load-bearing here**: it leaves the editor's focus
mode (ED‑6). Taking it unconditionally would break that, so the handler returns
false when neither overlay is open and the key goes on to mean what it meant.

**PAL‑5 — `visibleTabs()` was extracted for this, and the drift would have been
the palette's.** `appShell` built the list inline; the palette's first job is
"jump to a tab", so a second copy would eventually offer a tab a feature switch
has turned off or a permission does not allow — and it is the palette that would
be wrong, because the shell's copy is the one somebody looks at. LIVE‑IN's
shape: derive it once. The test asserts the list is spelled exactly once in the
whole console.

**PAL‑6 — the authorization is somebody else's and that is the point.**
`GET /api/search` already answers across notes, repository objects and
knowledge-graph entities with the per-row `can?` filter, so the palette cannot
offer a record its user may not read **by construction** rather than by a check
written here. The search is sequence-counted (`renderTab()`'s rule): two
searches can be in flight and the slower one would otherwise overwrite the
newer list.

**PAL‑7 — an action that merely looks plausible is a button that 404s.** Every
entry in the map is a function that already exists in this console, and the map
is deliberately a handful per tab: a palette that lists everything is a menu.

**PAL‑8 — the overlays are in `static/index.html`, not in a render pass**,
because a tab re-render must not take the palette down mid-interaction. The
cost is the documented one: **the shell is cached at startup, so a live box
needs a restart to pick this up** — the console's own `*.js` is read per request
and does not.

**A `.kbd-hint` in the header, because "a palette nobody knows about is a
palette nobody uses"** is the issue's own note. It shows the detected modifier,
so it is also the visible half of PAL‑2.

## CHUNK — the chunker, and the half of it that does not wait for hardware (issue #189, step 3, built 29 Oct 2026)

Step 3 of `docs/design/vector-store.md`'s build plan, and the plan describes it
as "the decision that governs retrieval quality and the one with no measurement
behind it yet, because measuring recall needs a real embedding endpoint." That
is true of **two numbers** — the chunk size and the overlap — and it is not true
of the mechanism: where a boundary falls, what an offset MEANS, that the walk
terminates, and that two runs agree are each decidable with a string and no
model, and each is now pinned. So what remains behind the GPU rig is a
**calibration**, not a build. `domain/ai/chunk.rkt`; `test/chunk-tests.rkt`,
17 cases, **ten positive controls, all of which bite**. No migration, no route,
no environment variable, no permission.

| | |
|---|---|
| **CHUNK‑1** | The offsets are CHARACTER offsets into the text the extractor returned — `repo_text.content`'s own string, which is `repo_text.spans`' coordinate system |
| **CHUNK‑2** | The unit is characters, not tokens, because there is no tokenizer here; the ratio behind the default is an ENGLISH assumption and it is measured |
| **CHUNK‑3** | A boundary is preferred, never required, and the search window is bounded |
| **CHUNK‑4** | The progress rule is the one place termination is guaranteed |
| **CHUNK‑5** | A whitespace-only chunk is never emitted |
| **CHUNK‑6** | Pure: the same text and parameters give identical offsets in any process |
| **CHUNK‑7** | The chunk count is capped, and the truncation is reported both ways |
| **CHUNK‑8** | There is no paragraph scan, and a positive control is what removed it |
| **CHUNK‑9** | The two numbers are PROVISIONAL, labelled as such in the code, and what would change them is a measurement |

**CHUNK‑1 — THE OFFSETS COST NOTHING AND BUY STEP 5.** The build plan asks that
"a chunk's offsets line up with `repo_text.spans` so a hit can be shown where it
was read". They line up by being the same thing: both index the string the
extractor produced, so `spans-covering` (extract.rkt, LAY‑5) resolves a chunk's
start to a page and a bbox with **no new code**, and step 5's "return the chunk's
offsets so the caller can cite it" is a lookup. A chunker carrying its own
notion of position — token indices, paragraph ordinals — would need a mapping
back, and a mapping is a thing that can disagree. The test asserts it against
the real `spans-covering` rather than restating the rule.

**CHUNK‑2 — CHARACTERS, BECAUSE A TOKEN COUNT HERE WOULD BE A GUESS.** There is
no tokenizer in this tree and the one that matters is `nomic-embed-text`'s own,
so a token figure computed on this side is a number wearing a measurement's
clothes. The default converts the 256-token figure `vector-store.md` sized
#183's corpus with at the usual English ratio of about four characters to the
token: **1,024 characters, with 154 of overlap** (its 15%).

Measured against the real corpus rather than estimated: **62 English documents,
997,972 characters, 157,709 words → 1,227 chunks**, where the design document's
token-based estimate was 1,159. Within 6%, which is the confirmation that the
conversion is sound for English. A document **at `EXTRACT-CAP`** gives **231
chunks**, which is the "about 230" that document quotes — now a number somebody
checked.

**AND THE RATIO IS AN ENGLISH ASSUMPTION, WHICH IS A FINDING RATHER THAN A
FOOTNOTE.** This platform ships a complete `ja` catalog, a Japanese edition of
its own book and a Japanese generated reference, so Japanese documents are the
normal case here and not a hypothetical. Measured on the book's own chapters:
chapter 04 is **3,342 characters in English and 2,079 in Japanese** (62%), and
chapter 02 **2,517 against 1,797** (71%) — fewer characters, as a reader would
expect. But Japanese runs close to ONE token per character against English's
four, so **a 1,024-character chunk of Japanese carries on the order of four
times the tokens a 1,024-character chunk of English does**, and the 256 the
default was calibrated on becomes something nearer a thousand. A chunk that
overruns the embedding model's context is truncated BY THE MODEL, so the failure
is a quietly worse vector and never an error. The recall measurement must
therefore be made in BOTH languages, and if the answer is one number per
language then `size` is already the knob. Nothing here guesses at a locale, and
the alternative — a per-language default nobody has measured — would be the
confident wrong answer this decision exists to avoid.

**CHUNK‑3 — THE WINDOW IS WHAT MAKES A BACKWARD SEARCH SAFE.** The search runs
backwards from the hard limit: a sentence end, then any whitespace, then the
hard limit itself, mid-word. It may walk back at most a quarter of the size.
Searching the whole chunk instead is the obvious version and is wrong on text
with one early boundary and a long unbroken run after it — minified JSON, a
base64 blob, an unspaced CJK line — where it splits two characters in and every
chunk after is a sliver: a recall problem and a cost problem that looks like
neither. **The fixture with NO boundary at all cannot see that**, which is what
a control showed, so the case is a document whose only boundary is near the
start. The CJK sentence enders (`。！？`) are in the set for the same reason the
asymmetry above is: a whitespace search finds nothing inside a Japanese
paragraph, and without them every Japanese document splits mid-word. Dropping
them fails a case.

**CHUNK‑4 — ONE RULE, AND A BUG IT CAUGHT.** The next start is
`(max (add1 start) (- end overlap))`, and the first version lacked the arm that
stops once a chunk has reached the end of the text — the overlap subtracts from
the end, so the walk stepped BACK inside a finished document and re-emitted its
tail until the cap stopped it. A hundred-character document answered with ten
identical chunks and `truncated`, which reads as a cap set too low. The test
found it. Three knobs interact here, so an argument that the arithmetic cannot
stall is an argument about all three at once and the kind that stays true until
somebody changes one; the rule is stated once instead. What it promises is
PROGRESS and not coverage: `overlap` is only held below `size`, so a caller who
sets the two within a character of each other advances one character per chunk
and the cap ends the walk, saying so. A degenerate setting that reports itself
beats one that hangs.

**CHUNK‑5 — A BLANK CHUNK IS NEVER PRODUCED, WHICH IS CHEAPER THAN REFUSING
ONE.** `vec-normalize` answers `#f` for a zero vector because a zero vector has
no direction (VEC‑11), and `vector-store.md` already names "a chunker will
eventually hand an embedder one whitespace-only chunk" as how that is reached.
Not emitting it costs no request, no budget and no row, and it makes the output
exactly "the chunks worth embedding" rather than a list something downstream has
to filter. The ordinals stay DENSE over what was emitted — a gap in them would
be a key with a hole in it for step 4.

**CHUNK‑6 — PURITY IS WHAT MAKES STEP 4 CHEAP.** No clock, no randomness, no
database, so a re-chunk of an unchanged version is a no-op that can be
recognised as one and a stored chunk's offsets are still true about the text
they were cut from. `canonical-json`'s stability argument (FEED‑18), one layer
up.

**CHUNK‑7 — THE CAP IS A SECOND, INDEPENDENT BOUND.** `EXTRACT-CAP` already
holds one document to 200,000 characters, which at the defaults is the 231
chunks above. `size` is a caller's argument, though, and a small one turns one
document into thousands of model requests against a 200/day `ai.requests`
default — so the count is capped at 400 as well, and `truncated` answers in both
directions. A flag that is only ever true tells an operator nothing: CLS‑27's
rule, where a short page and the last page are the same shape and must not be.

**CHUNK‑8 — THERE IS NO PARAGRAPH SCAN, AND A CONTROL IS WHAT REMOVED IT.** The
first version preferred a blank line over a sentence end, which reads well and
was doing nothing: `#\newline` is already a sentence ender, so both scans walk
backwards to a newline and on ordinary prose find the same one. Dropping it
changed no test at all — #110 r1's shape, where a check that duplicates the next
one is how a reader comes to believe the next one is missing. Where the two
genuinely differ is the case that settles it: a window holding a blank line and,
later, a single line break. The paragraph scan prefers the earlier, stronger
break, which on a hard-wrapped document — every line ending in a newline —
walks back through the whole window and gives away a quarter of every chunk.
What ending mid-paragraph costs instead is the seam, and the overlap is what
already covers a seam. So the trade is a measurable quarter of the context
against a coherence argument with no number behind it, and that is not a trade
this module pays. **If a measurement later shows paragraph-aligned chunks
retrieve better, it comes back WITH the number.** The distinguishing case is now
a test, so the question cannot go quiet again.

**CHUNK‑9 — NOTHING CALLS IT YET, AND THE TWO NUMBERS SAY THEY ARE
PROVISIONAL.** #110 r4's rule is that an export in `domain/` with no consumer is
a claim, and its stated exception is an export with a test behind it; step 4 is
the table and the write path in `plugins/doc-indexer`, which is where the
consumer arrives. The defaults carry the word "provisional" at their definition
together with what would change them, because a number that looks decided is
indistinguishable from one that was measured — #119's shape — and these two are
the ones the GPU rig's driver upgrade is still holding, beside #163's
`EMBED-MARGIN-SCALE`.

## VEC (continued) — the table, the first binary column, and the write path (issue #189, step 4, built 29 Oct 2026)

Step 4 of `docs/design/vector-store.md`'s build plan: "the table and the write
path, as a step in the existing indexing workflow rather than a new seam — a
chunk's vector is the same kind of thing as its extracted text, keyed on the
version, replaced wholesale by a new one." Migration `0064-chunk-vectors`,
`domain/ai/chunkstore.rkt`, `domain/repo/embed-tools.rkt`, and a second workflow
in `plugins/doc-indexer/`. **No route, no permission, no new environment
variable** — `TMACH_EMBED_URL` and `TMACH_EMBED_MODEL` are #163's.

**VEC‑18 — THE KEY IS THE VERSION, exactly as `repo_text`'s is.** A vector is of
a chunk of the text of a particular set of bytes, so a new upload does not
"update" it — it replaces the set wholesale, the rule `repo_text.spans` already
lives by (LAY‑5). It is also what makes a superseded version's vectors
unreachable rather than merely stale: step 5's scan will join
`o.current_version_id`, so an old set can never score, and the lister sees "no
vectors for the current version" and offers the document again.

**VEC‑19 — `id` IS SYNTHETIC AND THE NATURAL KEY IS A UNIQUE INDEX**, which is
not tidiness. A sealed column's AAD is `<table>.<column>:<row-id>` and
`telemachus-secrets rewrap` walks a column by ONE id column, so a composite
primary key here would have meant teaching the rotation CLI about composite keys
in order to satisfy VEC‑3. A uuid costs 36 bytes and leaves both the AAD rule
and the CLI as they are. `(object_id, version_id, idx)` is still enforced, as an
index, because "one vector per chunk per version" is what the write path depends
on — and it is what makes a mid-insert failure possible to test at all (below).

**VEC‑20 — `model` IS A COLUMN AND `dims` IS NOT.** EMB‑8: vectors from two
checkpoints are not comparable and mixing them does not raise, so the read
filters on the model in SQL rather than discarding mismatches mid-scan, and
changing `TMACH_EMBED_MODEL` makes every document eligible for a re-embed.
`dims` is absent for the opposite reason: VEC‑15 reads the width off the BYTES,
so a stored copy is LIVE‑IN's shape — a second fact able to disagree with the
first.

**VEC‑21 — REPLACED WHOLESALE, IN ONE TRANSACTION.** The unit of correctness is
"the vectors of this version", never one row: a half-written set is a document
whose chunks 0–4 are of today's bytes and 5–11 of last week's, and **nothing
downstream could detect that** — the model matches, the widths match, and the
offsets point into a string that has changed underneath them. A positive control
is what established which mechanism does the work: every validation in
`chunks-replace!` runs BEFORE the delete, so with the transaction removed the
"a refused write does not destroy the previous set" case still passed. The
transaction's own case had to be written — two chunks claiming one `idx`, which
VEC‑19's unique index refuses on the second insert — and that case fails without
it, naming the mixture.

**VEC‑22 — A VECTOR WITH NO DIRECTION IS REFUSED AT THE WRITE**, not stored and
skipped later. `vec-normalize` answers `#f` for a zero or NaN vector and the
store's invariant is that every row is a UNIT vector, because that is what makes
the read a bare dot product (VEC‑11). A stored zero would compare 0.0 against
every query — the WORST match — which is a claim where "this chunk could not be
embedded" is the truth. Providers really do answer a zero vector for empty
input, which is `cosine`'s own reason for the same choice.

**VEC‑23 — A BLANK-TEXT DOCUMENT IS FILTERED IN THE LISTER, AND IT CANNOT BE A
SQL TEST.** `repo_extract_text` records an unreadable document as
processed-with-nothing — an empty `repo_text` row, deliberately, so one corrupt
file cannot wedge a team's indexing — and the chunker answers zero chunks for an
empty string, so such a document can never acquire a vector row. Unfiltered it
is listed by every run for ever, which is index-tools' own objection to filtering
in the map, and here it also means **the drain never terminates**: an operator
running the workflow until it finds nothing never finishes. The test has to be
made in Racket on the unsealed text, because under `TMACH_ENCRYPT_CONTENT` the
stored `content` is a sealed string and an empty text is NOT an empty column —
`t.content <> ''` is true for it. A check that worked on the documented default
and silently stopped working on a sealed instance is the dialect-divergence class
this codebase already watches for, wearing a different hat. So the window is
bounded in SQL (`EMBED-SCAN`) and the filter runs over it, CLS‑27's shape.

**VEC‑24 — A SECOND WORKFLOW, NOT TWO MORE STEPS ON `index-documents`.** The
build plan says "as a step in the existing indexing workflow rather than a new
seam", and the *seam* is what that sentence is about: no daemon, no second
execution path, the plugin's spec and the core's tools. What it is not is two
steps appended to the published `index-documents` spec, because **a step that
errors fails the RUN**: `repo_embed_chunks` refuses without `TMACH_EMBED_URL`,
which is unset on every instance today, so text indexing would start failing
everywhere the moment this landed. Positive-controlled by appending them — the
run errors with `step 'efind' failed: no embedding model configured`. The
precedent is `classify-backfill` (CLS‑24): a separate spec rather than a flag on
a published one, for the same reason adding an INPUT to a published spec is a
breaking change. It also lets an operator drain the text backlog and the vector
backlog at different rates, which is what they will want, because one is free and
one spends the AI budget.

**VEC‑25 — NO EMBEDDING CALL IN THE STORE, AND NO AUTHORIZATION EITHER.** The
vectors arrive as an argument. `embed-exchange` is egress-gated, request-logged
and metered at the seam in `doc-tools.rkt` (`current-doc-embed` + `meter-embed!`,
now exported for its second asker), and a second caller of it inside the store
would be a second place those three could be forgotten — RED‑16's finding, where
`model-exchange`'s own header called itself the one place content leaves while
two other paths had their own. So the store is pure of the network and its test
needs no endpoint. It is handed no principal either, exactly as `repo-text-upsert!`
is: VEC‑17's rule, and the blob store's — a layer never handed a principal has no
authorization to get wrong.

**THE FIRST BINARY COLUMN IN THIS SCHEMA, and the round trip was measured before
anything was written.** Zero `BLOB`/`BYTEA` columns existed. The type spelling is
branched (`BLOB` on SQLite, `BYTEA` on PostgreSQL) and getting that wrong is a
syntax error at migration time — loud, and therefore the harmless half. The half
that would NOT have been loud is the round trip, so a probe stored all 256 byte
values through `db-kit/portable` on both dialects and read them back identical
before the migration existed; `test/chunkstore-tests.rkt` then pins it, and the
whole file runs under `DATABASE_URL=postgres://…`. A vector that decodes to
plausible-but-wrong numbers has no model name to catch it (VEC‑13's own argument
for pinning little-endian) and retrieves the wrong chunk for ever.

**ONE EMBEDDING REQUEST PER BATCH OF 32 CHUNKS, metered per batch.**
`ai.requests` defaults to 200/day, so one request per chunk would let a single
231-chunk document — a document at `EXTRACT-CAP` — spend a team's whole day; one
request per document hands a provider a 231-item array. Metering per batch rather
than once at the end is FEED‑9's rule: a run that fails on its third batch has
spent the first two, and a meter that only fires on success makes a failing
document free to retry for ever. The completion budget is untouched and a test
pins that it is, because folding an embedding into `ai.tokens.total` would make a
retrieval index silently eat the budget the chat path needs (EMB‑6).

**AND THE TEXT INDEXER HAD BEEN HANDING A COLLEAGUE'S PRIVATE DOCUMENT TO A RUN
THAT COULD NOT READ IT** — found while writing this slice's own lister, which had
the same shape. `repo-list` has applied `can?` per row since slice 49;
`repo_list_unindexed` (slice 54) selects by `team_id` alone, so a member running
**Index Documents** on a team holding one private document was handed its id,
and `repo_extract_text` then raised `forbidden: files:read`, which fails the step
and the run. So the workflow was unusable for anyone but the owner on any team
with a private document, and what an operator saw was a failed run naming a
permission. `repo-readable?` in `repo.rkt` is the one predicate both listers now
ask, collapsing a miss and a refusal as the knowledge graph does. **The first
regression case for it did not bite**, because by the point it ran alice had
already indexed the private document and the lister offers only what is
unindexed — the "exactly-once hides every later mistake" shape, in a lister. It
takes a private document created AFTER that run, which is the one state in which
nothing else is deciding.


## VEC (continued) — the nearest-chunk read (issue #189, step 5, built 29 Oct 2026)

Step 5 of `docs/design/vector-store.md`'s build plan, verbatim: "a nearest-chunk
query, team-scoped in SQL, `can?` per row after the scan, returning the chunk's
offsets so the caller can cite it." `domain/ai/chunksearch.rkt` and
`test/chunksearch-tests.rkt`. **No migration, no route, no permission, no new
environment variable, and no model** — every piece it needed had been on disk
since step 4, which is why the one thing still behind the GPU rig (step 3's size
and overlap calibration, in both languages) does not block it.

**VEC‑26 — THE WINDOW CAP AND THE REVISIT THRESHOLD ARE THE SAME NUMBER, ON
PURPOSE.** `vector-store.md`'s "When to revisit" says to look again when a single
team's chunk count passes 50,000, and the measured scan at that scale is ~390 ms
of arithmetic. So `NEAREST-SCAN` is 50,000 and a team whose window TRUNCATES is a
team that has already crossed the line where this design says to reconsider the
whole approach — which makes `truncated` the signal to revisit rather than a
routine condition to be tuned around. A cap chosen independently would have been
a second number saying the same thing, and LIVE‑IN's shape says the two would
drift.

**VEC‑27 — THE JOIN AND THE MODEL FILTER ARE BOTH IN SQL.** The window joins
`o.current_version_id`, which is what makes a superseded version's vectors
unreachable rather than merely stale (VEC‑18) — and that matters because a
re-upload deliberately does NOT clear the old rows, so this join is the only
thing standing between a query and vectors of bytes nobody can see any more. It
filters `c.model` in SQL rather than in Racket (VEC‑20/EMB‑8): a dot product
between two unrelated coordinate systems is a NUMBER, so mixing checkpoints
answers confidently and nobody can tell, and filtering after the fact would
decode every foreign row in order to throw it away. The test asserts on
`scanned`, not only on the hits, so a filter moved into Racket fails it.

**VEC‑28 — `can?` PER ROW AFTER THE SCAN, MEMOIZED BY OBJECT, OVER `k ×
AUTHZ-HEADROOM` CANDIDATES — AND THIS IS THE ONE APPROXIMATION IN THE MODULE.**
VEC‑9 is kept and the memo is what makes it affordable rather than clever: a
document is many chunks, so the number of `repo-readable?` calls is the number of
distinct DOCUMENTS among the candidates and not the number of candidates, and an
ordinary business document is ~9 chunks. The headroom is the part worth stating
plainly, because the exact version is reachable and was measured against. Taking
exactly `k` from the scan and filtering afterwards has a real recall hole: if the
top ten chunks all belong to a colleague's PRIVATE document the query answers
nothing while readable chunk eleven was a good match — **which is the shape step
4 found one slice earlier from the other side**, where `repo_list_unindexed`
selected by `team_id` alone and handed a member what the next step could not read.
The exact fix is to authorize every row in the window BEFORE the arithmetic, and
that costs one `repo-readable?` per distinct document in the team: at ten thousand
documents it is ten thousand queries on a query path, which is seconds. So the
hole is pushed out four-fold rather than closed, and when the headroom is
exhausted with fewer than `k` survivors the report says so.

**VEC‑29 — `truncated` REPORTS BOTH WAYS OF STOPPING**, CLS‑27's rule that a flag
which is only ever true one way tells an operator nothing — and here the two have
different remedies. The window filled means "this team is past the scale this
design says to revisit at"; the headroom running out means "ask for fewer, or you
may not read what is nearest". `withheld` and `skipped` are separate counts
beside it for the same reason: a candidate `can?` removed and a row of a foreign
width (VEC‑15) have nothing in common.

**VEC‑30 — THE CUT'S ORDER IS `created_epoch DESC`, SO A WINDOW THAT HAS TO CUT
CUTS THE STALEST, AND THE TIEBREAK IS `object_id, idx` SO IT CUTS A DOCUMENT'S
TAIL RATHER THAN A SCATTER.** Every chunk of one `chunks-replace!` is stamped
with the same `current-seconds`, so within a document the tiebreak decides the
entire cut. **How far the test goes is written down in the module and is not all
the way**: removing `created_epoch DESC` fails the last case on BOTH dialects,
removing the whole `ORDER BY` fails nothing on either (four runs on SQLite, three
on PostgreSQL — both planners happen to return the newer document's rows first
for that fixture), and substituting `c.id` for `idx` fails nothing either,
because `chk_<ms>_…` is near-monotonic within one write and so is accidentally
almost a prefix order. That is VEC‑13's unpinnable pin — the reason to write the
key down rather than a reason the key is redundant — and it is stated because the
next reader will run that control and should know it was run.

**VEC‑31 — THE QUERY IS NORMALIZED HERE AND A DIRECTIONLESS ONE IS REFUSED BY
NAME.** `vec-dot` is only a similarity when both sides are unit (VEC‑12); the
stored side is unit by the write's own invariant (VEC‑22), so the query is the
half left to establish. Scoring a zero or NaN vector would compare 0.0 against
everything and report the whole corpus as equally bad — a claim, where the honest
answer is that the question had no direction — and an embedder really does answer
one for empty input, so the refusal says that the query TEXT is the thing to look
at. `vec-normalize`'s `#f` is what makes this one line rather than a second guard.

**VEC‑32 — A HIT CARRIES WHERE TO READ AND NOT THE TEXT.** The store holds
offsets and a vector and no text at all, so text means reading `repo_text` and
taking a substring — which is the retrieval TOOL's job (step 6), needs
`repo-text-for`, and belongs where the model-facing result is composed. What a
hit does carry is the chunk's own offsets, and CHUNK‑1 is what makes those
citable with no new code: they and `repo_text.spans` index the SAME string, so
`spans-covering` resolves a hit to the page and bbox it was read from. The test
asserts that through the real function, which is the assertion that would fail if
a future chunker grew a coordinate system of its own.

**It is a SEPARATE MODULE from `chunkstore.rkt` because of what that one
promises.** Its header says it is handed a connection and an object id and is
never handed a principal — VEC‑17's rule and the blob store's, that a layer with
no authorization cannot get it wrong. This read is the opposite kind of thing:
`can?` is the whole of its difficulty, so putting it beside the write would make
that promise false for the module as a whole. **Nothing calls it yet**, by the
build plan's own ordering (#110 r4's exception: an export with a test behind it).

## VEC (continued) — the retrieval surface (issue #189, step 6, built 29 Oct 2026)

Step 6 of `docs/design/vector-store.md`'s build plan, and the last of it: "a
retrieval tool and `?semantic=` on search, which is where #183 and #191 pick it
up." `domain/repo/passages.rkt` (the shared read), `domain/repo/retrieve-tools.rkt`
(the tool), `search-passages` in `domain/apps/search.rkt`, and `?semantic=` on
`GET /api/search`. **No migration and no new permission** — the two it uses,
`files:read` and `chat:use`, both already mean what is needed.

**VEC‑33 — TWO ASKERS, ONE ANSWER.** The step names a tool AND a search
parameter, so `passages-for` is the one place the question is embedded, the
budget is spent and the scan is asked. Two copies would be
`executor-can-run?`'s drift in the worst place available, since one of them is a
model request against somebody's allowance. The division is three modules on
purpose: `chunksearch.rkt` is the scan and the `can?`, `passages.rkt` turns
chunks into TEXT, and the tool and the search half are each just a surface.

**VEC‑34 — THE TOOL REFUSES WHERE THE SEARCH DEGRADES, and both are right for
the reason each is right where it already appears.** A tool asked for exactly
this names the unset variable and stops — `repo_embed_chunks`'s rule, and
`require-embedder!`'s argument that failing at step one beats failing
twenty-five times for one variable. A search asked for a SEARCH answers the
keyword half and reports that the other one did not run — `content_search:
false`'s rule, in the very module that rule lives in, and the alternative would
leave a caller asking for both worse off than one asking for neither.
`semantic-available?` is exported so the two surfaces cannot drift into one
posture; it makes neither decision itself.

**VEC‑35 — ASKING COSTS A MODEL REQUEST, SO IT IS GATED ON `chat:use`.** This is
the only kind of search in this tree that spends the team's AI allowance: the
question has to be embedded by the same checkpoint the stored vectors are of.
`chat:use` is already the permission meaning "may spend the team's AI
allowance", and `search.rkt` gates translations on it one `cond` arm away. The
registry still declares the tool under `files:read`, because that is the
resource permission and declaring the stricter one there would hide the tool from
the role that holds both. The metering goes through `current-doc-embed` +
`meter-embed!`, never `embed-exchange` directly — RED‑16's finding, that a second
caller of the wire is a second place the egress policy, the request log and both
dimensions can be forgotten.

**VEC‑36/‑37 — THE TEXT COMES FROM `repo_text`, AND A PASSAGE WHOSE TEXT HAS
MOVED UNDER IT IS DROPPED RATHER THAN CLAMPED.** The store holds offsets and a
vector and no text at all (VEC‑32), so a passage is a substring, memoised per
document. The offsets are into the string the extractor returned for a
PARTICULAR version (CHUNK‑1) and `repo-text-for` is keyed by object alone; the
scan's join makes the two agree in every state a workflow can produce, so
reaching the mismatch means something raced. Both wrong answers are worse than
nothing: a clamped substring quotes characters the vector was never made from,
and an unclamped one RAISES and takes a whole search down over one document.
`embed-one` refuses the symmetric case at write time in the same words.

**VEC‑38 — THE TOOL ANSWERS STRUCTURE, NOT PROSE WITH CITATIONS**, and `kg_query`
is the precedent it is weighed against: that one answers in text with `[key]`
citations because an entity's answer IS a sentence. A passage's is not. The whole
point of carrying offsets is that a citation be MACHINE-READABLE —
`spans-covering` turns one into a page and a bbox — and flattening them into
prose leaves a model retyping a key it was handed, which is the one step in a
citation that can silently be wrong. The agent boundary JSON-encodes a non-string
result, so a model sees a JSON array and a workflow's `map #:over` gets the real
list: `repo_list_unindexed`'s documented contract.

**VEC‑39 — THE THREE WAYS THE SEMANTIC HALF CAN BE UNAVAILABLE ARE A CLOSED
VOCABULARY, NOT AN EXCEPTION MESSAGE** (`unconfigured` / `forbidden` /
`unavailable`). `embed-exchange` classifies a transport failure and FEED‑6
redacts the URL, but the message is still somebody else's gateway talking, and
#123's line is that a reply may carry what the CALLER supplied and not what we
choked on. A short label is also the only form a client can branch on.
`semantic_reason` is present exactly when the half was ASKED FOR and did not run,
never when it ran and matched nothing — QUOTA‑3's rule — and a search that did
not ask carries no `semantic` field at all.

**VEC‑40 — A SEMANTIC SNIPPET IS THE PASSAGE'S HEAD, NOT A WINDOW ON A MATCH**,
and that difference is the feature rather than a shortcut. `snippet` centres on
the query substring because for a keyword hit there IS one; a passage was chosen
for its meaning and may not contain a single word of the question, so there is
nothing to centre on and pretending otherwise puts the ellipses where they imply
a match. The full passage is reachable from the offsets the row carries.

**AND IT IS THE FIRST CONTENT SEARCH THAT SURVIVES `TMACH_ENCRYPT_CONTENT`.**
#83 seals `repo_text.content`, so the keyword half's `LIKE` is dropped and
`content_search` reports false — that is ENC‑3, and it has been the cost of the
privacy-first switch since it shipped. The semantic half compares VECTORS and
reads the text back through `repo-text-for`, which unseals, so on a sealed
instance it is the only way left to search inside a document and it still works.
A case asserts both halves in one fixture: the keyword search finds nothing and
the semantic one finds the passage in plaintext.

### What the end-to-end gate taught, which three red runs paid for

- **`doc-pipeline-smoke.sh` §8 IS THE ONLY PLACE THE EMBEDDING WIRE IS DRIVEN END
  TO END, ANYWHERE.** Every unit test of #189 scripts `current-doc-embed`, which
  is the right trade for a suite that must not need `nomic-embed-text` — and it
  means `embed-exchange`'s own HTTP path and the whole chain from a question to a
  cited passage were exercised nowhere. #187's lesson, where the one defect that
  existed only on the streaming path survived a year for exactly that reason. So
  `test/mock-llm.rkt` serves `/v1/embeddings` now (a request carrying `input` and
  no `messages`), answering a deterministic BAG OF WORDS.
- **THE MOCK'S WIDTH IS A FIXTURE PARAMETER THAT DECIDES WHETHER THE GATE CAN
  DISTINGUISH ANYTHING.** It was 32 dimensions first. Words collide into buckets,
  so a long text covers most of them and scores respectably against any query:
  measured, a 440-byte JSON classification record scored **0.276** against
  "cephalopods with arms" where the sentence actually containing both words
  scored **0.144** — the gate ranked a machine-generated record above the answer.
  256 makes a collision between two specific words unlikely.
- **BOTH WORKFLOWS HAVE TO BE DRAINED, and what that looked like was a ranking
  problem.** By that point the suite holds well over twenty-five documents, every
  earlier section having left derived `.classification.json` and `.form.md`
  objects behind, and both listers are bounded (`LIST-BATCH` 40, `EMBED-BATCH` 25)
  and ordered `updated_at` **ASC** — oldest first. So two documents uploaded a
  moment earlier sit at the BACK of the queue and one run of each never reaches
  them. The retrieval then returned plausible, badly-ranked passages from other
  sections' fixtures, because the right answer was simply not in the index.
- **AND DRAINING BROKE A BLOCK 250 LINES AWAY.** With many more documents
  carrying extracted text, the knowledge-graph extraction's own batch spread over
  a different set and "carol sees Acme too" failed — a block with nothing to do
  with retrieval. The file's own recorded lesson, a fixture that changes GLOBAL
  state breaking a distant one, and the same remedy: the section is **last** now.
- **A CORE TOOL WITH NO PLUGIN BEHIND IT IS ABSENT FROM THE GENERATED REFERENCE.**
  `cli/telemachus-docs.rkt` lists its tool modules by hand, and step 4's two tools
  reach `tools.md` anyway because `doc-indexer` requires `embed-tools` for its
  workflows. Nothing owns a workflow over `repo_retrieve`, so it was registered
  only by `server/main.rkt` — live on every instance and missing from the docs,
  with the drift gate GREEN because the committed page was rendered in that same
  state. #110 r3's side-effect-require trap, met from the generator's side.

## HELP — the in-product help corpus and its read (issue #183, slice 1, built 29 Oct 2026)

#183 asks for in-product help as a chat box grounded in this repository's own
documentation, and names four decisions to make before building. This slice makes
them and builds the half they decide: the corpus, its ingest and the
nearest-passage read. The ANSWER — the prompt, the refusal, the route and the
console panel — is slice 2, specified at the end of
`docs/design/in-product-help.md`. **No route, no permission, no console code and
no new environment variable**: migration `0065-help-corpus`,
`domain/help/{helpstore,helpindex,helpsearch}.rkt` and
`cli/telemachus-help.rkt`.

| # | Decision | Taken | Why |
|---|---|---|---|
| **HELP‑1** | Who runs the ingest | **An operator CLI** · vs a workflow, a trigger, a boot step | Every model-backed workflow here runs as a principal and bills a team; the corpus belongs to no team, and this platform has **no instance-tier quota subject** — `quotas.md` and #113's note both say so. So an ingest is out of band, beside `telemachus-secrets rewrap` and `telemachus-anchor emit`. What it costs is stated: the requests are charged to nobody. They ARE logged, and that took finding — `model-request-logger` is a box `server/main.rkt` fills, so the first working ingest wrote 111 requests to a model endpoint and logged NONE, which `log-model-request!`'s own swallow (RED‑17) made silent. The CLI installs a logger; the fix was the logger, not the sentence that claimed it. |
| **HELP‑2** | Where the documents come from | **A tree the operator names, ingested into the database** · vs read off disk at request time or at boot | A MEASUREMENT decided it. `nix/telemachus.nix` sets `src = ../refimpl/racketmaximus`, so `docs/` is in neither the store nor the image: a boot-time read works in every checkout and finds nothing on every packaged install — #119's shape exactly, a feature reporting healthy and doing nothing. Adding `docs/` to the derivation puts the committed book PDF and nineteen chapters of art into an image whose size `container.md` guards twice. The corpus therefore lives in the DATABASE, which travels with the instance, and `telemachus-help` is packaged so an operator needs no build toolchain to fill it. |
| **HELP‑3** | Whose rows they are | **The instance's, in `help_docs`/`help_chunks`** · vs a team's repository documents | `repo_objects.team_id` is NOT NULL, so the shipped manual would be ingested **once per team**, charged to each team's `storage.bytes`, listed in each team's documents and search, and offered to its knowledge-graph extraction. A plugin was the other candidate and cannot be: a plugin may not add a permission to the catalog (MTX‑9), own a sealed column (FEED‑5), add a quota dimension or add a console tab, and slice 2 needs three of the four. |
| **HELP‑4** | What makes a document stale | **sha1 of the file's text, per path** · vs a version chain, an mtime | A repository document is versioned because somebody uploaded a new one; a documentation file simply differs from what was ingested last time. That is the rule `locales/ja.json` and the screenshot caption catalogs already live by, and `source-hash` is already the one place it is spelled. An mtime moves on a fresh `git clone` and would re-embed the whole corpus for nothing. |
| **HELP‑5** | Is the vector sealed | **No** · vs `#:bytes` as `repo_chunks.vector` is | The one deliberate divergence from #189's schema, so it is pinned by a test rather than left to read as a forgotten seal. VEC‑3 seals that column because embedding inversion recovers much of a chunk's source text and the source is a team's own document. Here the source is the product's **published** documentation: an inversion that recovered it perfectly would recover a web page. Sealing would protect nothing and would add a column `telemachus-secrets rewrap` must walk — which is how a sealed value becomes silently unrotatable. The case runs with a key configured AND `TMACH_ENCRYPT_CONTENT` on, which is exactly when a content column seals. |
| **HELP‑6** | What is embedded | **`title / heading / text`, while the offsets quote the raw chunk** · vs the bare chunk | A chunk in the middle of a runbook reads "set it to 1 and restart"; the words that make it findable are hundreds of characters above it, in no chunk that contains the answer. The cost is real and is stated where somebody would otherwise meet it by surprise: **a chunk's vector is of more than the chunk cites**, so a passage can be retrieved for a word that appears only in its heading. The first chunk of a document has no heading above it — nothing precedes offset 0 — which is the second reason the title is in the composition. |
| **HELP‑7** | Authorization per row | **None, and that is the shape of the feature** · vs `can?`, as `chunks-nearest` must | A paragraph of `docs/ops/container.md` is the manual for the software the asker is signed in to. So there is no per-row filter to get wrong, and — the part worth noticing — **VEC‑28's authorization headroom disappears with it**, and with it the one approximation #189's read had to make. `k` candidates are scored and `k` are answered. What remains is slice 2's: asking costs a model request, so the ROUTE is gated on `chat:use` (VEC‑35's rule), which is about spending and not about the documents. |
| **HELP‑8** | The write's unit | **One path, one transaction, replaced wholesale** · vs per-chunk upserts | VEC‑21 unchanged: a half-written set is a document whose chunks 0–4 index today's text and 5–11 last release's, and nothing downstream can detect it — the model matches, the widths match, and the offsets point into a string that changed underneath them. |
| **HELP‑9** | Re-ingesting | **An unchanged file costs no model request** · vs always re-embed | 1,568 chunks is 111 embedding requests; editing one runbook should be one. Measured: a second ingest of `docs/ops` makes **zero** requests and does not call the embedder at all. `--force` exists because changing the chunk SIZE does not change the model name and so cannot be detected, unlike a model change (EMB‑8), which `status` warns about and which needs `clear` first. |
| **HELP‑10** | Finding a locale in a path | **A closed set, matched as a directory segment or a `.xx.md` suffix** · vs a two-letter grammar | Both spellings are real here (`docs/book/ja/…`, `docs/reference/ja/…`, `README.ja.md`). The set is the catalogs this build actually ships — `available-locales`, exported for this second asker — which is the `available` rule: an instance must not build a help corpus in a language it cannot render one string of. A grammar would read any two-character directory as a language, and a mis-tagged document is INVISIBLE: never retrieved for the locale that should have found it. |
| **HELP‑11** | The window cap | **20,000, which is sixteen times the corpus** · vs VEC‑26's 50,000 | A different kind of number from VEC‑26's, which is deliberately equal to the scale at which `vector-store.md` says to reconsider the design, because a team's document count is unbounded. This corpus is the project's own documentation — measured at 1,568 chunks — so a truncating window would mean the documentation had outgrown the assumption. `truncated` is reported for that reason. |
| **HELP‑12** | The locale of an answer | **An exact SQL filter, a fallback, and the report says which locale answered** · vs one pooled corpus | The console ships in Japanese; a Japanese operator asking a Japanese question should be answered out of the Japanese pages. What is NOT claimed is cross-lingual retrieval: whether `nomic-embed-text` puts a Japanese question near its English answer is unmeasured, and relying on it quietly would be the confident wrong answer CHUNK‑2 warns about. A silent fallback is worse than an obviously untranslated page — the screenshot captions' own rule — so the fallback is named in the result. |
| **HELP‑13** | A passage whose text moved | **Dropped and counted** · vs clamped, vs raising | VEC‑37, unchanged: a clamped substring quotes characters the vector was never made from, which is wrong in the one way a citation must not be; raising takes a whole answer down over one file. `help-replace-doc!` writes text and chunks in one transaction, so a mismatch means something raced an ingest. |
| **HELP‑14** | What a citation carries | **path, title, heading, character range — and the text** · vs an id, vs prose | CHUNK‑1 is why this is free: the chunker indexes the string it was given and the store keeps that same string, so a hit resolves to a substring with no mapping in between. The path is relative to the tree the operator named, because an absolute one names a directory on a machine the reader has no access to. |

### What the slice measured, against the real embedder

On the test lab box, `nomic-embed-text` through ollama on loopback, ingesting
`docs/` plus both READMEs from empty:

| | documents | chunks |
|---|---|---|
| English | 65 | **1,427** |
| Japanese | 27 | **178** |
| total | **92** | **1,605** |

**114 embedding requests, 29.7 s wall**; **zero** requests for a re-ingest that
finds nothing changed. A vector row is 3,072 bytes (768 float32), so the corpus
is ~4.9 MB of vectors. The ingested set matches the tree exactly, checked by
diffing `help_docs.path` against the tree rather than by trusting the count.

`vector-store.md` estimated **1,159** English chunks; the real chunker gives
**1,427** for 65 files, because CHUNK‑3's boundary search ends a chunk at the last
sentence break inside its window — slightly shorter chunks, a few more of them.
Within 20%.

**The scan is ~55 ms for 1,427 chunks and ~6 ms for 178**, end to end. That is
slower per chunk than #189 step 1's pure-arithmetic 76 ms at 10,000, which says
the **row read dominates at this size** — so `HELP-SCAN` bounds a read, and an
index is not the thing to reach for first.

**Two of six real probes are worth recording.** "Why does my container
healthcheck always report unhealthy?" found the right FILE and the wrong SECTION
(0.576), with `decisions.md`'s BLOB‑7 "boot health check" second — a different
sense of the same word. And **"認可はどのように決まるのですか？" retrieved
`docs/book/ja/14-secrets.md` while `docs/book/ja/04-authz.md`, the chapter
titled 認可のモデル, did not appear at all** — which is CHUNK‑2's predicted shape
arriving as evidence: a 1,024-character chunk of Japanese carries roughly four
times the tokens the English-derived default intends, so a Japanese chunk is a
much larger span of meaning and a short question matches it less sharply. **This
is the first real datum for #189 step 3's calibration, and the corpus is now a
set of questions with known right answers to make it against.**

Japanese against Japanese otherwise worked and scored the highest of the six
(0.805 for the job-queue chapter). An English question asked under
`#:locale "ja"` is answered out of the Japanese directories **in English**,
because the generated reference is English where untranslated — HELP‑12's filter
doing what it says, and the reason cross-lingual stays unclaimed.

### Three things this slice paid for

- **THE REQUEST LOG IS A BOX A CLI DOES NOT FILL, AND THE SWALLOW HIDES IT.**
  The module header said an ingest's requests were logged; they were not, and
  nothing failed — `log-model-request!` catches its own failures so an unwritable
  log never costs anybody their answer (RED‑17), and an EMPTY box is not even a
  failure. Found by reading `model_requests` after the first working ingest and
  seeing nothing at all. Any future CLI that makes a model request has the same
  hole.
- **THE SCRIPTED EMBEDDER'S TOKENIZER DECIDED WHETHER THE JAPANESE CASES COULD
  EXIST.** `[[:alnum:]]` is ASCII-only here, so a bag of words built by splitting
  on its complement reduced every Japanese fixture to **no words and a zero
  vector** — which `help-replace-doc!` correctly refuses (VEC‑22), so twelve of
  fifteen cases failed naming the Japanese README. The fixture was the problem and
  the refusal was right. A per-character bag is the stand-in for a language with
  no spaces.
- **`check-true` ON `member` AGAIN**, the fourth appearance in these suites: it
  demands exactly `#t` and `member` answers a tail, so the case fails while
  printing the list that proves it right. `(and … #t)`.

All twelve positive controls bite: the locale rule, the staleness hash,
`--no-prune`, the title/heading composition, the heading scan, the empty-file
record, the model filter in SQL, the directionless refusal, the locale fallback,
the moved-text drop, `help-available?`'s reasons, and the stored form.

## HELP (continued) — the answer, and what it refuses (issue #183, slice 2, built 29 Oct 2026)

Slice 1 built the corpus and the nearest-passage read; this is the half #183 is
actually asking for — "it must cite, and it must be able to say 'I don't know'.
An answer invented about an operator's own platform is worse than silence."
`domain/help/answer.rkt`, `POST /api/help` (`server/api/help.rkt`),
`ai.help.total`, `help` on `GET /api/whoami`, and the console overlay
`static/console/17-help.js`. **No migration.**

| # | Decision | Taken | Why |
|---|---|---|---|
| **HELP‑15** | How "I don't know" is decided | **TWO LAYERS: a score floor before any model call, and citation resolution after it** · vs a prompt instruction alone, vs a relevance threshold | Neither layer is sufficient. The floor answers "is there anything in this documentation at all near this question", which is what makes a refusal cost nothing — and it CANNOT be a relevance test, which slice 1's probe proved: the Japanese question that missed its chapter entirely still had a top hit at **0.651**, higher than the English question that found the right file at 0.576. So the floor is deliberately low (0.35) and **provisional**, with what would move it written at its definition — a recall measurement over a question set with known answers, in both languages, which is #189 step 3's calibration and the same sitting. `#:floor` is an argument rather than a constant read at the call, because a calibration has to sweep it and no test of anything else should depend on today's value. |
| **HELP‑16** | What makes a citation real | **Every cited path is resolved against the passages actually retrieved** · vs trusting the model, vs demanding a verbatim substring | A model told to cite sometimes invents a plausible file, and that is the one failure this feature cannot have: a reader who follows a citation to a file that says something else is worse off than one who got no answer. A path the retrieval never offered is DROPPED and reported in `invented_citations`. The KG extractor can demand a verbatim substring because it extracts SPANS; a prose answer has no such invariant, so this is as far as verification can honestly go — and the honesty is why `uncited` is reported rather than hidden. |
| **HELP‑17** | The answer's form | **Prose with `[path]` markers, plus citations resolved alongside** · vs `response_format: json_schema` | VEC‑38 made the opposite call for `repo_retrieve` and both are right for their reader: that one answers a MODEL, so a machine-readable citation matters; this one answers a PERSON in a panel. And a schema here would be a liability — most local servers ignore `response_format`, so a model that cannot produce the object would make help fail outright, where a model that cannot produce a bracket still produces a readable answer with no citations and says so. The structured citations come back beside the prose, resolved from the retrieved hits rather than retyped by the model. |
| **HELP‑18** | Where the prompt's language goes | **The system prompt is English; the ANSWER's language is named in it** · vs a localized system prompt | The system prompt is an instruction to a model, not copy anybody reads, so localizing it would put a translation on the critical path of every answer for no reader. The retrieval locale and the answer locale are the same one, and the response says which locale answered (HELP‑12). |
| **HELP‑19** | How a failure is reported | **A closed vocabulary, 200, never an exception message** · vs a 4xx/5xx per cause | #123's line and VEC‑39's: `unconfigured` / `empty` / `locale-empty` / `no-model` / `nothing-relevant` / `uncited`. The request was well-formed and the server did its job, so the status is 200 and the body carries the reason a client branches on. `reason` is ABSENT (null) when the question was answered — QUOTA‑3's rule, so a caller tests for absence rather than for a sentinel. |
| **HELP‑20** | With no chat model | **The PASSAGES come back, with `no-model`** · vs an error | `content_search: false`'s posture: report what did not run, keep what did. A reader handed three cited passages out of the documentation is better off than one handed an error, and on an instance with an embedder and no chat model that is the whole of what help can be. |
| **HELP‑21** | What a question costs | **`ai.help.total` (its own dimension, no default limit) and `ai.requests`, and deliberately NOT `ai.tokens.total`** · vs the completion budget, vs free | #183's question 3 answered. The shipped `ai.tokens.total` default is 2,000/day, so a question or three exhausts it and "help that stops working at lunchtime is worse than no help" — the issue's own words. Its own dimension is EMB‑6's and JUDGE‑10's shape: a cost with no sensible home gets a dimension rather than being folded into somebody else's budget. `ai.requests` IS charged because the dimension counts calls to a model and this is two of them, and its 200/day default is a real bound that is not the one that would hurt. **What that does not bound is stated**: a team with no `ai.help.total` limit can spend provider tokens on help without it appearing in the completion budget an operator reads as spend, and the remedy is to set the limit the dimension exists for. In `QUOTA-HOLD-DIMS` and on `GET /api/usage`. |

### HELP‑22 — an answer that cites every passage it was shown has cited nothing

**Found by the only real-model run there has been**, which is the argument for
having made one. On the lab box, against the real 1,427-chunk English corpus and
`qwen2.5:7b`: asked "what is the airspeed velocity of an unladen swallow?", the
retrieval's top score was **0.488** — above the floor, because the floor is
deliberately not a relevance test (HELP‑15) — and the model then did exactly what
it was told, answering "the passages provided do not contain any information
about…". And then it named **all five** passages it had been shown, in brackets,
by way of explaining what they were about instead. HELP‑16's resolution kept five
perfectly valid citations, so the response presented a REFUSAL as a five-source
answer — in the one field this feature exists to get right.

A citation distinguishes; naming every input distinguishes nothing. So an answer
that cites all of the passages it was given is an **inventory**, reported as
`unfocused` with the citations dropped. The passages are returned anyway, so
nothing is lost; what goes is the claim that they are sources.

**Raising the floor is NOT the fix, and that is worth stating because it is the
obvious one**: the genuinely useful container-healthcheck answer scored **0.587**
against this question's **0.488**, so a floor that refused the swallow would sit
within a tenth of refusing a question somebody really asks. `HELP-INVENTORY-MIN`
is 3, because with one or two passages citing all of them is exactly what a good
answer looks like — and the first version of the test could not fire the rule at
all, because the shared fixture has only two English documents and the locale
filter meant `k = 3` could never offer three. It reported `#f` and passed for the
wrong reason until it got a tree of its own.

The other four probes in that run are the reason this is a fix and not a retreat:
the key-rotation question produced a correct five-step answer out of the secrets
runbook at 0.693, the queued-jobs question answered "a team out of AI budget" at
0.768, the container question was accurate at 0.587, and the Japanese
job-queue question answered in Japanese out of the Japanese chapter at 0.805.
Warm latency was **0.9–3.8 s**; the first call, with the model cold, took 18 s.

### The permission, and the gate that found it missing

`chat:use`, declared on the route and enforced in the handler — and the handler's
line was MISSING on the first run. **`test/route-perm-gate-tests.rkt` named it**
(`POST /api/help declares "chat:use" — not enforced anywhere reachable from
ep-help`), which is exactly the defect that gate was built for after
`GET /api/retention` shipped declaring a permission and enforcing nothing. The
route table is documentation; the handler is the enforcement.

The permission is about the SPENDING, not the documents: HELP‑7 says the corpus
needs none, because it is the manual for the software the caller is signed in to.
The smoke pins that with a **viewer**, the one built-in role that separates
`files:read` from `chat:use` — and the first version asserted against a MEMBER,
who holds both, so it passed against a correct server and said nothing.

### The console, and two things it inherited

The overlay is shell-resident like the palette's two (#182), so a tab re-render
cannot take it down mid-answer — and the documented cost is the same: **the shell
is cached at startup, so a live box needs a restart.** It hooks the one delegated
`keydown` listener AFTER `paletteKey`, and the order is asserted rather than
commented: the palette owns `Esc` while ITS overlay is open and `helpKey` claims
`Esc` only while its own is, so two handlers taking `Esc` unconditionally is how
one starts closing the other's. Asking is ONE send on #174's shape — the flag is
both the guard and the pending state, nothing awaits between the check and the
set, and the `finally` is what stops one network error leaving the button dead.

**The affordance is HIDDEN when help cannot answer**, off `S.me.help.reason`
from whoami, which the console already fetches on every render pass. A panel that
explains itself only after you press it is worse than no panel. `locale-empty` is
deliberately NOT hidden: the corpus exists and the answer arrives in another
language, which is worth offering and worth saying. `help-any?` is an EXISTENCE
test rather than a count, because whoami asks it on every pass and a `COUNT(*)`
over the corpus for a boolean is a scan.

### Three things this slice paid for

- **A SCRIPTED BAG-OF-WORDS EMBEDDER SCORES NOTHING LIKE A REAL ONE**, and five
  cases failed on it first: a seven-word question against a thirty-token passage
  scores about **0.28** over 256 buckets, where `nomic-embed-text` gives
  0.55–0.80. So the floor is passed explicitly in every case but the one that is
  ABOUT the floor. A suite that pinned a provisional constant by accident would
  turn a calibration into a test failure.
- **A PYTHON-SCRIPTED EDIT ENDED A BASH LITERAL WITH A DOUBLED QUOTE**, and bash
  then swallowed the remaining 40 lines of the smoke silently — it printed five
  passing assertions and then no verdict at all. `bash -n` catches it in
  milliseconds and the absence of the `server-smoke: PASS` line is the tell;
  "the last assertions did not run" reads nothing like a failure.
- **A CLASS THAT MATCHES NO RULE FAILS NOTHING** (#178, paid again): `.sec` is
  scoped to `.bx-ed` and `.small`/`.plain` do not exist at all. The overlay has
  three classes of its own, grepped out of the stylesheet first.

All thirteen positive controls bite: the `chat:use` enforcement, the citation
resolution, the score floor, the `no-model` branch, the `uncited` report, the
dimension, `help-cited-paths`, the prompt's only-the-passages rule, the help
hook's position in the dispatch, `helpBlocked`'s two reasons, the header button's
guard, the one-send guard and its `finally`.

## FEED (continued) — the four remaining adapters (issue #193, built 29 Oct 2026)

#114 named six sources. One had an adapter (`github.issues`, FEED‑14…22) and one
was a protocol rather than a shape (Matrix, which shipped as #133 in the
notifying direction). These are the four that were left, and #193's reading was
right: each is a parser and a registry entry. `domain/feeds/adapter-cve.rkt`,
`adapter-kuma.rkt`, `adapter-discord.rkt`, `adapter-alerts.rkt`. **No migration,
no route, no permission and no environment variable.** One shared helper moved.

| # | Decision | Taken | Why |
|---|---|---|---|
| **FEED‑23** | CVE: the `external-id` | **The CVE id, and nothing else** | Globally unique by construction, stable across revisions, and the string a person types into a search box. Unlike GitHub's issue number there is nothing to compose it with and nothing it can collide against — FEED‑16's hazard simply does not arise. |
| **FEED‑24** | CVE: one advisory, or one per affected dependency | **One advisory is one item** · vs one per package | #193's own open question. An advisory is the thing that gets published, revised and withdrawn, so it is the thing with an identity. One item per affected package would write N documents that all change together on every revision, and the dedup hash would re-version all N and charge the team's storage each time. The packages ride in the payload and in `feed_packages`, which is what a trigger filters on. |
| **FEED‑25** | CVE: the cursor | **Walk FORWARD at most 120 days per poll** · vs clamp the start, vs refuse | NVD refuses a modification range wider than 120 days and requires both dates together. A feed whose cursor is a year old therefore cannot be caught up in one request: clamping the start would silently skip a year of advisories, and refusing would leave the feed permanently broken. Walking forward with the cursor only advancing over what landed (FEED‑19) makes a year's backlog three polls rather than a gap. A FIRST poll sends no window at all, because what "everything" means is the operator's URL — choosing a start date here would be the adapter deciding how much history a team gets. |
| **FEED‑26** | CVE: the source | **NVD CVE API 2.0** · vs OSV | OSV is the better fit for "against my dependencies" and **cannot be used**: its batch query is a POST with a body, and `feed-adapter`'s `prepare` answers a URL and headers. `fetch` already takes `#:method` and `#:body`, so the gap is the ADAPTER contract rather than the transport — and widening a contract four adapters share for a source nobody has asked for yet is the wrong trade. Recorded so the next reader does not re-derive it: the day a POST source is wanted, `prepare` grows a method and a body and `poll.rkt` passes them through. |
| **FEED‑27** | Kuma: what an item IS | **A status TRANSITION, computed from the list** · vs one item per heartbeat, vs Kuma's `important` flag | #193 says "an alert is an event rather than a document that evolves", and the first reading of that is unaffordable: Kuma beats every 60 seconds per monitor, so a ten-monitor status page is 14,400 documents a day. What anybody wants is "when did it go down and when did it come back". The flag is NOT used because the status-page projection is not documented to carry it — relying on it would make the adapter silently emit nothing on a version that trims it, which is the worst failure available here. `status` and `time` are certainly present and a transition is derivable from them. |
| **FEED‑28** | Kuma: the `external-id` | **`<monitor>-<instant>`** | #193's own observation: two "down" events an hour apart are two items, not one. The consequence is worth stating — a pulled transition is immutable, so it is created once and never updated, and `feed_items` grows with the number of OUTAGES rather than with time. |
| **FEED‑29** | Kuma: the cursor | **Applied in `parse`, because the endpoint has no window** | The heartbeat endpoint answers the most recent N beats per monitor and nothing narrows it. So the cursor goes nowhere near the request. What that costs is real and bounded: a feed polled less often than Kuma's retention window loses the transitions that fell off the list, which makes an hourly cadence comfortable and a daily one not. `poll_seconds` is where an operator sets that and `polling` reports it. |
| **FEED‑30** | Discord: the cursor | **An epoch converted to a snowflake, exactly** | The first source whose window is not a time at all: `after` takes a message id, and a snowflake's top 42 bits ARE a millisecond timestamp with a fixed epoch. So this is a conversion rather than an approximation — the same shape as `github.issues` turning an epoch into ISO‑8601, which is the whole reason `prepare` takes the cursor instead of `poll.rkt` formatting one for every source. It goes back one second, because `after` is exclusive and a message in the same second as the last one stored would otherwise never be asked for. |
| **FEED‑31** | Discord: the sort | **Left alone** · vs `github.issues`' forced ascending order | Worth writing down because it looks like an omission. GitHub needed `sort=updated&direction=asc` because its cursor filtered on a field the default sort did not use, so the first page of a busy repository was the newest issues and the cursor would jump past everything older. Here the cursor IS the id, every message carries one, and `note-landed!` keeps the maximum — so a descending page advances the cursor correctly on its first element. |
| **FEED‑32** | Discord: system messages | **Kept and MARKED** (`feed_kind`) · vs filtered | `github.issues`' rule for pull requests: the operator's channel is theirs to decide about, and a trigger can tell a join from a message without parsing the payload. |
| **FEED‑33** | OTel | **NOT AN ADAPTER, and `alerts.alertmanager` instead** | OTLP is a PUSH protocol: a collector or an SDK opens a connection and POSTs at this instance. A feed POLLS. So "an OTel adapter" is the same category error #114 already found with Matrix — "a protocol rather than a shape" — and the honest shapes for OTLP arriving are an ingest endpoint and a job kind, which is its own issue. What an operator running that stack actually has that is pollable is the thing that fires when something is wrong: Prometheus Alertmanager, `GET /api/v2/alerts`. The substitution is recorded rather than quietly made. |
| **FEED‑34** | Alertmanager: the cursor | **There is none** | It answers "what is firing now" — no modification window, no `since`, no pagination. Every poll sees the whole current set, bounded by how much is broken rather than by how long the feed has existed. The cursor is stored and ignored, so an operator reading the feed can still see the poll is working. |
| **FEED‑35** | Alertmanager: the `external-id` | **`<fingerprint>-<startsAt>`** | Kuma's lesson a second time. A fingerprint identifies the LABEL SET, so the same alert firing next month carries the same fingerprint and is a different incident; keying on it alone would store the second occurrence over the first and the hash would then report a document that changes every time anything flaps. With the instant, each firing is its own immutable item — and an alert whose annotations change WHILE firing is one document that updates, which is correct. `updatedAt` is what moves it. |
| **FEED‑36** | Alertmanager: what is asked for | **`active=true&silenced=false&inhibited=false`, set by the adapter** | The API's DEFAULT includes all three, so a feed configured with the bare endpoint would pull in exactly the alerts its operator has already acknowledged or suppressed by a rule they wrote. `query-set` replaces, so an operator cannot have them back by editing the URL; that is deliberate, and the remedy is a second feed on a kind that does not filter. |

### One core change, and it is a helper rather than a contract

`query-set` is hoisted from `adapter-github.rkt` into `adapters.rkt`. Four copies
of "which query parameters are the platform's and which are the operator's" is
`executor-can-run?`'s drift in the place it would be hardest to see: a copy that
APPENDED instead of replacing would walk a window the operator chose and the
cursor did not, which looks like a source that keeps re-sending the same items.

### A control that did not bite found an order-dependence

Fifteen of sixteen bit on the first run. The sixteenth — substituting "the first
non-empty severity wins" for the rank comparison in `cve.nvd` — changed nothing,
because the scan ran in Racket's own hash order over NVD's `metrics` object and
happened to reach `cvssMetricV31` before `cvssMetricV2`. That is
`canonical-json`'s trap in a second place, and worse than cosmetic here: the
severity a trigger routes on could differ between two processes reading the same
advisory. The keys are sorted now, the walk is deterministic, and the control
bites.

### What the tests can and cannot establish

Every case is a byte string in and a list of `feed-item` out — no database and no
socket, which is FEED‑14's contract paying off. **The response shapes are from
each source's published schema and are NOT verified against a live source in this
build**, stated rather than implied, as the LibreOffice conversion branch and the
SSE round trip are: a fixture written from the same documentation as the parser
agrees with the parser by construction. What they DO establish is every rule each
adapter decides for itself — the composed identity, the cursor conversion, the
refusals and the field set — which is where #193 said the decisions were.

**And the smoke's pinned `pollable_kinds` list failed**, which is the gate
working: that assertion pins the DERIVED set as a whole, so adding four adapters
had to be a deliberate edit rather than something a suite agreed with silently.
Same argument `vocabulary-tests.rkt` makes for pinning a closed vocabulary rather
than re-deriving it.

## VOICE — voice notes: the wire, the tools, the pipeline (issue #192, slice 1, built 30 Oct 2026)

#192 asks for four things: a built-in tool for voice notes, a way to upload
offline ones, an API for streamed capture, and a pipeline that transcribes and
then lets you converse with the result. **Two of them were already mostly
built**, which is the finding and is why this slice is small. The streamed
capture API is slice 2 and is specified at the end of
`docs/design/voice-notes.md`.

`transcribe-exchange` in `domain/ai/executor.rkt`, `domain/repo/voice.rkt`,
`domain/repo/voice-tools.rkt`, `ai.transcriptions.total`, and the
**Transcribe Voice Notes** workflow in `plugins/doc-indexer/`. **No migration and
no new route.**

| # | Decision | Taken | Why |
|---|---|---|---|
| **VOICE‑1** | The endpoint and the model | **Their own pair, `TMACH_TRANSCRIBE_URL` / `_MODEL`** · vs derived from `TMACH_MODEL_URL` | EMB‑1's argument a third time and no weaker for it: a transcription model is `whisper-large-v3` or `parakeet`, never a chat model and never an embedding one, so the name cannot be shared with either — and once the name is separate the URL may as well be. Deriving the path assumes one server and would send the chat model's name to an endpoint that cannot use it. |
| **VOICE‑2** | The body | **`multipart/form-data`, through `http-post-data`** · vs a JSON spelling, vs a second transport | `/v1/audio/transcriptions` takes a file part and there is no JSON spelling of it in the OpenAI shape; inventing one would mean picking the providers that accept base64 and excluding the rest. `http-post-json` is now a thin wrapper over `http-post-data`, so the encoding is the only thing that differs — a second copy of the open/deadline/dynamic-wind/retry shape would reintroduce the descriptor leak `llm.rkt`'s header was written about, for the request kind carrying the LARGEST body. The boundary is checked against the payload, not merely randomised: a collision truncates the part, and what that produces is not an error but a shorter transcript. |
| **VOICE‑3** | What the request log records | **The filename and the byte count; never the audio, never the transcript** | `log-model-request!` digests its `messages` (RED‑18), and audio is not a message — a digest of 40 MB of it is an HMAC nobody can reproduce or compare, which is the opposite of what a digest is for. The filename and size are enough for an operator auditing egress to see what left and how much of it, and cannot reconstruct a word. The transcript stays out because it is content and the row is the record that a request was made. |
| **VOICE‑4** | An empty answer | **`""` is an answer; a missing `text` key is an error** | Silence really does transcribe to empty and a recording of a quiet room is a legitimate voice note. A response with no `text` at all is a proxy, a gateway or a different API — treating it as silence would store an empty transcript for a recording that was never read. `content->text`'s rule: an empty answer must never be manufactured. |
| **VOICE‑5** | Which types | **A closed list, not `audio/*`** · and `video/*` excluded | A prefix match claims every format anybody invents, and the endpoint picks its decoder from the filename EXTENSION — so a type with no extension in the table would be posted as `.bin` and refused by the far end with a message about the format rather than about the type. `video/*` is a different decision: a screen recording carries pictures this platform would be discarding silently, and "which audio stream?" has no answer a closed list can give. |
| **VOICE‑6** | The posted filename | **Derived from the content type, never from the key** | Two reasons and the second is the one that matters: a key is somebody else's string and it becomes part of a multipart header, where a newline would ADD a header — the injection `fetch` refuses for its own headers. And a key need not carry an extension at all, while every OpenAI-compatible server picks its decoder from one. So it is `voice-note.<ext>` and the document's identity stays in the row. |
| **VOICE‑8** | Uploading an offline note | **Already true; no code** | `PUT /api/repo/<key>` with an `audio/*` content type. The repository takes any format in and `web-kit/http1` moves it. What requirement 2 needed was for the thing to be worth uploading. |
| **VOICE‑9** | Where the transcript goes | **`repo_text`** · vs a derived `<key>.transcript.txt` | `doc_redact` writes a derived document because RED‑8's point was that a person must audit what would have been sent. A transcript is not a copy of anything — it is the text OF the recording, which is what `repo_text` is for. And it is what makes requirement 4's "converse with data" need NOTHING: keyword search, the knowledge graph, `?semantic=1` and `doc_extract_fields` all already read that column. A derived document would double the storage and give search two hits for one recording. |
| **VOICE‑10** | A tool, or an extractor | **A tool** · vs `register-extractor!` on the audio types | LAY‑7's registry is the obvious home and would make a recording searchable through the indexing workflow with nothing changed. But an extractor's contract is `(port content-type) -> (values text reason)` — no connection, no principal — and a transcription is a model request against somebody's budget. `chunkstore.rkt` takes its vectors as an argument for exactly this reason: metering can only happen where the principal is. |
| **VOICE‑11** | What it costs | **`ai.transcriptions.total`, counting RECORDINGS, no default limit** · vs tokens, vs seconds of audio | A transcription returns no tokens at all, so `ai.tokens.total` could not measure it even if it should. Seconds of audio is worse than it sounds: the duration is known only if the endpoint reports it, so the dimension would read 0 for every server answering plain `json`. Recordings is the unit an operator can reason about. In `QUOTA-HOLD-DIMS`; `ai.requests` charged beside it. |
| **VOICE‑12** | A lister of its own | **Yes** · vs reusing `repo_list_unindexed` | That one filters on `extractable?`, which audio is not — so a voice note is invisible to it, and correctly: the indexing workflow would otherwise fan out over recordings it cannot read and fail a step on each. This window is the same question narrowed to `AUDIO-TYPES`, with `can?` per row for the reason #189 step 4 found the hard way. |
| **VOICE‑13** | A document that is not audio | **Refused before the wire, by name** | A PDF posted to a transcription endpoint comes back as whatever that server says about a file it cannot decode, which names its internals rather than the caller's mistake (`doc_fill_form`'s reason for refusing by content type first) — and it would have spent the request. |
| **VOICE‑14** | A silent recording | **Recorded, not raised** | Raising would fail the step, and the next run would list the same object and fail again: one silent recording wedging the team's transcription for ever. `repo_extract_text`'s own `else` branch. The row keyed to this version is what stops it being offered again; a re-upload makes it eligible. |

### A third workflow, and the order is the opposite of the other two

`transcribe-documents` is separate for VEC‑24's reason once more — a step that
errors fails the RUN, and `doc_transcribe` refuses without an endpoint that is
unset on every instance today, so appending it to either existing workflow would
make indexing start failing everywhere. And it runs **first** for a voice note,
where embed runs second for a text document: a recording has no text until this
has run, so Index Documents has nothing to extract and Embed Documents has
nothing to chunk. The workflow description says so and the smoke asserts the
recording is not findable before.

### Two things this slice paid for

- **`pregexp` HAS NO `\r` OR `\n` ESCAPE, AND THE FAILURE WAS AT MODULE
  INSTANTIATION.** `test/mock-llm.rkt`'s multipart reader was written with
  `"\\r?\\n"`, which raises `illegal alphabetic escape` when the pattern is
  compiled — at module level, so **the mock server never started**. What that
  looked like was `connection refused` on the model port and 30 failing
  assertions across four sections of `doc-pipeline-smoke.sh` that have nothing to
  do with voice notes, including a knowledge-graph block reporting
  `unextracted: 34`. `raco make` stayed green throughout, which is this project's
  own recorded shape for a plugin that compiles and will not load. Real CR and LF
  characters, built with `string-append`.
- **AND THE PLUGIN BYTECODE WAS STALE, which is the same lesson from the other
  side.** Changing `executor.rkt`'s exports left `plugins/feeds/compiled/*.zo`
  linking a `run-chat` that no longer existed, so the feeds plugin failed to load
  and nine assertions failed naming feeds. `raco make server/main.rkt` does not
  reach a `dynamic-require`d plugin: `find . -name compiled -type d -prune -exec
  rm -rf {} +` after touching anything a plugin requires.

### Two controls that cannot bite, and both are stated rather than papered over

Eleven of thirteen bite. The two that do not:

- **The boundary collision check.** The boundary is 64 random bits, so a fixture
  cannot contain one — neutralising the check changes no assertion, and
  falsifying it would need the generator seeded. VEC‑13's unpinnable pin: a
  reason to write the check down, not a reason it is redundant, and it costs one
  scan of bytes already in memory.
- **The fields-before-file ORDER.** That the fields are written, that the file
  part has its own headers and that the body closes are each controlled and each
  bite; the ORDER itself is asserted and is not independently falsifiable by a
  string patch. The order exists so a provider that streams the parse can refuse
  an unknown model without reading a 40 MB body.

And the request log's `REQUEST-OPERATIONS` is pinned as a whole list, so adding
`"transcribe"` failed `embed-tests.rkt` — the gate working, a third kind of
model request being a deliberate edit rather than a string that arrives and is
never explained.

## STG — streamed capture: an upload assembled from chunks (issue #192, slice 2, built 30 Oct 2026)

#192's requirement 3, and **the protocol already existed**. The S3 listener has
staged multipart uploads since slice 52 and reaped abandoned ones since #54:
numbered parts, each its own content-addressed blob, assembled at Complete
through `input-port-append` into the same `repo-put!` a single-shot PUT uses,
charged against `storage.bytes` on arrival and refunded in one place (S3‑8). What
#192 wants — chunk by chunk, with a failed chunk retried rather than the whole
recording re-sent — is that, and it was reachable only through SigV4.

`domain/repo/staging.rkt` (extracted), `server/api/staged.rkt`, five routes.
**No migration.**

| # | Decision | Taken | Why |
|---|---|---|---|
| **STG‑1** | Where the protocol lives | **Extracted to `domain/repo/staging.rkt`; the S3 listener delegates** · vs a second implementation on the JSON plane | The move `release-blob!` already made in that same file when it got a second asker, and its own comment is the argument: "two implementations of one rule, each missing a different half, which is why there is one now and it lives with the tables it reads." Three routes and NO new storage, because the refund, the reap, the retry-replaces rule and the assembly are all shared. **The S3 suites and `s3-smoke.sh` passing unchanged with the real `aws` CLI is what says the extraction was behaviour-preserving** — #110 r7's characterisation argument, where the tests existed before the change. |
| **STG‑2** | A minimum part size | **None, and S3's 5 MiB floor is NOT inherited** · but the part COUNT is bounded at 10,000 | That floor is AWS's, enforced by AWS, and the listener never checked it either. A 60-second chunk of 16 kbps opus is about 120 KB, so a floor would make the obvious client impossible. What needed bounding is the count: `max-upload-bytes` caps one part and nothing capped their number, which is the hole S3‑8's charge-on-arrival closed for BYTES — ten thousand 1-byte parts is a cheap way to make Complete chain ten thousand ports. 10,000 is AWS's own part limit, so it is a number a client author has already read. A REPLACEMENT is exempt, or a client that reaches the ceiling can no longer recover a chunk. |
| **STG‑3** | The route names | **`/api/uploads`, not `/api/voice-notes`** | The chunking has nothing to do with audio: it is "a thing being recorded or produced while it is uploaded", equally a long export, a camera roll or a database dump. Naming it for voice notes would have been a second upload API the first time anybody wanted one for something else — the shape #114 avoided by making feed adapters a registry rather than a `cond`. What IS voice-specific is the content type the caller sends and the trigger that fires afterwards. |
| **STG‑4** | When the key is validated | **At Begin, in the MODULE** · vs at Complete, vs in the route | `repo-put!` validates it too and would refuse at the END — after the client had uploaded the whole recording, which for a long voice note is minutes of somebody's time and a storage charge that then has to be refunded. The same argument `doc_fill_form` makes for refusing by content type before reaching the engine. **A control is what moved it from the route into the module**: it reported no bite, because no unit case began an upload with a bad key — and putting it in the module also fixed the S3 listener, whose Initiate did not validate either, so `aws` could begin a multipart upload to a key that could never be completed. |
| **STG‑5** | How a part is addressed | **The number is in the path** · vs an append-only `POST .../parts` | Append-only is simpler and wrong for the one failure this exists to survive: a chunk whose request fails must be sent again, and with an implied position a retry either duplicates it or is indistinguishable from the next chunk. Numbered, a retry REPLACES — `UNIQUE(upload_id, part_number)` and the upsert — so a flaky connection costs one chunk rather than the recording. `GET /api/uploads/:id` is the resume read that makes that usable: the parts it lists are the ones a client need not send again. |
| **STG‑6** | Who decides the order | **The platform, ascending** · vs the client's list, as S3 takes | There it must be the client's: parts arrive concurrently from `aws s3 cp`'s parallel workers and only the client knows which byte range each one was. A streamed capture has ONE writer producing chunks in time order, so ascending IS the order, and accepting a list would be offering a way to assemble a recording wrong. `staging-complete!` takes the order as an argument and the JSON surface passes `#f`. |

### The reaper moved with the tables, and that matters

`reap-uploads!` lived in `domain/s3/server.rkt` — **a listener that is off by
default.** The sweep always rode the pool's reaper seam rather than the listener,
which was S3‑7's own decision ("an instance that staged parts and then turned it
off would hold those bytes for ever"); now that a second surface stages uploads
with the listener possibly never instantiated at all, the sweep lives where the
rows do. `server/main.rkt` and `test/upload-reap-tests.rkt` name the new module
directly rather than reaching it through a re-export, which is #110 r3's
`SOURCES` lesson: a test that keeps naming the old module goes on passing while
reading something that no longer holds the code.

### The permission gate flagged these routes, and the answer was not to relabel them

`route-perm-gate-tests.rkt` refuses a `files:*` route whose path carries an `:id`
and is ROLE-scoped, because a grant would stop admitting. All five of these
tripped it, and the heuristic is a false positive here: that id is an UPLOAD id,
and a grant is on a repository object or a note — nothing grants anything on a
staged upload. The row is scoped to the caller's own team and the only check is
the role, **which is the same check `repo-put!` makes on its FIRST LINE** before
any resource weighing, so a staged write and a single-shot
`PUT /api/repo/<key>` admit exactly the same callers (asserted, in
`staging-tests.rkt` case 10, against both functions).

So `/api/uploads` is exempt BY NAME — the shape that file already uses for the
prefix delete rather than a pattern that would excuse a class. Were grants ever to
reach an upload, that line is what would have to be revisited, which is the point
of naming it.

### A control that cannot bite, and one that found a test gap

Thirteen of fourteen bite. The one that does not is the **default ascending
sort**: removing it fails nothing, tried with three parts and again with twelve
scrambled ones, because Racket's `hash-keys` on small integer keys happens to come
back ascending for a hash that size. VEC‑13's unpinnable pin, the third
appearance of that shape in these suites — a reason to write the sort down rather
than a reason it is redundant, since the hash's order is not a documented
property. What IS pinned is that an **explicit** order is honoured, which is the
S3 surface's case and the only one where the order is somebody's choice.

And two of the three that reported no bite on the first run were test gaps rather
than code problems, which is the useful half:

- **The released blob on a refused part.** The quota figure cannot see it: the
  charge happens AFTER the admission check, so removing the release leaves the
  number right and the bytes leaked — and nothing would ever collect them, because
  #122's sweep reads `repo_blob_staging` and a part is not recorded there. The case
  checks the store by digest now.
- **The key check**, which is STG‑4 above.
