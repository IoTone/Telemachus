# External feeds, and a prioritised work queue

*Requirements for [issue #114](https://github.com/IoTone/Telemachus/issues/114),
an external customer requirement. **Slices 1–4 are built** (FEED‑3 as #135/#140,
FEED‑4 as #142, FEED‑5/‑6/‑12/‑13 as the feed configuration plane, and
FEED‑14…22 as the first adapter — GitHub issues, 23 Oct 2026). Slices 5 (the
ranked queue) and 6 (proposals) remain, and FEED‑8 says both are the plugin's.
Decisions FEED‑1…22.
Every claim about what exists was checked against the code and carries a
reference; where a claim in an earlier comment of mine turned out to be wrong,
the correction is marked.*

The ask, restated as a capability: **pull work items from systems the customer
already runs, and answer "what should somebody do first today" — including
"nothing, an agent can do this one".**

## What exists, and is composition rather than work

| Need | Have |
|---|---|
| An item that arrives gets processed automatically | the **trigger seam** at the end of `repo-put!` (DWF‑1), which covers every arrival path by construction |
| Fields out of a free-text item, refused rather than guessed | `doc_extract_fields` + `domain/tools/jsonschema.rkt`, where an object with no `additionalProperties` is CLOSED and the refusal names the path (DWF‑5) |
| Facts bound to the item that stated them | the **knowledge graph** — nothing enters without a source, and a snippet that is not a verbatim substring is refused (KG‑3) |
| A step that waits for a person, with four-eyes and a hash-chained decision | the **review queue** (LAY‑1…3, LAY‑11) |
| Team-defined metadata on an item, with no migration | `repo_objects.attributes` (LAY‑4) |
| A cancellable, durable, quota-admitted, restart-surviving runner | the **workflow engine** + scheduler |
| Tables a plugin owns, run like the platform's own | `(provide migrations)` (#121, shipped) |
| Retention, cascade delete, sharing, audit, search over the item | the repository, free, if the item is a repo object |

## The five things genuinely missing

**1. Nothing pulls.** Every ingestion path is *pushed* — console upload, API
`PUT`, S3 `PUT`, a worker's `derive`. There is no fetcher, no schedule, no
cursor.

**2. Nothing recurs.** `jobs` has no deferred-start column: a job runs *now*.
`set-reaper!` is the platform's own private seam, not plugin-facing. So "poll
this feed every 15 minutes" has no primitive. (#121's reporter wants this too,
for a different reason — it is one prerequisite, not two.)

**3. There is no general outbound HTTP client, and `http-sendrecv` must not be
used.** Three private clients exist — `domain/agent/llm.rkt`,
`domain/mcp/client.rkt`, `domain/s3/client.rkt` — and each opens and closes its
own connection rather than calling `http-sendrecv`, which *abandons the socket
under the response port*. Measured (`llm.rkt:127‑142`): ten POSTs went 8 → 18
descriptors, and a long-polling worker hit the 1024-descriptor limit in about
five and a half hours and then failed every request while the process stayed
alive. A fourth private copy is #110 r1's shape; this wants one seam.

**4. An outbound credential has nowhere to live.** The sealed-column machinery
covers three secrets (`users.totp_secret`, `repo_credentials.secret_key`,
`executors.secret_key`). A feed's API token is a fourth kind, and
`CREDENTIAL-SECRETS` in `cli/telemachus-secrets.rkt` is the registry
`telemachus-secrets rewrap` walks — a sealed column that is not in it is
silently unrotatable.

**5. The ranked queue cannot be expressed as a listing. — CORRECTION.** I said
on the issue that "a prioritised queue over that is a read, not a subsystem."
**That is wrong.** `repo-list` orders by `team_id, key ASC` and nothing else;
`?attr=` is an exact-match filter applied **in Racket, after the page**; an
attribute value may only be a **string or null**; and there is **no JSON SQL
anywhere in the tree**, in either dialect. So you can filter to `status:open`
and you cannot sort by priority, compare a due date, or ask for a range — and
sorting a page of 100 that was already chosen by key sorts the wrong 100.

## Decisions

### FEED‑1 · A pulled item is a repository object

`feeds/<feed-slug>/<external-id>`, the source's own payload as the body, the
source's identifiers in `attributes`.

Everything else re-implements six subsystems: visibility, grants, retention,
cascade delete, search over extracted text, the audit trail, the trigger seam and
"Processed by" all arrive free, and migration `0022-fold-documents` already
established that a text document *is* a repo object. The cost is that a ticket is
stored as a file — which is right, because what the customer wants to do with it
(extract fields, rank it, let an agent read it) is what the repository is for.
Same call RSCH‑2 makes for a research report.

### FEED‑2 · A feed belongs to a team and names the user it acts as

