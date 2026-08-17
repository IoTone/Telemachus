# Odysseus — Feature Inventory

**Purpose of this document.** A local, code-grounded map of *what Odysseus does*
— its product features, subsystems, data model, security posture, and the
design patterns worth understanding — so it can be reviewed when deciding what
belongs in **Telemachus**'s `FeatureRequirements.md`. This is a description of
the *existing* system, not a plan and not a requirements list.

It was assembled by reading the current tree (Python `src/`, `routes/`, `core/`,
`services/`; the Racket port under `racket/`; and the docs), not from memory.
Where a capability the Telemachus brief calls for is **absent or thin** today,
that is called out inline as a *Gap* so the requirements review has it.

> **Scope note for the MIT successor.** Telemachus intends to carry over only
> code the owner wrote themselves — in practice the **Racket** implementation
> and the owner-authored **documentation**. The Python backend is described here
> for its *concepts and contracts*, which are reusable, not as importable code.
> A separate `TelemachusMigration.md` will decide provenance file-by-file.

---

## 0. What Odysseus is

A self-hosted, **privacy-first** AI workspace: a single FastAPI monolith
(`app.py`) wiring ~50 route modules over a SQLAlchemy/SQLite data layer, with an
optional ChromaDB + FastEmbed vector tier that degrades gracefully when absent.
It bundles several distinct end-user apps (chat, research, documents, email,
notes/tasks/calendar, gallery) around local or hosted LLMs, plus an agent/tool
runtime, a hardware-aware local-model "Cookbook," and MCP support. The frontend
is ~140k LOC of framework-less vanilla-ESM JavaScript (out of scope here).

A **Racket port** (branch `racket-port`) is migrating the backend capability-by-
capability behind a strangler-fig proxy; ~20 of ~58 agent tools are ported so
far. See §8.

**Design point:** "trusted users on a private network," i.e. treat the whole app
like an admin console. Strong perimeter auth and prompt-injection discipline;
*intentionally* no in-process sandbox around what a trusted admin/agent can do on
the host. This shapes everything in §6.

---

## 1. End-user applications

### 1.1 Chat + Agents
Conversational AI over any configured endpoint (local Ollama / llama.cpp / vLLM,
or hosted APIs), with three session **modes**: `chat`, `agent`, `research`.

- **Agent mode** — a multi-step reason→act loop (§4.1): shell/Python, file ops,
  web search/fetch, MCP tools, skills, AI-to-AI session tools; capped rounds.
- Streaming responses (SSE); **detached runs** survive client disconnect/refresh
  via a replay-buffer + subscriber fan-out (in-memory, not restart-durable).
- Vision (image inputs) auto-detected by model name; file/attachment uploads
  inlined; large PDFs/Office docs auto-promoted to pageable Documents.
- URL and **YouTube** awareness (auto-fetch page text / transcript + comments).
- Long-term **memory** (per-user facts, vector-backed) and **RAG** over personal
  docs.
- **Crew members** — custom AI personas (personality, system prompt, model,
  avatar, enabled tools, greeting), including a singleton "personal assistant."
- User-authored sandboxed **mini-apps** (HTML/JS "user tools" with a per-tool
  key/value store).

Entities: `sessions`, `chat_messages` (+ FTS5 index), `memories`, `crew_members`,
`user_tools` / `user_tool_data`.

### 1.2 Deep Research
Autonomous, cancellable multi-step web research producing a cited Markdown (and
styled HTML) report.

- IterResearch-style **Think → Search → Extract → Synthesize** loop; the LLM
  decides what to search, what's relevant, what's missing, and when to stop.
- Date-grounded query generation (uses the real current date, not the training
  cutoff); boilerplate/low-quality page filtering; source-linked synthesis.
- Runs as a background task with a registry so it **survives page refresh**;
  falls back to a legacy orchestrator or basic web search if the engine fails.

Persistence: research blobs under `DEEP_RESEARCH_DIR` (not a DB table);
`ResearchSource` / `ResearchResult` dataclasses; a `tidy_research` action GCs
orphans. *(One of the three "generic" Telemachus apps — this is the closest
existing analogue.)*

### 1.3 Compare
Blind side-by-side A/B (and N-way) model testing.

- One prompt → two+ models; **blind by default** (identities and left/right→model
  mapping hidden until the user votes, then revealed).
- Records winner (`a`/`b`/`tie`) + per-side metrics; history and deletion. Each
  side runs through real owner-scoped chat sessions using the owner's endpoint/key.

Entities: `comparisons`.

### 1.4 Documents
Writing-first editor where both user and AI edit living documents, with full
version history.

- Markdown / HTML / CSV / code with syntax highlighting and a language field.
- **Version history** — every edit snapshots a `document_versions` row (summary +
  `source` = ai/user); any prior version is viewable and restorable.
- **Library** with search, soft-archive, and **AI Tidy** (LLM keep/junk verdict).
- **PDF** import (text), page-to-PNG render, and export; **PDF form filling**
  (AcroForm → editable Markdown → LLM maps values back on export; freeform +
  AI-fill annotations). **Office/EPUB** → Markdown via optional markitdown.
