# Knowledge Graph

*Proposal for review. The largest unknown left in the FSD, so this is deliberately
the narrowest thing that is still a knowledge graph — a v1 you can build, ship, and
then find out what people actually ask of it. The policy forks are under
**Decisions to confirm**.*

## What it is, and what it is not

A knowledge graph here is **entities and the relations between them, extracted
from the team's own documents, with every fact traceable to the document and the
version it came from.** It answers "what do we know about *X*, and where did we
learn it" — across a repository nobody can read end to end.

It is *not* a general-purpose graph database, a reasoning engine, an ontology
project, or a place where facts live that did not come from a document. Nothing
enters the graph without a source. That single rule is what makes the rest of this
design fall out: authorization is inherited from the source, staleness is inherited
from the source, and deleting the source deletes the fact.

## Where it sits — composed, not built

Everything the graph needs already exists. This is the same argument the
Localization Manager just made good on:

| Need | Already have |
|---|---|
| The documents | the **repository** (any format, creator-set visibility, versioned) |
| Their text | **`repo_text`**, produced by the `index-documents` workflow (slice 54) |
| A way to run extraction over a corpus without flattening the model | the **workflow engine**: find-unprocessed → `map` fan-out → an LLM tool, quota-admitted |
| Who may see a fact | **`can?`** on the source object — no new authorization code, just as the repository needed none |
| Meter the AI spend | the **quota** ledger, `ai.tokens.total`, per team |
| Surfaces | **search** (`search-all`), an **agent tool**, a console tab |

The new parts are two tables, one extraction tool, one workflow spec, one query
module and one tab.

## Model

Three concepts. **Entities** are things with a type and a canonical name.
**Relations** are typed, directed edges between two entities. **Mentions** bind
either to the document and version that asserted it, with the sentence that did.

```
kg_entities(id pk, team_id, type, name, name_norm, description, first_seen_at,
            uniq(team_id, type, name_norm))
kg_relations(id pk, team_id, subject_id fk, predicate, object_id fk, first_seen_at,
             uniq(team_id, subject_id, predicate, object_id))
kg_mentions(id pk, team_id, entity_id fk | relation_id fk,   -- exactly one
            object_id, version_id, snippet, extracted_at)
```

- **Team-scoped**, like notes and documents; the org gate applies at step 0 as
  everywhere. Not instance-scoped — a company's knowledge is not the product's.
- **Deduplication is `(type, name_norm)`**: "Acme Robotics", "ACME robotics" and
  "Acme Robotics Inc" are the same `organization` once normalized (case, whitespace,
  a small suffix list). Cross-type merging ("Acme" the org vs "Acme" the product)
  is deliberately NOT attempted in v1; it is where knowledge graphs go to die.
- **Types are an open vocabulary with a shipped starter set** — `person`,
  `organization`, `product`, `place`, `event`, `concept` — and a plugin may add to
  it. A closed set makes the extractor refuse things; an unbounded one makes the
  graph unqueryable. Open-with-starter is the compromise, revisited under KG‑1.
- **Predicates are free text, normalized** (`works_at`, `part_of`, `depends_on`), from
  the extractor's own choice, lower-snake-cased. The starter prompt suggests a
  dozen; it does not enforce them.
- **Nothing here is authoritative on its own.** An entity or relation with zero
  mentions is garbage-collected. The graph is a *view over the documents*, and the
  mentions table is the join that makes that literally true.

## Extraction pipeline

A workflow, `index-knowledge`, in the same plugin family as `index-documents`:

```
kg_list_unextracted (≤ 40 objects/run, team-scoped)
  └─ map ──▶ kg_extract (LLM tool: repo_text → {entities, relations}, with snippets)
                └─ upsert entities/relations/mentions for (object_id, version_id)
```

- **One document per tool call, batched by the workflow.** The map fan-out is what
  makes the concurrency cap and the quota apply; a bulk extraction over 5,000
  documents is a queue of small jobs, cancellable, not one long one. This is the
  drafting pattern from the Localization Manager, and it earned its place there.
- **The extractor is a `define-tool`** that asks the model for a strict JSON
  shape and **refuses anything that does not validate** — a mention whose snippet
  is not a substring of the source text, an entity with an empty name, a relation
  to an entity not in the same reply. The Manager's lesson applies unchanged: a
  bad fact that looks finished is worse than a missing one.
- **A new version re-extracts and supersedes.** Mentions are keyed by
  `(object_id, version_id)`; extracting version *n+1* removes version *n*'s
  mentions for that object, and entities left with no mentions are pruned. The
  graph never says something the current documents no longer say.
- **Deleting a document deletes its mentions**, in the same transaction the
  repository already uses. Same pruning.
- **An unreadable document records nothing and never wedges the run** — the
  `index-documents` rule, kept.

## Authorization — inherited, never assigned