**There is no system principal, and this is not a gap to fill.** A job carries
`team_id` and `user_id` and runs as `(user-principal conn user team)`
(`scheduler.rkt:590‑591`); the retention sweep acts as the team's own owner
(DEL‑13); DWF‑2 says the run is the uploader's. So a feed row carries a team and
a user, and everything the fetch writes is that person's — their permissions,
their team's quota, their name in the audit trail.

This is also the answer to "who can see a pulled item": whatever that user's
`can?` says, with no new authorization code.

### FEED‑3 · Recurring work is a due time on a row, swept into a job — never a thread

> **Built** (22 Oct 2026, issues #135 and #140, decisions SCHED‑10…18):
> `job_schedules` plus `/api/schedules*`, gated on `jobs:schedule`. All three
> sub-rules below hold and each is positive-controlled. The cadence is an
> interval OR a wall-clock time of day with a stored timezone (#137 made the
> second answerable), so a morning briefing is expressible. Slice 1 is done.

A `schedules` table (team, user, kind, payload, `every_seconds`,
`next_due_epoch`, `last_job_id`), swept on the existing `set-reaper!` seam, whose
only action is to **enqueue a job**. A thread started at load has no team, no
principal and no request context, which is what makes it dangerous rather than
merely awkward: `can?` has nobody to answer about and the org gate has no tenant
to scope to. Enqueuing inherits quota admission, the org gate, cancel, the lease,
the fence, SCHED‑9's run-time ceiling and the whole FLEET surface.

Three sub-decisions, because each is a way to get this wrong:

- **A missed tick does NOT backfill.** One run, and `next_due_epoch` moves
  forward from *now*. A box down for a week must not wake up and fire 672 polls;
  a feed is a cursor, not a ledger, and the next fetch sees everything the missed
  ones would have.
- **Two replicas cannot both fire.** The claim is
  `UPDATE schedules SET next_due_epoch = ? WHERE id = ? AND next_due_epoch <= ? RETURNING id`
  and is believed only when a row comes back — issue #17's one-claim rule, which
  is already why `claim-job!` is an `UPDATE … RETURNING` and not a `query-exec`.
- **An overrunning run does not stack.** While the previous job is unfinished the
  next enqueue is **skipped and reported**, not queued behind it. A 20-minute
  fetch on a 15-minute schedule would otherwise grow a queue for ever, and
  "skipped because the previous run is still going" is a fact an operator needs
  rather than a silence.

### FEED‑4 · One outbound HTTP seam, and the policy belongs to the CALLER

🔑 **This is the decision the rest depends on, and it is where #114 and RSCH‑3
collide.**

RSCH‑3 (proposed) specifies a fetcher that *"refuses private address space, with
DNS resolved ONCE and the connection pinned to the resolved address"* — because a
research loop fetches a URL a **model** chose out of a **search result**, which
turns the server into an SSRF proxy onto its own network.

#114 asks for feeds **"in our network"**. A fetcher with RSCH‑3's rule would
refuse the customer's primary use case.

Both are right, because **the rule attaches to who chose the URL, not to where it
points**:

| Caller | URL chosen by | Private address space |
|---|---|---|
| a configured feed (FEED‑1) | the operator or a team admin, stored and reviewable | **allowed** — same trust as `TELEMACHUS_MODEL_URL`, `executors.json`, an MCP server |
| a research fetch (RSCH‑3) | a model, from a search result | **refused**, with DNS pinned |

So: **one fetcher, two policies, and the policy is a parameter the caller cannot
widen.** `(fetch url #:policy 'configured)` versus `#:policy 'untrusted`, with
`'untrusted` the default so a new caller is safe by omission — the opposite of
LAY‑9's unknown-is-permissive, and for ZDR‑2's reason: being wrong here means a
request reached somewhere it should not, so this one fails closed.

The seam must also carry what the three private clients each learned
independently: its own connection opened and closed on every exit (the
descriptor leak), a deadline, a bounded retry on 429/5xx/timeout and **never on
4xx**, and a response size cap.

### FEED‑5 · An outbound credential is a sealed column in the registry

`feeds.secret` sealed with `define-sealed-column` (#110 r1), AAD
`feeds.secret:<feed-id>` — and a row added to `CREDENTIAL-SECRETS`, without
which `telemachus-secrets rewrap` silently skips it and a key rotation leaves it
unopenable. #83's own notes call this the step people forget.

**Built, and the registry row was not the only trap.** The macro's seal is
conditional on `TELEMACHUS_ENCRYPT_CONTENT` — correct for #83's content columns,
wrong for a credential — so #85's `webhooks.secret`, the first credential
declared through it, was written in the clear on any instance with a key and the
content switch off, which is the documented default. The macro has a
`#:credential` form now (ENC‑23) and both columns use it.

**The feed table is CORE, not the plugin's**, which revises FEED‑11's "slices
3–6 are a plugin": the sealed-column machinery and `CREDENTIAL-SECRETS` are
platform, and a plugin-owned sealed column would be precisely the
silently-unrotatable case this decision exists to prevent. A plugin-registrable
sealed column would move it and is not built.

**Three auth modes, and one refusal** (FEED‑13): `bearer`, a named `header`, and
`query` — the last supported deliberately, because refusing it only pushes the
token into the `url` field where it would be unsealed. Userinfo in the URL
(`https://user:pass@host/`) is refused outright: unambiguously a credential, with
a sealed home available, and silently relocating it would leave the operator
unsure which home was in use.

**A credential is addressed to an ORIGIN** (FEED‑23). Sealing it and never
returning it are half the rule; the other half is where it is sent. `fetch` takes
the header names a caller considers its credential — `authorization` and `cookie`
by default, plus a feed's own `auth_name` — and withholds them from any hop whose
scheme, host or port differs from the URL the caller supplied. RFC 9110 §15.4 and
the Fetch standard say the same for `Authorization`; the caller-named list is what
makes it hold for `header` mode, which no fixed list covers. An `http` to `https`
upgrade on one host counts as another origin, as it does for a browser, so an
operator whose source upgrades configures the `https` URL.

The same problem exists one level up, where no redirect rule reaches: a
`Link: rel="next"` is the source naming a URL, and a poll applies the credential
to it before fetching. The poll refuses a next page on another origin rather than
following it without the credential, because an unauthenticated page is a 401 at
best and somebody else's items landed under this feed's key prefix at worst.

Two writes enforce the same idea at configuration time: a PATCH that moves a
feed's URL to another origin must carry `secret` in the same request, since the
stored one was sealed for the old origin, and a secret containing a control
character is refused, because a header is written as `name: value\r\n` and a
line break in it adds a header. The fetcher refuses that too, so a row written
before the check existed cannot still send one.

### FEED‑6 · A failing fetch records the host and the status, never the URL

The customer's words are *"without spilling credentials in logs that go into the
ether"*, and sealing the stored secret is not enough. #83 r4 sealed four `error`
columns because this platform's own tools quote what they choked on; this
session's #123 work stopped a 500 carrying `exn-message`. An outbound client adds
a new copy: **a token in a query string is in the URL**, and a failing request's
URL is the first thing an error wants to quote.

So the recorded error names the host, the path and the status code — never the
query, never a header, never the body. And the fetcher redacts on the way *into*
the exception, not on the way out of it, because by then it has been formatted.

### FEED‑7 · Dedup is a per-item content hash in the plugin's own table

`repo-put!` on an existing key writes a **new version**, so re-fetching an
unchanged item would version it on every poll — the storage cost and the "updated"
signal would both be lies. The feed keeps `(feed, external-id) → content-hash`
in its own table (possible since #121) and skips an unchanged item, so an
unchanged poll costs one comparison and no write.

Exactly-once is not the property to aim for; **idempotence** is. The platform
already prefers that shape: `doc_trigger_fires` claims `(trigger, version)`
before the run starts and a re-upload is a new version that fires again.

### FEED‑8 · The ranked queue is the plugin's own table and route

🔑 **This is the correction in §5 above, and it changes who builds what.**

The queue needs ordering by priority, a due-date comparison and a status filter.
`repo-list` cannot do any of them, attribute values are strings, and there is no
JSON SQL in either dialect — so a core implementation means typed storage and a
dialect-specific query, which is a schema decision with the `meta LIKE` trap
attached.

The plugin keeps its own typed table — `x_feeds_items(object_id, priority INTEGER,
due_epoch BIGINT, status TEXT, skills TEXT)` — written when an item lands, and
serves `GET /api/x/feeds/queue` ordered the way the customer needs. The
documents stay the source of truth; the table is an index over them.

**This means the customer can build now**, on seams that shipped: plugin
migrations (#121), plugin routes (slice 63), plugin bundle screens (#20, #43).
If the queue later belongs in the core console that is a separate decision, and
it will want the typed columns anyway.

### FEED‑9 · A fetch is metered, and the dimension holds the queue

One new dimension, `feed.fetches`, in `QUOTA-HOLD-DIMS` so an over-budget team's
feed **stops** rather than hammering a source. Storage is already metered
(`storage.bytes`) and an agent run is already metered (`ai.tokens.total`); what
is unmetered is the polling itself. This protects the customer's own source
systems as much as the instance, which matters when the source is someone else's
API with its own rate limit.

### FEED‑10 · "An agent can do this one" is a PROPOSAL until a person says otherwise

The issue says *"some tasks may even just need an agent to say, I can do this …
and it can be performed safely"*. Two things to separate:

**Nothing prevents an acting tool today.** `register-tool!` takes an arbitrary
handler, so a tool that calls somebody's API already works. The requirement is
therefore **not** to build the capability — it is to govern it.

**So the v1 answer is: the agent writes a proposal, and a `review` step gates the
act.** LAY‑1…3 exists precisely so a machine's output can be a proposal with a
recorded, hash-chained decision and a four-eyes rule. An acting tool must:
declare that it acts; run inside a workflow with a review step before the act;
record what it changed in the audit log with the target named; and receive only
the credentials it declared.

**I would not ship the act without the gate**, and would rather say so now than
have it arrive as a surprise: the blast radius of a mistaken devops action is
outside this system, where none of the platform's own guarantees reach. An
optional gate becomes an off switch the first week somebody is in a hurry.

### FEED‑11 · Scope of v1

In: FEED‑1 … FEED‑9, plus FEED‑10's proposal half.
Out, deliberately: acting without a gate; a core-console queue; more than one
source adapter.

## Slice plan

| # | Slice | Depends on | Acceptance |
|---|---|---|---|
| 1 ✅ | **Recurring jobs** — `schedules`, the reaper sweep, `POST /api/schedules` | — | A schedule fires once per interval; a missed week fires once, not 672 times; two concurrent sweeps produce one job (unit, both dialects); an overrunning run skips and reports |
| 2 ✅ | **The outbound seam** — one client, two policies | — | `'untrusted` refuses 10.x/127.x/169.254.x and a DNS name resolving to them, with the connection pinned to the resolved address; `'configured` reaches a private host; the default is `'untrusted`; a fetch leaks no descriptor over 100 calls (measured, as `llm.rkt`'s was) |
| 3 ✅ | **Feed configuration** — `feeds` row, sealed secret, `CREDENTIAL-SECRETS`, the probe | 2 | `telemachus-secrets rewrap` rotates a feed secret; a failing fetch records host + status and **not** the query string (positive-controlled with a token in the URL) |
| 4 ✅ | **The adapter** — one concrete source, items land as repo objects | 1,2,3 | An item becomes a repo object the configured user can read; an unchanged item on the next poll writes no new version; `feed.fetches` is charged and an over-budget team stops |
| 5 | **The queue** — plugin table, route, screen | 4 | "The first actionable task" is one request, ordered by priority then due date, filtered by status, scoped by `can?` |
| 6 | **Proposals** — the agent reads an item and proposes; a review gates it | 4,5 | A proposal is a document derived from the item; the act does not run until a person decides; the decision is in LAY‑11's chain |

Slices 1 and 2 are the platform work and are what #121's reporter and RSCH both
wait on. Slices 3–6 are a plugin.

## The owner's answer, and what it changed (23 Oct 2026)

The blocking question was answered, and it named **six** sources rather than
one: a GitHub issue tracker, CERT advisories against the pinned BOM dependencies
their own source scanning finds, Kuma uptime alerts, feeds from Discord servers
they operate, Matrix chat notifications, and OTel server notifications.

One consequence, and it is a design change rather than a scheduling one: **the
adapter registry is built now** (FEED‑14). With one source a registry is
speculative scaffolding; with six, five of which are "JSON over HTTP with a
different item shape", a `cond` in the fetch loop is the thing #110 r1 kept
finding — and it would put the next source's parser inside the code that spends
the team's quota and writes its documents. So an adapter is a registry entry
with LAY‑7's ownership rule, a plugin can contribute one under
`x.<plugin-id>.<name>`, and `FEED-KINDS` is derived from what is registered.

**GitHub issues is the one built**, because it was named first and because it is
the only one of the five whose own API shape this repository can exercise. The
sixth, Matrix, is not a shape but a protocol, and it is issue #133.

The other two questions — a plugin screen or the core console for the queue, and
whether FEED‑10's gate is acceptable for v1 — are still open and still do not
block slice 5's design.

## Three questions that need the owner's answer

1. **Which source first?** The requirements cannot be final without one concrete
   adapter — a Jira, a GitHub, an RSS, a filesystem drop. It decides what
   `external-id` and `priority` even mean, and whether auth is a token, OAuth or
   nothing.
2. **Is a plugin screen acceptable for the queue, or must it be the core
   console?** FEED‑8 says plugin, which is buildable today; a core tab is a
   bigger change and the integrator's guide already states that a plugin cannot
   add one.
3. **Is FEED‑10's gate acceptable for v1?** If the customer needs unattended
   action in v1, that is a different conversation with its own decisions, and I
   would want to have it explicitly rather than by implication.