- **Signatures** — reusable saved handwritten stamps (encrypted at rest), used in
  PDF forms, email, and docs.
- **Email → document → signed reply** — a doc created from an email attachment
  remembers its source email so a reply can thread on the original conversation.

Entities: `documents`, `document_versions`, `signatures`, `editor_drafts`.

> **Gap (translation).** Telemachus names *document translation* as a generic
> app. Odysseus has **no dedicated translation feature** — no translate action or
> endpoint anywhere in the document/email/task paths. Translation is only
> implicit via general chat/agent edits. This is a build-new, not a port.

### 1.5 Email
Multi-account IMAP/SMTP inbox with AI triage, summaries, drafts, and calendar/
reminder integration.

- Multiple accounts per user (passwords Fernet-encrypted); experimental Google
  OAuth; Outlook/O365 basic-auth documented as unsupported.
- List/search/read, folders, move/archive/delete (+ permanent), flags; threaded
  reply parsing across 20+ locales and Outlook/original-message styles.
- **AI triage** — urgency tagging + notify, pre-generated summaries, pre-drafted
  reply suggestions; learned per-sender **writing style** and **signatures**.
- Compose with attachments, **scheduled send**, and an **approval queue** for
  agent-drafted mail.
- **Email → calendar** (auto-extract events from confirmations); **email →
  reminders** (stored as Notes); attachments open as editable Documents.

Entities: `email_accounts` (IMAP/SMTP creds encrypted) + a dedicated
`scheduled_emails.db` (9 tables — scheduled sends, summaries, tags, AI replies,
urgency alerts, calendar extractions, sender signatures, body boundaries, seen
ledger). Messages themselves live on the IMAP server.

### 1.6 Notes, Tasks + Calendar
**Notes** — Google-Keep-style notes/checklists/reminders: color/label, pin,
archive, reorder, images, repeat (daily/weekly/monthly/yearly), due-date
reminders, **AI classification**, a "solve this todo" agent button, and reminder
synthesis in a chosen **persona voice** (Socrates, Nietzsche, …). Entity: `notes`.

**Tasks (scheduled agents)** — recurring or one-off automation. Triggers: time
(once/daily/weekly/monthly or cron), **event** (e.g. session_created, every N
events), or **webhook**. Types: `llm` (agent prompt with tools, capped steps) or
`action` (builtin: tidy, daily_brief, email triage, cookbook_serve, ssh/script).
Chaining (`then_task_id`), pause/resume/run-now/revert, run history with token/
step logs, notifications, result emailing. Entities: `scheduled_tasks`,
`task_runs`.

**Calendar** — multiple calendars; events (all-day, recurring rrule, importance,
type, color); NL event parsing; ICS import/export; two-way **CalDAV** (pull sync
+ write-back to iCloud/Nextcloud/Radicale/Fastmail, with tombstones until remote
confirms deletes); AI event classification; `daily_brief` digest (calendar +
unread email + todos). Entities: `calendars`, `calendar_events`,
`caldav_deleted_events`.

### 1.7 Gallery / Image generation / Editor
- Photo **library** with albums, favorites, user + AI tags, EXIF (camera/GPS/
  taken_at/dimensions), SHA-256 dedupe, stats.
- **AI generation** via self-hosted diffusion server or OpenAI-compatible
  endpoint (privilege-gated); saved with prompt/model/size/quality.
- **AI edit tools** — inpaint, harmonize, upscale, style transfer, sharpen,
  denoise, background removal, face/portrait enhancement (GFPGAN + PIL fallback).
- Layered **image editor** with resumable server-side drafts; a standalone
  **faces** service (detection + embeddings).

Entities: `gallery_images`, `gallery_albums`, `editor_drafts`.

### 1.8 Search & Web
Meta-search (SearXNG + other providers) with SafeSearch, ranking, caching, and
analytics; `comprehensive_web_search` and `fetch_webpage_content` as agent tools
backing chat and Deep Research. `SearchResult` dataclass; on-disk caches; no DB
table.

### 1.9 Speech & video (STT / TTS / YouTube)
- **STT** — local faster-whisper, OpenAI-compatible `/audio/transcriptions`, or
  browser Web Speech (config-selectable).
- **TTS** — local Kokoro, OpenAI-compatible API, or browser; speed control;
  cached output.
- **YouTube** — transcript + comment extraction (yt-dlp) formatted into context.

### 1.10 Cookbook (local-model serving)
Covered as an AI-layer subsystem in §2.1/§2.7 — surfaced to users as
hardware-aware model recommendations, downloads, and one-click serving.

---

## 2. AI / model layer

### 2.1 Local model serving
Spawn and manage local/remote inference servers, then auto-register them as chat
endpoints.

- **tmux-backed** (PowerShell on Windows) serve so the process outlives the
  request and its log is inspectable; can target a **remote host over SSH**.
