# Documents

A text document you write here: a title, a path, a body in the
[editor](editor.md), and a visibility.

**A text document is a repository object.** There is no separate documents
store — what this screen creates is the same kind of thing the
[Repository](repository.md) screen lists, with a Markdown content type and your
title as its filename. This screen is the one that lets you *write* one; that
one is the one that lets you upload any format and share it.

## Creating one

**New document** asks for:

- **Title**
- **Path** — optional. `A path ending in / files it into a project; the
  filename comes from the title. Blank means documents/.`
- **Content** — the editor
- **Visibility** — the same three choices as a [note](notes.md)

Open one and the card offers **Edit**, **Export .md** and **Delete**.

## Paths

The path strip above the list walks the project tree: **All paths**, then a
crumb per folder, then the folders inside the one you are looking at.

- A folder is **a prefix of the paths that exist**, not a stored record. It
  cannot be empty and it stops existing with its last document.
- `Nothing filed here yet.` means this folder holds nothing you can read, not
  that the folder is wrong.
- `More paths than fit one listing — open one to narrow it.` means the folder
  list had to stop.
- **A document keeps its path.** The edit card says so: there is no move. In a
  content-addressed store a move would be a new object plus a delete, which
  would break every share, every derivation record and every link pointing at
  the old one.

Uploading or saving to a path that already exists keeps the old copy as a
**version** rather than replacing it.

## What this screen lists

Documents of a text content type that nothing else derived. A `.form.md` a
workflow rendered, or an extracted `.json`, is somebody's **output** and belongs
on the [Repository](repository.md) screen with its source beside it — so it is
not in this list, even though it is a document.
