# Onboarding & Tenant Provisioning (Hosted / SaaS)

**Purpose.** Define how a **hosted** Telemachus tenant comes into existence:
provision an isolated instance and **seed exactly one account owner — with no
other users in the system** — driven by an external event (a trial signup, a paid
subscription, a launched VM). Self-hosted deployments keep their interactive
first-run bootstrap; this doc is the **hosted** path and the piece a control plane
needs to automate it.

This is the "hosted multitenant offering" the [tenancy decision](README.md#tenancy-decided)
defers to: cross-legal-entity multitenancy on a *shared* instance is a non-goal, so
the hosted answer is **one isolated instance per tenant**. Seeding a lone owner is
therefore not a special mode — it is simply what a freshly provisioned instance is.

## What this is — and is NOT

| | |
|---|---|
| **IS** | Per-tenant instance provisioning, an idempotent **seed-one-owner** step, and a secure **first-login** (magic-link activation), all triggerable by an external event. |
| **IS NOT** | Shared-database multitenancy (explicit non-goal); a billing system; an email/SMS service; VM/container orchestration. Those live in the **control plane** (below), not in the OSS platform. |

## Two planes

- **Control plane** — your commercial layer, **outside** the OSS repo: receives
  events (signup form, Stripe webhook, VM launch hook), does billing, orchestrates
  the instance (VM/container/DB), keeps the tenant registry (`provision_id →
  instance URL`), and sends the activation email. Keeping billing/orchestration out
  of the OSS repo protects the clean-MIT, no-open-core posture.
- **Instance** — the OSS platform (`refimpl/racketmaximus`): exposes the
  **provisioning + activation hooks** and the **operator control surface** the
  control plane calls. Almost everything else it needs already exists (operator
  tier, `api_tokens`, quotas, `status` fields, `audit_log`).

## Roles: split **operator** from **owner** (the SaaS refinement)

Self-hosted collapses these (RBAC-5: the first owner bootstraps as operator). Hosted
**keeps them apart** — the platform already made `operator` a distinct tier
(`is_operator`, `instance:*` operator-only) precisely to allow this.

| Tier | Held by | As | May |
|---|---|---|---|
| **Operator** (`instance:*`) | **You**, the provider | a **service token**, *not a user* | set/enforce quotas, suspend/resume, provision, plan changes |
| **Owner** | **The customer** | the one seeded **user** | run everything, manage their team, invite members — **not** raise their own quota or unsuspend |

Because the operator is a **scoped `api_token`, not a user account**, the instance
genuinely contains **exactly one user** (the customer owner). This is what
satisfies "no other users in the system," literally. The control plane keeps the
operator token and calls `instance:manage` endpoints as billing dictates. See
[rbac-and-teams.md](rbac-and-teams.md).

## Principals & data shapes (backend-neutral)

Generic types (`text`, `int`, `timestamp`, `json`) per the house tenet — no
SQLite-only constructs, so the SQLite→Postgres move stays a `db-kit` swap. Most of
this reuses existing tables.

**`provisioning`** — idempotency + audit of each seed (new):

| field | type | notes |
|---|---|---|
| `id` | text (uuid) | pk |
| `provision_id` | text **unique** | external id: Stripe `subscription_id`, VM id, signup id |
| `source` | text | `signup` \| `subscription` \| `vm` |
| `plan` | text | maps to a quota preset |
| `status` | text | `seeded` \| `activated` \| `suspended` \| `deprovisioned` |
| `owner_user_id` | text | the seeded owner |
| `created_at` / `updated_at` | timestamp | |

**`users.status`** — extend the existing enum: `invited` → `active` → `suspended`.
A seeded owner starts `invited` with **no usable password hash**.

**`activation_tokens`** (new, mirrors `api_tokens`): `id, user_id, token_hash,
prefix, expires_at, used_at, created_at` — single-use, expiring, hashed at rest.

**Operator service token** — an `api_tokens` row scoped `instance:*` (existing
mechanism: tokens are capped by issuer-perms ∩ scopes). Minted at provision, handed
to the control plane.

## Control surface (API)

Gated by a **mode flag**: `TELEMACHUS_MODE=saas` **disables interactive
`/api/bootstrap`** (closing its open first-run race) and enables the endpoints below.

| endpoint | auth | does |
|---|---|---|
| `POST /api/provision` | `X-Provision-Token` (per-instance secret) | **idempotent** on `provision_id`: create team + owner (`invited`, no password), apply plan quotas, mint an activation token, optionally mint the operator service token; returns `{ activation_url, owner_user_id, provision_id }` |
| `GET /api/activate?token=…` | the token | validate + show the set-credentials page |
| `POST /api/activate` | the token | set password (+ optional TOTP) → owner `active`, token `used`; returns a session |
| `POST /api/instance/suspend` \| `/resume` | `instance:manage` | flip tenant `status`; suspended requests are gated |
| `POST /api/quota` *(exists)* | `instance:manage` | plan-driven limit changes |

**Boot-env seeding (for launched VMs).** Instead of an inbound call, a VM's
cloud-init can set `TELEMACHUS_SEED_OWNER_EMAIL`, `…_NAME`, `…_ORG`,
`TELEMACHUS_SEED_PLAN`, and `TELEMACHUS_PROVISION_TOKEN`. On first boot **with zero
users**, the instance self-seeds and emits the activation token to a
**provisioning sink** (stdout line / file / webhook) for the control plane to relay.
Same idempotent seed code path as `/api/provision`.

## Flow (happy path)

```
Event (signup / Stripe webhook / VM launch)
        │
        ▼
Control plane ── verify + dedupe on provision_id
        │        provision instance; inject env:
        │          TELEMACHUS_MODE=saas, PROVISION_TOKEN, plan
        ▼
POST /api/provision  { owner_email, owner_name, org, plan, provision_id }
        │
        ▼
Instance (idempotent): if no users →
   create team + owner(status=invited, no password)
   apply plan quotas ; mint activation token (single-use, 72h)
   → { activation_url }
        │
        ▼
Control plane emails owner the magic link
        │
        ▼
Owner opens /activate?token=… → sets password (+2FA) → status=active → signed in
   (only user in the instance; invites teammates via the existing members flow)
```

### Per-trigger notes

| Trigger | Control-plane action | `provision_id` |
|---|---|---|
| **Trial signup** (web form) | provision, seed owner, trial quotas, email link | signup id |
| **Paid subscription** (Stripe `checkout.session.completed`) | verify signature → provision → seed owner (email from Stripe customer) → email link | `subscription_id` |
| **Launched VM** (cloud-init) | VM self-seeds from `TELEMACHUS_SEED_*`; orchestrator records URL + relays the activation token | VM/instance id |

## Idempotency & lifecycle

- **Idempotent seed.** `provision_id` is unique; a retried webhook returns the
  existing `activation_url` (or `200` if already `active`) — never a second owner.
- **Resend.** Calling `/api/provision` again while the owner is still `invited`
  re-issues a fresh activation token (old one invalidated).
- **Billing lifecycle** (control plane → operator token):
  `subscription.updated` → `POST /api/quota`; `past_due` → `suspend` after a grace
  window; `canceled` → `suspend`, then after a **retention window** the control
  plane **deprovisions** (destroys the instance/VM) — with a data-export hook first.

## Security

- **No plaintext credentials, ever.** Activation tokens are single-use, expiring
  (72h default), hashed at rest, rate-limited, and resendable.
- **Provision token** is per-instance, transported only control-plane→instance over
  TLS, and **rotated after the first successful seed**.
- **Interactive bootstrap is disabled** in `saas` mode — the open first-run race is
  gone.
- **Suspended tenant:** requests gated (`402` + read-only, data retained); export
  allowed; deprovision is a separate, explicit step.
- **Everything is audited.** Provision, activate, suspend/resume, deprovision, and
  every quota change write to the shared `audit_log`.

## Interlock with existing subsystems

- **RBAC** — owner role + operator **service token**; the "one user" property is an
  RBAC consequence, not a special case. ([rbac-and-teams.md](rbac-and-teams.md))
- **Quotas** — `plan` maps to a preset applied via `set-limit!` at provision;
  lifecycle events adjust it. ([quotas.md](quotas.md))
- **Feature activation** — a plan can gate which features a tenant sees (the
  per-feature activation flag), enabling tiered plans without an open-core split.
- **Audit** — provisioning is a first-class actor in `audit_log`.

## What the OSS platform ships vs. the control plane

| OSS platform (this doc) | Control plane (commercial, not OSS) |
|---|---|
| `TELEMACHUS_MODE=saas`; guarded `/api/provision`; `/api/activate`; suspend/resume; operator service tokens; boot-env seeding | Stripe/billing; email sender; VM/container orchestration; tenant registry (`provision_id → URL`); the signup web funnel |

## Decisions to confirm

🔑 = gates the build.

- **ONB-1 · Tenancy model.** 🔑 **Instance-per-tenant** *(recommended)* vs. shared
  DB. Recommend instance-per-tenant — it *is* the hosted answer to the TEN non-goal
  and makes "one seeded owner" free.
- **ONB-2 · Operator identity.** **Service token** *(recommended)* vs. a hidden
  operator user. Recommend the token so the instance truly has one user.
- **ONB-3 · Seed transport.** **Both** `/api/provision` **and** boot-env seeding
  *(recommended)* — endpoint for signup/Stripe, env for VM launch.
- **ONB-4 · First login.** **Magic-link activation** *(recommended)* vs. a temp
  password. Recommend the magic link (no plaintext secret in transit).
- **ONB-5 · 2FA at activation.** **Optional now, plan-gated enforce later**
  *(recommended)* vs. required for every owner.
- **ONB-6 · Activation TTL + resend.** **72h, resendable** *(recommended)*.
- **ONB-7 · Suspend semantics.** **`402` + read-only, data retained**
  *(recommended)* vs. hard `403`. Keep export available.
- **ONB-8 · Deprovision / retention.** **30-day retention then destroy, with an
  export hook** *(recommended)*.

## Status

**Built (slice 19).** `TELEMACHUS_MODE=saas`, `POST /api/provision`,
`POST /api/activate`, `POST /api/instance/{suspend,resume}`, boot-env seeding, the
`/activate` SPA view, and the read-only suspend gate are implemented in
`refimpl/racketmaximus` (`domain/saas/onboarding.rkt`, migration `0006`,
`test/saas-tests.rkt`). Verified end-to-end: provision → single invited owner →
magic-link activation → login; suspend blocks writes (`402`) but allows reads;
resume restores.

One refinement landed vs. this proposal — **ONB‑2**: provider actions authenticate
with the per-instance **provision token** rather than an operator *service token*,
so the seeded instance holds **exactly one user** (the owner). The operator tier
still exists for self-hosted. The billing/email/orchestration **control plane**
remains out of the OSS repo. Retention/deprovision (**ONB‑8**) is a control-plane
concern. Recorded in [decisions.md](decisions.md) (ONB‑1…8).
