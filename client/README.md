# Client-side installer

Adds the New Relic MCP (routed through this APIM gateway) to Claude Code.

**Who this is for**: AMN engineers on the **APIM Claude Code path** (the default at AMN — installed via `AMNEngineering/amn-claude-code-client`'s `Bootstrap-TerminalApimDev.ps1` or equivalent). If you're on the Anthropic-direct Claude Code subscription (SSO cohort), use [`AMNEngineering/newrelic-mcp-sso`](https://github.com/AMNEngineering/newrelic-mcp-sso) instead.

## What it does

Merges an `newrelic` entry into `~/.claude/.mcp.json` (non-destructively) pointing at this APIM gateway. Authentication uses a `headersHelper` that calls `az account get-access-token` on every request — so tokens refresh automatically, no static value stored on disk, no NR key on your laptop (APIM injects it server-side from Key Vault).

The `.mcp.json` entry looks like:

```jsonc
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev",
      "headersHelper": {
        "command": "az",
        "args": [
          "account", "get-access-token",
          "--resource", "api://709bbe94-f759-422f-b7fa-28f1fde28ae1",
          "--query", "{Authorization: join(' ',['Bearer',accessToken])}",
          "-o", "json"
        ]
      }
    }
  }
}
```

## Prerequisites

- **Claude Code ≥ v2.1.195**.
- **Azure CLI** on PATH (`az --version`). The APIM Claude Code client bootstrap installs this for you; if you haven't run that yet, install via `winget install Microsoft.AzureCLI` (Windows) or `brew install azure-cli` (macOS).
- **An active `az login` session** authenticated against the AMN tenant. The APIM client bootstrap prompts for this on first run; `az account show` should return an account you recognize.
- **Membership in the `AZ_JobRole_Observability_NewRelicMcp_User` AD group** — request via ServiceNow.
- `NODE_OPTIONS=--use-system-ca` (corp Zscaler TLS trust). The APIM Claude Code bootstrap sets this; if you're using Claude Desktop launched from Finder/Start-menu, run `Set-DesktopCodeTabCaTrust.ps1` from `amn-claude-code-client`.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install.sh | bash
```

Or, from a local clone: `bash client/install.sh`

**Windows (PowerShell):**

```powershell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install.ps1 | iex
```

Or, from a local clone: `.\client\install.ps1`

Both installers accept `-Check` / `--check` to validate + report without modifying anything, and `-Env dev|int` / `--env dev|int` to target a non-default environment (default: `dev`).

## Verify

1. Restart Claude Code (fully quit + relaunch — MCP config is read at startup).
2. Run `/mcp` — `newrelic` should show **✔ Connected**. There is **no OAuth prompt** on this path; the `headersHelper` mints an Entra bearer from your `az` session on every request.
3. Ask for a read, e.g. "list the New Relic accounts I can access."
4. Restart Claude Code again — since the `headersHelper` refreshes tokens per request, sessions never age out mid-use.

## Uninstall

Remove the `newrelic` block from `~/.claude/.mcp.json` (or delete the file if that was its only entry).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/mcp` shows `newrelic: ✗ Failed to connect` | Check `az account show` — you need an active `az login` session. Also verify `az account get-access-token --resource api://709bbe94-f759-422f-b7fa-28f1fde28ae1 --query accessToken -o tsv` returns a token. If it errors on `AADSTS...`, your account isn't in the access group. |
| `401` at the gateway | Not in `AZ_JobRole_Observability_NewRelicMcp_User`. Request via ServiceNow, then re-check `/mcp`. |
| TLS failure to `api.dev.amnhealthcare.io` | Missing `NODE_OPTIONS=--use-system-ca`. See `AMNEngineering/amn-claude-code-client/scripts/targets/dev/Desktop/Set-DesktopCodeTabCaTrust.ps1` for the Desktop app; the Terminal / VS Code bootstraps set it automatically. |
| Claude Code < v2.1.195 | Upgrade — older versions don't support the `headersHelper` MCP config shape. |
| I want to use prod / int instead of dev | Re-run the installer with `--env int` (or `-Env int` on Windows). The installer accepts `dev`, `int`. Prod use is a separate governance conversation. |

See the top-level [`docs/CONNECT-MCP-CLIENT.md`](../docs/CONNECT-MCP-CLIENT.md) for connection details for VS Code, Copilot Studio, and raw HTTP clients.

## Security posture

- **No NR key on your laptop.** APIM injects the NerdGraph key from Key Vault at the gateway.
- **Per-user Entra identity.** Every request carries your `az`-minted bearer; APIM validates the JWT + AD-group membership. Audit trail attributes to you individually.
- **Auto-refreshing tokens.** `headersHelper` re-runs `az` on each request, so tokens never expire mid-session.
