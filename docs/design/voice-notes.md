# Voice notes

Issue #192. Status: **slice 1 is BUILT** — the transcription wire, the two tools,
the workflow and the quota dimension. Slice 2 is the **streamed capture API**, and
it is specified at the end of this document.

Decisions **VOICE‑1…14** are in `docs/design/decisions.md`.

## The four requirements, and how much of each was already there

#192 asks for four things. Two of them turned out to be mostly built already,
which is the useful finding and is why this slice is small.

### 2. "a way to upload offline voice notes" — already true

`PUT /api/repo/voice/standup.mp3` with `Content-Type: audio/mpeg`. The
repository takes any format in and gives it back byte-identical (DOC‑1…17), and
`web-kit/http1` is the data plane that moves it. No route, no migration and no
code.

What it needed was for the thing to be worth uploading, which is the transcript.

### 4. "a pipeline for audio transcription, or a pipeline to converse with data" — half built

The transcription half is this slice. The **conversing** half needed nothing at
all: once the transcript is in `repo_text`, it is read by

- keyword search (`GET /api/search`, DOC‑13),
- the knowledge graph (`kg_extract` reads `repo_text`, KG‑5),
- semantic retrieval (`?semantic=1` and `repo_retrieve`, VEC‑33…40),
- and the field extractor (`doc_extract_fields`, DWF‑5).

So "converse with your voice notes" is four existing readers, not a new pipeline
(VOICE‑8/‑9). That is the whole argument for putting the transcript in
`repo_text` rather than into a derived `<key>.transcript.txt` document: a derived
document would double the storage and give search two hits for one recording,
and none of those four would read it without being told to.

### 1. "a built-in tool for voice notes" — `doc_transcribe` and `voice_list_untranscribed`

A tool, not an extractor, and the reason is metering (VOICE‑10). LAY‑7's
extractor registry is the obvious home — register `audio/mpeg` and a recording
becomes searchable through the indexing workflow nobody has to change — but an
extractor's contract is `(port content-type) -> (values text reason)`, with no
connection and no principal, and a transcription is a model request against
somebody's budget. `chunkstore.rkt` has the same shape for the same reason.

`voice_list_untranscribed` exists rather than reusing `repo_list_unindexed`
because that one filters on `extractable?`, which audio is not — so a voice note
is invisible to it, which is correct: the indexing workflow would otherwise fan
out over recordings it cannot read and fail a step on each (VOICE‑12).

### 3. "an API for streamed notes capture" — slice 2

Not built. See the end of this document.

## The wire

`transcribe-exchange` in `domain/ai/executor.rkt` is the **third model seam**,
beside `model-exchange` and `embed-exchange`, and it shares their egress gate,
their request log and their transport-error classification — RED‑16's finding,
where `model-exchange`'s own header called itself the one place a request leaves
while two other paths had their own.

Its own endpoint and its own model name (VOICE‑1), which is EMB‑1's argument
arriving a third time: a transcription model is `whisper-large-v3` or
`parakeet`, never a chat model and never an embedding one.

```sh
export TMACH_TRANSCRIBE_URL=http://127.0.0.1:8080/v1/audio/transcriptions
export TMACH_TRANSCRIBE_MODEL=whisper-large-v3
```

**The body is `multipart/form-data`** (VOICE‑2), which is the one thing this seam
does not share with the other two: `/v1/audio/transcriptions` takes a file part
and there is no JSON spelling of it in the OpenAI shape. `http-post-json` is now
a thin wrapper over `http-post-data`, so this posts through exactly the
connection discipline the other two do — a second copy of the
open/deadline/dynamic-wind/retry shape would reintroduce the descriptor leak
`llm.rkt`'s header was written about, for the request kind carrying the largest
body.

**What is logged is that a transcription happened, not the audio** (VOICE‑3).
`log-model-request!` digests its `messages` (RED‑18); audio is not a message and
a digest of 40 MB of it is an HMAC nobody can reproduce or compare. So the
logged message is the filename and the byte count. The transcript is not logged
either — it is content, and the row is the record that a request was made.

