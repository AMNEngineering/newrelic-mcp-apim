variable "environment" {
  description = "Environment (dev, int, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "int", "prod"], var.environment)
    error_message = "Environment must be dev, int, or prod"
  }
}

variable "apim_name" {
  description = "APIM instance name"
  type        = string
}

variable "apim_resource_group" {
  description = "APIM resource group"
  type        = string
}

variable "backend_url" {
  description = "New Relic hosted MCP endpoint (base URL). The API operations expose /mcp; the policy routes here."
  type        = string
  default     = "https://mcp.newrelic.com"
}

variable "tenant_id" {
  description = "Azure AD tenant ID (AMN Healthcare)"
  type        = string
  default     = "6232c2ec-fa42-4f27-92cd-787913fba489"
}

variable "newrelic_mcp_app_id" {
  description = "Application (client) ID of the dedicated New Relic MCP Entra app (DECISION #2). ONE app for all New Relic MCP actions — read AND write; New Relic does not distinguish them at the token level, so neither does the app. The policy validates this audience and requires the MCP.Access.Developer app role; read/write is enforced at the marketplace/skill layer. Create it with identity/New-NewRelicMcpAppReg.ps1 and paste the id here."
  type        = string
}

# --- New Relic key (DECISION #1) ------------------------------------------
# New Relic has no read-only key type; the "read" key is the existing NerdGraph
# User key. Delivered as a Key Vault reference so it never enters TF state.
variable "key_vault_name" {
  description = "Key Vault holding the New Relic User key. When set, the api-key named value becomes a KV reference (recommended). Default vault co-wus2-newrelic-kv-p01."
  type        = string
  default     = ""
}

variable "newrelic_api_key_secret_name" {
  description = "Secret name in key_vault_name for the New Relic User key. Confirmed: AMNHealthcare-NR-Terraform-UserKey (exists + enabled in co-wus2-newrelic-kv-p01). Still confirm the key's cross-subaccount reach at Verify."
  type        = string
  default     = "AMNHealthcare-NR-Terraform-UserKey"
}

variable "newrelic_api_key" {
  description = "FALLBACK ONLY: inline New Relic User key (NRAK-...). Lands in TF state — leave empty and use key_vault_name (DECISION #1). If ever used, supply via TF_VAR_newrelic_api_key in the pipeline, never committed."
  type        = string
  sensitive   = true
  default     = ""
}

# --- Rate limit (DECISION #3, revised) ------------------------------------
# Unlike the sfdc reference (which documents but does not implement a limit),
# New Relic DOES have a flood/cost vector (arbitrary NRQL), so we implement a
# real per-user cap. Tune to ingest-cost tolerance.
variable "rate_limit_calls" {
  description = "Per-user call budget for the MCP endpoint (flood/cost guardrail)."
  type        = number
  default     = 300
}

variable "rate_limit_period_seconds" {
  description = "Renewal window (seconds) for rate_limit_calls."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    project    = "newrelic-mcp-apim"
    managed_by = "terraform"
  }
}
