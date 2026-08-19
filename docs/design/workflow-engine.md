# Workflow Engine — plugins that process in steps

**Status:** slices 46 and 47 built. `map` fan-out, the plugin `workflows` export
and `${principal.locale}` were pulled forward by the Translate Chat demo. Slices 48–49
pending. All decisions settled (WF‑1…WF‑10).
**Depends on:** the tool registry, the scheduler, `can?` + the org gate (TEN‑2).
**Operators:** [../ops/workflow-engine-runbook.md](../ops/workflow-engine-runbook.md)
— setup, the four test tiers, failure modes, CI.

## The requirement

*"A developer plugin for a workflow engine, so any new plugin can utilize workflow
steps in processing."* Unpacked, that is three demands:

1. **Composition.** A plugin declares that step 2 runs after step 1 and consumes
   its output.
2. **Durability.** A sequence that takes minutes survives a restart, and can be
   cancelled halfway.
3. **Legibility.** Someone who did not write the plugin — an admin, a reviewer, a
   customer — can see what it will do before it does it.

Composition alone is satisfiable today with a hundred lines. **Durability and
legibility are what force a real design, and they force the same thing:** the step
graph must be an inspectable data structure at runtime rather than a closure. A
run that resumes after a restart has to record which step it stopped on; an
administrator who never reads the source still has to see what happens next.

> A fourth demand — *reach*, that non-Racket authors could write a workflow — was
> proposed and **struck** during review. The project is all-in on Racket. This is
> recorded because it changes how the design is *presented*, not what it is: the
> spec is a storage, execution and rendering format, **not** a second authoring
> surface to document and keep at parity.

## What already exists

Most of the hard parts. What is missing is the thin sequencing layer on top.

| Piece | Where | What it gives a workflow |
|---|---|---|
| Tool registry | `domain/agent/registry.rkt` | `(name, schema, permission, handler)` + per-team activation. **Every registered tool is already a step.** |
| Plugin loader | `domain/agent/plugins.rkt` | Out-of-tree folders; optional `tools` / `init!` via `dynamic-require` with defaults |
| Scheduler | `domain/sched/scheduler.rkt` | Durable `jobs` table, atomic claim, bounded pool, per-team concurrency cap, injected quota admission, cancel |
| Agent spine | `domain/agent/loop.rkt` | A pure state machine with injected effects — the precedent for the interpreter |
| `define-tool` | `domain/tools/dsl.rkt` | **A macro that emits JSON.** The load-bearing precedent for this whole design |
| Authorization | `domain/authz/authz.rkt` | `can?` with the org gate at step 0, grants, token scopes, `audit_log` |
| Quotas / features | `domain/quota`, `domain/features` | Nested org/team subjects; per-team activation for dark launches |

```
  TODAY                                    MISSING
  ─────────────────────────────────        ─────────────────────────────────
  plugin ──▶ register-tool! ──▶ tool       "step 2 runs after step 1,
                                 │          with step 1's output,
  agent loop ──▶ picks tools ────┤          durably, and an admin can
                                 │          see the sequence before
  scheduler ──▶ job kind ────────┘          it runs"

  one call at a time, chosen by a          no way to DECLARE a sequence.
  model or hard-coded in a handler          Only to hard-code one.
```

The gap is **declaration**, not execution. Execution is solved.

## The design

**The spec is the contract. `define-workflow` is the authoring surface that
compiles to it. The canvas is a renderer of it. The runtime is the scheduler.**

```
  AUTHORING                 THE CONTRACT                RUNTIME
  ──────────────────        ────────────────────        ──────────────────────────
  define-workflow  ─┐
  (Racket macro)    │
                    ├──▶   workflow spec  ────────▶    flow interpreter
  workflows/*.json ─┤      (validated JSON;            (pure reducer: reads the
  (plugin file)     │       stored, versioned,          run, decides next steps)
                    │       diffable, drawable)                 │
  API / admin      ─┤                                           ▼
                    │                                   scheduler job "flow.step"
  canvas editor    ─┘                                           │
  (later, MIT)                                                  ▼
                                              tool  │  job kind  │  agent  │  approve
                                                              │
                                    can? ▸ ORG GATE ▸ quota ▸ audit_log
```

