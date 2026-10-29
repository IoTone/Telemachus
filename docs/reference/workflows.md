# Workflows

Workflows shipped by plugins. Each is a validated spec (the public contract, WF‑9); a team sees them under `GET /api/workflows` and runs one with `POST /api/workflows/<slug>/run {input}`. Declared inputs are required and typed.

| Workflow | Plugin | Version | Steps | Description |
|---|---|---|---|---|
| `classify-and-extract` | doc-pipeline | 1 | 7 | Decide which kind of document this is (deterministic rules first, then the model), record the type on the document, and extract fields against the schema for THAT type. A type with no schema is classified and left alone. |
| `classify-backfill` | doc-pipeline | 1 | 2 | Backfill document types over a prefix: find the documents that have no type yet and classify each one, up to 25 per run. Safe to re-run — a document that already has a type is skipped — so a large backlog is drained by running it until it finds nothing. Pass backends ["rules"] to backfill without spending model budget. |
| `classify-eval` | doc-pipeline | 1 | 1 | Measure the classifier against the team's labelled fixtures — the documents under a prefix carrying a doc_type_expected attribute. Reports accuracy and coverage for each backend on its own, per label, with what each label was confused for and how confident the right and wrong answers were. Writes nothing: no type is recorded and no trigger fires, so a fixture set can be evaluated as often as you like. |
| `classify-review-extract` | doc-pipeline | 1 | 14 | Decide which kind of document this is; when the classifier is less sure than `min_confidence`, park the run and ask a person instead of guessing. Their decision is recorded on the document — approved as it stands, corrected to another type, or withdrawn when it is none of them — and the run then extracts fields against the schema for that type. |
| `embed-documents` | doc-indexer | 1 | 2 | Chunk the extracted text of repository documents and store an embedding per chunk, for semantic retrieval. Finds documents whose text has no vectors for the current version (or vectors from a different model), then embeds each one. Needs TMACH_EMBED_URL. Safe to re-run; processes up to 25 documents per run and spends the team's embedding budget. |
| `feed-propose` | feeds | 1 | 2 | An agent reads one pulled item and writes a proposal beside it; the run then parks on a person. Nothing acts on the proposal — v1 has no acting tool, and when it has one it goes on the approve branch. |
| `feed-triage` | feeds | 1 | 1 | Put one pulled item on the work queue with a priority, a due date and skills. The queue is an index: this records what triage decided. |
| `index-documents` | doc-indexer | 1 | 2 | Extract text from repository documents into the search index. Finds what is unindexed (or stale after an overwrite), then extracts each one. Safe to re-run; processes up to 40 documents per run. |
| `index-knowledge` | knowledge-graph | 1 | 2 | Extract entities and relations from indexed repository documents into the knowledge graph. Finds what is unextracted (or stale after an overwrite), then extracts each one with the model; a reply that does not validate is refused. Safe to re-run; processes up to 40 documents per run. |
| `process-upload` | doc-pipeline | 1 | 6 | Extract text, pull structured fields against a JSON schema (refused if they do not conform), fill a form template, and translate the result into the team's languages. Every output is a repository document beside the source, with provenance. |
| `redact-document` | doc-pipeline | 1 | 1 | Replace the identifiers in a document's text with stable tokens and write the result beside it as <key>.redacted.txt, so you can read exactly what a model request would be built from. Detectors are named — email, date, id_number, dictionary, phone — and the map from token back to value is kept in a sealed row no endpoint returns. |
| `translate-chat` | translate-chat | 1 | 3 | Chat once, fan the reply out to Spanish, Dutch and Icelandic, then bring each back. |

## `classify-and-extract` — Classify a document, then extract its fields

Decide which kind of document this is (deterministic rules first, then the model), record the type on the document, and extract fields against the schema for THAT type. A type with no schema is classified and left alone.

Plugin: `doc-pipeline` · version 1 · max steps 20 · starts at `classify`

Input:

| Name | Type |
|---|---|
| `labels` | array |
| `object_id` | string |
| `rules` | array |
| `schemas` | object |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `classify` | `tool:doc_classify` | `{"labels":"${input.labels}","object":"${input.object_id}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | next in order |
| `is_invoice` | `choice` | when `{"eq":["${steps.classify.output.result.label}","invoice"]}` then `invoice_text` else `is_letter` | next in order |
| `invoice_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `invoice_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.invoice}","step":"invoice_fields","text":"${steps.invoice_text.output.result}"}` | end · retry 1 |
| `letter_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `letter_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.letter}","step":"letter_fields","text":"${steps.letter_text.output.result}"}` | end · retry 1 |
| `is_letter` | `choice` | when `{"eq":["${steps.classify.output.result.label}","letter"]}` then `letter_text` | next in order |

