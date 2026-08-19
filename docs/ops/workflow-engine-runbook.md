# Workflow Engine — setup & test runbook

Operator-facing. How to stand the workflow engine up, prove it works, and read the
failures. Design rationale lives in
[../design/workflow-engine.md](../design/workflow-engine.md); this file is the
runbook.

**Everything below runs from `refimpl/racketmaximus/`.**

---

## 1. What you are deploying

A workflow is a validated JSON **spec**, published per team, executed one step at a
time. Each step becomes a row in the existing `jobs` table, so the engine adds no
new runtime, no new daemon and no new datastore — if the server runs, workflows run.

```
POST /api/workflows/<slug>/run
        │
        ▼
  workflow_runs  ──advance──▶  workflow_steps  ──▶  jobs  ──▶  worker pool
   (cursor_json)                (one per step)      (existing scheduler)
```

**Operational consequences, all inherited:**

| Property | Comes from | What it means for you |
|---|---|---|
| Survives restart | run state is rows, not memory | `systemctl restart` mid-run is safe; the run resumes |
| Cancellable | `POST /api/runs/<id>/cancel` | queued steps stop; a step already running finishes (SCHED‑7) |
| Rate limited | the scheduler's per-team concurrency cap | a 500-item fan-out cannot self-DDOS; it drains at the cap |
| Budgeted | quota admission at claim time | an over-budget team's steps **defer** (stay queued), they do not fail |
| Isolated | the org gate at step 0 of `can?` | a workflow cannot read across an org boundary (TEN‑2) |
| Audited | `audit_log` | `workflow.publish` and `workflow.run` events |

---

## 2. Prerequisites

### Option A — Nix (recommended)

Nothing to install but Nix itself. The toolchain, its version, and every test
dependency are pinned in `flake.lock`.

```sh
nix run  github:IoTone/Telemachus            # run a server, no checkout needed
nix build github:IoTone/Telemachus           # build + run the full unit suite
nix develop                                  # dev shell, from a checkout
nix flake check                              # unit suite + HTTP smoke, sandboxed
```

`nix develop` gives you Racket 9.2, `PLTCOLLECTS` already exported, plus
PostgreSQL, SQLite, OpenSSL, Node and `jq`. It replaces the entire ritual in
Option B — no brew, no `PATH` surgery, no exported collection paths.

The packaged server writes **nothing** to its own install prefix: state goes to
`$TELEMACHUS_DATA_DIR`, defaulting to `${XDG_STATE_HOME:-$HOME/.local/state}/telemachus`.

```sh
nix profile install github:IoTone/Telemachus
TELEMACHUS_DATA_DIR=/var/lib/telemachus PORT=8835 telemachus-server
```

> `nix build` runs `raco test test/*-tests.rkt` and the localization gate **inside
> the sandbox**, so a successful build is a passing test run. `nix flake check`
> adds the HTTP smoke, which binds a port and therefore cannot live in the build.

### Option B — manual toolchain

| | |
|---|---|
| Racket | **9.2 CS** (`minimal-racket`). Distro packages are usually 8.x — too old. |
| Python 3 | the demo scripts parse JSON with it |
| curl | the demo scripts |
| A model | **only** for `translate-chat-demo.sh`. Everything else runs without one. |

```sh
# Linux (linuxbrew) / macOS (homebrew) — same formula
brew install minimal-racket
export PATH="$(brew --prefix minimal-racket)/bin:$PATH"
```

```sh
cd refimpl/racketmaximus
export PLTCOLLECTS="$PWD/pkgs:"     # REQUIRED, every shell — see §7
raco make server/main.rkt           # precompile; startup is slow otherwise
```

---

## 3. Configuration

