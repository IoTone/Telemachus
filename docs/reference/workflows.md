# Workflows

Workflows shipped by plugins. Each is a validated spec (the public contract, WF‑9); a team sees them under `GET /api/workflows` and runs one with `POST /api/workflows/<slug>/run {input}`. Declared inputs are required and typed.

| Workflow | Plugin | Version | Steps | Description |
|---|---|---|---|---|
| `classify-and-extract` | doc-pipeline | 1 | 7 | Decide which kind of document this is (deterministic rules first, then the model), record the type on the document, and extract fields against the schema for THAT type. A type with no schema is classified and left alone. |
| `index-documents` | doc-indexer | 1 | 2 | Extract text from repository documents into the search index. Finds what is unindexed (or stale after an overwrite), then extracts each one. Safe to re-run; processes up to 40 documents per run. |
| `index-knowledge` | knowledge-graph | 1 | 2 | Extract entities and relations from indexed repository documents into the knowledge graph. Finds what is unextracted (or stale after an overwrite), then extracts each one with the model; a reply that does not validate is refused. Safe to re-run; processes up to 40 documents per run. |
| `process-upload` | doc-pipeline | 1 | 6 | Extract text, pull structured fields against a JSON schema (refused if they do not conform), fill a form template, and translate the result into the team's languages. Every output is a repository document beside the source, with provenance. |
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

