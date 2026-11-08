# Beta

The public onboarding funnel: the page a prospect lands on, and the people who
have applied. Two sub-screens, chosen by the buttons at the top —
**Prospects** and **Onboarding page**.

The tab appears with a settings-manage permission.

## Prospects

Everybody who filled the form in. Per row: the name and address, the details,
the judge's verdict, a status, and **Qualify** / **Reject**.

- **details** is rendered **generically from the form's own field list**, so a
  field you add to the funnel shows up here with its label and needs no change
  to this screen.
- **LLM judge** is a verdict — `valid` or `flagged`, a score out of 100, an
  estimate and the model's reasoning — or `judging…` while it is still being
  decided. The judge's prompt is the operator's own, and its answer is held to
  a schema: a reply that does not answer with a score and a verdict is refused
  by name rather than being scored zero and quietly rejecting the applicant.
- **Qualify** and **Reject** are a decision; a decided row offers neither.

A shield card above the table appears when the anti-abuse gate has turned
applicants away: `Blocked N abusive attempt(s)`, with the reasons and counts.
Those are not prospects and are not listed as people.

## Onboarding page

A live editor with the real page beside it: *"Live preview — this is exactly
what applicants see."* **Save draft** keeps it to yourself; **Publish** makes it
the page the public sees.

### The fields are the form

**The field list *is* the form.** Turning a field off means removing it from the
list; adding one means adding it. Each field has a **Label**, a **Key**, a
**Type**, **Required**, and — depending on the type — **Options**, **Min
length**, **Max length**, **Digits only**.

Three things follow from that and are worth knowing:

- **`required` is enforced from this list**, and an unconfigured field is never
  demanded. A field you remove is not secretly still required.
- **`email` cannot be removed.** The velocity caps, the disposable-address check
  and the duplicate check are all keyed on it.
- **Adding a field needs no migration.** Any key outside the reserved ones
  lands in the prospect's attributes and appears in **Prospects** on its own.

The validation vocabulary is deliberately small — required, digits-only, a
minimum and a maximum length — **and deliberately not a regular expression**. A
pattern here would be written by an operator and run against whatever an
anonymous stranger types into a public form, which is a way to take the server
down with the operator's own configuration.

The refusal a visitor reads names the **translated** label, so the server
translates the page before it validates.

### Branding and rendering

**Logo text**, **Eyebrow**, **Hero title**, **Hero subtitle**, **Button
label**, **Footer**, and the funnel's own palette — the same token vocabulary
as the console's [theme](admin.md#theme), so a customer's colours are written
once and worn by both.

**Landing renderer** picks how the page is drawn: the built-in themeable shell,
a plugin's own bundle, or a sandboxed HTML template. All three go through the
same anti-abuse gate.

Unlike the console's theme, a low-contrast funnel palette is **warned about
rather than refused** — it is a marketing page, and there is always a way back
to this editor.

### Translating the copy

The funnel's copy is yours, so its translations are an overlay on this
document rather than a product catalog. A translation matches a field **by key**
and takes only its label and its options: it can never rename a key, change a
type, flip `required`, or reach the judge's prompt or the theme. The body a
visitor submits is identical in every language.

A language with no copy behind it is never offered, and an unknown one falls
back **whole** rather than half-translated. `?lang=` in the URL wins over
everything, because a funnel is a page people are linked to and the switcher
must leave a shareable address.
