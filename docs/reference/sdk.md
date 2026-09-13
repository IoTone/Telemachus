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

## The route table

`server/routes.rkt` declares every HTTP route with its permission, authentication, feature flag and one line of documentation; the server refuses to boot if the table and the handlers disagree. [api.md](api.md) is rendered from it.