- **Command allow-list** — only `vllm`, `llama-server`/`llama.cpp`, `ollama`,
  `python` may lead a serve command (an admin-supplied cmd is shell-executed).
- Self-building **llama.cpp** (auto-detect ROCm/CUDA/CPU, correct cmake build).
- **Scheduled-serve lifecycle** — a scheduler-launched serve is stamped with a
  hard stop; a tick loop kills expired serves *and* deletes their auto-registered
  endpoint so it doesn't linger offline. State in `cookbook_state.json`.
- **Model discovery** — scans Tailscale peers (CGNAT range) + env hosts,
  fingerprints `/v1/models` vs Ollama `/api`, 60s cache.
- **Readiness vs liveness split** — `/api/ready` is a strict integrity self-check
  (DB reachable, data dir writable), distinct from a liveness ping.

Runtimes: llama.cpp/`llama-server`, `python -m llama_cpp.server`, vLLM, Ollama
(native + OpenAI-compat), diffusers for image gen.

### 2.2 LLM call core & provider abstraction
One resilient client (`llm_core.py`) for sync/async/streaming across ~10 provider
dialects behind an OpenAI-compatible surface.

- **Provider detection by hostname** (exact host/subdomain, not substring):
  ollama, anthropic, openrouter, groq, nvidia, moonshot/Kimi, opencode zen/go,
  ChatGPT-subscription, Copilot — else OpenAI-compatible.
- **Anthropic dialect translation** — OpenAI↔`/v1/messages`, Bearer→`x-api-key`,
  content-block conversion, ephemeral prompt-cache `cache_control`, temperature
  omission where rejected.
- **Dead-host cooldown / circuit breaker** — N connect failures ⇒ host marked
  dead for a cooldown so calls fail fast instead of hanging.
- **llama.cpp KV-cache slot affinity** — inject `session_id` + `cache_prompt` for
  self-hosted endpoints only (withheld from strict cloud providers).
- **Reasoning/thinking** — split `<think>` into a separate delta channel;
  reasoning-model temperature rules (o1/o3/o4/gpt-5, Kimi thinking).
- **Fallback chains** at the call layer (`llm_call_with_fallback`).

### 2.3 Endpoint resolution & context discovery
- `ModelEndpoint` = a DB row with `base_url`, `api_key`, and a `kind`
  (auto/local/api/proxy) that drives cache affinity and context trust.
- Credentials are **static** (Fernet-encrypted) or **session-backed OAuth**
  (`provider_auth_sessions`) resolved to a fresh bearer per call.
- Smart auto-pick of a chat model (skips embedding/tts/whisper/rerank/dall-e);
  context-window sizes discovered from `/models` and cached per endpoint identity
  (a proxy may cap below the true window).

### 2.4 External providers & auth
Supported: OpenAI (incl. o-series), Anthropic, OpenRouter, Groq, NVIDIA, Moonshot/
Kimi (incl. Kimi Code), opencode Zen/Go, **ChatGPT subscription** (OpenAI device-
auth OAuth, server-side refresh), **GitHub Copilot** (GitHub device flow), Ollama,
and any OpenAI-compatible custom endpoint (LM Studio, vLLM, TGI, llama.cpp).
`APIKeyManager` keeps a Fernet-encrypted `api_keys.json` (`.key` forced 0600).

### 2.5 Embeddings & lanes
- **Two-tier**: HTTP `EMBEDDING_URL` (Ollama/vLLM/llama.cpp) → local **fastembed**
  ONNX MiniLM (~50MB) fallback; drop-in `.encode()`.
- **Embedding lanes** — because a Chroma collection fixes its dimension on first
  insert, vectors from different models are kept in separate lanes/collections
  (model/url/dimension fingerprint), fanned and de-duped at query time. *(Lesson:
  never mix embedding models in one collection.)*

### 2.6 Vector stores — RAG & memory
- Singleton Chroma HTTP client with a fast TCP pre-probe (fail-fast, optional dep).
- **RAG** — Chroma + API embeddings, **hybrid search** (0.7 vector + 0.3 keyword),
  sentence-aware chunking (1000/200), **owner-scoped doc ids** (multi-tenant).
- **Memory vector store** — same lane infra over an `odysseus_memories` collection.

### 2.7 Hardware-aware Cookbook (`services/hwfit/`)
"Will it run, how well, with what flags." A ~1000-entry `hf_models.json` registry;
**quant physics tables** (bytes/param incl. GGUF tiers, AWQ/GPTQ/MLX, FP4/FP8,
mixed-MoE); a **bandwidth-based speed model** (per-GPU + Apple unified-memory
tables); `rank_models` / `analyze_model`; and `compute_serve_profiles` that emits
Quality/Balanced/Speed llama.cpp launch flags (`n_gpu_layers`, `n_cpu_moe`, KV
cache type, ctx) using the *same* VRAM math as the fit scorer so advice and
serving never diverge. Hardware detection is local or over SSH (24h cache). A
curated diffusers image-model registry mirrors this.

