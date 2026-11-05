# Org-mode notes, and a graph of what they link to

Issues **#246** (notes should support orgmode) and **#247** (notes need a network
graph view). They are one feature and the order between them is forced, which is
the first thing to establish because it decides the whole shape.

**Nothing in this build links a note to a note.** `notes` carries `id`,
`team_id`, `owner_user_id`, `visibility`, `title`, `body` and two timestamps,
plus #245's `note_tags` join table. So #247 has no edge set: a graph drawn today
is either disconnected dots or a bipartite note↔tag projection, which is not what
Obsidian's graph is and not what was asked for. #246 is what creates the edges —
org's `[[target][description]]` link syntax — and #247 renders them. Starting at
#247 means inventing a link format inside a renderer, which is the wrong home for
it.

**This was already a parked question and the owner has now answered it.**
`research-graph-rag.md`'s out-of-scope list says of Markdown wiki-links:
*"Obsidian's graph is built from them; this one is built from extraction, which
is the difference between a graph a person maintains and one the platform
derives. … If the owner wants the authored half, say so — it is a note syntax and
a second mention source, and it is a different slice."* #246 and #247 are that
word. They also settle half of **RG‑14** from a different door: this is the
reading tool, not the question-answering one.

And **RG‑5's reconciliation rule, which it recorded as a thing nobody had asked
for, is now the sharpest decision in this document** — see ORG‑14. An authored
edge and a derived mention are two different kinds of statement, and the honest
first version does not draw them in one picture.

## What "orgmode compliant" means here, and what it does not

Decided with the owner, 5 Nov 2026: **a note's body may be org markup, and a note
imports and exports as a `.org` file.** A note stays ONE FLAT BODY.

What was declined, and why it matters that it was: the org **outliner data
model** — a headline tree per note, `:PROPERTIES:` drawers, TODO keywords and
state transitions, `SCHEDULED`/`DEADLINE` as typed dates. That is not a format
change. A note would stop being a flat body, and search, `15-editor.js`,
`note_tags`, `note-tools.rkt` and #247's own node set would all change shape with
it — the graph would become a tree of headlines rather than a graph of notes. It
is a second resource, and it is a different issue if anybody wants it.

So the whole of #246 is: a renderer, a link extraction, and two interchange
routes. No new resource, no change to how a note is authorized, and every
existing reader untouched.

## The decisions

### ORG‑1 — Markdown stays, and the format is a declared property of the note

`notes.format`, `'markdown'` by default, `'org'` opt in. **Not a replacement**:
every note that exists is Markdown and `mdRender` is the only renderer the e2e
gate's §3c sanitiser case covers. **Not auto-detected**, which is the tempting
version and is wrong on its first line: a body beginning `* something` is a valid
Markdown bullet AND a valid org headline, and the two render completely
differently, so a detector would silently change what somebody's note looks
like — and change it again the next time they edited the first line.

### ORG‑2 — Converting a note is a declaration, never a rewrite

`PUT /api/notes/:id {"format":"org"}` changes how the body is RENDERED and does
not touch the body. Running the org renderer over Markdown source produces a
readable mess rather than an error, which is honest and **reversible** — where a
conversion is neither, and a conversion that got one construct wrong would have
eaten the only copy.

### ORG‑3 — The renderer is `mdRender`'s own safety order, and it is tested in a browser

ED‑4's rule exactly: **escape first**, then the block and inline rules run over
escaped text and emit a closed set of tags, so nothing from the source is ever
passed through as markup. `orgRender` sits beside `mdRender` in `15-editor.js`
and **shares `esc` and `mdSafeUrl`** — a second copy of the URL scheme allowlist
is the drift this tree has paid for repeatedly, and it is the one piece of this
renderer where a divergence is a stored XSS rather than an ugly paragraph.

A Markdown renderer is effectively a sanitiser, so "does it escape" is a question
about what the code COMPUTES and cannot be answered by grepping it. The org
renderer gets its own runtime case in `demo-validate.mjs` §3c, calling the real
function on the real page with an `<img onerror>`, a `<script>`, an
`[[javascript:…][click]]` and its entity-encoded variant, and a `#+BEGIN_SRC`
block whose asterisks must stay literal.

### ORG‑4 — The subset is STATED, and anything outside it renders as its own text

In: headlines `*`…`******`; lists `-`/`+`/`1.`; `#+BEGIN_SRC`…`#+END_SRC` and
`#+BEGIN_EXAMPLE`; `*bold*`, `/italic/`, `_underline_`, `=verbatim=`, `~code~`;
`[[target][description]]` and `[[target]]`; tables (`|…|` with a `|---|`
separator); the `#+TITLE:` and `#+FILETAGS:` keywords; `:tag:tag:` trailing a
headline.

