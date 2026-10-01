# A map of the code


## Layers

The server is one module, `server/main.rkt`, and it is deliberately thin: it parses requests, resolves the principal, calls into `domain/`, and encodes the response. Everything that could be wrong about the product lives in `domain/`, which knows nothing about HTTP and is what the unit suites exercise directly.

| Module | Owns |
|:---|:---|
| `domain/authz` | principals, roles, the permission catalog, `can?`, grants, tokens, audit |
| `domain/db` | migrations, applied at startup, dialect-neutral |
| `domain/repo` | the document repository: objects, versions, blobs, sharing, provenance, triggers, the pipeline tools |
| `domain/flow` | the workflow engine: spec validation, bindings, the run reducer |
| `domain/sched` | the job scheduler and the concurrency governor |
| `domain/quota` | the usage ledger and limits |
| `domain/agent` | the tool registry, the agent loop, the plugin loader |
| `domain/ai` | the model executor: one call, or a stream, or the simulated fallback |
| `domain/i18n` | catalogs, ICU formatting, the lint, the Localization Manager |
| `domain/kg` | the knowledge graph |
| `domain/apps` | search, translation — applications composed from the rest |
| `domain/orgs` | multi-tenancy: organizations above teams |
| `domain/beta` | the onboarding funnel |

## The four small libraries

`pkgs/` holds code that knows nothing about Telemachus and could be lifted out.

`db-kit/portable` is a drop-in for Racket’s `db` that rewrites `?` placeholders to `$n` on PostgreSQL. Always require it instead of `db`. Forgetting is invisible on SQLite and fails on PostgreSQL with `syntax error at or near "AND"` — and test files issue raw SQL too, so the rule applies to them.

`web-kit` wraps Racket’s `web-server` for the JSON control plane and adds `web-kit/http1`, an HTTP/1.1 listener that treats request bodies as ports. The second exists because the S3 endpoint moves multi-gigabyte files and because `Expect: 100-continue` has to be answered lazily, on the first read of the body, so that a handler refusing before it reads never receives the bytes at all.

`cli-kit` is argument parsing for the command-line tools, and an EXIT CONTRACT. A tool could say “it worked” and “it broke”; it had no way to say the domain *refused* the input, which is a different answer needing a different response — fix the input, versus page an operator. Four outcomes now: `0` ran, with the result on stdout; `2` refused, with an error object that always carries reasons; `1` could not run, with stdout *empty*; `64` CLI misuse, on stderr. Two of those are enforced rather than documented: a refusal with no reasons is rejected (it is a 1 wearing a 2’s exit code), and a run that did not happen writes nothing to stdout, because it must not hand anyone a document.

`sha2-kit` is SHA-256 and HMAC-SHA-256 over libcrypto. It is a package rather than a module inside `domain/` because it has no platform knowledge, and separate from `crypto.rkt` — whose contract is “no native dependencies” — because it takes the FFI. Correctness is pinned to the NIST vectors: the risk in a binding is a wrong signature, and a vector says so at once.

## One principal, one check

Every request resolves to a *principal*: a user id, a team id, an operator flag, an optional org role, and — for API tokens and S3 keys — a scope list that caps what the issuer could do. Every authorization decision in the platform is one function, `can?`, described in the next chapter. Handlers call `require-perm`; a refusal raises, and the server turns it into a localized 403.

## Files to open

`server/main.rkt` (skim the requires and the `HANDLERS` table), `domain/authz/authz.rkt`, `pkgs/db-kit/portable.rkt`.
