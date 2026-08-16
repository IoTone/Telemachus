# AI Workload Scheduler (Queue, Governor & Executors)

**Purpose.** Admit, queue, and place AI **workloads** onto **compute resources**,
capping concurrency so a runaway agent or a burst of flows **cannot unintentionally
DDOS or max out** the host or upstream model servers. The reference implementation
(RI) runs single-node with **local** compute, but the design keeps an **executor**
seam open so the same scheduler can later dispatch to additional LLM servers, CPU
nodes, or an HPC/Kubernetes backend — without the RI itself becoming a cluster.

Odysseus had nothing here beyond a per-IP login limiter and a dead-host breaker;
this is net-new.

## What this is — and is NOT (queue taxonomy)

Two unrelated things are both called "queues." This subsystem is the second kind.

| | **Message queue / broker** | **Workload processing queue** *(this)* |
|---|---|---|
| Examples | ZeroMQ (0mq), JMS, RabbitMQ/AMQP, Kafka, NATS | SLURM, Kubernetes (Jobs/scheduler), HTCondor, Nomad, Ray |
| Moves | *messages* between components | *compute jobs* onto *resources* |
| Concerns | transport, pub/sub, decoupling, durability of messages | admission, capacity, priority, fairness, placement |
| Role here | possible *wire* to remote executors (deferred, pluggable) | **the subsystem itself** |

A message transport (0mq/NATS/HTTP/gRPC) may eventually carry work to a *remote*
executor — but that is an implementation detail of the executor **transport**,
not the identity of this subsystem. Telemachus's scheduler is a **workload
scheduler**: its workloads are AI jobs (model calls, agent flows, task runs); its
resources are **executors**.

## Mental model (HPC / k8s analogy)

| Telemachus | SLURM | Kubernetes |
|---|---|---|
| Job (+ `requirements`) | `sbatch` task (`--gres=gpu`, `--mem`) | Pod / Job (resource requests, nodeSelector) |
| Executor / executor pool | partition / node | Node / node pool |
| capacity (slots) | cores / GPUs | allocatable resources |
| Scheduler + Governor | `slurmctld` | kube-scheduler |
| queue (priority, fair-share) | `squeue` / fair-share | scheduling queue |

A **Job** declares what it needs (model, estimated tokens/time, optionally a
compute class); **Executors** advertise capacity + health; the **Scheduler**
places jobs on a matching executor with a free slot, else queues them.

## Two planes

- **Control plane — Scheduler + Governor** (this is the workload queue): admission
  (RBAC + quota), queueing (priority + weighted-fair + depth cap), **placement**
  (pick an executor whose capabilities match the job and that has a free slot), and
  concurrency governance via per-scope semaphores.
- **Data plane — Executors** (where work runs): the scheduler doesn't care *how* an
  executor runs a job, only its **capacity / health / dispatch** contract. The RI
  ships **local** executors only; remote/HPC executors are future implementations
  of the same interface — this is the federation seam.

## Executors (the federation seam)

An `Executor` is any place work can run, with a `kind`, a `capacity` (its real
slot count), health, and the capabilities it offers (e.g. which models).

| Executor kind | What it is | Status |
|---|---|---|
| `local-model` | a `llama-server` / model runtime on this host | **RI (v1)** |
| `remote-model` | a networked LLM server (Tailscale/SSH fleet, or an API) | designed-for; Odysseus already discovered such fleets |
| `cpu-node` | a generic compute worker (embeddings, doc processing) | future |
| `hpc-partition` | submit to SLURM/PBS as batch jobs | future |
| `k8s` | submit Kubernetes Jobs | future |

The RI implements `local-model`. Adding `remote-model` (link up more LLMs/CPUs) is
"implement the `Executor` interface + pick a transport" — no scheduler change. The
scheduler↔remote-executor **transport** (HTTP/gRPC/0mq/NATS) is deliberately
pluggable and **out of RI scope**.

## Admission & placement

```
submit(job):
  RBAC.require(principal, "chat:use" | "tools:invoke" | "flows:run")
  d = Quota.check(subject, dims for this job)          # budgets → may reject here
  if d.rejected(budget):        return quota_exceeded(d.reset_at)
  candidates = executors matching job.requirements (healthy, offers job.model)
  place on the least-loaded candidate with a free slot in {global, executor, team, user}
  if none has a free slot:       enqueue(job, priority)
```

- **Priority + fairness.** Ordering = priority (from role/policy) then
  **weighted-fair across teams**, so one team can't starve others. Per-team **max
  queue depth** bounds memory; overflow → reject `try_later`.
- **Custom policy seam.** Admission + ordering + placement is a pluggable
  **`QueuePolicy`** a deployer can override — the requirement's "enforcement of any
  custom policy for system use." Default = priority + weighted-fair + depth cap +
  least-loaded placement.

## Multi-step flows hold a slot only per step

`run-agent` is the hook. Each round: **acquire** a slot on an executor → make the
`#:llm` call → **release**. A 50-round agent never pins one slot for its whole
life; other jobs run between rounds. Flows are **cancelable** and (optionally)
**preemptible** at round boundaries. This is the payoff of the pure-spine +
injected-effects design: the governor wraps `#:llm` without touching the loop.

```
governed_llm = wrap(real_llm, job):
  lambda messages:
    slot = scheduler.acquire(job)                # places on an executor; blocks/queues per limits
    try:    resp = slot.executor.dispatch(messages)
            Quota.record(tokens from resp)
    finally: scheduler.release(slot)
    return resp
```

