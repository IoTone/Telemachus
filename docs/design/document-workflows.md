# Document workflows: uploads that trigger processing

*Proposal for review. This is the first-user scenario the platform is for: **a team
uploads files, and a workflow processes them** — extracts the data, runs inference
over it, generates filled forms, translates the result. Data shapes and contracts
are concrete enough to build from; the policy forks are under **Decisions to
confirm**. Sharing of what the pipeline produces is in
[document-sharing.md](document-sharing.md).*

## What exists, and the one thing missing

| Need | Have |
|---|---|
| Upload any format, versioned, permissioned, S3-compatible | the **repository** (slices 49–55) |
| Text out of a PDF / DOCX / HTML / MD | `repo_extract_text` → `repo_text` (slice 54) |
| A validated, durable, quota-admitted multi-step runner with `map` fan-out | the **workflow engine** (slice 46) |
| Structured LLM output that is validated and refused on bad shape | the pattern from the Localization Manager's drafting guard |
| Translation with a team glossary | `translate!` (`domain/apps/translate.rkt`) |
| A run that starts from a document | `POST /api/workflows/<slug>/run {input: {object_id, version_id}}` — the spec already has typed `input` |

The missing thing is small and precise: **nothing runs a workflow because a
document arrived.** Runs start when a person posts one. And there are three
places a document arrives — the console upload, the documents shim, and the S3
`PUT` — with no shared seam after the write.

Everything else in this design is composition.

## The seam: inside `repo-put!`, after the version is committed

Triggers are evaluated in exactly one place: at the end of `repo-put!`, once the
new version row exists. That covers all three entry points by construction —
including S3, which is how a team uploads files at any scale (DWF‑1). The
alternative, hooking each endpoint, is the same bug as the three copies of the
periwinkle palette: it drifts.

A match **enqueues** a run. It never executes inline: the upload returns as fast
as it does today, and the run is a scheduler job, so it inherits quota admission,
cancellation, the org gate and durability across a restart. A team that uploads
five hundred scans gets five hundred queued runs and the governor's concurrency
cap, not a five-hundred-way fan-out against the local model.

## Triggers

A trigger is a team-scoped subscription: *when a document matching this lands,
run that workflow with it.*

```
doc_triggers(id pk, team_id, workflow_slug, enabled bool,
             match_prefix text,           -- key prefix, e.g. "inbox/invoices/"
             match_types text,            -- comma-separated content types, "" = any
             input jsonb,                 -- extra input merged into the run, e.g. a schema ref
             fire_on_derived bool default false,
             created_by, created_at)

doc_trigger_fires(trigger_id, version_id, run_id, fired_at,  -- exactly-once per version
                  pk(trigger_id, version_id))
```

- **Fires once per version.** `doc_trigger_fires` is the idempotency key: a
  re-upload of the same bytes to the same key is a new version and fires again; a
  retried request for the same version does not.
- **Derived documents do not re-trigger** unless the trigger opts in. Without
  this a pipeline that writes `…/extracted.json` back into `inbox/` runs itself
  forever (DWF‑3).
- **The run executes as the uploader.** Its principal is whoever `repo-put!` ran
  as — a person in the console, or the S3 key's user with the key's scopes. So a
  run can only read what its uploader could read, and its outputs are owned by
  someone real. A trigger whose creator has broader rights than the uploader does
  not lend them (DWF‑2).
- Creating a trigger needs `workflows:write` on the team; the picked workflow
  must already be published there.

The run's input is the engine's typed `input` block:

```
{ "object_id": "…", "version_id": "…", "key": "inbox/invoices/2026-09-acme.pdf",
  "content_type": "application/pdf", ...trigger.input }
```

## The step tools

Four `define-tool`s. Being tools, they are also available to the agent and to any
hand-written workflow; the pipeline below is just the shipped composition.

**`doc_text`** — already exists as `repo_extract_text`; returns the extracted text
of `(object_id, version_id)`. Kept as the first step so a pipeline never depends
on the search index having run.

**`doc_extract_fields`** — text + a **JSON schema** → an object that validates
against it. The model is asked for JSON; the reply is parsed, validated, and
**refused on mismatch** — a missing required field, a string where a number was
asked for, an invented key. This is the Localization Manager's lesson applied to
data: an extraction that looks finished and is wrong is worse than a failed step
(DWF‑5). Output is written as a derived document, `<key>.extracted.json`.

**`doc_render`** — a template document from the repository plus data → a new
document. v1 renders **Markdown and HTML** templates with `{{field}}`
substitution and a `{{#each}}` for line items; **DOCX** via a template whose
paragraphs carry the same placeholders (the repository already unzips DOCX to
extract text; writing one back is the same `file/unzip` in reverse). **PDF is
deferred**: every PDF renderer is a dependency the deterministic-deps tenet would
have to be argued past, and a DOCX or HTML form is what a person edits anyway
(DWF‑6).

**`doc_translate`** — wraps `translate!`: a document's text (or a rendered form)
into a target locale, glossary applied, written as `<key>.<locale>.<ext>`. Fanned
out with `map` over a list of locales.

Every output goes through **`inherit`** ([document-sharing.md](document-sharing.md)):
it takes the source's visibility and live grants at creation, is owned by the
run's principal, and gets a `repo_derivations` row naming the source version, the
run and the step. That row is what makes "where did this come from" a click, and
what lets a trigger tell a derived document from an original.

