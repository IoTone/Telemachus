# Secrets and the front door


## Who may call at all

Before any of this: a request has to become a principal, and for a long time it could become one too easily. With no bearer token, the server fell back to two HEADERS — `X-Telemachus-User` and `X-Telemachus-Team` — and resolved them to that user. On a laptop that is a convenience: a script acts as somebody without minting a token. On an instance bound to a network address it was a login, and a free one: any caller on that network was whoever they said they were, with every permission that user holds. Note where this sits — *before* role checks, scopes, the org gate and session policy, none of which run until a principal exists. An identity mistake at that layer cannot be caught by any control above it.

The headers are honoured only from a trusted peer now: loopback, or an address the operator names in `TMACH_TRUSTED_HEADER_PEERS` because a reverse proxy really does terminate there. Nothing is trusted for looking private — “10.x is internal” is an assumption about somebody else’s network. `POST /api/bootstrap` is gated the same way, because an un-bootstrapped instance belongs to whoever calls it first, and on a LAN that is a stranger; an operator who cannot reach loopback presents a secret instead.

The rule lives in its own small module so it can be tested directly. That matters more than it sounds: every smoke runs on the same host as the server, so a smoke can never *be* a stranger, and this gap survived months of them.

## What is hashed, and what cannot be

Passwords and API tokens are stored as hashes — a token as a peppered HMAC-SHA-256 with the pepper in the environment, so a database dump without the process’s environment cannot be replayed. Rotating the pepper signs everyone out at once, which is a fine emergency action and the reason it is rotatable. Tokens also expire now: a session after thirty days, a console-issued API token after ninety, and a row with no expiry is still “never”, so an upgrade signs nobody out.

Three secrets cannot be hashed, because they are not compared — they are *used*. A TOTP seed generates the code; an S3 secret keys the HMAC that verifies a signature; a push executor’s key signs its requests. All three used to sit in the clear, which made one dump — a backup, a replica, a `pg_dump` pasted into a ticket, a stolen volume snapshot — enough to replay every one of them.

## Sealing the rest

They are sealed with AES-256-GCM, keyed from the environment and never from the database. What this protects is deliberately narrow, and worth stating precisely because the earlier note in the code got it half right: this defends a **dump** and does nothing for a **host**. An attacker running as the server reads the key out of its own environment. But a dump travels without that environment, and a dump is the thing that ends up somewhere it should not.

    enc:v1:<key-id>:<nonce>:<ciphertext+tag>

Anything without that prefix is plaintext and is read as-is, so adopting a key is not a migration and needs no downtime: rows seal as they are rewritten, and a CLI seals the rest. The same CLI rotates — a previous key reads, the current key writes — and it is deliberately not something the server does at boot, because a mistyped key at startup would seal every row with a key nobody has. Running with no key at all remains supported; that is the “the database is the trust boundary” position, and the only change is that it is now visible in the boot line and in the admin status rather than inherited silently.

Two details carry weight. Each value is sealed with its own column and row id as additional authenticated data, so a ciphertext lifted out of one row and pasted into another does not open — someone with write access cannot move a known secret onto another principal. And a sealed value that will not open *raises*: it must never degrade to an empty string, because an empty TOTP seed would silently disable somebody’s second factor.

## The second factor, and the way back in

A password can be changed and an access key re-issued. A TOTP seed cannot be rotated by using it, which is what made a leaked one permanent — so it is revocable: a user can turn their own off, and an operator can revoke anyone’s, both audited. That covers the leak. It does not cover the lost phone, so enrolment also hands out ten single-use **recovery codes**, and a code is accepted anywhere a TOTP code is. Unlike the seed, a code *is* compared, so it is hashed like a token.

The small decisions are where the value is: matching forgives case and dashes, and the alphabet drops the characters people confuse, because these are read aloud and typed off paper; spending a code is the same statement that matches it, so two simultaneous sign-ins cannot both spend one; a spent row is kept rather than deleted, so “already used” stays distinguishable from “never issued”; re-issuing replaces the whole set, because a set on paper should be the whole truth about what opens the account; and revoking the second factor deletes the codes with it.

