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
4. **The table and the write path**, as a step in the existing indexing
   workflow (`plugins/doc-indexer`) rather than a new seam: a chunk's vector is
   the same kind of thing as its extracted text, keyed on the version, replaced
   wholesale by a new one.
5. **The read**: a nearest-chunk query, team-scoped in SQL, `can?` per row after
   the scan, returning the chunk's offsets so the caller can cite it.
6. **A retrieval tool and `?semantic=` on search**, which is where #183 and #191
   pick it up.

Steps 1–3 are built. **Step 4 is the next one and it needs no model**: the
table, the sealed vector column and a write step in the existing indexing
workflow. What waits for a live `nomic-embed-text` is step 3's CALIBRATION — the
two numbers above — which is the same measurement `EMBED-MARGIN-SCALE` (#163)
wants and is therefore a thing to do once, in both languages, when the GPU rig's
driver upgrade lands. It is no longer a thing that blocks building.

One thing step 4 must not forget, recorded here as well as in `decisions.md`
because this is the document somebody reads before building it: **the vector
column has to be added to `CONTENT-SECRETS` in `cli/telemachus-secrets.rkt` in
the same commit as its `CREATE TABLE`.** VEC‑3 says so, and a sealed column
`rewrap` does not walk is silently unrotatable.
