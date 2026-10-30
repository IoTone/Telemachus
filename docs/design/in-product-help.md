# In-product help: a chat box grounded in our own documentation

Issue #183. Status: **BUILT, both slices.** Slice 1 is the corpus, its ingest
and the nearest-passage read; slice 2 is the answer — the two-layer refusal, the
citations, `POST /api/help`, `ai.help.total` and the console overlay.

Decisions **HELP‑1…21** are in `docs/design/decisions.md`.

## What was already there, and what was missing

#183's own reading was that "the feature is mostly assembly", and that was very
nearly right. What existed:

- `docs/` — 63 English Markdown files and 26 Japanese, gated for drift where it
  is generated and prose where it is not.
- The chunker (`domain/ai/chunk.rkt`, CHUNK‑1…9), the vector arithmetic
  (`domain/ai/vectors.rkt`, VEC‑11…17) and the embedding wire
  (`embed-exchange`, EMB‑1…11).
- `chunksearch.rkt` + `passages.rkt` (VEC‑26…40) — a nearest-chunk read over a
  team's documents, with a citation.

What was missing was the thing #183's own question 4 named: **embeddings did not
exist** when the issue was filed. They do now, so the retrieval half of this is
the one a measurement can be made about rather than a trade to be discovered.

What could NOT be assembled is the corpus itself, and that is where every real
decision in this slice is.

## The four questions, answered

### 1. Whose documents, and where do they live?

**Two tables of the instance's own, ingested by an operator CLI** —
`help_docs` and `help_chunks` (migration `0065-help-corpus`), written by
`racket cli/telemachus-help.rkt ingest`.

Not a team's repository documents (HELP‑3). `repo_objects.team_id` is NOT NULL,
so the shipped manual would be ingested once per team, charged to each team's
`storage.bytes`, listed in each team's documents and search, and offered to each
team's knowledge-graph extraction. None of that is wanted and all of it is
irreversible per team.

Not read off disk at request time either, and **a measurement decided that**
(HELP‑2): `nix/telemachus.nix` sets `src = ../refimpl/racketmaximus`, so `docs/`
is in neither the store nor the container image. A boot-time read of `docs/`
works in every developer's checkout and finds an empty directory on every
packaged install — the shape #119 was filed against, a feature reporting healthy
and doing nothing. Adding `docs/` to the derivation would put the committed book
PDF and nineteen chapters of rendered art into an image whose size
`docs/ops/container.md` already guards twice.

So the operator ingests from a checkout of the release they are running, and what
travels with the instance is the database.

