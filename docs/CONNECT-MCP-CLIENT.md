# Connect an MCP client to the New Relic MCP gateway

This gateway exposes New Relic's MCP as a native APIM `type=mcp` server. Any
MCP-capable client that speaks streamable HTTP can connect — you never hold a New
Relic key; APIM injects it server-side.

## What you need

| | |
|---|---|
| **Endpoint URL** | `https://<gateway>/mcp/newrelic/<env>` |
| **dev** | `https://amn-wus2-hub-apim-d02.azure-api.net/mcp/newrelic/dev` |
| **int** | `https://amn-wus2-hub-apim-i02.azure-api.net/mcp/newrelic/int` |
| **Auth** | Entra **bearer token** for audience `api://<newrelic-mcp-app-id>` |
| **Authorization** | membership in the **`AZ_JobRole_Observability_NewRelicMcp_User`** AD group |

> If your org uses an Azure Front Door custom domain (e.g. `api.dev.amnhealthcare.io`)
> in front of APIM, use that host instead of the `*.azure-api.net` gateway host —
> the `/mcp/newrelic/<env>` path is the same.

**Access model:** being in the group is what grants access. The gateway is read-
oriented; write actions are gated in the marketplace/skill layer, not by a second
credential (New Relic has no read-only key — one User key covers both, injected by
APIM). Ask an admin to add you to the group if you get a `401`/`403`.

## Getting a token

Interactively (developer laptop, Azure CLI logged in):

```bash
az account get-access-token --resource "api://<newrelic-mcp-app-id>" --query accessToken -o tsv
```

The token is short-lived and **baked at client launch** — a mid-session `401`
means it aged out, so restart the client to re-mint it (same pattern as the Claude
Code model gateway). If your Claude Code model-gateway token already carries the
right audience, it will validate here too.

## Client configuration

### Claude Code (`.mcp.json`)

The `amn-ops-observability` marketplace plugin ships this (URL + token come from
`NEWRELIC_MCP_URL` / `NEWRELIC_MCP_TOKEN` set by the bootstrap). Standalone form:

```jsonc
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://amn-wus2-hub-apim-d02.azure-api.net/mcp/newrelic/dev",
      "headers": { "Authorization": "Bearer ${NEWRELIC_MCP_TOKEN}" }
    }
  }
}
```

### VS Code (`.vscode/mcp.json`)

```jsonc
{
  "servers": {
    "newrelic": {
      "type": "http",
      "url": "https://amn-wus2-hub-apim-d02.azure-api.net/mcp/newrelic/dev",
      "headers": { "Authorization": "Bearer ${input:newrelic_token}" }
    }
  }
}
```

### Copilot Studio / Power Automate

Add an MCP server / custom connector pointing at the endpoint URL with OAuth (Entra)
using audience `api://<newrelic-mcp-app-id>`. The consuming identity must be in the
access group.

### Any other MCP client

Point it at the endpoint URL as a **streamable-HTTP MCP server** and send
`Authorization: Bearer <entra-token>`.

## Verify your connection

```bash
TOKEN=$(az account get-access-token --resource "api://<newrelic-mcp-app-id>" --query accessToken -o tsv)
curl -sS -X POST "https://amn-wus2-hub-apim-d02.azure-api.net/mcp/newrelic/dev" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

A JSON-RPC result with `serverInfo` = you're in. `401` = bad/expired token; `403` =
not in the access group. (`test-harness/Invoke-ApimSmokeTest.ps1` does this end to end.)
