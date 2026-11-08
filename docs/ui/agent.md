# Agent

The same shape as [Chat](chat.md) — one prompt, **Send**, the transcript
below — with one difference that is the whole point: **the model is given the
platform's own tools and may act on your data.** Asking it to create a note
creates a note.

The prompt box ships with a worked example, which is the clearest statement of
what this screen is for: *create a private note titled "Q3 goals"…, then list
my notes.*

## What it can reach

The transcript shows each tool the model called and what came back. The tools
on offer are the ones your team has enabled and that fit the model's input
budget — `docs/reference/tools.md` lists every one with its schema and the
permission it needs, and marks which are offered to the agent at all.

Two things to know about that set:

- **Not every tool is offered here.** A tool whose required arguments are
  structures nobody utters in conversation — a JSON schema, a label set, a
  template and its data — is a *workflow* tool. It is registered, documented
  and callable from a [workflow](workflows.md) step, and it is kept out of the
  agent's list so that it cannot crowd out the tools the agent is actually
  instructed to use.
- **A tool runs as you.** Every read and write it makes is checked against your
  own permissions, so the agent can never reach a document you could not open
  yourself.

## What it costs

An agent run is far more expensive than a chat turn — a tool-using run spends
thousands of tokens where a single reply spends tens, because each step sends
the transcript again. It is metered on the provider's real token count, so a
busy run can exhaust a team's daily `ai.tokens.total` on its own; raise it in
[Usage](usage.md) before a long session. `steps used` on a completed run says
how many turns it took.

A worker in a pull fleet **cannot** run the agent: that wire carries a reply,
not tool calls. Asking for it by name is refused rather than quietly answered
by the local model.

Agent can be turned off for the instance, a company or a team.
