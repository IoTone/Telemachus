# The route table and the generated reference


## Declared, not enacted

Every HTTP route is one entry in `server/routes.rkt`: method, path pattern, handler key, how it authenticates, the permission it enforces, the feature flag it sits behind, and one line of documentation. The server binds keys to handlers in one table and refuses to boot if either side names something the other lacks. An endpoint cannot exist undocumented, and a documented endpoint cannot fail to exist. Public-ness is declared rather than a comment beside a `cond` clause, which is what lets a test assert it.

## Generated and gated

`telemachus-docs describe` evaluates the tool registry, the plugin loader, the workflow specs, the permission catalog and the route table into one JSON model; `render` writes `docs/reference/`; `check` regenerates and fails on a byte of difference. The output is committed, so a pull request that changes a tool’s parameters shows the documentation change in the same diff. Every description is also a `doc.*` message in the catalogs, translated by the same Manager as everything else.

    racket cli/telemachus-docs.rkt render      # regenerate docs/reference/
    racket cli/telemachus-docs.rkt check       # the CI gate
    racket cli/telemachus-docs.rkt render --locale ja

Adding an endpoint is therefore: one entry in the table, one handler in the map, one render, one commit. Forgetting the render fails CI; forgetting either half refuses to boot.
