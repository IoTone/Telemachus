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

**What slice 1 shipped of this, and what it deliberately did not.** The renderer
sends an `http(s)`/`mailto:` target through the shared allowlist and draws an
anchor. An INTERNAL target is drawn as a marked span and NOT an anchor: nothing
resolves a note id or a title yet, and the console's router has no note route, so
an `<a>` there would be a link that goes nowhere — which is worse than a marker
that says what it is. Slice 2's extraction is what resolves it, and slice 4 is
what makes it navigable.

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
`raw_target` is kept and the renderer draws it visibly broken. A link that
silently became plain text is how a reader concludes the editor ate their markup.

🔑 **The decision above is kept exactly and the COLUMN it first named is not, and
the reason is worth reading before anybody adds one back.** This said
"`dst_note_id` is nullable"; slice 2 stores no resolution at all, because a
stored one is a copy of a decision that the NOTES change underneath it. Two
things decided it. Deleting the target leaves every stored id a lie until
something nulls it — survivable. And **somebody writes `[[Levee 7 survey]]`
BEFORE creating that note**, which is exactly how org-roam is used: a stored NULL
never heals, so the link would stay broken for ever while the note it names sat
in the same team. Healing it means re-resolving on create, on rename and on
delete — three statements and an invariant to keep — which is the shape RG‑23,
TAG‑1, PATH‑1 and the Localization Manager's `missing`/`stale` all refuse.

So what is stored is the target AS WRITTEN plus its fold, written once in the
same INSERT and never updated, and the resolution is an indexed equality at read
time. **ORG‑7's objection is satisfied in full**: the expensive half — parsing a
body — happens on write, and what PERF‑5 measured was a leading-wildcard `LIKE`
over bodies, not a lookup. `target_fold` is deliberately not the drift shape it
resembles: it is a pure function of `raw_target`, written beside it, and neither
is ever rewritten, so they cannot come apart. A resolution can, and that is the
one thing not stored.

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

**Built, with four things decided in the building:**

- **The import's body IS the file**, not a JSON field. An importer runs
  `curl --data-binary @note.org`, and making them escape a whole file to reach a
  route whose entire input is that file would be a surface nobody uses.
  `?visibility=` carries the only other thing a create needs. **One file per
  call**: a bulk form would have to decide what a partial failure means.
- **Only a LEADING run of the two keywords this understands is consumed.** A
  file whose first line is `#+OPTIONS:` keeps every line it has — eating a
  foreign file's keywords silently would be worse than leaving its title in the
  body, where `orgRender` draws it as the heading anyway.
- **Tags split on org's own `:`**, which round-trips a tag org's own grammar
  would not have allowed (org tags carry no spaces; a #245 tag may be
  `levee 7`). A colon-free value is split on whitespace, because that is the form
  files written elsewhere use — and this platform's export always writes the
  colons, so the ambiguity cannot arise from a round trip.
- **Any format is exportable.** A Markdown note in an org envelope is still a
  readable file, and refusing would make "give me this note as a file" depend on
  a declaration that says nothing about whether somebody wants one.

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

🔑 **Built, and two things about it were only settled by building it.**

**An ABSENT `#+FILETAGS:` line is not a line saying "no tags".** A line that is
there is authoritative, including when it is empty — that is how a body clears
them. A line that is NOT there says nothing and leaves the stored set alone. The
split is `#:tags #f` vs `'()` exactly, and without it ORG‑2's own rule would
destroy data: a conversion never rewrites the body, so a converted note has no
keyword line, and "absent means none" would have silently dropped the whole tag
set the first time somebody saved it.

**An import is the one other reader of that same home, and it needs its own
keyword.** `POST /api/notes/import` strips the leading keyword block to keep the
body byte-identical, so by the time the create runs the line that carried the
tags is gone — the import therefore hands them over as `#:filetags`, which is
ORG‑12's home reached from a file rather than a second home. The e2e gate found
this: the unit test had passed because its fixture's body happened to carry a
`#+FILETAGS:` line of its own.

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

### 🔑 ORG‑9a — AN UNREADABLE FAR END ANSWERS AS A NONEXISTENT ONE (correction, 7 Nov 2026)

**ORG‑9 as slice 2 shipped it did not hold, and the way it failed is worth more
than the fix.** The rule was enforced by DROPPING an edge whose far end the
caller may not read — no count, no placeholder, no field — which reads as the
strongest possible answer and is an oracle, because **ORG‑8's report is the
baseline**. Silence is itself a signal. Measured on a team where the owner has a
private note titled "Secret plan" and a plain member has neither:

| the member writes | slice 2 answered |
|---|---|
| `[[Secret plan]]` | `()` — nothing at all |
| `[[No such thing]]` | `broken`, reason `missing` |

So the member learns from the ABSENCE of a broken marker that a note with that
title exists in their team and is not theirs. **And the second order needed no
comparison with a baseline**: once the member created their own note of that
title, two notes shared the fold and the link answered **`ambiguous`**, which
states outright that there is another note of that title they cannot see.

The fix is one line of placement, not a new rule: **`team-note-index` is the
CALLER'S view of the team.** A target the caller may not read is then not in the
index and resolves exactly as a nonexistent one does, and the caller's own note
is the unique holder of its fold in the only view that matters. **ORG‑10 had
already applied this exact rule inside `resolve-target` for a CROSS-TEAM
target** — "treated exactly as a nonexistent one" — so what was missing was that
rule reaching the case written next to it. `repo-get`'s collapse of a refusal
and a miss.

