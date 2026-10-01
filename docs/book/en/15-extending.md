# Extending Telemachus


## Four seams, and one prefix

A plugin is a directory with a manifest and an entry module, loaded at boot. It may fill four seams, and the whole extension contract is those four:

- **Tools** — `(provide tools)`. A capability the model may call. It registers through the same registry as the built-ins, so per-tool permissions and per-team activation apply without the plugin doing anything.

- **Workflows** — `(provide workflows)`, or spec files in a directory. Validated exactly as an API-published spec is, and materialized into a team on first lookup, because a plugin has no team at load time.

- **HTTP routes** — `(provide routes)`. Mounted at `/api/x/<plugin-id>/...`. The prefix is platform-fixed, so a plugin cannot shadow a core route or another plugin’s; every route requires a bearer token and the permission it names is checked before the handler runs; and a malformed entry fails *that plugin’s load* rather than a request an hour later.

- **Job kinds** — registered from `init!`, named `x.<plugin-id>.<name>`. A plugin kind is an ordinary job: the enqueuing team and user, the concurrency cap, quota admission, the org gate, cancellation and the lease all apply, and none of it is inherited from the plugin. A remote kind must supply a validator, since there is no in-process handler to be strict for it.

## Where plugins are found, and what happens when one is not

The built-in directory is always searched; `TELEMACHUS_PLUGINS` adds more, as a `:`-separated list, and a literal `-` entry drops the built-ins for a deployment that means to ship only its own. It used to name the ONE directory to load, so adding a plugin of your own silently removed the document pipeline and every other shipped one — an instance that came up looking healthy with its workflows gone.

That shape — healthy-looking and quietly missing — is worth naming, because the loader had a second instance of it. A plugin that throws while loading is caught, logged and skipped, which is right: one bad plugin must not stop the server. But it was ONLY logged, one line among sixty, and the instance then served an API with that plugin’s tools, workflows, routes and job kinds simply absent. Failures are kept now: a `failed` list beside the plugin listing, a warning block at boot that says how many and why, and a strict mode that refuses to start at all. Two plugins claiming one id is a failure too, rather than a silent shadow.

A related trap, since it produced exactly this: `raco make` does not reach a plugin’s entry module, because the loader `dynamic-require`s it. A Racket upgrade therefore leaves stale bytecode under `plugins/<id>/compiled/` that fails to load — and before the change above, said so in one line nobody read.

## Screens of your own

A plugin serves its own pages from two directories, and the difference between them is who may read them. `landing/` is public at `/beta/bundle/<id>/` and publicly cached — it is a marketing funnel a prospect is linked to. `bundle/` is authenticated at `/api/x/<id>/bundle/`, requires a bearer token, and is answered `private, no-store`. Customer screens belong in the second; before it existed there was only the first, and serving a signed-in screen set from it would have put customer pages behind a public cache.

Assets ship inside the bundle. The console’s policy is same-origin, so a CDN font or script is blocked — deliberately.

Two things about that authenticated directory are worth knowing before you build on it. Its files are served from where the LOADER found the plugin, not from a fixed path under the checkout: a plugin loaded from elsewhere used to serve its tools and routes perfectly while every page it had came back 404. And a page there cannot simply be opened in a browser, because the token lives in the console’s storage and a navigation carries no bearer — the smoke passed for a year because `curl` sends a header a browser never will. Opening one means minting a short-lived TICKET with the token you do have; the first response sets it as a cookie scoped to that plugin’s bundle path, so the page’s own script and stylesheet follow without it trailing through every URL. Not a session cookie issued at sign-in: the JSON API keeps its no-cookie, no-CSRF-surface property, and this one reaches nothing but one plugin’s static files.

## Wearing the customer’s colours

The branding document carries a *theme*: background, surface, ink, muted, brand, the ink that sits on the brand, a corner radius, a mode and a font. It is the same token vocabulary the onboarding funnel already used, so a palette is written once and worn by both, and it is per-organization for free, because a company’s branding is one more document under the same key — a company on its own hostname is themed before anyone signs in.

Two rules keep it honest. An unknown token is refused rather than ignored, because a token that silently does nothing is how an integrator concludes the theming is broken. And contrast is *enforced* by the server, not merely warned about: WCAG AA for text, muted text, text on a panel and a button label, and a lower bar for the brand against its ground. This is the screen people sign in on, and an instance that themed its own sign-in link into invisibility would have no way back through the UI. The button’s ground is a colour the console mixes rather than a token, so that mix is what gets checked — checking the brand itself would fail themes that render perfectly and pass ones that do not — and which side of the palette counts as dark is measured, not read from the mode token.

## What is not available

Stated plainly, so nobody designs around a hope: a plugin cannot add a tab to the core console — it serves its own screens instead; feature flags are per team, with no instance-wide switch, so “this deployment has no chat” means doing it for every team; and there is no hot reload, so adding a plugin means a restart.

## Files to open

`docs/integrators-guide.md`; `plugins/integrator-demo/`, the worked example — a tool, two routes, a job kind and a themed screen; `domain/agent/plugins.rkt`; `domain/branding/branding.rkt`; `docs/reference/sdk.md` and `docs/reference/plugins.md`.
