# Workflows

Four cards: **Definitions**, the run form, **Automations**, and **Runs**.

A workflow is a validated spec — a list of steps, each one a tool call, a
branch, a fan-out over a list, or a pause for a person. `docs/reference/workflows.md`
lists the shipped ones step by step, and
`docs/design/workflow-engine.md` is the design.

## Definitions

Every workflow published for this team: its name and slug, its version, its
**Source**, and how many steps it has.

**Source** is where it came from — a plugin that ships it, or the API. A
plugin's workflows appear here the first time anybody looks at this tab, which
is why a brand-new team sees `No workflows are published for this team yet.`
with the remedy on the same line: a plugin that ships one appears here on first
use; otherwise post a spec to `/api/workflows`.

A plugin may ship a **newer version** of a workflow it already shipped. The
highest version is what runs; the old row survives, because a run that recorded
which version it used must not become a lie.

**Run** opens the run form for that workflow.

## The run form

One field per declared input. **Every declared input is required by the
engine** — leave a box blank and it means "skip" only where the workflow says
an empty value is acceptable. The field order is not meaningful: it comes from
the spec and is not a sequence.

Starting a workflow from a document — **Run workflow…** on the
[Repository](repository.md) detail panel — prefills the document's id, which is
the ordinary way in.

## Runs

Every run: a short id, the workflow, a status badge, `N steps used`, when it
started, and **View**.

Statuses are `queued`, `running`, `waiting`, `done`, `error` and `canceled`.
`waiting` means the run has stopped on a [review](review.md) and is waiting for
a person — it holds no concurrency slot while it waits, however long that is.

**View** shows the run's **Input**, its **Steps** with each step's own status,
input and output, and the final **Output**. It refreshes itself while the run
is live and stops when it settles. **Cancel** stops a live run.

A step that failed carries its reason. A run whose steps are all queued with
nothing running is usually a budget: [Usage](usage.md) and the
[Jobs](jobs.md) screen both say so.

## Automations

`When a document matching a prefix and type lands in the repository — from the
console or over S3 — run this workflow with it, as the uploader.`

A trigger is:

- **Workflow** — which one to run.
- **Key prefix** — the path it watches.
- **Content types (blank = any)**.
- **Attributes** — equality on the document's own metadata, at most ten keys.
  This is how a trigger watches `doc_type` rather than a path: at upload the
  condition is simply false, and the trigger fires later, when something
  classifies the document.
- **Workflow input (JSON)** — prefilled with an example. The arrival's own
  fields win over anything here that clashes.
- **also on derived documents** — off by default. On, it fires on *other*
  pipelines' outputs; never on its own, in either case.

Each trigger shows `enabled` / `disabled`, **Enable**/**Disable**,
**History** and **Delete**. **History** lists every fire, with its error if it
could not start. A fire that cannot start leaves the error on its own record and
never fails the upload.

**It fires exactly once per version.** Re-uploading the same path is a new
version and fires again; a workflow that writes back to the document that
started it does not loop, because that version's fire is already recorded.

**A trigger is not a backfill.** Creating one does not fire it on the documents
that already match — the honest reading of a fire is "this document *became* an
invoice", not "this document is one". A backfill is a workflow you run
yourself.

The card carries the team's **AI budget** — `N tokens left today` — because a
queue of runs under a trigger is a team out of tokens, not a broken trigger.

Workflows can be turned off for the instance, a company or a team.
