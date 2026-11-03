# Email delivery and notifications

> Status: **built**, except the one thing named at the end — a quota dimension
> for the API a plugin calls. Decisions **MAIL‑1…MAIL‑24** in
> `docs/design/decisions.md`; the working notes are the "Email delivery and
> notifications" section of `CLAUDE.md`.

The ask, in the owner's words: *"We need a means of integrating with email
delivery, email notifications. Notifications should be configurable by an admin,
and can be configured. And per user, notifications should be configurable.
Plugins can use the email api for notifications, and can be used for something
like a notification of a workflow completion, for example."*

Four things, and the fourth is nearly free: **a transport**, **an admin's
configuration**, **a person's configuration**, and **an API a plugin may call**.
The workflow-completion example needs no new event — `run.completed` has been in
`EVENTS` since #85 and is already emitted.

## What was already here, and the one thing that was not

Almost all of this is assembly, which is worth saying plainly before any of it is
justified:

- **`EVENTS` is a closed vocabulary of seven** (`events.rkt`) and `emit!` already
  fans out to named sinks. #133 made the sink a registry precisely so a second
  notifier would not have to displace webhooks. Email is the third subscriber and
  needs no change to that seam at all.
- **The delivery shape exists twice.** Webhooks (#85) is a table with
  claim-before-send, exponential backoff, a dead letter and a sweep on
  `set-reaper!`; Matrix (#133) is a job kind with two attempts and no table. Email
  wants the first, for the reason in MAIL‑7.
- **The three-layer tighten-only resolution exists twice**, in `features.rkt`
  (#63) and session policy (SESS‑4). A notification preference is the same shape
  with a fourth layer.
- **`net/smtp` is in base Racket**, with `#:auth-user`, `#:auth-passwd`,
  `#:port-no`, `#:tcp-connect` (implicit TLS) and `#:tls-encode` (STARTTLS). So
  the transport is **no new dependency and no change to the Nix closure.**

And the thing that was not here:

> **`users.email` has existed since migration 0001 and NOTHING IN THE TREE HAS
> EVER WRITTEN TO IT.** `create-user!` does not take an address;
> `POST /api/profile` takes `locale` and `timezone`; `POST /api/members` takes a
> username; `provision!` uses the address as the *username* and leaves the column
> NULL. So the column is NULL on every row of every instance.

That is #113's shape — a field declared, published in the schema, and filled by
nothing — and it is why the first slice is not the transport. A notification
subsystem built on that column would have sent nothing, to nobody, for ever, and
the only symptom would have been silence.

## The address, the transport, the queue

### The address (MAIL‑4…6)

`users.email` becomes writable through `POST /api/profile`, beside `locale` and
`timezone`, which is where a person's own durable preferences already live.

**An address is not used until it is verified.** `email` is what somebody
*claimed*; `email_verified_epoch` (migration 0069) is what makes it deliverable.
Changing the address clears the epoch, because a change is the case this
protects: a typo'd address receives another person's notifications indefinitely
and nothing says so. The verification token is hashed through **`hash-token`**,
the one token-hashing rule — SEC‑3 found `activation_tokens` still on a pre-#13
bare SHA‑1 over a compiled-in salt, and the finding was that there were two rules
and the weaker one was the one nobody looked at.

**The verification message is the one message sent to an unverified address**,
and that asymmetry is stated rather than discovered. Everything else refuses.

### The transport (MAIL‑1…3, MAIL‑10…12)

One row, `instance:manage`, `GET/PUT/DELETE /api/email-transport`. Host, port,
`from`, the TLS mode, an optional user, and a **sealed** password — a core table
can own a sealed column where a plugin cannot (FEED‑5), and the password is
listed in `CREDENTIAL-SECRETS` **in the same commit as its `CREATE TABLE`**: a
sealed column `rewrap` does not walk is silently unrotatable, and here that means
every notification on the instance stops for ever at the first key rotation.

Matrix put its credential in the environment (MTX‑3) because it is a plugin and
had no other choice. This is core and the requirement is that an **admin**
configures it, so it is a row: no restart, and no shell on the box.

**A team configures nothing about the transport.** A team-chosen SMTP host is an
SSRF primitive, and the `From` address is the instance's own identity — a team
able to set it could send mail as the instance. One row.

**#142's egress gate does not apply and that is not an omission.** `net/smtp`
opens its own socket, so `fetch.rkt` is not on this path. FEED‑4's rule is that
the policy attaches to *who chose the address*: this one is the operator's, the
same trust as `TMACH_MODEL_URL` or `executors.json`. A member cannot reach it.

**`POST /api/email-transport/test` sends one message, synchronously, and stores
only the outcome.** #85's ping, for #85's reason: a transport nobody can test is
a transport nobody trusts — and an operator who has just typed a password needs
to know before anybody's notification depends on it.

### The queue (MAIL‑7…9)

`email_deliveries` is webhooks' table with the URL swapped for a recipient.
Claim-before-send (WHK‑1), `attempts` compared as well as set so two senders
cannot both win a row, the due time moved out *before* the send so a sender that
dies leaves a row that becomes due again on its own backoff (WHK‑2), and a dead
letter an operator can read.

Email needs this more than a webhook does, not less: an SMTP server is routinely
unavailable for minutes at a time, so the retry curve is load-bearing rather than
belt-and-braces — and a duplicate send is not an idempotent POST somebody can
dedupe, it is the same email in a person's inbox twice.

**A permanent refusal is distinguished from a transient one.** A 5xx SMTP reply
is a retry; a 5xx *permanent* reply (a rejected recipient, a refused relay) is a
dead letter on the first attempt, because nine more attempts are nine more
identical refusals. Webhooks' own 4xx/5xx split, in SMTP's vocabulary.

**A message carries ids, status and a link — never content** (MAIL‑9). MTX‑8, and
it binds harder here: an inbox leaves the instance altogether, rests on a third
party's server, is indexed by them, and is forwarded onwards by its reader. The
workflow **slug** rides along for Matrix's own stated reason — a team's own word
for a process is not document content, and without it "run 3f2a finished" tells
nobody which thing finished. **The subject line goes through the same composer as
the body**, so a subject cannot leak what a body refuses.

## Who hears about it (MAIL‑13…19)

A **category** is a group of events a person would want to hear about together,
and it is a second closed vocabulary over the first: `EVENTS` is what the
platform emits, a category is what somebody subscribes to. They are not the same
list and collapsing them would make the preference surface seven checkboxes of
which two matter.

    workflows   run.completed, run.failed
    documents   object.created, object.deleted
    reviews     review.decided
    jobs        job.completed

**Three layers, tighten-only**: instance → org → user. `features.rkt`'s
resolution order and SESS‑4's argument — an admin turning a category off for the
instance must not be overridable from below, because that is the whole point of
having an instance switch. A **person may always turn a category off**, including
one every layer above them allows, and that choice survives the layer above being
switched back on: an opt-out is a standing instruction, exactly as a team's own
feature row is.

A person may **not** turn on a category their admin disabled. The resolution
reports **which layer said no**, because "why am I not getting these" with three
documents to diff by hand is a poor answer (`disabled_by`'s rule).

**There is no TEAM layer, and that is a stated limit.** An event is emitted for a
team, so "workflow mail from this team but not that one" is a real want — and it
is a refinement: a person is in one org and several teams, so a per-team
preference makes "do I get these" depend on which team a run was in, which
doubles the surface and the console card for a want nobody has stated. Because
the resolution reports which layer answered, a fourth layer is additive.

**Absence means enabled at every layer**, so an instance that configures nothing
behaves as it did. What stops an upgrade from mailing everybody is MAIL‑5 and
MAIL‑10, not the preference default: with no transport configured and no verified
address anywhere, nothing is sent.

**The fan-out is per-recipient and is authorized per recipient.** An event is
emitted for a *team*; a notification goes to *people*. So the sink resolves the
team's active members, and for each one asks the preference layers AND `can?` on
the subject — TAG‑6's rule, that a count is a count but somebody's words are
somebody's. A member who cannot read the document must not learn from their inbox
that it exists.

## The API a plugin may call (MAIL‑20…24)

    (mail-notify! conn event team data)      ; the sink's own entry point
    (mail-enqueue! conn #:recipient … #:category … #:subject … #:body …)

The first is what a plugin wants and what the platform's own sink calls: it
resolves the layers, composes the message, asks `can?` per recipient and writes
the rows. A plugin names an event and hands over ids; it does not compose a
subject, choose a recipient, or reach the transport. The second is the one INSERT
everything goes through, including the two transactional messages, and is what a
plugin would reach for only to send something that is not a notification.

**That is the whole safety argument.** An email API a plugin can hand arbitrary
text and an arbitrary recipient is a spam cannon with the instance's own
reputation behind it, and the `From` address is the instance's identity. So a
plugin may reach *the team's own verified members who have not opted out*, with
*ids and a link*, and nothing else. A plugin that needs to mail a stranger is
asking for a different feature, and the honest answer is that it should ship a
webhook receiver.

**Rate limiting is the one thing NOT built, and it is the next thing to build.**
A plugin calling `mail-notify!` in a loop meets the preference layers and `can?`
and no quota dimension at all, so what it meets after that is the instance's own
mail reputation. The shape is settled by four precedents — `ai.help.total`,
`ai.transcriptions.total`, `ai.embeddings.total` and `ai.judgments.total` are
each their own dimension for each one's own stated reason — and the argument here
is the same: a message is not a token, so it cannot share a token budget. It
belongs in `QUOTA-HOLD-DIMS` only if a limit should hold a team's job queue,
which for mail it should not: a notification nobody can send is not work to
defer.

## Deliberately not built, and said so rather than discovered

- **No bounce or complaint handling.** It wants an inbound path (IMAP, or a
  webhook from a provider) and a suppression list, and a suppression list that
  nothing populates is worse than none. A hard bounce today is a dead letter with
  the SMTP reply on it, which an operator can read.
- **No HTML body.** A notification is one line, a status and a link; an HTML part
  doubles the composer and invites a template, and a template is where content
  starts to leak back in.
- **No digest or batching.** "Four runs finished" is a different subsystem (it
  needs a window, a schedule and a per-person cursor) and it is the obvious second
  request. The categories are the seam it would hang off.
- **No vendor HTTP API** (SES, Postmark, SendGrid). SMTP is what a self-hosted
  instance can point at its own Postfix, and a vendor adapter is exactly what the
  slice-3 API makes possible from a plugin — which is where it belongs, since each
  one is somebody else's credential and somebody else's wire.
- **No unsubscribe link in the message.** It would need a route that mutates a
  preference from an unauthenticated GET, which is a CSRF surface on a platform
  that has deliberately kept a no-cookie JSON API. The preference is in the
  console, and the message links to it.
