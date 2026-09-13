# Tools

Every tool the agent may call and a workflow step may use, from `define-tool` declarations and plugin registrations. Each tool checks its own permission when invoked; a workflow step also needs `tools:invoke`.

| Tool | Permission | Source | Description |
|---|---|---|---|
| `chat_message` | `chat:use` | translate-chat | Send one chat message to the model and return its reply. |
| `create_note` | `notes:write` | built-in | Create a note for the current user's team. |
| `doc_extract_fields` | `files:write` | built-in | Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json. |
| `doc_render` | `files:write` | built-in | Fill a form template (a Markdown, HTML or DOCX document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside (in a DOCX, a table row that is only {{#each items}} opens a per-item row block). Writes the result beside the source as <key>.form.<ext>. |
| `doc_text` | `files:read` | built-in | Return the text of a repository document (PDF, DOCX, HTML, Markdown, plain text). The first step of any document pipeline; it does not depend on the search index having run. |
| `doc_translate` | `files:write` | built-in | Translate a repository document into a language, applying the team glossary, and write the result beside it (the locale goes before the extension: report.md -> report.ja.md; a PDF's text becomes report.ja.txt). |
| `get_usage` | `chat:use` | built-in | Report the team's current AI usage against its quota. |
| `kg_extract` | `files:read` | built-in | Extract entities (people, organizations, products, places, events, concepts) and the relations between them from one repository document into the knowledge graph, every mention with a verbatim snippet. Refuses a reply that does not validate. |
| `kg_list_unextracted` | `files:read` | built-in | List repository documents whose text has not been extracted into the knowledge graph yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the index-knowledge workflow again to continue. |
| `kg_query` | `files:read` | built-in | What the team's documents say about an entity: its relations and the documents that mention it, with snippets. Give a name (or an entity id); hops 1 returns its neighbours, hops 2 their neighbours too. |
| `list_notes` | `notes:read` | built-in | List the current user's notes (title and visibility). |
| `repo_extract_text` | `files:write` | built-in | Extract the text of one repository document into the search index. |
| `repo_list_unindexed` | `files:read` | built-in | List repository documents whose text has not been extracted for search yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the indexing workflow again to continue. |
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

## `doc_extract_fields`

Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | no | The source document's object id — write the fields as a derived document beside it |
| `run` | string | no | The workflow run id, for provenance |
| `schema` | object | yes | A JSON schema the extracted object must conform to |
| `step` | string | no | The workflow step id, for provenance |
| `text` | string | yes | The document's text |

## `doc_render`

Fill a form template (a Markdown, HTML or DOCX document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside (in a DOCX, a table row that is only {{#each items}} opens a per-item row block). Writes the result beside the source as <key>.form.<ext>.

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `data` | object | yes | The data to fill in, e.g. the extracted fields |
| `object` | string | no | The source document's object id — the form is written beside it (default: beside the template) |
| `run` | string | no | The workflow run id, for provenance |
| `step` | string | no | The workflow step id, for provenance |
| `template` | string | yes | The template document's object id or key |

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

