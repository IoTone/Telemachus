# SDK

The authoring surfaces a plugin, a tool or a workflow is written against. The durable product is the contract: a second implementation targets the same specs, APIs and security model.

## `define-tool`

A tool is a declaration that expands to the OpenAI-compatible function schema the model sees. Parameters are required unless `#:optional`; `#:enum`, `#:items` and `#:items-of` (arrays of objects) are supported.

```racket
(define-tool doc_text
  #:description "Return the text of a repository document."
  (object string #:description "The repository object id")
  (version string #:optional #:description "A specific version id"))

(register-tool! "doc_text" doc_text "files:read"
                (lambda (conn principal args) ...))   ; -> a string or a jsexpr
```

The handler receives the database connection, the calling principal and the parsed arguments. It checks its own permission (`require-perm`) and meters its own AI spend (`tenant-quota-record!`); a result that is not a string is JSON-encoded at the agent boundary and kept as a value for a workflow step.

## Artifact-shaped results

A handler may return a string, a JSON value, or an **artifact** — a result that names a thing rather than carrying it:

```racket
(artifact #:kind "document" #:title (hash-ref o 'key) #:summary "the filled form"
          #:content-type ct #:object-id (hash-ref o 'id) #:version-id (hash-ref o 'version_id)
          #:extra (hasheq 'object_id (hash-ref o 'id)))   ; keys a workflow step may bind
```

Kinds are `document`, `table`, `text`, `link`, `image`. The model receives one line (`[document] inbox/acme.pdf.form.docx — the filled form (application/…) object_id=…`) instead of the payload; the console renders a card that opens the document or follows the link; a workflow step keeps the whole value, so `(out step result object_id)` binds as before. Every document-pipeline tool returns one.

## `define-workflow`

A workflow is a validated data spec; the macro emits it, and a JSON document posted to `POST /api/workflows` goes through the same validator. Unknown fields are rejected. Bindings are the frozen sublanguage: `(in name)`, `(out step path…)`, `(item path…)`, `(index)`, `(locale)`, `(run-id)`, `(team-id)`, `(user-id)`, and seven predicates for `choice`.

```racket
(define-workflow process-upload
  #:input ([object_id string] [schema object] [template string] [locales array])
  (step text   (tool doc_text #:object (in object_id)))
  (step fields (tool doc_extract_fields #:text (out text result) #:schema (in schema)
                                        #:object (in object_id) #:run (run-id) #:step "fields")
               #:retry 1)
  (step has_form (choice (empty (in template)) #:then translate_source #:else form))
  ...)
```

Every step is a scheduler job: durability, cancellation, quota admission and the org gate are inherited. `map` fans out over a list, one job per item. The shipped workflows are in [workflows.md](workflows.md); the format is served at `GET /api/workflows/schema`.

## The blob store

`register-blob-store! name (hash 'put! 'get 'delete! 'stat)`. The store is handed a namespace (the org id) and a SHA-256 digest, never a principal — a backend has no authorization to get wrong. `TELEMACHUS_BLOB_STORE` selects one.

## The onboarding provider

`register-onboarding! name experience` contributes a beta funnel experience document (fields, copy, theme, judge prompt). The published one in the database wins over any registered default.

## The browser SDK

`/beta-sdk.js` exposes `window.Telemachus.beta` — `config()`, `challenge()`, `signup(fields)` — for a Tier-B bundle; a Tier-C template gets the same three endpoints over CORS from its sandboxed iframe.

## Plugin routes

A plugin may contribute authenticated HTTP endpoints — the API a Tier-B onboarding bundle or an app-specific console calls:

```racket
(define (word-count-route conn principal args)          ; args: {params, query, body}
  (define text (hash-ref (hash-ref args 'query) 'text #f))
  (unless (string? text) (raise-user-error 'word_count "text is required"))   ; -> 400
  (hasheq 'words (length (string-split text))))               ; -> 200 JSON

(define routes
  (list (list "GET" "/word-count" "chat:use" word-count-route "Count the words in ?text=.")))
```

The platform mounts it at `/api/x/<plugin-id>/word-count`, so a plugin can never shadow a core route. Every plugin route requires a bearer token; the named permission is checked through `can?` before the handler runs, exactly as a tool's is. A malformed entry fails the plugin's load.

## Job kinds

A plugin may add background work of its own. `init!` runs at load with full SDK access, and that is the documented route:

```racket
(define (word-count-job conn principal payload)       ; -> a jsexpr result
  (hasheq 'words (length (string-split (hash-ref payload 'text "")))))

(define (init!)
  (register-job-kind! "x.example-tools.word-count" word-count-job))
```

The name is **platform-fixed**: `x.<plugin-id>.<name>`, the same rule plugin routes follow, enforced while the plugin's `init!` runs — so a plugin can never take a core kind's name (`flow.step`, `infer.chat`) or another plugin's, and a violation fails that plugin's load rather than surfacing at claim time.

A plugin kind is an ordinary job. It inherits everything the row carries, not anything from the plugin: the enqueuing team and user, the per-team concurrency cap and quota admission at claim, the org gate on whatever the handler touches, cancellation, and the lease that returns it to the queue if the worker dies. `enqueue-job!` submits one; `GET /api/jobs` lists it like any other.

A **remote** kind (`#:remote? #t`) has no in-process handler — it is claimed by a pull executor over HTTP — and must carry `#:validate`, a procedure returning a string naming the problem or `#f`. It is the only thing standing between a worker's reply and the rest of the system, so it is required, not optional.

## The route table

`server/routes.rkt` declares every HTTP route with its permission, authentication, feature flag and one line of documentation; the server refuses to boot if the table and the handlers disagree. [api.md](api.md) is rendered from it.
