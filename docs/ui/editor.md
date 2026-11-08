# The editor

[Notes](notes.md) and [Documents](documents.md) use the same editor. It is one
component on purpose: three bare text boxes becoming three different editors is
the outcome worth avoiding.

A toolbar, a text area, a preview, and a count.

## The view buttons

- **Write** — the text only.
- **Split** — text and preview side by side.
- **Preview** — the rendered result only.
- **Lines** — a line-number gutter.
- **Wrap** — soft wrap.
- **Mono** — a monospaced face.
- **Focus** — full width, `Esc` to leave. The button then says **Done**.

**Turning line numbers on turns soft wrap off**, and the hint says why: a
wrapped logical line occupies several visual rows, so a gutter of logical
numbers stops lining up the moment one wraps. A subtly wrong gutter is worse
than none.

The four view choices are remembered in this browser. The **text** is not
stored anywhere until you save it.

## The count

`N words · N chars · N lines`. This is a plain measure of what you have
written — it is not a model budget, unlike the count on the
[Chat](chat.md), [Agent](agent.md) and [Translate](translate.md) prompts.

## The preview

The preview renders Markdown, or Org when the note's [body
format](notes.md#body-format) says so.

It is deliberately strict about what it will draw: the text is escaped first and
the rendering rules then emit a fixed set of tags, so nothing in a body can
become markup. A `<script>`, an `<img onerror=…>` and a `javascript:` link all
appear as the characters you typed. A link is only made into a link for a
recognised scheme.

## The buttons that leave the editor

- **Export .md** / **Export .org** download the body as a file. They export
  what is in the box, including unsaved changes.
- **Save to repository** stores the body as a document in the
  [repository](repository.md), where the document pipeline can act on it. A text
  document *is* a repository object, so this is a store rather than a copy.

## Two things to know

- **Switching tabs abandons an edit in progress.** There is no draft recovery.
- **The view buttons re-render the tab**, which rebuilds the plain fields around
  the editor — so a title typed into a create form and not yet saved is lost by
  pressing Split or Focus. Save first, or set the view before you start typing.
