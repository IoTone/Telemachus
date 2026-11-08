# Usage

What this team has spent, what its limits are, and which tools it has switched
on.

## The table

A row per **Dimension**, with **Limit**, used, remaining and **Resets**.

The dimensions that stall work:

| Dimension | What it counts |
|---|---|
| `ai.tokens.total` | provider tokens on chat and agent completions |
| `ai.requests` | calls to a model, and scheduler jobs |
| `ai.concurrency` | jobs this team may run at once |
| `ai.embeddings.total` | vectors asked for |
| `ai.help.total` | questions to [Docs](asking-the-documentation.md) |
| `ai.judgments.total` | typed judgments |
| `ai.transcriptions.total` | recordings transcribed |
| `storage.bytes` | bytes stored, as a running total |
| `feed.fetches` / `research.fetches` | outbound fetches |
| `mail.notifications` | messages queued to a mailbox |

**Set limit** writes one, with a window of a minute, a day or a total. A team
owner may set the team's own limits, and so may a company admin; a team admin
deliberately may not.

**Resets** says when the window ends. A minute window and a `total` have no
reset instant and say nothing rather than guessing.

**`no limit set` reports `0` used.** The ledger only counts against a limit, so
a dimension with no limit shows nothing spent — that is not a claim that
nothing was spent.

**A limit here cannot widen what the company allows.** The company's decision
is taken first and may refuse; raising a team limit above it changes nothing.

## Work is paused by a budget

When something is held, a card appears at the top saying which allowance ran
out, how much of it was used, and:

> Queued jobs wait — they have not failed — and start again when the window
> resets.

It also says who can raise it: you, if you hold the permission, or an operator.
A **company's** allowance is not the team operator's to raise, and the card does
not promise otherwise.

**This is the screen to come to when the [Jobs](jobs.md) queue has stopped
moving.** The shipped daily allowances are small — a few thousand tokens and a
couple of hundred requests — and one agent run, one bulk translation draft or
one fan-out over a dozen documents will reach them. The symptom is always the
same: jobs `queued`, nothing `running`, no error anywhere.

Because `mail.notifications` deliberately does **not** hold the queue, this
figure is the only place a team learns it has stopped sending notifications.

## Tools

Every registered tool, and whether this team has it switched on. Switching one
off takes it away from the [Agent](agent.md) and from any workflow step that
calls it.
