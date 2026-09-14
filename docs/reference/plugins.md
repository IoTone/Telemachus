# Plugins

A plugin is a directory under `plugins/` with a `plugin.json` manifest (`id`, `name`, `version`, `description`, `entry`) and an entry module. Plugins run in-process with platform privileges; placing one in the directory is the consent.

## Loaded plugins

| Plugin | Version | Tools | Workflows | Description |
|---|---|---|---|---|
| Founders beta onboarding (`beta-onboarding`) | 0.1.0 | — | — | A customized beta funnel (founders program) registered via the SDK's init! hook. |
| Document Indexer (`doc-indexer`) | 0.1.0 | — | `index-documents` | A workflow that extracts text from repository documents into the search index: find what is unindexed, fan out, extract. Re-run it any time; it only touches what changed. |
| Document Pipeline (`doc-pipeline`) | 0.1.0 | — | `process-upload` | Process an uploaded document: extract its text, pull structured fields against a JSON schema (refused if they do not conform), fill a form template, and translate the result into the team's languages. Every output is a repository document beside the source, with provenance. |
| Example Tools (`example-tools`) | 0.1.0 | `word_count` | — | A sample third-party plugin: adds a word_count tool. |
| Knowledge Graph (`knowledge-graph`) | 0.1.0 | — | `index-knowledge` | A workflow that extracts entities and relations from the team's indexed documents into the knowledge graph, every fact traceable to the document and version it came from. Re-run it any time; it only touches what changed. |
| rs3 — local content-addressed blob store (`rs3`) | 0.1.0 | — | — | Stores document bytes on the local filesystem, addressed by their SHA-256. The default backing store for the document repository. |
| Translate Chat (`translate-chat`) | 0.1.0 | `chat_message`, `translate_text` | `translate-chat` | A demo workflow plugin: chat once, fan the reply out to Spanish/Dutch/Icelandic, then bring each back to the user's own language. |

## The seams a plugin may fill

| Seam | How | Where it lands |
|---|---|---|
| Tools | `(provide tools)` — a list of `(name schema permission handler)`; the handler is `(conn principal args) -> result` | the same registry as built-ins: per-tool RBAC and per-team activation apply |
| Workflows | `(provide workflows)` — specs from `define-workflow`, or `workflows/*.json` | validated like an API-published spec; materialized into a team on first lookup |
| Anything else | `(provide init!)` — runs with full SDK access at load | e.g. `register-blob-store!` (the `rs3` local store), `register-onboarding!` (a beta funnel experience) |
| A beta funnel bundle | a `bundle/` directory served at `/beta/bundle/<id>/` | a Tier-B custom frontend over `window.Telemachus.beta` |

See [sdk.md](sdk.md) for the authoring surfaces.
