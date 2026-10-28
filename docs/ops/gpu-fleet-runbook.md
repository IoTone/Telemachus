# Staging a multi-GPU host into the worker fleet

How to put a box with several GPUs to work for a TMach instance, and the four
things that will otherwise silently waste it.

The shape is one sentence: **one inference server per card, each with its own
TMach worker in front of it.** Everything below follows from that, and none of
it requires a line of TMach configuration beyond minting an executor per worker
and raising three quotas.

Companion files, meant to be copied rather than retyped:

- [`deploy/gpu-fleet/ollama-gpu@.service`](../../deploy/gpu-fleet/ollama-gpu@.service)
- [`deploy/gpu-fleet/readyd.py`](../../deploy/gpu-fleet/readyd.py)
- [`deploy/gpu-fleet/tmach-readyd@.service`](../../deploy/gpu-fleet/tmach-readyd@.service)
- [`deploy/gpu-fleet/telemachus-worker@.service`](../../deploy/gpu-fleet/telemachus-worker@.service)

Related: [pull executors](../design/pull-executors.md) for the protocol,
[configuration](configuration.md) for every variable named here.

---

## The one thing to understand first

**A TMach worker owns no GPU, and the platform has no concept of one.** A worker
is a queue client: it long-polls for a job, POSTs to an OpenAI-compatible
`/v1/chat/completions`, and returns the answer. Which card serves that request
is entirely the inference server's business.

So "split the workers across the GPUs" is not a TMach setting. It is four
inference servers, each pinned with `CUDA_VISIBLE_DEVICES`, each with a worker
pointed at its port. The platform sees four ordinary pull executors and
distributes work across them exactly as it would across four separate machines.