Out, deliberately: babel execution of any kind; `#+INCLUDE:` (ORG‑5); property
drawers and TODO keywords (the outliner model, declined above); footnotes; LaTeX
fragments; timestamps as a data type rather than as text. Each renders as its own
text, which is the honest failure for a preview.

### ORG‑5 — `#+INCLUDE:` is refused by name, not quietly inert

In real org it reads a file from the filesystem. Rendering it as plain text would
be safe and would leave an operator wondering why the content never appears, so
the renderer draws a visible refusal naming the directive. Same call as an
unknown theme token and an unknown classifier backend: a setting that silently
does nothing is the hardest thing on a surface to diagnose.

### ORG‑6 — A link's target is a note, and that is the only edge this creates

`[[<note id>][description]]` is an internal link and is what the editor's link
picker inserts, so the author sees a title and the stored target is stable across
a rename. A `http(s)://` or `mailto:` target renders as an external anchor
through `mdSafeUrl` and **creates no edge** — the graph is the team's own notes,
and an external URL already has a home that archives it (a bookmark, #191 slice
1). That narrowing is what keeps the entire edge set inside one authorization
domain.

A bare `[[Some Title]]` is resolved by exact, case-folded title within the team,
because that is what a person types. **An ambiguous title is a broken link that
says it is ambiguous** rather than one of the candidates: titles are not unique,
and picking one would make a link mean a different note depending on which was
created first. It is also why org-roam links by id.

### ORG‑7 — Links are EXTRACTED to a table on write, not parsed on read

`note_links(src_note_id, dst_note_id, team_id, label, raw_target)`, rewritten in
the same transaction as the body. #247 needs an edge set it can query and
authorize per row; parsing every note's body on every graph read is a `LIKE
'%[[%'` with a leading wildcard, which **PERF‑5 measured as unable to use its
index at all**. TAG‑2's argument for a join table over a delimited column,
arriving at a second asker.

### ORG‑8 — A broken link is stored as broken, with its raw target, and reported

A link to a note that does not exist is not the same as no link, and it is the
commonest failure this feature will have — somebody deletes a note. So
`dst_note_id` is nullable, `raw_target` is kept, and the renderer draws it
visibly broken. A link that silently became plain text is how a reader concludes
the editor ate their markup.

### 🔑 ORG‑9 — The edge is authorized at BOTH ends, at read time, and an unreadable one is INDISTINGUISHABLE from absent

A link row confers nothing — QUEUE‑3's rule, that the resource is authorized and
never the row. The graph read applies `can?` per note and then drops any edge
whose other end the caller cannot see.

**And unlike ORG‑8 it does not say that it dropped one.** "There is a note here
you may not read, and this one links to it" is an existence oracle on a
colleague's private note. So a broken link is reported and an unreadable link is
simply not there, and the two look different on purpose. KG‑3's rule, which is
what makes the knowledge graph trustworthy with no new authorization code.

### ORG‑10 — A cross-team target is treated exactly as a nonexistent one

`notes.id` is instance-global, so a link to another team's note id would resolve
in SQL. Extraction stores it as broken (`dst_note_id` NULL). Collapsing it into
ORG‑8's answer rather than ORG‑9's is deliberate and is the one place the two
rules meet: the reader learns their own link does not work, and learns nothing
about whether an id somewhere else in the instance exists. `repo-get`'s collapse
of a refusal and a miss into one answer.

### ORG‑11 — Interchange is `.org` in and out, and the file's keywords are the note's metadata

`GET /api/notes/:id?as=org` answers the body with `#+TITLE:` and `#+FILETAGS:`
composed in front of it, `Content-Disposition: attachment`, as the download path
already does for a repository object. `POST /api/notes/import` takes org text,
reads `#+TITLE:` as the title and `#+FILETAGS:` through `tags-clean` (TAG‑4's one
home, so an imported tag normalizes exactly as a typed one does), and the rest as
the body. **The round trip is asserted byte-identical for the body**, which is
the only property a user of this cares about.

### ORG‑12 — For an org note the BODY is the source of truth for tags, and `tags` on a write is refused

`#+FILETAGS:` is authoritative on every write, and `PUT /api/notes/:id
{"tags":[…]}` against an org note is refused with a message naming the keyword.
Two homes for one fact is the drift this tree names everywhere, and the home that
must win is the one the author can SEE — the body they are editing. A hand-edited
`#+FILETAGS:` line that did nothing would be worse than a refusal.

**Headline-level `:tags:` are rendered and NOT stored.** A headline is not a note
(that is the outliner model), so storing them would make a note's tag set depend
on a tree this build deliberately does not model.

