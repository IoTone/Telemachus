# In-product help: a chat box grounded in our own documentation

Issue #183. Status: **the corpus and the retrieval are BUILT** (slice 1); the
answer — the prompt, the citations, the refusal and the console panel — is
slice 2 and is specified at the end of this document.

Decisions **HELP‑1…14** are in `docs/design/decisions.md`.

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

## Measured

Through the real ingest over the real tree (scripted embedder, so these are
counts and not a recall figure):

| | documents | chunks |
|---|---|---|
| `docs/` + both READMEs, English | 63 | **1,400** |
| the same, Japanese | 26 | **168** |
| total | **89** | **1,568** |

At `HELP-EMBED-BATCH` of 32 that is **111 embedding requests** for a whole
corpus, and **zero** for a re-ingest that finds nothing changed (HELP‑9). The
whole `docs/ops` subtree — seven runbooks — is 173 chunks and 8 requests,
measured end to end through `embed-exchange` against `test/mock-llm.rkt`'s
embeddings mode.

`vector-store.md` estimated 1,159 chunks for the English corpus at 256 tokens
with 15% overlap. The real chunker gives 1,400 for 63 files: the boundary search
(CHUNK‑3) ends a chunk at the last sentence break inside its window, so chunks
are a little shorter than the nominal size and there are a few more of them. The
estimate was within 20% and the scan cost is unaffected — 1,568 chunks is about 12 ms
of arithmetic, interpolated from #189 step 1's measured 8 ms at 1,000 and
76 ms at 10,000.

## What slice 2 builds

1. **`ai.help.total`**, a quota dimension with no default limit, in
   `QUOTA-HOLD-DIMS`, charged per question.
2. **`domain/help/answer.rkt`** — the composition: embed the question, retrieve
   `HELP-K` passages, refuse below a score floor, and prompt for an answer that
   cites by path. The model seam is a parameter (`current-help-chat`), as every
   model-backed tool here has one, so the test needs no model.
3. **`POST /api/help`** — authenticated, `chat:use` (asking costs a model
   request, which is VEC‑35's rule), answering `{answer, citations, locale,
   reason}` and degrading with a closed vocabulary rather than an exception
   message: `unconfigured` / `empty` / `locale-empty` / `forbidden` /
   `unavailable`.
4. **A console panel**, available on every tab, with the strings in `en.json`
   and `ja.json`.
5. **The gate**: `server-smoke.sh` for the degradation on an instance with no
   corpus, and the question path in `help-tests.rkt` with a scripted model.

Nothing in slice 2 needs a migration.

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
