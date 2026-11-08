# Asking the documentation a question

**The console has a button for this. It is labelled `Docs`, in the header, to
the right of `⌘K`. The keyboard route is `⌘/` (`Ctrl+/`).** Pressing either
opens a panel over the screen you are on; type a question in plain English or
Japanese, press `Ask`, and the answer comes back with the documents it was read
from. `Esc` closes it.

That is the whole of it. There is no tool to call, no workflow to run and no
tab to find — asking the documentation is not one of the AI tools on the
[Agent](agent.md) screen, and it is not a `doc_` tool you invoke from a
workflow. It is the `Docs` button.

## What it is reading

The corpus is this product's own documentation — the pages under `docs/`, both
READMEs, and these UI pages — ingested once by an operator and stored as
passages. It is the **instance's** corpus, not your team's: asking a question
reads the manual, never your team's documents. For a question about your own
files, use [Search](search.md) or [Chat](chat.md).

An operator fills the corpus with `telemachus-help ingest`, which is why the
panel can say `No documentation has been ingested yet` on a fresh instance.

## Reading the answer

The panel always shows **Sources** — the passages the answer was read from,
each with the document it came from. Every path in the answer is checked
against those passages before you see it, so a citation to a file that was
never retrieved is removed rather than shown.

Five things it says instead of answering, and each means something different:

- **"Nothing in the documentation is close to that question."** The retrieval
  found nothing near enough to be worth asking a model about. Rephrasing in the
  words the documentation itself uses is the thing that helps.
- **"The answer named no source…"** — the model declined, or answered without
  citing. You get the passages it was shown; they are usually the answer.
- **"The answer named every passage it was shown, which distinguishes
  nothing — treat it as a refusal."** An answer that cites all five sources has
  cited none of them. This is the shape a polite non-answer takes.
- **"No model is configured, so these are the passages closest to the question
  rather than an answer."** Retrieval works without a chat model; the prose does
  not.
- **"The documentation has not been ingested in this language, so the answer
  comes from another."** The corpus is matched to your language first and falls
  back when that language has no pages, saying so rather than quietly answering
  in English.

The `Docs` button is **hidden** when nothing could answer at all — no embedding
model, or an empty corpus. A missing button is not a broken one.

## What it costs

Asking is two model calls: one to turn your question into a vector and one to
write the answer. It spends the team's `ai.help.total` and `ai.requests`
allowances, which [Usage](usage.md) reports, and needs the `chat:use`
permission — that permission is about the spending, not about the documents.

Deliberately, it is **not** a scheduler job: the answer comes back in the
request, in a second or two. So asking leaves nothing on the [Jobs](jobs.md)
screen, and there is no progress bar, no elapsed time and no way to cancel. A
cold model can make the first question of the day take much longer than the
rest.
