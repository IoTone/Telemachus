# Repository

Any file, any format, in and out byte for byte — pdf, svg, png, docx, xml, md.
Four parts: **Store** (the upload form), the **Documents** listing with its path
strip, a detail panel, and **S3 access keys**.

## Uploading

**Store** takes a **File**, a **Path** and a **Visibility**.

`Any format. The path may contain slashes; uploading the same path again keeps
the old copy as a version.` When the path already exists the form says so
before you press Upload — *"This path exists — uploading saves a new version
and keeps its current visibility"* — so a version is never a surprise.

The upload ceiling is an operator's setting. Something far larger belongs on
the S3 endpoint, which is the data plane built to move it.

## The listing

`All` / `Shared with me`, a **Refresh**, and the path strip described under
[Documents](documents.md) — folders here are the same prefixes of the same
keys.

**`Shared with me` is "handed to me"**: objects somebody granted you that you
do not own. A team-visible document is not "shared with me", and neither is
your own.

Each row offers **Download**, **Link** and **Details**.

## Link — a presigned URL

`Link` produces a URL that downloads the document **without signing in**, for a
few minutes.

Read what it says: *"Anyone with this link can download the document for the
next N minutes, without signing in. It carries your S3 key's permissions and
stops working if that key is revoked."* It is signed with **your own newest S3
key**, so it can never exceed what that key may do, and revoking the key kills
every link made with it.

## The Details button

**`Details` on a document's row opens that document's detail panel**: its
versions, its visibility and who it is shared with, what has processed it, and
the control that runs a workflow over it. It changes nothing by itself — it is
how you look at one document rather than the list.

The panel opens **below the listing**, and scrolls itself into view when it is
under the fold, so on a long list the answer to "nothing happened" is that it
happened off screen. `Close` dismisses it.

It carries four things.

### Versions

Every upload to this path, newest first, each downloadable. Nothing is
overwritten.

### Visibility and sharing

**Visibility** is the same three choices, and the hint states the rule: *"You
set this because you uploaded it. Sharing narrows a team document to just the
people you name."*

**Share with** offers the team's own members and the company's teams, and
nothing outside the company is ever on the list. **Can** is one of three, and
the hint is the whole model:

> View opens and downloads; edit also uploads new versions; manage also shares,
> revokes and changes visibility.

**Until (optional)** is a date, inclusive. An expired grant is kept and listed
as `expired` rather than vanishing, so the record of what was shared survives.
**Revoke** removes one principal's access.

Two rules worth knowing:

- **Only `manage` can re-share.** A colleague given `view` cannot pass it on.
- **A team admin reaches a colleague's team-visible document and never their
  private one.** Private is private from admins too; only a grant or the owner
  opens it.

### Processed by

Every derived document, every source, and every workflow run that touched this
document — found through the derivation records, the triggers that fired, and
the runs whose input named it. Each row is checked on its own, so a run you may
not see is simply absent.

`Derived from` points the other way, and a `trigger` badge says a trigger
started the run rather than a person.

`No workflow has processed this document yet.` is a statement about this
document, not about the pipeline.

### Run workflow…

Starts a [workflow](workflows.md) on this document, prefilling the document's
own id. The run is **yours**: its outputs are yours, and if the owner has
already run the same pipeline the derived paths are their private objects and
your run fails on the write rather than clobbering them.

## Annotating a region

A person can mark a place on a document — a box on a page, or a range of
characters — with a note or a highlight. **Anyone who may read a document may
annotate it**, deliberately: a specialist handed a document to review would
otherwise be unable to mark it up. Only the author may edit their own
annotation; the author or a `manage` steward may delete one. There is no canvas
for drawing them in this console — that is a plugin's screen; the storage and
the API are the platform's.

An annotation is bound to the version you were looking at, so re-uploading
leaves it marked as applying to replaced bytes rather than silently moving it.

## S3 access keys

`Any S3 client works: aws-cli, rclone, boto3, Cyberduck. Your team is the
bucket.`

**Key created** shows the secret **once**: `Copy the secret now — it is not
shown again.` There is no way to recover it; create another key and revoke this
one.

If the endpoint is not switched on, the card says so and names the setting an
operator needs (`TMACH_S3_PORT`). A key is scoped, so it can be narrower than
your own account — and an S3 key issued with only file permissions cannot start
a workflow, which is why a [trigger](workflows.md) that should fire on an S3
upload needs a key with the workflow permissions too.