Three authoring paths, one contract, one runtime. Only the middle column is a new
commitment.

### Why the spec exists even though we are all-in on Racket

The weakest argument for a data spec is "someone might not know Racket", and it
has been struck. Three stronger ones survive, none about reach:

- **Durability requires it.** A run that survives a restart must persist where it
  stopped — stable step ids and a graph the interpreter re-reads from the
  database. That structure gets built whether or not anyone looks at it. Writing
  it to a column is then one line.
- **Legibility requires it.** TEN‑2a says a company administrator *manages but
  does not read* team data. That administrator still has to know what automation
  runs inside their company. A diagram renders from data, not from a closure.
- **The stated product requires it.** `CLAUDE.md`: the durable product is the SDK
  contract, APIs, security model, protocols — and a second implementation may
  target the same contracts. A macro cannot be that contract; a spec can.

### The precedent

`define-tool` is *already* a macro whose output is a JSON document the rest of the
system consumes. Nothing in the platform knows the macro exists — the agent loop,
the registry and the model all see plain data, and a hand-written schema is
indistinguishable from a macro-generated one. `define-workflow` → workflow spec is
the identical move, one level up.

### Step kinds (v1)

| Kind | Does | Built on |
|---|---|---|
| `tool:<name>` | Invoke a registered tool with bound arguments | `registry.rkt` — every existing tool, free |
| | *Optional `retry: {"max": n}`. Backoff waits for a `run_after` column on `jobs` — slice 47; until then a retry re-enqueues immediately.* | |
| `job:<kind>` | Enqueue a registered scheduler job kind | `register-job-kind!` |
| `agent` | Run the agent loop with a prompt, a context binding and a tool allowlist | `run-agent-flow` |
| `choice` | Branch on a frozen predicate | interpreter |
| `map` | Fan out over a list; bounded by the team's existing concurrency cap. `over` is a list or a reference to one; `step` is a tool template run per item with `${item}` / `${index}` bound. Children are real jobs (`<map>#<i>`) under one parent row, which aggregates `{results: […]}` in `over` order. | scheduler claim logic |
| `approve` | Park the run until a principal holding a named permission approves | `can?` + `audit_log` |
| `flow:<slug>` | Call a sub-workflow, depth-capped | interpreter |

`approve` looks like scope creep and is not: a parked run is what people actually
mean by "workflow", and it is nearly free once runs are durable rows rather than
live threads.

### The binding sublanguage — deliberately frozen (WF‑2)

This is what decides whether the spec stays clean or rots into a bad programming
language. Frozen in the first commit:

- **References only:** `${input.x}`, `${steps.<id>.output.<path>}`, `${run.id}`,
  `${principal.team_id}`, `${principal.user_id}`, `${principal.locale}`. Dotted paths,
  no wildcards. Inside a `map` only: `${item}`, `${item.<path>}`, `${index}` —
  confined there by the validator, so reaching for one elsewhere is a publish-time
  rejection rather than a null at run time.
- **Predicates for `choice`:** `eq · ne · lt · gt · contains · exists · empty`.
  Left side a reference, right side a literal or a reference.
- **No arithmetic, no string functions, no evaluation of any kind.**

Anything more is a tool call — typed, permissioned, testable, auditable. *"Write a
tool"* is a better answer than *"extend the expression language"*, and saying so in
v1 is what stops v2 from being a scripting engine nobody chose to build.

### Data shapes

```
workflow_defs(id pk, team_id fk, slug, version int, source, spec json,
              status, created_by, created_at)
              UNIQUE(team_id, slug, version)
              source: 'plugin:<id>' | 'db' | 'builtin'

workflow_runs(id pk, def_id fk, team_id fk, user_id fk, status,
              input json, output json, error, cursor_json json,
              steps_used int, created_at, started_at, finished_at)
              -- cursor_json, not `cursor`: the bare word is a SQL key word and
              -- the schema stays dialect-neutral without quoting tricks

workflow_steps(id pk, run_id fk, step_id, seq int, status, attempt int,
               job_id fk jobs, input json, output json, error,
               started_at, finished_at)
```

