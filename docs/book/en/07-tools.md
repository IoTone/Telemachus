# Tools and the agent


## Declaring a tool

    (define-tool doc_text
      #:description "Return the text of a repository document."
      (object string #:description "The repository object id")
      (version string #:optional #:description "A specific version id"))

    (register-tool! "doc_text" doc_text "files:read"
                    (lambda (conn principal args) ...))

`define-tool` expands to the OpenAI-compatible function schema the model sees, so the declaration and the contract are one thing. The handler gets the database connection, the calling principal and the parsed arguments; it checks its own permission and meters its own AI spend. A result that is not a string is JSON-encoded at the agent boundary and kept as a value inside a workflow — a list-returning tool feeds a `map` step directly.

## The registry

Built-in tools, plugin tools and workflow tools all land in one registry, tagged with their source. A team may disable any tool; the agent offers only enabled tools to the model and dispatch refuses disabled ones. Plugins run in-process with platform privileges — placing one in `plugins/` is the consent — and sandboxed out-of-process plugins exist as a separate, capability-scoped mechanism, speaking newline-delimited JSON over stdio.

An out-of-process tool may answer with STRUCTURE, not only text: its result message carries an optional structured field beside the human one. Without it every such answer became a JSON *string* by the time a workflow bound it, so a later step needed an in-process shim whose whole job was to parse what the platform had just stringified — while an in-process tool had been free to return a value for slices. The platform never guesses that a string was meant to be JSON; the plugin says so by sending the structured field.

## The model seam

Everything that calls a model goes through `run-chat` in `domain/ai/executor.rkt`, and the tools that need structured output take the model as a parameter (`current-doc-chat`). Unit tests script it; the HTTP smokes run `test/mock-llm.rkt`, a deterministic OpenAI-compatible server whose chat mode answers from a file of `needle: reply` pairs, longest needle winning. The same smoke runs against a live model when the model URL is set. This is how a pipeline that needs a model is tested in CI in seconds and verified against qwen2.5:7b on a developer’s machine.

## What a message may carry

A message’s content is a string *or* a list of parts, the OpenAI-compatible `[{type: "text", text: ...}]` shape that gateways and multimodal servers send. One module decides this for every path — the agent loop, the chat endpoint, the stream and the pull wire — so they cannot disagree. Text parts are joined; content that carries parts and *no* text is a named error rather than a quiet empty string. That distinction is the whole point: an empty reply must never be manufactured, because it is indistinguishable from a model that said nothing. Content that is absent or empty is still legitimately empty — that is what a tool-call-only turn looks like — so the agent parsers raise only when the turn has no tool calls either. This was a silent bug for a year: `(if (string? c) c "")` read every reply, and a provider that answered in parts produced an empty message and no complaint.

A caller may also ask for a shape. `response_format` — `text`, `json_object` or `json_schema` — rides to the provider *and* is checked against the reply here, because most local servers ignore the field entirely and a schema request would otherwise come back as prose the caller parses as though it had conformed. Validation is the same subset validator, and the same `$.total: expected number, got string` refusal, as the document pipeline’s extraction. The simulated no-model fallback refuses a format rather than passing an upper-cased echo off as conforming JSON. Streaming judges the format once the stream has ended and reports the verdict in its final event; raising after the answer has already gone out would be worse.

## Files to open

`domain/tools/dsl.rkt`, `domain/agent/registry.rkt`, `domain/agent/plugins.rkt`, `domain/ai/executor.rkt`, `docs/reference/tools.md`.