## `classify-backfill` — Classify a backlog

Backfill document types over a prefix: find the documents that have no type yet and classify each one, up to 25 per run. Safe to re-run — a document that already has a type is skipped — so a large backlog is drained by running it until it finds nothing. Pass backends ["rules"] to backfill without spending model budget.

Plugin: `doc-pipeline` · version 1 · max steps 30 · starts at `find`

Input:

| Name | Type |
|---|---|
| `backends` | array |
| `labels` | array |
| `prefix` | string |
| `rules` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:doc_list_unclassified` | `{"prefix":"${input.prefix}","run":"${run.id}","step":"find"}` | next in order |
| `classify` | `map` | over `${steps.find.output.result.ids}` → `tool:doc_classify` with `{"backends":"${input.backends}","labels":"${input.labels}","object":"${item}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | end |

## `classify-eval` — Evaluate the classifier

Measure the classifier against the team's labelled fixtures — the documents under a prefix carrying a doc_type_expected attribute. Reports accuracy and coverage for each backend on its own, per label, with what each label was confused for and how confident the right and wrong answers were. Writes nothing: no type is recorded and no trigger fires, so a fixture set can be evaluated as often as you like.

Plugin: `doc-pipeline` · version 1 · max steps 5 · starts at `measure`

Input:

| Name | Type |
|---|---|
| `backends` | array |
| `labels` | array |
| `prefix` | string |
| `rules` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `measure` | `tool:doc_classify_eval` | `{"backends":"${input.backends}","labels":"${input.labels}","prefix":"${input.prefix}","rules":"${input.rules}","run":"${run.id}","step":"measure"}` | end |

## `classify-review-extract` — Classify, ask a person when unsure, then extract

Decide which kind of document this is; when the classifier is less sure than `min_confidence`, park the run and ask a person instead of guessing. Their decision is recorded on the document — approved as it stands, corrected to another type, or withdrawn when it is none of them — and the run then extracts fields against the schema for that type.

Plugin: `doc-pipeline` · version 1 · max steps 30 · starts at `classify`

Input:

| Name | Type |
|---|---|
| `labels` | array |
| `min_confidence` | number |
| `object_id` | string |
| `rules` | array |
| `schemas` | object |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `classify` | `tool:doc_classify` | `{"labels":"${input.labels}","object":"${input.object_id}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | next in order |
| `gate` | `choice` | when `{"lt":["${steps.classify.output.result.confidence}","${input.min_confidence}"]}` then `confirm` else `is_invoice` | next in order |
| `confirm` | `review` | `{}` | next in order |
| `accept` | `tool:doc_set_type` | `{"label":"${steps.classify.output.result.label}","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"accept","verdict":"approve"}` | `is_invoice` |
| `correct` | `tool:doc_set_type` | `{"label":"${steps.confirm.output.result.answers.doc_type}","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"correct","verdict":"revise"}` | `r_is_invoice` |
| `withdraw` | `tool:doc_set_type` | `{"label":"","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"withdraw","verdict":"reject"}` | end |
| `invoice_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `invoice_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.invoice}","step":"invoice_fields","text":"${steps.invoice_text.output.result}"}` | end · retry 1 |
| `letter_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `letter_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.letter}","step":"letter_fields","text":"${steps.letter_text.output.result}"}` | end · retry 1 |
| `is_invoice` | `choice` | when `{"eq":["${steps.classify.output.result.label}","invoice"]}` then `invoice_text` else `is_letter` | next in order |
| `is_letter` | `choice` | when `{"eq":["${steps.classify.output.result.label}","letter"]}` then `letter_text` else `r_is_invoice` | next in order |
| `r_is_invoice` | `choice` | when `{"eq":["${steps.correct.output.result.label}","invoice"]}` then `invoice_text` else `r_is_letter` | next in order |
| `r_is_letter` | `choice` | when `{"eq":["${steps.correct.output.result.label}","letter"]}` then `letter_text` | next in order |

## `embed-documents` — Embed Documents

Chunk the extracted text of repository documents and store an embedding per chunk, for semantic retrieval. Finds documents whose text has no vectors for the current version (or vectors from a different model), then embeds each one. Needs TMACH_EMBED_URL. Safe to re-run; processes up to 25 documents per run and spends the team's embedding budget.

Plugin: `doc-indexer` · version 1 · max steps 35 · starts at `find`

