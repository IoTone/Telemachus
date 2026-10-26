# Document workflows: uploads that trigger processing

*Decided 12 Sep 2026 (DWF‑1…8, see [decisions.md](decisions.md)). **All five
steps of the plan below are built** (slices 57–59): the four tools in
`domain/repo/doc-tools.rkt`, the validator in `domain/tools/jsonschema.rkt`, the
`doc-pipeline` plugin, "Run workflow…" on a document, upload **triggers** on the
seam in `repo-put!` (`domain/repo/triggers.rkt`, `/api/doc-triggers`), the
**Automations** card and the **"Processed by"** panel in the console, DOCX
rendering, and the invoice scenario in the e2e gate — with
`test/doc-pipeline-tests.rkt`, `test/doc-triggers-tests.rkt` and
`test/doc-pipeline-smoke.sh` (which ends with an `aws s3 cp` firing a run).* This is the
first-user scenario the platform is for: **a team uploads files, and a workflow
processes them** — extracts the data, runs inference over it, generates filled
forms, translates the result. Sharing of what the pipeline produces is in
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
run that workflow with it* — and, since issue #87 req 3b, *or when a document's
METADATA comes to match it.*

```
doc_triggers(id pk, team_id, workflow_slug, enabled bool,
             match_prefix text,           -- key prefix, e.g. "inbox/invoices/"
             match_types text,            -- comma-separated content types, "" = any
             input jsonb,                 -- extra input merged into the run, e.g. a schema ref
             match_attrs jsonb,           -- object metadata, key -> value, ALL must match
             fire_on_derived bool default false,
             created_by, created_at)

doc_trigger_fires(trigger_id, version_id, run_id, fired_at,  -- exactly-once per version
                  pk(trigger_id, version_id))
```

- **Fires once per version.** `doc_trigger_fires` is the idempotency key: a
  re-upload of the same bytes to the same key is a new version and fires again; a
  retried request for the same version does not.
- **`match_attrs` needs a SECOND seam, and that is the whole of CLS‑19…23.** A
  metadata condition cannot be evaluated when a document ARRIVES — at `repo-put!`
  nothing has classified it yet — so a trigger that names attributes also fires
  from `repo-set-attributes!`, the one place in the tree where object metadata
  changes. Equality only, at most ten keys, the `?attr=` vocabulary; a non-string
  or empty value is refused, because LAY‑4 values are strings and either would be
  a condition that can never hold. **A trigger wakes for the attributes it NAMES
  and only when they MOVE**, which is both the compatibility guarantee (a trigger
  with no `match_attrs` is untouched, so no existing deployment changes) and the
  rule that stops an edit to `project` waking a trigger watching `doc_type`.
  Exactly-once per version is unchanged and is what bounds the loop: a workflow
  that re-records the type on the document that started it finds the fire row
  already claimed. **A trigger is not a backfill** — creating one does not fire it
  on documents that already match.
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