## How long a session lasts

Two clocks, because they answer different attacks. An **idle** timeout limits an unattended desk; an **absolute** cap limits a stolen token that is being used, which never idles out. The shipped defaults are thirty minutes and eight hours — the least disruptive ends of OWASP’s own bands — and `null` on either means no limit on that axis, spelled explicitly so that “I did not set this” and “I turned this off” cannot look the same.

Only a SESSION is governed. A machine token is idle by design, and idling one out is a silent outage, so API and worker tokens are exempt — and the parameter that says which a token is defaults to the exempt value, so a caller who forgets it mints a token that behaves as tokens always did. The clocks are epoch columns rather than the text timestamps beside them, because a text `CURRENT_TIMESTAMP` formats differently on each dialect and a rule comparing those would be invisible on one and wrong on the other.

An instance sets the policy and a company may TIGHTEN it, never loosen it: the effective value is the stricter of the two per axis. That is deliberately the opposite of branding, where the company’s document wins whole — branding is cosmetic, this is a control, and the instance owns the floor. Enforcement is in `resolve-token` and nowhere else, the one place a bearer becomes a principal; a lapsed session is revoked with a reason, so the token list can say why it ended and a lapsed session cannot be revived by using it.

The console counts down against the last REQUEST, not against pointer activity. The server measures requests, so a mouse-driven timer would cheerfully show a live session the server had already expired.

## The console’s policy

Every response carries a baseline set of headers, and the console carries a Content-Security-Policy that is same-origin for everything. **Its script source is now `'self'` and nothing else** — no `'unsafe-inline'`, which is the directive that lets an injected script tag execute, and no nonce either. The nonce was the first answer and is gone: it existed solely to authorize the console’s own inline block, and once that block became files on disk it authorized nothing, so the policy is strictly narrower than the one the nonce earned. The baseline policy every *other* response carries still allows inline script, because a plugin’s own bundle page may legitimately ship some and that page is not the console.

Earning that cost more than the policy line. A nonce cannot authorize an inline event handler, and the console was built from a hundred and forty-one of them. They are all delegated listeners now: a render writes a data attribute holding an index into a registry of closures, and one listener per event type dispatches to it. The call expressions stayed where they were readable, and their arguments are now real values instead of being escaped into a string and parsed back out — which also removed a class of quoting bug where a title containing an apostrophe could break its own button. Style attributes keep their allowance, and the figure behind that was wrong when somebody finally counted: 392 of them, of which exactly **five** interpolate anything at all — a rounded number, a percentage, two variable names and the funnel’s theme. Removing the allowance means moving 387 static attributes to classes, which is why it is still declined; and the re-measurement also enumerated the thing that would have to go wrong first, since CSS injection needs HTML injection ahead of it. Of 1,499 interpolations across the console’s nineteen files, 373 go through the escaper, 550 are a known-safe shape, and almost all of the rest touch no server-supplied string — because the delegated-handler change returns an *index* and keeps the value in a closure. No path to HTML injection was found, so the CSP allowance is defence in depth on top of a control that holds, and the thing to re-run when a renderer is added is the enumeration rather than the attribute count.

One handler sat inside a single-quoted string rather than a template literal, so its registry call never interpolated and the funnel’s submit button shipped as dead text. No static check saw it; a browser test pressed the button and timed out. There are now static checks for both the inline handlers and that exact stranding, because the policy holds only while they hold.

## What the model is not told

Everything above is about keeping a secret *at rest*. The other direction is a
document leaving the process on its way to a model, and it has three parts.

**The detectors are named, not written.** A request to redact asks for classes —
emails, telephone numbers, national identifiers, a dictionary of terms the caller
supplies — and there is deliberately no way to supply a pattern. A pattern would be
operator-authored and run against the text of a document the operator does not
control, which is catastrophic backtracking with the operator’s own configuration as
the weapon, on the upload path. It is the same call that froze the funnel’s
validation vocabulary and the workflow binding sublanguage, and here it costs the
caller nothing, because nobody wants to write an email pattern.