**No `org_id` anywhere**, matching the rule TEN‑2 already set for notes and
documents: a team belongs to exactly one org, so the org is derivable, and a second
source of truth is a second thing that can drift.

### Execution — a reducer, not a thread

The interpreter never blocks and never sleeps:

```
advance : (conn run) -> 'done | 'waiting | (listof next-step)

  1. read the run's cursor and its completed steps   — from the DB, not memory
  2. decide the next step(s)
  3. enqueue each as a scheduler job of kind "flow.step"
  4. when a step job finishes, its handler records the output
     and calls advance again
```

Consequences, all **inherited** rather than built:

- **Crash-safe** — a restart resumes from the database; no in-memory run state.
- **Cancellable** — cancel the queued step jobs and mark the run; SCHED‑7's
  "cancelable, not preemptible" applies unchanged.
- **Metered** — every step is a job, so quota admission already gates it and an
  over-budget team's run *defers* rather than fails.
- **Fair** — the per-team concurrency cap already stops one team's fan-out from
  monopolising the pool.
- **Testable** — `advance` is pure over a database snapshot. No model, no server,
  no clock. Exactly the discipline `run-agent` established, one level up.

### Security and tenancy

| Concern | Answer |
|---|---|
| Ambient authority | A run pins a principal at start; **every** step re-checks `can?` with it. Permissions never accumulate across steps; a workflow can never do what its starter could not. |
| Org isolation | Definitions are team-scoped, so the org gate at step 0 applies untouched. A cross-org workflow is impossible **by construction**, not by policy. |
| Prompt injection | An `agent` step's context is an earlier step's output — a fetched page, a file, an email body. It goes through `untrusted-context-message`, the boundary `loop.rkt` already enforces, so tool output stays data. |
| Runaway loops | Capped twice: a per-run `max_steps` in the spec, and a `workflow.steps` quota dimension nesting under the org cap like everything else. |
| Permissions | New `workflows:read` / `workflows:write` / `workflows:run`. Per TEN‑2a an org admin gets `read` — definitions, runs, failures — and **not** `run`, because running someone's workflow is reading their data by proxy. |
| Dark launch | A `workflows` feature flag, per team, through the existing registry. |
| Plugin trust | Unchanged: in-process plugins hold platform privileges, and installing one is the consent. The gain is that a plugin expressing its work as a spec is *inspectable*, which is the precondition for ever sandboxing it. |

### The plugin SDK addition — one optional export

```racket
(provide tools init! workflows)   ; workflows : (listof spec-jsexpr)

; …and/or drop plain files at plugins/<id>/workflows/*.json,
;    auto-loaded exactly like plugin.json is today.
```

This mirrors how `init!` was added: optional, `dynamic-require` with a default,
breaking nothing that already loads. The plain-file path stays supported because it
costs nothing — it is the same loader — but it is the storage format, **not** a
recommended authoring surface, and it does not get its own tutorial.

### Endpoints

| Endpoint | Gated by | Does |
|---|---|---|
| `POST /api/workflows` | `workflows:write` | Validate and publish a definition; versions on conflict |
| `GET /api/workflows` | `workflows:read` | The team's definitions, with source and version |
| `GET /api/workflows/<slug>` | `workflows:read` | The spec itself — what the diagram renders from |
| `GET /api/workflows/schema` | public | The spec version and shape this instance accepts — contract discovery |
| `POST /api/workflows/<slug>/run` | `workflows:run` | Start a run with an input object; returns a run id |
| `GET /api/runs/<id>` | `workflows:read` | Run status plus every step's status, timing and error |
| `POST /api/runs/<id>/cancel` | `workflows:run` | Cancel queued steps; running ones finish |
| `POST /api/runs/<id>/approve/<step>` | the step's own permission | Release a parked `approve` gate; writes to `audit_log` *(slice 48)* |
| `GET /api/runs` | `workflows:read` | The team's recent runs |

