# The document pipeline


## The first-user path

A team uploads a file and a workflow processes it: extract its text, pull structured fields against a JSON schema, fill a form template, translate the result. Four core tools compose into the shipped `process-upload` workflow; schema, template and locales are inputs, so one workflow serves invoices and intake forms with no new code. Every output is a repository document beside its source, with the source’s grants and a provenance row.

## Refuse, do not flag

The field extractor validates the model’s reply against the schema and refuses a missing required field, a string where a number was asked for, and an invented key — an object schema with no `additionalProperties` is *closed*, a deliberate departure from JSON Schema’s default. The template renderer refuses a placeholder the data cannot satisfy rather than rendering a blank: a form with an empty Total that looks finished is the failure the whole design exists to prevent. The step retries once, because a schema mismatch is the model’s mistake and a second reading at temperature zero often conforms.

## Templates

Markdown and HTML templates use `{{field}}`, dotted paths and `{{#each items}}` blocks. A DOCX template is a zip whose `word/document.xml` carries the same placeholders, and two things make that harder than it sounds: Word splits a placeholder across runs the moment the author pauses or the spell-checker looks at it, so every tag between a `{{` and its `}}` is dropped before rendering; and line items want a table row per item, so a row whose only text is `{{#each items}}` opens a block and a row that is only `{{/each}}` closes it. PDF rendering is deferred: every PDF renderer is a dependency, and a DOCX or HTML form is what a person edits anyway.

## Triggers

A trigger is a team-scoped subscription: when a document matching this prefix and these content types lands, run that workflow with it. Triggers are evaluated in exactly one place — a hook at the end of `repo-put!`, after the version commits — which covers the console upload, the text-document shim and an S3 `PUT` by construction. A match enqueues a run as the *uploader*, scopes and all; a run can only read what its uploader could read, and its outputs are owned by someone real. Fires are exactly once per version. A pipeline’s own outputs never re-fire the trigger that produced them, and an opted-in trigger never fires on the output of a run it started itself; without that rule an opted-in trigger ran itself fifty times in a test before the drain limit stopped it. An S3 key issued with the default `files:*` scopes cannot start a workflow — the trigger’s history says so plainly — and needs `workflows:run` for a prefix meant to fire.

## Files to open

`domain/repo/doc-tools.rkt`, `domain/tools/jsonschema.rkt`, `domain/repo/triggers.rkt`, `plugins/doc-pipeline/main.rkt`, `docs/design/document-workflows.md`, `test/doc-pipeline-tests.rkt`, `test/doc-triggers-tests.rkt`, `test/doc-pipeline-smoke.sh`.
