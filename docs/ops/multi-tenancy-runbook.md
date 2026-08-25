# Multi-Tenancy — operator runbook

Operator-facing. How to run **several companies on one Telemachus instance**:
turn it on, onboard a company, run it day to day, and take it off again. Design
rationale lives in [../design/multi-tenancy.md](../design/multi-tenancy.md); this
file is the runbook.

**Everything below runs from `refimpl/racketmaximus/`.**

> **The short answer to "does onboarding a company need a restart?"** No.
> `POST /api/orgs` provisions a complete company — org, first team, its owner and
> that owner's token — and it is live on the very next request. The **only**
> restart in this whole document is the one that first sets
> `TELEMACHUS_MULTITENANT=1`, because that is a process environment variable.
> Everything after it is API.

---

## 1. What you are deploying

One layer above the team boundary that already exists:

```
              ┌───────────────── instance ─────────────────┐   superadmin (instance:*)
              │                                            │   ─ runs the box
    ┌─────────▼─────────┐                    ┌─────────────▼────────┐
    │  org: acme        │                    │  org: globex         │  org admin (org:*)
    │   team: engineering│                   │   team: engineering  │  ─ runs one company
    │   team: operations │                   │   team: sales        │
    └───────────────────┘                    └──────────────────────┘
              notes · documents · jobs · workflows · repo objects       team roles
```

| Property | Comes from | What it means for you |
|---|---|---|
| Isolation | **step 0 of `can?`** — an unconditional deny | runs *before* permissions, owner-ok, token scopes and resource grants; a share cannot tunnel out of an org |
| Nested budgets | `quota_limits.subject_type = 'org'` | admission needs the org cap **and** the team cap; one company cannot spend another's |
| Freeze | `orgs.status` | suspending a company makes every team in it read-only, and touches no data |
| Audit | `audit_log` joined through `teams.org_id` | an org admin sees its own company's events and no one else's |
| No second code path | the org row exists even single-tenant | the flag switches **surface area**, not semantics |

**There is no console UI for any of this.** The whole multi-tenancy surface is
HTTP — which is what makes it scriptable, and what means an operator without curl
(or the snippets below) cannot do it at all.

---

## 2. Prerequisites

Nix, as everywhere else in this repo — the toolchain and every test dependency are
pinned in `flake.lock`.

```sh
nix develop                      # from the repo root; Racket 9.2, PLTCOLLECTS set
cd refimpl/racketmaximus
raco make server/main.rkt        # precompile, or startup is slow
```

The examples use `curl` and `jq`; both are in the dev shell.

---

## 3. Configuration

| Variable | Default | Notes |
|---|---|---|
| `TELEMACHUS_MULTITENANT` | `0` | `1`/`true`/`yes`/`on` turn it on. **Restart to change.** |
| `DATABASE_URL` | derived from `TELEMACHUS_DATA_DIR` | SQLite or PostgreSQL; orgs work identically on both |
| `PORT` | `8835` | `TELEMACHUS_PORT` is a synonym |
| `TELEMACHUS_BIND` | `127.0.0.1` | loopback by default — see the workflow runbook's warning before exposing it |

Everything else is unchanged by multi-tenancy. Migration `0016-orgs` adds the
`orgs` table, `users.org_id`, `users.org_role_key`, `teams.org_id`, and rebuilds
`teams` for per-org slug uniqueness. It applies at startup; there is no manual step.

> **The flag is read from the process environment, so flipping it is a restart —
> and it is the only restart in this runbook.** Turning it *on* over an existing
> single-tenant database is safe: that database already has exactly one org, which
> simply stops being the only one. Turning it back *off* on a database that has
> several does **not** delete anything; it hides `/api/orgs*` and `/api/org*`
> behind `404` while every org gate keeps enforcing, which leaves you with tenants
> you can no longer administer. Do not use the flag as an off switch for a
> populated instance.

---

## 4. Day 0 — turn it on and bootstrap the superadmin

```sh
export TELEMACHUS_MULTITENANT=1
export DATABASE_URL="sqlite:///$PWD/data/telemachus.db"
racket server/main.rkt &
```

```sh
curl -s localhost:8835/health | jq .multitenant     # → true, or you did not restart
```

`POST /api/bootstrap` is **first-run-only** — it answers `409` the moment any user
exists, so it is safe to leave routed, and it is not a way back in later.

```sh
ROOT=$(curl -s -X POST localhost:8835/api/bootstrap \
  -d '{"username":"root@instance","password":"'"$SUPERADMIN_PW"'"}' | jq -r .token)
```