## Durability & non-goals for the RI

- **Durability.** Prototype uses in-memory queue + semaphores, but job **state** is
  persisted (`jobs` table) so restart is safe — on boot, `running` jobs with no
  live worker are requeued or failed per policy. (Odysseus made background jobs
  restart-safe via on-disk exit-code files; generalized here.)
- **Non-goals (RI).** No distributed scheduling, no autoscaling, no real
  HPC/k8s backend, no cross-node clustering. The RI is a **single-node local
  scheduler with local executors**. We build the *seam* (the `Executor` contract
  and job `requirements`) that makes federation possible later — not the cluster.

## Data shapes (backend-neutral)

```
executors(id pk, team_id nullable, kind, name, endpoint nullable,        -- kind: local-model|remote-model|cpu-node|hpc-partition|k8s
          capabilities json,                                             -- { "models": [...], "class": "gpu|cpu", ... }
          max_concurrency int, health, last_seen, weight, transport json,-- transport: how to reach a remote executor (deferred)
          meta json)                                                     -- team_id NULL = shared/instance-wide

jobs(id pk, type, principal_user_id, team_id, priority,                  -- type: chat|flow|task|tool
     status, requirements json,                                          -- { "model": "...", "est_tokens": N, "class": "..." }
     executor_id nullable, cost_estimate,                                -- status: queued|running|done|failed|canceled
     parent_flow_id nullable, submitted_at, started_at, finished_at,
     tokens_used nullable, error nullable, meta json)

job_events(id pk, job_id fk, event, at, meta json)                       -- queued/placed/started/step/finished — observability + audit
```

Concurrency **limits** live in `quota_policies` (`ai.concurrency` per scope:
global / executor / team / user); this subsystem reads them. `QueuePolicy` config
(weights, max depth, priority map, placement rule) is an operator-editable
settings/`features` record.

## Contracts (any backend implements)

```
Scheduler:                       # control plane — the workload queue
  submit(job) -> handle
  await(handle) -> result        # or stream events
  acquire(job) -> slot           # place on a matching executor; blocks/queues under limits
  release(slot)
  cancel(handle)
  status(handle) -> job

Executor:                        # data plane — RI ships local-model only
  kind() -> symbol
  capabilities() -> {models, class, ...}
  capacity() -> {limit, in_use, queued}
  health() -> ok | degraded | down
  dispatch(job|messages) -> result | stream
  cancel(job)

QueuePolicy (pluggable):
  admit?(job, state) -> now | enqueue | reject
  order(queued_jobs) -> next
  place(job, candidates) -> executor | none
```

`refimpl/racketmaximus` implements `Scheduler`/`Governor` over Racket's native
evented scheduler (green threads + `sync`, no libuv FFI — the concurrency demo
already proved ~40 concurrent I/O connections on one OS thread) and a single
`local-model` `Executor`. Remote/HPC executors are additional `Executor`
implementations behind a chosen transport, not core changes.

## Management surface

Live queue + executor dashboard (depth, in-flight, per-team fair-share, per-
executor capacity/health), job cancel/requeue, executor enable/disable + capacity,
editable `QueuePolicy`. All `manage`-gated + audited; honors `features` activation.

## Decisions to confirm

1. **Executor kinds in v1.** Ship `local-model` only (RI), with `remote-model` as
   the first designed-for extension? (Default: yes — local-model in v1, contract
   ready for remote.)
2. **Requirements granularity.** v1 `requirements` = `{model, est_tokens}`; add a
   compute `class` (cpu/gpu) + memory hints when `cpu-node`/HPC land? (Default: yes.)
3. **Remote transport.** Leave the executor transport unspecified in v1 (interface
   only), or pick one now (HTTP/gRPC vs a message queue like 0mq/NATS)? (Default:
   defer — interface only; the RI is local so no wire is needed yet.)
4. **Durability in v1.** Persisted `jobs` table from the start (recommended,
   restart-safe) vs in-memory-only first?
5. **Fairness algorithm.** Weighted-fair-share across teams (default) vs simple
   priority+FIFO for v1?
6. **Governor scopes.** Global + per-executor + per-team + per-user semaphores in
   v1, or start with per-executor + per-team?
7. **Preemption.** Cancelable always (default); preemptible-at-round-boundary now
   or later?

## Status

**First cut built (slice 27).** The persisted `jobs` table (migration `0009`), a
bounded worker pool with atomic claim, submit/poll/list/cancel endpoints
(`/api/jobs`), and `chat` + `translate` job kinds are implemented in
`refimpl/racketmaximus` (`domain/sched/scheduler.rkt`, `test/scheduler-tests.rkt`),
with a Jobs UI tab. Decisions realized: durable jobs table (SCHED‑4), priority+FIFO
(SCHED‑5), cancelable-not-preemptible (SCHED‑7).

**Per-team fairness (slice 28).** The claim now skips a team already at its
concurrency cap (= the team's `ai.concurrency` limit), so one team's batch can't
monopolize the pool — enforced at claim time, so a busy team never head-of-line-
blocks a worker (unlike wrapping a shared blocking governor).

Deferred follow-ups: weighted-fair-share across teams (beyond the flat cap), quota
metering of job runs, and an `agent` job kind (the tool-loop flow) — all layer on
without changing the claim/pool core.
