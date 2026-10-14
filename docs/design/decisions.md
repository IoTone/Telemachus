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

**Still open after this, deliberately.** A worker cannot report that it is READY
or PAUSED — executor health is derived from `last_seen_at`, so a busy or paused
box looks idle. That is a wire change on both sides (a worker state the claim
loop reports and the executor row records) and belongs in its own slice, not
bolted onto a defect sweep. Also unbuilt: a purge for finished jobs' payloads
and results, worker-token expiry with a rotation overlap, a releasable claim
that does not spend an attempt, and writable derived objects from a worker
result — all four were questions on #54 rather than defects, and each needs a
decision of its own before code.

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

## Typed judgments, and TypeSafe AI's JEV (JUDGE) — **explored 14 Oct 2026** (issue #31)

Issue #31 asked whether to use TypeSafe AI's JEV, a hosted "System One" decision
model (`POST https://api.typesafe.ai/v1/systemone`). **Only JUDGE‑6 is built** —
the one item that turned out to be a defect rather than a design question. The
recommendation on the rest is deliberately not "integrate it" or "do not": it is
that the platform is missing a *seam*, that JEV is a good second backend for that
seam, and that it cannot be the first one.

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
| 🔑 **RSCH‑3** | Egress | **A per-team feature flag, and a fetcher that refuses private address space with DNS resolved ONCE and the connection pinned to the resolved address** · vs trusting the URLs the model chose · vs search snippets only, no fetch | Today every outbound request goes to an endpoint the **operator** configured — the model URL, `executors.json`, an MCP server. A research loop would be the first thing to fetch a URL a *model* picked out of a *search result*, which turns the server into an SSRF proxy onto its own network: the cloud metadata endpoint, the database, the ArangoDB on 8529. "Nothing is trusted for looking private" is the call `domain/authz/peer.rkt` already made for inbound identity; this is the same rule pointed outward. Resolving the name twice is the rebinding hole, so resolve once and connect to the address. This is the row that gates the feature for a privacy-first, self-hosted product. |
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
