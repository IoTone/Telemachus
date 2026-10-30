# Where a document vector lives (issue #189)

#189 asks for a story and an evaluation, not a build: *"define story for vector
database and evaluate options."* This is that document. It is written because
`domain/ai/embedstore.rkt` deliberately refuses to answer the question — EMB‑7
stores label vectors and says, in the module header, that a vector per DOCUMENT
is a different subsystem wearing the same words, so that whoever needs one is
forced to decide rather than inherit an answer nobody made on purpose.

Everything below was measured on this box (aarch64‑darwin, Racket 9.3,
SQLite 3.53.3, PostgreSQL 18.6, pgvector 0.8.7) on 28 Oct 2026. The scripts are
throwaway; the numbers are not, and every claim that decides something here is
one of them rather than an opinion about one.

## What exists, and where it stops

- **The wire exists.** `embed-exchange` in `domain/ai/executor.rkt` (#163) sends
  text to `TMACH_EMBED_URL` and reads vectors back by `index`, through the same
  egress refusal, content-logging policy and request log as a chat call, metered
  on `ai.embeddings.total`.
- **A store exists and is the wrong shape on purpose.** `embedstore.rkt` holds a
  vector per LABEL in a settings document. There are at most `MAX-LABELS` of
  them and nothing searches them, because classification compares against every
  one.
- **`cosine` exists** and is a `for/fold` over two boxed `vector`s of flonums.
- **Nothing chunks text.** `repo_text.content` is one string per version, capped
  at `EXTRACT-CAP` (200,000 characters). There is no chunker anywhere in the
  tree — "chunk" in this codebase means HTTP chunked transfer encoding.
- **Retrieval today is a `LIKE`.** `domain/apps/search.rkt` matches a repository
  object on key, filename and extracted text, every row re-checked with `can?`.
  With `TMACH_ENCRYPT_CONTENT` on it cannot match the text at all and reports
  `content_search: false`.

## Who is waiting, and how big they are

This is the half of the question that decides it, and it is measurable rather
than arguable.

| Caller | Corpus | Chunks at 256 tokens, 15% overlap |
|---|---|---|
| **#183** in-product help over our own docs | 61 English `.md` files, 189,166 words | **1,159** (579 at 512 tokens, 289 at 1024) |
| **#191** graph‑RAG over bookmarked URLs | a person's reading list | hundreds to low thousands |
| Semantic search over a team's repository | an ordinary 2–5 page business document is ~9 chunks | 1,000 documents ≈ **9,000** |
| …the same, for a team with a real archive | `EXTRACT-CAP` bounds one document at ~230 chunks | 10,000 documents ≈ **90,000** worst case |

So the thing actually waiting on #189 is **about twelve hundred vectors**, and
the largest corpus this platform's own limits permit a team of ten thousand
documents is about ninety thousand.

## The full scan, measured

One row per chunk, 768 dimensions, packed float32 in a SQLite `BLOB`, read out
and scanned in process. Cosine over unit-normalized vectors is a dot product, so
the stored vector is normalized at write time and the query vector once.

| Chunks | `SELECT` + scan, unsealed | …sealed (AES‑256‑GCM per row) | SQLite file |
|---|---|---|---|
| 1,000 | **8.0 ms** | **8.3 ms** | 3.9 MiB |
| 10,000 | **74 ms** | **85 ms** | 39.2 MiB |
| 100,000 | **759 ms** | **868 ms** | 391.6 MiB |

Where the time goes, at 10,000 vectors: the dot products are **12 ms**, decoding
float32 bytes into flonums is **97 ms** for 29 MiB, and `aes-256-gcm-decrypt`
over that same 29 MiB is **44 ms** — about 665 MiB/s, which is to say the cipher
is not the problem. **The arithmetic is not the cost; moving the bytes is.**

Two things that are worth knowing before anyone optimizes this:

- **Today's `cosine` is 8× slower than it needs to be.** Over boxed `vector`s it
  takes **1,272 ms** at 100,000 where an `flvector` dot product takes **150 ms**,
  because every component is a heap-allocated flonum and the loop recomputes both
  norms on every comparison. That is exactly right for EMB‑7's handful of labels
  and would be the whole cost of a document scan.
- **Paging buys very little.** Sealing and storing 32 vectors per row rather than
  one moves 10,000 vectors from 74/85 ms to 56/62 ms and the file from 39.2 to
  29.3 MiB — about 20% of the time and 25% of the disk, for a row that can no
  longer be deleted, superseded or cited on its own. Measured at 1, 32, 128, 512
  and 2048 per row; the curve is flat past 32.

### Sealing is nearly free, and the obvious way to do it costs 51×

A document vector is a function of `repo_text.content`, so on an instance that
set `TMACH_ENCRYPT_CONTENT` it has to be sealed — embedstore.rkt's own header
predicts this ("the day a DOCUMENT vector is stored, the answer is the
opposite"), and it is not a formality: embedding inversion recovers a great deal
of the source text, so an unsealed vector column beside a sealed `repo_text`
would undo #83 on the instance that asked for it, which is #119's shape.

**`secret-wrap` is a STRING API, and a vector is binary.** Sealing 29 MiB of
packed float32 through it means base64 on the way in, UTF‑8 conversion, the
cipher, UTF‑8 conversion back and base64 on the way out:

| | 29.3 MiB of packed float32 |
|---|---|
| `aes-256-gcm-decrypt` on raw bytes | **44 ms** |
| `secret-unwrap` + `base64-decode` on the same data as a string | **2,240 ms** |
| stored size, sealed as bytes | **29.3 MiB** |
| stored size, sealed through `secret-wrap` | **52.1 MiB** (1.8×) |

So the string path is **51× slower and 1.8× larger**, and the first measurement
of this slice — "sealing makes a 10,000-vector scan take 2.3 seconds" — was
wrong about why: it was the base64 and the UTF‑8 round trips, not AES. Nothing in
the tree had noticed because nothing seals anything large: the biggest sealed
value today is 200 KB of extracted text, which costs 18 ms through the same path.
**A vector store needs a bytes-level seal**, either `aes-256-gcm-encrypt`
directly under `sealed.rkt`'s AAD rule or a bytes variant of `secret-wrap`.

## pgvector, measured

100,000 × 768 `vector`, `vector_cosine_ops`, on the same box.

| | |
|---|---|
| `CREATE EXTENSION vector` | ok, 0.8.7 |
| load 100,000 rows | 11 s; table 402 MB |
| sequential scan, top‑10 | **252 / 225 / 226 ms** |
| HNSW build (m=16, ef_construction=64) | **272 s**; index **391 MB** |
| HNSW query, top‑10 | **9.3 / 1.6 / 1.7 ms** |

The index is real: **1.7 ms against 868 ms** is a 500× answer at 100,000 chunks.
It also costs four and a half minutes to build, an index as large as the table,
and maintenance on every insert. And note what the sequential-scan row says:
pgvector's own full scan in C with SIMD is **225 ms** where this platform's
in-process scan over the same 100,000 vectors is **759 ms** — a factor of three,
not a factor of a hundred. The index is the whole of pgvector's advantage.

Availability is not an obstacle and I expected it to be: nixpkgs carries pgvector
0.8.7 for PostgreSQL 15 through 18 at **685 KiB unpacked**, and sqlite-vec 0.1.9
with a **343 KiB** closure. My own first framing of this question — "two
extensions to pin, and the Nix closure grows" — was wrong by three orders of
magnitude.

## sqlite-vec cannot be reached from this platform at all

This is the finding that settles the extension question, and it is specific to
Racket rather than to SQLite.

```
db/sqlite3 exports exactly: sqlite3-connect, sqlite3-available?
  (no extension-loading entry point of any kind)

through db:   select load_extension('…/vec0.dylib')  ->  "not authorized"
through the CLI, same SQLite 3.53.3 in the same closure:
              .load …/vec0   then select vec_version()  ->  v0.1.9
```

"Not authorized" is SQLite's answer when `sqlite3_enable_load_extension` was
never called, and Racket's binding never calls it and exposes no way to.
The identical library loads the identical extension from the shell. So reaching
`vec0` means **our own FFI binding to libsqlite3 beside `db`'s**, with its own
connection to the same file, on the request path — against a store this platform
already opens through `db-kit/portable`.

Which means: even if pgvector were adopted, **SQLite would be served by the
full scan anyway** — and SQLite is the default, the single-box case, what
`nix build` tests and what one leg of CI runs. An extension does not replace the
scan; it adds a second retrieval path on top of one that has to exist.

## The decision

**A sealed `BLOB` column, one row per chunk, scanned in process. No extension,
no new service, no index — and a stated threshold at which that is revisited.**

The reasons, in the order they carry weight:

1. **The caller that is waiting needs 8 ms.** #183's entire documentation corpus
   is 1,159 chunks. An ANN index over twelve hundred vectors is a build step, an
   index file and a recall question in exchange for seven milliseconds.
2. **The scan has to exist regardless**, because SQLite cannot be given an
   index (above) and because a sealed instance cannot be given one either — the
   engine has to read the vector to compare it.
3. **Sealing costs 4–14%** when done at the bytes level, so the privacy-first
   default is not the slow path. That was the question I most expected to go the
   other way.
4. **Nothing is foreclosed.** The column holds packed float32 with the model name
   beside it; adding `pgvector` later is a Postgres-dialect index over a column
   that already exists, on an instance that has not sealed its content. Deciding
   for the extension now would instead foreclose the sealed instance and SQLite.

### When to revisit

Not "if it gets slow" — a number. **When a single team's chunk count passes
50,000**, which is where the scan crosses half a second and where a second
concurrent query starts to matter. `GET /api/admin/queue`'s shape is the
precedent for making that visible: the store should report its own row count per
team so the threshold is something an operator can see rather than something
somebody has to profile.

### What is declined, and why

- **An external vector store** (Qdrant, Weaviate, Chroma, pgvector-as-a-service).
  A self-hosted, privacy-first product adding a second network service that
  nothing else in the deployment needs, for a workload measured in milliseconds,
  is the trade `container.md` already declines twice for LibreOffice and MinIO.
  It also puts document-derived vectors — which invert back towards the text —
  on a wire this platform does not control.
- **`sqlite-vss`**. Superseded by sqlite-vec upstream, and unreachable for the
  same reason.
- **An FFI binding to libsqlite3 of our own.** A second SQLite connection to the
  same file, outside `db-kit/portable`'s `?`→`$n` rewriting and outside the pool,
  to gain an index on the dialect whose corpora are smallest.

## Decisions (VEC‑1…10)

The canonical table is the **VEC** block in `docs/design/decisions.md`. In short:
a vector is of a CHUNK with character offsets into `repo_text.content` (LAY‑5's
vocabulary); one row per chunk in a typed table; packed float32, normalized at
write; sealed as BYTES under `TMACH_ENCRYPT_CONTENT` and listed in the rewrap
CLI's `CONTENT-SECRETS`; the model name travels with the vectors and a mismatch
discards them whole (EMB‑8); every hit re-checked with `can?` after the scan, as
search does; no ANN index, revisited at 50,000 chunks per team.

## The build plan, in order

**Steps 1 and 2 are BUILT** (28 Oct 2026, decisions VEC‑11…17 and ENC‑24);
steps 3–6 are not. Each step is independently useful and each one ends somewhere
a person can see.

1. ~~**An `flvector` dot product and a normalized store.**~~ **BUILT** —
   `domain/ai/vectors.rkt`, `test/vectors-tests.rkt`. The arithmetic half,
   re-measured with the real module: boxed `cosine` 1,314 ms against an
   `flvector` dot product of 168 ms at 100,000 × 768, and 784 ms for the whole
   scan including the decode and a bounded top‑k. `cosine` stays as it is for
   EMB‑7's labels (VEC‑14) and the scan has its own primitive. One module, no
   schema, no caller yet.
2. ~~**A bytes-level seal.**~~ **BUILT** — `secret-wrap/bytes` /
   `secret-unwrap/bytes` in `secretbox.rkt` and a `#:bytes` form on
   `define-sealed-column`. A bytes variant beside the string one, under the same
   key, cipher, nonce and `aad-for`, so the AAD rule is shared rather than
   re-spelled; the stored form is a binary frame rather than base64, which is
   both the 51× and the 1.8×. The one thing it needed that the string path did
   not is a sniff that works on arbitrary bytes.
3. ~~**A chunker.**~~ **BUILT, with its two numbers left to calibrate** —
   `domain/ai/chunk.rkt`, `test/chunk-tests.rkt`, decisions CHUNK‑1…9. The
   mechanism needed no model and is pinned: a chunk's offsets ARE
   `repo_text.spans`' own coordinates, so `spans-covering` shows a hit where it
   was read with no new code; the boundary search walks back through a bounded
   window (a sliver is the failure an unbounded one produces); the walk's
   termination is one rule in one place; a whitespace-only chunk is never
   emitted; and the whole thing is pure, so a re-chunk of unchanged bytes is a
   recognisable no-op. Measured rather than estimated: **1,227 chunks over the
   62 English documents** here, where this plan's token-based estimate was
   1,159, and **231 chunks for a document at `EXTRACT-CAP`**, which is the ~230
   above. What remains is the **size and the overlap**, provisional at 1,024
   characters and 154 — and the unit is characters because there is no
   tokenizer here, which makes the default an ENGLISH assumption: the same book
   chapter is 3,342 characters in English and 2,079 in Japanese, yet Japanese
   runs near one token per character against English's four, so a chunk of
   Japanese carries roughly four times the tokens the calibration intends.
   **The recall measurement has to be made in both languages.**
4. ~~**The table and the write path.**~~ **BUILT** — migration
   `0064-chunk-vectors`, `domain/ai/chunkstore.rkt`,
   `domain/repo/embed-tools.rkt`, and an **Embed Documents** workflow beside
   Index Documents in `plugins/doc-indexer/`; decisions VEC‑18…25. One row per
   chunk per VERSION, sealed as bytes under the content switch and listed in
   `CONTENT-SECRETS` as VEC‑3 requires — which also meant teaching
   `telemachus-secrets` the binary form, because `rewrap` and `status` were
   string-path throughout and `secret-wrap` is total, so it would have passed a
   vector through unsealed and reported having sealed it.
   **It is this schema's first `BLOB`/`BYTEA` column**: the type spelling is
   branched by dialect, and all 256 byte values were measured through
   `db-kit/portable` on both engines before the migration was written, because a
   vector that decodes to plausible-but-wrong numbers has no model name to catch
   it. It is a SECOND workflow and not two steps on the published spec (VEC‑24),
   since a step that errors fails the run and `repo_embed_chunks` refuses
   without `TMACH_EMBED_URL` — which is unset on every instance today.
   Still no model needed to BUILD or test it: the embedding seam is
   `current-doc-embed`, scripted by the suite.
5. ~~**The read.**~~ **BUILT** — `domain/ai/chunksearch.rkt`,
   `test/chunksearch-tests.rkt`, decisions VEC‑26…32. A nearest-chunk query,
   team-scoped in SQL, `can?` per row after the scan, returning the chunk's
   offsets so the caller can cite it. No migration, no route, no permission and
   no model: everything it needed was on disk after step 4, which is the whole
   point of having landed the arithmetic and the seal first. The window cap IS
   this document's own revisit threshold (50,000), so a truncating team is one
   that has already crossed the line where this design says to reconsider the
   approach, and `truncated` reports both ways of stopping. **The one
   approximation is the authorization headroom**: the scan keeps `k × 4`
   candidates and `can?` is applied in score order over them, memoized by
   document, because authorizing the whole window first — the exact answer —
   costs one query per document in the team and is seconds at ten thousand. So
   a private document ranking first withholds a hit and does not take the whole
   answer with it, and an exhausted headroom says so.
6. ~~**A retrieval tool and `?semantic=` on search.**~~ **BUILT** —
   `domain/repo/passages.rkt`, `domain/repo/retrieve-tools.rkt`,
   `search-passages` in `domain/apps/search.rkt`, and `?semantic=` on
   `GET /api/search`; decisions VEC‑33…40. No migration and no new permission.
   **The tool refuses where the search degrades** and both are right (VEC‑34):
   a tool asked for exactly this names the unset variable, a search asked for a
   search answers the keyword half and reports that the other one did not run —
   `content_search: false`'s own rule. Asking is gated on `chat:use`, because
   embedding the question is the only search in this tree that spends the team's
   AI allowance. **And it is the first content search that survives
   `TMACH_ENCRYPT_CONTENT`**: it compares vectors and unseals the text through
   `repo-text-for`, so on a sealed instance it is the only way left to search
   inside a document. #183 and #191 pick it up from here.

**THE WHOLE BUILD PLAN IS BUILT**, steps 1 through 6, and none of it needed a
model: the arithmetic and the seal, the chunker, the table and the write path,
the scan, and the retrieval surface. **And step 3's size-and-overlap calibration
has now been made** — in both English and Japanese, against a live embedder — so
nothing on #189 is outstanding. The run is at the end of this document; its
answer is that the two numbers stand and the embedding MODEL is the lever, which
is not what this section expected when it was written.

What it expected was CHUNK‑2's argument: the same book chapter is 3,342
characters in English and 2,079 in Japanese, yet Japanese runs near one token per
character against English's four, so a 1,024-character chunk of Japanese carries
roughly four times the tokens the default intends — and a chunk that overruns the
model's context is truncated BY THE MODEL, so the failure is a quietly worse
vector and never an error. **The reasoning was sound and the conclusion was
wrong**: shrinking the chunk does not close the Japanese gap, and swapping
`nomic-embed-text` for a multilingual checkpoint doubles Japanese recall at the
default size. The paragraph is kept rather than deleted because the hypothesis is
why the measurement was worth making.

It was also expected to be one sitting with `EMBED-MARGIN-SCALE` (#163). It is
not: that is the margin between LABEL similarities in `doc_classify`'s `embed`
backend, which is a different measurement over a different input, and it is still
open.

The end-to-end gate is **`doc-pipeline-smoke.sh` §8**, which drives a question
through the real `embed-exchange` wire against `test/mock-llm.rkt`'s embeddings
mode. It is the only place that path is exercised end to end anywhere, which is
#187's lesson applied before it had a chance to cost anything.

Two things step 5 needed to know, both of which it now acts on — kept here
because they are the facts a reader of the read's SQL will want:

- **The scan's window joins `o.current_version_id`**, which is what makes a
  superseded version's vectors unreachable rather than merely stale (VEC‑18),
  and it filters `c.model` in SQL, because vectors from two checkpoints are not
  comparable and mixing them answers confidently and wrongly (VEC‑20).
- **A re-upload does not clear the old version's vector rows.** The lister sees
  the document as un-embedded and offers it again, and `chunks-replace!` deletes
  by `object_id`, so the rows go on the next embed — but between the upload and
  that run they sit there, unreachable to the scan and counted by
  `chunks-count`. That is storage, not correctness, and it is stated rather than
  tidied because the alternative — clearing them at upload — would throw away a
  usable index the moment somebody fixed a typo in a document.

## The calibration (#189 step 3, measured 30 Oct 2026)

The one thing left on #189. `CHUNK-SIZE-DEFAULT` and `CHUNK-OVERLAP-DEFAULT` said
**provisional** at their definition, with "what would change them is a recall
measurement, in both languages (CHUNK‑2)". This is that measurement, and **it
says the two numbers are not the lever**.

The harness is `refimpl/racketmaximus/test/calibrate-retrieval.rkt` — not a suite
and deliberately not named `*-tests.rkt`, because it needs a live embedder and
takes minutes. The question set is `test/calibration-questions.json`: **28
questions, each asked in BOTH languages**, with the file or files that answer it
in each corpus.

### How it is scored, and what that cannot tell you

**File level, not section.** A question's answer is unambiguously in a file;
which section is often arguable, and the earlier probe already showed the section
is the harder problem ("why does my container healthcheck report unhealthy" found
the right file and the wrong heading). Scoring sections would have measured my
adjudication of a hundred headings as much as the retrieval.

**A SET of acceptable files**, because several things are documented in a book
chapter *and* a runbook on purpose. Insisting on one would score a correct
retrieval as a miss and then invite "improving" the chunker to fix a problem that
was in the question set.

**28 questions means one question is 3.6 points.** Differences under about 11
points — three questions — are not distinguishable. And the questions were
written by the same person who wrote most of the documentation, so they share its
vocabulary more than a stranger's would; the Japanese forms are translations of
the English ones, which is what makes the two languages comparable and also means
they may not use the words the machine-assisted `ja` book chose. These are
figures for comparing cells, not figures to quote.

### The sweep: 6 sizes × 3 overlaps, `nomic-embed-text`

Recall@3, as percentages, over the project's own documentation (1,400 English
chunks / 178 Japanese at the default):

| size | 0% overlap | 15% | 30% |
|---|---|---|---|
| 384 | 86 / 59 | 86 / 44 | 86 / 52 |
| 512 | 82 / 52 | 82 / 56 | 82 / 48 |
| 768 | 86 / 56 | 82 / 48 | 86 / 37 |
| **1024** | 89 / 44 | **82 / 41** | 79 / 56 |
| 1536 | 89 / 59 | 93 / 52 | 86 / 44 |
| 2048 | 89 / 44 | 89 / 52 | 82 / 56 |

*(English / Japanese. The bold cell is today's default.)*

**English is flat.** Over an eightfold range of chunk size, recall@3 moves between
82% and 93% — three questions' worth, inside the noise. recall@1 spans 61–82% and
recall@5 79–96%, with no monotone trend in either. There is no cell the data
prefers, and the ingest cost varies by 2.5× across the range (160 embedding
requests at 384, 102 at 2,048), which is the only thing that separates them.

**Japanese is roughly half of English in every single cell**, and that is the
result worth having.

### CHUNK‑2's hypothesis is not supported

CHUNK‑2 reasoned that Japanese runs near one token per character against
English's four, so a 1,024-character Japanese chunk carries about four times the
tokens the default intends — and therefore that Japanese would want a smaller
size. It does not. At **384** characters, about the English-equivalent of 1,536,
Japanese recall@3 is **59%** against English's **86%** in the same cell.
Shrinking the chunk does not close the gap.

### What does close it is the model

One cell, 1024/154, same questions and same corpus; only `TMACH_EMBED_MODEL`
changed:

| | `nomic-embed-text` | `bge-m3` | |
|---|---|---|---|
| English recall@1 | 61% | **75%** | +14pp |
| English recall@3 | 82% | **93%** | +11pp |
| English recall@5 | 93% | **96%** | +3pp |
| Japanese recall@1 | 26% | **70%** | +44pp |
| Japanese recall@3 | 41% | **81%** | +40pp |
| Japanese recall@5 | 59% | **81%** | +22pp |

**Japanese recall@3 doubles.** English improves too, by about one question at
each k. The costs are real and are the reason this is a recommendation rather
than a default: the same ingest takes **49s against 19s** (bge-m3 is the larger
model), and its vectors are **1,024 dimensions against 768**, so the stored
corpus is a third larger — 4,096 bytes a row rather than 3,072.

### What changed, and what did not

- **The two chunk constants STAY at 1,024 and 154**, and the word *provisional*
  is gone from their definition. They are measured now, and the measurement's
  answer is that the parameter does not matter much. A negative result, and the
  honest one.
- **`bge-m3` is recommended over `nomic-embed-text` for any instance that
  retrieves in a language other than English**, in `docs/ops/configuration.md`
  with these numbers beside it. Not changed in code: `TMACH_EMBED_MODEL` has no
  real default (`local-embed` is a placeholder), and which checkpoint an operator
  runs is theirs.
- **Changing the model re-embeds everything** (EMB‑8), which is why that
  recommendation belongs where an operator reads it before ingesting rather than
  as a silent default change.

### What this run did NOT settle

- **`HELP-SCORE-FLOOR`** (0.35) was set from `nomic-embed-text`'s score
  distribution. bge-m3's will differ, and this run recorded recall rather than
  scores, so the floor is unchanged and remains model-dependent. Re-deriving it
  is a `--scores` mode on the same harness.
- **#163's `EMBED-MARGIN-SCALE`** is about the margin between LABEL similarities
  in `doc_classify`'s `embed` backend, not about retrieval. It was expected to be
  the same sitting and it is not the same measurement; it is still open.
- **Section-level recall**, for the reason given above.