### What "public contract" commits us to (WF‑9)

The spec is public: documented, versioned, publishable. Most of the bill is paid in
the first commit rather than retrofitted.

1. **A spec-format version in every document** — `"spec": 1`, distinct from the
   workflow's own `version`. There is no way to add it later without guessing.
2. **One validator, and it is normative.** Both the macro's output and
   API-submitted JSON pass through the same module. If `define-workflow` gets a
   private fast path, the two definitions drift inside one release.
3. **Unknown fields are rejected** (WF‑10). Ignoring them means a v2 feature
   silently no-ops on a v1 runtime; for something that takes actions, that failure
   mode reads as *"the approval step was skipped"*.
4. **Additive-only within a spec version.** New step kinds and optional fields are
   free; removing or repurposing a field is a version bump.
5. **A round-trip test as a permanent gate** — publish → store → load → execute
   unchanged, in `raco test`. The cheapest thing that stops the Racket path and the
   JSON path from diverging.
6. **A reference page that says "subset, not conformant"** — WF‑3 borrows CNCF
   Serverless Workflow vocabulary, and the document must be explicit that a real
   Serverless Workflow file will not run here.

**Not** committed: the interpreter internals, the Racket-side API, the tables, and
the `cursor` column in `workflow_runs`. Run state is private and may change freely.

### The visual interface, staged

- **v1 — read-only, ships with the engine.** Render the spec as a DAG, and a run as
  the same DAG with node status colours. Mermaid is MIT and needs no build step.
  Seeing what a workflow does is most of the value; editing is the rest.
- **v2 — an optional canvas editor** round-tripping the same JSON. Drawflow,
  Rete.js and React Flow are all MIT; the choice can wait until someone asks to
  drag a box.
- **Nothing in the engine ever depends on the editor existing.** That is the payoff
  for making the spec the contract.

## Alternatives considered

### A Racket-only DSL, with no spec underneath

The nicest thing to write, and the fastest to prototype — the macro machinery in
`dsl.rkt` is directly reusable. Rejected **as the contract** (not as the authoring
surface, which it is): durability forces the data structure back anyway, since a
crash-resumable run needs stable step ids and a re-readable graph. The macro can
hide that; it cannot avoid it. Having been forced to build it, the only saving left
is refusing to write it to a column. Beyond that it is not storable, not
publishable without a redeploy, has nothing to render, and could never be honoured
by a second implementation.

Note also that Racket continuations are not durably serializable across a process
restart, so a checkpointing runtime must checkpoint at step boundaries regardless.
The macro does not buy a free `await`.

### Adopting an existing engine

Licences below are as understood at time of writing and should be re-confirmed
before adoption.

| Candidate | Licence | Verdict |
|---|---|---|
| **n8n** | Sustainable Use (source-available) | Excluded: fails clean-MIT *and* no-open-core, on principle rather than merit |
| **Windmill** | AGPL‑3.0 | Excluded: strong copyleft breaks the MIT promise to embedders |
| **Temporal** | MIT | Licence is fine; a Go server, gRPC SDKs, its own datastore and no Racket SDK are not. *The best argument against adopting an engine is that even the MIT one is too heavy.* |
| **Node-RED** | Apache‑2.0 | Best-known visual editor; runtime is Node plus a second execution model. Steal the editor idea, not the runtime |
| **Airflow · Prefect** | Apache‑2.0 | Python-first, heavyweight; collides with the deterministic-deps tenet |
| **CWL** | Apache‑2.0 | Excellent spec discipline, wrong domain (container batch science); Python runner |
| **BPMN 2.0 + bpmn-js** | OMG spec; MIT **+ attribution** | Standard is vast relative to the need; `bpmn-js` carries a watermark/attribution requirement worth flagging early |
| **Amazon States Language** | vendor terms | Clean state model, but not a plain OSI grant — avoid for a project selling licence cleanliness |
| **CNCF Serverless Workflow** | Apache‑2.0 **spec** | **Borrowed.** A vendor-neutral state vocabulary with no runtime to adopt; we implement the subset we need in MIT Racket |
| **Drawflow · Rete.js · React Flow** | MIT | Canvas libraries, not engines — shelved for the v2 editor |
| **Mermaid** | MIT | Read-only DAG rendering at near-zero cost; good enough for v1 |