Only the first three matter for a workflow deployment. Everything else has a
working default.

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | derived from `TELEMACHUS_DATA_DIR` | `postgres://user:pass@host:port/db` also supported |
| `PORT` | `8835` | `TELEMACHUS_PORT` is a synonym |
| `TELEMACHUS_MODEL_URL` | *unset* | **OpenAI-compatible chat-completions URL.** See the warning below. |
| `TELEMACHUS_MODEL` | `local` | model name sent to that endpoint |
| `TELEMACHUS_MODEL_KEY` | *unset* | bearer token, if the endpoint needs one |
| `TELEMACHUS_DATA_DIR` | checkout: `./data` · Nix: `$XDG_STATE_HOME/telemachus` | **all** writable state — the database, TLS material, uploads. `DATABASE_URL` defaults to `sqlite:///$TELEMACHUS_DATA_DIR/telemachus.db`. |
| `TELEMACHUS_PLUGINS` | `./plugins` | plugin directory; plugins load at startup |
| `TELEMACHUS_MULTITENANT` | `0` | orgs above teams; workflows are team-scoped either way |
| `TELEMACHUS_BIND` | **`127.0.0.1`** | loopback by default — a container or remote host must set `0.0.0.0` |
| `TELEMACHUS_TLS` | off | with `TELEMACHUS_TLS_CERT` / `_KEY` |

> **The one that will burn you.** With `TELEMACHUS_MODEL_URL` **unset**, the server
> does not error — it answers every model call with a *simulated uppercase echo*. A
> workflow with translation steps will complete successfully and return garbage.
> If your workflows call a model, treat a missing `TELEMACHUS_MODEL_URL` as a
> failed deployment. `test/translate-chat-demo.sh` refuses to start without it for
> exactly this reason.

> **Second one that will burn you.** The server binds **loopback** by default. In a
> container or on a remote host it will come up healthy, log nothing unusual, and be
> unreachable from outside. Set `TELEMACHUS_BIND=0.0.0.0` (and put a TLS terminator
> in front, or set `TELEMACHUS_TLS`).

Migrations run automatically at startup. Workflows add `0017-workflows` (three
tables) and `0018-user-locale` (one column). No manual step.

---

## 4. Health & readiness

```sh
curl -s localhost:8835/health
# {"kdf":"pbkdf2_sha1","multitenant":false,"ok":true,"service":"telemachus","tls":false,"version":"0.1.0"}
```

`/health` is liveness. For **workflow readiness**, probe the contract endpoint —
it is unauthenticated by design so a probe needs no credentials:

```sh
curl -s localhost:8835/api/workflows/schema
# {"spec":1,"step_kinds":["tool:<name>","choice","map"],"unknown_fields":"rejected", …}
```

A non-200, or a `spec` that is not the version your workflow documents declare, is
the signal to stop the rollout.

Plugins that shipped workflows are listed on startup and at `/api/plugins`:

```
  plugin: translate-chat v0.1.0 — 2 tool(s), 1 workflow(s)
```

---

## 5. The test tiers

Four tiers, cheapest first. Tiers 1–3 need **no model** and run in CI today.

### Tier 1 — unit (~15 s, no server, no network)

```sh
export PLTCOLLECTS="$PWD/pkgs:"
raco test test/flow-tests.rkt        # the engine: 20 cases
raco test test/*-tests.rkt           # everything: 137 cases
```

Covers the validator (including that unknown fields and newer spec versions are
*rejected*), the binding sublanguage, fan-out ordering and failure, `max_steps`,
retries, cross-org refusal, and a run resumed **by a second database connection**
after the first is closed — the durability claim, tested rather than asserted.

> **Never** run `raco test test/*.rkt`. That glob pulls in `test/mock-*.rkt`, which
> are mock *servers* that block forever. Always `test/*-tests.rkt`.

### Tier 2 — HTTP smoke (~30 s, boots a server on a temp DB)

```sh
bash test/server-smoke.sh            # or PORT=8890 bash test/server-smoke.sh
# → server-smoke: PASS
```