Three things this cost, all of them instructive:

- **The slice-2 test asserted the defect.** "The private one is simply gone"
  passed, and the case even checked that the private note's title appeared
  nowhere in the answer — which it now does, as the RAW TARGET the author typed
  themselves. The honest property is not "it is absent" but "the two answers are
  indistinguishable", which is strictly stronger and is what is pinned now, in
  the unit suite and over HTTP. The HTTP assertion normalizes the target out and
  compares the two bodies, because a grep cannot say "these are the same".
- **The guard moved and did not multiply.** With the index filtered, the branch
  testing readability in `note-links-of` is #110 r1's redundant guard, and worse
  than redundant: a reader would take it for the place the rule lives when the
  two outcomes must be ONE answer. There is deliberately no branch for "exists
  and is not yours".
- **Ambiguity still works where it is REAL.** Two notes the caller CAN read
  sharing a fold is a link that reaches neither (ORG‑6), and that had to survive
  the oracle being closed; it has its own assertion.

The cost is one `can?` per note in the team on a links read, stated rather than
hidden: both readers already scanned the whole team's notes, and `notes-list`
applies per-row `can?` over the same set on every listing. A SQL predicate would
be faster and would be `can?`'s rule written a second time.

### ORG‑15 — Backlinks come free and are the half people actually use

`note_links` read in reverse is "what links here", one query, same authorization
rule as ORG‑9. In org-roam and Obsidian this is used far more than the graph
picture is, and it ships in the same slice as the table rather than waiting for
the drawing.

**Built, and the e2e gate corrected one thing about it that reasoning had not.**
Both spellings of a note are asked for — its id and its folded title — and an
inbound TITLE link is suppressed while that title is ambiguous, because such a
link resolves to neither note and a backlink on a note the link does not reach
would be a lie. And the two columns of the console's panel are gated
DIFFERENTLY: outgoing links exist only for an org body, while **backlinks exist
for any note**, since a Markdown note is linked to by an org one just as
readily. Gating the whole panel on the note's own format hid every backlink on
every Markdown target — which is most of a team's notes.

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

1. **The format and the renderer** — **BUILT** (5 Nov 2026). `notes.format`
   (migration `0073-note-format`), `orgRender` beside `mdRender` sharing
   `escBody` and `mdSafeUrl`, the ORG‑4 subset, ORG‑5's refusal, the §3c runtime
   sanitiser case, and `test/note-format-tests.rkt` for the column and ORG‑2's
   promise. No new table, no new permission and no feature switch. An org user
   can keep org notes today.
2. **The links** — **BUILT** (5 Nov 2026). `note_links` (migration `0074`),
   `domain/notes/org-links.rkt` for the syntax and the fold, extraction inside
   the body's own transaction, `GET /api/notes/:id/links` carrying both
   directions, the panel on the note detail, and the ORG‑8/ORG‑9 asymmetry with a
   positive control for each (`test/note-links-tests.rkt`, 19 cases, ten
   controls). **#247 now has its edge set.**
3. **The interchange** — **BUILT** (6 Nov 2026). `?as=org` and
   `POST /api/notes/import` (whose body IS the file),
   `domain/notes/org-file.rkt`, ORG‑11's byte-identical round trip asserted over
   eight body shapes and over the STORED bytes, and ORG‑12 in full — the
   `#+FILETAGS:` authority, the refusal of a `tags` field, and `note_autotag`
   declining an org note before it calls the model.
   `test/org-interchange-tests.rkt`, 19 cases, nine controls.
4. **The graph** — **BUILT** (7 Nov 2026), which closes **#247**. `note-graph`
   in `notes.rkt` beside the two link readers — a THIRD reader of one edge set,
   in that module because `team-note-index` IS the caller's own view and
   `resolve-target` is the one place a stored target becomes a note.
   `GET /api/notes/graph` above the `:id` patterns, and
   `static/console/21-notegraph.js`: ORG‑13's seeded fixed-iteration
   Fruchterman-Reingold as inline SVG, run once and drawn still — **no
   `requestAnimationFrame`, no `Math.random`, no timer**, which is QVIZ‑6 as
   well as the gates. ORG‑16's cap, neighbourhood default and three-member
   `reason` vocabulary. **No migration, no new permission, no new environment
   variable.** `test/note-graph-tests.rkt` (11 cases, eight controls), six
   console cases with eight controls, 24 HTTP assertions, and
   `demo-validate.mjs` §3c6, which **pins a node by name** — the assertion
   ORG‑13's whole argument rests on, and whose own control (a `Math.random`
   jitter) fails it by name.

Slices 1 and 2 are #246. Slice 3 is #246's other half and needs nothing from
slice 2. Slice 4 is #247 and needed slice 2 — and, as it turned out, needed
ORG‑9a, because the drawing has a node for an unresolved target and slice 2's
resolution would have made that node an oracle.

## What this document does not promise

That a force layout is more legible than a radial one — nobody has measured it,
and ORG‑13 rests on the owner having asked for the Obsidian look rather than on a
number. That the org subset is enough for an org user's real files; it is a
subset, it is stated, and the first import of somebody's actual notes is what
will say which construct is missing. And that an authored graph improves anything
measurable — unlike RG's slice 5, there is no recall question here, because this
graph is a navigation surface and not a retrieval index.
