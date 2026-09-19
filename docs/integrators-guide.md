# Integrator's guide

For a team putting **their own product** on Telemachus: their palette, their tools,
their screens, their API. Nothing here is a fork — every seam below is a supported
extension point, and the worked example is
[`refimpl/racketmaximus/plugins/integrator-demo/`](../refimpl/racketmaximus/plugins/integrator-demo/),
which fills all four of them and is exercised by `test/server-smoke.sh`.

Reference material, generated from the source and always current:
[`docs/reference/`](reference/) — [sdk.md](reference/sdk.md) for the authoring
surfaces, [api.md](reference/api.md) for every route, [plugins.md](reference/plugins.md)
for the seams, [permissions.md](reference/permissions.md) for the permission catalog.

---

## 1. What you can change, and what you cannot

| You want | You get | How |
|---|---|---|
| Your name, logo and palette on the console | All of it | §2 — the branding document |
| Your own capabilities the model can call | Tools, RBAC-checked like built-ins | §3 |
| Your own screens | Served by the platform, behind a bearer token | §4 |
| Your own API | Routes under a prefix that cannot collide | §5 |
| Background work | Job kinds on the platform's queue and quotas | §6 |
| Your marketing funnel | Three render tiers, fully skinnable | §7 |

What is **not** available today, stated plainly so you do not design around it:

- **A plugin cannot add a tab to the core console.** It serves its own screens (§4)
  instead. There is no extension point inside `static/index.html`.
- **Feature flags are per TEAM, not per instance.** `chat`, `agent`, `translate`,
  `search` and `workflows` can each be switched off — `POST /api/features/<name>
  {"enabled":false}`, permission `settings:manage`, and the console drops the tab as
  well as refusing the endpoint. But "this deployment has no chat" means doing it
  for every team; there is no instance-wide switch yet. Individual tools switch the
  same way (`POST /api/tools/<name>`).
- **No hot reload.** A plugin is loaded at boot; adding one means a restart.

## 2. Theme the console

The branding document carries the palette, and it is the *same token vocabulary* the
beta funnel uses — so you write your palette once and every surface wears it.

```sh
curl -X PUT $BASE/api/branding -H "Authorization: Bearer $OP" -d '{
  "title": "Acme Trade",
  "tagline": "Import compliance, in-house",
  "theme": {
    "bg": "#101014", "surface": "#1b1b22", "ink": "#f5f5f7", "muted": "#a0a0ad",
    "brand": "#c9a227", "brandInk": "#ffffff",
    "radius": "12px", "mode": "dark", "fontBody": "Serif"
  }
}'
```

| Token | What it paints |
|---|---|
| `bg` | the page ground |
| `surface` | cards, panels, the header |
| `ink` | body text |
| `muted` | secondary text — timestamps, counts, "no results" |
| `brand` | links, active tabs, the button ground (deepened) |
| `brandInk` | text **on** a brand-coloured button |
| `radius` | corner radius, `0px`–`16px` |
| `mode` | `dark` or `light` |
| `fontBody` | `System`, `Serif`, `Mono` or `Rounded` |

There is an editor at **Admin → Branding** that previews live. The logo goes up
separately (`POST /api/branding/logo`) and replaces both the mark and the wordmark.

Four things worth knowing before you fight the API:

- **An unknown token is a 400.** We refuse rather than ignore, so a token that does
  nothing cannot look like a token that does not work.
- **Contrast is enforced, not advised.** WCAG AA — 4.5:1 for text, muted text, text
  on a panel and a button label; 3:1 for the brand on its ground. A theme below the
  floor is refused with the pair and the measured ratio named. This is the screen
  people sign in on; there is no way back through a UI nobody can read.
- **Only these nine tokens.** `--panel2`, hairlines and the button's hover state are
  derived from them, so a theme stays the few decisions you actually want to make.
- **`GET /api/branding` is public**, because the sign-in screen renders it before
  anyone has a token. Writes are `instance:manage`.

### Per company, on a multi-tenant instance

With `TELEMACHUS_MULTITENANT=1`, each company gets its own branding *and its own
theme* — one more document, the same shape:

```sh
curl -X PUT $BASE/api/org/branding -H "Authorization: Bearer $ORG_ADMIN" -d '{ … }'
```

Resolution: the **Host header** first (the superadmin sets `orgs.domain`, so a
company on `acme.example` is themed before sign-in), then the caller's own org once a
bearer resolves. A company that has set nothing wears the instance's branding
**whole** — there is no per-field merge, because a half-branded console is the
confusing outcome.

## 3. Ship a tool

A tool is a capability the model may call. It registers through the same registry as
the built-ins, so per-tool RBAC and per-team activation apply for free.

```racket
(provide tools)
(define tools (list (list "shipment_eta" shipment-eta-schema "chat:use" shipment-eta)))
;; handler: (conn principal args) -> a string, a jsexpr, or an artifact
```

The schema is plain OpenAI-compatible function JSON; `define-tool` in
[sdk.md](reference/sdk.md) writes it for you. Return an **artifact** when the result
*names* something rather than carrying it (a document, a table, a link) — the model
gets one line, the console renders a card, a workflow step keeps the whole value.

## 4. Serve your own screens

