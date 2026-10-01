# The authorization model


## Permissions and roles

A permission is a string `resource:action`. A role is a named set of them; the built-in team roles are owner, admin, member and viewer, and two org roles sit above them. Wildcards exist (`files:*`, `*:read`, `*:*`) but two tiers are unreachable from any team role whatever it grants: `instance:*` belongs to the operator alone, and `org:*` to a company’s org role alone. Every permission carries a one-line description beside its declaration; a built-in role that grants an undescribed permission fails at load. The generated `permissions.md` shows the catalog and the role matrix.

## `can?`, in order

1.  **The org gate.** If the resource belongs to another organization, deny, unconditionally, before anything else is consulted. This is what makes multi-tenancy sound: no share, no grant, no scope can tunnel across companies, because the check that would honour them never runs.

2.  **The tier.** An `instance:` permission needs the operator flag; an `org:` permission needs the org role.

3.  **The role, or a grant.** The principal’s team role must cover the permission — *or* the principal must hold a resource grant naming it on this resource. A grant is a delegation: sharing an editable document with a viewer means the viewer can edit that one document, and handing a member the `manage` capability means they can share it onward. Before the sharing work, a grant only widened reachability and could not confer a permission the role lacked, which made “share for editing” a lie.

4.  **Owner-ok.** The owner of a resource holds every team-tier permission on it. A member who could not delete a colleague’s document can delete their own.

5.  **Scopes.** An API token or S3 key caps its issuer: the scope list must also cover the permission. Scopes narrow; they never widen.

6.  **Reachability.** A private resource is reachable by its owner, the operator, or a grantee; a team-visible one by anyone in the team; a shared one by owner and grantees.

## Capabilities

A person sharing a document does not pick permission strings. They pick a capability — view, edit or manage — and the platform writes the corresponding set of grant rows: `files:read`; plus `files:write`; plus `files:delete` and `files:manage`. Never a wildcard; a grant row says exactly what it says. Only manage can share onward. A grant may name a user or a team in the same organization, may carry an expiry (epoch seconds — `BIGINT`, because a 32-bit column overflowed on a year-2099 expiry in the PostgreSQL smoke), and an expired row is ignored, not deleted, because it is the audit trail of who was given what.

## Multi-tenancy

Off by default. With the flag on, an *org* sits above teams, a superadmin runs the instance and an org admin runs one company. The org admin manages but does not read: no `documents:read`, no `chat:use`. A company admin who needs a team’s data joins that team as a member, and the join is audited. The gate at step 0 never reads the feature flag, so turning the flag off on a populated instance hides the management planes and keeps enforcing.

## Files to open

`domain/authz/permissions.rkt`, `domain/authz/authz.rkt` (read `can?` and `has-grant?`), `docs/design/rbac-and-teams.md`, `docs/design/document-sharing.md`, `test/authz-tests.rkt`, `test/tenancy-tests.rkt`.