Takes no input.

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:repo_list_unembedded` | `{}` | next in order |
| `embed` | `map` | over `${steps.find.output.result}` → `tool:repo_embed_chunks` with `{"id":"${item}"}` | end |

## `feed-propose` — Propose what to do about a feed item

An agent reads one pulled item and writes a proposal beside it; the run then parks on a person. Nothing acts on the proposal — v1 has no acting tool, and when it has one it goes on the approve branch.

Plugin: `feeds` · version 1 · max steps 100 · starts at `propose`

Input:

| Name | Type |
|---|---|
| `object_id` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `propose` | `tool:feed_propose` | `{"object":"${input.object_id}","run":"${run.id}","step":"propose"}` | next in order |
| `decide` | `review` | `{}` | next in order |

## `feed-triage` — Triage a pulled feed item

Put one pulled item on the work queue with a priority, a due date and skills. The queue is an index: this records what triage decided.

Plugin: `feeds` · version 1 · max steps 100 · starts at `queue`

Input:

| Name | Type |
|---|---|
| `due` | number |
| `object_id` | string |
| `priority` | number |
| `skills` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `queue` | `tool:feed_queue_put` | `{"due":"${input.due}","object":"${input.object_id}","priority":"${input.priority}","skills":"${input.skills}"}` | end |

## `index-documents` — Index Documents

Extract text from repository documents into the search index. Finds what is unindexed (or stale after an overwrite), then extracts each one. Safe to re-run; processes up to 40 documents per run.

Plugin: `doc-indexer` · version 1 · max steps 50 · starts at `find`

Takes no input.

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:repo_list_unindexed` | `{}` | next in order |
| `extract` | `map` | over `${steps.find.output.result}` → `tool:repo_extract_text` with `{"id":"${item}"}` | end |

## `index-knowledge` — Index Knowledge

Extract entities and relations from indexed repository documents into the knowledge graph. Finds what is unextracted (or stale after an overwrite), then extracts each one with the model; a reply that does not validate is refused. Safe to re-run; processes up to 40 documents per run.

Plugin: `knowledge-graph` · version 1 · max steps 50 · starts at `find`

Takes no input.

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:kg_list_unextracted` | `{}` | next in order |
| `extract` | `map` | over `${steps.find.output.result}` → `tool:kg_extract` with `{"object":"${item}"}` | end |

## `process-upload` — Process an uploaded document

Extract text, pull structured fields against a JSON schema (refused if they do not conform), fill a form template, and translate the result into the team's languages. Every output is a repository document beside the source, with provenance.

Plugin: `doc-pipeline` · version 1 · max steps 40 · starts at `text`

Input:

| Name | Type |
|---|---|
| `locales` | array |
| `object_id` | string |
| `schema` | object |
| `template` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schema}","step":"fields","text":"${steps.text.output.result}"}` | next in order · retry 1 |
| `has_form` | `choice` | when `{"empty":["${input.template}"]}` then `translate_source` else `form` | next in order |
| `form` | `tool:doc_render` | `{"data":"${steps.fields.output.result.fields}","object":"${input.object_id}","run":"${run.id}","step":"form","template":"${input.template}"}` | next in order |
| `translate_form` | `map` | over `${input.locales}` → `tool:doc_translate` with `{"locale":"${item}","object":"${steps.form.output.result.object_id}","run":"${run.id}","step":"translate"}` | end |
| `translate_source` | `map` | over `${input.locales}` → `tool:doc_translate` with `{"locale":"${item}","object":"${input.object_id}","run":"${run.id}","step":"translate"}` | end |

## `redact-document` — Redact a document

Replace the identifiers in a document's text with stable tokens and write the result beside it as <key>.redacted.txt, so you can read exactly what a model request would be built from. Detectors are named — email, date, id_number, dictionary, phone — and the map from token back to value is kept in a sealed row no endpoint returns.

Plugin: `doc-pipeline` · version 1 · max steps 5 · starts at `redact`

Input:

| Name | Type |
|---|---|
| `detectors` | array |
| `object_id` | string |
| `terms` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `redact` | `tool:doc_redact` | `{"detectors":"${input.detectors}","object":"${input.object_id}","run":"${run.id}","step":"redact","terms":"${input.terms}"}` | end |

## `translate-chat` — Translate Chat Workflow

Chat once, fan the reply out to Spanish, Dutch and Icelandic, then bring each back.

Plugin: `translate-chat` · version 1 · max steps 20 · starts at `chat`

Input:

| Name | Type |
|---|---|
| `message` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `chat` | `tool:chat_message` | `{"text":"${input.message}"}` | next in order |
| `to_all` | `map` | over `["es","nl","is"]` → `tool:translate_text` with `{"source":"${principal.locale}","target":"${item}","text":"${steps.chat.output.result}"}` | next in order |
| `back_home` | `map` | over `${steps.to_all.output.results}` → `tool:translate_text` with `{"target":"${principal.locale}","text":"${item.result}"}` | end |

