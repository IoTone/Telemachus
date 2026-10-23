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
adopt Telemachus without doing the packaging themselves: deployment was Nix-only,
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
| **DEPLOY‑12** | MinIO in the compose file | **Left out, with the reason written down** · vs including it · vs silence | Issue #89 asks for it. Telemachus SERVES an S3 API but cannot yet STORE blobs in a bucket — an S3-compatible blob-store backend is issue #82, unbuilt — so a MinIO container today would be a service nothing talks to. That reads as a broken example rather than a staged one, and the acceptance criterion's MinIO half genuinely depends on #82 rather than on this slice. |

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
Telemachus from a queued worker — the shape the issue describes — a retry is not
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

An integrator running Telemachus headless as a document-processing service feeds
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
| 🔑 **JUDGE‑8** | How it is reached | **A remote JOB KIND and a pull worker — no new wire, no plugin** · vs a push executor with a second protocol · vs JUDGE‑3's plugin · vs in-process | Supersedes JUDGE‑3, in a cheaper direction. JUDGE‑3 was right that `model-exchange` is single-wire OpenAI chat-completions and that `/v1/systemone` is not a chat call — and the notes already defer a second wire protocol deliberately. Laya shows we need none: register `judge.typed` with `#:remote? #t` and a `#:validate`, and a small worker on the Mac calls `laya_serve.py --stdio` (0.11 ms) or its loopback HTTP. Telemachus's side is a kind registration and a validator. It inherits, with no new code: quota admission, the org gate, cancel and `canceling` (SCHED‑8), the lease and the `claim_token` fence (#24), the reported state (PULL‑11), the blameless release (PULL‑12), and every one of FLEET‑1…4's visibility surfaces. A push executor would also mean Telemachus reaching OUT to a Mac on somebody's desk; a pull worker means the Mac reaches in and needs no inbound port, which is PULL‑1's whole argument. |
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
| 🔑 **JUDGE‑14** | What laya must expose | **Nothing new.** `laya_serve.py --port` already speaks `POST /v1/systemone` + `GET /v1/health` on loopback; the bridge is a Telemachus pull worker on the same host · vs a Telemachus-specific API on laya · vs embedding laya in the worker | Verified against `packages/laya` at `dev`: the HTTP transport exists, loopback by default, with `--model`, `--revision`, `--dtype`, `--device` and `--batch-size` flags — everything JUDGE‑11 needs to pin is a startup flag, and G1 already made the response's `model` the real checkpoint (`aac6fef/laya-mlx@20aed81… float16`). The worker forwards `request_json` as the body, returns the answer as received, and maps `GET /v1/health` onto PULL‑11's ready/paused report. Run laya with **`--batch-size 1`**: exact answer-independence, ~1.7× latency on a 16-question request, and the one configuration under which a stored verdict is reproducible at all. If the laya API ever grows for this, it grows conveniences, not contract — the contract is JEV's, and matching it is laya's reason for existing. |

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

**Three answers are needed before this is final**: which source adapter comes
first (it decides what `external-id` and `priority` mean, and whether auth is a
token, OAuth or nothing); whether a plugin screen is acceptable for the queue or
it must be the core console; and whether FEED‑10's gate is acceptable for v1.

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
| 🔑 **ANCHOR‑1** | What the anchor IS | **The platform EMITS a signed receipt; it never CALLS a notary** · vs an RFC 3161 timestamping authority · vs a public ledger · vs a second Telemachus instance | A notary is a network dependency and a disclosure, and this platform is self-hosted, privacy-first and has to work air-gapped. The head hash itself is low-information, but the *existence and cadence* of a team's decisions is not nothing to hand a third party. It is also the wrong shape: a specific remote would be one mechanism per remote in the core, when the thing the core can uniquely provide is a receipt that is meaningful **wherever** it ends up. So the platform produces the artifact and **where it is retained is the deployment's decision** — a second instance, a git repository, an object store in another account, a mail archive, a sheet of paper in a safe. That is exactly the decision #66 says this issue is really about, and it is the operator's, not the platform's. |
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
