# The route table and the generated reference


## Declared, not enacted

Every HTTP route is one entry in `server/routes.rkt`: method, path pattern, handler key, how it authenticates, the permission it enforces, the feature flag it sits behind, and one line of documentation. The server binds keys to handlers in one table and refuses to boot if either side names something the other lacks. An endpoint cannot exist undocumented, and a documented endpoint cannot fail to exist. Public-ness is declared rather than a comment beside a `cond` clause, which is what lets a test assert it.

**The table is the enforcement, not a description of it**, and for the first months
of this codebase it was not. The three fields were documentation: each handler did its own
authentication, permission and feature check by hand, and the generated reference
published the declarations as fact. One route declared a permission and enforced
nothing — straight from authentication to the data, so any authenticated caller could
read the team’s, the company’s and the *instance’s* retention policy, while its
sibling two definitions below had the line. One forgotten line and nothing checking.
The dispatcher applies all three now, and the order is load-bearing: the
multi-tenancy gate first, so a single-tenant instance answers 404 rather than telling
an anonymous caller which routes exist; then authentication, so a 401 precedes any
mention of a permission; then the feature flag; then the permission. The handlers keep
their own checks on purpose — two layers on the authorization path is a feature, and
deleting ninety-three of them would make the dispatcher a single point of failure.

**A permission the dispatcher may pre-check is not the same as one it may not**, and
the distinction is per *route* rather than per permission. The same permission on a
route with a document to weigh must be left to the authorization function, which also
admits the owner and anyone holding a grant — a role pre-check there would be
*stricter* than the handler’s own and would refuse exactly what sharing exists for.
Deriving that from the permission instead of declaring it per route was the first
attempt and it left the unprotected route above looking covered.

**A feature flag has three layers**, and the one place in this platform where absence
means *enabled*: the instance, then the company, then the team, each able only to
tighten. A team cannot turn on what the instance turned off, and that attempt is a
refusal naming the layer rather than a stored row that resolution ignores — but
turning a feature *off* is allowed at every layer, including under a layer that
already says no, because that is a team recording its own intention and it survives
the layer above being switched back on. Absence means enabled so that an instance
which configured nothing behaves exactly as it did before the layers existed.

**And a gate that reads a declaration can only ever check one direction.** A second
one asks the opposite question — is every permission in the catalog enforced
*somewhere* a route can reach — and it found a permission granted to three roles,
described in the catalog, read by nothing, while the endpoint it was obviously for
demanded the instance operator’s. So a team that hit its daily token default could be
unblocked only by the operator. That gate fails in both directions, so a permission
that is deliberately unreachable has to be listed with a reason; a one-directional
allowlist rots into a list of excuses.

## Generated and gated

`telemachus-docs describe` evaluates the tool registry, the plugin loader, the workflow specs, the permission catalog and the route table into one JSON model; `render` writes `docs/reference/`; `check` regenerates and fails on a byte of difference. The output is committed, so a pull request that changes a tool’s parameters shows the documentation change in the same diff. Every description is also a `doc.*` message in the catalogs, translated by the same Manager as everything else.

    racket cli/telemachus-docs.rkt render      # regenerate docs/reference/
    racket cli/telemachus-docs.rkt check       # the CI gate
    racket cli/telemachus-docs.rkt render --locale ja

Adding an endpoint is therefore: one entry in the table, one handler in the map, one render, one commit. Forgetting the render fails CI; forgetting either half refuses to boot.

The same model also emits `openapi.json`, so a viewer or a client generator can read
the surface. **It carries no request or response schemas and says so in its own
description**, because they are declared nowhere: they are read out of the
handler bodies one at a time, so emitting them is not a generation problem but a
decision about where a shape should live, with every route in the table behind it. A reference that
implied completeness would be worse than no reference, so the absence is stated in the
document and a test pins both halves — the note must be there, and no operation may
carry a body or a response. The response field is omitted entirely rather than stubbed:
a fabricated “200: OK” on every operation is the generator asserting a status code it
has not read, wrong for every 202, 204 and 302, and the one claim a code generator
would act on.

## Files to open

`server/routes.rkt`, `server/main.rkt` (the dispatcher), `cli/telemachus-docs.rkt`, `docs/reference/`, `test/route-perm-gate-tests.rkt`, `test/openapi-tests.rkt`.