Nine `define-tool`s (four at slice 57; `doc_classify` arrived with issue #87
slice 1, `doc_set_type` with slice 2, `doc_list_unclassified` with requirement 5,
`doc_classify_eval` with requirement 6, and `doc_redact` with issue #91).
Being tools, they are also available to the agent and to any hand-written
workflow; the pipeline below is just the shipped composition.

**`doc_text`** — already exists as `repo_extract_text`; returns the extracted text
of `(object_id, version_id)`. Kept as the first step so a pipeline never depends
on the search index having run.

**`doc_set_type`** — the other half of the review hook (slice 2): record the type
a PERSON decided. The label is held to the label set the classification offered,
so a type nothing could match is refused rather than stored; an empty label
withdraws the type. Writes the same three attributes with source `"review"` and
confidence `1.00`, and versions the same `<key>.classification.json`. It is a
separate tool from `doc_classify` rather than a mode of it because the two need
different things — a backend, a budget and `chat:use` on one side, none of them on
the other — but they share ONE write path, since the attributes-then-record order
is a rule and not an implementation detail.

**`doc_classify`** — an object plus a **label set** → one label, a confidence and
a one-line rationale (issue #87, decisions CLS‑1…12). Deterministic keyword /
content-type / key-suffix rules are tried first and the model second; `backends`
reorders them. The answer is written onto the document as `doc_type`,
`doc_type_confidence` and `doc_type_source`, so a later step — or a `?attr=`
filter — can choose a schema by type, and kept beside the source as
`<key>.classification.json`. **The rules are phrases and never regular
expressions**: a rule is operator-authored and runs against a document the
operator does not control, which is the same call this platform's field
vocabulary and binding sublanguage both make. **It does not need readable text**,
which is why it runs BEFORE `doc_text` in the type-routing pipeline: `doc_text`
raises for a photograph, and a photograph is exactly what a content-type rule is
for.

**`doc_redact`** — a document's text → the same text with its identifiers
replaced by stable tokens (issue #91 requirement 1, decisions RED‑1…9). The
detectors are **named, never written by the caller**: `email`, `date`,
`id_number`, `dictionary` (literal terms you supply) and `phone`, for the reason
the classifier's rules are phrases — an operator-authored pattern run against a
document the operator does not control is a denial of service with the operator's
own configuration as the weapon. A token is stable **within one document and
deliberately not across documents**, because a token meaning the same person
everywhere is a pseudonym and a pseudonym is a join key. The redacted text lands
beside the source as `<key>.redacted.txt`, so a person can read exactly what a
model request would be built from; the map back is a sealed row that **no endpoint
returns**. Text that already contains a token-shaped string is refused, since a
token minted there could not be told from it. Counts per detector come back with
it — requirement 5, so under-redaction is visible.

**`doc_classify_eval`** — a label set plus the team's **labelled fixtures** → one
report (requirement 6, decisions CLS‑29…33). The fixtures are the documents under
a prefix carrying a `doc_type_expected` attribute, which the tool declares on its
own first run so that there is something to label with. Every backend named is run
SEPARATELY on each fixture, from one reading of the document; the report carries
accuracy and coverage per backend, the same per label, what each label was
confused for, and the mean confidence of right and wrong answers. **It writes
nothing** — the tool is `files:read`, which is what keeps measuring the classifier
from classifying the fixture set.

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
extract text; writing one back is the same `file/unzip` in reverse). **PDF** came
in slice 68 as `format: "pdf"` on `doc_render`: the Markdown or HTML template is
filled exactly as before and the finished text goes through **pandoc → tectonic**,
the two tools the developer e-book had already pinned in `flake.nix` and that the
packaged server carries on its PATH. The toolchain is looked up at call time, so
a box without it boots and renders every other format; the one PDF call fails by
name. A DOCX template is refused rather than converted — LibreOffice is not a
dependency this platform takes on (DWF‑6).

**`doc_translate`** — wraps `translate!`: a document's text (or a rendered form)
into a target locale, glossary applied, written as `<key>.<locale>.<ext>`. Fanned
out with `map` over a list of locales.

Every output goes through **`inherit`** ([document-sharing.md](document-sharing.md)):
it takes the source's visibility and live grants at creation, is owned by the
run's principal, and gets a `repo_derivations` row naming the source version, the
run and the step. That row is what makes "where did this come from" a click, and
what lets a trigger tell a derived document from an original.

## The reference pipelines

Shipped as a plugin, `doc-pipeline`, in the pattern of `doc-indexer`. Six
compositions: `process-upload` (below) for an inbox whose documents are all of one
kind, **`classify-and-extract`** for a mixed one,
**`classify-review-extract`** for a mixed one with a person in it,
**`classify-backfill`** for the prefix that was already there, and
**`classify-eval`** for the question none of the others can answer, and
**`redact-document`** for what a model is NOT told —

```
classify  ->  the schema for THIS kind of document  ->  text  ->  fields
```

whose `labels`, `rules` and `schemas` are input, so a team configures its own
types without new code. There is deliberately no `switch` step kind: `choice`
chains into the same routing, and a `choice` with no `#:else` falls through to the
next step in list order rather than ending the run — so the branch that ends it is
the last step. A type with no schema is classified and left alone, which is the
right answer for a photograph.

`classify-review-extract` adds requirement 4's review hook (CLS‑13…18):

```
classify  ->  below min_confidence?  ->  a review  ->  record what was decided  ->  fields
```

**The threshold is a `choice`, not a flag on the tool.** Only a step can park a
run (LAY‑1), and `lt` with a declared `number` input already spells "below a
configurable confidence" — so the hook is composition, exactly as the routing
was. A decision lands on the document through **`doc_set_type`**: an approval
re-records the type with `doc_type_source = "review"` and confidence `1.00`, a
revision records the type the reviewer named (held to the same label set as the
model's — a type outside it is refused, never corrected to the nearest name), and
a rejection WITHDRAWS the type, because there is no `doc_type` of `"unknown"` and
the only honest record of "none of these kinds" is the absence of an assertion.
The backend's own guess survives as the previous version of
`<key>.classification.json`.

It carries **two routing chains**, one reading the classifier's label and one the
correction's, sharing the extraction steps. That is not tidy and it is not an
oversight: a revision changes the label, and the binding sublanguage has no
coalesce and no default by design, so nothing can say "the label from whichever of
these two steps ran". The escape hatch, when a third chain is wanted, is a tool
that reads the type back off the document.

`classify-backfill` is requirement 5, and it is `index-documents` with one tool
swapped:

```
find what has no type yet  ->  fan out  ->  classify each one
```

**A backfill is a workflow, not a mode of the tool.** A `batch: true` flag on
`doc_classify` would be one tool call doing unbounded work — no per-document
retry, no cancel granularity, and a step output that is a list of N results
nothing can route on — where `map` has been the engine's fan-out primitive since
slice 46. **"Unclassified" is the absence of `doc_type`**, so the marker is the
thing the backfill writes: a finished run followed by another run does nothing,
and no table and no migration were needed. **The records a run derived are never
listed**, or the next batch would be the classifications the last one wrote.
There is no `force`: the absence of the attribute is the only progress marker
there is, so a forced run would re-do its own first batch for ever — the way to
reclassify after changing the label set is to clear the type, which makes exactly
those documents eligible again. `backends` is an input because a backfill is
where the cost shows: `["rules"]` is free and deterministic, where four hundred
documents through the model is four hundred requests against a 200/day default.

`classify-eval` is requirement 6, and it is the only one of the five that
measures rather than does:

```
find the labelled fixtures  ->  run each backend on each of them  ->  one report
```

**The ground truth is an object attribute**, `doc_type_expected`, so the fixture
set is a thing the team curates in the repository and grows one document at a
time — a manifest passed to the call would be a file somebody has to keep in step
with the documents. A fixture labelled outside the label set is excluded and
reported, never scored as a miss: the classifier is not to blame for somebody's
typing.

**Each backend is run separately**, which is the thing production never does. In
a chain the second backend is only ever asked about the documents the first
declined, so a chain run measures the rules backend fully and the model backend
on a biased remainder. The chain's own answer is reported beside them and costs
nothing — it is "the first backend that answered", derived from the outcomes
already in hand.

**A backend that declines ABSTAINED and was not wrong.** The rules backend is
designed to answer only when a rule matched, so scoring silence as an error would
make a careful rule set look worse the more careful it was. Accuracy is therefore
over what a backend ANSWERED, with `coverage` beside it, and both are needed: a
backend that answers one document perfectly is 100% accurate and useless. It also
reports the mean confidence of right and wrong answers, which is the pair that
says whether `classify-review-extract`'s threshold can separate them.

**It writes nothing**, and the tool is `files:read`. Writing would overwrite the
type on a document a run had already classified, wake the metadata triggers
CLS‑23 built on every fixture, and leave the second run scoring the first run's
output. It is one step and no `map`, the opposite shape from the backfill above:
`map` fans out work done to each of N documents, and this produces one aggregate
over the set, which an engine with no reduce step kind cannot put back together.



`redact-document` is issue #91's requirement 1, and it is one step:

```
find the identifiers  ->  replace them with tokens  ->  a document you can read
```

**It is deliberately not yet a step inside the pipelines above.** That is #91's
requirement 2, where `doc_extract_fields`, `doc_classify` and `doc_translate` gain
`redact: true`, build their prompts from the redacted text and put the values back
before anything is stored — and adding an input to a published spec is a breaking
change, so those are left alone until the slice that earns it. What this already
gives an operator is the thing they ask for first: show me what you WOULD have
sent.

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

1. ✅ `repo_derivations` + `inherit` (slice 56); `doc_extract_fields` with schema
   validation and the refuse-on-mismatch tests, run against a scripted model AND
   a live one, as the Manager's drafting was.
2. ✅ `doc_render` for Markdown/HTML; `doc_translate`; the `doc-pipeline` plugin with
   `process-upload`; **"Run workflow…"** on a document. Smoke: upload → run by hand
   → four derived documents with provenance.
3. ✅ Triggers: the tables, the seam in `repo-put!`, exactly-once, the derived-document
   guard. Smoke: an S3 `PUT` fires the run — the path a team will actually use.
4. ✅ The Automations card and the "Processed by" panel; the e2e gate gains the
   invoice scenario end to end.
5. ✅ DOCX rendering. ✅ PDF (slice 68): `doc_render {format: "pdf"}` → `<key>.form.pdf`
   via pandoc + tectonic; `format` is a tool argument, so a workflow binds it as a
   literal (`"with": {"format": "pdf", …}`) — the four `process-upload` inputs are
   unchanged.

### As built (steps 1–2)

- **The model is a seam, not a dependency.** `current-doc-chat` (a parameter,
  default `run-chat` at temperature 0) is what the tools call; the unit tests
  script it, `test/mock-llm.rkt` gained a CHAT mode (`MOCK_REPLY_FILE`) so the
  HTTP smoke is deterministic, and the same smoke runs against a live model when
  `TELEMACHUS_MODEL_URL` is set. Without a model the default **refuses** ("no
  model configured") rather than letting the uppercase-echo fallback fail every
  schema with a misleading message.
- **The validator is a subset of JSON Schema with one deliberate difference**: an
  object that says nothing about `additionalProperties` is *closed* — an invented
  key is refused — because the point of an extraction schema is to say what the
  data is. `"additionalProperties": true` opens it. Supported: `type` (incl. a
  list), `properties`, `required`, `items`, `enum`, min/max, minLength/maxLength,
  minItems/maxItems, `pattern`. Unsupported keywords are ignored, but `type` is
  always enforced, so nothing is ever accepted on the strength of a keyword the
  validator does not know.
- **The renderer is strict too.** `{{field}}`, `{{a.b}}`, `{{#each items}}…{{/each}}`
  with `{{this}}` / `{{@index}}` and the outer scope visible inside a block; HTML
  templates escape values. A placeholder the data cannot satisfy is an **error**,
  never a blank — a form with an empty Total that looks finished is the failure
  DWF‑5 exists to prevent.
- **Keys read as a family**: `inbox/acme.pdf` → `inbox/acme.pdf.extracted.json`,
  `inbox/acme.pdf.form.md` (extension = the template's), `inbox/acme.pdf.form.ja.md`
  (locale before the extension); a translation of the *source* is
  `inbox/acme.ja.txt`. A re-run writes the next version of the same key.
- **A derived document is private from its first byte**: `repo-put!` is called
  with the source's visibility and *then* `repo-inherit!` copies the grants and
  writes the derivation row — never a window where a private invoice's fields are
  team-visible.
- **All four inputs are declared** (`object_id`, `schema`, `template`, `locales`)
  and therefore required by the engine; `""` and `[]` are the "skip" values (no
  template → the source is translated; no locales → stop after the form). The
  console's run form sends prefilled empties rather than dropping them.
- **The fields step retries once**: a schema mismatch is the model's mistake and a
  second reading at temperature 0 often conforms; a third would not. The refusal
  message names the path and the mismatch (`$.total: expected number, got string`).
- **The AI tools meter themselves** (`ai.requests`, `ai.tokens.total`, both tiers):
  the scheduler bills a *job's* `tokens_used`, and a workflow step's tool result
  is nested where it does not look. Raise the team's daily token budget before a
  batch, exactly as for the Localization Manager, or the queue stalls.
- **A viewer can run the pipeline on a shared document, and the outputs are
  theirs** (owned by the run's principal, DWF‑2) — but if the owner already ran it,
  the derived keys exist as the owner's private objects and the viewer's write is
  refused: the run fails cleanly instead of overwriting someone else's document.

### As built (step 3 — triggers)

- **The seam is a box on `repo-put!`** (`set-put-hook!`), installed when
  `domain/repo/triggers.rkt` is required; the engine never depends on the
  repository, so there is no cycle. The hook receives the written object and
  `#:derived?` — `#t`, or the **run id** the output came from. The run id matters
  because the derivation row is written *after* `repo-put!` returns; at the seam it
  does not exist yet.
- **A fire never fails an upload.** `doc_trigger_fires` is claimed before the run
  starts (exactly once per version); if the run cannot start, the row keeps the
  reason and an audit event `doc.trigger.error` is written. The two reasons seen in
  practice: the workflow was unpublished, and **the uploader's credential cannot
  run workflows** — an S3 key issued with the default `files:*` scopes. Issue the
  key with `workflows:read` and `workflows:run` for a prefix meant to fire.
- **The arrival wins on a clash** with the trigger's `input`: a trigger can carry
  a schema or a template, never redirect the run at a different document.
- **`fire_on_derived` means "other pipelines' outputs", never its own.** A trigger
  never fires on the output of a run it started (recognized by the run id at the
  seam, or by the derivation rows on a re-upload). Without this an opted-in
  trigger whose output matches itself ran 50 times in the test before the drain
  limit stopped it; "the operator opted in" is no consolation at 3 a.m.
- `match_types` takes exact types or a family (`image/*`); `""` is any. Fires are
  ordered by an epoch-millisecond column, because `CURRENT_TIMESTAMP` is seconds
  and "newest first" is a promise the history has to keep.
- The list endpoint carries the team's **remaining AI budget**: a trigger whose
  runs sit queued is a team out of tokens, not a broken trigger.

### As built (steps 4–5)

- **"Processed by"** is `GET /api/repo-obj/<id>/processing`: what was derived from
  the document (key, step, run), what it was derived from, and every run that
  touched it — started by hand with it as input, started by a trigger on it, or
  the run that wrote it. Each row is authorized on its own; a derived document
  the caller cannot read is simply absent. The console panel sits under the
  document's versions with "View" links into the run.
- **Automations** is a card on the Workflows tab: the team's triggers (workflow,
  prefix, types, enabled), each with a history (which version, which run, or why
  not), enable/disable/delete for `workflows:write`, a create form whose input
  is prefilled with the example schema, and the team's remaining AI budget.
- **DOCX rendering** (DWF‑6): a `.docx` template is a zip whose
  `word/document.xml` carries the same `{{placeholders}}`. Two things make that
  harder than it sounds and `docx-prepare` handles both: Word **splits a
  placeholder across runs** the moment the author pauses or the spell-checker
  looks at it (every tag between a `{{` and its `}}` is dropped), and line items
  want a **table row per item** (a row whose only text is `{{#each items}}`
  opens a block, a row that is only `{{/each}}` closes it; the rows between are
  repeated). Values are XML-escaped; the output is `<key>.form.docx` with the
  DOCX content type, and its translation is its text as `.txt`. Newlines in
  values, images and native tables of contents are v2.
- **The e2e gate** boots the scripted mock model when it boots its own server
  and runs the whole scenario through the console: upload a template and an
  invoice, "Run workflow…", wait for the run, find the derived documents, open
  the panel, create a trigger from the Automations card, upload into its prefix,
  watch it fire. On a live box the scenario runs only with `VALIDATE_PIPELINE=1`.

## Decisions (confirmed 12 Sep 2026)

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **DWF‑1** | Where triggers fire | **Inside `repo-put!`, after the version commits** · vs per-endpoint hooks | One seam covers console, shim and S3; three hooks drift. |
| **DWF‑2** | Whose principal a triggered run uses | **The uploader's** · vs the trigger creator's · vs a service account | A run can only read what its uploader could; outputs are owned by someone real. |
| **DWF‑3** | Re-firing | **Exactly once per version; derived documents do not re-trigger unless opted in** · vs fire on every write | Without both, a pipeline runs itself forever. |
| **DWF‑4** | Where outputs live | **Repository documents with a provenance row** · vs blobs in run state | Shareable, versioned, searchable, and "where did this come from" is a click. |
| **DWF‑5** | Extraction output | **Validated against a caller-supplied JSON schema; refused on mismatch** · vs accept and flag | A wrong extraction that looks finished is worse than a failed step. |
| **DWF‑6** | Form rendering | **Markdown/HTML in v1, DOCX via template; PDF as `format: "pdf"` through pandoc → tectonic (slice 68)** · vs a PDF renderer in-process · vs never | The two tools were already pinned for the e-book; looked up at call time so their absence costs exactly one named refusal. |
| **DWF‑7** | Manual vs automatic | **The same `run` path for both; "Run workflow…" ships first** · vs triggers only | A pipeline is tested by hand before it is automated, on the same code. |
| **DWF‑8** | The first-user path | **A shipped `doc-pipeline` plugin: text → fields → form → translations, configured per trigger** · vs a bespoke pipeline per customer | One workflow, many configurations, no new code per team. |
