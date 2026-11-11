# The threat model, per surface

**What this is for.** Issue #186 asked for a security sweep and named the method:
*"threat-model per surface, then a positive control for every claim — the
project's own standard, which is that a check nobody has seen fail is a check
nobody has."* Two passes were done before this document existed and each was ONE
enumeration — the request-scoped parameters, then the refusals that quote a value
— each chosen because the previous pass's leftovers pointed at it. Both found
real defects. Neither was a method.

This is the method, and it earns its place by a measurement rather than by being
asked for: **the public surface grew from 23 routes to 25 between the first pass
and the third, and the two new ones are in the exact class the first pass had
flagged and left open** — a public endpoint that redeems a mailed token with no
throttle. Nothing re-ran the survey, because nothing said when to. (SEC‑13 below
closes both; the point of the measurement is that nothing would have gone looking
for the second one, not that it stayed open.) A list of
surfaces with a re-run condition is what turns "we looked once" into "we look
when it changes", and `test/threat-model-tests.rkt` pins the two surfaces that
grow by accident so an addition has to be a deliberate edit of this file — the
shape `pollable_kinds` and the console's `src` tags already use.

**How to use it.** Each surface below says what an attacker reaches, who they
have to be, what is enforced and what is NOT. When you add a route, a listener,
a plugin seam or an outbound caller, find its surface and answer the four
columns; if the answer to the fourth changes, the row changes with it. **The
"not enforced" column is the valuable one** — it is where the next pass starts,
and a row that has nothing in it is almost certainly a row nobody has read
properly.

**What this document is not.** It is not an assertion that the enforced column is
complete, and it names the controls by the decision that established them so a
reader can go and check. Where a claim here has a positive control behind it the
row says so; where it does not, it says that instead.

## Surface 1 — the unauthenticated public

**Who reaches it:** anybody who can open a socket. **25 routes**, pinned in
`test/threat-model-tests.rkt`.