With the flag on, this first user is the **superadmin**: `is_operator`, placed in
its own `system` org with an `instance` team so team-scoped endpoints still work.
It is not a member of any customer company.

```sh
curl -s localhost:8835/api/whoami -H "Authorization: Bearer $ROOT" \
  | jq '{org_slug, is_operator}'      # → {"org_slug":"system","is_operator":true}
```

Keep the password. The bootstrap token can be reissued by logging in; the
superadmin is the one account with no one above it to recover it for you.

---

## 5. Onboarding a company

### 5.1 By hand

One call creates the org, its first team, its `org_owner`, and that owner's token:

```sh
curl -s -X POST localhost:8835/api/orgs -H "Authorization: Bearer $ROOT" -d '{
  "name":           "Acme Robotics",
  "slug":           "acme",
  "plan":           "starter",
  "owner_username": "admin@acme.test",
  "owner_password": "…",
  "team_name":      "Engineering",
  "team_slug":      "engineering"
}' | jq
```

```json
{ "org_id": "…", "org_slug": "acme", "org_name": "Acme Robotics", "plan": "starter",
  "team_id": "…", "team_slug": "engineering",
  "owner_user_id": "…", "owner_username": "admin@acme.test", "token": "tk_…" }
```

The company is live now. Hand `token` to the customer's administrator, or have
them log in with `owner_username` / `owner_password`; from there they run their own
company through `/api/org*` (§7) without you.

| Field | Required | Notes |
|---|---|---|
| `name` | ✅ | display name; also the source of a derived slug |
| `owner_username` | ✅ | **instance-global** (TEN‑2b) — use an email. `409` if taken. |
| `slug` | — | the natural key. Omit it and one is derived from `name`. |
| `owner_password` | — | **omit at your peril** — see the warning below |
| `plan` | — | `trial` (default) · `starter` · `pro` · `enterprise`; anything else is `400` |
| `team_name` / `team_slug` | — | default `Engineering` / `engineering`; per-org unique, so every company may have one |
| `owner_name` | — | display name for the owner |

> **Always send `owner_password`.** Without it the owner row is created with a NULL
> password hash, `POST /api/login` can never authenticate it, and the token in the
> 201 response becomes the account's **only** credential. There is no endpoint that
> mints a token for another user, so losing it means fixing the row in SQL. This is
> the one field whose omission is quietly unrecoverable.

### 5.2 From a pipeline

The create call is designed to be re-run. The contract:

| You send | Slug is free | Slug is taken |
|---|---|---|
| `"slug": "acme"` (explicit) | creates `acme` | **`409`**, and nothing is written |
| no `slug`, `"name": "Acme"` | creates `acme` | creates `acme-1`, `acme-2`, … |

An explicit slug is a **natural key**: a pipeline that declares `acme` means the
same company on every run, so a re-run is refused rather than silently answered
with a second company named `acme-1` — a duplicate you would first notice on an
invoice. A slug *derived from a name* still suffixes, because two humans typing
"Acme" may genuinely mean two companies and there is no declared key to honour.

That makes check-then-create the correct shape, and `<ref>` accepts the slug you
declared as well as the id the server minted:

```sh
#!/usr/bin/env bash
# provision.sh — converge one company. Safe to run on every deploy.
set -euo pipefail
: "${BASE:?}" "${ROOT_TOKEN:?}" "${SLUG:?}" "${NAME:?}" "${OWNER:?}" "${OWNER_PW:?}"
PLAN="${PLAN:-starter}"

api(){ curl -sS -H "Authorization: Bearer $ROOT_TOKEN" "$@"; }

if api "$BASE/api/orgs/$SLUG" | jq -e '.slug?' >/dev/null 2>&1; then
  echo "org $SLUG exists — converging plan to $PLAN"
  api -X PATCH "$BASE/api/orgs/$SLUG" -d "{\"name\":\"$NAME\",\"plan\":\"$PLAN\"}" | jq -c
else
  echo "provisioning $SLUG"
  api -X POST "$BASE/api/orgs" -d "$(jq -nc \
    --arg n "$NAME" --arg s "$SLUG" --arg p "$PLAN" --arg u "$OWNER" --arg pw "$OWNER_PW" \
    '{name:$n, slug:$s, plan:$p, owner_username:$u, owner_password:$pw}')" \
    | tee /dev/stderr | jq -r '.token' > "owner-$SLUG.token"   # shown ONCE
fi
```

Two notes for whoever wires this into CI:

- **The owner token appears once, in the 201.** Treat it as a secret at birth —
  write it to your secret store in the same step that creates it, never to a build
  log. With `owner_password` set you always have a second way in, which is why §5.1
  insists on it.
