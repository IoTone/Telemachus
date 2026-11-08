# Health

> what an operator needs when told "it's slow"

One screen, five cards, one read. It needs `instance:read` — the narrow
permission an operator holds and a monitoring credential can be scoped to
without also being able to reset a password.

`read at HH:MM:SS` and a **Refresh** button. **Nothing on this screen polls
itself**, except the queue cards' own tick while the queue is moving: a
dashboard that refreshed every ten seconds would hold a session open for as
long as the tab was left up, which is an inactivity timeout switched off by
something that looks like polish.

## Server

- **Uptime**.
- **Database** — which engine, and its **Schema**: how many migrations are
  applied, and `N pending` if any are not. **A pending migration means one
  failed**, since migration runs at boot; the ids are named, because the id is
  the only actionable part.
- **Secrets at rest** — `sealed` or `plaintext`. *a dump of this database is
  replayable* is what plaintext costs, and it is a supported position (the
  "trusted database" one) rather than a fault — but it should be a decision
  somebody made.
- **TLS** — on, or `off`.
- **Blob store** — which store holds the document bytes. *verified at boot — the
  instance refuses to serve if it cannot write and read back.* So an instance
  that is answering has already proven its store once. **What this cannot tell
  you is whether the store has gone away since boot**: there is no probe on this
  screen, deliberately, because a read of an operator's dashboard must not write
  to somebody's bucket.
- **Drain window** — *how long a stop waits before handing running work back to
  the queue*, or `immediate`. This is the number to know before restarting.
- **Multi-tenancy** — whether the org layer is on.
- **Accounts** — `N users · N teams · N orgs`.

## Budgets

> this team's own — the three that actually stall work

Used, limit and window for the dimensions that hold a queue. **These are the
signed-in team's own figures, not an instance-wide total** — the card says so,
because there is no instance-wide roll-up. The instance-wide version of "what is
being held" is the queue card's own three figures below.

`no limit set` means no limit, which reads as nothing spent.

## The pictures, the fleet and the queue

- **Work moving through the queue** — the flow drawings, below.
- **Workers** and **Queue** — described in [Workers and the
  queue](workers.md). They are the same cards as on [Admin](admin.md).

## Work moving through the queue

Four small drawings over the window chosen for the fleet figures, so the
pictures and the numbers under them are over the same hours. `last Nh` and
`· N-minute buckets` say the window and the grain; a long window widens the
bucket rather than sampling.

**Refresh** here is **off by default**, and the hint says why: *a screen that
refreshes itself holds your session open.*

### What the queue is waiting for

> these four add up to the queued jobs, and each has a different remedy

- **No worker can run it**
- **Held by a paused worker**
- **Held by a cap or a budget**
- **Queued, working through**

When the queue is empty the four zeros are drawn **beside their colours** rather
than as a bar of nothing — four zeros say what the picture would show, and a
zero-width bar says nothing at all.

`sampled: oldest N` means the queue is deeper than one scan, so the bar is the
oldest rows rather than all of them.

### Flow

**Arrivals** (jobs enqueued in each bucket), **Claims** (jobs a worker or the
pool picked up) and **Completions** (jobs that finished, whatever their
outcome), each with its peak. Arrivals running ahead of claims for several
buckets is the shape of a fleet that is behind.

### Leases

Who is holding a job right now, and for how much longer.

> a lease quietly not being refreshed is what a failover looks like, 90 seconds
> early

`expired` on a row means the platform has already given that work back.
