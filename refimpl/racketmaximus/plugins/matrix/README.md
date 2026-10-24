# Matrix notifications (issue #133)

Sends this instance's own events to a Matrix room on a homeserver **you** run.
Optional: with no homeserver configured the plugin registers no event sink and
no job kind, so an instance that does not use Matrix carries nothing extra.

## Configure the instance

```sh
export TELEMACHUS_MATRIX_HOMESERVER=https://matrix.example.internal
export TELEMACHUS_MATRIX_TOKEN=syt_...        # a bot account's access token
```

Both are the **operator's**, and the token is deliberately not in the database:
a plugin cannot own a sealed column (see FEED‑5 in `docs/design/decisions.md`),
and a credential stored unsealed is the failure that rule exists to prevent. So
there is one bot identity per instance — which is what a self-hosted notifier
is — and a tenant admin never sees the token.

The bot must already be **in** the room. The plugin never joins one: being
invited by a person keeps "who may be told" a decision made on the Matrix side,
where it belongs, and makes a mistyped room a named error instead of a bot
wandering into a public room.

A private, encrypted room is **not** supported: this sends plaintext events
through the client-server API, and end-to-end encryption would need a device,
key management and a megolm session — a different piece of work entirely. Use a
room whose history visibility you are happy with, and remember that a
notification carries ids and a link, never content.

## Subscribe a team to a room

```sh
curl -X POST "$BASE/api/x/matrix/rooms" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"room_id":"!abcdef:example.internal","events":"run.failed,review.decided","label":"ops"}'

curl -X POST "$BASE/api/x/matrix/rooms/$ID/test" -H "Authorization: Bearer $TOKEN"
```

`events` is `*` or a comma-separated subset of the platform's own closed event
vocabulary (`GET /api/x/matrix/rooms` lists it). The permission is
`webhooks:manage`, not one of this plugin's own: it is the same question — where
may this instance send notifications — and a plugin cannot add a permission to
the catalog, which is the platform's rule against a permission nothing enforces.

A room id is `!opaque:server`. An **alias** (`#room:server`) is refused, because
an alias is resolved by the homeserver and can be repointed at another room by
whoever controls it, which would silently redirect a team's notifications.

## What a room is told

Ids, status and a link — never content. No document title, no note body, no
model output. A room is read by people who may hold no permission on the thing
that happened, and Matrix rooms are routinely bridged somewhere else again.

```
run.failed: run 3f2a91bc (process-upload) FAILED — /api/runs/3f2a91bc-…
```

## What this is not

**It is not a guaranteed-delivery channel.** A notification is queued as an
ordinary job — so it inherits quota admission, the org gate, the lease and
cancellation — and the job tries twice, a second apart, which covers a
homeserver restarting. After that the failure is recorded on the room row
(`last_status`, `last_error`) and that is the end of it. Webhooks' ten attempts
with backoff live in a table built for them; duplicating that here would be a
second delivery subsystem inside a plugin. **If you need delivery guarantees,
use a webhook** — a missed chat line is not a lost event, because the audit log
and the webhook path both still have it.

The Matrix **transaction id** is the job's id, so a job the lease reaper
re-queued cannot post the same line twice: the idempotency is the protocol's.
