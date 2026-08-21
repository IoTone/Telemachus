# Telemachus — Platform Design

Design docs for the platform subsystems that make Telemachus a **team** platform
rather than a single-user workspace, plus the **Localization** flagship that
proves the platform can build real tools. These are *proposals with data shapes
and contracts* for review — concrete enough to build from, with the genuine policy
forks flagged **Decisions to confirm** in each doc.

| Doc | Subsystem | One line |
|---|---|---|
| [rbac-and-teams.md](rbac-and-teams.md) | **RBAC & Teams** | Who exists, what they may do, whose data is whose. |
| [quotas.md](quotas.md) | **Quotas** | What is metered per user/team, and the limits. |
| [ai-queue-and-concurrency.md](ai-queue-and-concurrency.md) | **AI workload scheduler** | Admission, placement & concurrency caps — a workload queue (SLURM/k8s-style), not a message bus; local now, federation-ready. |
| [localization.md](localization.md) | **Localization** | i18n top-to-bottom + a manager tool (extract → team-complete → CI-gate); English at launch, ja/nl/es-419 built *by the tool*. |
| [multi-tenancy.md](multi-tenancy.md) | **Multi-tenancy** | Many companies on one instance, behind a flag: an org above the team, a superadmin tier above the org admin, an org gate at step 0 of every check. |
| [workflow-engine.md](workflow-engine.md) | **Workflow engine** | Plugins that process in steps: a public data spec as the contract, `define-workflow` as the Racket authoring surface, every step a scheduler job. *(Operators: [../ops/workflow-engine-runbook.md](../ops/workflow-engine-runbook.md).)* |
| [document-repository.md](document-repository.md) | **Document repository** | Binary documents of any format, team access control with creator-set visibility, exposed as an S3-compatible API; content-addressed bytes behind a plugin seam (`rs3` local). *(✅ Built, slices 49–55 — including content search and the documents fold. Operators: [../ops/document-repository-runbook.md](../ops/document-repository-runbook.md).)* |
| [saas-onboarding.md](saas-onboarding.md) | **Onboarding / SaaS** | Provision a per-tenant instance seeded with exactly one owner (signup / subscription / VM launch); operator-vs-owner split, magic-link activation. |
| [beta-onboarding-experience.md](beta-onboarding-experience.md) | **Beta onboarding** | Skinnable, admin-configurable pre-sales lead capture; core = mechanism, plugin = presentation; extensible `attributes` model + a token-themed render contract. |
| [nix-packaging.md](nix-packaging.md) | **Build & deploy** *(toolchain, not a platform subsystem)* | ✅ **Built.** Reproducible `nix develop` / `nix build` / `nix run`; retires the brew+`PLTCOLLECTS` ritual and unlocks live Postgres testing. |

## How they interlock

- **RBAC defines the principals** (users, teams, service tokens). Those same
  principals are the **subjects** that quotas meter and the queue attributes work
  to. Read RBAC first.
- **Quotas set the caps** (tokens/day, max concurrency, storage). The **governor
  enforces** the concurrency/rate portion at admission time; the quota service
  owns the accounting and the periodic budgets.
- **The scheduler places** admitted work on an **executor** (a compute resource)
  and holds a slot only per step, so long agent flows don't starve others. It is a
  *workload* queue (schedules jobs onto resources, SLURM/k8s-style), **not** a
  message queue (0mq/NATS); a message transport may later be the *wire* to remote
  executors, but that is deferred and out of RI scope.
- **Localization is composed from the other three**, not new infra: the manager is
  RBAC-gated (who edits which locale), meters AI drafts through **quotas**, runs
  bulk drafts as **scheduler** jobs, and ships as an **SDK** localization
  extension. That it needs no new plumbing is the proof — the platform builds a
  real tool out of its own primitives, and that tool then produces ja/nl/es-419.

```
request ─▶ RBAC check ─▶ quota check ─▶ scheduler admission ─▶ executor slot ─▶ model
             (may?)        (budget?)      (place? fair? depth?)   (local now;
                                                                  remote later)
                └──────────────── audit_log (every decision) ─────────────────┘
```

## Cross-cutting tenets baked in

- **Contract-first / swappable backends.** Each subsystem is defined as an
  interface (`AuthzService`, `QuotaService`, `Scheduler`) that *any* backend
  implements; `refimpl/racketmaximus` is the reference implementation. Frontends
  and alternative backends target the contract, not the Racket code.
- **Every feature is manageable + activatable.** Each subsystem exposes a
  management surface and honors a global/team **feature activation** flag
  (`features` registry, §RBAC). Enforcement decisions and management actions write
  to a shared **`audit_log`**.
- **Backend-neutral data.** Shapes below use generic types (`text`, `int`,
  `timestamp`, `json`) — no SQLite-only or Postgres-only constructs — so the
  SQLite→Postgres move stays a `db-kit` backend swap.
- **Hooks the engine we already built.** `run-agent`'s injected effects are the
  enforcement seam: the `#:llm` effect is wrapped by the governor + token meter;
  the `#:exec` effect is wrapped by the RBAC tool-permission check + tool-quota
  meter. The pure spine is untouched — this is exactly what the injected-effects
  design was for.

## Tenancy (decided — revised in slice 45)

**Team is the tenancy boundary**, and above it sits an **org** (a company). Every
deployment has at least one org; `TELEMACHUS_MULTITENANT` decides whether it may
have more.

- **Flag off (default)** — exactly one implicit org, and the product behaves as it
  always has: a deployment serves one legal entity containing one or many teams.
  This was decision **TEN**.
- **Flag on** — several companies share one instance, isolated by an org gate that
  runs *before* every permission, grant and token-scope check. A **superadmin**
  (`instance:*`) runs the instance; each company's **org admin** (`org:*`) runs
  only its own. This is decision **TEN‑2**, which supersedes TEN. See
  [multi-tenancy.md](multi-tenancy.md).

The **hosted** offering can now serve different legal entities either way: as
**one isolated instance per tenant** ([saas-onboarding.md](saas-onboarding.md)),
or as several orgs on one instance. The two compose — a provisioned instance is
just a deployment with the flag off.

## Follow-up design items (noted, not yet drafted)

- **Documentation generation.** The project needs generated docs (SDK contracts,
  backend APIs, tool catalog, permission catalog) emitted as **localizable**
  Markdown that flows into the localization pipeline (§localization → Documentation).
  Its own design doc is a planned follow-up.
- **Management-contract & audit.** The uniform per-feature management/activate
  interface and the shared `audit_log` are referenced by every doc; they may earn a
  short dedicated spec.

## Kickoff decisions

All the choices needed to start building — with recommendations and a decision log
— are compiled in **[decisions.md](decisions.md)**.

## Status

Proposals, pending your review. Nothing here is built yet; the Racket engine
nucleus (`refimpl/racketmaximus/domain/`) is the substrate these will wrap. They
also feed the checkboxes in [../FeatureRequirements.md](../FeatureRequirements.md).