Apache‑2.0 *code* can legally ship inside an MIT distribution — permissive licences
compose one way — but those files keep their own terms, NOTICE obligations and
patent grant. For a project whose pitch is *clean MIT, nothing held back*, depending
on a **specification** is categorically cleaner than depending on code.

No established Racket workflow engine surfaced in this review; worth one pass over
the package catalog before treating that as settled.

### The smaller answer this beats

*"A plugin runs three steps in order"* is available **today** with
`register-job-kind!` and a handler that calls three tools — durable, quota-metered,
cancellable, roughly forty lines. If that were the whole requirement, this would be
over-build. It is not, because a handler cannot:

- **park for a human** — a handler holding a worker thread cannot wait three days
  for an approval; a durable run row can, and costs nothing while it waits;
- **be seen** — forty lines of Racket inside a plugin is not a management surface
  for an org admin who administers a company whose data they may not read;
- **be reused** — a sequence embedded in one handler belongs to one plugin;
- **be changed without a redeploy** — and under TEN‑2 a tenant cannot rebuild the
  instance, so on a shared deployment "edit the Racket" is available to the operator
  and to nobody else.

## Build slices

| Slice | Contents | Done when |
|---|---|---|
| **46** ✅ | `define-workflow` macro *and* the spec it emits + the single strict validator + `advance` interpreter + the `flow.step` job kind + `tool`/`choice` steps + tables + endpoints + `/schema` + tests | **Done.** `domain/flow/{bind,spec,dsl,run}.rkt`, migration `0017-workflows`, `test/flow-tests.rkt` (15 cases, incl. a run resumed by a second process against the same file database and a cross-org refusal) |
| **47** ✅ | `map` + the plugin `workflows` export and `workflows/*.json` loader + `users.locale` + the Translate Chat demo plugin. *(`agent`, `job:` and `flow:` step kinds deferred — nothing needed them yet.)* | **Done.** `plugins/translate-chat/` ships a three-step workflow with two chained fan-outs; `test/translate-chat-demo.sh` drives it against a live model |
| **48** | Run view in the console + Mermaid DAG + the `approve` gate + audit events | A parked run is visible, approvable, and the approval is in `audit_log` |
| **49** | *Optional.* Canvas editor round-tripping the spec | Only if someone asks to drag a box |

Slice 46 is the only irreversible commitment, and it ships the Racket authoring
surface with it — nobody writes JSON by hand to try the feature. 47–49 are additive
and each can be dropped without stranding the one before it.

## Decisions

| id | Decision | Status |
|---|---|---|
| WF‑1 | The **data spec is the contract**; `define-workflow` is the authoring surface that compiles to it | ✅ decided |
| WF‑2 | Binding sublanguage **frozen**: references + a fixed predicate set, no evaluation | ✅ decided |
| WF‑3 | Borrow CNCF Serverless Workflow **vocabulary** as a documented subset; claim no conformance | ✅ decided |
| WF‑4 | Durability unit is **one scheduler job per step** | ✅ decided |
| WF‑5 | Human `approve` gate lands in v1 (slice 48) | ✅ decided |
| WF‑6 | Visual interface is **read-only** at v1; editor deferred | ✅ decided |
| WF‑7 | New `workflows:{read,write,run}`; org admins get `read` only, per TEN‑2a | ✅ decided |
| WF‑8 | Plugin steps run in process with platform privileges, as tools do | ✅ decided — out of scope; revisit as hardening |
| WF‑9 | The spec is a **public contract** — documented, versioned, API-publishable | ✅ decided — Racket stays the documented way to write one |
| WF‑10 | Unknown fields in a submitted spec are **rejected** | ✅ decided — a silent no-op on a step that takes action is worse than a refusal |

