# Workers and the queue

**The worker fleet is the `Workers` card, and it is on two tabs: `Health` and
`Admin`.** There is no tab called Workers — the queue beside it is the `Queue`
card, on the same two tabs.

They are the same two cards in both places, drawn from the same two reads, so
the figures cannot disagree between the screens because there is only one of
each.

Both need `instance:read`, which an operator holds and which a monitoring
credential can be scoped to on its own.

## Workers

> the hosts that come and claim work

A worker is a machine that **asks for jobs instead of waiting to be called**,
which is how inference runs on a box of its own. `No workers yet.` says so.

### The columns

**models** — what each worker can serve.

> What each worker can serve. For a pull worker this is what it DECLARED on its
> last claim, which is what the platform matches a job's requested model
> against — not a value typed in when it was created.

Three things it can say, and the difference matters:

- The declared list, rewritten on every claim. **The first entry is what the
  worker answers with when a job names no model at all**, so the order carries
  information and is shown as declared.
- A muted value with a `*`: *typed in when this worker was created and
  confirmed by nothing — it has not claimed yet, so it has declared nothing.
  This value governs no matching.*
- `Nothing declared. A job that names a model will not be offered to this
  worker; a job that names none can be.`

A **push** backend — one this instance calls rather than one that claims — never
declares anything, and its own configured value is the answer.

**reports** — what the worker last said about itself: `active`, `stale`,
`paused`, `idle`, or nothing at all. `This worker has never said what it is
doing. It was written against an older protocol, or it has not claimed yet —
not a fault.`

**health** and **last seen** — the platform's own view. A host is `stale` when
it has stopped answering for three lease periods.

**lease** — *"Time left before the platform assumes this host is gone and
returns the job to the queue. The worker extends it with every heartbeat."*

**last {window}** — three figures over the window chosen above the table, each
with its own tooltip, and a legend underneath:

> ✓ finished · ✗ failed · ⧖ lease expired — the host went quiet mid-job

- **✓** jobs this host finished.
- **✗** jobs it reported as failed. *The job itself was at fault, or the model
  refused it — a host that cannot run work releases it instead.*
- **⧖** leases that expired: *this host stopped answering while it held a job,
  so the platform gave the work back to the queue for somebody else to attempt.
  Above zero means it has been dropping work mid-job.*

A non-zero ✗ or ⧖ is coloured; a zero stays muted. **The window is a control**,
not a fixed day — the figures change meaning when you change it, which is why
it is on screen rather than implied.

### Drain, Resume, Retire

- **Drain** — *"Taking no new work, by your instruction. It keeps its token and
  goes on reporting, so you can see it is still there."* A drained worker keeps
  polling and is answered "nothing for you", so you watch a live box taking
  nothing instead of one that has gone quiet. **A job it is already holding runs
  to the end**: drain says start nothing new.
- **Resume** — back in rotation.
- **Retire** — *"Its worker token is revoked for good and any job it is holding
  goes back to the queue. To take it out of rotation for a while, drain it
  instead."* Irreversible, and the confirmation names the reversible
  alternative.

A worker declared in the instance's own configuration file carries a `from
file` badge: *"Declared in executors.json, which owns its names — this instance
reads the file at boot. It cannot be drained or retired from here; edit the file
and restart."*

`local` is the model this instance calls itself, in process — it claims nothing
and cannot be drained.

### Add a worker

> Creates the worker token this host signs in with. The token is shown once,
> here, and never again.

The token appears with the command line to run the worker with, and stays on
screen until you dismiss it:

> Copy it now. It is not stored anywhere you can read it again; if it is lost,
> retire this worker and add another.

**One token per host, never shared.** Two processes presenting one token are
one executor as far as this screen is concerned, so the fleet view would be
wrong about what is running and a drain would take both out.

### The three queue figures

Above the table:

- **queued for workers**, and the **oldest wait**.
- **waiting on a paused host** — *queued jobs that a live worker matches, where
  every worker that matches has reported it is not taking work. There is nothing
  to start and nothing to buy: it clears when the host says it is ready again.*
  The hint names the remedy: *a host that can run these has stood itself down —
  check its readiness endpoint.*
- **no worker can run** — *queued jobs that no live worker's declared models or
  kinds match, and jobs whose only candidate you have drained — both need you to
  act on the fleet.* The remedy: *nothing in the fleet matches these — check a
  worker's models, or start one.*

**These three are different problems with different remedies, and they are
separate figures on purpose.** A job merely waiting for its team's AI budget is
**not** counted in any of them — that one says so on the job itself, on the
[Jobs](jobs.md) screen — and neither is one whose host has reported itself
paused counted under "no worker can run".

## Queue

Every job on the instance, across every team: its **kind**, how long it has been
**waiting**, which **try** this is, who is holding it, and its status.

- **in the order a free worker will take them** when you are looking at the
  queued ones — row one really is next. Any other filter is **newest first**,
  and the card says which, because a list that looked like drain order while
  mixing in finished jobs would mislead about what runs next.
- `sub` marks a sub-job: *another job is waiting on this one, so it is exempt
  from the team's concurrency cap — its parent already holds a slot.*
- A **held** badge means the platform is holding admissible work on a limit;
  `no worker` means nothing can run it at all.
- **Path** on a row shows which machines have held this job and which let it
  go — *first attempt — nothing has let it go*, or a line per holder with
  `handed back`, `lease expired` or `attempts exhausted`. This is the only place
  that record exists: a requeue clears the holder from the job, so afterwards
  nothing but this trail says which machine dropped the work.

This card is **read-only**. It refreshes while the queue is moving and stops
when it settles. The pager is numbered, and changing page swaps the card rather
than the screen.

It deliberately carries no payload and no result: it crosses every team and
company on the instance, and a queue is managed by kind, age, team and holder.
A team's own job detail is on the [Jobs](jobs.md) screen.