Put them in `plugins/<id>/bundle/`. The platform serves that directory at
**`/api/x/<id>/bundle/*path`** to a caller with a bearer token, answered
`Cache-Control: private, no-store`.

```
plugins/acme/bundle/index.html   →  GET /api/x/acme/bundle/
plugins/acme/bundle/app.js       →  GET /api/x/acme/bundle/app.js
```

- **Ship every asset in the bundle.** The console's Content-Security-Policy is
  same-origin: a CDN font or script is blocked. This is deliberate.
- **`bundle/` is reserved** by the platform under your prefix, and core routes match
  before plugin ones, so do not declare a route there.
- The path cannot climb out of the directory, and an unloaded plugin is a 404.
- **Wear the theme.** Read `GET /api/branding` with the bearer and map the same
  tokens onto your own CSS variables — `plugins/integrator-demo/bundle/index.html`
  does exactly this in about fifteen lines, and a company's own theme answers on any
  host when the bearer is sent.
- `plugins/<id>/landing/` is the *other* directory: public, cached, for a marketing
  funnel (§7). Never put customer screens there.

## 5. Back them with your own API

```racket
(provide routes)
(define routes
  (list (list "GET"  "/eta" "chat:use" eta-route "Estimated days for ?lane=.")
        (list "POST" "/eta" "chat:use" eta-route "Estimated days for {lane}.")))
;; handler: (conn principal args) -> jsexpr,  args = {params, query, body}
```

Mounted at **`/api/x/<plugin-id>/<path>`** — the prefix is platform-fixed, so you can
never shadow a core route or another plugin's. Every route requires a bearer token;
the permission you name is checked through `can?` before your handler runs. A
`raise-user-error` becomes the caller's 400. A malformed entry fails **your plugin's
load**, not a request an hour later. They appear in
[api.md](reference/api.md#plugin-routes) and in `GET /api/plugins`.

If you need a permission the catalog does not have, add it with a description —
`PERMISSION-DOCS` in `domain/authz/permissions.rkt`; an undescribed permission is a
load error.

## 6. Background work

```racket
(provide init!)
(define (init!) (register-job-kind! "x.acme.lane-report" lane-report))
;; handler: (conn principal payload) -> jsexpr
```

`init!` runs at load with full SDK access, and this is the documented route. The name
**must** be `x.<plugin-id>.<name>` — enforced while your plugin loads, so nothing can
take a core kind's name or another plugin's. Enqueue with `POST /api/jobs
{"kind":…,"payload":…}`; watch it on `GET /api/jobs`.

Your kind is an ordinary job: the enqueuing team and user, the per-team concurrency
cap, quota admission, the org gate on whatever your handler touches, cancellation and
a lease that re-queues it if the worker dies. None of that is inherited from the
plugin — it comes from the row.

For multi-step work, publish a **workflow** instead (`POST /api/workflows`): a
validated spec whose steps are jobs, with fan-out and choice. See
[workflows.md](reference/workflows.md).

## 7. The signup funnel

Separate from the product and skinnable on its own: **Tier A** the built-in themeable
shell, **Tier B** your own bundle in `plugins/<id>/landing/` over the
`window.Telemachus.beta` SDK, **Tier C** a sandboxed HTML template. All three go
through one anti-abuse gate, and the funnel's fields, copy, theme and translations
live in an experience document an operator edits in Admin → Beta. See
[design/beta-onboarding-experience.md](design/beta-onboarding-experience.md).

## 8. The worked example

`plugins/integrator-demo/` is the whole of the above in one directory, and it is the
file to copy:

```
plugins/integrator-demo/
  plugin.json          id, name, version, description, entry
  main.rkt             a tool, two routes, a namespaced job kind via init!
  bundle/index.html    a screen that calls its own route and wears the theme
```

Try it on a running instance:

```sh
curl "$BASE/api/x/integrator-demo/eta?lane=SIN-LAX" -H "Authorization: Bearer $TOKEN"
# {"lane":"SIN-LAX","days":18}

curl -X POST $BASE/api/jobs -H "Authorization: Bearer $TOKEN" \
  -d '{"kind":"x.integrator-demo.lane-report","payload":{"lanes":["SIN-LAX","HKG-LAX"]}}'

open "$BASE/api/x/integrator-demo/bundle/"     # after signing into the console
```

`test/server-smoke.sh` asserts every one of those, so the example cannot rot
silently.

## 9. Checklist for a first integration

1. `nix develop`, then `raco make server/main.rkt` — Nix is the toolchain.
2. Copy `plugins/integrator-demo/` to `plugins/<your-id>/` and rename the id in
   `plugin.json`. **`git add` it**: Nix only sees tracked files.
3. Set your theme and logo (§2). Check the console and your bundle screen together.
4. Replace the tool, the routes and the job kind with yours. Keep the namespace.
5. Restart. Confirm the boot log lists your plugin with the counts you expect
   (`… — 1 tool(s), 2 route(s), 1 job kind(s) +init`).
6. `racket cli/telemachus-docs.rkt render` and commit `docs/reference/` — CI fails on
   drift.
7. Decide about secrets at rest before you take a backup:
   [ops/secrets-at-rest-runbook.md](ops/secrets-at-rest-runbook.md).
