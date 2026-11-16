# TMach

[![CI](https://github.com/IoTone/Telemachus/actions/workflows/ci.yml/badge.svg)](https://github.com/IoTone/Telemachus/actions/workflows/ci.yml)
[![Nightly tour](https://github.com/IoTone/Telemachus/actions/workflows/nightly.yml/badge.svg)](https://github.com/IoTone/Telemachus/actions/workflows/nightly.yml)

**English** · [日本語](README.ja.md)

**Private AI for your workgroup, running on hardware you own.**

TMach is a self-hosted AI workspace for teams. You install it on your own
server, point it at a local model, and your group gets chat, an agent that can
use tools, document processing, translation, search, and workflows, all behind
real accounts and permissions. Your prompts and documents stay on your machines.
It works with no internet connection at all.

Two things follow from that design:

- **No data leaves through a public cloud or a public AI service unless you
  decide it should.** With a local model, nothing your team types or uploads is
  sent to a third party. If you also want a cloud model, you can connect one and
  set rules for which documents may be sent to it.
- **The cost of owning the stack stays low.** TMach is open source under the
  MIT license, a short, well-understood academic license. There are no
  per-seat fees, no usage fees, and no paid edition. You pay for the hardware
  you choose to run it on.

## Why it exists

Most AI tools make you pick one of two things.

Hosted assistants are easy to start with and the models are excellent, but
everything your team types and uploads goes to somebody else's servers. For a lot
of work (client files, contracts, medical or financial records, unreleased
designs) that is not an option, or it takes a legal review to find out.

Local tools keep the data at home, but most are built for one person at one
computer. Once five people share the same machine, you need accounts, a way to
decide who can see which documents, a way to stop one person's batch job from
starving everyone else, and a record of who did what.

TMach is built for that second situation: a group of people sharing private AI
on shared hardware.

## Who it is for

- **Small and mid-sized teams with sensitive documents.** Engineering firms, law
  offices, clinics, labs, consultancies, finance teams. Anyone whose work product
  should not leave the building.
- **The person who runs the server.** One operator can install it, add people,
  set spending limits, watch the job queue, and see what is healthy from one
  screen.
- **Integrators and consultancies** who build AI products for clients and want a
  platform they can rebrand, extend, and install on the client's own hardware.
- **Teams that work in more than one language.** The whole interface ships in
  English and Japanese, and translation is a built-in app, not an add-on.

It is probably not for you if you are one person who wants a chat window (Ollama
with any desktop chat app is simpler), or if you want a hosted service that
somebody else operates.

## What you get on day one

- **Chat and an agent** that stream answers from your local model and can call
  tools: create notes, search documents, look things up in the knowledge graph.
- **A document repository** that takes any file format, with private, team, and
  shared visibility, version history, sharing with expiry dates, and a record of
  who read what. It also speaks the S3 protocol, so `aws s3 cp` and `rclone`
  work against it.
- **Document processing.** Upload a file and have it classified, have fields
  pulled out against a schema, a form or PDF filled in, and the result
  translated. A person can be placed in the middle to approve or correct the
  result before it moves on. Scans and photos are read with OCR.
- **Search** by keyword and by meaning across notes and documents, always
  limited to what the person searching is allowed to see.
- **Translation** with a team glossary, so agreed terms are used every time,
  including for long documents.
- **Notes** in Markdown or Org format, with tags, links between notes, and a
  graph view.
- **A knowledge graph** built from your documents, where every fact points back
  to the document and version it came from.
- **Research bookmarks** that save a copy of a web page so you still have it
  after the original changes or disappears.
- **Voice notes**, transcribed and made searchable.
- **Workflows and schedules.** Chain steps together, run them when a document
  arrives or at a set time, and see every run.
- **Feeds** that pull in GitHub issues, security advisories, uptime alerts, and
  chat messages and turn them into a work queue.
- **Help built in.** Ask a question in the console and get an answer drawn from
  the product documentation, with the source pages listed.

## What you can build on it

TMach is also a platform. The built-in apps use the same extension points that
are open to you.

- **An intake desk for paperwork.** Invoices, inspection reports, or application
  forms arrive by upload or S3, get sorted by type, have their fields extracted,
  go to a reviewer when the model is unsure, and come out as filled forms and
  structured data.
- **A private research assistant** over your own files and saved web pages that
  answers with citations.
- **A bilingual document service** that translates incoming documents with your
  own terminology and keeps both versions side by side.
- **An operations queue** that collects alerts and issues from several systems
  and drafts a proposed response for a person to approve.
- **Your own product.** Add tools, API routes, screens, background jobs, and
  database tables as a plugin. Change the name, logo, and colors. Put a public
  sign-up page in front of it. The
  [integrator's guide](docs/integrators-guide.md) walks through all of it with a
  working example.
- **A shared GPU pool.** Machines with graphics cards connect as workers and
  pull jobs from the queue. Add a machine and the team gets more capacity. See
  the [GPU fleet runbook](docs/ops/gpu-fleet-runbook.md).

## What makes it a team system

- **Roles and permissions on everything.** Owner, admin, member, and viewer
  roles; private, team, and shared visibility on every note and document; API
  tokens limited to the permissions you choose.
- **Budgets.** Daily limits on AI requests, tokens, storage, and more, set per
  team. When a team reaches its limit, its jobs wait and the screen says why.
- **A queue in front of the model.** AI work is scheduled, so a burst of
  requests or a runaway agent cannot overload the server. Jobs can be cancelled
  and have a time limit.
- **A record of what happened.** Sign-ins, document reads, sharing, and admin
  actions are logged. The log is chained so tampering can be detected, and it
  can be exported.
- **Controls for sensitive data.** Encryption at rest for stored secrets and,
  optionally, extracted document text. Names, emails, and ID numbers can be
  removed from text before it goes to a model. Documents can be labeled so they
  are only ever sent to the models you approve.
- **Several companies on one install.** An optional mode keeps each company's
  teams, data, branding, and budgets separate.
- **Sign-in protections.** Two-factor authentication, session timeouts, rate
  limits on sign-in attempts, email invitations, and password reset.

## Deployment blueprints

TMach comes with [deployment blueprints](docs/ops/deployment-blueprints.md):
step-by-step layouts that say what you need, how to set it up, and exactly what
data leaves your network in each one. More are on the way.

- **On local infrastructure.** One server in your office or data center, with
  the model on the same machine. Nothing leaves it.
- **Across a tailnet.** The server in one place and GPU machines in others,
  joined by a private Tailscale network so nothing is exposed to the public
  internet.
- **Hybrid.** Your own hardware plus a rented GPU or a cloud model. TMach works
  with any OpenAI-compatible endpoint, and you can label documents so that
  sensitive ones only ever go to your local models while everything else can
  use the larger one.

In every layout the server, the database, and the stored documents stay on
infrastructure you control.

## How it compares

These are good tools and several of them are a better choice for some teams.
They also change quickly, so check their current documentation before you
decide.

| | Best at | How TMach differs |
|---|---|---|
| **Hosted team plans** (ChatGPT, Claude, Copilot, Gemini) | The strongest models, no setup, polished apps | Your data stays on your own hardware and it works offline. The trade is that local models are less capable than the largest hosted ones and you run the server yourself. |
| **Self-hosted chat front ends** (Open WebUI, LibreChat) | A fast, polished chat experience over local or hosted models, with large communities | TMach puts more weight on what happens around the chat: document processing, review steps, budgets, a job queue, and an audit trail. Its chat screen is plainer. |
| **Document chat workspaces** (AnythingLLM, PrivateGPT) | Getting from a folder of files to "ask questions about them" quickly | TMach adds per-document permissions, sharing, retention rules, structured extraction, and workflows that act on documents, not only answer questions about them. |
| **Workflow builders** (Dify, n8n, Flowise) | Drag-and-drop flow design and a wide catalog of connectors | TMach workflows are written as data or code, not drawn. They run inside the same permission, budget, and audit system as everything else. It has far fewer connectors. |
| **Building it yourself** (a model server plus scripts) | Total control | TMach gives you the accounts, permissions, queue, storage, and admin screens so you can start with the part that is specific to your work. |

A few things are true of TMach that are worth checking for any alternative:

- **MIT license for everything.** A permissive academic license that legal
  teams already know. No enterprise edition, no features held back, no terms
  that change with company size or branding.
- **Runs with no outside services.** One server process, a database file, and a
  model. PostgreSQL and S3 storage are options for when you outgrow that.
- **Few moving parts.** The server is written in Racket with a small, pinned set
  of dependencies, built the same way every time with Nix.

And some things to know before you commit:

- **It is pre-1.0.** It runs real workloads and has a large test suite, but APIs
  can still change between releases.
- **Local models have limits.** A 7B model on one graphics card will not match a
  frontier hosted model. TMach can call any OpenAI-compatible endpoint, so you
  can add a bigger cloud model for the work your privacy rules allow. See the
  hybrid blueprint.
- **The implementation language is uncommon.** You do not need to know Racket to
  run it or to call its API. You do to write an in-process plugin, though
  plugins can also run as separate programs in any language.
- **Multi-company mode has no admin screens yet.** It is managed over the API.
- **The Japanese edition is machine-assisted** and is being reviewed by a native
  speaker.

## Try it

You need [Nix](https://nixos.org/download) and a local model server such as
[Ollama](https://ollama.com).

```sh
git clone https://github.com/IoTone/Telemachus && cd Telemachus
ollama pull qwen2.5:7b

nix develop
cd refimpl/racketmaximus
raco make server/main.rkt

export DATABASE_URL="sqlite:///$PWD/data/telemachus.db"
export TMACH_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions
export TMACH_MODEL=qwen2.5:7b
racket server/main.rkt
```

Open <http://127.0.0.1:8835>, create the first operator account, and start a
chat. Without `TMACH_MODEL_URL` the server still starts, but chat replies are a
labeled placeholder, not real model output.

To run it in a container with PostgreSQL, see
[docs/ops/container.md](docs/ops/container.md). Every setting is listed in
[docs/ops/configuration.md](docs/ops/configuration.md).

## Documentation

- [Using the console](docs/ui/README.md), screen by screen.
- [The integrator's guide](docs/integrators-guide.md) for building on TMach.
- [API, tools, permissions, and workflow reference](docs/reference/README.md),
  generated from the source, including an
  [OpenAPI description](docs/reference/openapi.json).
- [Deployment blueprints](docs/ops/deployment-blueprints.md) for local, tailnet,
  and hybrid setups.
- [Operator runbooks](docs/ops/) for configuration, containers, GPU workers,
  secrets, multi-company mode, and releases.
- [The developer book](docs/book/), a guided tour of how the system is built.
- [Design documents](docs/design/) and the decision log behind them.

## Feature tour

<!-- BEGIN FEATURE-TOUR -->

<!-- Generated by refimpl/racketmaximus/test/e2e/refresh-screenshots.sh — do not edit by hand. -->

Every screenshot below is produced by the Playwright tours in
[`refimpl/racketmaximus/test/e2e/`](refimpl/racketmaximus/test/e2e/), which drive a real
server on a throwaway database — nothing here is a mockup. CI runs those same tours on
every push, so the flows stay exercised; the images committed here are refreshed by
re-running the script noted below.

### Sign in

![Sign in](docs/screenshots/01-signin.png)

The reference UI on first load — password + optional 2FA, an EN / 日本語 toggle, and a first-run path to create the initial operator.

### First-run bootstrap

![First-run bootstrap](docs/screenshots/02-bootstrap.png)

Creating the first operator. Under RBAC-5 the first owner bootstraps as the instance operator — a distinct tier above team owners.

### Streaming chat

![Streaming chat](docs/screenshots/03-chat.png)

A token-streamed reply from the local model (qwen2.5:7b), admitted through the per-team concurrency governor and metered against AI quotas.

### Agentic tool use

![Agentic tool use](docs/screenshots/04-agent.png)

The agent plans, calls the create_note tool (🔧), receives the result, and answers — the same registry that also serves plugins, MCP, and sandboxed tools.

### Notes

![Notes](docs/screenshots/05-notes.png)

The ownable/shareable resource behind RBAC — team / private / shared visibility. The "Investor demo" note here was created by the agent in the previous step.

### Translation app

![Translation app](docs/screenshots/06-translate.png)

The first user-facing app: live EN→JA translation with a team glossary for consistent terminology and a metered history. The same engine translates whole locale catalogs (the localization dogfood).

### Teams & RBAC

![Teams & RBAC](docs/screenshots/07-team.png)

Members and roles (owner / admin / member / viewer). Every API call is authorized through the AuthzService; tokens are capped by issuer-permissions ∩ scopes.

### Quotas & tool registry

![Quotas & tool registry](docs/screenshots/08-usage.png)

Windowed usage vs. limits, and every agent tool with a source badge: built-in, 🔌 plugin, mcp:mock (external MCP server), and 🛡️ oop:notes-helper (sandboxed out-of-process, with declared scopes).

### Admin & the worker fleet

![Admin & the worker fleet](docs/screenshots/09-admin.png)

Operator-only instance view. The Workers table lists the local node (qwen2.5:7b), federated executors (↗ gpu-sim) and any pull worker — each with its derived health, what the worker itself reports, what it is holding, and a reversible Drain. Below it the Queue: every job across every team with how long it has waited, and the two separate reasons one is not running — the platform is holding it, or no live worker can run it at all.

### Localized top to bottom

![Localized top to bottom](docs/screenshots/10-i18n.png)

One toggle re-renders the entire UI in Japanese (ICU MessageFormat catalogs, fallback chain, source-hash staleness) — localization is a core piece, not an afterthought.


### Beta onboarding funnel

A pre-sales lead funnel that a deployer skins and owns — three render tiers, all through
one anti-abuse gate. See [docs/design/beta-onboarding-experience.md](docs/design/beta-onboarding-experience.md).

<details>
<summary><b>10 more screenshots — the public funnel, the LLM judge, and all three render tiers</b></summary>

#### The funnel is the default experience

![The funnel is the default experience](docs/screenshots/beta/01-funnel-landing.png)

With home routing set to beta (TMACH_HOME=beta), the root route serves the public beta landing — not a login screen. The form is rendered from a pluggable onboarding provider whose copy, fields, and judge prompt are customizable via the SDK.

#### Setup: create the operator

![Setup: create the operator](docs/screenshots/beta/02-first-run.png)

Staff reach the team behind the funnel via "Team sign-in". On a fresh instance the first run bootstraps the operator/owner (RBAC-5) — the person who will vet inbound prospects — and creates the internal team that owns the pipeline.

#### Setup: the review inbox

![Setup: the review inbox](docs/screenshots/beta/03-review-empty.png)

The owner-only Beta tab is where prospects arrive. Empty to start — no signups yet.

#### The funnel: a prospect requests access

![The funnel: a prospect requests access](docs/screenshots/beta/04-funnel-filled.png)

A qualification submission — role, company, address, and phone give the LLM judge real B2B signal to weigh. Captured as a prospect, never as a user account: no password, no login, pre-sales vetting only.

#### Submitted — after invisible anti-abuse

![Submitted — after invisible anti-abuse](docs/screenshots/beta/05-funnel-submitted.png)

On submit the browser transparently solves a proof-of-work and passes the anti-abuse gate (rate limit, signed single-use challenge, honeypot, min fill-time, velocity caps). The prospect just sees a thank-you.

#### Review: prospects + the LLM judge

![Review: prospects + the LLM judge](docs/screenshots/beta/06-owner-review.png)

The Beta tab lists each prospect with the LLM judge’s verdict (valid? · score/100 · revenue estimate · reasoning) and a count of blocked abusive attempts. The judge ran async through the metered job queue.

#### Qualify or reject — vetting only

![Qualify or reject — vetting only](docs/screenshots/beta/07-qualified.png)

The owner qualifies (or rejects) each prospect. This vets beta candidates for the internal team; it never provisions a customer account.

#### Skin it: the console onboarding editor

![Skin it: the console onboarding editor](docs/screenshots/beta/08-onboarding-editor.png)

The owner brands the funnel from the Beta tab — logo, hero copy, theme tokens, detail blocks, form fields, and the judge prompt — with a live preview that is exactly what applicants see. Save draft, then Publish. No code, no redeploy; the same Tier-A shell, reskinned entirely from config.

#### Tier C: author a custom HTML template

![Tier C: author a custom HTML template](docs/screenshots/beta/09-tier-c-template.png)

Between no-code (Tier A) and shipping a bundle (Tier B): the owner writes raw HTML with {{placeholders}} right in the console, with a live sandboxed preview. On publish the markup is sanitized (scripts, handlers and dangerous tags stripped) and rendered in an isolated iframe; the submit button is wired to the anti-abuse gate for you.

#### Tier B: a fully custom plugin bundle

![Tier B: a fully custom plugin bundle](docs/screenshots/beta/10-tier-b-bundle.png)

For teams that want total control, a plugin ships its own frontend bundle — its own markup, type, and layout, with zero TMach chrome. It loads /beta-sdk.js and calls Telemachus.beta.submit(), so it still routes through the same anti-abuse gate (proof-of-work, signed challenge, honeypot, velocity) without re-implementing any of it.

</details>

<!-- END FEATURE-TOUR -->

> **Not pictured: multi-tenancy.** Several companies on one instance (an org above
> the team, a superadmin tier above the org admin) ships behind
> `TMACH_MULTITENANT` and is currently **API-only** — there is no console UI
> for it yet, so it cannot appear in a screenshot tour. It is validated instead by
> `refimpl/racketmaximus/test/multitenant-demo.sh`, which seeds two complete
> companies and asserts cross-org isolation over HTTP. See
> [docs/design/multi-tenancy.md](docs/design/multi-tenancy.md).

To regenerate this section — screenshots and captions both — run
`bash refimpl/racketmaximus/test/e2e/refresh-screenshots.sh`.

## The name

The project began as **Telemachus**, the son of Odysseus, who set out to find
his father with Athena beside him disguised as Mentor. **TMach** is the short
form used for the product and its documentation. The longer name is still the
name of the repository, the command-line tools, and the code modules.

TMach follows an earlier self-hosted AI workspace called Odysseus. It reuses
ideas from that project but none of its third-party code. Everything here was
written for this project and is released under the MIT license.

## How the project is run

- **Open source with nothing held back.** Every feature is in this repository
  under the same license. There is no plan for a paid tier.
- **The API is the product.** The HTTP API, the plugin contract, the security
  model, and the worker protocol are documented and meant to outlive any one
  implementation. The current implementation lives in `refimpl/racketmaximus/`,
  and another could sit beside it.
- **Every feature can be managed and switched off** by an operator, per
  instance, per company, or per team.
- **Documentation ships with the code.** The reference is generated from the
  source, and the build fails if the two disagree.
- **SQLite to start, PostgreSQL when you need it.** Both are tested on every
  change.

## Repository layout

- `docs/` holds the guides, runbooks, generated reference, design documents,
  and the book.
- `refimpl/racketmaximus/` is the server, console, plugins, and tests. It has
  its own README.
- `deploy/` and `compose.yaml` hold example deployment files.
- `refimpl/racketmaximus/VERSION` is the current version number.

## License

[MIT](LICENSE) © 2026 IoTone, Inc.
