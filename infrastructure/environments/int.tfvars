# Int environment — New Relic MCP gateway
# APIM: amn-wus2-hub-apim-i02 (int lives in the prod subscription; pipeline uses the Upper WIF connection)

environment         = "int"
apim_name           = "amn-wus2-hub-apim-i02"
apim_resource_group = "amn-wus2-hub-rg-i01"

backend_url = "https://mcp.newrelic.com"

tenant_id = "6232c2ec-fa42-4f27-92cd-787913fba489"

# Reuse of api://newrelic-mcp-reader (DECISION #2). Split to a dedicated
# per-env app + AZ_AMN_AAD_NewRelicMcp_Int_User group before broad rollout.
# TODO(Preflight): fill the real app id from Entra.
newrelic_mcp_app_id = "REPLACE-WITH-newrelic-mcp-reader-APP-ID"

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
