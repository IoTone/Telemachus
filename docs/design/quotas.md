# Quotas

**Purpose.** Per-user / per-team limits on AI use and resources, metered and
enforced, so cost and load stay bounded. Odysseus had **no metering** (only a
per-IP login rate limiter + a dead-host circuit breaker); this is net-new and is
part of the team design, not an afterthought.

## Metered dimensions (initial)

| Dimension | Unit | Window | Enforced at |
|---|---|---|---|
| `ai.requests` | count | rolling + daily | admission |
| `ai.tokens.input` / `ai.tokens.output` / `ai.tokens.total` | tokens | daily + monthly | post-call accounting; admission checks remaining budget |
| `ai.concurrency` | in-flight jobs | instantaneous | governor (admission) |
| `ai.rate` | requests / minute | rolling 60s | admission |
| `flows.runs` | count | daily | admission |
| `tools.invocations` | count | daily | `#:exec` seam |
| `storage.documents` / `storage.uploads` / `storage.vectors` | bytes or rows | instantaneous | on write |
| `tasks.scheduled` | count | instantaneous | on create |
| `tokens.api` | count | instantaneous | on issue |

Two flavors: **rate limits** (rolling window, smooth bursts) and **budgets**
(calendar day/month, hard ceiling that resets). `ai.concurrency` is owned by the
governor (see queue doc) but its *limit* is a quota value, so the two share the
policy store.

## Subjects & precedence

Quotas attach to a **team** (primary) and optionally a **user** (override/sub-cap).
Effective limit = `min(team_limit, user_limit_if_any)` for caps; usage is metered
at **both** levels (a user can exhaust their personal sub-budget without exhausting
the team's). Role-based defaults are expressed as a policy assigned to the
membership role. No pricing tiers — this is OSS; limits are a deployer/operator
policy, not a monetized plan.

## Enforcement

At **admission** (before a model call / flow / write):
`check(subject, dimension, amount) -> {allowed, remaining, reset_at, reason}`.

- **Budgets / counts exceeded → reject** (a `quota_exceeded` result, HTTP 429-shape
  with `reset_at`).
- **Rate exceeded → reject or delay**: coupled to the governor — instead of a hard
  reject, the job may be **enqueued** and admitted when the window rolls (see queue
  doc). Concurrency over-limit always enqueues (that's the governor's job).
- **Soft thresholds** (e.g. 80%) emit a warning event + `audit_log` entry, no block.

**Accounting.** Token counts are known only *after* the provider responds, so the
flow is: admission checks *remaining budget* against an **estimate**; the real
usage is recorded post-call into an append-only `usage_ledger` (mirrors how
Odysseus recorded `tokens_used` per `task_run`, generalized). Aggregations roll
into `usage_counters` per window for O(1) checks.

## Data shapes (backend-neutral)

```
quota_policies(id pk, name, description,
               limits json,          -- { "ai.tokens.total": {"limit":1e6,"window":"month"},
                                     --   "ai.concurrency": {"limit":4},
                                     --   "ai.rate": {"limit":60,"window":"60s"} }
               created_by, created_at, updated_at)

quota_assignments(id pk, policy_id fk, subject_type, subject_id,   -- subject_type: team|user|role
                  effective_from, uniq(subject_type, subject_id))

usage_ledger(id pk, team_id, user_id, dimension, amount,           -- append-only meter events
             model nullable, executor_id nullable, request_id, at, meta json)

usage_counters(subject_type, subject_id, dimension, window_key,    -- materialized aggregate
               amount, updated_at,
               pk(subject_type, subject_id, dimension, window_key)) -- window_key e.g. "2026-08" / "2026-08-12" / "rolling"
```

`window_key` encodes the period so a daily/monthly reset is just a new key;
rolling windows prune the ledger by time. Storage/counter dimensions read live
counts rather than a ledger.

## Contract (any backend implements)

```
QuotaService:
  check(subject, dimension, amount=1) -> Decision{allowed, remaining, reset_at, reason}
  record(event: {subject, dimension, amount, model?, executor?, request_id, meta})
  usage(subject, dimension, window) -> {used, limit, remaining, reset_at}
  effective_limit(subject, dimension) -> {limit, window} | none
  assign(policy, subject) / policies_crud(...)
```

The engine's `#:llm` wrapper calls `check(ai.tokens.total, estimate)` before the
call and `record(...)` with real usage after; `#:exec` calls
`check(tools.invocations)`. Same injected-effects seam as RBAC.

## Management surface

Operator/owner CRUD of `quota_policies` and assignments; a usage dashboard reading
`usage_counters`; warning/exceed events in `audit_log`. Honors `features`
activation (quotas can be globally disabled for a trusted single-team deployment).

## Decisions to confirm

1. **v1 dimension set.** Ship tokens + requests + concurrency + rate first, defer
   storage/tasks metering? (Default: yes — the AI dimensions first.)
2. **Rate-exceed behavior.** Enqueue-and-delay (smooth) vs hard reject? (Default:
   enqueue via the governor for `ai.rate`/`ai.concurrency`; hard reject for
   budgets.)
3. **Windows.** Confirm daily+monthly budgets + 60s rolling rate as the default
   windows. Timezone for calendar windows — team-configurable or UTC? (Default:
   UTC, team-overridable later.)
4. **Team vs user precedence.** Confirm `min(team, user)` caps with dual metering.
5. **Estimation.** Pre-call token estimate source — a cheap heuristic (chars/4) vs
   a tokenizer per model? (Default: heuristic in v1; refine later.)
6. **Default policy values.** Provide sane starter limits (e.g. small/medium/large
   deployment presets) or leave unlimited-until-configured? (Default: ship a
   conservative default policy + presets.)
