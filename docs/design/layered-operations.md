# Layered operations: human review, project metadata, and the plugin boundary

*Proposed 3 Oct 2026 (LAY‑1…12, see [decisions.md](decisions.md)). **LAY‑1, ‑2 and
‑3, ‑4, ‑5, ‑6 and ‑7 are BUILT** (4–12 Oct 2026): the `review` step kind, the `waiting` run status,
decision records in `domain/review/review.rkt`, generalised four-eyes, `/api/reviews*`
and the Review tab, with `test/review-tests.rkt` and the smoke's `== reviews ==`
block; the repository capabilities for out-of-process plugins; the extractor registry;
team-defined object metadata; and extraction provenance. LAY‑8 landed separately with four other defects from issue #54. The rest
remain proposals. This document is a gap analysis: it separates what the **platform**
must grow from what a **domain supplies as plugins and workflows**. It is driven
by an RFE from a prospective customer — a small civil-engineering and
disaster-response team in Japan — but the platform gaps it finds are not
theirs alone, and the civil-engineering specifics are deliberately pushed out of
core.*

## The shape the RFE describes

Three layers over one local instance:

| Layer | Who | What they do |
|---|---|---|
| 1 | operators | routine processing — text out of documents, classification, draft summaries, record organisation |
| 2 | a small expert group | review AI output, make technical judgements, assess risk, prepare directives |
| 3 | leadership | negotiate with government agencies, set direction, give final approval |

Their own conclusion is that Layers 1 and 3 are clear and **Layer 2 is the hard
part** — and they are right, because Layer 2 is the only one the platform cannot
express at all today. The rest of their asks are either already built or are
domain content.

Their hard constraint — everything runs locally, no cloud — is the platform's
existing thesis, not a feature request.

## The boundary this document draws

The platform grows **seams**. The domain supplies **content through them**. If a
requirement names a levee, a disaster type or a crack width, it is not a platform
requirement.

| Their requirement | Platform seam needed | Who supplies the content |
|---|---|---|
| Japanese OCR of scanned inspection reports | an extractor registry (LAY‑7), repository access for out-of-process plugins (LAY‑6) | a plugin wrapping YomiToku or PaddleOCR |
| Damage classification from site photos | the same two seams, plus the existing pull-executor and job-kind machinery | a plugin wrapping a CV model |
| Engineers annotating images by hand | annotation storage (LAY‑4) and a review step (LAY‑1); the authenticated plugin bundle already serves custom screens | a plugin's annotation canvas |
| EXIF capture time and location on photos | the extractor registry writing into object metadata (LAY‑7 → LAY‑4) | a plugin that reads EXIF |
| Inspection checklists / evaluation axes | a review step that carries a form (LAY‑1, LAY‑2) | the team's checklist, as workflow config |
| Government submission forms | **nothing — already built** (`doc_render` → pandoc → tectonic) | their form templates |
| "Who approved this, when, and why" | decision records (LAY‑2), tamper-evidence (LAY‑11) | — |
| Project ID, location, period, status, responsible person | operator-defined object metadata (LAY‑4) | their field definitions |

Six or seven seams carry all of it. That is the test of whether this design is
right: **if a civil-engineering requirement needs a core change, the seam is
wrong.**

## What already answers the RFE

So that none of it is rebuilt:

