# Prod environment — New Relic MCP gateway
# SKELETON — do not deploy until CAB approval. The prod pipeline stages are
# commented out in .ado/pipelines/deploy.yml until then.
# APIM: amn-wus2-hub-apim-p02 (prod subscription; Upper WIF connection).

environment         = "prod"
apim_name           = "amn-wus2-hub-apim-p02"
apim_resource_group = "amn-wus2-hub-rg-p01"

backend_url = "https://mcp.newrelic.com"

tenant_id = "6232c2ec-fa42-4f27-92cd-787913fba489"

# Dedicated New Relic MCP Entra app (DECISION #2). For the pilot this is the same
# single app as dev/int; a dedicated prod app is optional future hardening.
newrelic_mcp_app_id = "TBD-newrelic-mcp-PROD-APP-ID"

# Authorized AD group (DECISION #2): membership gates access (groups claim). Group
# name TBD — confirm the group + its Object ID before enabling prod.
newrelic_user_group_oid = "TBD-newrelic-mcp-PROD-GROUP-OID"

key_vault_name               = "co-wus2-newrelic-kv-p01"
newrelic_api_key_secret_name = "AMNHealthcare-NR-Terraform-UserKey"

rate_limit_calls          = 300
rate_limit_period_seconds = 60

tags = {
  environment = "prod"
  project     = "newrelic-mcp-apim"
  managed_by  = "terraform"
  cost_center = "platform-engineering"
}