**The cost is real and is stated rather than discovered**: #245's `note_autotag`
cannot work on an org note, because its write path is `notes-set-tags!`. It
refuses by name and says the remedy is `#+FILETAGS:`. A tool that rewrote the
body's keyword line is the obvious next decision and is not this slice's.

### ORG‑13 — #247's drawing: a seeded, fixed-iteration force layout, computed once, as inline SVG

Not d3: `script-src 'self'` blocks a CDN, so it would be ~280 KB vendored into
`static/console/`, and this console draws every other picture it has by hand.

Not RG‑9's deterministic radial layout either, and that is a standing decision
being narrowed rather than ignored. RG‑9 declined a force simulation for the
DERIVED graph on three grounds, and two of them do not survive the move to an
authored graph of tens of nodes: the dependency (answered by not taking one) and
the ~200 lines of physics (a Verlet integrator over a few dozen nodes is ~40).
**The objection that does survive is non-determinism**, because this project's
gates are its evidence and a layout no screenshot can reproduce and no e2e
assertion can pin a node in is a feature with nothing behind it. A fixed seed and
a fixed tick count answers it: the same input gives the same picture, and the
layout is computed once and drawn still, so there is no animation loop holding a
session open against #38's idle clock (QVIZ‑6).

### 🔑 ORG‑14 — The notes graph is NOT joined to the knowledge graph

RG‑5 recorded that mixing them "needs a reconciliation rule nobody has asked
for". The rule is: **there is no reconciliation, and they are two screens.**

An authored edge is what a person asserted. A derived mention is what a model
read out of a document, bound to the version it was read from. They are different
kinds of statement, with different warrants, and drawing them in one picture leaves a reader
unable to tell which is which — in a product whose knowledge graph earns its
trust precisely by saying where every fact came from. One of the two would have
to be drawn as weaker, which is a visual encoding of a distinction the data
already carries better.

Whether they ever meet is its own decision. The honest first version keeps them
apart, and this is the recorded answer rather than another deferral.

### ORG‑15 — Backlinks come free and are the half people actually use

`note_links` read in reverse is "what links here", one query, same authorization
rule as ORG‑9. In org-roam and Obsidian this is used far more than the graph
picture is, and it ships in the same slice as the table rather than waiting for
the drawing.

### ORG‑16 — The graph read is bounded, defaults to a neighbourhood, and reports both

CLS‑27 and VEC‑29's rule. A team with five thousand notes cannot be drawn at all
and must not try: the node set is capped, `truncated` reports BOTH ways of
stopping (the cap, and a neighbourhood that filled it), and the default view is
the neighbourhood of ONE note — RG‑9's own argument, that a whole-graph map is
unreadable past a few dozen nodes under any layout whatsoever. A whole-team view
sits behind an explicit control.

## What does not change, which is most of it

`can?` on a note, the visibility triple, `notes:read`/`notes:write`, the tag
vocabulary and its normalization, `search-all`'s coverage of `notes.body`, the
editor's `edRows`/wrap/preview preferences, and every one of #245's tools except
`note_autotag`'s refusal above. There is no new permission and no feature switch:
both renderers ship on every instance, because a format is not a capability.

An org note's markup is in its body, so a keyword search for `[[` matches it.
Stated rather than fixed — stripping markup before indexing would mean a second
parser on the write path, and the alternative nobody wants is a search that
cannot find text that is on the screen.

## The build plan

1. **The format and the renderer** — `notes.format` (migration `0073`),
   `orgRender` beside `mdRender`, the ORG‑4 subset, ORG‑5's refusal, the §3c
   runtime sanitiser case. No new table. Independently useful: an org user can
   keep org notes the day it lands.
2. **The links** — `note_links` (migration `0074`), extraction inside the body
   write, backlinks on the note detail, and the ORG‑8/ORG‑9 asymmetry with a
   positive control for each. Independently useful; **and it is #247's
   prerequisite**.
3. **The interchange** — `?as=org` and `POST /api/notes/import`, ORG‑11's
   byte-identical round trip. Independent of 2 and of 4.
4. **The graph** — #247. ORG‑13's layout, ORG‑16's bound and neighbourhood
   default, the e2e assertion that pins a node.

Slices 1 and 2 are #246. Slice 3 is #246's other half and needs nothing from
slice 2. Slice 4 is #247 and needs slice 2.

## What this document does not promise

That a force layout is more legible than a radial one — nobody has measured it,
and ORG‑13 rests on the owner having asked for the Obsidian look rather than on a
number. That the org subset is enough for an org user's real files; it is a
subset, it is stated, and the first import of somebody's actual notes is what
will say which construct is missing. And that an authored graph improves anything
measurable — unlike RG's slice 5, there is no recall question here, because this
graph is a navigation surface and not a retrieval index.
