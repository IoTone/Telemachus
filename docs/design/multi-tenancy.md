# Multi-Tenancy — one instance, many companies

**Status:** designed + built behind a flag (slice 45).
**Supersedes:** decision **TEN** ("team = boundary, single implicit org, no `org_id`
in the schema"). See [decisions.md](decisions.md) — **TEN‑2**.

## Why this is one design element, not a rewrite

Telemachus already has a real tenancy boundary: **team**. Every ownable resource
carries `team_id`, every check resolves a team context, every quota meters a team
subject. What it lacked was a **boundary above the team** — so a deployment could
only ever serve *one* legal entity, and "several companies on one system" meant
one VM per company (the [saas-onboarding](saas-onboarding.md) instance-per-tenant
model).

The tweak is a single new layer:

```
                 ┌──────────── instance ────────────┐      superadmin  (instance:*)
                 │                                  │
        ┌────────▼────────┐            ┌────────────▼───────┐
        │  org: Acme      │            │  org: Globex       │   org admin (org:*)
        │  ┌───────────┐  │            │  ┌──────────────┐  │
        │  │ team: eng │  │            │  │ team: eng    │  │   team roles
        │  │ team: ops │  │            │  │ team: sales  │  │   (owner/admin/
        │  └───────────┘  │            │  └──────────────┘  │    member/viewer)
        └─────────────────┘            └────────────────────┘
```

Everything below the org line is unchanged. `org_id` is the new column; the org
isolation gate is the new first step in `can?`. Nothing else about RBAC moves.

## The feature flag

`TELEMACHUS_MULTITENANT=1` turns it on. **Off is the default and off is the
current product**, byte for byte:

| | flag off (single-tenant) | flag on (multitenant) |
|---|---|---|
| orgs in the DB | exactly one, implicit (`default`) | many |
| `/api/orgs*` (superadmin) | `404` | live |
| `/api/org*` (org admin) | `404` | live |
| bootstrap | first user = operator + team owner (RBAC‑5) | first user = **superadmin**, in the `system` org |
| org isolation gate | trivially true (one org) | enforced |
| `GET /api/config`, `/health` | `multitenant: false` | `multitenant: true` |

The org row **always exists** — even single-tenant. That is deliberate: the schema
and the authorization path are identical in both modes, so the flag switches
*surface area*, not *semantics*. There is no untested second code path.

## The three tiers

| Tier | Held via | Permissions | Scope |
|---|---|---|---|
| **superadmin** (instance operator) | `users.is_operator = 1` | `instance:*` + supersedes everything | the whole instance, all orgs |
|  | *bootstrap puts it in a `system` org of its own, so team-scoped endpoints still work; `is_operator` is what lets it cross orgs, not a NULL org.* | | |
| **org admin** (company administrator) | `users.org_role_key` ∈ {`org_owner`, `org_admin`} | `org:*` + team/member/role/quota/feature/audit **management** | exactly their own org |
| **team roles** | `memberships.role_key` | `owner` / `admin` / `member` / `viewer` (unchanged) | one team |

Three rules make the split real:

1. **`instance:*` is superadmin-only.** No org role, not even `org_owner`'s
   `org:*`, can reach it — the same guard that already stops team `owner`'s `*:*`
   from reaching `instance:*` (RBAC‑5), extended one level.
2. **`org:*` is org-role-only.** A team `owner` with `*:*` does **not** get
   `org:manage`; company administration is a distinct tier from team stewardship.
3. **An org admin manages, it does not read.** ✅ **Decided (TEN‑2a).**
   `org_admin` grants `team:{read,write,create}`, `members:manage`, `roles:manage`,
   `quota:manage`, `settings:manage`, `features:manage`, `tokens:manage`,
   `audit:read`, `org:{read,manage}` — and deliberately **not** `documents:read` /
   `notes:read` / `chat:use`. A company admin can create teams, move people, set
   budgets and read the audit log, but cannot silently read an employee's notes.
   If they need data access they add themselves to the team as a member — an act
   that lands in `audit_log`. `org_owner` is the same set plus `org:*` and
   `team:delete`.

   Mechanically this is one extra clause in `resource-reachable?`: an org role's
   permissions **do** reach sibling teams in the same org (that is what
   administering a company means), team-role permissions never do, and nothing at
   the org tier reaches a `private` resource. So the same `members:manage` that
   works across every team in the org yields nothing when the permission asked for
   is `notes:read`, because the role simply does not contain it.

Org roles are **data**, not code: they are rows in the existing `roles` /
`role_permissions` tables (with `team_id IS NULL`, like the built-in team roles),
so a deployer can retune them without a release.

## Data shapes

```
orgs(id pk, slug uniq, name, status, plan, created_at, updated_at)
                                    -- status: active | suspended
users.org_id       fk orgs — the user's home org; NULL only before they join a team
users.org_role_key NULL | 'org_owner' | 'org_admin'
teams.org_id       fk orgs, NOT NULL
teams              UNIQUE(org_id, slug)      -- was UNIQUE(slug)
```

Three notes on the shape:

- **`teams.slug` becomes per-org unique.** Acme and Globex may each have an
  `engineering` team. This is the one constraint that actually had to change, and
  it needs a table rebuild on SQLite (`ALTER TABLE` cannot drop an inline
  `UNIQUE`); the migration branches on `db-dialect` — rebuild-and-copy on SQLite,
  `DROP CONSTRAINT` / `ADD CONSTRAINT` on PostgreSQL.
- **`users.username` stays instance-global.** ✅ **Decided (TEN‑2b).** The login
  identifier is global (use email); `POST /api/login` therefore stays unambiguous
  and needs no org selector or subdomain. Cost: two orgs cannot both have a user
  literally named `alice` — they have `alice@acme.test` and `alice@globex.test`.
  Per-org usernames would mean rebuilding `users` *and* redesigning login; that is
  a separate, larger change if we ever want it.
- **No org column on resources.** `notes`, `documents`, `jobs`, … keep only
  `team_id`. A team belongs to exactly one org, so the org is derivable — adding
  `org_id` everywhere would create a second source of truth that can drift.

## Authorization: the org gate

`can?` gains **step 0**, ahead of everything else:

```
0. ORG GATE. Resolve the target org (the resource's team's org, or the
   principal's team's org for team-level actions).
   If principal.is_operator            -> pass (superadmins cross orgs by design)
   else if target-org != principal.org -> DENY, unconditionally.
1. instance:*  -> grant iff principal.is_operator
2. org:*       -> grant iff the principal's org role grants it AND (0) passed
3. is_operator -> grant (supersedes team roles)
4. else        -> team role permissions, as today
```

The gate is **unconditional deny**, not "deny unless granted": it runs *before*
resource grants, owner-ok, and token scopes, so no sharing path can tunnel out of
an org. Concretely, `resource_grants` cannot cross an org boundary — `has-grant?`
returns `#f` for a cross-org principal even when the row exists.

Suspension composes the same way. A suspended **org** puts every team in it into
read-only (the existing `402 tenant suspended` path), so a superadmin can freeze a
non-paying company without touching its data.

## Quotas: a cap the company divides

`quota_limits.subject_type` already accepts an arbitrary string, so **`org`**
needs no schema change. The rule is a nesting, not a replacement:

- the **superadmin** sets the org's cap (`subject_type='org'`) — what the company
  bought;
- the **org admin** distributes it across teams (`subject_type='team'`) — how the
  company spends it;
- admission requires **both** to pass. A team under its own limit but inside an
  org that has burned its budget is deferred, not admitted — one company cannot
  consume the instance on another's behalf.

## Endpoints

**Superadmin** — all gated `instance:manage`, all `404` when the flag is off:

| | |
|---|---|
| `POST /api/orgs` | create an org + its first `org_owner` (returns a login token) |
| `GET /api/orgs` | list orgs with team/user/usage counts |
| `GET /api/orgs/<id>` | one org: teams, members, quota, status |
| `POST /api/orgs/<id>/suspend` \| `/resume` | freeze / unfreeze a company |
| `POST /api/orgs/<id>/quota` | set the company's cap |
| `POST /api/admin/seed-tenants` | seed the demo fixture (below) |

**Org admin** — gated `org:manage`, scoped to the caller's own org:

| | |
|---|---|
| `GET /api/org` | my company: name, plan, status, quota, teams |
| `GET /api/org/teams` · `POST /api/org/teams` | list / create teams in my org |
| `POST /api/org/members` | add a user to my org (optionally into a team) |
| `GET /api/org/audit` | audit events across my org's teams |

`GET /api/whoami` grows `org_id`, `org_slug`, `org_role`, so a frontend can pick
its navigation without a second call.

## Demo & validation

`POST /api/admin/seed-tenants` (superadmin-only, refuses to run twice) creates two
complete companies with **known dev passwords**:

| account | password | role |
|---|---|---|
| `root@instance` | `superadmin1` | superadmin (created by bootstrap) |
| `admin@acme.test` | `acme-admin1` | Acme **org owner** |
| `dev@acme.test` | `acme-dev1` | Acme `engineering` member |
| `admin@globex.test` | `globex-admin1` | Globex **org owner** |
| `dev@globex.test` | `globex-dev1` | Globex `engineering` member |

Both companies get a team slugged `engineering` — which is itself the proof that
per-org slug uniqueness landed. Each team gets a private note, so cross-org read
attempts have something real to fail against.

`test/multitenant-demo.sh` boots a server on a temp DB and asserts the properties
that matter:

1. two orgs each own an `engineering` team (slug collision resolved);
2. an org owner **cannot** reach `instance:*` — no superadmin powers leak down;
3. an org owner **can** manage their own org, and creating a team lands in it;
4. cross-org reads fail: Acme's owner cannot read Globex's note, list its teams,
   or see it in `/api/org`;
5. a cross-org `resource_grant` does **not** open access — the gate runs first;
6. an org admin cannot read a private team note in their own org (TEN‑2a), but
   can read the org audit log;
7. the org quota caps the company: with the org's `ai.requests` exhausted, an
   under-limit team is still refused;
8. suspending Acme makes every Acme team read-only and leaves Globex untouched;
   resume restores it;
9. with the flag **off**, `/api/orgs` and `/api/org` are `404` and the
   single-tenant bootstrap → members → notes flow is byte-identical to today.

## Decisions to confirm

| id | Decision | Status |
|---|---|---|
| TEN‑2 | Multi-org tenancy exists, behind `TELEMACHUS_MULTITENANT` | ✅ supersedes TEN |
| TEN‑2a | Org admin **manages but does not read** team data | ✅ decided |
| TEN‑2b | `username` is instance-global (email); `teams.slug` is per-org | ✅ decided |
| TEN‑2c | A user belongs to **exactly one** org (`users.org_id`) | ✅ decided — cross-org membership is a non-goal; it would reintroduce exactly the ambiguity the gate exists to remove |
| TEN‑2d | Per-org custom branding / domain routing (`orgs.slug` → subdomain) | ⬜ open — the column exists, routing does not |
| TEN‑2e | Per-org model endpoints (a company brings its own inference) | ⬜ open — `executors` are instance-scoped today |
