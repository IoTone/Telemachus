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
- **Opening a page in a browser needs a ticket.** The route wants a bearer token, and
  a browser navigation carries none — so mint one and open the URL it hands back:

  ```sh
  curl -X POST $BASE/api/x/acme/bundle-ticket -H "Authorization: Bearer $TOKEN"
  # {"ticket":"tk_…","expires_in":1800,"url":"/api/x/acme/bundle/?ticket=tk_…"}
  ```

  The first response sets that ticket as a cookie scoped to your bundle path, so the
  page's own script, stylesheet and images load without it in the query string. The
  console does this for you: a plugin with a `bundle/` directory is a link on the
  Usage tab. The cookie is `HttpOnly`, `SameSite=Strict` and reaches nothing but that
  one plugin's static files.
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

## 7b. Ship a tool that is not Racket

A plugin that is not written in Racket runs as a **subprocess** and speaks
newline-delimited JSON over stdio. It has no database handle and no platform
imports. To do anything on the platform it asks the host for a **capability**,
and the host runs it only if the plugin DECLARED the scope in its manifest **and**
the calling user holds the matching RBAC permission. Both halves, every call.

Register it in `oop.json` (or `TELEMACHUS_OOP`):

```json
{ "plugins": [ { "name": "ocr", "command": "python3", "args": ["oop-plugins/ocr/main.py"] } ] }
```

The capabilities a plugin may ask for:

| Capability | Needs | Does |
|---|---|---|
| `notes.create` / `notes.list` | `notes:write` / `notes:read` | the team's notes |
| `repo.get` | `files:read` | a document's bytes, base64, with its content type and version |
| `repo.text` | `files:read` | its extracted text — see the scan case below |
| `repo.put` | `files:write` | write a document; with `derived_from` it inherits the source's visibility and grants and records the provenance |

Bytes travel **base64 over the pipe**, not as a filesystem path or a URL. A path
would couple your plugin to the local store and leak its layout — the blob store
is never handed a principal, only a namespace and a digest, so a backend has no
authorization to get wrong. The ceiling on an inline read or write is the same
`TELEMACHUS_MAX_UPLOAD` the HTTP front door enforces: a plugin is not a way past
a limit.

**`repo.text` answers "this is a scan" rather than failing.** A PDF with no text
layer comes back as `text: null` with `reason: "needs-ocr"` — an *answer*, because
it is precisely the branch an OCR plugin exists to take, and a plugin should not
have to match on an error string to find it.

```python
r = host("repo.text", {"object": object_id})
if r.get("reason") == "needs-ocr":
    text = my_ocr(host("repo.get", {"object": object_id})["bytes_b64"])
    host("repo.put", {"key": r["key"] + ".ocr.txt", "content_type": "text/plain",
                      "bytes_b64": b64(text), "derived_from": object_id})
```

`derived_from` matters: the output is private from its first byte, inherits the
source's sharing, and `GET /api/repo-obj/<id>/processing` can answer where it came
from. Without it you have written an orphan.

`oop-plugins/doc-reader/` is the worked example — it reads a document, branches on
the scan case, and files the text back derived from the original. `GET /api/plugins`
lists sandboxed plugins under `sandboxed` with the scopes each declared, which is
how an operator audits who holds `files:write`.

## 7c. Teach it a file format

The platform reads text, markup, DOCX and PDF. Everything else is `unsupported` —
invisible to search, and a hard stop for the document pipeline. A plugin can claim
a content type and the whole chain picks it up: the search index, `doc_text`, and
every workflow built on them, with no other change.

```racket
(require (only-in "../../domain/repo/extract.rkt" register-extractor!))

(define (extract-rtf in content-type)
  ...)                                   ; -> (values text-or-#f reason-or-#f)

(define (init!)
  (register-extractor! "application/rtf" extract-rtf))
```

**Registering a type the platform already reads REPLACES its reader.** That is the
point, not a side effect: claiming `application/pdf` is how a local OCR engine
takes over from `pdftotext`.

An extractor is in-process Racket, and reaching a non-Racket engine is its own
business — the built-in PDF reader is a pipe to `pdftotext`, so a plugin wrapping
YomiToku or PaddleOCR is a few lines of Racket around a subprocess. (Shipping
bytes *to* an out-of-process plugin is the other seam, §7b, for a plugin that acts
as a tool rather than as a reader.)

Four rules the platform holds you to:

| | |
|---|---|
| **The contract** | `(in content-type) -> (values text-or-#f reason-or-#f)`, or three values with `spans` third (below) |
| **The reasons** | `unsupported`, `missing-tool`, `needs-ocr`, `failed` — and nothing else. A fifth would reach `doc_text` as a refusal naming something it cannot explain, so anything else becomes `failed`. |
| **Failure is contained** | Raising, or answering with the wrong shape, is the same `failed` an in-tree extractor would give. One plugin must not be able to wedge a team's indexing. |
| **The cap is ours** | Output is truncated to `EXTRACT-CAP`. This feeds a search index, not an archive. |

