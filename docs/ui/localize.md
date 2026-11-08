# Localize

> Translate the product. AI drafts, people approve — nothing reaches the product
> unreviewed.

The tab appears with the `localization:read` permission, which a plain member
holds — translating is a team activity. Approving somebody else's work and
writing catalogs to disk are admin acts and need `localization:review` and
`localization:manage`.

## The shape of it

**The catalogs on disk are the shipping artifact.** This screen is the workflow
around them, and neither of its two ends is on the request path:

1. **Import catalogs** pulls the English source and the existing translations
   in.
2. You translate, or draft, and somebody approves.
3. **Export** writes the approved strings back out to the catalog files.

So nothing you do here changes the running product until an export, and an
export needs the manage permission.

## The table

**Translating into** picks the target language. **Coverage** is how much of it
is done.

Each row is a **Key**, the **English**, and the **Translation**, with a
**Status** — and the filter above takes `All statuses` or one of them.

- **missing** — there is no translation.
- **stale** — the English has changed since this translation was made.

Both are **derived, never stored**: stale is the stored source hash disagreeing
with the English's current one, so editing an English string makes every
translation of it stale with nothing rewriting a status. A row can never
disagree with the catalog.

Statuses a translation itself carries: `machine` (an AI draft), `submitted`
(a person's), and `approved`.

**Search key or text** filters both sides.

## AI draft

Drafts a batch with the model. Output lands as `machine`, **never approved**.

The button says what it will cost before it queues anything:

> AI budget: about N tokens needed, M remaining today — raise `ai.tokens.total`
> in Usage or the drafts will wait

and then

> Queued N strings in B batch(es) — they land as "machine" for review

Twenty strings per job, so a large namespace is a cancellable queue rather than
one long job. **A draft that runs out of budget looks like a hang**: the
remaining jobs sit `queued` with nothing `running`. Raise the limit in
[Usage](usage.md) first — a couple of hundred interface strings is on the order
of twenty thousand tokens on a small local model.

**A draft that loses, invents or mangles a placeholder is refused rather than
stored.** Two checks: the placeholder names must match, and so must the number
of braces — the second is what catches a stray `{}` the model appends to a
sentence, which the name check cannot see and the formatter will not reject
either. A bad draft that looks finished in a review queue is worse than a
missing one.

**A human submission is not placeholder-checked.** The model is held to a
standard the person is not, so check placeholders by hand when submitting a
batch.

## Approve and Reject

**Approve** / **Reject** on a translation, with the reason.

> You cannot approve your own translation.

A **machine** draft has no human author, so anybody with the review permission
may approve it — which is the review the AI path needs.

## Export

Writes the approved strings for one language back to its catalog file.

**Export refuses a language with nothing approved.** The languages the console
offers are derived from the files that exist, so writing an empty catalog would
put a language in the switcher with English behind it. A partial catalog is
fine — the fallback chain covers the gaps, and an untranslated string shows the
English rather than a blank.