Includes the workflow endpoints end to end: publish, list, run, poll, and assert
the notes the steps actually created — plus that a spec with an unknown field is
refused with **400**, that a member without `workflows:write` is refused with
**403**, and that a workflow honors per-team tool activation.

### Tier 3 — multi-tenancy (~40 s, needs `PORT` and `PORT+1`)

```sh
bash test/multitenant-demo.sh        # 56 assertions
```

Not workflow-specific, but it is what proves the org gate the engine relies on.

### Tier 4 — the real thing (~2 min, **needs a live model**)

```sh
# warm the model first; a cold pull inside the demo looks like a hang
ollama serve &
ollama run qwen2.5:7b </dev/null

export TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
export TELEMACHUS_MODEL=qwen2.5:7b
bash test/translate-chat-demo.sh
```

Drives the `translate-chat` plugin's workflow: one chat turn, a fan-out to Spanish,
Dutch and Icelandic, then a second fan-out bringing each back to the user's own
language — 3 steps, 9 step rows, 7 model calls. Then it switches the translation
tool off mid-demo and asserts the run stops at the failing fan-out and hands the
reason back without running anything downstream.

**Not in CI** (no model on the runner), and it exits **2** rather than run against
the echo fallback if `TELEMACHUS_MODEL_URL` is unset.

Use `qwen2.5:7b`. Avoid `qwen3.5` "reasoning" models — their answer lands in a
`reasoning` field the OpenAI-compatible path does not read, so steps come back
empty.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | pass |
| `1` | an assertion failed, **or** the port was busy (message on stderr) |
| `2` | `translate-chat-demo.sh` only: `TELEMACHUS_MODEL_URL` not set |

All four scripts run on a `mktemp -d` database and clean up after themselves. They
touch no deployed data.

---

## 6. Verifying a deployment by hand

```sh
B=localhost:8835
TOK=$(curl -s -X POST $B/api/bootstrap -d '{"username":"ops","password":"CHANGE-ME"}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
A="Authorization: Bearer $TOK"

# 1. the contract this build speaks
curl -s $B/api/workflows/schema

# 2. what is installed (plugin workflows appear on first listing)
curl -s $B/api/workflows -H "$A"

# 3. publish a trivial one
curl -s -X POST $B/api/workflows -H "$A" -d '{
  "spec":1,"slug":"ping","input":{"title":"string"},
  "steps":[{"id":"note","uses":"tool:create_note",
            "with":{"title":"${input.title}","body":"from a workflow"},"end":true}]}'

# 4. run it, then read the run
RID=$(curl -s -X POST $B/api/workflows/ping/run -H "$A" \
        -d '{"input":{"title":"deploy check"}}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s $B/api/runs/$RID -H "$A"
```

A healthy run reaches `"status":"done"` within a second or two for tool-only steps.

### Endpoints

| Endpoint | Permission | |
|---|---|---|
| `GET /api/workflows/schema` | *none* | contract discovery; safe as a probe |
| `POST /api/workflows` | `workflows:write` | publish; re-publishing a slug bumps its version |
| `GET /api/workflows` | `workflows:read` | the team's definitions |
| `GET /api/workflows/<slug>` | `workflows:read` | the spec itself |
| `POST /api/workflows/<slug>/run` | `workflows:run` | returns `202` and a run id |
| `GET /api/runs` · `/api/runs/<id>` | `workflows:read` | run + every step's status, timing, error |
| `POST /api/runs/<id>/cancel` | `workflows:run` | `409` if already finished |
| `POST /api/profile` | *authenticated* | `{"locale":"es"}` — what `${principal.locale}` binds to |

Org admins hold `workflows:read` and **not** `workflows:run`: running someone's
workflow is reading their data by proxy, which TEN‑2a forbids.

---

## 7. Failure modes

Ordered by how often they will actually happen.

