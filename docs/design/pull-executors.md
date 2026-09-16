# Pull-model executors: inference hosts that come to the work

*Decided 15 Sep 2026 (PULL‑1…8 confirmed). **Built** as slice 66:
`domain/exec/pull.rkt`, migration `0028-executors`, the worker protocol under
`/api/workers/*`, `cli/telemachus-worker.rkt`, `test/pull-tests.rkt` and
`test/pull-smoke.sh` (a chat routed through a real worker against the scripted
model). Requested by a downstream project (issue #15) and the shape TEN‑2e has
been waiting for. See **As built** at the end.*

## What exists, and where it stops

| Layer | Today |
|---|---|
| Executors | `domain/exec/federation.rkt`: a registry of **push** endpoints — a name, an OpenAI-compatible URL, a model, a key. The server calls them. Instance-scoped, loaded from `TELEMACHUS_EXECUTORS` at boot (SCHED‑3: transport deferred). |
| The scheduler | `domain/sched/scheduler.rkt`: a durable `jobs` table, an atomic in-process claim under a lock, a bounded worker pool, per-team concurrency caps, quota admission at claim, cancel-not-preempt (SCHED‑7). Every workflow step is a job. |
| Model calls | `run-chat` picks a backend by name and POSTs to it. A tool that needs a model calls `run-chat` (or the `current-doc-chat` seam) synchronously inside its job. |
| Credentials | API tokens with scopes, now expiring; S3 keys with scopes. Nothing identifies a *machine that runs inference*. |

So a GPU box behind a NAT, a laptop on a tailnet, a spot instance that comes and
goes, or a company's own inference host (TEN‑2e) cannot participate: the server
has to be able to reach it. The ask is the inversion — **a host that reaches the
server, claims work it is capable of, runs it, and posts the result** — without
a second queue, a second credential model, or a second place jobs live.

## The shape: a worker is a client of the jobs table

Nothing new is invented above the scheduler. A pull host is a **worker** that
claims jobs over HTTP exactly as an in-process worker thread claims them from
the database: same atomic claim, same per-team cap, same quota admission, same
cancel semantics. What changes is *where the handler runs* and that a job now
carries a **lease**.

```
in-process today:   claim-next! ──▶ run-claimed! (handler in this process) ──▶ done/error
pull host:          POST /api/workers/claim ──▶ (the host runs it) ──▶ POST /api/workers/jobs/<id>/complete|fail
                                          └─ heartbeat, or the lease expires and the job is re-queued
```

- **A job kind declares where it may run.** Today a kind is `(conn principal
  payload) -> jsexpr`, in-process. A kind may now also be registered as
  **`#:remote`** with a *dispatch contract*: what the host receives (the payload
  the server prepared) and what it must post back (a jsexpr the server
  validates). The first remote kind is `infer.chat`: `{messages, model,
  temperature}` in, `{reply, tokens_used}` out — the exact wire `run-chat`
  already speaks, so every existing model-using tool works unchanged when its
  chat call is routed to a pull executor.
- **A worker is an executor row plus a credential.** The executor registry gains
  `mode: push | pull` and an `org_id`; a pull executor is created through the API
  (not a config file) and the call returns a **worker token** once — an API
  token with the single scope `jobs:execute`, bound to that executor. Scopes cap
  it, expiry applies, revoking the token retires the worker. No new credential
  model (RBAC‑4 as-is).
- **Capabilities, not names.** A worker claims with what it offers (`models:
  ["qwen2.5:7b"]`, `kinds: ["infer.chat"]`); the claim matches jobs whose
  requirements it satisfies (SCHED‑2's `{model, est_tokens}` finally has a
  consumer). A job with no requirement runs anywhere; a job that names a model
  waits for a host that has it.
- **Leases.** A claimed job carries `lease_until` and the worker heartbeats. An
  expired lease returns the job to `queued` with `attempt+1`; after a bounded
  number of attempts it fails with "no executor completed it". This is the one
  genuinely new mechanism, and it is what makes a host that vanishes mid-job
  safe: the job is not lost and not run twice by design — the *result* is
  accepted only from the lease holder whose lease is current.
- **Routing a model call to a pull executor.** `run-chat #:executor` today
  resolves a name to a push URL. For a pull executor it instead **enqueues an
  `infer.chat` job and waits for it** (bounded by the caller's own job's lease),
  so a tool inside a workflow step that says "use executor X" blocks on a
  sub-job the host will claim. The team's concurrency cap and quota apply to the
  sub-job too — a pull host does not bypass admission.
- **TEN‑2e falls out.** An executor with an `org_id` is offered only to that
  org's teams; a company's own inference host serves only that company. An
  instance-wide executor has `org_id NULL`. The gate is the same step-0 rule
  everything else uses.

## What a worker looks like

A worker is a loop any language can write; the reference one is
`cli/telemachus-worker.rkt`, and it is short on purpose:

```
loop:
  job = POST /api/workers/claim {kinds, models, max_wait: 20}     # long-poll; 204 when nothing
  if job:
     thread heartbeat every lease/3:  POST /api/workers/jobs/<id>/heartbeat
     try:    result = run(job.kind, job.payload)                # e.g. call the local ollama
             POST /api/workers/jobs/<id>/complete {result}
     except: POST /api/workers/jobs/<id>/fail {error}
```

The Bearer is the worker token. Every one of those four endpoints is a declared
route with `auth: bearer`, `perm: jobs:execute`, and appears in `api.md`.

## Authorization

- `jobs:execute` is a new permission, held by nothing but a worker token. It
  lets a principal claim, heartbeat, complete and fail jobs **offered to its
  executor** — never read a team's data, never start a run. The payload the
  host receives is what the server prepared for the kind (for `infer.chat`,
  the messages); the host sees exactly what the model endpoint would have seen.
- A job is offered to a worker only if the worker's executor is instance-wide
  or belongs to the job's team's org. The org gate, again.
- A result is accepted only from the current lease holder. A late result from
  a worker whose lease expired is refused (409) and logged; the job may already
  be running elsewhere.

## Data shapes (backend-neutral)

```
executors  + mode        text not null default 'push'     -- push | pull
           + org_id      text null                        -- TEN-2e: null = instance-wide
           + token_id    text null                        -- the worker token (pull only)
           + capabilities text not null default '{}'      -- {kinds:[…], models:[…]}
           + last_seen_at, status                         -- health from heartbeats
jobs       + executor_id  text null                       -- who holds it
           + lease_until  bigint null                     -- epoch seconds; null for in-process
           + attempt      integer not null default 1
           + requirements text not null default '{}'      -- {model?, kind}
```

The executor registry moves from a boot-time config file into a table (the
push entries from `TELEMACHUS_EXECUTORS` are imported on boot, as plugin
workflows are materialized). Nothing else changes shape.

## Contract (any backend implements)

```
Executors:
  create(principal, {name, mode, org_id?, model?, url?, capabilities}) -> {executor, worker_token?}
  list(principal) -> [executor…]              # keys never shown
  retire(principal, id)                       # revokes the worker token

Workers (bearer = worker token, perm jobs:execute):
  claim({kinds, models, max_wait}) -> job | none          # atomic; leases; per-team cap + quota apply
  heartbeat(job_id) -> lease_until
  complete(job_id, result) -> ok | 409 not-lease-holder
  fail(job_id, error) -> ok | 409

Scheduler:
  register-job-kind! kind handler #:remote? #:validate    # a remote kind has no in-process handler
  reap-leases!                                             # expired -> queued (attempt+1) or error

Model routing:
  run-chat #:executor <pull executor> -> enqueue infer.chat, wait (bounded), return (values reply tokens)
```

## Bootstrapping plan

1. Migration: the four `jobs` columns and the `executors` table; import
   `TELEMACHUS_EXECUTORS` on boot. `jobs:execute` in the catalog, described.
2. Worker endpoints + leases + the reaper (a scheduler tick). Unit tests: claim
   is atomic across two workers, an expired lease re-queues, a stale complete
   is 409, a job with a model requirement waits for a capable worker, an
   org-bound executor never sees another org's job.
3. `infer.chat` as the first remote kind; `run-chat #:executor` routing to a
   pull executor by enqueue-and-wait. Smoke: `cli/telemachus-worker.rkt` against
   the scripted mock model, a chat routed through it end to end.
4. TEN‑2e: `POST /api/org/executors` for an org admin; the org gate on offers.
5. Admin › Compute lists pull executors with health; a worker that stops
   heartbeating goes `stale`.

## As built

- **Remote kinds** are registered with `#:remote? #t #:validate` and have no
  in-process handler; the pool's `claim-next!` skips them, and a worker's
  `worker-claim!` takes only them. `infer.chat` is the one shipped kind; its
  validator requires a string `reply` and a numeric `tokens_used`, and a bad
  shape FAILS the job as the worker's mistake.
- **The worker token** is an ordinary API token, scope `jobs:execute`, `ttl
  'never`, returned once by `POST /api/executors`. A worker endpoint finds its
  executor through the token's own id (`executors.token_id`), so a token can
  never speak for another host; the operator's token, which passes every
  team-tier permission, is still refused with "not bound to an executor".
- **Sub-jobs are exempt from the team cap.** `run-chat #:executor <pull>`
  enqueues `infer.chat` with `parent_job_id` set (or a top-level job on the
  request path) and waits, polling every 250 ms up to 300 s. Without the
  exemption two parents at a cap of 2 would each wait for a sub-job nothing
  could claim — a deadlock until the leases expired.
- **The reaper runs on the pool's idle tick** (`set-reaper!`), so an expired
  lease is noticed within a worker's idle interval; tests call it directly.
- **Health is derived**, not stored: `never-seen`, `active`, `stale` (no claim or
  heartbeat for 3 × the lease), `retired`.
- The `executors` table holds API-created executors (push or pull); the
  `TELEMACHUS_EXECUTORS` push entries stay in memory as before, and the two are
  merged in `GET /api/executors`. Retiring a pull executor revokes its token and
  returns any job it holds to the queue.
- The reference worker's only job kind is `infer.chat`; a worker written in
  another language needs the four calls and nothing else.

## Decisions (confirmed 15 Sep 2026)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **PULL‑1** | Where pull work lives | **The existing `jobs` table, claimed over HTTP** · vs a separate work queue | One queue means one cap, one quota, one cancel, one audit. |
| **PULL‑2** | Worker identity | **An API token with the single scope `jobs:execute`, bound to an executor row** · vs a new credential type · vs mTLS | Scopes, expiry and revocation already exist; a token is the natural key. |
| **PULL‑3** | Lost workers | **Leases with heartbeats; expiry re-queues with a bounded attempt count** · vs run-once-and-fail · vs no lease | A host that vanishes must not lose the job and must not double-run it. |
| **PULL‑4** | Placement | **Capability match (`kinds`, `models`) at claim; no requirement = anywhere** · vs named routing only | SCHED‑2 finally gets a consumer; a job that needs a model waits for one. |
| **PULL‑5** | Routing a synchronous model call | **Enqueue `infer.chat` and wait, bounded by the caller's lease** · vs make every model-using tool asynchronous | Every existing tool keeps working; the wait is inside a job that is already admitted. |
| **PULL‑6** | Per-org executors (TEN‑2e) | **`executors.org_id`, offered only to that org's teams; null = instance-wide** · vs instance-wide only | A company's own inference host serves only that company — the org gate, again. |
| **PULL‑7** | Transport | **Plain HTTPS, long-poll claim, JSON** · vs WebSocket · vs a message bus | Works through NAT and a tailnet; nothing to deploy beside the server (SCHED‑3 stays deferred for anything richer). |
| **PULL‑8** | Token formats for federation | **Opaque worker tokens now; revisit PASETO only if a host must be verifiable without the database** · vs signed tokens now | The server checks the database on every call anyway; signed tokens buy nothing until there is a second verifier. |
