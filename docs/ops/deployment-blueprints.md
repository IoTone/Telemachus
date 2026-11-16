# Deployment blueprints

Five ways to lay out a TMach installation, from one machine in a closet to a
mix of your own hardware and cloud models. Each blueprint says what you need,
how to set it up, and exactly what data leaves your network.

Pick by answering two questions:

1. **Where does the model run?** On your hardware, on a machine you rent, or at
   a public AI provider.
2. **Which of your data is allowed to go there?** All of it, none of it, or
   only some.

| Blueprint | Model runs | Prompts and document text leave your network? |
|---|---|---|
| [1. One box](#1-one-box) | Same machine as TMach | No |
| [2. Your own GPU machines over a tailnet](#2-your-own-gpu-machines-over-a-tailnet) | Machines you own, anywhere | No (they travel inside your private network) |
| [3. Rented GPU, private to you](#3-rented-gpu-private-to-you) | A cloud VM only you use | To your own VM, not to an AI provider |
| [4. Cloud model for everything](#4-cloud-model-for-everything) | A public AI provider | Yes, every prompt |
| [5. Split: local for sensitive work, cloud for the rest](#5-split-local-for-sensitive-work-cloud-for-the-rest) | Both | Only what your rules allow |

In every blueprint the TMach server, its database, and the stored documents
stay on infrastructure you control. What changes is where the text of a prompt
goes when a model is asked something.

The settings named here are all described in
[configuration.md](configuration.md).

## What TMach needs from a model

TMach talks to models over the OpenAI-compatible HTTP API. Anything that
answers `POST /v1/chat/completions` in that format will work: Ollama,
llama.cpp's `llama-server`, vLLM, LM Studio, and most cloud providers either
directly or through their compatibility endpoint. A provider with a different
API needs a small gateway in front of it that translates.

There are three separate model connections, and each can point somewhere
different:

| Used for | Settings |
|---|---|
| Chat, the agent, document tools | `TMACH_MODEL_URL`, `TMACH_MODEL`, `TMACH_MODEL_KEY` |
| Search by meaning, in-product help | `TMACH_EMBED_URL`, `TMACH_EMBED_MODEL`, `TMACH_EMBED_KEY` |
| Voice note transcription | `TMACH_TRANSCRIBE_URL`, `TMACH_TRANSCRIBE_MODEL`, `TMACH_TRANSCRIBE_KEY` |

Remember all three when you decide what may leave. Embedding a document sends
its text to the embedding endpoint, and transcribing a recording sends the
audio.

## 1. One box

**For:** a small team getting started, or any site that must run with no
outside connection.

One machine runs TMach, the database, and the model server.

```sh
export TMACH_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
export TMACH_MODEL=qwen2.5:7b
```

Follow the [container guide](container.md) or the quick start in the README.
Nothing leaves the machine. The team reaches it over the office network, so put
TLS in front of it (`TMACH_TLS`, or a reverse proxy) and set
`TMACH_SECRET_KEY` before storing any credentials.

The limit is the one graphics card. When people start waiting on each other,
move to blueprint 2.

## 2. Your own GPU machines over a tailnet

**For:** a team with more than one GPU machine, or with machines in different
places (the office, a colo rack, someone's workstation at home).

The TMach server sits in one place. Each GPU machine runs a model server and a
small TMach worker. Workers connect out to the server and pull jobs, so the GPU
machines need no open ports. A private Tailscale network joins everything, and
nothing is exposed to the public internet.

Set it up with:

- [Deploying on a tailnet](../deploy-tailnet.md) for the server side.
- [The GPU fleet runbook](gpu-fleet-runbook.md) for the workers, with unit files
  in `deploy/gpu-fleet/`.

Prompts travel between your own machines inside an encrypted private network.
Nothing goes to a third party.

Raise the team's `ai.concurrency` limit when you add workers. It defaults to 2,
so four workers will still run two jobs at a time until you change it.

## 3. Rented GPU, private to you

**For:** a team that needs more GPU than it owns, sometimes or always, but does
not want its data going to a public AI service.

Rent a GPU virtual machine from a cloud provider, install a model server and
the TMach worker on it, and join it to your tailnet. To TMach it is one more
worker, set up exactly as in blueprint 2. You can start it for a large batch
and shut it down afterward.

What is different from blueprint 2: prompts are processed on hardware owned by
the cloud provider. They are not sent to an AI company and are not used by
anyone else, but they do leave your building. Whether that is acceptable is a
question for your own data rules. Use full-disk encryption on the VM and delete
it, not just stop it, when you are done.

If only some work may go to the rented machine, use the labeling rules in
blueprint 5. A worker is treated as "outside this server" by those rules, so
you can keep labeled documents away from it.

## 4. Cloud model for everything

**For:** a team that wants TMach's accounts, permissions, document handling,
and audit trail, has no GPU, and is allowed to send prompts to a provider it
has an agreement with.

Point TMach at the provider:

```sh
export TMACH_MODEL_URL=https://api.example-provider.com/v1/chat/completions
export TMACH_MODEL=their-model-name
export TMACH_MODEL_KEY=...            # keep this out of shell history and unit files
export TMACH_MODEL_CONTEXT=32000      # the provider's context window, in tokens
```

Set `TMACH_MODEL_CONTEXT` to match the model. The default of 4,096 is sized for
a small local model and will make TMach split long documents into far more
pieces than a large model needs.

What leaves: every chat prompt, every agent step, and the text of every
document a tool works on. What stays: the documents themselves, the database,
accounts, the audit log, and search indexes.

Things to do in this layout:

- **Read the provider's data terms.** Find out whether prompts are stored, for
  how long, and whether they are used for training.
- **Watch the spend.** TMach's budgets count requests and tokens per team. Set
  `ai.tokens.total` and `ai.requests` to numbers that match what you are
  willing to pay for.
- **Check the request log.** `GET /api/model-requests` lists every model call
  with the host it went to and whether it left the server. It never stores the
  prompt text.

## 5. Split: local for sensitive work, cloud for the rest

**For:** most teams that want both privacy and a strong model. Sensitive
documents stay on local models. General questions and bulk work on
non-sensitive material can use a cloud model.

This takes four steps.

### Step 1. Keep the default model local

Set `TMACH_MODEL_URL` to your local model, as in blueprint 1 or 2. This is the
model the chat screen and the agent use, and it is what any request gets when
nobody has chosen something else.

### Step 2. Add the cloud model as a named backend

```sh
curl -X POST "$BASE/api/executors" -H "Authorization: Bearer $OP" -d '{
  "name": "cloud-large",
  "mode": "push",
  "url": "https://api.example-provider.com/v1/chat/completions",
  "model": "their-model-name",
  "key": "...",
  "capabilities": {"no_content_logging": true}
}'
```

The key is stored encrypted when `TMACH_SECRET_KEY` is set. Include
`no_content_logging` only if your agreement with the provider says prompts are
not kept. It is your statement about the provider, recorded with every request.
TMach cannot verify it.

To insist on that statement for every outside backend, set
`TMACH_REQUIRE_NO_CONTENT_LOGGING=1`. Requests to an outside backend that has
not declared it are then refused.

### Step 3. Decide who uses the cloud model

- **A single request:** an operator can pass `"executor": "cloud-large"` to
  `POST /api/ai/chat`.
- **A team's bulk work:** `PUT /api/model-roles` with
  `{"roles": {"utility": "cloud-large"}}` sends that team's field extraction,
  knowledge-graph building, and translation drafts to the cloud model. Only do
  this for a team whose documents are allowed to go there. Leave the role unset
  for teams with sensitive documents and their bulk work stays local.

### Step 4. Label sensitive documents and write the rule

Give your team a document field named `sensitivity` and choose its values, for
example `public`, `internal`, and `confidential`. Then tell TMach where each
label may go:

```sh
curl -X PUT "$BASE/api/executor-policy" -H "Authorization: Bearer $OP" -d '{
  "labels": {
    "public":       {"executors": ["cloud-large"], "default_model": true},
    "internal":     {"executors": [], "default_model": true, "allow_redacted": true},
    "confidential": {"executors": [], "default_model": true, "allow_redacted": false}
  }}'
```

Read that as:

- `public` documents may go to the cloud model or the local one.
- `internal` documents go to the local model. They may go to the cloud model
  only after names, emails, phone numbers, and ID numbers have been replaced
  with placeholders (the `redact` option on the document tools).
- `confidential` documents go to the local model only, redacted or not.

A request that breaks the rule is refused before anything is sent, and the
refusal is written to the team's audit log.

Once a rule exists, a document with a label the rule does not mention is
refused everywhere, so list every label you use. A document with no label at
all is not restricted.

### What the rule does not cover

Know these limits before you rely on it:

- **Typed prompts.** The rule applies to documents. If someone pastes text into
  a chat that an operator has routed to the cloud model, the rule has no label
  to check. Keeping the default model local (step 1) is what protects ordinary
  chat.
- **Unlabeled documents.** They are not restricted. If most of your documents
  are sensitive, make labeling part of intake, or do not give those teams a
  cloud route at all.
- **Local addresses.** A model on the same machine as the server is always
  allowed. A model elsewhere on your tailnet counts as outside the server, so
  name it in the rule if labeled documents should reach it.
- **Embeddings and transcription.** These use their own endpoints (see the
  table at the top). Keep them local if document text and recordings must not
  leave.

## What leaves, by blueprint

| | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Stored documents and database | stay | stay | stay | stay | stay |
| Accounts, permissions, audit log | stay | stay | stay | stay | stay |
| Chat prompts | stay | stay | to your VM | to provider | stay (local default) |
| Text of documents being processed | stay | stay | to your VM | to provider | only as the rule allows |
| Paying per token | no | no | no (per hour) | yes | for cloud work only |

## Before you go live, in any blueprint

- Set `TMACH_SECRET_KEY`, and keep a copy of it somewhere other than the
  server. See the [secrets runbook](secrets-at-rest-runbook.md).
- Put TLS in front of the server if anyone reaches it from another machine.
- Set team budgets. The defaults are small on purpose.
- Back up the data directory or the PostgreSQL database.
- Open `GET /api/model-requests` after a day of use and confirm every backend
  host listed is one you expected.

## How far these have been tested

Blueprints 1 and 2 describe setups this project runs itself. The cloud
settings in blueprints 4 and 5 use the same code path as a local model and are
tested against local OpenAI-compatible servers. They have not been tested
against each commercial provider, so try a few requests and check the request
log before you depend on one.
