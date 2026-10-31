# inbox

A team's inbox of things that need a person. Something outside raises an item, the team moves it
through a short lifecycle, and the digest answers "what is waiting, how bad, and for which part of the
business". Plugin id `inbox`: routes under `/api/x/inbox/`, tables `x_inbox_*`, job kind `x.inbox.wake`.

It is an index and not a policy (INBOX-1, INBOX-2). It does not know where items come from, does not
derive a severity or a scope from a title, and does not own accounts. The producer says how severe an
item is, which scope it belongs to, and whether this is a new revision of a fact it already raised.

## One item

| Field | Meaning |
|---|---|
| `source`, `key` | The producer's own words. One live item per team, source and key. |
| `severity` | `critical`, `high`, `normal`, `low`. |
| `state` | `open`, `acknowledged`, `snoozed`, `suppressed`, `resolved`. |
| `scope` | A free-form label to filter and count by. Not an access boundary (INBOX-8). |
| `kind` | An optional label for the producer's own grouping. |
| `title`, `body`, `url`, `data` | What a person reads. `data` is a JSON object, at most 8 KiB. |
| `revision` | Optional. A different revision is a material change (INBOX-4). |

## Lifecycle

```
open --ack--> acknowledged
open|acknowledged|snoozed --snooze(until)--> snoozed --until passes--> open
open|acknowledged|snoozed --suppress--> suppressed
acknowledged|snoozed|suppressed --reopen--> open
any live state --resolve--> resolved   (terminal)
```

A resolved item is never dug up. The same `(source, key)` raised later is a new item with the next
`occurrence`. An act on an item already in the target state changes nothing and writes nothing.

## Raising an item

```
POST /api/x/inbox/items
{"source":"watcher","key":"nl:hpai","title":"Source changed","severity":"high",
 "scope":"org:a/market:jp","revision":"d1","url":"https://example.test/page"}
```

The answer says what happened, in `outcome`:

| outcome | Meaning |
|---|---|
| `created` | A new live item. |
| `reopened` | A new item for a key whose earlier item was resolved. |
| `refreshed` | Same revision. `last_seen` and `seen_count` moved, nothing else. An acknowledgement is not disturbed. |
| `revised` | A new revision replaced the content. State is unchanged. |
| `resurfaced` | A new revision replaced the content and sent an acknowledged or snoozed item back to open. |

A producer that polls every hour can raise the same item every hour without waking anyone.

## Reading

- `GET /items` is most severe first, then longest waiting. The default is open and acknowledged.
  `?state=`, `?severity=`, `?source=`, `?kind=`, `?scope=` (exact), `?scope_prefix=` (a subtree).
- `GET /items/:id` returns the item with its events in order: who acknowledged, when, and the note.
- `GET /digest` returns counts by state, open items by severity, the age of the oldest open one, and
  the top few. It takes the same `scope` and `scope_prefix`.

A snooze that has run out reads as open. Every read wakes the team's expired snoozes first, and
`x.inbox.wake` does it on a schedule for a team that wants the wake in the event log at the time it
happened.

## Permissions

`tasks:read` for reads and `tasks:write` for ingest and acts (INBOX-6). The platform has no inbox
permission, and adding one is a core change.

## Tests

```sh
raco test test/inbox-tests.rkt                                   # SQLite
DATABASE_URL=postgres://u@host:5432/db raco test test/inbox-tests.rkt   # PostgreSQL
```