- **The superadmin cannot add people to a customer company.** `/api/org/members`
  always targets the *caller's* org, and the superadmin's org is `system` — by
  design, so an instance operator cannot quietly place an account inside a
  customer's tenancy. To seed staff, chain off the owner token the create call
  returned (§7).

### 5.3 Verify what you just did

```sh
curl -s localhost:8835/api/orgs -H "Authorization: Bearer $ROOT" \
  | jq -r '.orgs[] | "\(.slug)\t\(.status)\t\(.plan)\tteams=\(.teams)\tusers=\(.users)"'
```

```sh
curl -s localhost:8835/api/orgs/acme -H "Authorization: Bearer $ROOT" \
  | jq '{slug, status, plan, teams: [.team_list[].slug], quota}'
```

---

## 6. Day-2 operations (superadmin)

Every route below takes `<ref>` = **the org's id or its slug**.

| Operation | Call |
|---|---|
| List companies | `GET /api/orgs` |
| One company, in full | `GET /api/orgs/<ref>` — teams, members, quota, usage |
| Rename / change plan | `PATCH /api/orgs/<ref>` `{"name":…,"plan":…}` |
| Freeze / unfreeze | `POST /api/orgs/<ref>/suspend` · `/resume` |
| Set one cap | `POST /api/orgs/<ref>/quota` `{"dimension":…,"limit":…,"window":"day"}` |

### Plans and quotas

A plan is a **live setting, not a label**. `PATCH` with a `plan` re-applies that
plan's caps and says so:

```sh
curl -s -X PATCH localhost:8835/api/orgs/acme -H "Authorization: Bearer $ROOT" \
  -d '{"plan":"pro"}' | jq '{plan, quotas_reapplied, quota}'
```

| plan | `ai.tokens.total` / day | `ai.requests` / day | `ai.concurrency` |
|---|---|---|---|
| `trial` | 100 000 | 1 000 | 2 |
| `starter` | 1 000 000 | 10 000 | 4 |
| `pro` | 10 000 000 | 100 000 | 8 |
| `enterprise` | 99 000 000 | 990 000 | 16 |

> **A bespoke cap survives until the next plan change, then it does not.** Setting
> `ai.tokens.total` by hand on an `enterprise` customer and later `PATCH`ing
> `{"plan":"enterprise"}` again — even as a no-op convergence step — overwrites it
> with the table above. Either keep the custom cap out of the pipeline's declared
> state, or re-assert it after every plan write. A `PATCH` that sends only `name`
> never touches quotas.

Caps **nest**: admission requires the org's budget *and* the team's. The refusal
names which tier said no, which is the first thing to check when a customer reports
throttling that their own team quota does not explain:

```json
{ "error": "quota exceeded", "dimension": "ai.requests", "subject": "org" }
```

### Suspending a company

```sh
curl -s -X POST localhost:8835/api/orgs/acme/suspend -H "Authorization: Bearer $ROOT"
```

Every team in the company goes **read-only** — writes answer `402 tenant
suspended`, reads keep working, and nothing is deleted. Suspension is a *status
read*, never a cascade write, so `resume` cannot accidentally un-suspend a team
that was individually suspended for its own reasons.

---

## 7. What the company runs itself (org admin)

The owner token from §5.1, or any user with `org_owner` / `org_admin`:

| | |
|---|---|
| `GET /api/org` | my company: name, plan, status, quota, teams, members |
| `GET /api/org/teams` · `POST /api/org/teams` | list / create teams |
| `POST /api/org/members` | add a person, optionally straight into a team |
| `GET /api/org/audit` | audit across my company's teams |

```sh
OWNER=tk_…
curl -s -X POST localhost:8835/api/org/members -H "Authorization: Bearer $OWNER" \
  -d '{"username":"dev@acme.test","password":"…","role":"member"}' | jq
```

**An org admin manages but does not read (TEN‑2a).** It can create teams, move
people, set team budgets and read the audit log; it cannot read the notes,
documents or chats inside those teams. If it needs the data it adds itself to the
team as a member — an act that lands in `audit_log`. Do not treat `org_admin` as a
break-glass data-access role; it is not one, and it is not meant to become one.

`org:*` is also **org-role-only**: a team `owner` holding `*:*` does not get
`org:manage`. And no org role reaches `instance:*` — company administration never
escalates to instance administration.

---

## 8. Offboarding

**There is no `DELETE /api/orgs/<ref>`, deliberately.** Removing a company means
removing its teams, users, tokens, notes, documents, repo objects, blobs, jobs,
workflow runs and audit trail — an irreversible cascade that should not be one
HTTP verb away from an operator with a shell-history typo. The supported sequence:

