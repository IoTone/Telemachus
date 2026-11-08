# Notes

A note is a title, a body and a visibility. The screen has a create form, a
list, and — when you open one — a view or an edit card above it.

## Creating and editing

**New note** gives you a title, the [editor](editor.md), tags and a
visibility. **Create** saves it.

A note in the list offers **View** (read-only, with its links) and **Edit**.
Editing is the same card as viewing, in the same place, so a note is never open
twice.

**Visibility** is one of three, and you set it because you wrote it:

- `Private — only me`
- `Team — everyone on this team`
- `Shared — only the people below`

**Leaving the tab abandons an unsaved note.** So does switching the body format
on an untouched form — the format control repaints in place precisely so that it
does *not* discard a title you have typed, but the view buttons (Write / Split /
Preview / Focus) still re-render the tab and will.

## Body format

**Body format** is `Markdown` or `Org`, and it is **declared, never guessed**.
A body beginning `* something` is a valid Markdown bullet *and* a valid Org
headline, and the two render completely differently, so nothing here detects
which you meant.

Changing the format **changes how the body is rendered and does not touch the
body**. It is reversible, and a conversion that rewrote your text would not be.
An existing note is Markdown unless you say otherwise; a note that is Org
carries a small badge saying so.

### What the Org renderer understands

Headlines `*`…`******`; `-`, `+` and `1.` lists; `#+BEGIN_SRC` and
`#+BEGIN_EXAMPLE` blocks; `*bold*`, `/italic/`, `_underline_`, `=verbatim=`,
`~code~`; `[[target][description]]` and `[[target]]`; tables with a `|---|`
separator; `#+TITLE:` and `#+FILETAGS:`; and `:tag:tag:` trailing a headline.

Everything else renders as its own text — a property drawer appears as
`:PROPERTIES:` rather than disappearing. Babel, `#+INCLUDE:`, TODO keywords,
footnotes, LaTeX fragments and timestamps-as-a-type are not implemented.
`#+INCLUDE:` is **refused by name and visibly**, because in real Org it reads a
file off the server's filesystem.

## Tags

Comma separated. Tags are lower-cased and trimmed, so `Invoice` and `invoice`
are one tag. The list shows each note's tags as badges and a tag badge filters
the list; **Clear filter** removes it. Filtering resets you to the first page.

**Auto-tag** asks the model for tags for one note, in the note's own language,
and keeps the tags it already has. It costs a model request, and it checks that
you may write the note *before* calling the model rather than after.

**An Org note's tags come from its own `#+FILETAGS:` line.** The tags field is
replaced by that line, and Auto-tag is disabled with a note saying why — there
is one authority for a note's tags and for an Org note it is the body. A
`#+FILETAGS:` line that is present is authoritative *including when it is
empty*, which is how a body clears them; a line that is absent says nothing and
leaves the stored tags alone.

## Links, and what `broken` means

An Org note's `[[target]]` makes an edge to another note, by title or by id.
Viewing a note shows two columns:

- **Links from this note** — only for an Org body, since only Org has the
  syntax.
- **Linked from** — for *any* note, because a Markdown note is linked to by an
  Org one just as readily.

A link that reaches nothing is drawn as **broken**, with the target as you typed
it and one of two reasons:

- `no note here has that title or id` — nothing in this team matches. Writing
  `[[Levee 7 survey]]` before creating that note is the ordinary way to get
  this, and it heals the moment the note exists.
- `two notes share that title, so the link reaches neither` — titles are not
  unique, and picking one of them would make the link mean a different note
  depending on which was created first.

A link whose target is a note you may not read is reported **exactly as one
that does not exist**. That is deliberate: reporting it differently would tell
you that a colleague's private note of that title exists.

## The graph

**Show the graph** draws the notes and the links between them. This is *your
team's notes*, not the [knowledge graph](knowledge.md) — the two are separate
screens and are deliberately not joined, because an edge somebody wrote and a
mention a model extracted are different kinds of statement.

- `The whole team` draws every note it can fit. From a single note, **Hops**
  chooses how far out to walk.
- A hollow node is a link target **no note has been written for yet** — four
  notes pointing at one unwritten note is a thing to go and do.
- The caption says how many notes were drawn of how many, and how many links.
- Nothing animates and no node can be dragged. The picture is the same every
  time for the same notes, which is what lets it be tested and photographed.

Four things it says when it had to stop:

- `This team has more notes than one picture can show.` Open a single note's
  graph instead — a few dozen nodes is the readable size, and a bigger cap would
  not help.
- `The picture filled up before the last hop.` Ask for fewer hops.
- `Not every link in the team was read, so an edge may be missing.`
- `N link(s) name a title two notes share` — those reach neither note and are
  not drawn.

`Nothing to draw yet. An org note's [[target]] is what makes an edge.` means
there are no edges, not that the graph is broken.

## Org files in and out

- **Download .org** writes the saved note as a file, which imports back
  unchanged.
- **Import .org…** takes one file: `#+TITLE:` becomes the title, `#+FILETAGS:`
  the tags, and the rest is the body, byte for byte. Only a leading run of those
  two keywords is consumed — a file starting with some other keyword keeps every
  line it has.
- **Export .md** / **Export .org** in the editor toolbar download *what is in
  the box*, draft and all, and compose no keyword lines. They are not the same
  button as Download.

## Paging

The list is a page of fifty, newest first, with a numbered pager. The total
counts what exists in the window rather than what you can read, so the last
page can be shorter than the count suggests.

Changing the page swaps the list only — it does not re-render the tab, so a
half-written note in the create form survives it.
