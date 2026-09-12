# Document sharing, with permissions

*Decided 12 Sep 2026 (DSH‑1…6, see [decisions.md](decisions.md)). Steps 1–2 of
the plan below and `inherit` are **built** (slice 56): `domain/repo/repo.rkt`,
migration `0025-sharing`, `test/repo-tests.rkt` case 7, the sharing block of
`test/server-smoke.sh`. Step 3 (the dialog and "Shared with me") is open.
Companion to [document-workflows.md](document-workflows.md): derived documents need
a permission model to inherit from, and this is it.*

## What exists, and where it stops

The repository already has more sharing *machinery* than it exposes:

| Layer | Today |
|---|---|
| Visibility | `private` · `team` · `shared` on every object; set by the creator (DOC‑2) |
| Grants | `resource_grants(principal_type user\|team, permission, granted_by)` — a grant can name a **team**, and carries a **permission string**, not a boolean |
| Enforcement | `can?` unions grants with the caller's team role; the org gate at step 0 means no grant crosses a company |
| Links | presigned, time-boxed, bound to the caller's own S3 key; revoking the key kills the link |
| API | `POST /api/repo-obj/<id>/share {user_id}` — grants **`files:read` to one user**, and nothing else |

So the gap is not in the model. It is that the API and the console expose one
corner of it: read-only, to a user, forever. "True sharing" means exposing the rest
without inventing a second mechanism.

## Capabilities, not permission strings

A person sharing a document should choose from three words, not from an RBAC
vocabulary:

| Capability | Means | Permission strings granted |
|---|---|---|
| **view** | open, download, search hits it | `files:read` |
| **edit** | upload a new version, change the filename | `files:read` `files:write` |
| **manage** | change visibility, share and revoke, delete | `files:read` `files:write` `files:delete` `files:manage` |

`manage` implies `edit` implies `view`, enforced by **granting the set**, never by
a wildcard — a grant row says exactly what it says. The owner holds all three by
owner‑ok and needs no row. `files:manage` is a new permission (a team admin holds
it by role, for the documents the role reaches — a colleague's team-visible one,
never their private one); it lets an owner delegate stewardship of one document
without handing over a team role. The set carries `files:delete` too, because the
catalog has a separate delete permission and a "manage" that cannot delete is not
stewardship.

**A grant is a delegation.** Before slice 56, `can?` took the permission from the
caller's *role* and used a grant only to *reach* a private resource — so a viewer
shown an editable document still could not edit it, and a member handed `manage`
still could not share. Now a grant on a resource confers its permission for that
one resource in the team tier, capped by token scopes as before and never reaching
`instance:*` / `org:*`. That is the whole difference between "sharing" and "a
narrower way to say what the role already said". Sharing again with the same
principal **replaces** the capability (narrowing an editor to a viewer drops the
write row) and **renews** the expiry.

**Only `manage` can re-share.** A viewer cannot forward what they were shown;
neither can an editor. Sharing is a stewardship act, and DSH‑2 keeps the set of
people who can widen access small and visible.

## Principals

- **user** — as today.
- **team** — already supported by the table and by `has-grant?`, never exposed.
  Sharing with another team **inside the same org** is the cross-team case the FSD
  asks for; the org gate makes cross-*company* sharing impossible by construction,
  and that stays true (DSH‑6).
- **group** — RBAC has no groups yet. Deferred (DSH‑4); when groups land they are
  one more `principal_type`, and nothing here has to change.

## Expiry

Links already expire. Grants do not, and that asymmetry is the wrong way round: a
link is bound to a key and dies with it; a grant to a contractor outlives the
contract. `expires_at` on a grant, optional, checked in `has-grant?` beside the org
gate. Expired rows are ignored, not deleted — they are the audit trail of who was
given what.

## Derived documents inherit at creation

When a workflow produces a document from another — extracted fields, a filled form,
a translation ([document-workflows.md](document-workflows.md)) — the output's
visibility and grants are **copied from the source at the moment of creation**, and
the output is owned by the run's principal. After that the two are independent:
narrowing the source later does not narrow a translation already shared. That is
the least surprising rule and the only one that can be explained in a sentence
(DSH‑5). The `repo_derivations` row is what records that the copy happened, and
from what.

## Surfaces

- **The share dialog** on a document gains: a capability picker (view / edit /
  manage), a principal picker (a person, or a team in this org), and an optional
  expiry. The list below it shows every grant with capability, who granted it,
  when, and when it lapses — with revoke on each row.