### 2.8 Context management
- **Adaptive input budget** — default is an "auto" sentinel meaning "scale to the
  discovered window ×0.85, capped at 200K"; explicit values honored.
- **Auto-compaction** — at 85% of window, summarize older turns via the same LLM
  (structured self-summary); aggressive trim for ≤8k models.

### 2.9 Model roles & presets
- **Role-based routing** — named `(endpoint, model)` pairs each with an ordered
  fallback chain: `default`, `utility` (summarize/name), `vision`, `image`,
  `task`, `research`, `teacher`, plus `tts`/`stt`/`search` providers. Selected
  keys are **per-user overridable** on one shared deployment.
- **Chat presets** — named sampling profiles (temperature + max_tokens + system
  prompt), distinct from Cookbook serve-presets (launch commands).

---

## 3. Cross-cutting AI design patterns worth carrying

- **OpenAI-compatible as lingua franca**, with per-provider dialect adapters only
  where needed.
- **Endpoint = DB row with a `kind`** driving caching, context trust, perf hints.
- **Role-based model routing with ordered fallbacks** at both config and call
  layers.
- **Deterministic hardware-fit math shared between "recommend" and "serve."**
- **Fail-fast resilience** — TCP pre-probes, dead-host circuit breaker, bounded
  health probes, separate connect/read timeouts.
- **Tailscale/SSH as first-class transport** for a private model fleet.
- **Graceful degradation** — Chroma/SearXNG/embeddings are optional; the app runs
  (reduced) without them.

---

## 4. Agent & tool system (the SDK-relevant core)

This is the part the porting plan calls "the part that gets *better* in Racket,"
and the nucleus of any Telemachus SDK.

### 4.1 Agent loop & runs
- **Reason→act loop** (`agent_loop.py`, capped at 50 rounds): each round the model
  emits tool calls, they run, results stream back, it iterates.
- **Per-turn `ToolPolicy`** — every call checked (`blocks`/`reason_for`) before
  dispatch; supports disabled tools, `disable_mcp`, and a `guide_only` (no-tools)
  mode.
- **RAG tool selection (`ToolIndex`)** — embed tool descriptions, inject only
  top-K relevant per message plus a small always-available floor (keeps large
  catalogs affordable for small-context models).
- **Skill-aware unlocking** — a matched skill's `requires_toolsets` unlocks those
  tools for the turn.
