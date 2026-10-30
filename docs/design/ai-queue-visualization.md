# A picture of work moving through the AI queue

**Issue #184. The design shipped first, on its own, as the issue asked; the
build landed 30 Oct 2026.** The issue asks for a design "with the retention
question answered, before any rendering code", and the retention question turns
out to have a better answer than either of the two the issue offers.

Decisions **QVIZ‑1…13** are recorded in `docs/design/decisions.md` — ‑10…‑13 are
what the build found, and QVIZ‑10 is the one worth reading before touching any
of it.

## The question the picture exists to answer

An operator has been told "it's slow". Three states look identical in a depth
count and have different remedies, and the #169 fleet runs produced all three:

- work **queued behind other work** — nothing is wrong; it is working through,
- work the platform is **holding** (`waiting`: a concurrency cap or an AI
  budget), which clears on its own,
- work **no live host can run** (`runnable: false` / `unclaimable`), which
  nothing clears but an operator,
- and, since #172, work **held by a host that has paused itself**
  (`held_by_paused`) — alive, matching, and not taking work, which is what the
  readiness gate produces every time a GPU host loses its card.

That is four, not three, and the four **partition** the queued set. A picture
that makes them one shape is the whole of priority 1.

## QVIZ‑1 — The retention question: neither option, because the table already answers it

The issue offers two: sample client-side (a live view, nothing on reload) or
decide to retain counters somewhere. **Neither is needed for two of the three
series, and the third needs one column rather than a store.**

| series | where it comes from |
|---|---|
| **arrivals** per minute | `jobs.created_epoch`, a `GROUP BY` — migration 0041 |
| **claims** per minute | `jobs.started_epoch`, stamped in `claim-job!` — migration 0038 |
| **completions** per minute | **not derivable today** — see below |

`jobs.finished_at` is `TEXT CURRENT_TIMESTAMP`, whose format differs by dialect:
SQLite writes `2026-10-29 04:16:09`, PostgreSQL `…225696-07`. Bucketing on it
would be wrong on one engine and invisible on the other — the exact trap
migrations 0038, 0039, 0040 and 0041 each name in their own comment. So the
build slice adds **`jobs.finished_epoch`**, the fifth instance of that same
shape, stamped where `finish!` and `worker-complete!` already write the terminal
row, with no backfill: a pre-migration job reports no completion minute rather
than a guessed one, which is DEL‑9's rule (an unknown age means never stale,
never infinitely old).

**Why this is better than either option the issue names.** Client-side sampling
has nothing on reload, and "it's slow" is a question asked *after* the fact — a
view that only knows what happened while it was open cannot answer it. A
retained counter table is a second copy of a decision the rows already carry,
which is the issue's own second constraint ("every figure should be derived at
read time"). Deriving from `jobs` means:

- **there is no retention decision to make.** How far back the picture goes is
  bounded by what already bounds those rows — #59's per-job content purge keeps
  the row, and #86's retention rules delete it on the team's own horizon. An
  operator who has set a seven-day horizon gets seven days of flow, because that
  is what they asked to keep. No new policy, no new sweep, nothing to configure.
- **it survives a reload and a restart**, which a sampled series does not.
- **it cannot disagree with the queue read**, because it is the same table.

Client-side sampling is kept for exactly one thing: the **lease countdown**,
which is already per-second and already client-side on the Workers card.

## QVIZ‑2 — The shape is inline SVG, not a chart library

`script-src 'self'` with no `'unsafe-inline'` since #110 r6, and bundle assets
must be same-origin — so a CDN chart library is blocked by policy and a vendored
one is a third-party dependency shipped for four small pictures. Each of the
four is a shape this codebase can draw by hand:

- the **stuck breakdown**: one horizontal stacked bar, four segments, each
  already a figure the queue read answers;
- the **three flow series**: three sparkline rows of `<rect>`s over a fixed
  minute grid;
- the **per-host lease**: a bar per holding executor, its width the fraction of
  the lease remaining;
- the **attempt path**: a row of pills, one per holder.

The Mentor mark is already hand-authored SVG inheriting `currentColor`
(`01-base.js`), and the theme tokens are CSS custom properties, so a drawn
picture is themed for free where a library's canvas would need a second palette.

## QVIZ‑3 — The attempt path is already recorded, and FLEET‑1 is why

Priority 4 asks for "attempts and releases as a path, not a counter". That
history exists: `reap-orphans!`/`reap-leases!` write `job.lease.expired` **per
attempt, naming the executor, BEFORE the UPDATE** — precisely because the
requeue sets `executor_id = NULL` and afterwards nothing in the `jobs` table
says which machine dropped the work. `job.attempts.exhausted` carries `holders`,
oldest attempt first. So the path is a read of the audit log by resource id, not
a new table.

