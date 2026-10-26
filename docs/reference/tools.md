# Tools

Every tool the agent may call and a workflow step may use, from `define-tool` declarations and plugin registrations. Each tool checks its own permission when invoked; a workflow step also needs `tools:invoke`.

| Tool | Permission | Source | Description |
|---|---|---|---|
| `chat_message` | `chat:use` | translate-chat | Send one chat message to the model and return its reply. |
| `create_note` | `notes:write` | built-in | Create a note for the current user's team. |
| `doc_classify` | `files:write` | built-in | Decide which KIND of document this is, from a label set the caller gives: one label plus a confidence and a one-line rationale. Deterministic keyword/content-type rules are tried first and the model second (`backends` reorders them). The answer is written onto the document as doc_type / doc_type_confidence / doc_type_source, so a later step — or a trigger — can choose a schema by type, and kept beside it as <key>.classification.json. |
| `doc_classify_eval` | `files:read` | built-in | Measure the classifier against a labelled fixture set: the documents under a key prefix that carry a doc_type_expected attribute. Reports accuracy and coverage per backend AND per label, what each label was confused for, and the mean confidence of right and wrong answers — the figure that tells you whether a review threshold can separate them. Each backend is run SEPARATELY, so rules and llm are compared rather than chained, and the chain's own answer is reported beside them. Writes nothing: no type is recorded and no trigger fires. |
| `doc_extract_fields` | `files:write` | built-in | Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json. |
| `doc_fill_form` | `files:write` | built-in | Fill the AcroForm fields of a PDF in the repository from a JSON object of field names to values, and write the result beside it as <key>.filled.pdf. A text field takes a string, a checkbox true or false, and a radio group, combo box or list box one of its own options. Field names that the form does not carry are REPORTED in `unmatched` (every name wrong is refused instead). With flatten true the fields are drawn into the page and the document is no longer editable. |
| `doc_list_unclassified` | `files:read` | built-in | List repository documents under a key prefix that have no document type yet — the input to a classification backfill. Returns object ids, capped at a batch; run the backfill again to continue. A document that already carries doc_type is skipped, which is what makes a re-run free, and the outputs other runs derived are never listed. |
| `doc_redact` | `files:write` | built-in | Replace the identifiers in a document's text with stable tokens — <PERSON_1>, <DATE_2>, <ID_3> — so a model request can be built from what is left. Detectors are named, not written by the caller: email, date, id_number, dictionary (terms you supply) and phone. Writes the redacted text beside the source as <key>.redacted.txt and keeps the map from token back to value in a sealed row that no endpoint returns. Reports counts per detector, so under-redaction is visible. |
| `doc_render` | `files:write` | built-in | Fill a form template (a Markdown, HTML or DOCX document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside (in a DOCX, a table row that is only {{#each items}} opens a per-item row block). Writes the result beside the source as <key>.form.<ext>, or as <key>.form.pdf when format is "pdf" (a Markdown or HTML template, converted with pandoc and tectonic). |
| `doc_set_type` | `files:write` | built-in | Record the document type a PERSON decided, after a review. The label is held to the same label set the classification offered, so a type no trigger could match is refused rather than stored. An EMPTY label withdraws the type — the honest record of a rejection, since there is no doc_type of "unknown". Writes doc_type / doc_type_confidence / doc_type_source with source "review" and confidence 1.00, and versions <key>.classification.json beside the document so the backend's original guess stays in its history. |
| `doc_text` | `files:read` | built-in | Return the text of a repository document (PDF, DOCX, HTML, Markdown, plain text). The first step of any document pipeline; it does not depend on the search index having run. |
| `doc_translate` | `files:write` | built-in | Translate a repository document into a language, applying the team glossary, and write the result beside it (the locale goes before the extension: report.md -> report.ja.md; a PDF's text becomes report.ja.txt). |
| `get_usage` | `chat:use` | built-in | Report the team's current AI usage against its quota. |
| `kg_extract` | `files:read` | built-in | Extract entities (people, organizations, products, places, events, concepts) and the relations between them from one repository document into the knowledge graph, every mention with a verbatim snippet. Refuses a reply that does not validate. |
| `kg_list_unextracted` | `files:read` | built-in | List repository documents whose text has not been extracted into the knowledge graph yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the index-knowledge workflow again to continue. |
| `kg_query` | `files:read` | built-in | What the team's documents say about an entity: its relations and the documents that mention it, with snippets. Give a name (or an entity id); hops 1 returns its neighbours, hops 2 their neighbours too. |
| `list_notes` | `notes:read` | built-in | List the current user's notes (title and visibility). |
| `repo_extract_text` | `files:write` | built-in | Extract the text of one repository document into the search index. |
| `repo_list_unindexed` | `files:read` | built-in | List repository documents whose text has not been extracted for search yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the indexing workflow again to continue. |
| `shipment_eta` | `chat:use` | integrator-demo | Estimate arrival days for a shipment lane. |
| `translate_text` | `chat:use` | translate-chat | Translate text into a target language. |
| `update_note` | `notes:write` | built-in | Update a note's title and/or body by id. |
| `word_count` | `chat:use` | example-tools | Count the number of words in a piece of text. |

## `chat_message`

Send one chat message to the model and return its reply.

Permission: `chat:use` · source: translate-chat

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | What the user said |

## `create_note`

Create a note for the current user's team.

Permission: `notes:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `body` | string | yes | Note body text |
| `title` | string | yes | Short note title |
| `visibility` | string (team, private, shared) | no | Who can see it; defaults to team |

## `doc_classify`

Decide which KIND of document this is, from a label set the caller gives: one label plus a confidence and a one-line rationale. Deterministic keyword/content-type rules are tried first and the model second (`backends` reorders them). The answer is written onto the document as doc_type / doc_type_confidence / doc_type_source, so a later step — or a trigger — can choose a schema by type, and kept beside it as <key>.classification.json.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `backends` | array of string | no | Backend order: "rules", "llm" (default: rules then llm) |
| `labels` | array of object | yes | The document types to choose between — one of these, and nothing else, can be the answer |
| `object` | string | yes | The repository object id |
| `redact` | boolean | no | Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored |
| `redact_detectors` | array of string | no | Which detectors to run when redact is true: "email", "date", "id_number", "dictionary", "phone" (default: all but dictionary) |
| `redact_terms` | array of string | no | Literal names or phrases for the dictionary detector — not patterns |
| `rules` | array of object | no | Deterministic rules, tried in order; the first that matches decides. Phrases, not regular expressions, and a rule needs at least one condition |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `text` | string | no | The document's text (default: extracted from the document; a scan with no text layer can still match a content-type rule) |

## `doc_classify_eval`

Measure the classifier against a labelled fixture set: the documents under a key prefix that carry a doc_type_expected attribute. Reports accuracy and coverage per backend AND per label, what each label was confused for, and the mean confidence of right and wrong answers — the figure that tells you whether a review threshold can separate them. Each backend is run SEPARATELY, so rules and llm are compared rather than chained, and the chain's own answer is reported beside them. Writes nothing: no type is recorded and no trigger fires.

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `backends` | array of string | no | Which backends to measure, each on its own: "rules", "llm" (default: both) |
| `labels` | array of object | yes | The document types being evaluated — a fixture expecting anything else is excluded and reported |
| `prefix` | string | no | Only documents whose key starts with this (default: every document in the team) |
| `rules` | array of object | no | The rule set to evaluate — the same rules the pipeline would run |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |

## `doc_extract_fields`

Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | no | The source document's object id — write the fields as a derived document beside it |
| `redact` | boolean | no | Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored |
| `redact_detectors` | array of string | no | Which detectors to run when redact is true: "email", "date", "id_number", "dictionary", "phone" (default: all but dictionary) |
| `redact_terms` | array of string | no | Literal names or phrases for the dictionary detector — not patterns |
| `run` | string | no | The workflow run id, for provenance |
| `schema` | object | yes | A JSON schema the extracted object must conform to |
| `step` | string | no | The workflow step id, for provenance |
| `text` | string | yes | The document's text |

## `doc_fill_form`

Fill the AcroForm fields of a PDF in the repository from a JSON object of field names to values, and write the result beside it as <key>.filled.pdf. A text field takes a string, a checkbox true or false, and a radio group, combo box or list box one of its own options. Field names that the form does not carry are REPORTED in `unmatched` (every name wrong is refused instead). With flatten true the fields are drawn into the page and the document is no longer editable.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `flatten` | boolean | no | Draw the filled fields into the page content and remove them, so the result cannot be edited (needs qpdf) |
| `object` | string | yes | The form document's object id — a PDF carrying AcroForm fields |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `values` | object | yes | Field name to value, e.g. {"applicant": "Arun Patel", "urgent": true} |

## `doc_list_unclassified`

List repository documents under a key prefix that have no document type yet — the input to a classification backfill. Returns object ids, capped at a batch; run the backfill again to continue. A document that already carries doc_type is skipped, which is what makes a re-run free, and the outputs other runs derived are never listed.

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `prefix` | string | no | Only documents whose key starts with this (default: every document in the team) |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |

## `doc_redact`

Replace the identifiers in a document's text with stable tokens — <PERSON_1>, <DATE_2>, <ID_3> — so a model request can be built from what is left. Detectors are named, not written by the caller: email, date, id_number, dictionary (terms you supply) and phone. Writes the redacted text beside the source as <key>.redacted.txt and keeps the map from token back to value in a sealed row that no endpoint returns. Reports counts per detector, so under-redaction is visible.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `detectors` | array of string | no | Which detectors to run: "email", "date", "id_number", "dictionary", "phone" (default: all but dictionary, which needs terms) |
| `object` | string | yes | The repository object id |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `terms` | array of string | no | Literal names or phrases the dictionary detector should replace — not patterns |
| `text` | string | no | The text to redact (default: extracted from the document) |

## `doc_render`

Fill a form template (a Markdown, HTML or DOCX document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside (in a DOCX, a table row that is only {{#each items}} opens a per-item row block). Writes the result beside the source as <key>.form.<ext>, or as <key>.form.pdf when format is "pdf" (a Markdown or HTML template, converted with pandoc and tectonic).

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `data` | object | yes | The data to fill in, e.g. the extracted fields |
| `engine` | string (latex, weasyprint) | no | Which PDF engine, when format is "pdf": "latex" (the default — pandoc and tectonic, good for text-heavy documents) or "weasyprint", which renders the HTML template's own CSS including @page margins, running headers and footers, and "Page X of Y". The HTML engine needs an HTML template and can inline a repository document as an image with src="repo:<object id>". |
| `format` | string | no | Output format: the template's own (default) or "pdf" — Markdown and HTML templates only |
| `object` | string | no | The source document's object id — the form is written beside it (default: beside the template) |
| `pdf_variant` | string (pdf/a-2b) | no | Ask the HTML engine for an archival PDF: "pdf/a-2b". A raster image makes the output non-conformant (the engine marks images Interpolate true, which PDF/A forbids) — use an SVG logo. |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `template` | string | yes | The template document's object id or key |

## `doc_set_type`

Record the document type a PERSON decided, after a review. The label is held to the same label set the classification offered, so a type no trigger could match is refused rather than stored. An EMPTY label withdraws the type — the honest record of a rejection, since there is no doc_type of "unknown". Writes doc_type / doc_type_confidence / doc_type_source with source "review" and confidence 1.00, and versions <key>.classification.json beside the document so the backend's original guess stays in its history.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `label` | string | yes | The type that was decided, spelled exactly as in the label set; empty to withdraw the type |
| `labels` | array of object | yes | The label set the decision was made against — the same one doc_classify was given |
| `object` | string | yes | The repository object id |
| `rationale` | string | no | Why, in the reviewer's own words — kept in the record, not in the attributes |
| `review` | string | no | The review id, for provenance |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `verdict` | string | no | The review verdict this came from: approve, revise or reject |

## `doc_text`

Return the text of a repository document (PDF, DOCX, HTML, Markdown, plain text). The first step of any document pipeline; it does not depend on the search index having run.

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | yes | The repository object id |
| `version` | string | no | A specific version id (default: the current version) |

## `doc_translate`

Translate a repository document into a language, applying the team glossary, and write the result beside it (the locale goes before the extension: report.md -> report.ja.md; a PDF's text becomes report.ja.txt).

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `locale` | string | yes | Target language code, e.g. ja, nl, es-419 |
| `object` | string | yes | The document's object id |
| `redact` | boolean | no | Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored |
| `redact_detectors` | array of string | no | Which detectors to run when redact is true: "email", "date", "id_number", "dictionary", "phone" (default: all but dictionary) |
| `redact_terms` | array of string | no | Literal names or phrases for the dictionary detector — not patterns |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |

## `get_usage`

Report the team's current AI usage against its quota.

Permission: `chat:use` · source: built-in

No parameters.


## `kg_extract`

Extract entities (people, organizations, products, places, events, concepts) and the relations between them from one repository document into the knowledge graph, every mention with a verbatim snippet. Refuses a reply that does not validate.

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | yes | The repository object id |

## `kg_list_unextracted`

List repository documents whose text has not been extracted into the knowledge graph yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the index-knowledge workflow again to continue.

Permission: `files:read` · source: built-in

No parameters.


## `kg_query`

What the team's documents say about an entity: its relations and the documents that mention it, with snippets. Give a name (or an entity id); hops 1 returns its neighbours, hops 2 their neighbours too.

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `hops` | integer | no | 1 (default) or 2 |
| `name` | string | yes | An entity name (matched case-insensitively) or an entity id |
| `type` | string | no | Restrict a name lookup to one entity type, e.g. organization |

## `list_notes`

List the current user's notes (title and visibility).

Permission: `notes:read` · source: built-in

No parameters.


## `repo_extract_text`

Extract the text of one repository document into the search index.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | The repository object id |

## `repo_list_unindexed`

List repository documents whose text has not been extracted for search yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the indexing workflow again to continue.

Permission: `files:read` · source: built-in

No parameters.


## `shipment_eta`

Estimate arrival days for a shipment lane.

Permission: `chat:use` · source: integrator-demo

| Parameter | Type | Required | Description |
|---|---|---|---|
| `lane` | string | yes | Lane, e.g. SIN-LAX |

## `translate_text`

Translate text into a target language.

Permission: `chat:use` · source: translate-chat

| Parameter | Type | Required | Description |
|---|---|---|---|
| `source` | string | no | Source language code, or auto |
| `target` | string | yes | Target language code, e.g. es, nl, is |
| `text` | string | yes | The text to translate |

## `update_note`

Update a note's title and/or body by id.

Permission: `notes:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `body` | string | no | New body (optional) |
| `id` | string | yes | The note id |
| `title` | string | no | New title (optional) |

## `word_count`

Count the number of words in a piece of text.

Permission: `chat:use` · source: example-tools

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | The text to count words in |