## What it costs

`ai.transcriptions.total`, its own dimension, **counting recordings** (VOICE‑11)
— EMB‑6's and JUDGE‑10's shape a third time. A transcription returns **no tokens
at all**, so `ai.tokens.total` could not measure it even if it should, and the
unit an operator can reason about is recordings ("two hundred voice notes a
day"). Seconds of audio was the alternative and is worse: the duration is known
only if the endpoint reports it, so the dimension would read 0 for every server
that answers plain `json`.

No default limit, in `QUOTA-HOLD-DIMS`, on `GET /api/usage`. `ai.requests` is
charged too, because the dimension counts calls to a model and this is one.

## The order the three workflows run in

Transcribe, then index, then embed — and the first is the opposite of the order
the other two have between themselves. A recording has **no text** until
`transcribe-documents` has run, so Index Documents has nothing to extract from it
and Embed Documents has nothing to chunk. The workflow description says so, and
the smoke asserts the recording is not findable before transcription.

It is a third workflow rather than two more steps on either of the others, for
VEC‑24's reason: a step that errors fails the RUN, and `doc_transcribe` refuses
without `TMACH_TRANSCRIBE_URL` — which is unset on every instance today — so
appending it would make indexing start failing everywhere.

## What is deliberately not built

- **No spans.** A transcript HAS positions — every segment carries a time — and
  LAY‑5's span is a page and a bbox, which a renderer draws. A time range is not
  a region, and putting one in `bbox` would make
  `GET /api/repo-obj/:id/spans?at=` answer with coordinates something would try
  to draw on a page that does not exist. "Jump to where this was said" is LAY‑5
  gaining an optional time range, which is its own decision.
- **No `video/*`.** A screen recording with a voice track is a real thing and
  transcribing it is a different decision: it carries pictures this platform
  would be discarding silently, and the one format question — which audio
  stream? — has no answer a closed list can give (VOICE‑5).
- **No diarisation, no speaker labels, no summary.** A summary is
  `doc_extract_fields` or a chat turn over the transcript, both of which already
  work on it.
- **No local engine in the image.** `whisper-cpp` is a 123 MiB closure and needs
  a model file that is not packageable; the OCR plugin's rule applies — opt-in,
  added through `extraPath`, and the operator points at whichever server they
  run.

## Slice 2: the streamed capture API

#192's requirement 3, and the only one needing real design.

**The machinery already exists and is the S3 listener's multipart upload.**
`repo_uploads` and `repo_upload_parts` take parts out of order, each as its own
blob, assembled at Complete via `input-port-append` → `repo-put!`; parts are
charged against `storage.bytes` on arrival and refunded in `drop-upload!`
(S3‑8), and an abandoned upload is reaped on the newest part's clock (S3‑7).
That is a streamed capture protocol with the quota and the reaping already
right.

What it is not is reachable from a browser: the S3 listener is off by default and
needs SigV4, which a `MediaRecorder` cannot compose. So slice 2 is **three routes
on the JSON plane over those same two tables**:

1. `POST /api/voice-notes` → initiate, answering an upload id.
2. `PUT /api/voice-notes/<id>/part?n=` → one chunk, raw body, `files:write`.
3. `POST /api/voice-notes/<id>/complete` → assemble into a repository object,
   then the ordinary trigger seam fires and `transcribe-documents` picks it up.

Three routes and no new storage, because the refund, the reap and the assembly
are `drop-upload!`'s and `repo-put!`'s. What slice 2 has to decide is whether a
part has a minimum size (S3 requires 5 MiB for all but the last part; a
60-second voice chunk is nearer 100 KB, so this plane must NOT inherit that),
and what a browser does when a chunk fails — which is a retry of that part, and
is the reason the parts are numbered rather than appended.

A websocket was considered and is not worth it: there is no websocket support in
the tree, and a chunked PUT is resumable where a socket is not.
