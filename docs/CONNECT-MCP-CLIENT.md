# Connect an MCP client to the New Relic MCP gateway

This gateway exposes New Relic's MCP as a native APIM `type=mcp` server. Any
MCP-capable client that speaks streamable HTTP can connect — you never hold a New
Relic key; APIM injects it server-side.

## What you need

| | |
|---|---|
| **Endpoint URL** | `https://api.<env>.amnhealthcare.io/ai/new-relic-mcp/<env>` |
| **dev** | `https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev` |
| **int** | `https://api.int.amnhealthcare.io/ai/new-relic-mcp/int` |
| **Auth** | Entra **bearer token** for audience `api://<newrelic-mcp-app-id>` |
| **Authorization** | membership in the **`AZ_JobRole_Observability_NewRelicMcp_User`** AD group |

> Always use the **AFD apex host** (`api.<env>.amnhealthcare.io`). APIM runs in
> internal mode (private IPs only) — the `*.azure-api.net` host is not routable.
> The service rides the shared **AI-API-RR** edge route (`/ai/*`).

**Access model:** being in the group is what grants access. The gateway is read-
oriented; write actions are gated in the marketplace/skill layer, not by a second
credential (New Relic has no read-only key — one User key covers both, injected by
APIM). Ask an admin to add you to the group if you get a `401`.

## Getting a token

Interactively (developer laptop, Azure CLI logged in):

```bash
az account get-access-token --resource "api://<newrelic-mcp-app-id>" --query accessToken -o tsv
```

The token is short-lived. Claude Code's `headersHelper` mints one on connection
or reconnect; after a `401` or `403`, Claude Code re-runs the helper, reconnects,
and retries the request once. Clients that bake the token at launch must restart
to re-mint it after expiry. The audience is the **dedicated NR MCP app**
(`api://<newrelic-mcp-app-id>`), not the model-gateway audience — mint a token
for this app specifically.

## Client configuration

### Claude Code (`~/.claude.json`)

**Preferred:** run the client-side installer, which merges the server into the
supported user-scope file `~/.claude.json` using the `headersHelper` pattern
(`az` mints tokens on connection/reconnect and after a `401` or `403`; no static
value on disk, no env vars). Existing top-level settings and unrelated MCP
servers are preserved:

```bash
# macOS/Linux
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install.sh | bash

# Windows PowerShell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install.ps1 | iex
```

See [`../client/README.md`](../client/README.md) for `-Check` mode, env
selection (`--env=dev|int`), uninstall instructions, and troubleshooting.

**Manual form:**

```jsonc
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev",
      "headersHelper": "az account get-access-token --resource \"api://709bbe94-f759-422f-b7fa-28f1fde28ae1\" --query \"{Authorization: join(' ', ['Bearer', accessToken])}\" -o json"
    }
  }
}
```

### GitHub Copilot CLI and App (`~/.copilot/mcp-config.json`)

Copilot has no `headersHelper` field, so do not put an expiring Entra bearer in
its static `headers` object. Use the Copilot installer, which installs a local
stdio bridge that obtains and refreshes the bearer through Azure CLI:

```bash
# macOS/Linux
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install-copilot.sh | bash

# Windows PowerShell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install-copilot.ps1 | iex
```

The resulting `mcpServers.newrelic` entry uses `node` to launch the installed
bridge. GitHub Copilot App and VS Code Agent Host consume the same Copilot CLI
user MCP configuration. See [`../client/README.md`](../client/README.md) for
IDE coverage and check-only/environment options.

### VS Code (`.vscode/mcp.json`)

```jsonc
{
  "servers": {
    "newrelic": {
      "type": "stdio",
      "command": "/absolute/path/to/node",
      "args": [
        "/absolute/path/to/.copilot/servers/newrelic-apim/bridge.mjs",
        "--url", "https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev",
        "--audience", "api://709bbe94-f759-422f-b7fa-28f1fde28ae1",
        "--az-path", "/absolute/path/to/az"
      ]
    }
  }
}
```

VS Code Agent Host reads `~/.copilot/mcp-config.json` directly, so no separate
file is needed there. Use this explicit stdio form only for the traditional VS
Code extension host. Static bearer headers expire and are not supported by the
installer.

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
curl -sS -X POST "https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```

A JSON-RPC result with `serverInfo` = you're in. `401` = bad/expired token **or** not authorized (not in the access group). (`test-harness/Invoke-ApimSmokeTest.ps1` does this end to end.)