## Built (slice 46)

| File | What it is |
|---|---|
| `domain/flow/bind.rkt` | The frozen binding sublanguage: references, interpolation, the seven predicates |
| `domain/flow/spec.rkt` | **The normative validator** + `spec-schema` for `/api/workflows/schema` |
| `domain/flow/dsl.rkt` | `define-workflow` — checks duplicate ids, undeclared step references, predicate arity and input types while the module compiles, then runs its output through `validate-spec` |
| `domain/flow/run.rkt` | Publish/version definitions, start/cancel runs, the `advance` reducer, and the `flow.step` job kind (registered at module level, so requiring it is all the wiring there is) |
| `domain/db/migrations.rkt` | `0017-workflows` — `workflow_defs`, `workflow_runs`, `workflow_steps` |
| `test/flow-tests.rkt` | 15 cases; `raco test test/*-tests.rkt` picks it up, so CI covers it |

Two things worth knowing about the build that the design above does not say:

- **A retried step's job reports success.** The step row is where a run's truth
  lives — it says `queued, attempt N+1` — and letting the job fail too would double
  count the failure in `jobs`. Only the final, exhausted attempt marks the step (and
  the run) `error`.
- **Tool existence is not checked at publish time.** Plugins register tools when
  they load, so `uses: "tool:x"` is shape-checked on publish and resolved when the
  step runs; an unregistered tool fails that step with `unknown tool 'x'`. Checking
  earlier would make publishing depend on load order.

## The Translate Chat demo (slice 47)

`plugins/translate-chat/` is the first plugin to ship a **workflow**, not just
tools. It is deliberately useless as a product and deliberately thorough as a test:

```
  chat        tool:chat_message                       one model turn, user's language
  to_all      map over ["es","nl","is"]            -> tool:translate_text
  back_home   map over ${steps.to_all.output.results} -> tool:translate_text
                                                      …back into ${principal.locale}
```

Three steps, nine step rows, seven model calls. What it actually exercises: a
plugin-registered tool as a workflow step; one step's output feeding two later
steps; two **chained** fan-outs where the second maps over the first's results; the
profile language as a binding; and — with `translate_text` switched off mid-demo —
a run that stops at the failing fan-out and hands the reason back to its initiator
without running anything downstream.

```sh
export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
export TELEMACHUS_MODEL=qwen2.5:7b
bash test/translate-chat-demo.sh
```

**Not in CI**, and it refuses to start without `TELEMACHUS_MODEL_URL`: with no model
the platform's uppercase-echo fallback would answer every call, the run would go
green, and it would prove nothing. Failing is the better outcome.

The lossy round trip is the point — comparing each return against the original is a
translation-quality smoke test you can read. From a representative run: *"That's a
great achievement; well done on your cautious pride!"* came back from Dutch as
*"That is a great performance; well done with your cautious pride!"*, and from
Icelandic as *"This is goldingly well performed; well done within your time limit!"*

### What it forced into the design

- **`users.locale`** (migration `0018`). i18n had only ever been request-scoped
  (`Accept-Language`); "translate back into the user's language" has to be a
  property of the profile, not of whichever browser started the run. Exposed on
  `GET /api/whoami`, set with `POST /api/profile`, bound as `${principal.locale}`.
- **Plugin definitions are materialized, not published.** A plugin has no team at
  load time, so its specs live in a registry and are copied into a team's
  `workflow_defs` the first time that team looks one up — `source: 'plugin:<id>'`.
  The run still references a real, versioned row and the foreign key stays honest.
- **A fan-out completes under a lock.** Children finish on different worker threads,
  so "was I the last one?" and the parent's write have to be one critical section,
  or two children both see a full house and the next step is enqueued twice.