## The reference pipeline

Shipped as a plugin, `doc-pipeline`, in the pattern of `doc-indexer`:

```racket
(define-workflow process-upload
  #:name "Process an uploaded document"
  #:description "Extract text, pull structured fields against a schema, fill a form
                 template, and translate the result into the team's languages."
  (step text      (tool doc_text #:object (input object_id) #:version (input version_id)))
  (step fields    (tool doc_extract_fields #:text (out text result)
                                           #:schema (input schema)))
  (step form      (tool doc_render #:template (input template)
                                   #:data (out fields result)))
  (step translate (map #:over (input locales)
                       (tool doc_translate #:object (out form object_id) #:locale (item)))
        #:end))
```

`schema`, `template` and `locales` come from the trigger's `input` block, so the
same workflow serves invoices and intake forms with different configuration and no
new code. Each step is optional in the obvious way: a trigger with no `template`
gets fields and translations of the source; one with no `locales` gets a form and
stops.

The first-user proof, end to end: upload an invoice PDF to `inbox/invoices/` →
`extracted.json` with the vendor, date, line items and total → a filled purchase
approval form as DOCX → the form in Japanese, Dutch and Spanish — all four sitting
beside the original in the repository, each with a provenance link, each shared
exactly as the original was.

## Running one by hand

A **"Run workflow…"** action on any document runs the same pipeline for one object
through the same `run` endpoint. It is how a pipeline is tested before a trigger
automates it, and it is the same code path, so what worked by hand works on
upload (DWF‑7). A per-document **"Processed by"** panel lists the runs and the
derived documents, with status.

## Failure, retry, re-run

A failing step fails the run, as the engine already does. Outputs already written
stay — they are documents, and a partially processed invoice with its extracted
fields is worth more than nothing. Re-running on the same version writes new
versions of the derived documents (the repository versions by key), so a fixed
template or a better model supersedes rather than duplicates. An unreadable
document records nothing and never wedges the trigger — the indexing rule, kept.

AI steps meter `ai.tokens.total` through the ordinary quota, and the same
over-budget stall the Localization Manager hit applies: a queue that stops is a
team out of budget, not a hang. The trigger list shows the team's remaining budget
for that reason.

## Data shapes (backend-neutral)

`doc_triggers` and `doc_trigger_fires` above; `repo_derivations` from the sharing
design. Nothing else. Runs, steps, jobs, quota and audit are the existing tables.

## Contract (any backend implements)

```
DocumentPipeline:
  on_put(object, version, principal) -> [run_id…]       # the seam; enqueue only
  triggers(team) / trigger_create / trigger_update / trigger_delete
  fired(trigger, version) -> bool                        # exactly-once
  run_on(principal, object, workflow_slug, input) -> run_id     # the manual path
  derivations(object) -> [{object, version, run, step}]

Tools:
  doc_text(object, version) -> text
  doc_extract_fields(text, schema) -> object | refused
  doc_render(template_object, data) -> object_id
  doc_translate(object, locale) -> object_id
```

## Bootstrapping plan

1. `repo_derivations` + `inherit`; `doc_extract_fields` with schema validation and
   the refuse-on-mismatch tests, run against the deterministic fallback model AND
   a live one, as the Manager's drafting was.
2. `doc_render` for Markdown/HTML; `doc_translate`; the `doc-pipeline` plugin with
   `process-upload`; **"Run workflow…"** on a document. Smoke: upload → run by hand
   → four derived documents with provenance.
3. Triggers: the tables, the seam in `repo-put!`, exactly-once, the derived-document
   guard. Smoke: an S3 `PUT` fires the run — the path a team will actually use.
4. The Automations card and the "Processed by" panel; the e2e gate gains the
   invoice scenario end to end.
5. DOCX rendering. PDF stays deferred until someone needs a PDF that is not a
   printed DOCX.

## Decisions to confirm

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DWF‑1** | Where triggers fire | **Inside `repo-put!`, after the version commits** · vs per-endpoint hooks | One seam covers console, shim and S3; three hooks drift. |
| **DWF‑2** | Whose principal a triggered run uses | **The uploader's** · vs the trigger creator's · vs a service account | A run can only read what its uploader could; outputs are owned by someone real. |
| **DWF‑3** | Re-firing | **Exactly once per version; derived documents do not re-trigger unless opted in** · vs fire on every write | Without both, a pipeline runs itself forever. |
| **DWF‑4** | Where outputs live | **Repository documents with a provenance row** · vs blobs in run state | Shareable, versioned, searchable, and "where did this come from" is a click. |
| **DWF‑5** | Extraction output | **Validated against a caller-supplied JSON schema; refused on mismatch** · vs accept and flag | A wrong extraction that looks finished is worse than a failed step. |
| **DWF‑6** | Form rendering | **Markdown/HTML in v1, DOCX via template; PDF deferred** · vs a PDF renderer now | Every PDF renderer is a dependency; a DOCX form is what people edit anyway. |
| **DWF‑7** | Manual vs automatic | **The same `run` path for both; "Run workflow…" ships first** · vs triggers only | A pipeline is tested by hand before it is automated, on the same code. |
| **DWF‑8** | The first-user path | **A shipped `doc-pipeline` plugin: text → fields → form → translations, configured per trigger** · vs a bespoke pipeline per customer | One workflow, many configurations, no new code per team. |
