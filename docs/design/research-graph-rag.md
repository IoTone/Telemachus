# Research tools over a knowledge graph

**Issue #191. This document is the deliverable; no code ships with it.** It is
the same shape as `ai-queue-visualization.md` (#184) and `vector-store.md`
(#189): the decisions first, the measurements that settle them where there are
any, and a build plan at the end that somebody can start from.

Decisions **RG‑1…14** are recorded in `docs/design/decisions.md`. They sit on
top of the **RSCH** block proposed 13 Oct 2026, which this document revises
rather than replaces — the first section says how.

## What the issue asks for

> Build up a list of bookmarked URLs of the knowledge you are using… distill
> knowledge from these URLs and the information contained at the other end.
> Then we want to be able to view our knowledge graphs… visual graphs, apis to
> talk to our knowledge graphs, and some query tools.

And the reason, which is the part that decides the storage question:

> That old CERN philosophy about the permanence of links is being eroded.

So: four things — a curated set of URLs, a distillation, a view, and a way to
ask questions of it — and a stated motive of **permanence**.

## RG‑0 — What changed since RSCH was written, and it is the expensive half

The RSCH block closed by saying: *"the order is BYOK‑2 → ZDR‑2 → RSCH‑3.
RSCH‑3 is the expensive one, because an SSRF-safe fetcher is the whole cost of
the research surface and the rest of that loop is assembly."*

**That fetcher exists.** `domain/net/fetch.rkt` was built for #142 (EGR‑1…8) and
#114's feeds: one outbound seam, a caller-supplied trust policy defaulting to
`'untrusted`, DNS resolved by NAME with the socket's real **peer** vetted before
a byte is written (which is RSCH‑3's property without RSCH‑3's broken mechanism
— connecting to a resolved literal breaks TLS verification and SNI), a byte cap,
a timeout, a redirect cap, credentials withheld off-origin, and `safe-url`
redacting the query on the way **into** the exception. It is not the only thing
that landed in the seventeen days since RSCH was proposed:

| RSCH said it needed | what exists now |
|---|---|
| an SSRF-safe fetcher (RSCH‑3) | `domain/net/fetch.rkt`, `'untrusted` by default (FEED‑4) |
| a report as a repo object (RSCH‑2) | unchanged and still right; `repo-derive!` is the shared writer (QUEUE‑9) |
| citations refused, not footnoted (RSCH‑4) | `domain/help/answer.rkt` implements exactly this, twice over (HELP‑15, HELP‑22) |
| a recurring job (FEED‑3) | `job_schedules`, #135/#140 |
| retrieval over a corpus | the whole of #189 — chunker, vectors, sealed column, scan, `passages-for` |

So **#191 is assembly plus one table, one renderer and one retrieval seam.** It
is no longer gated on the hard security work, and the slice plan below reflects
that.

**RSCH‑5 is the other thing that changed, and it is a standing debt.**
`research:use` is granted to member, admin and owner, its description says "Use
the research surfaces", and **nothing reads it** —
`test/route-perm-gate-tests.rkt` lists it in `UNREACHABLE-BY-DESIGN` with the
reason *"no research surface is built; chat:use gates the model paths"*. That is
#113's shape, and that list **fails in both directions**: the first slice that
enforces `research:use` must delete the entry in the same commit, or the gate
fails. Which is the gate working.

## RG‑1 — A bookmark is a repository document, and a typed row holds the URL

The bytes go to the repository: `research/<host>/<slug>-<id8>.<ext>`,
`content_type` as served. That buys visibility, grants and sharing, search over
extracted text, `?semantic=1`, retention and the cascade delete, "Processed by",
`storage.bytes`, the audit trail for reads, and the put-hook trigger seam —
every one of them with no new code. Same call RSCH‑2 made for a report and
FEED‑1 for a pulled item, and `0022-fold-documents` settled the general case.

**The URL itself needs a typed row**, and the argument is QUEUE‑1's: there are
questions `repo-list` cannot answer, and LAY‑4 attributes cannot answer them in
SQL either, because an attribute value is a string and the vocabulary is
equality.

| the question | what it needs |
|---|---|
| have we already bookmarked this URL? | `UNIQUE(team_id, url_canon)` |
| which bookmarks are stale? | `ORDER BY fetched_epoch ASC` |
| did it change since last time? | `etag`, `last_modified`, `content_sha256` |
| did the last fetch fail, and how? | `last_status`, `last_error` (sealed) |

`research_sources` is the feed row's shape for a bookmark: a typed row for the
thing being watched, repository objects for what came back. One deliberate
difference — **no credential column**. A feed has one because an operator
configures a feed against an API; a bookmark is a public page a person was
reading, and a sealed credential on a member-writable row would put FEED‑5's
machinery behind a surface where the trust argument does not hold (RG‑3).

**The canonical URL is the identity, and canonicalization is narrow on purpose**:
lower-case the scheme and host, drop a default port, drop the fragment, and
nothing else. No tracking-parameter stripping, no trailing-slash normalization,
no sorting the query — every one of those changes which resource is addressed on
some real site, and the failure is silent (two bookmarks collapse into one, or
one page is archived twice). A person who pastes two spellings of one URL gets
two rows, which is visible and fixable; a platform that merges two different
pages is neither.

## RG‑2 — Permanence is the content-addressed store plus versioning, and it is already built

This is the issue's actual motive and it needs **no new mechanism at all**.
Blobs are keyed by SHA‑256 and a repository object is a sequence of versions, so:

- a fetch writes a **new version of the same key**, never a new object. That is
  the whole of it: the old bytes remain, addressable, and "what did this page say
  when I bookmarked it" is a version read.
- a re-fetch of **identical** bytes dedups to the same blob, so watching a stable
  page costs one row and no storage.
- the archive cannot silently rot, because the digest is the name.

Two things the slice must get right, both of which this tree has paid for once:

- **the same KEY on a re-fetch.** A new object per fetch gives N documents nobody
  can diff and N entries in search for one page.
- **`#:derived?` on the put**, or an opted-in trigger fires on the pipeline's own
  output — the defect DWF‑3 found when a trigger on `application/json` fired 50
  times on its own extracted JSON.

**What this does NOT archive, stated rather than implied:** the bytes the fetcher
received, not the page a browser renders. A single-page application archives as
a loader shell. Fixing that means a headless browser in the image, which this
project has now declined three times — HPDF‑1 on the merits (no CSS paged media,
no PDF/A, a JavaScript engine running somebody else's page), OFFICE‑1 and
`container.md` on the ~1 GB. A bookmark of a JS-rendered page should be a saved
reader-mode copy the person uploads, which the repository already takes.

## RG‑3 — The egress policy attaches to who chose the URL, and a bookmark is `'untrusted` with no escape hatch

FEED‑4 settled the rule: *"the policy belongs to the CALLER — `'untrusted` by
default… the rule attaches to who chose the URL, not to where it points."* A
feed URL is **operator**-authored behind `feeds:manage`, which is the same trust
as `TMACH_MODEL_URL` or an MCP server, so a feed may be `'trusted` and reach
inside the network — which is what #114 explicitly asked for.

A bookmark is **member**-authored. So this is the first URL this platform fetches
that an ordinary team member chose, and the honest reading is that it is exactly
as untrusted as a model-chosen one in the respect that matters: a member can
type `http://169.254.169.254/latest/meta-data/`, and nothing about being
authenticated makes that request safe to make. **There is no `'trusted` mode on
this surface**, not even for an operator — an internal page that should be
archived is a feed, which already has the right trust argument and the right
permission. Adding a flag here would put an SSRF switch behind `research:use`,
which a plain member holds.

The one thing that IS member-visible and must stay redacted: `last_error`.
`safe-url` already drops the query on the way into the exception, and the column
is sealed for #83 r4's reason (this platform's own code quotes what it choked
on).

## RG‑4 — Distillation is a workflow over the fetch, not a mode of it

CLS‑24's rule, for CLS‑24's reasons. A `distil: true` flag on a fetch tool would
be one tool call doing unbounded work: no per-document retry, no cancel
granularity, no quota admission between documents, and a step output that is a
list of N results nothing can route on.

So: `research_fetch` (no model, no budget — it fetches and stores) and a
`distil-bookmarks` workflow that `map`s the stale set through `doc_text` →
`doc_classify` → `kg_extract`, which are **all three already built**. The batch
is small for CLS‑24's measured reason: every document may be a model request
against a 200/day `ai.requests` default, so 25, not 40.

**The distillation produces nothing new in the schema.** The summary is
`<key>.distilled.md` through `repo-derive!`; the facts go into the knowledge
graph; the passages come from `repo_chunks`. Three existing homes, no fourth.

## RG‑5 — The graph is the knowledge graph, and a distilled bookmark is another document in it

There is no second graph. `kg_entities` / `kg_relations` / `kg_mentions` already
hold the shape the issue asks for, and KG‑3 is the property that makes a
bookmark graph trustworthy without new authorization code: **nothing enters
without a source, and visibility is the source's.** A fact extracted from an
archived page carries a mention whose `object_id` is that page and whose
`version_id` is the version it was read from — so "where did this come from" is
a URL *and a point in time*, which is more than a bookmark manager can say.

The entity browser exists too (`static/console/13-kg.js`), with relations and
every mention linked to its document. What #191 adds is a drawing (RG‑9) and a
question-answering seam (RG‑6), not a data model.

## RG‑6 — Graph‑RAG is a JOIN this schema already supports, and the seed is an argument

This is the one genuinely new piece of retrieval, and it needs **no table and no
second vector**:

- `kg_mentions` carries `(object_id, version_id)`.
- `repo_chunks` is keyed by `(object_id, version_id, idx)` (#189 step 4).
- `chunks-nearest` (`domain/ai/chunksearch.rkt`) scans a bounded window, filters
  by model in SQL, joins on `o.current_version_id`, and applies `can?` per row
  with a memo over `AUTHZ-HEADROOM` candidates (#189 step 5).
- `passages-for` (`domain/repo/passages.rkt`) turns chunks into quotable text
  with offsets that resolve to a page and a bbox through `spans-covering`
  (CHUNK‑1, #189 step 6). **Its own header already names #191** as one of the
  two callers its passage limits were sized for, which is the ordering working
  rather than a coincidence.

So graph‑RAG is: pick a seed, expand it over the graph, collect the objects the
mentions name, and **restrict `chunks-nearest`'s window to those objects**. The
new code is a window restriction on an existing scan plus a composer.

**The seed is an argument, because two different questions want opposite
directions**, and one seam is what keeps the budget, the `can?` and the citation
rule in one place — VEC‑33's two-askers-one-answer, which is why `passages-for`
exists at all:

| the question | the seed | what expansion buys |
|---|---|---|
| "what do we know about Acme?" | **graph-first** — `kg-find` on the name | the passages behind every fact, not just the ones whose words match |
| "what have we read about supply-chain risk?" | **vector-first** — `chunks-nearest` for a seed set, then the entities those chunks mention | the neighbours of what matched, which is the half plain retrieval misses |

Plain `repo_retrieve` already answers the second question *without* the
expansion. **The expansion is the whole claim of graph‑RAG and it is unmeasured
here**, exactly as the chunk size was before #189 step 3 — so the build plan ends
with a calibration against `test/calibration-questions.json`'s shape, and the
claim stays "this is what it does" until there is a recall number. CHUNK‑10's
lesson: the parameter that looked like the lever was not, and only the
measurement said so.

## RG‑7 — The traversal is bounded, and every bound is reported

`kg-neighbourhood` already clamps hops to 2, and that is the right ceiling rather
than a timid one: on a graph with a few hub entities the 3-hop neighbourhood is
the whole graph, and a retrieval window that is the whole corpus is `chunks-nearest`
with extra steps and a worse budget. Beside it: a cap on entities collected, a
cap on objects whose chunks are scanned, and `truncated` saying **which** bound
was hit — CLS‑27 and VEC‑29's rule, and here the two have different remedies
(ask a narrower question, or the graph has a hub that wants splitting).

## RG‑8 — Two authorization rules compose, and the shortening must be reported

KG‑3 (an entity is visible only through a mention on a readable object) and
VEC‑28 (a chunk is scanned only on a current version of a readable object)
compose correctly: a walk cannot learn a private document's facts, and the
retrieval cannot quote one. Nothing new is needed.

The one new consequence is worth a field. **A traversal can be legitimately
shorter for one reader than another**: an entity reachable only through a
colleague's private document is invisible, so the path through it does not
exist. That is correct, and silently shortening the answer is the failure —
VEC‑28's recall hole in a second place. `withheld` reports it, and VEC‑28's own
`k × 4` headroom applies to the restricted scan too.

## RG‑9 — The visual graph is a deterministic layout drawn by hand

KG‑6 declined a graph library. #184 has since established that this console
draws its pictures by hand in inline SVG, inheriting the theme tokens, under
`script-src 'self'` with no `'unsafe-inline'` — so a CDN library is blocked by
policy and a vendored one is a third-party dependency.

**A force-directed simulation is the obvious Obsidian-like thing and is the
wrong trade**, on three counts and not on taste:

- it needs an **animation loop**, on a console that deliberately polls nothing
  (#38's idle clock counts from the last request, which is QVIZ‑6's whole
  argument) and whose slowest tab is already measured;
- it is **non-deterministic**, so no screenshot can be compared and no e2e
  assertion can pin a node's position — this project's gates are its evidence;
- it is a library or ~200 lines of physics, for a view of at most a few dozen
  nodes.

**A radial layout, one ring per hop around the selected entity**, is
deterministic, O(n), assertable, themed for free, and is exactly the shape
`kg-neighbourhood` already answers. Edges are straight lines with the predicate
as a label; a node's size is its mention count; clicking a node re-centres,
which is the neighbourhood read again.

The cost, stated: **it is a neighbourhood view, not a map of the whole graph.**
A whole-graph map of five thousand entities is unreadable under any layout, and
the drag-and-arrange canvas Obsidian is loved for is a plugin's — LAY‑12's
standing decision, and the authenticated bundle surface (#20, #43) is the seam
it would use.

## RG‑10 — The answer's citation rule is #183's, and it moves to one home

RSCH‑4 said a claim whose source is not in the fetched set is **refused, not
footnoted**. `domain/help/answer.rkt` implements that and one more layer #183's
only real-model run had to discover:

- **a score floor before any model call**, so an answer is not composed over
  passages nothing retrieved (HELP‑15);
- **every cited path resolved against the passages actually offered**, with an
  invented one dropped and reported;
- **an answer that cites EVERY passage it was shown has cited nothing** —
  `unfocused` (HELP‑22), found because `qwen2.5:7b` refused correctly and then
  named all five sources by way of explaining what they were about.

A second copy of those three rules is `executor-can-run?`'s drift in the worst
available place, because the failure is a reader following a citation to a page
that says something else. So the verification moves to one module with two
askers, which is the move `passages-for`, `repo-fields-declare!` and
`repo-derive!` each made when their second caller arrived.

**The seam is there and the export is not.** `answer.rkt` already keeps the
floor and the inventory rule behind named constants (`HELP-SCORE-FLOOR`,
`HELP-INVENTORY-MIN`, `HELP-ANSWER-REASONS`) and `help-cited-paths` is exported
for its own tests — so what the move costs is extracting the resolve-and-judge
step from `help-answer`, which currently also owns the prompt, the retrieval and
the locale filter. Those three stay corpus-specific, as does the floor's
**value**, which HELP‑15 records as model-dependent and provisional. And
`HELP-ANSWER-REASONS` is a closed vocabulary (#123's rule): a research answer's
reasons overlap but are not identical, so the shared module owns the two it
really shares — `uncited` and `unfocused` — and each caller keeps its own for
"there is no corpus".

## RG‑11 — `research:use` gets teeth, and the gate's allowlist loses an entry

Enforced on the research routes. The entry in `UNREACHABLE-BY-DESIGN` goes in
the same commit, and `doc.perm.research:use`'s description stops asserting a
surface that does not exist — which costs `strings.json`, `en.json`, `ja.json`
and both rendered reference trees, as RSCH‑5 already noted.

`chat:use` is **also** required where a model is called (VEC‑35's rule for
`?semantic=`: asking a question spends the team's AI allowance), and the two are
not redundant — `research:use` is about the surface, `chat:use` about the spend,
and a team may legitimately want the archive and not the answers.

## RG‑12 — Re-fetching is crawling, and only that half gets a courtesy delay

`robots.txt` is deliberately **not** consulted for a person-initiated fetch: the
person is reading the page, not crawling it, and a robots check would refuse
pages they can legitimately open in a browser. A **scheduled re-fetch** is
different in kind — it is automated, repeated and unattended — so that is where a
per-host delay and a rate cap belong, and it is **off unless configured**, which
is every default-bearing knob's rule here (DEL‑9, PULL‑15a, ANCHOR‑7). An
instance that quietly began crawling the web on a timer after an upgrade would be
the #119 shape at its worst.

The copyright and terms question is the operator's and is stated rather than
solved: the platform fetches what it is told to, archives what it received, and
records who asked.

## RG‑13 — What this design deliberately does not include

- **Web SEARCH.** RSCH‑1 put the backend behind a plugin-registered tool because
  it is deployment-specific (a self-hosted SearxNG, a vendor API), and #191 asks
  for *bookmarks a person curates*, which is the opposite of a search loop. The
  Think → Search → Extract → Synthesize loop remains RSCH's, unbuilt, and is
  **easier** after this: it is this retrieval seam with a different source of
  URLs.
- **A headless browser**, for RG‑2's reasons.
- **A whole-graph canvas**, for RG‑9's.
- **A second graph store.** No property graph, no triple store, no ArangoDB. The
  measurement that settles it is #189's: a full scan over `repo_chunks` is 8 ms
  at 1,000 chunks and 759 ms at 100,000, and `vector-store.md` says to revisit at
  50,000 chunks for one team. A graph of a team's bookmarks is smaller than that
  by an order of magnitude.
- **Markdown wiki-links** (`[[like this]]`). Obsidian's graph is built from them;
  this one is built from extraction, which is the difference between a graph a
  person maintains and one the platform derives. Both are defensible and they are
  not the same product; mixing them would need a reconciliation rule nobody has
  asked for. **If the owner wants the authored half, say so** — it is a note
  syntax and a second mention source, and it is a different slice.
- **An OpenMetrics rendering**, for QVIZ‑9's reason.

## RG‑14 — The question for the owner, before slice 3

Slices 1 and 2 are unambiguous: a bookmark archives, and a distillation feeds the
graph the platform already has. **Slice 3 is where the product forks**, and the
fork is the one #191 names by mentioning Obsidian and orgmode in the same
sentence as graph‑RAG:

- **a reading tool** — the graph is how you navigate what you collected, and the
  value is the neighbourhood view and the provenance (which page, which version,
  which sentence);
- **a question-answering tool** — the graph is a retrieval index, the value is
  the cited answer, and the drawing is a debugging aid for it.

They want different slices next: the first wants RG‑9 and a bookmarks screen,
the second wants RG‑6 and RG‑10. Both are in the plan and the order is the
owner's. Nothing below slice 2 should be started on a guess.

## The build plan

1. **The bookmark** — migration `research_sources`, `research_fetch`, three
   routes behind `research:use`, and the `UNREACHABLE-BY-DESIGN` entry deleted.
   Verifiable without a model: the archive, the re-fetch as a new version, the
   dedup, the `'untrusted` refusal of private address space. The egress refusals
   are the cases to write first.
2. **The distillation** — a `distil-bookmarks` workflow over tools that already
   exist. No new tool but `research_list_stale`. The graph fills by itself.
3. *(the fork — RG‑14)* **either** the neighbourhood drawing and a bookmarks
   screen, **or** the graph‑RAG retrieval seam and the shared citation verifier.
4. **The other one.**
5. **The calibration** — does graph expansion improve recall over plain
   `repo_retrieve`, measured in both languages, on the shape of
   `test/calibration-questions.json`. Until this exists, graph‑RAG is a
   described mechanism and not a demonstrated improvement, and the documentation
   should say exactly that. CHUNK‑10 is the precedent: the hypothesis was sound
   and the measurement disconfirmed it.

Slices 1 and 2 are independently useful and need no decision from slice 3: an
archived, searchable, extracted set of bookmarked pages with per-version
provenance is the issue's permanence requirement met, and every existing reader
— keyword search, `?semantic=1`, `repo_retrieve`, the knowledge graph, the
document pipeline — picks it up with no further work.