- **Intent routing** (`action_intents.py`) — cheap regex classifier promotes plain
  chat to agent mode only for *action* requests (guards against "how does X
  work").
- **Detached runs** — replay-buffer + subscriber fan-out so streams survive client
  disconnect (in-memory; grace-period eviction).

### 4.2 The tool contract (extension seam)
- **`TOOL_HANDLERS`** — central registry, `name → async execute(content, ctx)`;
  each native tool a small class (`BashTool`, `ReadFileTool`, …).
- **`FUNCTION_TOOL_SCHEMAS`** — OpenAI-style JSON function schemas (declaration
  side) + `function_call_to_tool_block` converter.
- **`TOOL_TAGS`** — allow-list; an unknown name is rejected before dispatch.
- **Multi-format parsing** — native function calls, XML `<invoke>`/`<tool_call>`,
  custom fenced blocks.
- **Two-tier dispatch** (`execute_tool_block`) — **MCP-first**
  (`mcp__{server}__{tool}`) with fallback to the native registry. *This dual
  native/MCP path is the key third-party seam.*

**Full native/`do_*` tool surface (~58 names):** exec (`bash`, `python`); web
(`web_search`, `web_fetch`); filesystem (`read_file`, `write_file`, `edit_file`,
`ls`, `glob`, `grep`, `get_workspace`); documents (`create/update/edit/suggest_
document`, `manage_documents`); model interaction (`chat_with_model`,
`ask_teacher`, `list_models`); sessions/pipeline (`create/list/send_to/manage_
session`, `pipeline`, `search_chats`); productivity (`manage_notes/calendar/
tasks`, `resolve/manage_contact`); memory/skills/research (`manage_memory/skills/
research/rag`, `trigger_research`); images (`generate/edit_image`); control-plane
(`ui_control`, `manage_settings/endpoints/mcp/webhooks/tokens`); escape hatches
(`api_call`, `app_api`); vault (`vault_get/search/unlock`); Cookbook (~13
`do_*_model`/serve/download tools); email (~9 tools via the email MCP server);
interaction (`ask_user`, `update_plan`).

### 4.3 MCP (Model Context Protocol)
- **Client manager** — stdio / SSE / Streamable HTTP transports; qualified naming
  `mcp__{server}__{tool}`; schema surfacing with disabled-map + plan-mode gating;
  auto-reconnect for builtin servers.
- **Built-in MCP servers** (`mcp_servers/`) — image_gen, memory, rag, email (all
  IMAP logic), plus an NPX Playwright browser. Trivial bash/python/fs/web were
  folded into in-process native execution (*keep as MCP only what carries unique
  logic*). Disable via `ODYSSEUS_DISABLE_MCP`.
- **MCP OAuth** — RFC 9728 discovery, Dynamic Client Registration, auth-code +
  PKCE, refresh; tokens persist encrypted per server; loopback (RFC 8252) or
  paste-back.

### 4.4 Skills (portable capability format)
`SKILL.md`-backed, progressively disclosed procedures the agent can author,
publish, and retrieve.

- **On-disk** `data/skills/<category>/<name>/SKILL.md` — YAML frontmatter (name,
  description, version, tags, platforms, `requires_toolsets`, status
  draft/published, confidence, source learned/taught/imported) + structured body
  (When to Use / Procedure / Pitfalls / Verification).
- **Progressive disclosure** — L0 list, L1 full view, L2 sub-file ref (keeps token
  cost low).
- **Lifecycle** — add(draft) / patch / edit / publish / delete / search; near-dup
  dedup; usage counters in a sidecar so content doesn't churn; owner in
  frontmatter; toolset + platform gating.

### 4.5 Memory providers (clean plugin ABC)
`MemoryProvider` ABC: id/name/enabled, async init/shutdown, `remember/recall/
list/delete`, **and `get_tool_schemas()` + `handle_tool_call()`** so a provider
contributes *both behavior and its own tools*. A registry aggregates schemas
across active providers; the native local store is always the baseline. *(A
reusable template for domain extensions generally.)*

### 4.6 Integrations & third-party agent plugins
- **Integration presets** (`INTEGRATION_PRESETS`) — Miniflux/Gitea/ntfy/… declare
  `auth_type`, `auth_header`, and an embedded endpoint cheat-sheet that doubles as
  the tool's prompt context; the `api_call` tool reaches them; creds encrypted.
- **Scoped external-agent plugins** (`integrations/claude/`, `integrations/codex/`)
  — a **scope-gated HTTP API** (canonical `/api/codex/*`); every surface checked
  server-side, `403` until the user toggles it on; scoped `ody_...` tokens; agents
  must call `/api/*/capabilities` first. Delivered as skill bundles (Claude Code
  `plugin.zip` → `~/.claude/skills/odysseus/`; Codex `.codex-plugin/plugin.json`).
  *A clean template for "third party drives your tools over a user-consented,
  scope-enforced token."*

### 4.7 Shell / exec
`ShellService.execute` and native `bash`/`python` tools — streaming subprocess
with a progress emitter, long default timeouts, output caps. **No in-process
sandbox** — isolation comes from the Docker boundary + the scope-gated token
model, not a jail (see §6).

**SDK takeaways:** (1) two-tier MCP-then-native dispatch is the seam; (2)
declaration (schemas + allow-list + multi-format parsing) is separate from
execution; (3) the provider-ABC pattern lets an extension add behavior *and*
tools; (4) per-turn policy + RAG selection keep large catalogs affordable; (5)
consent/scope enforcement lives server-side; (6) SKILL.md is a portable, gated
capability package.

---

## 5. Automation & background processing

- **Task scheduler** (`task_scheduler.py`) — executes `scheduled_tasks` on cron/
  interval/event triggers; owner-based tool gating; chaining; writes `task_runs`.
- **Event bus** — lightweight in-process pub/sub (session-created, message-sent…)
  that fires automation tasks.
- **Background jobs + monitor** — the agent's `bash` tool can detach long
  commands; status derives from an on-disk exit-code file (restart-safe); a 5s
  monitor **re-invokes the agent** when a job finishes ("auto-continue"), marking
  followed-up only on success.
- **Cleanup service** — retention/GC (archive 7d, delete 14d, keep ≥20 messages).
- **Webhooks** — outbound subscriptions (url/secret/events/last-status); SSRF
  regression-tested.
- **Rate limiter** — thread-safe sliding-window keyed by IP.

---

## 6. Security & multi-user model

*(The most important section for a "team-oriented" successor — the model here is
single-tenant hardening, not multi-tenant isolation.)*

### 6.1 Posture / threat model
- **Trust boundary defended:** unauthenticated access; non-admins reaching
  admin-only capabilities; the agent acting on **prompt-injected** untrusted
  content; internal services (Chroma/Ollama/SearXNG/ntfy) reachable from outside.
- **Intentionally *not* defended:** what a trusted admin/agent can do on the host
  (shell/Python/file/email all run as the app process user — **no sandbox, no
  egress filter**). Deployment guidance: keep auth on, behind HTTPS + a trusted
  reverse proxy / Tailscale / VPN, services internal-only.

### 6.2 Authentication
- **Password** — bcrypt, usernames lowercased, `data/auth.json` atomic writes.
- **Sessions** — opaque 32-byte tokens, 7-day TTL, httponly/samesite=lax cookie,
  `secure` gated by env; re-validated each request (deleted user kicked next hit).
- **2FA / TOTP** — pyotp enrollment (`otpauth://`), 8 single-use backup codes,
  verified after password before session issuance.
- **First-run bootstrap** — first user is admin (lock-guarded); legacy single-user
  auth auto-migrated.
- **API bearer tokens** — `ody_` + 43 chars, bcrypt-hashed with an 8-char display
  prefix, `owner` + `scopes` + `is_active`; callers present as pseudo-user `api`
  but actions attribute to the real owner (`effective_user()`).
- **Token scopes** — a fixed catalog (`chat`, `todos:*`, `documents:*`, `email:*`,
  `calendar:*`, `memory:*`, `cookbook:*`), writes imply reads, plus curated
  profiles. *(Finer than `THREAT_MODEL.md` still claims — treat code as
  authoritative.)*
- **Bypass modes** — `AUTH_ENABLED=false` (anonymous), `LOCALHOST_BYPASS=true`
  (loopback), pre-setup loopback. Rate limits on login/signup.

### 6.3 Multi-user / ownership / sharing — **what exists vs. what a team product needs**
- **Roles: exactly two** — `is_admin` boolean. **No named roles, no groups, no
  teams, no orgs, no tenants.** ("workspace" here = a filesystem folder for file
  tools, *not* a shared team space.)
- **Per-user privileges** — a flat capability dict for non-admins
  (`can_use_agent/browser/documents/research/generate_images/manage_memory`,
  `can_use_bash=false`, `max_messages_per_day`, `allowed_models`). Admins get the
  full set, recomputed live every request.
- **Capability gate (the real boundary)** — `NON_ADMIN_BLOCKED_TOOLS`: non-admins
  blocked from shell/python, file ops, email, calendar, any MCP tool, memory/
  skills/tasks/endpoints/webhooks/tokens/documents/settings management, vault, and
  model serving. Enforced **server-side at dispatch**, not just UI.
- **Data ownership** — a nullable `owner` (username) column on ~20 tables;
  isolation via `owner_filter(query, model, user)`.
- **Sharing is primitive** — `owner == user OR owner IS NULL`; a **NULL owner is
  world-visible** (a legacy/migration bucket, not a deliberate ACL). **No
  row-level grants, no share-with-user, no per-resource ACL, no group ownership.**
  In anonymous mode ownership filtering is a no-op.
- **Reserved usernames** — `internal-tool`, `api`, `demo`, `system`.
  `internal-tool` is security-critical: `require_admin` grants unconditional admin
  to that pseudo-user (the in-process tool loopback), guarded by a per-boot random
  `INTERNAL_TOOL_TOKEN` and an `owner_is_admin_or_single_user` check before any
  loopback call.

> **Gap (teams).** For a team platform, teams/roles/sharing would be **built
> essentially from scratch.** The existing foundation is reasonable — every
> ownable table already stamps an owner, and there's a server-side capability
> gate — but there is no group entity, no shared-resource ACL beyond
> NULL-owner=public, and admin is all-or-nothing with intentionally unsandboxed
> host access.

### 6.4 Secret management
Local at-rest encryption, no external vault/KMS (no SOPS in this repo despite some
docs' phrasing):
- **`secret_storage.py`** — Fernet for DB-stored secrets (IMAP/SMTP passwords),
  key at `data/.app_key` (0600, gitignored), `enc:` prefix for idempotent
  migration. Protects against DB-file exfiltration, *not* process compromise.
- **`api_key_manager.py`** — separate Fernet store for provider keys (`data/.key`).
- **Vault routes** — optional Vaultwarden/Bitwarden CLI (`bw`) integration,
  admin-only.
- **Leak prevention** — `settings_scrub.py` deep-scrubs secret-shaped keys from
  the auth-exempt `/api/auth/settings`.

### 6.5 Content / prompt-injection defenses
- **`prompt_security.py`** — all untrusted content passes through
  `untrusted_context_message`: placed in a **user** role (never system), prefixed
  with a warning header, fenced in guard markers with any literal markers in the
  content escaped, tagged `trusted=False`. A system preamble restates "external
  content is data, not instructions." Required for web results, fetched URLs,
  emails, memories, skills, notes.
- **Plan mode** — a read-only tool **allowlist** (new tools default blocked;
  bash/python excluded entirely).
- **SSRF/URL safety** — private-IP blocking for exposed deployments; webhook SSRF
  regression tests. (A historical `/api/v1/chat base_url` SSRF is a noted gap.)
- **HTTP headers** — `X-Frame-Options: DENY` + `frame-ancestors 'none'`, nosniff,
  no-referrer, **nonce-based CSP**. CORS via `ALLOWED_ORIGINS` (localhost default).

---

## 7. Backend architecture & data model

### 7.1 Architecture
FastAPI monolith; a **manager-graph DI root** (`app_initializer.initialize_
managers()`) builds singletons at startup and injects them into ~50 routers.
`constants.py` is the single source of truth for all `DATA_DIR`-relative paths and
tunables. `core/` holds cross-cutting infra (database, auth, middleware, session
manager, atomic IO, platform-compat).

### 7.2 Route groups
Core AI (`chat`, `research`, `compare`, `model`, `embedding`, `assistant`,
`codex`/`copilot`/`chatgpt_subscription`, `mcp`); sessions/history/search/
admin-wipe; content (`document`, `note`, `calendar`, `contacts`, `email`,
`gallery`, `signature`, `editor_draft`, `emoji`, `font`, `cookbook`, `skills`);
memory/personal/vault; automation (`task`, `webhook`, `api_token`, `device_flow`,
`shell`, `workspace`, `upload`, `backup`, `cleanup`, `diagnostics`, `hwfit`);
auth/settings/prefs/preset; `tts`/`stt`; companion.

### 7.3 Data model (SQLite; all ORM in `core/database.py`)
**`app.db` — primary** (~30 tables): `sessions`, `chat_messages` (+ FTS5 index &
shadow tables), `documents`, `document_versions`, `notes`, `memories`,
`calendars`, `calendar_events`, `caldav_deleted_events`, `email_accounts`,
`integrations`, `model_endpoints`, `provider_auth_sessions`, `mcp_servers`,
`comparisons`, `signatures`, `api_tokens`, `webhooks`, `user_tools`,
`user_tool_data`, `crew_members`, `scheduled_tasks`, `task_runs`,
`gallery_albums`, `gallery_images`, `editor_drafts`.

**`scheduled_emails.db` — email automation** (9 tables): `scheduled_emails`,
`email_summaries`, `email_tags`, `email_ai_replies`, `email_urgency_alerts`,
`email_calendar_extractions`, `sender_signatures`, `email_boundaries`,
`email_event_seen`.

**`email_cache.db`** — IMAP message cache (referenced in constants).

**JSON/dir persistence** under `DATA_DIR`: `settings.json`, `features.json`,
`auth.json`, `sessions.json`, `presets.json`, `memory.json`, `contacts.json`,
`vault.json`, `skills.json`, `bg_jobs.json`, `cookbook_state.json`; dirs for
`rag/`, `chroma/`, `uploads/`, `generated_images/`, `tts_cache/`,
`memory_vectors/`, `fastembed_cache/`, `skills/`.

Conventions: `TimestampMixin`, an `EncryptedText` type-decorator, WAL pragmas,
FTS5 for chat search, and ~50 in-code additive `_migrate_*` functions run at
startup (no external migration tool).

### 7.4 Deployment surface
Docker (generic CPU, plus `pi`, `gpu-amd`/ROCm, `gpu-nvidia`/CUDA composes;
services: odysseus + chromadb + searxng + ntfy); **Nix/NixOS** flake (4 systems +
`nixosModules.odysseus`); macOS (PyInstaller `.app`, `apple-ml-containers.md`
notes GPU/ANE is unavailable in mac containers → keep ML native behind HTTP);
Windows portable (frozen PyInstaller, tray launcher, data in `~/.odysseus/data`);
Linux systemd unit.

---

## 8. The Racket port — what already moved

A **strangler-fig** rewrite under `racket/`, structured as a monorepo of
independently installable packages. The porting analysis (`porting.md`) chose
Racket (CS) as primary for native four-OS coverage (Win/mac/Linux first-class,
FreeBSD gated) plus batteries-included GUI (`racket/gui`) and standalone binaries
(`raco exe`). `PORTING_PLAN.md` details the phases.

**Reusable library seed (`racket/pkgs/`, app-agnostic, publishable):**
- **`cli-kit`** — JSON-emitting CLI scaffolding (`emit`, `fail`, `run` harness,
  own pretty-printer).
- **`db-kit`** — SQLAlchemy-style `sqlite:///` URL → Racket `db` connection +
  value coercers + `datetime→iso` (Python-parity), platform-aware paths.
- **`web-kit`** — thin JSON-API wrapper over `web-server` (intentionally minimal).

**Domain (`racket/domain/`, shared by CLI *and* HTTP so they can't drift):**
- **Tool SDK** — `dsl.rkt`'s **`define-tool` macro** emits byte-faithful OpenAI
  function-tool JSON (~12 declarative lines/tool vs Python's 1372-line nested-dict
  file); `#:optional`/`#:enum`/`#:items`/`#:items-of`; auto-registration
  (`all-tool-schemas`, `tool-ref`, `reset-tools!`). Converter (`convert.rkt`,
  aliases + tool-tags + MCP passthrough) and result renderer (`result.rkt`) round
  out the contract.
- **Agent runtime** — `loop.rkt` is a **pure `run-agent` spine** with injected
  `#:llm` and `#:exec` effects (deterministic/testable without a model); `llm.rkt`
  an OpenAI-compatible adapter (blocking + SSE, temp 0 for deterministic tool
  selection); `exec.rkt` real built-ins (`bash`/`python`/file tools/`web_fetch`)
  with the deny-list confinement (`.ssh`/`id_rsa`/`.env`, prune `.git`/
  `node_modules`) and output caps; `prompt.rkt` and `prompt-security.rkt`.
- **Ported tool implementations** — notes, sessions, tasks, calendar (+ an NL
  datetime engine), integrations (endpoints/mcp/webhooks/tokens), documents,
  settings, skills (+ SKILL.md).

**CLI (`racket/cli/`)** — ~10 `odysseus-*` commands incl. `odysseus-agent`
(drives the loop against any OpenAI-compatible endpoint, e.g. local Ollama).

**Server (`racket/server/`)** — `main.rkt` (`/health`, byte-identical
`GET /api/notes` honoring an `X-Odysseus-User` trusted header); `proxy.rkt` the
strangler proxy (config-flippable path prefixes → Racket :8099, else Python :7000);
a concurrency demo (native evented scheduler, no libuv/FFI).

**Tests** — portable rackunit suite + a scripted mock-LLM for end-to-end runs.

**Ported tools (20 of ~58):** `bash`, `python`, `web_search`, `web_fetch`,
`read_file`, `grep`, `glob`, `ls`, `write_file`, `edit_file`, `manage_tasks`,
`manage_calendar`, `manage_notes`, `manage_endpoints`, `manage_mcp`,
`manage_webhooks`, `manage_tokens`, `manage_skills`, `manage_documents`,
`manage_settings`. **Not yet ported:** `manage_session`/`manage_memory` (live
session state / Chroma), contacts (CardDAV), the email built-ins, plus the rest of
`tool_implementations.py`.

**Three permanent porting rules:** (1) the **ML/native moat stays Python forever
behind HTTP** (fastembed ×162, torch ×78, diffusers ×60, PyMuPDF ×58, chromadb,
faster-whisper — plus email/CalDAV initially); (2) each migrated unit is proven by
a **byte-identical fidelity diff** vs the Python original before Python is
retired; (3) the vanilla-JS frontend is untouched. Phase 4's payoff is a native
desktop client on `racket/gui` sharing the Phase-2 core.

---

## 9. Documentation set (owner-authored → migration candidates)

**Root:** `README.md`, `ROADMAP.md` ("Help Wanted"), `CONTRIBUTING.md`,
`SECURITY.md`, `THREAT_MODEL.md` (trust boundaries; slightly behind code on token
scopes), `porting.md` (language selection: Racket ≳ SBCL ≫ Guile), `PORTING_PLAN.md`
(phased execution), `NIX_DEPLOYMENT.md`, `apple-ml-containers.md`,
`ACKNOWLEDGMENTS.md`.
**`racket/`:** `README.md`, `PERFORMANCE.md`, `VALIDATION.md`.
**`docs/`:** `setup.md`, `local-mac.md`, `small-host.md` (ARM SBC / Pi profile),
`agent-migration.md`, `backup-restore.md`, `email-outlook.md`, `security-ci.md`,
`pr-blocker-audit.md` (+ `.webm` demos).
**`specs/`:** `architecture-runtime-inventory.md`.

> **Provenance caution.** Several docs reference the upstream GitHub repo and
> third-party/borrowed code (`ACKNOWLEDGMENTS.md`, docker-bundled deps). For an
> MIT/X successor carrying only owner-written material, authorship must be vetted
> per file before migration — that is the job of `TelemachusMigration.md`.

---

## 10. Summary — reading this against the Telemachus brief

Telemachus is stated as a **team-oriented platform for hosting AI tools and
applications**, generic set = **chat, research, document translation**, plus an
**SDK** for plugins (tools, integrations, datasets, localizations), Racket-first
with **swappable frontend/backends**, keyed on the **SDK contract, backend APIs,
security model, and protocols**. Against that:

- **Directly reusable concepts (strong):** the agent loop spine + `define-tool`
  DSL + two-tier MCP/native dispatch (the SDK nucleus); role-based model routing
  with fallbacks; the OpenAI-compatible provider abstraction; SKILL.md as a
  portable capability package; the MemoryProvider ABC as a general extension
  template; scoped-token consent for third-party agents; the hardware-fit
  Cookbook; embedding lanes; the `pkgs/` (cli-kit/db-kit/web-kit) as an app-
  agnostic library seed; the owner-column data model as an ownership foundation.
- **Generic apps status:** **chat** ✅ and **research** ✅ exist and are mature;
  **document translation** ❌ does not exist as a feature (build-new).
- **Biggest deltas to design fresh for a *team* product:** teams/groups/roles and
  per-resource sharing/ACLs (today: binary admin + owner-or-NULL); a real
  **security/isolation model** for untrusted plugins and multi-tenant data (today:
  single-tenant hardening, unsandboxed host access by design); a **stable SDK
  contract & backend API/protocol spec** as first-class artifacts (today: implicit
  in code); **datasets and localizations** as SDK extension types (today: only
  tools/integrations/skills exist).
- **Stays out of pure-Racket scope regardless:** the Python ML/document/STT/TTS
  moat, walled behind small JSON-contract HTTP services.

*End of inventory. This document describes Odysseus as it exists; requirements and
migration decisions are deliberately left to `FeatureRequirements.md` and
`TelemachusMigration.md`.*
