# Secrets and the front door


## Who may call at all

Before any of this: a request has to become a principal, and for a long time it could become one too easily. With no bearer token, the server fell back to two HEADERS — `X-Telemachus-User` and `X-Telemachus-Team` — and resolved them to that user. On a laptop that is a convenience: a script acts as somebody without minting a token. On an instance bound to a network address it was a login, and a free one: any caller on that network was whoever they said they were, with every permission that user holds. Note where this sits — *before* role checks, scopes, the org gate and session policy, none of which run until a principal exists. An identity mistake at that layer cannot be caught by any control above it.

The headers are honoured only from a trusted peer now: loopback, or an address the operator names in `TELEMACHUS_TRUSTED_HEADER_PEERS` because a reverse proxy really does terminate there. Nothing is trusted for looking private — “10.x is internal” is an assumption about somebody else’s network. `POST /api/bootstrap` is gated the same way, because an un-bootstrapped instance belongs to whoever calls it first, and on a LAN that is a stranger; an operator who cannot reach loopback presents a secret instead.

The rule lives in its own small module so it can be tested directly. That matters more than it sounds: every smoke runs on the same host as the server, so a smoke can never *be* a stranger, and this gap survived a year of them.

## What is hashed, and what cannot be

Passwords and API tokens are stored as hashes — a token as a peppered HMAC-SHA-256 with the pepper in the environment, so a database dump without the process’s environment cannot be replayed. Rotating the pepper signs everyone out at once, which is a fine emergency action and the reason it is rotatable. Tokens also expire now: a session after thirty days, a console-issued API token after ninety, and a row with no expiry is still “never”, so an upgrade signs nobody out.

Three secrets cannot be hashed, because they are not compared — they are *used*. A TOTP seed generates the code; an S3 secret keys the HMAC that verifies a signature; a push executor’s key signs its requests. All three used to sit in the clear, which made one dump — a backup, a replica, a `pg_dump` pasted into a ticket, a stolen volume snapshot — enough to replay every one of them.

## Sealing the rest

They are sealed with AES-256-GCM, keyed from the environment and never from the database. The claim is deliberately narrow, and worth stating precisely because the earlier note in the code got it half right: this defends a **dump** and does nothing for a **host**. An attacker running as the server reads the key out of its own environment. But a dump travels without that environment, and a dump is the thing that ends up somewhere it should not.

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

Every response carries a baseline set of headers, and the console carries a Content-Security-Policy that is same-origin for everything. Its script source is now a **per-request nonce** rather than `'unsafe-inline'` — which is the directive that lets an injected script tag execute.

Earning that cost more than the policy line. A nonce cannot authorize an inline event handler, and the console was built from a hundred and forty-one of them. They are all delegated listeners now: a render writes a data attribute holding an index into a registry of closures, and one listener per event type dispatches to it. The call expressions stayed where they were readable, and their arguments are now real values instead of being escaped into a string and parsed back out — which also removed a class of quoting bug where a title containing an apostrophe could break its own button. Style attributes keep their allowance: two hundred and fifty of them remain, and injected CSS is a far smaller prize than injected script.

One handler sat inside a single-quoted string rather than a template literal, so its registry call never interpolated and the funnel’s submit button shipped as dead text. No static check saw it; a browser test pressed the button and timed out. There are now static checks for both the inline handlers and that exact stranding, because the policy holds only while they hold.

## Files to open

`domain/authz/secretbox.rkt`, `domain/authz/authz.rkt` (tokens, 2FA, recovery codes), `cli/telemachus-secrets.rkt`, `docs/ops/secrets-at-rest-runbook.md`, `test/secretbox-tests.rkt`, `test/console-tests.rkt`.