A plugin was considered and rejected for the ordinary reason: a plugin cannot
add a permission to the catalog (#113/MTX‑9), cannot own a sealed column
(FEED‑5), cannot add a quota dimension and cannot add a console tab. Slice 2
needs three of those four.

### 2. It must cite, and it must be able to say "I don't know"

The citation is built and is free, because of CHUNK‑1: the chunker's offsets
index the string it was given and `help_docs.content` is that same string, so a
hit resolves to a substring with no mapping in between and nothing to disagree.
A hit carries the **path**, the **title**, the **heading** it sits under and a
**character range**, so a citation names a file a reader can open in the
repository or on the published site.

Two rules make it honest:

- **A passage whose document has moved under it is DROPPED, not clamped**
  (HELP‑13, VEC‑37's rule). A clamped substring quotes characters the vector was
  never made from, which is wrong in the one way a citation must not be.
- **What is embedded is MORE than what is quoted** (HELP‑6), and the cost is
  stated rather than hidden: the vector is of `title / heading / text` while the
  offsets index the raw chunk. A passage can therefore be retrieved for a word
  that appears only in its heading, and a reader comparing the quote with the
  question will not see why it matched. The alternative is a corpus of 1,400
  paragraphs in which the subject of each is unstated.

"I don't know" is slice 2's, and the mechanism it will use is already measurable
here: `help_passages` reports a `score` per passage, so a floor below which the
answer is "the documentation does not seem to cover this" is a number that can be
calibrated rather than a prompt instruction that may or may not be obeyed. The
KG extractor's verbatim-substring rule is the precedent for the stronger half:
a sentence the passages do not support is refused, not flagged.

### 3. It costs model calls against the team's budget

**The INGEST costs nothing to any team and is charged to nobody** (HELP‑1), which
is forced rather than chosen: every model-backed workflow here runs as a
principal and bills a team, the corpus belongs to no team, and this platform has
no instance-tier quota subject at all. So an ingest is an operator action, out of
band, like `telemachus-secrets rewrap`. It IS logged — `cli/telemachus-help.rkt`
installs a `model-request-logger`, which took finding (see HELP‑1's note) — with
a NULL team, so those rows are in `model_requests` and not on
`GET /api/model-requests`, which filters by team.

**Asking a question is slice 2's cost and is the one #183 is really about.** A
question is one embedding plus one completion; against the shipped defaults of
2,000 `ai.tokens.total` and 200 `ai.requests` a day, that is help which stops
working at lunchtime. Slice 2's answer is a dimension of its own,
`ai.help.total`, with **no default limit** — EMB‑6's and JUDGE‑10's shape, where
a cost with no sensible home gets a dimension rather than being folded into
somebody else's budget. What that does not bound is stated with it.

### 4. Embeddings do not exist yet

They do (#189, #163). The retrieval here is `vec-nearest` over the same stored
form, so the corpus is comparable with the document corpus and the same
calibration applies to both.

**What is NOT claimed is cross-lingual retrieval** (HELP‑12). The console ships
in Japanese and the documentation has a Japanese e-book and a Japanese generated
reference, so the locale is a SQL filter with an honest fallback: an exact match
first, the default locale second, and the report says **which locale answered**.
Whether `nomic-embed-text` puts a Japanese question near its English answer is
unmeasured, and a design that quietly relied on it would be the confident wrong
answer CHUNK‑2 warns about.

## Measured, against the real embedder

On the test lab box (`nomic-embed-text` through ollama on loopback), ingesting
`docs/` plus both READMEs:

| | documents | chunks |
|---|---|---|
| English | 65 | **1,427** |
| Japanese | 27 | **178** |
| total | **92** | **1,605** |

**114 embedding requests, 29.7 seconds wall**, for the whole corpus from empty —
and **zero requests** for a re-ingest that finds nothing changed (HELP‑9). A
vector row is 3,072 bytes (768 float32), so the corpus is about 4.9 MB of
vectors. The ingested set matches the tree exactly, checked by diffing
`help_docs.path` against `find docs -name '*.md'` plus the two READMEs.

`vector-store.md` estimated **1,159** English chunks at 256 tokens with 15%
overlap; the real chunker gives **1,427** for 65 files, because the boundary
search (CHUNK‑3) ends a chunk at the last sentence break inside its window and so
produces slightly shorter chunks and a few more of them. The estimate was within
20%.

**The scan is ~55 ms for 1,427 chunks and ~6 ms for 178**, end to end: the SQL
read plus the decode plus the dot products. That is slower per chunk than #189
step 1's pure-arithmetic benchmark (76 ms for 10,000), which says the **row read
dominates at this size, not the arithmetic** — so `HELP-SCAN`'s 20,000 is a bound
on the read, and an index would not be the thing to reach for first.

### What the first real retrieval probe showed

Three English questions and three Japanese ones, `k = 3`, against the corpus
above. This is not a recall measurement — six questions is an anecdote — but two
of the six are informative enough to write down.

**English retrieval is good where the documentation is prose.** "How do I rotate
the key that encrypts stored secrets?" answered with three passages of
`docs/ops/secrets-at-rest-runbook.md` at 0.66–0.73, the top one under the heading
about rotating it. "What stops a worker from taking new jobs?" answered with
`docs/book/en/13-queue.md` at 0.61–0.62.

**It is weaker where the question names a symptom.** "Why does my container
healthcheck always report unhealthy?" found the right FILE
(`docs/ops/container.md`, 0.576) and the wrong SECTION — "The four flags that are
not optional" rather than the paragraph that says a healthcheck must use the exec
form because the image has no shell. Its second hit was `decisions.md` on BLOB‑7's
"boot health check", which is a different sense of the same word. Scores in the
0.55 band are where a floor (slice 2) will have to sit.

**Japanese against Japanese works, and scored the highest of the six.** "ジョブの
待ち行列はどのように動きますか？" answered with `docs/book/ja/13-queue.md` at
**0.805**.

**And one Japanese question missed, which is the first real datum for #189's
calibration.** "認可はどのように決まるのですか？" retrieved
`docs/book/ja/14-secrets.md` — while `docs/book/ja/04-authz.md`, the chapter
titled 認可のモデル, did not appear at all. CHUNK‑2 predicted exactly this shape: a
1,024-character chunk of Japanese carries roughly four times the tokens the
English-derived default intends, so a Japanese chunk is a much larger span of
meaning and a short question matches it less sharply. **This is the measurement
#189 step 3 is waiting for, and it now has a corpus with known right answers to
be made against.**

**An English question asked with `#:locale "ja"` is answered out of the Japanese
directories — in English.** `docs/reference/ja/permissions.md` scored 0.613,
because the generated reference is English where a string is not yet translated.
That is HELP‑12's exact filter doing exactly what it says, and it is also why
cross-lingual retrieval stays unclaimed: the Japanese PROSE did not surface for an
English question.

## The answer (slice 2, built)

`domain/help/answer.rkt` is the composition; `POST /api/help` is the only route;
`static/console/17-help.js` is the overlay. No migration.

**"I don't know" is two layers, and neither is sufficient** (HELP‑15/‑16):

1. **A score floor, before any model is called** — so the honest refusal costs
   nothing. It is **0.35 and provisional**, and it is deliberately NOT a
   relevance test, because the probe above proves a threshold cannot be one: the
   Japanese question that missed its chapter entirely still had a top hit at
   **0.651**, higher than the English question that found the right file at
   0.576. What it answers is "is anything in this documentation near this
   question at all". `#:floor` is an argument, because a calibration has to
   sweep it.
2. **Every cited path is resolved against the passages actually retrieved.** A
   model told to cite sometimes invents a plausible file, and a reader who
   follows a citation to a file that says something else is worse off than one
   who got no answer. An invented path is dropped and reported; an answer that
   cites nothing is `uncited` and still returned, because that is usually the
   model declining, which is what it was asked to do.

**And an answer that cites EVERY passage it was shown has cited nothing**
(HELP‑22), which the only real-model run found: asked something the
documentation does not cover, the top score was 0.488 — above the floor, by
design — and `qwen2.5:7b` refused correctly and then named all five passages by
way of explaining what they were about. Five valid citations turned a refusal into
a five-source answer. That is `unfocused` now, citations dropped and passages
kept. Raising the floor is not the fix: the useful container answer scored 0.587
against that question's 0.488.

The answer is **prose with `[path]` markers plus resolved citations beside it**
(HELP‑17). VEC‑38 made the opposite call for `repo_retrieve` and both are right
for their reader: that one answers a model, this one answers a person. A
`json_schema` here would be a liability — most local servers ignore
`response_format`, so a model that cannot produce the object would make help fail
outright, where one that cannot produce a bracket still gives a readable answer
and says it cited nothing.

**A question costs `ai.help.total` and `ai.requests`, and deliberately not
`ai.tokens.total`** (HELP‑21) — #183's question 3, answered. What that does not
bound is stated with it.

**The failure vocabulary is closed and the status is 200** (HELP‑19):
`unconfigured` / `empty` / `locale-empty` / `no-model` / `nothing-relevant` /
`uncited`. With no chat model the PASSAGES come back instead of an error
(HELP‑20) — `content_search: false`'s posture, report what did not run and keep
what did.

The console affordance is **hidden when help cannot answer**, off
`S.me.help.reason` from whoami, which is already fetched on every render pass.
`locale-empty` is not hidden: the corpus exists and the answer arrives in another
language, which is worth offering and worth saying.

### What verification covers

| | |
|---|---|
| `raco test test/help-tests.rkt` | 24 cases, both dialects |
| `raco test test/console-tests.rkt` | the overlay's structure, the dispatch order, the one-send guard |
| `bash test/server-smoke.sh` | nine assertions on the DEGRADATION — the state every fresh install is in, which a configured box can never show |
| `bash test/e2e/validate.sh` | §3e: no affordance, and the shortcut opens nothing, when nothing can answer |
| positive controls | 13, all biting |

`test/route-perm-gate-tests.rkt` is what found the handler's `require-perm`
missing on the first run, which is the defect that gate exists for.

## What is deliberately not built, and will not be

- **No ingest at boot, and no ingest on a timer.** The corpus changes when the
  operator deploys a release, which is exactly when they run a command.
- **No per-team corpus.** A team's own documents are already searchable
  semantically (`?semantic=1`, VEC‑33…40); that is a different question with a
  different authorization story, and conflating them would put `can?` back into
  this module and with it VEC‑28's approximation.
- **No answer cache.** Two people asking the same question should get the same
  answer because the corpus is the same, not because a row was kept; and a cache
  keyed on a question is a store of what operators do not understand about their
  own instance.
