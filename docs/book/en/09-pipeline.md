# The document pipeline


## The first-user path

A team uploads a file and a workflow processes it: extract its text, pull structured fields against a JSON schema, fill a form template, translate the result. Four core tools compose into the shipped `process-upload` workflow; schema, template and locales are inputs, so one workflow serves invoices and intake forms with no new code. Every output is a repository document beside its source, with the source’s grants and a provenance row.

## Refuse, do not flag

The field extractor validates the model’s reply against the schema and refuses a missing required field, a string where a number was asked for, and an invented key — an object schema with no `additionalProperties` is *closed*, a deliberate departure from JSON Schema’s default. The template renderer refuses a placeholder the data cannot satisfy rather than rendering a blank: a form with an empty Total that looks finished is the failure the whole design exists to prevent. The step retries once, because a schema mismatch is the model’s mistake and a second reading at temperature zero often conforms.

## Templates

Markdown and HTML templates use `{{field}}`, dotted paths and `{{#each items}}` blocks. A DOCX template is a zip whose `word/document.xml` carries the same placeholders, and two things make that harder than it sounds: Word splits a placeholder across runs the moment the author pauses or the spell-checker looks at it, so every tag between a `{{` and its `}}` is dropped before rendering; and line items want a table row per item, so a row whose only text is `{{#each items}}` opens a block and a row that is only `{{/each}}` closes it. **PDF rendering was deferred here and is not any more** — three engines, each for the
half it is good at, and all three found at the moment they are called, so a box
without one boots and only that call is refused.

The default turns a filled Markdown or HTML template into a PDF through the document
converter and TeX engine the book itself is built with. The second takes an HTML
template and the paged-media CSS in it: running headers, a page count, and an archival
profile that a conformance validator passes at 144 rules. A headless browser was the
obvious alternative and was declined on measurements rather than taste — it implements
none of those CSS features, cannot emit the archival profile at all, brings a
JavaScript engine to a template an operator or a customer wrote, and puts a browser in
the image. What made that choice honest was measuring the *marginal* closure: the
renderer’s own dependency graph is 1.5 GB, of which 82 of 105 paths were already in the
image because the book’s toolchain had brought the font and text-shaping stack along, so
the real cost is 173 MB. The standalone figure was nine times the truth.

Two things about that engine are worth carrying away. A template reaches a repository
document by object id and each reference is read *as the caller*, then inlined, so
every other protocol can be switched off — a template that could reach any object by
id would be a way past the repository’s own gate. And the exit code is not the verdict:
a resource it could not load is logged as an error and the process exits zero, leaving a
hole where the logo was, so the log is parsed and a refused resource becomes a refusal
that names what a template may reach.

The third engine converts a filled DOCX through an office suite, which is roughly a
gigabyte and therefore *not* in the image: it is opt-in, added to the packaged path by
an integrator who installed it, and the refusal says so, because “needs an office
suite” with no hint where it comes from is how somebody concludes the feature is
broken. Its sandbox is not a flag — the suite takes no equivalent argument — so the
constraint goes on the *input*: a template that declares an external relationship, which
is how a word processor stores a linked image, is refused by name before anything
converts. That is checked before the binary is even looked for, which is what makes the
refusal testable on a platform where the suite cannot be installed at all.

## Forms somebody else wrote

Filling a template is one half; the other is an interactive PDF form that *arrived*, and
it needed two binaries rather than one. The first lists and fills, because its export
already names every field with its kind, value and options, so nothing has to be
composed in an intermediate format. The second flattens, because the first has no
flatten of any kind. A value is held to its field’s kind and a choice field to its own
options — a stored value the form’s own reader cannot interpret renders *blank* while
the document claims it was filled. And the unmatched list is computed here, because the
filler exits zero on a field name no field carries: without that, a misspelled field
hands back a document that looks filled with nothing saying which half was ignored. A
partial match is a report; every name wrong is a refusal that lists the fields the form
does have.

## Which kind of document is this

Routing wants a type, and a type comes from a *chain* of backends rather than a choice
of one: rules first, because they cost nothing and answer the same way every time, then
the model for what no rule described. **The rules backend has no regular expressions,
and the requirement asked for them** — the same reason the redaction detectors are
named rather than written, with the same weapon and the same operator-authored
configuration. The field-extraction tool’s pattern argument is not a counter-example:
that one runs against the model’s reply, which this platform asked for and bounded.

A rule match *is* the confidence. “Short-circuits when it is confident” has no degrees
for a deterministic rule, and 0.85 would be a number nothing computed. The answer lands
in three object attributes — the type, the confidence to two fixed decimals because the
metadata filter is an equality test, and which backend decided — plus a record document
beside the source, so no migration was needed. **A document this platform cannot read is
still classifiable**, which is why the text is optional and why the shipped workflow
classifies *before* it tries to read: a photograph or a scan refuses text extraction,
correctly, so a pipeline that reads first can never reach the documents that most need
routing. The first version of that workflow had it the other way round and its own test
found it.

**A low-confidence answer parks the run on a person**, and the threshold is an ordinary
branch step rather than a flag on the tool, because only a *step* can park a run — a
flag would have the tool reach into the review subsystem from inside a tool call. The
person’s label is held to the same closed set the model’s is: a free-text answer is one
keystroke from “Invoice”, “invoices” or a trailing space, and each of those is a type no
trigger and no filter will ever match, so the refusal lists the types the run offered
and says it will not guess. An approval re-records the type as decided by review at full
confidence, because leaving the model’s own guess would make a document somebody checked
indistinguishable from one nobody looked at — and would offer it for review again on the
next pass. An empty label *withdraws* the type, and the record is still written, so who
withdrew it and why survives.

Two shapes fall out of that and are worth naming because each was tempting to build
differently. The backlog is a **workflow**, not a batch mode of the tool: a flag would be
one tool call doing unbounded work with no per-document retry, no cancellation
granularity, no quota admission between documents, and a result nothing can branch on.
And the evaluation harness scores *abstention* separately from error — the rules backend
is designed to answer only when a rule matched, so counting silence as a mistake makes a
careful rule set look worse the more careful it is, and sends an operator to loosen the
rules that are carrying the load. Accuracy is over what it answered, coverage over the
set, and both are needed: a backend that answers one document perfectly is 100% accurate
and useless.

## Triggers

A trigger is a team-scoped subscription: when a document matching this prefix and these content types lands, run that workflow with it. Triggers are evaluated in exactly one place — a hook at the end of `repo-put!`, after the version commits — which covers the console upload, the text-document shim and an S3 `PUT` by construction. A match enqueues a run as the *uploader*, scopes and all; a run can only read what its uploader could read, and its outputs are owned by someone real. Fires are exactly once per version. A pipeline’s own outputs never re-fire the trigger that produced them, and an opted-in trigger never fires on the output of a run it started itself; without that rule an opted-in trigger ran itself fifty times in a test before the drain limit stopped it. An S3 key issued with the default `files:*` scopes cannot start a workflow — the trigger’s history says so plainly — and needs `workflows:run` for a prefix meant to fire.

## Files to open

`domain/repo/doc-tools.rkt`, `domain/tools/jsonschema.rkt`, `domain/repo/classify.rkt`, `domain/repo/htmlpdf.rkt`, `domain/repo/pdfform.rkt`, `domain/repo/docxpdf.rkt`, `domain/repo/triggers.rkt`, `plugins/doc-pipeline/main.rkt`, `docs/design/document-workflows.md`, `test/doc-pipeline-tests.rkt`, `test/doc-triggers-tests.rkt`, `test/doc-pipeline-smoke.sh`.