| Their ask | What answers it |
|---|---|
| All processing local, no cloud | the local model seam, local blob store, pull executors for a GPU box |
| Reusable standardised workflows | the workflow engine (slice 46) — a validated data spec, published per team |
| "PDF ingestion → extraction → summarisation → report generation" | the `doc-pipeline` plugin, as shipped |
| Traceable records linking each input to its output | `repo_derivations`, `doc_trigger_fires`, `GET /api/repo-obj/<id>/processing` |
| Audit of who did what, when | `audit_log` with microsecond ordering (issue #47) |
| Processing starts when a document arrives | upload **triggers** on the `repo-put!` seam (DWF) |
| Model-replaceable summarisation | model **roles** and named executors |
| Mandatory second pair of eyes | the rule exists, in one subsystem — see LAY‑3 |
| Any format in, byte-identical out | the document repository (DOC‑1…17) |

Their volume — tens of documents at a time, ordinary report lengths — is already
within the shipped limits: `EXTRACT-CAP` is 200,000 characters (~50 printed
pages), the indexing batch is 40 documents per run, the upload ceiling is 32 MiB.
**No throughput work is implied by this RFE**, and the pull-executor fleet we
have is more compute architecture than they need. One box runs all of it.

---

## The platform gaps

### LAY‑1 — A workflow cannot wait for a person  ✅ built

Step kinds are `tool:<name>`, `choice` and `map`. `agent`, `job:` and `flow:` are
planned. **There is no step that parks a run until a human decides.**

Their core sequence — *extraction → summarisation → **specialist review** →
report generation → **leadership approval*** — has two human gates, and neither
can exist inside a workflow. Today the only way to express it is to run a
pipeline, have somebody look at the output by hand, and start a second workflow;
nothing records that the review happened as part of the run, so the run's history
is a lie by omission.

This is the gap. Everything else in this document is smaller.

The engine is already a durable reducer: `flow-advance!` reads the run from the
database and enqueues the next step, and nothing lives in memory. A `waiting`
run status and a `review` step fit that shape rather than fight it — the run
stops being advanced, and a decision advances it. No new durability story, no
timer, no in-memory queue.

*As built:* a review step never becomes a job. `start-review!` writes the step row
`waiting`, opens the review and parks the run; `resume-from-review!` (installed as
`review.rkt`'s resume hook, so that module never learns what a workflow is) writes
the step done, moves the cursor to the branch the verdict names and sets the run
running again. Nothing is queued while it waits, so a parked run holds no
concurrency slot however long the specialist takes — pinned by an assertion that
the job queue is empty. Cancelling a parked run cancels its pending review.

### LAY‑2 — A decision is not a log line  ✅ built

A review produces four things: a **verdict**, a **rationale**, an **actor** and a
**time**. The audit log carries actor and time, but it is an append-only ordering
of events — not a queryable work surface. "What is waiting for me?" and "why was
this rejected in March?" are both ordinary questions that an audit log answers
badly.

Decisions want their own rows, referenced from the run step, with the audit log
recording *that* a decision happened as it does for every other action.

Their Layer 3 requirement — "preservation of decision-making records, including
who made each decision, when, and based on what rationale" — is this record, not
a separate feature.

### LAY‑3 — Four-eyes exists, in exactly one subsystem  ✅ built

`l10n-review!` already refuses to let a translator approve their own string, and
a machine draft has no human author so anyone with the permission may approve it.
That is precisely the rule the RFE asks for under "mandatory dual-review for
high-importance projects" — **built, tested, and locked inside the Localization
Manager.**

It should be the platform's rule about review generally, not one tab's rule about
strings.

### LAY‑4 — Objects carry no metadata a team can define  ✅ built

`repo_objects` has `org_id`, `team_id`, `owner_user_id`, `visibility`, `key`,
version pointers and timestamps. There is no project, no location, no period, no
status, no responsible person — and **no way for an operator to add any**.

Their Solution 4 ("a unified three-layer project data model") is entirely unmet,
and without it Layers 2 and 3 cannot filter, group or report: a leadership
dashboard has nothing to aggregate over.

The precedent to lift is the beta funnel's: operator-defined fields with a
deliberately **non-regex** validation vocabulary (`required` / `digits` /
`minlength` / `maxlength`), where any key outside a reserved set lands in an
`attributes` blob and needs no migration. That design was chosen because the
fields are admin-authored and the input is attacker-chosen; the same reasoning
holds here.

The knowledge graph is not a substitute. It extracts what a document *says*;
this is what the team *asserts*. For an inspection record the second is the
authoritative one.

*As built:* definitions are a team setting (`repo-fields:<team>` in
`instance_settings`, beside branding) and values are a blob on `repo_objects`, so
adding a field needs no migration. The validation vocabulary is literally the
funnel's — `field-problem` moved to `domain/fields/fields.rkt` and both now share
it, rather than a second implementation drifting. A key the team has not defined
is REFUSED rather than stored, the call the theme tokens make with an unknown
token: a value nothing can display or filter on is how a team concludes the model
is broken. `GET /api/repo?attr=key:value` is repeatable and applied AFTER the
per-row `can?`, so a filter can only narrow what a caller may see, never widen it.

### LAY‑5 — Extraction provenance is lost at ingest, and cannot be recovered later  ✅ built

**The one decision with a deadline.**

Today `extract-text` returns a string. When OCR reads a scanned page it knows far
more — the page, the region, the table cell each value came from — and all of it
is discarded at the seam.

If the coordinates are kept, their review interface stops being "source on the
left, output on the right" and becomes *click the extracted value and jump to the
highlighted region it came from*. Their stated objective is reducing specialist
workload; verifying a number against a highlighted region is seconds, hunting for
it in a thirty-page scan is minutes. It is the largest single lever on the thing
they actually care about.

If the coordinates are not kept, adding them later means re-processing every
document that was ever ingested. **This is cheap to design in and expensive to
retrofit**, which is why it belongs in this document rather than a later slice.

*As built:* an extractor may answer with two values or three, the third being its
spans — so provenance is additive and every extractor written before it, including
plugin ones, keeps working. `repo_text.spans` stores them beside the text;
`GET /api/repo-obj/<id>/spans?at=<offset>` resolves an offset to a region. No
built-in fills it yet: `pdftotext` would need `-bbox-layout`, and the reader that
will actually have regions is an OCR plugin. **The column exists before anything
fills it, which is the entire point** — the seam was the expensive half.

### LAY‑6 — An out-of-process plugin cannot touch the repository  ✅ built

The out-of-process host exposes exactly two capabilities: `notes.create` and
`notes.list`. A plugin can be handed JSON arguments and can return structured
results (issue #46), but it **cannot read a document's bytes, cannot read its
extracted text, and cannot write a derived document.**

Every domain pipeline in this RFE is Python — OCR, damage classification — so
this is a hard blocker for all of them, and it is small, well-shaped work: a few
more capabilities behind the scope check and `can?` that the two existing ones
already go through.

Note that an **in-process** Racket tool has no such problem (`doc-tools.rkt`
reads blobs freely). The asymmetry is the bug.

*As built:* `repo.get`, `repo.text` and `repo.put` behind the same double gate the
two notes capabilities already went through. Bytes travel base64 over the existing
pipe rather than as a path (which would couple a plugin to the local store and
leak its layout) or a presigned URL (which would need the S3 listener and a second
credential), capped at the same `TELEMACHUS_MAX_UPLOAD` the front door enforces.
`repo.put` with `derived_from` inherits the source's visibility and grants and
writes the derivation row, in that order. `repo.text` reports a scan as
`reason: "needs-ocr"` beside a null text rather than as an error — an OCR plugin
should not have to match on an error string to find its own branch. `GET
/api/plugins` now lists sandboxed plugins and the scopes each declared, which was
not observable at all. Worked example: `oop-plugins/doc-reader/`.

### LAY‑7 — Extractors are a fixed dispatch, not a registry  ✅ built

`kind-of` in `extract.rkt` is a `cond` over content types: text, markup, docx,
pdf. A plugin can add tools, routes, job kinds and workflows — but **cannot add
or replace a format handler.** Their "model-replaceable architecture" names PDF
extraction and image classification as the things they expect to swap, which is
exactly the list this seam does not cover.

With a registry, Japanese OCR, EXIF reading and keyframe sampling are all the
same kind of object: a plugin that claims a content type and returns text plus
metadata plus (LAY‑5) provenance.

*As built:* `register-extractor!` keyed by content type, with the ownership rules
the job-kind registry already had — two plugins cannot claim one type, and
re-registering your own is fine because the loader may run twice. A registration
REPLACES the built-in for that type, which is how a local OCR engine takes over
`application/pdf`. An extractor is in-process Racket and reaches a non-Racket
engine by shelling out, exactly as the built-in PDF reader pipes to `pdftotext`.

Three things the platform holds a plugin to, each because the alternative
regresses something that already works: the reason vocabulary is CLOSED to
`unsupported` / `missing-tool` / `needs-ocr` / `failed`, because `doc_text`
branches on two of them to produce named refusals and a fifth would arrive as a
refusal naming nothing; a plugin that raises or answers with the wrong shape
becomes the same `failed` an in-tree extractor gives, because one plugin must not
wedge a team's indexing; and the cap stays `EXTRACT-CAP`, because this feeds a
search index rather than an archive. `GET /api/plugins` reports each plugin's
claimed types. Worked example: an RTF reader in `plugins/example-tools/`.

What this does NOT do is let an out-of-process plugin BE an extractor — the
registry is called where the bytes are, with a port. A Python engine is reached
by shelling out from a small Racket extractor, and LAY‑6 covers the other
direction, where a plugin acts as a tool and asks for the bytes itself.

### LAY‑8 — A scanned page is indistinguishable from a blank one  ✅ built

A PDF with no text layer extracts to empty text and is recorded as **successfully
indexed** — the code says so outright: *"possibly empty — an empty PDF is still
indexed, so the workflow will not retry it forever."* `doc_text` then returns
`""`, the model is handed an empty document, and the user sees a schema
refusal that says nothing about the cause.

Their corpus is confirmed to include scans. This is a small fix — a `'needs-ocr`
reason alongside the existing `'missing-tool` and `'unsupported` — and it should
land **before** any OCR work, because without it nobody can tell which documents
need OCR.

### LAY‑9 — Nothing records whether a model can do what a workflow asks

Nothing stores whether a backend supports tool calls or honours `json_schema`;
it is discovered as a runtime failure. The platform already carries a scar from
this (the note about reasoning models putting the answer in a `reasoning` field).

This matters more than it used to. Japanese-language models lead
international models of comparable size on general benchmarks but **lag
specifically on function-calling and applied tasks** (Nejumi Leaderboard4, W&B
Japan, Aug 2025) — and function-calling is exactly what the agent and the
schema-extraction pipeline depend on. Choosing a Japanese model is therefore not
a drop-in swap, and the platform should be able to say so before a run fails.

### LAY‑10 — The accuracy signal is a report, not a system

Their Layer 2 "essential challenge" is *establishing a framework to determine the
reliability and acceptable scope of AI-generated outputs* — which sounds like an
evaluation platform and is not one.

Once LAY‑2 exists, every reviewed output carries a verdict. Accuracy per workflow,
per step, per model is then a **query over decisions already recorded**, not a
separate benchmarking subsystem. Their own review work produces the measurement
as a by-product.

The same rows are a supervised dataset: approved / revision-required / rejected,
each with a rationale, is what fine-tuning a domain model needs. This is the
strongest argument for building LAY‑1 and LAY‑2 first — they pay three times.

### LAY‑11 — Decision records are not tamper-evident

They preserve decisions for administrative and internal audit. The audit log is
append-only by convention and ordered to the microsecond, but nothing proves a
row was not altered afterwards.

The platform already content-addresses blobs by SHA‑256 and has HMAC in
`sha2.rkt`. Hash-chaining the decision records is modest work on existing
primitives, and for government-facing defensibility it is the difference between
a record and evidence.

### LAY‑12 — A review queue is core; an annotation canvas is not

A plugin cannot add a tab to the console. That is a known, documented gap, and
this RFE presses on it from both sides at once:

- **The review queue is platform.** Every team that runs a workflow with a human
  gate needs it, and it should be a core surface, permission-gated like the
  Localize tab already is.
- **The annotation canvas is not.** Drawing regions on an inspection photograph
  is domain work, and the authenticated plugin bundle
  (`/api/x/<id>/bundle/`, with the ticket mechanism for browser navigation)
  already exists to serve exactly that.

The platform owes the queue, the decision record and the storage. It does not owe
a crack-width widget.

---

## Deliberately not now

| Not doing | Why |
|---|---|
| Embeddings / semantic search | "Links to similar past cases" over a few hundred documents is answered by the existing substring search plus the knowledge graph. Embeddings would solve a problem this customer does not have. |
| Video processing as a subsystem | Keyframe sampling through the extractor registry (LAY‑7) turns a walkthrough pass into stills, and every downstream capability then works unmodified. A video pipeline is not implied. |
| Throughput, chunking, GPU fleets | Tens of documents at a time, ordinary report lengths. The shipped limits already cover it. |
| A second model wire protocol | OpenAI chat completions is what llama.cpp, ollama, vLLM and the Japanese model servers speak. |
| Confidence-driven routing | Worth proposing to them — their static AI-only/review-required boundary will not reduce workload, because hard and easy cases are mixed inside every task type. But it needs LAY‑10's measurements to set thresholds, so it cannot be first. |
| Field/offline operation with sync | Disaster response happens where networks do not reach, and multi-instance merge is genuinely hard. Ask before offering. |

## Build order

1. **LAY‑1, LAY‑2, LAY‑3** — the review step, the decision record, generalised
   four-eyes. The core ask, and the source of LAY‑10's signal.
2. **LAY‑8** then **LAY‑6, LAY‑7** — stop lying about scans, then open the seams
   the OCR and CV plugins need.
3. **LAY‑4** — object metadata, without which Layer 3 has nothing to report on.
4. **LAY‑5** — provenance, designed in with the OCR work rather than after it.
5. **LAY‑9, LAY‑12** — capability records and the review surface.
6. **LAY‑11** — tamper-evidence, when a government-facing deployment is real.

LAY‑1, ‑2, ‑3, ‑4, ‑6, ‑7 and ‑9 are platform features that every customer
benefits from. Only LAY‑5's urgency and LAY‑8's existence are specific to this
RFE, and both are defects rather than features.

## Open questions

- **Handwritten and vertical Japanese.** Inspection notes are often both.
  YomiToku handles them; PaddleOCR is weaker on vertical text. Confirm the corpus
  before choosing.
- ~~**Where the review queue lives for a team that uses no workflows.**~~ Settled
  as built: `reviews.run_id` is nullable, so the table already supports a review
  nothing produced, but only a run opens one today. The standalone path is a
  later slice, not a schema change.
- ~~**Whether a decision can be revoked.**~~ Settled as built: a decided review is
  terminal and deciding again is refused. A decision that turns out to be wrong
  wants a superseding record, not a rewrite — the same call the grants table makes
  by keeping expired rows for the trail.
- **Signed PDFs.** The repository stores bytes byte-identically, so a signature
  survives ingest — but every pipeline output is a *derived* document and carries
  none. If the signed original is the legal record, the distinction has to be
  visible in the UI rather than implied.
