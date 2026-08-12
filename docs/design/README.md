# Telemachus — Platform Design

Design docs for the three interlocking platform subsystems that make Telemachus a
**team** platform rather than a single-user workspace. These are *proposals with
data shapes and contracts* for review — concrete enough to build from, with the
genuine policy forks flagged **Decisions to confirm** in each doc.

| Doc | Subsystem | One line |
|---|---|---|
| [rbac-and-teams.md](rbac-and-teams.md) | **RBAC & Teams** | Who exists, what they may do, whose data is whose. |
| [quotas.md](quotas.md) | **Quotas** | What is metered per user/team, and the limits. |
| [ai-queue-and-concurrency.md](ai-queue-and-concurrency.md) | **AI queue & governor** | Admission, concurrency caps, and workload distribution so nothing self-DDOSes. |

## How they interlock

- **RBAC defines the principals** (users, teams, service tokens). Those same
  principals are the **subjects** that quotas meter and the queue attributes work
  to. Read RBAC first.
- **Quotas set the caps** (tokens/day, max concurrency, storage). The **governor
  enforces** the concurrency/rate portion at admission time; the quota service
  owns the accounting and the periodic budgets.
- **The governor distributes** admitted work across model endpoints and holds a
  slot only per step, so long agent flows don't starve others.

```
request ─▶ RBAC check ─▶ quota check ─▶ queue admission ─▶ governor slot ─▶ model
             (may?)        (budget?)      (fair? depth?)     (endpoint)
                └──────────────── audit_log (every decision) ────────────────┘
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

## Cross-cutting decision to confirm

**Tenancy shape.** These docs model **Team as the tenancy boundary** with a
single implicit organization (the deployment). Multiple independent orgs sharing
one instance is treated as a *future additive layer* (`org_id` on `teams`), not
v1. Confirm this is the right scope, or say if multi-org isolation is required
now (it changes isolation checks everywhere).

## Status

Proposals, pending your review. Nothing here is built yet; the Racket engine
nucleus (`refimpl/racketmaximus/domain/`) is the substrate these will wrap. They
also feed the checkboxes in [../FeatureRequirements.md](../FeatureRequirements.md).
