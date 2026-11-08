# Translate

Three cards: the translation itself, the team's **Glossary**, and **Recent**
translations.

## Translating a passage

Paste into **Text to translate**, pick a **Target language**, leave **Use
glossary** ticked unless you want the model's own wording, and press
**Translate**. The result appears below the box.

While it works the pane counts the seconds — a translation of any length takes
seconds to a minute on a local model — and then says how long it took, and **in
how many sections** if it was long enough to be split.

## The character count, and why it is the number to watch

Under the box is `N / M characters`, and M comes from the server on the same
read that draws the screen, so the count cannot disagree with the rule that
refuses.

**M depends on the target language**, and is roughly a quarter as large for
Japanese or Chinese as for a European language. That is not caution: English
runs near four characters to the token and Japanese near one, so a passage
sized against the model's window in English has its *Japanese reply* truncated
by the model, silently. The number the screen shows before you have chosen a
target is the worst case, so being allowed more than it said is normal; being
refused below it is not.

Past the limit the count turns red and explains: a long text is translated in
sections, and longer still is refused outright. The refusal appears **in the
output pane, not as a toast** — it is several sentences, says how much was sent
and what the limit was, and a toast would scroll away before it could be read.

## Sections

A long passage is cut into sections and each is translated on its own, so a
document far past one model window still comes back whole.

- **The sections tile; there is no overlap.** A reader must not meet the same
  sentence rendered twice in two directions.
- **The glossary and the instructions go to every section.** An agreed term
  applied to half a document is worse than no glossary, because nobody reading
  the result can tell which half to trust.
- **Past 24 sections it is refused before anything is sent.** Each section is a
  model request, and the daily request allowance is finite.
- A refusal part-way through stores nothing; what was already spent is still
  recorded.

## Glossary

The team's terminology, per target language: a term and the translation it must
always get. Anyone can read it; adding a term needs a settings-manage
permission.

This is the lever for names, product words and anything the model would
otherwise translate differently on two pages.

## Recent

The last translations for this team, with the first part of the source and the
result. It is a record, not an editable history.

## Submitted in this session

**A translation is a scheduler job**, so pressing `Translate` does not hold the
screen: the request comes straight back, a row appears under the form, and the
source field is yours again — you can edit it and send the next one while the
first is still running.

The row carries the job's status, how long it has been running, how many
**sections** the text was split into and how many of them are done, and a
`Cancel` button while it is still queued or running. When it finishes, the
translation appears in the pane under the form. Each row is also an ordinary job
on the [Jobs](jobs.md) screen, with everything that screen offers.

The list is what you submitted **in this session** — reloading the page clears
it. The durable records are the Recent table below and the Jobs screen.

While a translation is running, the screen asks the server for its status every
couple of seconds; once nothing is live it asks for nothing at all, so leaving
this tab open does not keep your session alive.

Cancelling does not refund what has already been spent: a run stopped at section
twenty of twenty-four has paid for twenty. Nothing is stored for a cancelled or
refused translation — there is no half-translated document.

Translate can be turned off for the instance, a company or a team.
