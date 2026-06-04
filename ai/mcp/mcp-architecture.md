# MCP (Model Context Protocol) Architecture

How AI tools integrate with this repository through the Model Context Protocol. MCP exposes structured tools and contexts to the AI without requiring the AI to scan files itself.

## Goals

- Let Cursor / Claude / other MCP-aware clients call **deterministic tools** for: schema lookup, SP catalog, contract retrieval, dashboard query, runbook fetch.
- Keep the AI's working set small by serving **just-in-time** context.
- Provide an **audit trail** of what the AI accessed.

## Server inventory (planned)

| Server | Purpose | Backed by |
|---|---|---|
| `itorchestra-mssql` | Resolve table schemas, list SPs, fetch SP definitions, run **read-only** explain plans | A read-only MSSQL login per environment |
| `itorchestra-contracts` | Fetch OpenAPI specs, Protobuf descriptors, event envelopes | Local repo + NuGet contracts |
| `itorchestra-runbooks` | Retrieve service runbooks and on-call docs | Markdown in repo + Confluence (optional) |
| `itorchestra-observability` | Read recent metrics / spans / logs by service + time range | Tempo / Prometheus / OpenSearch (read-only API tokens) |
| `itorchestra-keycloak` | List roles, clients, audiences | Keycloak Admin API (read scope) |
| `itorchestra-vault` | List secret **paths** (not values), surface policies | Vault read-policy token |

> **No MCP server has write access to production resources.** All write actions are explicit human-driven PRs or Argo CD syncs.

## Configuration (Cursor)

`.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "itorchestra-mssql": {
      "command": "node",
      "args": ["./tools/mcp/itorchestra-mssql/dist/index.js"],
      "env": {
        "MSSQL_CONNECTION_STRING_FILE": "/run/mcp/mssql.txt"
      }
    },
    "itorchestra-contracts": {
      "command": "node",
      "args": ["./tools/mcp/itorchestra-contracts/dist/index.js"]
    },
    "itorchestra-observability": {
      "command": "node",
      "args": ["./tools/mcp/itorchestra-observability/dist/index.js"],
      "env": {
        "TEMPO_URL": "https://obs.itorchestra.com/tempo",
        "PROM_URL":  "https://obs.itorchestra.com/prometheus",
        "OPENSEARCH_URL": "https://obs.itorchestra.com/opensearch"
      }
    }
  }
}
```

## Tool definitions (read-only)

### `mssql.listProcedures`

| Param | Type | Description |
|---|---|---|
| `database` | string | Service DB name (`Orders`) |
| `schema` | string? | Optional schema filter (`dbo`, `outbox`) |

Returns: `[{ schema, name, parameters: [{name, type, mode, hasDefault}] }]`.

### `mssql.getProcedureBody`

| Param | Type | Description |
|---|---|---|
| `database` | string | |
| `schema` | string | |
| `name` | string | |

Returns the latest source of the SP (read-only).

### `mssql.explainQuery` (read-only)

| Param | Type | Description |
|---|---|---|
| `database` | string | |
| `sql` | string | Read-only `SELECT` against allowed objects |

Returns the estimated execution plan. **Refuses** anything other than `SELECT`.

### `contracts.openApi`

| Param | Type | Description |
|---|---|---|
| `service` | string | Service name |
| `version` | string? | `v1`, `v2` |

Returns the OpenAPI document text.

### `contracts.proto`

| Param | Type | Description |
|---|---|---|
| `service` | string | |
| `version` | string | `v1` |

Returns the `.proto` source.

### `observability.spans`

| Param | Type | Description |
|---|---|---|
| `service` | string | |
| `traceId` | string? | Specific trace |
| `start`, `end` | ISO timestamps | |

Returns span data from Tempo.

### `observability.logs`

| Param | Type | Description |
|---|---|---|
| `service` | string | |
| `query` | string | OpenSearch DSL or Lucene |
| `start`, `end` | timestamps | |

Returns up to N redacted log entries.

## Security

- Each MCP server runs as a **separate sandboxed process** with its own credentials.
- Credentials sourced from Vault via short-lived tokens; never embedded in `.cursor/mcp.json`.
- All MCP servers run in **read-only mode** for production resources.
- Each tool call logs to OpenSearch with `actor`, `tool`, `arguments`, `timestamp`.
- The AI's session id is propagated as `X-Correlation-Id` to the underlying systems.

## Tool-usage policy for the AI

1. Prefer **MCP tools** over filesystem scanning for SP bodies, contracts, observability queries.
2. Always cite which tool returned the data when proposing code changes.
3. Never invoke a write tool unless explicitly approved in the same chat session.
4. Honor the production read-only constraint — never propose `INSERT/UPDATE/DELETE/EXEC` of a write SP via an MCP tool.

## Building a new MCP server

- Use the official MCP SDK in TypeScript or Python.
- Project lives under `tools/mcp/<server-name>/`.
- Has its own `Dockerfile` and image; same scanning + signing rules as the platform.
- Credentials are file-mounted from Vault, never hardcoded.

## Related

- [`../rag/context-retrieval-strategy.md`](../rag/context-retrieval-strategy.md)
- [`../core/system-prompt.md`](../core/system-prompt.md)