**A token is stable inside one document and deliberately not across them.** Inside,
because that is the whole reason a span becomes a token rather than a black box — the
model can see that one person appears three times. Across, never: a token that meant
the same person everywhere would be a pseudonym, a pseudonym is a join key, and two
redacted documents would then tell their reader they concern the same person. Text
that already contains something token-shaped is *refused* rather than escaped, since
rehydration would otherwise write a real name where the document had an identifier —
the one failure here that invents data instead of losing it. Putting the values back
is one pass with a lookup, never a replacement per entry, or the tenth name rewrites
the first eight characters of the eleventh; a token the model invented is left
verbatim and reported, because guessing the nearest would put a real name into an
answer about somebody never mentioned.

The map is sealed whenever a key exists, *not* gated on the content switch whose
default is off — a column holding “PERSON_1 is this person” for every redacted
document needs that more than anything else in the schema — and **nothing serves it**.
No route reads it, which is how “it never leaves the instance” is kept by
construction rather than by validation. The same rule reaches the tool’s own result:
it carries the tokens and never the values, because a result lands in a step’s stored
output, the agent transcript and a console pane, which is three more copies than the
sealed row has.

**A step that redacts rehydrates before anything is stored**, so the extraction a
caller reads has the real values and the request that crossed the wire did not. Two
asymmetries in that are the interesting part. The classifier redacts for the *model*
and matches its own rules on the real text, because a rule is deterministic, local
and never leaves the process, so matching it on tokens buys nothing and costs
correctness. And the streaming endpoint *refuses* the option rather than ignoring it:
a token can be split across two server-sent events, so putting values back means
buffering the whole answer, which is the one thing a stream exists not to do — and
half-rehydrated text, a real name beside a token with no way to tell which is which,
is worse than a refusal.

**Which executors may see a labelled document’s unredacted text is a policy, and
absence means off.** A team labels a document through the ordinary metadata field it
defines itself; a policy at the instance and company tiers then names which backends
each label may reach. The tiers *tighten* where both speak. A label no tier mentions
is refused, which is the opposite of how an undeclared capability is read elsewhere
and is deliberate: the only way to reach that state is to remove a label from the
policy while documents still carry it. A loopback backend is outside the policy
entirely, so the ordinary single-box instance talking to a local model is unaffected.
A typo in the executor list fails closed, so it is *reported* on the read rather than
left to be discovered, and a refusal is audited with the label, the executor and the
backend’s host — never the text and never the document’s key.

**And there was no record of a model request at all.** The quota ledger counts
requests and can never answer what was sent, where it went, whose call it was, or
whether it was refused. The table that answers those is defined by what is not in it:
no prompt column, no reply column, no excerpt. Three paths leave this process and not
one — a plain call, a stream, and a job row a remote worker will claim — so a log
covering only the first would have been silent about exactly the two somebody would
check. The prompt is recorded as a keyed digest and not a bare hash, because a bare
hash of a name is the same digest on every machine in the world, which would make the
table a confirmation oracle over the exact identifiers redaction exists to remove.
With no key configured it is a plain hash and the row *says which*. And “this backend
does not log content” is an assertion nothing can verify, so what is enforced is that
somebody made it: a switch refuses a request to a backend that is not on this box
until its operator has declared it, per executor, and unset the request still goes
and the row reads “undeclared” — the gap visible rather than assumed.

## Files to open

`domain/authz/secretbox.rkt`, `domain/authz/authz.rkt` (tokens, 2FA, recovery codes), `cli/telemachus-secrets.rkt`, `docs/ops/secrets-at-rest-runbook.md`, `test/secretbox-tests.rkt`, `test/console-tests.rkt`, `domain/repo/redact.rkt`, `domain/repo/redactions.rkt`, `domain/ai/sensitivity.rkt`, `domain/ai/requestlog.rkt`, `test/redact-tests.rkt`, `test/sensitivity-tests.rkt`, `test/dump-leak-tests.rkt`.