A fact is visible to a principal **iff at least one of its mentions is on an
object that principal `can?` read.** There are no permissions on entities. There
is no "graph visibility" to configure. There is nothing to get wrong.

The consequence is deliberate and should be stated plainly: a fact that appears in
one private document and one team document is visible to the team, *and its
snippet from the private document is not.* Mentions are filtered per-row exactly
as search results are. The alternative — all-sources-must-be-visible — hides a
public fact because a private note also states it, which is both surprising and
unhelpful. KG‑3.

## Query surface

Three, in order of how much they will actually be used:

1. **Search.** `search-all` gains a fourth result kind, `entity`, hit by name;
   the row filter is the mention rule above. Zero new UI: entities appear beside
   notes and objects.
2. **The agent tool.** `kg_query(name | id, hops ≤ 2)` returns the neighbourhood as
   text with citations. This is the one that turns "what do we know about Acme"
   into an answer with sources, and it is where the graph earns its keep.
3. **A console tab.** An entity browser (type filter, search), and for one entity:
   its relations, and every mention with a link to the document and version. Lists
   and links. **No graph visualization library** in v1 — a force-directed canvas is
   a dependency and a week of tuning, and lists with citations are what a reviewer
   needs first. An inline SVG neighbourhood, hand-drawn like the brand marks, is a
   later slice if the tab proves used.

The HTTP surface is small and mirrors the tab: `GET /api/kg/entities?q=&type=`,
`GET /api/kg/entities/<id>` (relations + mentions, filtered), and
`POST /api/kg/extract` to queue the workflow (`workflows:run`).

No graph query language. Not Cypher, not Gremlin, not SPARQL — no dependency, no
parser, no injection surface, and no user has asked for one. `hops ≤ 2` from a
named entity covers the questions people have. KG‑5.

## Data shapes (backend-neutral)

The three tables above, plus nothing. `repo_text` is read, never written. Jobs,
quota and audit are the existing tables. The extractor's output contract:

```
{ "entities":  [{"type":"organization","name":"Acme Robotics","description":"…",
                 "snippet":"…verbatim from the source…"}],
  "relations": [{"subject":"Acme Robotics","predicate":"customer_of",
                 "object":"Globex Media","snippet":"…verbatim…"}] }
```

`snippet` must be a substring of the text the tool was given. That is the
validation, and it is also the provenance.

## Contract (any backend implements)

```
KnowledgeGraph:
  extract(object_id, version_id) -> {entities, relations}   # the tool; validated, refuses on bad shape
  upsert(team, object_id, version_id, extraction)           # supersedes prior version's mentions
  forget(object_id)                                          # on delete; prunes orphans
  entity(principal, id) -> {entity, relations, mentions}    # mention rule applied per row
  find(principal, q, type?) -> [entity…]
  neighbourhood(principal, id, hops) -> subgraph            # for the agent tool
```

## Bootstrapping plan

1. Migration + `domain/kg/kg.rkt` with `upsert`/`forget`/`entity`/`find` and the
   mention-rule filter; unit tests that prove the rule (private-vs-team mentions).
2. `kg_extract` tool with strict validation; test it against the deterministic
   fallback model AND a live one, as the Manager's drafting was.
3. The `index-knowledge` workflow; run it over the seeded sample documents.
4. Search integration (the fourth result kind) — smoke-tested.
5. The agent tool; then the tab.

## Decisions to confirm

| # | Decision | Recommendation · alternatives | Why it matters |
|---|---|---|---|
| **KG‑1** | Entity types | **Open vocabulary with a shipped starter set**, plugins may extend · vs a closed schema · vs fully open | Closed refuses real things; unbounded is unqueryable. |
| **KG‑2** | Scope | **Team-scoped**, org gate at step 0 · vs instance-wide | A company's knowledge is not the product's. |
| **KG‑3** | Visibility of a fact | **Visible if ANY source mention is readable**; snippets filtered per row · vs all sources must be readable | All-sources hides public facts because a private note repeats them. |
| **KG‑4** | Dedup | **`(type, name_norm)` only; no cross-type merging in v1** · vs embeddings-based entity resolution | Cross-type merging is where knowledge graphs die; earn it with data. |
| **KG‑5** | Query language | **None; `hops ≤ 2` from a named entity** · vs Cypher/Gremlin/SPARQL | No dependency, no parser, no injection surface, no demand. |
| **KG‑6** | Visualization | **Lists with citations first; hand-drawn SVG neighbourhood later if used** · vs a graph-viz library now | A force-directed canvas is a dependency and a week of tuning before anyone has asked a question. |
| **KG‑7** | Extraction model | **The `utility` role, `translation`-style opt-in per team** · vs always the chat model | Extraction is bulk and cheap-model-shaped; the Manager's LOC‑5 precedent. |
