# AI Queue & Concurrency Governor

**Purpose.** Queue AI use and multi-step flows, cap concurrency, and distribute
work across model endpoints so a runaway agent or a burst of flows **cannot
unintentionally DDOS or max out** the host or upstream model servers. Local model
servers (`llama-server`) have a *fixed, small* number of processing slots;
oversubscribing them thrashes everyone. This subsystem is the "no accidental
self-DDOS" tenet, plus the requirement's "queuing of resources to enable workload
distribution and enforcement of custom policy."

Odysseus had nothing here beyond a per-IP login limiter and a dead-host breaker;
this is net-new.

## Model

- **Job** — the unit of scheduled work: a single model call, a multi-step agent
  **flow** (`run-agent`), or a scheduled task run. Carries principal (user+team),
  priority, target model, cost estimate, and a parent-flow link.
- **Endpoint / worker** — a model server with a **capacity** (its real slot count)
  and health. The registry generalizes Odysseus's `model_endpoints` with
  `max_concurrency` + health, and its fleet discovery (local / Tailscale / SSH).
- **Governor** — holds per-scope **concurrency semaphores**: global, per-endpoint
  (= that server's slots), per-team, per-user. A job runs only when it can acquire
  a slot in *every* applicable scope; otherwise it waits in a queue.
- **Scheduler / distribution** — picks the least-loaded healthy endpoint that
  serves the requested model; enqueues when none is free; workers pull as slots
  free (backpressure, not drop).

## Admission

```
submit(job):
  RBAC.require(principal, "chat:use" | "tools:invoke" | "flows:run")
  d = Quota.check(subject, dims for this job)      # budgets → may reject here
  if d.rejected(budget):        return quota_exceeded(d.reset_at)
  pick endpoint for job.model (healthy, serves model)
  if slot free in {global, endpoint, team, user}:  run now
  else:                                            enqueue(job, priority)
```

- **Priority + fairness.** Queue ordering = priority (from role/policy) then
  **weighted-fair** across teams so one team can't starve others (round-robin by
  team weight, not raw FIFO). Max **queue depth** per team bounds memory; over
  depth → reject with `try_later`.
- **Custom policy seam.** The admission + ordering function is a **pluggable
  policy** (`QueuePolicy`) a deployer can override — the "enforcement of any custom
  policy for system use" requirement. Default policy = priority + weighted-fair +
  depth cap.

## Multi-step flows hold a slot only per step

The engine's `run-agent` loop is the hook. Each round: **acquire** a slot → make
the `#:llm` call → **release**. A 50-round agent therefore does *not* pin one slot
for its whole life; between rounds, other jobs run. Flows are **cancelable** and
(optionally) **preemptible** at round boundaries. This is the concrete payoff of
the pure-spine + injected-effects design: the governor wraps `#:llm` without
touching the loop.

```
governed_llm = wrap(real_llm):
  lambda messages:
    slot = governor.acquire(job.scopes)         # blocks/queues per concurrency limits
    try:    resp = real_llm(messages)
            Quota.record(tokens from resp)
    finally: governor.release(slot)
    return resp
```

## Durability

Prototype: in-memory queue + semaphores. But job **state** is persisted so a
restart is safe (Odysseus made background jobs restart-safe via on-disk exit-code
files; we generalize to a `jobs` table). On boot, `running` jobs with no live
worker are requeued or marked failed per policy.

## Data shapes (backend-neutral)

```
endpoints(id pk, team_id nullable, kind, base_url, models json,     -- kind: local|tailscale|ssh|api
          max_concurrency int, health, last_seen, weight, meta json) -- team_id NULL = shared/instance

jobs(id pk, type, principal_user_id, team_id, priority,             -- type: chat|flow|task|tool
     status, endpoint_id nullable, model, cost_estimate,            -- status: queued|running|done|failed|canceled
     parent_flow_id nullable, submitted_at, started_at, finished_at,
     tokens_used nullable, error nullable, meta json)

job_events(id pk, job_id fk, event, at, meta json)                  -- queued/started/step/finished — observability + audit
```

Concurrency limits themselves live in `quota_policies` (`ai.concurrency` per
scope); this subsystem reads them. Queue policy config (weights, max depth,
priority map) is a `features`/settings record, operator-editable.

## Contract (any backend implements)

```
Scheduler:
  submit(job) -> handle
  await(handle) -> result            # or stream events
  cancel(handle)
  status(handle) -> job
Governor:
  acquire(scopes) -> slot            # blocks/queues under concurrency limits
  release(slot)
  capacity(endpoint) -> {limit, in_use, queued}
QueuePolicy (pluggable):
  admit?(job, state) -> now | enqueue | reject
  order(queued_jobs) -> next
```

`refimpl/racketmaximus` implements these over Racket's native evented scheduler
(green threads + `sync`, no libuv FFI — the concurrency demo already proved ~40
concurrent I/O connections on one OS thread). Endpoint health/discovery reuses the
Odysseus *approach* (fleet probing), rebuilt.

## Management surface

Live queue/endpoint dashboard (depth, in-flight, per-team fairness), job
cancel/requeue, endpoint capacity + enable/disable, editable `QueuePolicy`. All
`manage`-gated + audited; honors `features` activation.

## Decisions to confirm

1. **Durability in v1.** Persisted `jobs` table from the start (my recommendation
   for restart-safety), or in-memory-only first and persist later?
2. **Fairness algorithm.** Weighted-fair-queuing across teams (default) vs simple
   priority+FIFO for v1?
3. **Preemption.** Are long flows preemptible at round boundaries (pause/resume),
   or run-to-completion once admitted? (Default: cancelable always; preemptible
   later.)
4. **Endpoint slot detection.** Manual `max_concurrency` config per endpoint
   (default) vs probing `llama-server` for its slot count?
5. **Reject vs delay coupling.** Confirm: budgets reject; rate/concurrency
   enqueue-and-delay; queue-depth overflow rejects with `try_later`.
6. **Scope of the governor.** Global + per-endpoint + per-team + per-user
   semaphores all in v1, or start with per-endpoint + per-team?
