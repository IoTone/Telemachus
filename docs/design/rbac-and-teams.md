# RBAC & Teams

**Purpose.** A real team + role model — not Odysseus's binary `is_admin` flag and
`owner==me OR owner IS NULL` sharing (where a NULL owner was world-readable). This
is the foundation: it defines the **principals** that quotas and the AI queue act
on, and the **authorization** every feature checks.

## Principals

- **User** — a human account (login, password/2FA). May belong to many teams.
- **Team** — the tenancy boundary. Owns resources; carries quota policy. The
  deployment is one implicit org containing teams (see index's tenancy decision).
- **Membership** — a `(user, team, role)` edge. A user's rights in a team come
  from their role there; the same user can be Admin in one team, Viewer in another.
- **Service principal / API token** — a non-human actor issued *by a user, within
  a team*, carrying a **subset** of that user's permissions (never more). Replaces
  Odysseus's `ody_` tokens and its magic `internal-tool` username; the engine's
  in-process tool loopback is a service principal with explicit, minimal grants.
- **Operator** — the instance-level superuser (first-run bootstrap, lock-guarded),
  manages deployment settings, model endpoints, feature activation, all teams.

## Roles → permissions

A **role** is a named set of **permissions**. Permissions are `resource:action`
strings, checked server-side at every mutating/reading entry point.

**Built-in team roles** (customizable; a deployer may define more per team):

| Role | Intent | Grants (summary) |
|---|---|---|
| `owner` | team steward | everything in the team incl. `team:delete`, `quota:manage`, `members:manage`, `roles:manage` |
| `admin` | manage without destroying | members, resources, settings, tokens; **not** `team:delete` or quota policy |
| `member` | use AI + own resources | `chat:use`, `tools:invoke`, `documents:write`, `research:use`, create/own resources |
| `viewer` | read shared | `*:read` on team-visible resources; no AI spend, no mutation |

**Instance role:** `operator` (all of the above across all teams + deployment
management). **Service tokens** get an explicit scope list, intersected with the
issuing user's live permissions at call time (revoking the user revokes the token).

**Permission catalog (initial).** `resource` ∈ {team, members, roles, quota,
settings, features, models, tokens, webhooks, audit, chat, tools, documents,
notes, tasks, memory, research, files}. `action` ∈ {read, write, delete, use,
invoke, manage, serve}. Examples: `documents:write`, `tools:invoke`,
`members:manage`, `models:serve`, `features:manage`. Wildcards allowed in a role
(`documents:*`, `*:read`).

## Authorization model

A check is `can(principal, permission, resource) -> bool`:

1. Resolve the **team context** (the resource's `team_id`, or an explicit team for
   team-level actions).
2. Resolve the principal's **effective permissions** in that team (role grants,
   ∪ operator-all; for tokens: issuer's perms ∩ token scopes).
3. Grant if the permission is present **and** the resource is reachable:
   - `visibility = team` → any team member with the permission;
   - `visibility = private` → only `owner_user_id` (+ admins/owner via `manage`);
   - `visibility = shared` → owner **plus** matching rows in `resource_grants`.

**No implicit public.** There is no NULL-owner=world rule. Cross-team access
requires an explicit grant. Single-user/anonymous mode is *not* a goal (this is a
team product); a solo deployer is simply the sole member of one team.

## Data shapes (backend-neutral)

```
users(id pk, username uniq, display_name, email, password_hash,
      totp_secret nullable, is_operator bool, status, created_at, updated_at)

teams(id pk, slug uniq, name, status, created_at, updated_at)         -- org_id added later if multi-org

memberships(id pk, user_id fk, team_id fk, role_key, status, created_at,
            uniq(user_id, team_id))

roles(id pk, team_id fk nullable, key, name, is_builtin bool,          -- team_id NULL = built-in/global
      uniq(team_id, key))

role_permissions(role_id fk, permission text,                          -- e.g. "documents:write"
                 uniq(role_id, permission))

api_tokens(id pk, user_id fk, team_id fk, name, token_hash, prefix,
           scopes json, status, expires_at nullable, last_used_at, created_at)

resource_grants(id pk, resource_type, resource_id, principal_type,     -- principal_type: user|team
                principal_id, permission, granted_by fk, created_at,
                uniq(resource_type, resource_id, principal_type, principal_id, permission))

audit_log(id pk, actor_type, actor_id, team_id, action, resource_type, -- shared by all subsystems
          resource_id, result, at, meta json)

features(key pk, scope, team_id nullable, enabled bool, updated_by, updated_at)  -- activate/deactivate
```

**Every ownable app resource** (documents, notes, tasks, sessions, memories, …)
carries: `team_id` (required), `owner_user_id` (creator), `visibility`
(team|private|shared). This is the through-line that makes isolation uniform —
the analogue of Odysseus's `owner` column, but team-scoped and without the
public-by-NULL footgun.

## Contract (any backend implements)

```
AuthzService:
  can(principal, permission, resource?) -> bool
  require(principal, permission, resource?) -> unit | raises Forbidden
  effective_permissions(principal, team) -> set<permission>
  resolve_token(bearer) -> principal | null           # token → acting user, scoped
  grant(resource, principal, permission, by)          # sharing
  revoke(resource, principal, permission, by)
```

`refimpl/racketmaximus` implements this over `db-kit`. The engine's `#:exec`
effect calls `require(principal, "tools:invoke", tool)` (and per-tool perms like
`documents:write`) before dispatch — the RBAC seam into the agent loop.

## Management surface

CRUD for teams/members/roles/tokens + a share/grant UI, all `manage`-gated and
**audited** (`audit_log`). Each feature area honors `features` activation so an
operator can disable a capability team-wide or instance-wide.

## Decisions to confirm

1. **Role set.** Keep `owner/admin/member/viewer` as built-ins? Add `guest`
   (single-resource external collaborator)? (Default: the four above.)
2. **Custom roles in v1** or built-ins only first? (Default: allow custom per-team
   roles from the start — cheap given the `roles`/`role_permissions` tables.)
3. **Cross-team sharing** in v1, or team-isolated only until later? (Default:
   ship `resource_grants` but allow only user↦resource shares within a team in v1;
   cross-team later.)
4. **Token scope model.** Confirm tokens = issuer-perms ∩ explicit-scopes (my
   recommendation) vs a fixed scope catalog like Odysseus.
5. **Operator vs Team-Owner split.** Is a distinct instance `operator` wanted, or
   should the first team's owner also be the instance operator? (Default: distinct
   `operator`.)
