# Dev environment — New Relic MCP gateway
# APIM: amn-wus2-hub-apim-d02 (shared hub instance, same as the Claude Code model gateway)

environment         = "dev"
apim_name           = "amn-wus2-hub-apim-d02"
apim_resource_group = "amn-wus2-hub-rg-d01"

# New Relic's hosted MCP (Streamable HTTP). The policy injects the Api-Key.
backend_url = "https://mcp.newrelic.com"

tenant_id = "6232c2ec-fa42-4f27-92cd-787913fba489"

# Dedicated New Relic MCP Entra app (DECISION #2): ONE app for all NR MCP actions
# (read + write). Callers present a JWT for this audience carrying the
# MCP.Access.Developer app role. Create it with identity/New-NewRelicMcpAppReg.ps1
# and paste the Application (client) ID here (TODO Preflight).
newrelic_mcp_app_id = "REPLACE-WITH-newrelic-mcp-APP-ID"

# New Relic User key via Key Vault reference (DECISION #1 — never inline in state).
key_vault_name               = "co-wus2-newrelic-kv-p01"
newrelic_api_key_secret_name = "AMNHealthcare-NR-Terraform-UserKey"

# Per-user flood/cost guardrail (DECISION #3).
rate_limit_calls          = 300
rate_limit_period_seconds = 60

tags = {
  environment = "dev"
  project     = "newrelic-mcp-apim"
  managed_by  = "terraform"
  cost_center = "platform-engineering"
}