**What it needs that does not exist: a way to ask for one job's trail.**
`audit-list` filters by team and does not project `meta`, which is where the
executor's name lives — the gap #59 and the anchor slice each paid for once. The
build slice therefore needs a narrow read, `instance:read`, returning the
ordered holders for one job id and nothing else.

## QVIZ‑4 — No payload, no result, no exceptions

The queue read crosses every team and org on the instance and carries neither by
design. A picture must not be the thing that reintroduces content into an
operator view, and the temptation is specific: a tooltip showing "what this job
is" is one `payload` field away. The answer is that **a job is identified by
kind, team and id** here, and an operator who needs to know what one contains
uses the team-scoped `GET /api/jobs/:id`, where `can?` decides.

## QVIZ‑5 — It lives on the Health tab (#179), not beside the Workers card

The issue says "beside the Workers and Queue cards", which at the time meant the
Admin tab. #179 builds a Health screen whose purpose is exactly this question,
and which **composes** the existing Workers and Queue cards rather than
re-rendering their figures — so the visualization belongs there, above the cards
whose numbers it is drawing. Two renderings of one set of figures is
`executor-can-run?`'s drift and LIVE‑IN's shape; the picture and the table must
read the same response.

## QVIZ‑6 — `instance:read`, and the refresh is explicit

#124 made that permission exist so a monitoring credential need not be able to
reset a password. A live view wants to update itself, and the console polls
nothing today except a workflow run — which is also what keeps an idle console
genuinely idle (#38: the idle clock counts from the last REQUEST, so a
self-refreshing screen would hold a session open indefinitely). So the refresh
is a **button and an explicit interval the operator chooses, defaulting to
off**, and the screen says when its figures were read. A dashboard that silently
keeps a session alive is a security control quietly disabled by a convenience.

## QVIZ‑7 — The minute grid is fixed, and gaps are drawn as gaps

A sparkline over "the buckets that had jobs" compresses idle time and makes a
stopped queue look busy. The grid is every minute in the window whether or not
it has rows, so a flat run of zeros is visibly a flat run of zeros — which is
the difference between "the queue is deep" and "the queue has stopped", the
issue's priority 2.

## QVIZ‑8 — The window is a control and is named on screen

#178's lesson, already paid for once on the Workers card: figures over a window
whose name is in a tooltip say nothing about themselves, and they silently
change meaning when the window moves. Same vocabulary as that card
(`?hours=`, clamped to 720 by the server) so an operator learns one control.

## QVIZ‑9 — What this design deliberately does not include

- **A chart library**, for QVIZ‑2's reasons.
- **A time-series store or a counter table**, for QVIZ‑1's.
- **A per-job timeline for every job**: the path is drawn for one job on
  demand, because the trail is an audit read per job and a list of 25 would be
  25 reads.
- **An OpenMetrics rendering.** It is the obvious sibling and was declined once
  already as a convenience for one scraper; this design does not need it and
  does not preclude it — the derivations it adds are exactly what one would
  render.
- **Cancelling anything.** The queue read is read-only on purpose: cancelling
  is team-tier (owner-ok or `jobs:cancel`), and an operator stopping another
  company's job is its own decision (FLEET‑4).

## The build slice, as it landed (30 Oct 2026)

1. **`jobs.finished_epoch`** — migration `0066-job-finished-age`, no backfill.
   Stamped at **eleven** terminal writes, not the two this document estimated,
   through one shared `finished-set` clause in `scheduler.rkt`. See QVIZ‑10.
2. **Three derived series + the four-way breakdown** —
   `GET /api/admin/queue/flow`, `instance:read`, bucketed over a fixed grid
   across `?hours=`. The breakdown rides the same response so the bar is one
   instant.
3. **One job's holder trail** — `GET /api/admin/jobs/:id/trail`, from the audit
   rows FLEET‑1 already writes.
4. **The four drawings** — `static/console/18-queueviz.js`, on the Health tab,
   above the cards they summarise.

```sh
raco test test/queue-viz-tests.rkt                              # 7 cases, 4 controls
DATABASE_URL="postgres://…" raco test test/queue-viz-tests.rkt  # the whole file, both dialects
bash test/pull-smoke.sh                                         # §7c, 23 assertions over HTTP
bash test/e2e/validate.sh                                       # §7c — four SVGs under `script-src 'self'`
```

Steps 1 and 2 remain independently useful: the series are the half an
OpenMetrics exporter would want, and they are verifiable on both dialects
without drawing anything. **An OpenMetrics rendering is still not built**
(QVIZ‑9) and is now a smaller job than it was, because these derivations are
exactly what one would render.