That is also why the readiness gate asks a **URL** rather than reading a GPU
(#93): what "this host can take work" means is the operator's, and on a rig it
means VRAM headroom, a temperature ceiling, or "somebody is using the desktop
this card drives". `readyd.py` is the seam where yours goes.

**One worker per card is the default. One worker for several cards** is right
only when the model will not fit on one — then the inference server splits
layers across a group and a single worker fronts it. On consumer cards with no
NVLink that split goes over PCIe and is markedly slower, so it is a fallback for
"will not fit", not a starting point. The two mix freely: one worker over two
cards for a large model, plus single-card workers beside it.

## 0. Before anything: the driver and the cards

Settle the hardware before TMach is involved at all.

- **Check the driver version first.** `nvidia-smi` reports it. Current ollama and
  llama.cpp CUDA builds want driver **≥ 525** (CUDA 12), or ≥ 450 for CUDA 11. A
  2017-era driver (the 384 series, CUDA 9) will not run any of them, however
  healthy the cards are — Pascal `sm_61` and later are still supported, so this
  is a driver upgrade and a reboot, not new hardware.
- **Read the whole `nvidia-smi` table, not just the VRAM column.** A card
  reporting `ERR!` for power draw is a card to settle before you give it work. A
  card with `Xorg`, a desktop shell or an office application in its process list
  is driving a display: its jobs will contend with whoever is using the machine,
  and a large model plus a browser will exhaust its memory. Either leave that
  card out of the fleet or give it the smallest model.
- **Write down each card's usable VRAM**, because step 2 turns it into a declared
  model list and that declaration is the one thing here that fails quietly.

## 1. What the rig needs installed

- **The worker.** `nix profile install github:IoTone/Telemachus` puts
  `telemachus-worker` on the box. A worker-only host needs nothing else from
  this repository — no checkout, no build toolchain, no test suite.
- **An inference server** — ollama, or llama.cpp's `server`, or anything else
  that speaks OpenAI-compatible `/v1/chat/completions`.
- **Network reachability to the TMach server.** Outbound only: the worker
  connects out and nothing ever connects in, so this works through NAT, through
  a tailnet, and with no inbound firewall rule.
- `python3` for the readiness probe (stdlib only).

## 2. Decide the layout, and mind the VRAM

One row per card. Example for a rig of three 8 GB cards and one 4 GB:

| GPU | VRAM | Port | Model to declare | Note |
|---|---|---|---|---|
| 0 | 8 GB | 11430 | `qwen2.5:7b` | |
| 1 | 4 GB | 11431 | `qwen2.5:3b` | a 7B at q4 is ~4.7 GB and **will not fit** |
| 2 | 8 GB | 11432 | `qwen2.5:7b` | |
| 3 | 8 GB | 11433 | `qwen2.5:7b` | drives the desktop — expect contention |

**The port scheme is `1143<i>` for inference and `890<i>` for readiness**, so the
GPU index is a digit in every port, endpoint and log line. It deliberately
avoids ollama's default `11434`: a stray unpinned `ollama serve` on the default
port will have grabbed GPU 0, and it must not be mistakable for a member of the
fleet.

**`TMACH_WORKER_MODELS` is load-bearing twice over, and a mistake there is
silent.** It is what the platform matches a job's `requirements.model` against,
so a card declaring a model it cannot serve is offered exactly those jobs — and
it is the model the worker sends when a job names none, taking the **first** in
the list. So a mis-declared card answers with the wrong model rather than
refusing. Declaring the 3B on the 4 GB card is not a workaround for the
capability matching; it is the capability matching doing its job.

## 3. Four inference servers, one per card

Install [`ollama-gpu@.service`](../../deploy/gpu-fleet/ollama-gpu@.service) as
`~/.config/systemd/user/ollama-gpu@.service`, then:

```sh
loginctl enable-linger "$USER"          # or user units stop when you log out
systemctl --user daemon-reload
systemctl --user enable --now ollama-gpu@0 ollama-gpu@1 ollama-gpu@2 ollama-gpu@3
```

Pull each model **once** — all four share `OLLAMA_MODELS`, so a second pull
through another port downloads nothing:

```sh
OLLAMA_HOST=127.0.0.1:11430 ollama pull qwen2.5:7b
OLLAMA_HOST=127.0.0.1:11431 ollama pull qwen2.5:3b
```

Confirm each card really is pinned before going further — four servers that all
landed on GPU 0 behave like one slow card and look like four healthy workers:

```sh
for i in 0 1 2 3; do curl -s "127.0.0.1:1143$i/api/version"; echo " <- gpu $i"; done
nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv
```

## 4. A readiness endpoint per card

```sh
install -D deploy/gpu-fleet/readyd.py ~/tmach/readyd.py
install -D deploy/gpu-fleet/tmach-readyd@.service \
           ~/.config/systemd/user/tmach-readyd@.service
systemctl --user daemon-reload
systemctl --user enable --now tmach-readyd@0 tmach-readyd@1 tmach-readyd@2 tmach-readyd@3
```

`touch ~/tmach/pause2` then stands GPU 2 down by hand and removing the file
brings it back. Add `nvidia-smi` checks to `readyd.py` if you want temperature
or ECC state to gate work — that is the operator's call by design, and it is why
this file exists rather than a knob in the worker.

## 5. Mint one executor per worker — on the server

From a machine signed in as an operator (`instance:manage`). **One per card, and
never a shared token**: two processes presenting one token resolve to the *same*
executor, so the fleet view would be wrong about what is running and a drain
would take both workers out.

```sh
B=https://tmach.example.internal        # the TMach server
for i in 0 1 2 3; do
  curl -s -X POST "$B/api/executors" -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"rig-gpu$i\",\"mode\":\"pull\"}"
done
```

`capabilities` may be passed here and does not need to be: the worker declares
its kinds and models on **every claim** and the platform records what it
declared. The authority is `TMACH_WORKER_MODELS` on the rig, not what was typed
at create time.

**The worker token is in that 201 response and nowhere else, ever.** There is no
second chance to read it; the way back from losing one is
`POST /api/executors/<id>/rotate-token`. Write each straight to a mode-600 file
on the rig:

```sh
install -m600 /dev/null ~/tmach/token0
printf '%s' '<the worker_token from the response>' > ~/tmach/token0
```

The file is not only hygiene. With `TMACH_WORKER_TOKEN_FILE` set the worker
rotates its own credential when the platform asks it to; without one it refuses
to rotate and says an operator has to do it for it (#60).

## 6. One worker per card

```sh
install -D deploy/gpu-fleet/telemachus-worker@.service \
           ~/.config/systemd/user/telemachus-worker@.service
# edit TMACH_URL, and TMACH_WORKER_MODELS if the cards differ
systemctl --user daemon-reload
systemctl --user enable --now telemachus-worker@0 telemachus-worker@1 \
                              telemachus-worker@2 telemachus-worker@3
```

Override a single card with a drop-in rather than forking the template:

```sh
systemctl --user edit telemachus-worker@1     # TMACH_WORKER_MODELS=qwen2.5:3b
```

Two things about the unit worth knowing before the first restart:

- **`ExecStart` must be an absolute path and `~` does not expand** in a unit
  file — use `%h`. A path that is not there restart-loops on **203/EXEC**, which
  reads as a crashing worker rather than as a wrong path.
- **Give the worker 30 seconds to stop.** It hands its claim back on the way out,
  which costs the job no attempt; killed halfway through that, the job instead
  waits out its 120-second lease before anyone else can take it.

## 7. Raise the quotas — the step that silently wastes the rig

The shipped defaults will throttle four GPUs to a crawl, and **it looks like a
hang rather than a limit**: jobs sit `queued` with nothing `running` and no error
anywhere.

```sh
curl -s -X POST "$B/api/quota" -H "Authorization: Bearer $TOK" \
  -d '{"dimension":"ai.concurrency","limit":4,"window":"instant"}'
curl -s -X POST "$B/api/quota" -H "Authorization: Bearer $TOK" \
  -d '{"dimension":"ai.tokens.total","limit":2000000,"window":"day"}'
curl -s -X POST "$B/api/quota" -H "Authorization: Bearer $TOK" \
  -d '{"dimension":"ai.requests","limit":20000,"window":"day"}'
```

- **`ai.concurrency` defaults to 2 per team**, so four workers would still run
  two jobs at once. This is the single setting that wastes the hardware.
- **`ai.tokens.total` defaults to 2,000/day** — one real conversation crosses it.
- **`ai.requests` defaults to 200/day**, and raising tokens does nothing for it.

`GET /api/jobs` reports a held job's reason, and the Usage tab carries a card for
it, so you can tell "over budget" from "no host can run this" without guessing.

## 8. Verify, and then verify the failure

```sh
curl -s "$B/api/admin/workers" -H "Authorization: Bearer $TOK" \
  | jq '.executors[] | {name, status, worker_state, admin_state}'
```

All four should read `status: active`, `worker_state: ready`. Then put unpinned
work in and watch it spread across the fleet:

```sh
for i in $(seq 1 12); do
  curl -s -X POST "$B/api/jobs" -H "Authorization: Bearer $TOK" \
    -d '{"kind":"infer.chat","payload":{"messages":[{"role":"user","content":"name three bridges"}]}}' &
done; wait
curl -s "$B/api/admin/queue?status=done" -H "Authorization: Bearer $TOK" \
  | jq -r '.jobs[].executor' | sort | uniq -c
```

**Four names in that tally is the fleet working.** One name is a fleet with one
usable worker and three that are declining the work — check `worker_state` and
each card's declared models before anything else.

Then prove the gate: `touch ~/tmach/pause2`, queue more work than the remaining
cards can take at once, and confirm GPU 2 stops appearing while the fleet report
shows the queue **held by a paused host** rather than `unclaimable`. Those are
different answers with different remedies — one clears when you remove the flag,
the other needs a worker that can run the job at all.

## 9. Reaching the rig from chat and from a model role

Unpinned jobs fan out across the fleet on their own. A **chat** and a **model
role** each name one executor, so without the next step the rig is reachable
only one card per call, which is load balancing done by hand with none of the
queue's knowledge of what is live.

The sentinel **`@fleet`** is accepted wherever an executor name is (#173). It can
never collide with a real host, because an executor name may not contain `@`:

```sh
curl -s -X POST "$B/api/ai/chat" -H "Authorization: Bearer $TOK" \
  -d '{"prompt":"hello","executor":"@fleet"}'

curl -s -X PUT "$B/api/model-roles" -H "Authorization: Bearer $TOK" \
  -d '{"roles":{"utility":"@fleet"}}'
```

**The `utility` role is the higher-value half of the two.** Knowledge-graph
extraction, the document pipeline's field extraction and translation, and the
Localization Manager's AI drafts all route through it, and all of them pin to a
single executor until it is set. Pointing it at `@fleet` puts the rig behind
every one of them.

Two limits, stated rather than discovered:

- **A fleet request names a model only when the caller did.** With a model named,
  capability matching still applies and a 4 GB card is never offered a 7B job.
  With none named, whichever host answers uses the first model it declared — so
  a mixed fleet gives a mixed answer, which is what "any host, any model it has"
  honestly means.
- **The agent and the stream refuse `@fleet` by name.** The worker wire carries a
  whole reply, not a token stream and not tool calls (#175). Use
  `POST /api/ai/chat`.

## 10. Day-to-day

| | |
|---|---|
| Stand one card down, reversibly | `touch ~/tmach/pause<i>` on the rig, or `POST /api/executors/<id>/drain` from the server |
| Bring it back | remove the flag, or `POST /api/executors/<id>/resume` |
| Retire a card for good | `DELETE /api/executors/<id>` — **irreversible**: it revokes the worker token and requeues whatever that host held |
| Which card answered | `GET /api/admin/queue` names the executor per job |
| Why is nothing running | `GET /api/admin/workers` — `held_by_paused`, `unclaimable` and a job's own `waiting` reason are three different answers |
| Rotate a worker token | `POST /api/executors/<id>/rotate-token`; with `TMACH_WORKER_TOKEN_FILE` set the worker picks the new one up and writes it itself |

A drain says "start nothing new" and leaves a job already running alone — that is
what makes it the safe thing to do before servicing a card, and why the table
above offers it everywhere `retire` would be the reflex.
