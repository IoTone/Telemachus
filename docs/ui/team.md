# Team

Five cards: **Members**, **API tokens**, **Features**, the **Audit log**, and
**Change your password**.

## Members

Everyone active on this team, with their **Role**. Only active memberships are
listed — somebody removed is gone from here, though the record of their having
been here is not.

An admin may change a **Role** from the dropdown and **Remove** a member:
*"Remove {name} from the team? Their tokens for this team stop working."* That
is the whole of offboarding — the membership goes inactive and the tokens they
held for this team are revoked in the same breath.

**The last owner can be neither demoted nor removed.** A team with no owner has
nobody who can grant the permission to fix it.

**Add member** takes a username and a password and mints the account's session
token, which is handed to the caller — a script's shape. An invitation by
**email address** is the other way in: the person sets their own password and
their address is confirmed by their having followed the link.

Roles and what each one holds are in `docs/reference/permissions.md`. Two that
surprise people: a team **admin** deliberately does not hold `quota:manage` —
spending is the owner's call — and a **viewer** given `edit` on one document
really can edit that one document, because a grant confers the permission on
that resource.

## API tokens

The team's machine credentials: a name, the first characters of the token, its
scopes, its status, and **Revoke**.

**Create token** shows the token **once**. There is no way to see it again;
revoke it and make another.

A token's **scopes** cap it: a token scoped to a monitoring read cannot reset a
password even if the account that issued it can. This is the credential to put
in a config file, never a session.

These are the *team's* tokens and are behind a settings-manage permission. Your
own browser sessions are a different thing and are not listed here.

## Features

Which of the switchable features this team has, and `decided by` — the layer
that decided: `team`, `org` or `instance`.

- `on` / `off`, with **Turn off** where you may.
- `a layer above does not allow it` locks the row. Turning it back on is not
  something this screen can do — the layer above owns the floor, and the attempt
  would only be refused.
- **Turning a feature off here is a record of this team's own intention, and it
  survives the layer above being switched back on.**

Five features are switchable at all — Chat, Agent, Translate, Search and
Workflows. The instance layer is in [Admin](admin.md).

## Audit log

The last twenty entries: when, the action, the actor, and what it was about.

This is the team's own trail. It is append-only, it is chained so that an
altered or deleted entry can be detected, and a team's retention rules
deliberately do **not** clear it — it is the record that survives an erasure of
everything it describes. A reset, a share, a revoke, a sign-in, a refused
notification and a cancelled job all appear here.

## Change your password

Current, new, confirm, **Update password**.

> Password changed — every session was signed out. Sign in again.

That includes the session you are using. API tokens and worker tokens are
deliberately spared: they are not reachable with the password, they are listed
and revocable on their own, and killing a customer's worker because somebody
rotated a password is the worse failure.
