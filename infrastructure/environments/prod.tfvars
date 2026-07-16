# Prod environment — New Relic MCP gateway
# SKELETON — do not deploy until CAB approval. The prod pipeline stages are
# commented out in .ado/pipelines/deploy.yml until then.
# APIM: amn-wus2-hub-apim-p02 (prod subscription; Upper WIF connection).

environment         = "prod"
apim_name           = "amn-wus2-hub-apim-p02"
apim_resource_group = "amn-wus2-hub-rg-p01"

backend_url = "https://mcp.newrelic.com"

tenant_id = "6232c2ec-fa42-4f27-92cd-787913fba489"

# TODO(prod): dedicated prod app + AZ_AMN_AAD_NewRelicMcp_Prod_User group is the
# expected end state (least privilege). Confirm before enabling prod.
newrelic_mcp_app_id = "TBD-newrelic-mcp-reader-PROD-APP-ID"

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
