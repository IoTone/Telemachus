# Knowledge

The knowledge graph: entities and relations extracted from the team's
documents.

> Entities and relations extracted from the team's documents. Every fact links
> to the document and version that said it; you only see facts from documents
> you can read.

Four figures at the top — **entities**, **relations**, **documents
extracted** and **waiting** — then a search box, a type filter, and
**Extract now**.

## What is in it, and what is not

**Nothing enters without a source.** Every entity and every relation carries
the document *and the version* that said it, and a fact whose only source is a
document you cannot read is not shown to you. An entity that does not exist and
one you cannot see are the same answer, on purpose.

**This is not the [notes graph](notes.md#the-graph).** That one draws links a
person wrote between notes; this one draws what a model read out of documents.
They are deliberately separate screens and are not joined — an authored edge
and an extracted mention are different kinds of statement, and showing them on
one canvas would mean drawing one of them as weaker, which the data already
says better.

## Finding something

**Find an entity** searches by name; **Type** narrows to one kind of entity, or
`any type`. **Details** on an entity shows its relations and its
**mentions** — each one the document, the version, and the passage that said
it.

Entities are deduplicated per team by type and a normalised name, so
`Acme Ltd.` and `Acme Ltd` are one entity. Entities of **different types are
never merged**, even with the same name.

`No entities match. Index documents first, then extract.` is the sequence, and
it is the usual reason the screen looks empty:

1. A document's text has to be extracted — the **Index Documents** workflow.
2. Then the entities can be read out of that text — **Extract now**, or the
   **Index Knowledge** workflow.

A document with text the extractor found nothing in is marked as read so that
it is not offered for ever. `waiting` is how many documents are still to be
extracted.

## Extract now

Queues the extraction as a workflow run — `Extraction queued`. It costs model
requests per document and is bounded per run, so draining a backlog is several
runs rather than one. [Jobs](jobs.md) and [Workflows](workflows.md) show its
progress.

**A new version supersedes.** Re-uploading a document removes the old mentions
and extracts again; deleting a document removes its facts, and any entity left
with no mentions at all goes with them.

## Its limits, stated

- The extractor **refuses** a reply whose passage is not a verbatim substring
  of the document's text, or that names an entity it did not report. It retries
  once. This is what makes a mention checkable rather than plausible.
- With no model configured it refuses loudly rather than extracting nothing.
- Relations are not inferred across documents and nothing is scored: this is a
  record of what was said and where, not a confidence model.