1. **Suspend** — `POST /api/orgs/<ref>/suspend`. Read-only, immediate, reversible.
   For most offboarding this is the end of the story: the tenancy is inert, the
   data is intact, and the customer can be resumed if they come back.
2. **Export**, if the contract requires it — as the customer's own owner token,
   through the ordinary APIs (`/api/repo*`, `/api/notes`, …). There is no
   instance-side export that crosses the org gate, and the superadmin reading
   customer data to produce one would be exactly the thing TEN‑2a exists to
   prevent.
3. **Erase**, only when you mean it: stop the server, back up the database, and
   delete in SQL. Blobs are content-addressed and refcounted per org
   (`domain/repo/blobs.rkt`, DOC‑6), so remove blob references before dropping the
   rows that point at them, or you strand bytes on disk with nothing to free them.

Treat step 3 as a maintenance window with a restore path, not a runbook one-liner.

---

## 9. Verification

```sh
raco test test/tenancy-tests.rkt          # the authz core: the org gate, no server
TELEMACHUS_MULTITENANT=1 bash test/multitenant-demo.sh
# → multitenant-demo: PASS
```

The demo boots a server on a temp database and asserts the properties that make
"several companies on one system" true, in twelve narrated sections (0–11) — read it
top-to-bottom as the worked example this runbook summarizes. Section **10** is the
pipeline path in §5.2: it provisions a company against the same process that has
been serving the previous ten sections, proves the owner works on the next
request, and proves a re-run yields `409` rather than a shadow `initech-1`.

It needs `PORT` and `PORT+1` free (default `8836`/`8837`) and honours a pre-set
`DATABASE_URL`, so run it on PostgreSQL too before trusting a PostgreSQL deploy:

```sh
DATABASE_URL="postgres://…" TELEMACHUS_MULTITENANT=1 bash test/multitenant-demo.sh
```

`POST /api/admin/seed-tenants` seeds Acme + Globex with **published dev
passwords**. It is a demo fixture, superadmin-only, refuses to run twice — and must
never be called on a production instance.

---

## 10. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `/api/orgs` → `404 multi-tenancy is not enabled` | flag off, or set but not restarted | `TELEMACHUS_MULTITENANT=1`, restart, confirm `/health` |
| `POST /api/orgs` → `409 … slug 'x' already exists` | the company is already provisioned | working as intended — `GET /api/orgs/x` and `PATCH` to converge |
| `409 owner_username already exists on this instance` | usernames are instance-global (TEN‑2b) | use an email; two companies cannot both hold `alice` |
| `400 unknown plan` | typo, or a plan this build does not sell | one of `trial`/`starter`/`pro`/`enterprise` |
| Orgs appearing as `acme-1`, `acme-2` | creates sent **without** an explicit `slug` | send `slug`; merge or delete the duplicates in SQL |
| Owner cannot log in, token lost | created without `owner_password` | no API recovery: `authenticate` refuses a NULL `password_hash` and nothing mints a token for another user. Repair `users.password_hash` in SQL. |
| `402 tenant suspended` on writes | the org **or** that team is suspended | check both: `GET /api/orgs/<ref>` and the team's own status |
| `quota exceeded` with `"subject":"org"` | the **company** cap, not the team's | `POST /api/orgs/<ref>/quota`, or move the plan up |
| A cross-org share does nothing | the org gate runs before grants, by design | not a bug; cross-org sharing is a non-goal (TEN‑2c) |
| Superadmin's `/api/org/members` lands in `system` | that plane is always the *caller's* org | use the company's own owner token |

---

## 11. What is not per-org yet

Worth knowing before you promise it to a customer:

- **Branding and hostnames are instance-wide** (TEN‑2d, open). `GET /api/branding`
  serves one title, tagline and logo for the whole box, and `orgs.slug` is not
  routed to a subdomain. Several companies on one instance today see the *same*
  product name on the sign-in screen.
- **Model endpoints are instance-wide** (TEN‑2e, open). Executors are configured
  per instance, so a company cannot bring its own inference endpoint or key. Every
  org's traffic goes to `TELEMACHUS_MODEL_URL`; the isolation between them is the
  quota nesting, not a separate model.
- **A user belongs to exactly one org** (TEN‑2c, decided). A consultant working for
  two customers needs two accounts with two emails. This is a non-goal, not a gap —
  cross-org membership would reintroduce the ambiguity the gate exists to remove.
- **No console UI.** Everything here is HTTP.
