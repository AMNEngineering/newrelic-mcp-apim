# Client-side installers

Adds the New Relic MCP (routed through this APIM gateway) to supported Claude
and GitHub Copilot clients.

**Who this is for**: AMN engineers on the **APIM Claude Code path** (the default at AMN — installed via `AMNEngineering/amn-claude-code-client`'s `Bootstrap-TerminalApimDev.ps1` or equivalent). If you're on the Anthropic-direct Claude Code subscription (SSO cohort), use [`AMNEngineering/newrelic-mcp-sso`](https://github.com/AMNEngineering/newrelic-mcp-sso) instead.

## Claude Code

### What it does

Merges a `newrelic` entry into the supported Claude Code user configuration file, `~/.claude.json`, without changing unrelated top-level settings or other MCP servers. Authentication uses a `headersHelper` command that calls `az account get-access-token` when Claude Code connects or reconnects. Claude Code also re-runs it and retries once after a `401` or `403`, so no static value is stored on disk and no NR key is kept on your laptop (APIM injects it server-side from Key Vault).

The `~/.claude.json` entry looks like:

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

### Prerequisites

- **Claude Code ≥ v2.1.195**.
- **Azure CLI** on PATH (`az --version`). The APIM Claude Code client bootstrap installs this for you; if you haven't run that yet, install via `winget install Microsoft.AzureCLI` (Windows) or `brew install azure-cli` (macOS).
- **An active `az login` session** authenticated against the AMN tenant. The APIM client bootstrap prompts for this on first run; `az account show` should return an account you recognize.
- **Membership in the `AZ_JobRole_Observability_NewRelicMcp_User` AD group** — request via ServiceNow.
- `NODE_OPTIONS=--use-system-ca` (corp Zscaler TLS trust). The APIM Claude Code bootstrap sets this; if you're using Claude Desktop launched from Finder/Start-menu, run `Set-DesktopCodeTabCaTrust.ps1` from `amn-claude-code-client`.

### Install

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

### Verify

1. Restart Claude Code (fully quit + relaunch — MCP config is read at startup).
2. Run `/mcp` — `newrelic` should show **✔ Connected**. There is **no OAuth prompt** on this path; the `headersHelper` mints an Entra bearer from your `az` session when Claude Code connects.
3. Ask for a read, e.g. "list the New Relic accounts I can access."
4. If a request gets a `401` or `403`, Claude Code re-runs the helper, reconnects with fresh headers, and retries the request once.

### Uninstall

Remove only the `mcpServers.newrelic` block from `~/.claude.json`. If `mcpServers` is then empty, that top-level key can also be removed; preserve the file and all unrelated Claude Code settings.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/mcp` shows `newrelic: ✗ Failed to connect` | Check `az account show` — you need an active `az login` session. Also verify `az account get-access-token --resource api://709bbe94-f759-422f-b7fa-28f1fde28ae1 --query accessToken -o tsv` returns a token. If it errors on `AADSTS...`, your account isn't in the access group. |
| `401` at the gateway | Not in `AZ_JobRole_Observability_NewRelicMcp_User`. Request via ServiceNow, then re-check `/mcp`. |
| TLS failure to `api.dev.amnhealthcare.io` | Missing `NODE_OPTIONS=--use-system-ca`. See `AMNEngineering/amn-claude-code-client/scripts/targets/dev/Desktop/Set-DesktopCodeTabCaTrust.ps1` for the Desktop app; the Terminal / VS Code bootstraps set it automatically. |
| Claude Code < v2.1.195 | Upgrade — older versions don't support the `headersHelper` MCP config shape. |
| I want to use prod / int instead of dev | Re-run the installer with `--env int` (or `-Env int` on Windows). The installer accepts `dev`, `int`. Prod use is a separate governance conversation. |

See the top-level [`docs/CONNECT-MCP-CLIENT.md`](../docs/CONNECT-MCP-CLIENT.md) for connection details for VS Code, Copilot Studio, and raw HTTP clients.

### Security posture

- **No NR key on your laptop.** APIM injects the NerdGraph key from Key Vault at the gateway.
- **Per-user Entra identity.** Every request carries your `az`-minted bearer; APIM validates the JWT + AD-group membership. Audit trail attributes to you individually.
- **Refreshable tokens.** `headersHelper` re-runs `az` on connection/reconnect and after a `401` or `403`; Claude Code retries the failed request once with the fresh header.

## GitHub Copilot CLI, App, and VS Code Agent Host

Copilot does not support Claude's `headersHelper` setting. The Copilot
installer therefore installs a small, version-pinned stdio bridge under
`${COPILOT_HOME:-~/.copilot}/servers/newrelic-apim` and adds a normal local MCP
entry to `~/.copilot/mcp-config.json`.

The bridge uses the official MCP SDK. It invokes Azure CLI directly (never
through a shell), keeps the Entra bearer in memory, refreshes shortly before
JWT expiry, and retries once with a fresh token after `401` or `403`. It accepts
only the AMN dev/int New Relic gateway URLs and rejects redirects.

### Copilot prerequisites

- Node.js 20 or newer and npm.
- Azure CLI on `PATH`, with an active AMN tenant login.
- Membership in `AZ_JobRole_Observability_NewRelicMcp_User`.
- `jq` on macOS/Linux.

### Copilot install

**macOS/Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install-copilot.sh | bash
```

**Windows PowerShell:**

```powershell
iwr -useb https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/master/client/install-copilot.ps1 | iex
```

From a clone, use `bash client/install-copilot.sh --env int` or
`.\client\install-copilot.ps1 -Env int`. Both installers support check-only
mode; pass `--check` or `-Check`.

### Copilot coverage

| Surface | Result |
|---|---|
| Copilot CLI | Reads the installed user entry from `~/.copilot/mcp-config.json`. |
| GitHub Copilot App | Uses the same Copilot CLI MCP configuration. |
| VS Code Agent Host | Reads `~/.copilot/mcp-config.json` natively. |
| VS Code extension host | Add the same stdio entry through **MCP: Open User Configuration** if Agent Host is not enabled. |
| JetBrains Copilot | Add the installed bridge through **Copilot Chat > Tools > Add MCP Tools**; the plugin does not consume Copilot CLI user configuration. |
| Copilot cloud agent/code review | Not supported: those hosted surfaces cannot run this local bridge or perform interactive delegated authentication. |

The installer does not install an IDE extension or silently change IDE
profiles. Install GitHub Copilot through the IDE's managed extension channel;
the shared config automatically covers VS Code Agent Host, while other hosts
must reference the already-installed bridge.

### Copilot verify

Start a new Copilot session and run `/mcp show newrelic`. The server should be
connected and list New Relic tools. If it fails, run:

```bash
az account get-access-token \
  --resource api://709bbe94-f759-422f-b7fa-28f1fde28ae1 \
  --query accessToken -o tsv
```

The token should be returned to the terminal. Do not paste or store it.

### Copilot uninstall

Remove only `mcpServers.newrelic` from `~/.copilot/mcp-config.json` (or from
`$COPILOT_HOME/mcp-config.json` when overridden), then remove the owned
`servers/newrelic-apim` directory under that same Copilot home. Preserve every
other MCP entry and top-level setting.
