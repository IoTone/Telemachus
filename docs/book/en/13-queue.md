# The job queue


## What a job is

A job is a row: a team, a user, a kind, a JSON payload, a priority, a status. Nothing about a running job lives in memory, which is why a restart loses no work and why a workflow step, a bulk translation and a model call routed to another machine can all be the same thing. A bounded pool of worker threads drains the queue; each thread claims one job, runs its kind’s handler, and writes the result back to the row.

Two policies are applied at claim time rather than inside the handler, so no kind can forget them: a **per-team concurrency cap**, which stops one team’s batch monopolizing the pool, and **quota admission**, which leaves an over-budget team’s jobs queued rather than failing them. A queue that has stopped moving with nothing running is usually a team out of AI budget, and that is the platform working.

## Claiming one

Claiming looks trivial and is not. The pool scans for queued rows, picks a candidate, and flips it to running — but the flip must be *conditional* on the row still being queued, and the condition is worthless unless somebody reads the result:

    UPDATE jobs SET status='running', started_at=CURRENT_TIMESTAMP,
                    lease_until=?, executor_id=?, claim_token=?
     WHERE id = ? AND status='queued'
     RETURNING id

The claim is believed only when a row comes back. This matters more than it looks: the driver reports affected rows on PostgreSQL and not on SQLite, so a row count would have been a dialect-dependent answer, while `RETURNING` works on both. A claimant whose update matched nothing moves to the next candidate instead of running a job another worker holds. Before this, exclusion rested on a lock inside one process — fine until there are two.

## When a worker dies

Every claim carries a **lease**: a timestamp the holder refreshes while it works. If the holder dies, the lease lapses, and a reaper returns the job to the queue with its attempt count raised, failing it for good after three. This applies to the in-process pool exactly as it does to a remote worker; when it did not, a pool job whose process died sat `running` forever and kept consuming its team’s concurrency slot. A job left behind by an older build — running, with no lease — is swept back to the queue when the pool starts.

Recovery creates a subtler problem, and it is the one worth remembering. Suppose a lease lapses while the original run is still alive; the reaper requeues the job; the *same* holder claims it again. The first run finally finishes and writes its result. Status matches. Holder matches. Nothing in either check can tell the two attempts apart. So each claim also mints a **fencing token**, and every later write about that attempt carries it — the terminal write, the lease refresh, and a remote worker’s heartbeat, completion and failure. Requeueing clears the column; so does every terminal write. A token from a previous attempt can never match again, and neither can a second write from the current one.

    claim  -> id + lease_until + claim_token
    heartbeat / complete / fail  -> must carry that claim_token, or 409

## Executors that come to the work

An inference host does not have to be callable from the server. A **pull executor** runs a loop that long-polls for a job it can run, heartbeats while it runs it, and posts the result — so it works from behind NAT or on a tailnet, connecting outward only. Its credential is an API token whose only scope is `jobs:execute`, shown once and bound to the executor row; the executor is resolved through the token, never through a field in the request.

A **remote kind** is registered with no in-process handler: the pool skips it, only a worker can claim it, and its results are validated by a function the kind must supply, because there is no local handler to be strict on its behalf. The shipped one is `infer.chat` — exactly the wire `run-chat` speaks — so a synchronous model call becomes a sub-job and waits for a worker, and every model-using tool works unchanged when its chat is routed elsewhere. A sub-job carries its parent and is exempt from the team cap at claim: two parents at a cap of two would otherwise each wait forever for a sub-job nothing could claim.

## Which model runs what

A *model role* resolves to an executor name: the team’s setting, then an environment variable, then the local model. One role ships — `utility` — and it carries the bulk work: knowledge-graph extraction, the pipeline’s field extraction and translation, and the Localization Manager’s drafts. A person’s chat never goes there. The tools set the role around their own model call, so a GPU box can take the batch work without any tool knowing it exists. Setting a role to an executor that does not exist is refused, because a typo would otherwise send every extraction quietly back to the local model.

## Files to open

`domain/sched/scheduler.rkt` (read `claim-job!`, `finish!` and `with-lease`), `domain/exec/pull.rkt`, `domain/ai/roles.rkt`, `cli/telemachus-worker.rkt`, `docs/design/pull-executors.md`, `test/pull-tests.rkt`, `test/pull-smoke.sh`.
