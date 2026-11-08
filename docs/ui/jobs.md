# Jobs

The scheduler queue for this team: a submit form, the list, and one paragraph
under it that is the most important thing on the screen.

## What appears here, and what does not

> This list is the SCHEDULER queue. Chat streams its answer, and Translate and
> Ask are answered in the request itself — none of the three creates a job, so
> using them leaves nothing here. What appears: what you submit above, a
> workflow's steps, a trigger's run, and any work a fleet worker claims.

An empty Jobs screen after a busy afternoon of chatting is correct.

## Submitting one

**kind** is `chat` or `translate`, with a prompt (and a target language for a
translation). These two run **in the server's own pool**, so they report no
worker:

> chat and translate run in the server's own pool, so they report no worker.
> Work that goes to a GPU host is kind `infer.chat`, which a chat routed to the
> fleet creates as a sub-job.

## The columns

**id** — the first eight characters.

**kind** — `chat`, `translate`, `infer.chat`, `flow.step`, `feed.poll`,
`l10n_draft`, a plugin's `x.<plugin>.<name>`, and so on.

**status** — `queued`, `running`, `canceling`, `done`, `error`, `canceled`,
plus a badge when something is **holding** it (below).

**when** — how long ago the job was created, with the wall-clock time in your
own timezone on hover. After it, a **duration**:

- a settled job shows how long it ran, claim to finish;
- a running job shows `N so far`, in a different colour, and the figure moves
  on every refresh — because `14s` and `14s so far` are different facts, and a
  reader who cannot tell them apart will read a stalled job as a fast one;
- a **queued** job shows nothing. It has not started, so it has no duration.

**worker** — which host ran it. Two absences, each of which says which:

- `unclaimed` — nothing has picked it up yet;
- `in process` — it ran in the server itself, and an in-process job has no
  worker by design.

**result** — the outcome, or the error for a job that failed.

**Cancel** is offered on a queued or a running job. Your own job is always
yours to stop; stopping somebody else's needs a permission. Nothing is
preempted: a running job goes to `canceling`, its handler is told, and its
answer is discarded when it arrives — so the slot comes back when the work
really stops rather than when you pressed the button.

## Held, not failed

A badge beside the status says the platform is holding the job:

- `held: <dimension> budget` — the team or its company has used that
  allowance. [Usage](usage.md) shows the figure and when the window resets.
- `held: team at N concurrent` — the team is at its concurrency cap.

> The platform is holding this job: it is admissible work waiting on a limit,
> not a failure, and it starts on its own when the limit clears.

**A queue of jobs with nothing running is nearly always one of these two.** It
is the single most mistaken state on this screen: it looks like a broken
scheduler and it is a budget. The shipped daily allowances are deliberately
small, and one agent run or one fan-out over a few documents will reach them.

A job that no worker in the fleet can run at all is a different problem with a
different remedy, and it is counted on [Health](health.md) rather than here.

## Refreshing

The list refreshes itself every two seconds **while there is live work** —
queued, running or canceling — and stops when the last job settles. It swaps the
list alone, so whatever you have typed into the submit form above survives it.