`needs-ocr` means something specific: the reader ran and found no text, so the
document is a scan. Report that rather than returning `""` — an empty extraction
is recorded as a success and the document is never looked at again.

### Reporting where the text came from

An extractor that knows the page and region of what it read — an OCR engine does —
may answer with a third value: a list of `{start, end, page, bbox}`, where `start`
and `end` are character offsets into the text it just returned and `bbox` is
`[x0 y0 x1 y1]` in whatever page units the engine uses. The platform carries them
and does not interpret them; only the renderer knows whether they are PDF points
or image pixels.

```racket
(values text #f (list (hasheq 'start 0 'end 11 'page 1 'bbox '(72 690 180 702))))
```

This is what turns review from "source on the left, output on the right" into
*click the extracted value and jump to the region it was read from* — the single
biggest lever on a reviewer's time. Two values remain entirely valid: provenance
is additive, and every extractor written before it keeps working.

A malformed span is dropped and the text is kept, because provenance is an
enrichment and losing a region must never cost a team the document. Spans pointing
past `EXTRACT-CAP` are dropped too, since they could never resolve.
`GET /api/repo-obj/<id>/spans?at=<offset>` is the lookup.

Two plugins cannot claim one content type; the second is refused. Re-registering
your own is fine, because the loader may run twice in one process.
`GET /api/plugins` lists each plugin's `extractors`, so an operator can see who
reads what. `plugins/example-tools/` ships an RTF reader as the worked example.

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

## 8b. Run it as a container

Everything above describes a plugin inside the instance. If you are deploying
Telemachus rather than extending it, the deployment surface is two pages:

- **[ops/configuration.md](ops/configuration.md)** — every environment variable
  and its default. There is no config file, and nothing is written at runtime:
  an instance is configured entirely by its environment, which is what lets the
  image run with a read-only root filesystem. A CI gate fails the build if the
  code reads a variable that page does not document.
- **[ops/container.md](ops/container.md)** — the OCI image, `compose.yaml` for
  evaluation, and Kubernetes manifests.

```sh
nix build .#container && docker load < result    # on a Linux host
docker run -d --read-only --tmpfs /tmp -v telemachus-data:/data \
  -e DATABASE_URL='postgres://…' -e TELEMACHUS_SECRET_KEY="$(openssl rand -hex 32)" \
  -p 8835:8835 --stop-timeout 30 telemachus:0.1.0
```

Four things about the image are worth knowing before you plan around it:

1. **It ships no shell.** `docker exec … sh` does not work; debugging is
   `docker logs` and the API. The only extra binary is `curl`, for the
   healthcheck.
2. **`/tmp` is not in it.** Pass `--tmpfs /tmp`, or the first upload fails.
3. **Set the stop timeout to at least 30s.** On SIGTERM the instance drains —
   in-flight jobs finish, and anything that does not is handed back to the queue
   **un-charged**. `docker stop` allows 10 seconds by default and then SIGKILLs,
   which leaves those jobs `running` until their lease expires.
4. **`POST /api/bootstrap` is loopback-only** unless you set
   `TELEMACHUS_BOOTSTRAP_SECRET` — from outside the container the caller is the
   bridge gateway, not loopback.

Set **`TELEMACHUS_STRICT_STARTUP=1`** for an unattended deployment: the checks
that are advisory by default (no sealing key; plaintext HTTP on a public bind)
then refuse to start instead of running degraded.

**Blob storage is still local.** With the default `rs3` store, document bytes
live in the `/data` volume, so back it up together with the database and do not
expect to scale past one replica. An S3-compatible backend is
[issue #82](https://github.com/IoTone/Telemachus/issues/82) and is not built;
until it is, that coupling is the real constraint on how you deploy this.

## 9. Checklist for a first integration

1. `nix develop`, then `raco make server/main.rkt` — Nix is the toolchain.
2. Copy `plugins/integrator-demo/` to `plugins/<your-id>/` and rename the id in
   `plugin.json`. **`git add` it**: Nix only sees tracked files.
3. Set your theme and logo (§2). Check the console and your bundle screen together —
   the console links your page once the plugin has a `bundle/` directory.
4. Replace the tool, the routes and the job kind with yours. Keep the namespace.
5. Restart. Confirm the boot log lists your plugin with the counts you expect
   (`… — 1 tool(s), 2 route(s), 1 job kind(s) +init`).
6. `racket cli/telemachus-docs.rkt render` and commit `docs/reference/` — CI fails on
   drift.
7. Decide about secrets at rest before you take a backup:
   [ops/secrets-at-rest-runbook.md](ops/secrets-at-rest-runbook.md).