- **"Shared with me"** as a repository filter: objects where the caller holds a
  grant and is not the owner. Today those are only findable by search.
- **Audit**: every grant and revoke already records `granted_by`; the audit log gets
  `repo.share` / `repo.unshare` events with the capability, so "who could see this
  in March" is answerable.

## Data shapes (backend-neutral)

```
resource_grants  + expires_at timestamp null          -- one added column; the rest exists
repo_derivations (id pk, object_id, version_id,       -- the derived document
                  source_object_id, source_version_id, run_id, step_id,
                  created_at)                          -- see document-workflows.md
```

Capabilities are not stored; they are the three named permission sets, resolved at
the API edge. A grant row is one permission string, as today.

## Contract (any backend implements)

```
Sharing:
  share(principal, object, {principal_type, principal_id, capability, expires_at?})
      -> [grant…]                    # requires manage on the object; writes the set
  revoke(principal, object, grant_id)
  grants(principal, object) -> [{principal, capability, granted_by, created_at, expires_at}]
  shared_with_me(principal, {limit, offset}) -> [object…]
  inherit(source_object, new_object, run)     # copy visibility + live grants; write the derivation
```

`POST /api/repo-obj/<id>/share` keeps accepting `{user_id}` and means *view* — the
existing smoke and e2e keep passing unchanged.

## Bootstrapping plan

1. ✅ `files:manage` in the permission catalog; `expires_at` migration; `has-grant?`
   honours expiry. Unit tests on the three capability sets and on expiry.
2. ✅ The share API takes `{principal_type, principal_id, capability, expires_at}`;
   `{user_id}` still works. Smoke: a team grant, an expired grant, a viewer who
   cannot re-share, a manage grantee who can.
3. The dialog and the "Shared with me" filter. *(The existing dialog already renders
   the capability and expiry of each grant; the pickers are the open part.)*
4. ✅ `inherit` — `repo-inherit!` plus `GET /api/repo-obj/<id>/derivations`; the
   first derived-document tool in the workflows slice calls it.

### As built

- `expires_at` is **epoch seconds** in the row (portable across dialects, like the
  quota ledger); the API accepts ISO‑8601 (`2026-12-31T00:00:00Z`, an offset, or a
  bare date) or epoch seconds, and listings hand back ISO‑8601 UTC. An expiry in
  the past is a 400, never a row. Expired rows are listed with `expired: true`.
- A principal must exist **in the object's org** (a user by `users.org_id` or by
  an active membership in one of its teams — an operator's `org_id` is NULL; a
  team by `teams.org_id`). Anything else is a 400: the org gate would leave a
  cross-company row inert anyway, and nobody should be told "shared" about
  something that will never open.
- `GET …/grants` returns one entry per principal — `capability` (the widest set
  the rows cover, `null` for a hand-written row that is no capability),
  `permissions`, `granted_by`, `created_at`, `expires_at`, `expired`, and the
  user's `username` or the team's `name`.
- Revoke is by principal and removes every row that principal held.
- Notes sharing (`/api/notes/<id>/share`) was already free-form in its permission
  string; since a grant now delegates, it is pinned to `notes:*`.

## Decisions (confirmed 12 Sep 2026)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DSH‑1** | What a person picks when sharing | **Three capabilities (view / edit / manage) that grant permission sets** · vs exposing permission strings · vs a boolean | Sharing must be explainable in one sentence; the row stays exact. |
| **DSH‑2** | Who may re-share | **Only `manage`** (owner, or a manage grantee) · vs any viewer | Keeps the set of people who can widen access small and auditable. |
| **DSH‑3** | Expiring grants | **In v1, optional `expires_at`, expired rows kept** · vs later · vs never | Links already expire; a contractor's grant should not outlive the contract. |
| **DSH‑4** | Groups | **Deferred; user + team principals in v1** · vs build groups now | RBAC has no groups; adding a principal type later changes nothing here. |
| **DSH‑5** | Derived documents | **Inherit visibility + grants at creation, then independent** · vs live-linked · vs private-by-default | The only rule explainable in a sentence; live-linking makes "who can see this" unanswerable. |
| **DSH‑6** | Cross-team sharing | **Allowed inside an org; never across** — the org gate already guarantees it | The FSD's "share across a team" without a hole in tenancy. |