| Symptom | Cause | Fix |
|---|---|---|
| A wall of unrelated assertion failures | another server already on that port; the scripts' readiness probe was satisfied by *it* | the scripts now refuse to start — heed `port … is already in use` and set `PORT` |
| Steps complete instantly, output is the input in CAPITALS | `TELEMACHUS_MODEL_URL` unset → simulated echo | set it; restart |
| `reference to a variable that is not exported` | stale `.zo` after a module's exports changed | `raco make` the tests too, or delete `compiled/` |
| Module not found / wrong module loaded | `PLTCOLLECTS` unset — `pkgs/{cli-kit,db-kit,web-kit}` collide with any linked Odysseus copies | `export PLTCOLLECTS="$PWD/pkgs:"` |
| A run sits at `"status":"running"` forever | its steps are `queued` and the team is over quota — deferral, not failure | check `GET /api/usage`; raise the limit or wait for the window |
| `400 invalid workflow spec: … unknown field 'x'` | strict validation (WF‑10) | remove the field, or the document was written for a newer build |
| `400 … unsupported spec format version 2` | the document is newer than this server | upgrade the server; do **not** hand-edit the version |
| `unknown tool 'x' — no plugin registered it` | tool names resolve at run time, not publish time | check the plugin loaded: `GET /api/plugins` |
| `tool 'x' is disabled for this team` | per-team tool activation | `POST /api/tools/<name> {"enabled":true}` |
| `max_steps exceeded` | a `next`/`then` cycle that never terminates | intended backstop; fix the workflow |
| The test suite hangs with no output | you ran `raco test test/*.rkt` | use `test/*-tests.rkt` |
| `error: Path 'x' … is not tracked by Git` | Nix only sees git-tracked files | `git add` the new file — an untracked source is invisible to the build |
| `nix build` succeeds but the server writes into the store | you overrode `DATABASE_URL` with a *relative* sqlite path | use an absolute path, or leave it unset and let it follow `TELEMACHUS_DATA_DIR` |

### Reading a failed run

`GET /api/runs/<id>` is the whole diagnosis. `error` says which step and why; the
`steps` array carries per-step `status`, `attempt`, `error` and the `job_id` that
executed it. A fan-out child is named `<map>#<i>`, so `to_all#0` is the first item
of the `to_all` fan-out.

```json
{"status":"error",
 "error":"step 'to_all#0' failed: flow: tool 'translate_text' is disabled for this team",
 "steps":[{"step_id":"chat","status":"done", …},
          {"step_id":"to_all","status":"error", …},
          {"step_id":"to_all#0","status":"error","attempt":2, …}]}
```

`attempt: 2` means the step's `retry.max` was honored before it gave up. Steps after
the failure are absent because they never ran — a failed step stops the run.

---

## 8. CI

The existing job already covers tiers 1–3; the unit step is a **glob**, so
`flow-tests.rkt` was picked up with no CI change:

```yaml
- name: Unit tests
  run: |
    export PLTCOLLECTS="$(pwd)/pkgs:"
    raco test test/*-tests.rkt      # glob — a named list silently skips new suites
- name: Server smoke
  run: bash test/server-smoke.sh
- name: Multi-tenancy demo
  run: bash test/multitenant-demo.sh
```

Tier 4 is deliberately absent: a runner with no model would run the echo fallback
and report success. To cover it, add a job with a model service and set
`TELEMACHUS_MODEL_URL`; without one, leave it out rather than let it pass falsely.

---

## 9. Backup & upgrade

- **State** is entirely in the database: `workflow_defs`, `workflow_runs`,
  `workflow_steps`, `jobs`. Back up the database and you have backed up every
  in-flight run.
- **Migrations** apply at startup, in order, once. Roll forward only.
- **In-flight runs across an upgrade**: a run references the `workflow_defs` row and
  *version* it started on, so republishing a workflow never changes a running one.
  Steps mid-flight resume from `cursor_json` after a restart.
- **A step whose job was `running` when the process died** stays `running` — the
  scheduler does not reap orphans. Rare, but if a run is stuck on a step whose job
  is `running` with no worker, cancel the run and start it again.
