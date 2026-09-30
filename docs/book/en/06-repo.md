# The document repository


## Objects, versions, blobs

A repository object is an ownable resource with the same three fields notes carry — team, owner, visibility — so `can?` governs it with no new authorization code. Writing the same key twice appends a version rather than replacing one; the object id is the stable thing a grant or a URL points at. Bytes live in a content-addressed store keyed by SHA-256, namespaced by *organization*: global deduplication across tenants would be an existence oracle. The store is never handed a principal — only a namespace and a digest — so a storage backend has no authorization to get wrong.

Uploads are a raw `PUT` body, never base64 in JSON. Every download is served as an attachment with `nosniff` and a denying CSP unless the type is on a short inline allowlist; SVG and HTML are never inline, because they share an origin with the console.

## The S3 endpoint

A second listener speaks enough S3 that `aws`, `rclone`, `boto3` and Cyberduck work: SigV4 verified from the specification and pinned to AWS’s published vectors, path-style buckets named by team slug, ranged GETs (mandatory — the CLI downloads large objects in parallel ranges), multipart uploads. Access keys are ordinary credentials with scopes; the secret is stored in the clear because SigV4 needs it to verify. Unimplemented sub-resources answer 501, never a silent success. Presigned links are signed with the caller’s own newest key, so revoking the key kills the link.

## Sharing and provenance

Sharing is the capability model of the previous chapter, over the grants table that already existed. Provenance is `repo_derivations`: when a workflow writes a document *from* another, the output takes the source’s visibility and live grants at the moment of creation — private from its first byte if the source is — and a derivation row names the source version, the run and the step. After that the two documents are independent. “Where did this form come from” is a click.

## Files to open

`domain/repo/repo.rkt`, `domain/repo/blobs.rkt`, `plugins/rs3/`, `domain/s3/sigv4.rkt`, `docs/design/document-repository.md`, `test/repo-tests.rkt`, `test/s3-smoke.sh`.
