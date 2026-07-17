# Int environment — New Relic MCP gateway
# APIM: amn-wus2-hub-apim-i02 (int lives in the prod subscription; pipeline uses the Upper WIF connection)

environment         = "int"
apim_name           = "amn-wus2-hub-apim-i02"
apim_resource_group = "amn-wus2-hub-rg-i01"

backend_url = "https://mcp.newrelic.com"

tenant_id = "6232c2ec-fa42-4f27-92cd-787913fba489"

# Dedicated New Relic MCP Entra app (DECISION #2) — same single app across envs
# for the pilot (one app for read + write), used as the JWT audience. Create with
# identity/New-NewRelicMcpAppReg.ps1; paste the Application (client) ID here.
# A per-env split is optional future hardening.
newrelic_mcp_app_id = "REPLACE-WITH-newrelic-mcp-APP-ID"

# Authorized AD group (DECISION #2): membership in
# AZ_JobRole_Observability_NewRelicMcp_User gates access (groups claim), not an
# app role. Create it via the identity script, then paste its Object ID here.
newrelic_user_group_oid = "REPLACE-WITH-newrelic-mcp-GROUP-OID"

key_vault_name               = "co-wus2-newrelic-kv-p01"
newrelic_api_key_secret_name = "AMNHealthcare-NR-Terraform-UserKey"

rate_limit_calls          = 300
rate_limit_period_seconds = 60

tags = {
  environment = "int"
  project     = "newrelic-mcp-apim"
  managed_by  = "terraform"
  cost_center = "platform-engineering"
}
