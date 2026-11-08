# Search

One box and a magnifier. Type two characters or more and press `Enter`, or
press the button.

It searches, in one pass:

- **notes** — title and body
- **documents and files** in the [repository](repository.md) — by title, by
  path, and by the text extracted from inside them
- **translations**
- **entities** from the [knowledge graph](knowledge.md)

Each result carries a type badge, a title, and a passage from the match. A file
row shows its path under the title and offers **Download**.

## What it will and will not find

- **Every row is checked against your own permissions.** A colleague's private
  note is not in your results, and the count is not reduced by a figure saying
  so.
- **Searching inside a file needs its text to have been extracted.** A PDF or a
  .docx is searchable only after the indexing workflow has read it — until
  then, it is findable by name and path. A scanned page with no text layer needs
  OCR, which is a plugin an operator enables.
- **A path match is a substring match**, so `levee` finds
  `surveys/levee-7.pdf`.
- **If this instance encrypts document text at rest**, searching inside
  documents is not possible — the server says so in its answer rather than
  returning nothing. The semantic retrieval the platform also has is unaffected
  by that switch, but this box does not use it.
- **This box is keyword search.** Meaning-based retrieval over the team's
  documents exists and is reached by a workflow tool, not from here; asking the
  *documentation* a question in prose is the [Docs](asking-the-documentation.md)
  panel.

`Nothing matched.` means exactly that. `Type at least two characters.` is the
only other thing it says.

Search can be turned off for the instance, a company or a team.
