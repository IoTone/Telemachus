# Document sharing, with permissions

*Proposal for review. Companion to [document-workflows.md](document-workflows.md):
derived documents need a permission model to inherit from, and this is it. Data
shapes and contracts are concrete enough to build from; the policy forks are under
**Decisions to confirm**.*

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
| **manage** | change visibility, share and revoke, delete | `files:read` `files:write` `files:manage` |

`manage` implies `edit` implies `view`, enforced by **granting the set**, never by
a wildcard — a grant row says exactly what it says. The owner holds all three by
owner‑ok and needs no row. `files:manage` is a new permission (today "manage" is
owner‑or‑team‑admin); it lets an owner delegate stewardship of one document without
handing over a team role.

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

1. `files:manage` in the permission catalog; `expires_at` migration; `has-grant?`
   honours expiry. Unit tests on the three capability sets and on expiry.
2. The share API takes `{principal_type, principal_id, capability, expires_at}`;
   `{user_id}` still works. Smoke: a team grant, an expired grant, a viewer who
   cannot re-share.
3. The dialog and the "Shared with me" filter.
4. `inherit` — landed with the first derived-document tool in the workflows slice.

## Decisions to confirm

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DSH‑1** | What a person picks when sharing | **Three capabilities (view / edit / manage) that grant permission sets** · vs exposing permission strings · vs a boolean | Sharing must be explainable in one sentence; the row stays exact. |
| **DSH‑2** | Who may re-share | **Only `manage`** (owner, or a manage grantee) · vs any viewer | Keeps the set of people who can widen access small and auditable. |
| **DSH‑3** | Expiring grants | **In v1, optional `expires_at`, expired rows kept** · vs later · vs never | Links already expire; a contractor's grant should not outlive the contract. |
| **DSH‑4** | Groups | **Deferred; user + team principals in v1** · vs build groups now | RBAC has no groups; adding a principal type later changes nothing here. |
| **DSH‑5** | Derived documents | **Inherit visibility + grants at creation, then independent** · vs live-linked · vs private-by-default | The only rule explainable in a sentence; live-linking makes "who can see this" unanswerable. |
| **DSH‑6** | Cross-team sharing | **Allowed inside an org; never across** — the org gate already guarantees it | The FSD's "share across a team" without a hole in tenancy. |
