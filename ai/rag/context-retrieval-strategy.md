# Context Retrieval Strategy (RAG)

How the AI assistant decides which files / passages / external sources to load into its working context for a given task.

## Goals

- Keep the **always-loaded** context tiny (only `system-prompt.md` + `forbidden-patterns.md`).
- Load skill files **on demand** from the routing table in [`../core/system-prompt.md`](../core/system-prompt.md).
- Retrieve **just enough** evidence from code, SQL, docs, and observability — not the whole repo.

## Sources, in priority order

1. **AGENTS.md + `ai/` files** — the project's curated rules (highest signal, lowest noise).
2. **Repository code** — by glob/grep when a specific symbol or file is named.
3. **MCP tools** — for SP bodies, contracts, observability snippets. See [`../mcp/mcp-architecture.md`](../mcp/mcp-architecture.md).
4. **Qdrant vector store** (optional) — semantic search over `ai/`, `docs/`, ADRs, runbooks.
5. **External docs** — only when the user explicitly asks or the framework is too new for memory.

## Retrieval policy

### Step 1 — Triage the task

| Task category | Always load |
|---|---|
| Writing new code in an existing service | `system-prompt.md`, `forbidden-patterns.md`, the skill file(s) for the touched concerns |
| Adding a new microservice | The above + `patterns/microservice-template.md`, `workflows/new-microservice-workflow.md` |
| Reviewing a PR | `prompts/code-review-prompt.md` + relevant skills |
| Debugging production issue | `core/architecture.md` + observability skill + service runbook |

### Step 2 — Targeted retrieval

When a task references a specific file/SP/contract:

1. Read the file directly (filesystem) if path known.
2. Otherwise, search by symbol name (Grep / Glob).
3. For SP bodies and OpenAPI/Protobuf docs, prefer the MCP server over filesystem.

### Step 3 — Semantic fallback

When the user asks an open question ("how do we handle X?"):

1. Query Qdrant with the user's prompt to find the top-K (K = 5) most relevant documents.
2. Re-rank by recency + author trust.
3. Cite the documents used in the response.

## Qdrant index design (when enabled)

| Collection | Source | Granularity | Refresh |
|---|---|---|---|
| `ai-rules` | `ai/**/*.md` | Per heading section | On every commit to `main` |
| `code-docs` | `docs/**/*.md`, `**/README.md` | Per heading section | Daily |
| `runbooks` | `runbooks/**/*.md` | Per heading section | Daily |
| `adr` | `docs/adr/*.md` | Per file | On commit |
| `sql-procs` | `db/**/sp_*.sql` | Per SP body | On commit (via CI) |

Embedding model: a stable, well-tested open model from Ollama (e.g., `nomic-embed-text` v1.5).

## Reranking & filtering

- Re-rank top-K with a small cross-encoder if precision matters.
- Filter out:
  - Files older than 1 year unless explicitly referenced.
  - Drafts / TODO documents (flagged by front-matter `status: draft`).
  - Files in `tests/` unless the task is test-related.

## Citation rules

- Whenever the AI uses retrieved content, cite the file path and section heading.
- For MCP tool results, cite the tool name and arguments.
- For Qdrant results, cite the source document + section.

## What NOT to retrieve

- Entire `src/` tree — costly and noisy. Use Grep/Glob.
- Build outputs (`bin/`, `obj/`, `node_modules/`, `publish/`).
- Generated code (`*.g.cs`, `*.designer.cs`, `bin/**`, `obj/**`).
- Large binary files.

## Caching

- The agent caches the contents of `system-prompt.md` and `forbidden-patterns.md` per session.
- Skill files are cached on first load; invalidated by file `mtime` change.
- Qdrant results cached per (query, K) pair for the duration of the session.

## Quality signals

- Track tool/file citations per response → review weekly.
- Track tasks that referenced files outside `ai/` more than expected → those are candidates for new skill / pattern files.

## Failure modes

- **Stale embeddings**: refresh nightly; alert on > 24h staleness.
- **Hallucinated paths**: if the AI references a file path that does not exist, refuse and ask the user.
- **Context overflow**: prefer linking to a skill file rather than inlining its content.

## Related

- [`../core/system-prompt.md`](../core/system-prompt.md)
- [`../mcp/mcp-architecture.md`](../mcp/mcp-architecture.md)
- [`../context/glossary.md`](../context/glossary.md)
- [`../context/tech-stack.md`](../context/tech-stack.md)