| | |
|---|---|
| **Assets** | the sign-in path, the instance's own identity and branding, the beta funnel and its prospect data, the bootstrap, and three endpoints that redeem a mailed token |
| **Enforced** | `POST /api/login` is throttled per account AND per address, with the two 429s deliberately identical so the throttle is not the oracle the body refuses to be (#116–#118); the username/unknown-account timing oracle is closed by running the live KDF against a dummy hash on BOTH cheap paths, and the test is a RATIO rather than a millisecond bound (#117). `POST /api/beta/signup` has the funnel's own velocity caps, disposable check and dedup. `POST /api/bootstrap` is loopback-or-secret and first-run-only (#40/#41). Every response carries the baseline CSP, `nosniff`, `Referrer-Policy` and `X-Frame-Options`; HSTS only under `TMACH_TLS`. A 500 body is `{error, request_id}` with the message on stderr (#123) — including inside an SSE stream, which kept the leak for a year after #123 (SEC‑1). |
| **Also enforced (SEC‑13)** | **`POST /api/activate` and `POST /api/password-reset/confirm` are throttled**, by ONE limiter keyed on the address, because the resource is one — the cost of a redemption attempt — and two budgets would double what an attacker can spend. The honest reason is NOT guessing (24 bytes of `crypto-random-bytes` was never guessable): it is that an unauthenticated caller could make this instance do unbounded peppered-HMAC and indexed-SELECT work. Generous at 30 in fifteen minutes with the shared-NAT cost stated, and the window self-clears, so unlike #116's account lock there is no state only an operator can clear. |
| **NOT enforced** | **`GET /api/i18n/catalog` is an unauthenticated amplification**: a tiny request for a whole catalog, uncapped. It must stay public, because the sign-in screen picks its language before anyone holds a token, so capping a public read is a decision rather than an oversight — and it is the one open item on this surface. |
| **Re-run when** | a route gains `#:auth 'public`. The gate fails until this section and the pinned list are both edited. |

## Surface 2 — the worker token

**Who reaches it:** a host holding a `jobs:execute` token minted by
`POST /api/executors`, shown once. Operator-registered, so semi-trusted — and
that is exactly why the rules here are written down rather than assumed.
**10 routes**, pinned.

| | |
|---|---|
| **Assets** | the job queue, every job's sealed payload, the documents a job names, and the team's repository |
| **Enforced** | every write about a claimed job carries the attempt's `claim_token` (#24), so a reaped-and-re-claimed job cannot have an earlier holder's result land on it; `holder-check` runs FIRST on every route, so a stranger cannot learn that a job exists. `/document` reads as the job's own USER, so `can?` decides, and a forbidden document and a missing one collapse to ONE answer (PULL‑9). `/derive` writes as that user too, inherits the source's visibility and then its grants, and sets `#:derived?` so a trigger cannot fire on it. A worker is not a way past `TMACH_MAX_UPLOAD` in either direction. |
| **NOT enforced** | **`jsexpr-strings` walks EVERY string in the payload**, so an object id merely MENTIONED in free text — a prompt somebody pasted — is a warrant. Deliberate ("the payload's shape is the kind's business") and wider than "the inputs this kind declares". **`#:version` is unconstrained**, so a worker may read a SUPERSEDED version of a document the payload names; the job's user can read it through the ordinary API too. |
| **Fixed by this pass** | **SEC‑9 — the derivation warranted the read and bounded nothing about the write.** `key` was whatever the worker said, so a claim on ANY job of a team could replace the current version of ANY document that job's user may write. Measured, not supposed: the control answers `ok: #t, version: 2, derived_from: <an unrelated scan>` against `documents/contract.md`. An existing object at the key must now already derive from THIS source. **The severity is bounded and stated: `repo-put!` has always checked an overwrite against the PRIOR resource, so a document the job's user may not write was never reachable** — there is no privilege escalation beyond that user, and what was broken is the module's own contract that "a worker token is not a key to the team's repository". |
| **Re-run when** | a route is added under `/api/workers`. The gate fails until this section and the pinned list are both edited. |

## Surface 3 — an authenticated team member

**Who reaches it:** anybody with a session or an API token. The largest surface:
286 routes, 37 of them resource-scoped.

| | |
|---|---|
| **Enforced** | the route table ENFORCES what it declares — `rt-auth`, `rt-feature` and, for a role-scoped permission, `rt-perm`, in that order, because reversing authentication and the feature flag would tell an anonymous caller which routes exist (#110 r2). `test/route-perm-gate-tests.rkt` asks, for every route, whether the permission it DECLARES is enforced anywhere reachable from its handler, and fails in BOTH directions — a granted permission that nothing enforces is a promise `GET /api/roles` makes and the server does not keep (#113). A token's SCOPES cap it below its role (RBAC‑4). Idle and absolute session timeouts are enforced in `resolve-token`, the one place a bearer becomes a principal (#38). |
| **NOT enforced** | a `'resource`-scoped route is deliberately NOT pre-checked, because a role-level pre-check is stricter than the handler's `can?` and would refuse exactly what document sharing built. That is 37 routes whose authorization is the handler's alone — which is why the gate reads the call graph rather than the table. |
| **Re-run when** | the resource-scoped count changes, or a new permission enters the catalog. Both already have gates. |

## Surface 4 — the company and instance planes

| | |
|---|---|
| **Enforced** | isolation is **step 0 of `can?`** — an unconditional deny before permissions, owner-ok, token scopes and resource grants, so a share cannot tunnel out of an org, and the gate never reads the feature flag (turning multi-tenancy off on a populated instance keeps enforcing). The flag gate answers **404** before any permission, so a single-tenant instance does not tell a stranger the plane exists. `org:*` does NOT imply `org:read-data`, so a company admin manages without reading (TEN‑2a/‑2h). `instance:manage` implies `instance:read` and the implication is ONE-WAY, which is what lets a monitoring credential read the fleet without being able to reset a password (#124). |
| **NOT enforced** | a team admin can point a model role at any executor NAME, including another org's, because `executor-known?` does not filter by org. Routing on `/api/ai/chat` and `/api/agent` is operator-only, so this is the one gap left in that area and it is recorded rather than closed. |

## Surface 5 — the S3 listener

Off by default (`TMACH_S3_PORT`). A second listener on `web-kit/http1`.

| | |
|---|---|
| **Enforced** | SigV4 verified against AWS's published vectors AND real captured aws-cli requests; the path is used AS RECEIVED and the payload hash comes from `x-amz-content-sha256`. Access keys are `repo_credentials`, sealed at rest (#19), scoped by RBAC‑4. Unimplemented sub-resources answer **501**, never a silent success — a swallowed bucket policy is the worst failure this subsystem could have. A presigned link is signed with the caller's own newest key, so revoking the key kills the link, and expiry is a separate check with its own verdict. |
| **NOT enforced** | the secret is stored **in the clear within the sealed column's plaintext** because SigV4 needs it to verify — the same trust boundary as `users.totp_secret`, stated rather than hidden. |

## Surface 6 — plugins

| | |
|---|---|
| **Enforced** | a plugin's routes mount under a platform-fixed `/api/x/<id>/` prefix, so one can never shadow a core route or another plugin's; core routes match FIRST, so `bundle/` cannot be claimed. A route is authenticated unless its own declaration says `'public` — declared, never inferred from a path — and a public route's handler is `(conn args)`, an arity the loader checks, so it cannot be handed a principal; a public route that names a permission fails its plugin's load (G13). A job kind must be named `x.<id>.<name>`. A migration is DATA, not a thunk, and every table and index must carry the plugin's prefix — schema-qualified names refused, because `public.users` walks past a check written on the bare name (#121). A plugin may not add a permission (MTX‑9), add a quota dimension or add a console tab, and the KEY a plugin seals with stays the platform's: it may declare a sealed column so a rotation walks it (SEAL‑1), it may not bring its own key into the platform's rotation. Out-of-process capabilities pass a DOUBLE gate: the plugin must have declared the scope AND the caller must hold the permission. A plugin that fails to load is REPORTED, and `TMACH_PLUGINS_STRICT=1` refuses to boot. |
| **NOT enforced** | an in-process plugin runs arbitrary Racket with the server's authority. That is the trust model, not a gap: installing one is an operator act. And a route a plugin declares `'public` is reachable by anyone who has the URL: the platform guarantees it was DECLARED and that its handler has no principal, not that what the handler reads is team-safe. That is the integrator's decision, and the only remedy the platform offers is the declaration being visible in `GET /api/plugins` and `plugins.md` (G13‑5). |

## Surface 7 — the console in the browser

| | |
|---|---|
| **Enforced** | **`script-src 'self'` with no `'unsafe-inline'` and no nonce** — the nonce existed only to authorize our own inline block and is gone with it (#110 r6), so an injected `<script>` or an `onerror=` attribute does not execute. `default-src 'self'`, `img-src 'self' data: blob:`, `font-src 'self' data:`, `connect-src 'self'`, `form-action 'self'`, `object-src 'none'`. The console's own output escaping was enumerated by this pass — **1,499 interpolations, and it comes back clean** — see the measurement below. No credential and no unsaved text reaches the URL fragment (ROUTE‑7), and `/activate` strips its own token from the address bar. Nothing polls, which is a security property: #38's idle clock counts from the last REQUEST, so a self-refreshing screen would hold a session open for as long as a tab was left up. |
| **NOT enforced** | **`style-src` keeps `'unsafe-inline'`**, and this pass re-priced it rather than acting on it — see below. |

### The measurement that re-priced `style-src` (SEC‑11)

The first pass listed "`style-src` still carries `'unsafe-inline'` with ~250 style
attributes behind it". Measured: **392 style attributes, of which exactly FIVE
interpolate anything at all** — a rounded number, a percentage, two CSS variable
NAMES, and the funnel's theme through `bxSan`. So the work is not "sanitize the
dynamic ones"; it is "move 392 static attributes to classes", because CSP blocks
the `style` ATTRIBUTE wholesale and `element.style.setProperty` from script is
not blocked at all.

**What re-prices it is that CSS injection needs HTML injection first, and this
pass went looking for that instead.** Every `${…}` in the console's nineteen
script files was enumerated — 1,499 of them — and classified: 373 go through
`esc()`, 550 are a known-safe shape, and of the 576 left, the ones touching a
server-supplied string are **almost all inside `H(…)`**, which returns an INDEX
and keeps the value in a closure. That is #27's delegated-handler change paying
off in a way its own notes predicted ("arguments are real values instead of
escaped strings, which also killed a quoting-bug class"). The three remaining
helpers that do put server data in markup are `esc` itself, `iv` (which is
`value="${esc(…)}"`) and `mdRender`, which **escapes FIRST and then runs its
block and inline rules over escaped text** (ED‑4) and is tested at runtime by
`demo-validate.mjs` §3c rather than by a source assertion, because a Markdown
renderer is effectively a sanitiser and that is a question about what code
COMPUTES.

So: no path to HTML injection was found, which makes `style-src 'unsafe-inline'`
defence in depth on top of a control that holds. A 392-site mechanical edit
across nineteen files, on a console whose coverage is source assertions plus one
browser gate, buys that depth at a real regression risk. **Measured and declined,
with the numbers**, which is #110 r7's shape for its five remaining complexity
rows. What would change the answer is an HTML-injection path turning up — and the
enumeration above is the thing to re-run, not the attribute count.

## Surface 8 — outbound egress

| | |
|---|---|
| **Enforced** | ONE fetcher (`domain/net/fetch.rkt`), `'untrusted` by DEFAULT so a caller that says nothing is safe, DNS resolved by name with the socket's real **peer** vetted before a byte is written, a byte cap, a timeout, a redirect cap with EVERY HOP re-vetted, credentials withheld off-origin, and the URL's query redacted on the way INTO the exception (FEED‑6). The policy attaches to **who chose the URL** (FEED‑4): a feed is operator-authored and may be `'trusted`; a bookmark is member-authored and has no `'trusted` mode at all, not even for an operator (RG‑3). A model request is logged with a KEYED digest of the prompt rather than a bare SHA‑256, which would make the table a confirmation oracle (RED‑18). `TMACH_REQUIRE_NO_CONTENT_LOGGING` refuses a hosted backend that has not declared itself, BEFORE the body is composed. A sensitivity label can refuse unredacted text per executor at two tiers (RED‑24). |
| **Also enforced (SEC‑12)** | a remote party's own words go through ONE home, `domain/net/remote-detail.rkt`, with BOTH halves: bounded at 400 characters saying it was cut, and made printable. Four askers — the model, embedding and transcription seams, the SMTP transport and the MCP client. Writing that home is what found the half `provider-detail` never had: its output becomes an exception message, so it reaches a sealed `error` column AND stderr, and a provider that put a CRLF in its own `error` string was writing into this instance's container log. |
| **NOT enforced** | text with no document is outside the sensitivity policy — a free prompt, the agent's tool results — because req 4 governs documents and any caller can paste content it read elsewhere. |

## Surface 9 — data at rest

| | |
|---|---|
| **Enforced** | AES‑256‑GCM with the AAD bound to `<table>.<column>:<row-id>`, so a ciphertext moved between rows does not open; the thirteen context strings are PINNED. `#:credential` seals whenever a key exists; `#:bytes` carries the content gate. **The audit of what is sealed is a WHOLE-DATABASE SCAN, not a list of sites** — the scan beat the enumeration twice (#83), and it has a control proving it finds the needle with encryption off. `telemachus-secrets rewrap` rotates, and a sealed column missing from its registry is **silently unrotatable**, which is why every slice adding one says so. |
| **NOT enforced** | this defends a DUMP, not a HOST: the key is in the environment, so anyone running as the server can read it. Stated since #19 and still the right scope. Volume encryption is necessary and not sufficient, because a running database decrypts for anyone it answers. |

## Surface 10 — the audit record

| | |
|---|---|
| **Enforced** | entries are hash-chained per org in a sweep (never at insert, which would FORK under two writers), the digest names every column one by one so a field outside it could be edited undetected, and verify checks the hash AND the link. The external anchor is Ed25519, not an HMAC — with a shared secret the verifier could have produced the receipt — and the SERIES is itself chained, so SILENCE is detectable, which is the attack a published chain otherwise has no answer to. `verify` needs neither the server nor the database, because an anchor is worth something precisely when the instance is the suspect. |
| **NOT enforced** | **the chain does not catch a rewrite by anybody who can WRITE the table**, who recomputes every later link — and that is the party an audit most defends against. The retained receipt is what closes it, and the platform cannot verify that somebody else kept one, so no read ever claims they did. |

## What a next pass should do

Ranked by what the columns above actually say, not by novelty:

1. **The `/api/i18n/catalog` cap** — the one open item on surface 1 that is a
   decision rather than a measurement, and **it is the owner's**: capping a
   public read that the sign-in screen depends on before anyone holds a token.
2. ~~**`provider-detail`'s fourth asker**~~ — **done, SEC‑12**, and it was not
   the cosmetic refactor it was ranked as: the one home turned up a fifth
   spelling and a disagreement, and the subsystem outside the comparison had the
   right answer.
3. ~~**Throttling the two token-redemption endpoints**~~ — **done, SEC‑13**, and
   the reason changed in the doing: not guessing, which was never feasible, but
   unbounded keyed-hash and database work for a stranger.
4. **Re-run the console interpolation enumeration** when a renderer is added;
   that is what makes surface 7's answer about `style-src` still true.

**That two of the four were done the same day they were ranked is the argument
for ranking them.** Both had been recorded by an earlier pass as "a refactor" and
"defence in depth" — true descriptions, and both wrong about the size of what was
behind them. A list that says what is left and why is the thing that gets read;
the leftovers at the end of an issue comment are not.

And the standing instruction, which is the whole point of the file: when a
surface grows, the gate fails. Edit the reasoning, not just the list.
