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
  description = "New Relic hosted MCP base URL. NR exposes a single fixed MCP address for all needs (https://mcp.newrelic.com/mcp/), same across envs — this is the base; the /mcp/ path is the module's backend_mcp_path."
  type        = string
  default     = "https://mcp.newrelic.com"
}

variable "tenant_id" {
  description = "Azure AD tenant ID (AMN Healthcare)"
  type        = string
  default     = "6232c2ec-fa42-4f27-92cd-787913fba489"
}

variable "newrelic_mcp_app_id" {
  description = "Application (client) ID of the dedicated New Relic MCP Entra app (DECISION #2) — the JWT audience the policy validates. ONE app for all New Relic MCP actions — read AND write; New Relic does not distinguish them at the token level, so neither does the app. Create it with identity/New-NewRelicMcpAppReg.ps1 and paste the id here."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.newrelic_mcp_app_id)) && !can(regex("REPLACE|TBD", var.newrelic_mcp_app_id))
    error_message = "newrelic_mcp_app_id must be a real GUID (not a placeholder like REPLACE/TBD)."
  }
}

variable "newrelic_user_group_oid" {
  description = "Object ID of the dedicated New Relic MCP AD group AZ_JobRole_Observability_NewRelicMcp_User. Access is gated on membership in this group (the policy requires it in the JWT groups claim) — NOT an app role. Create it with identity/New-NewRelicMcpAppReg.ps1, then paste its OID here. Read/write is enforced at the marketplace/skill layer, so one group covers both."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.newrelic_user_group_oid)) && !can(regex("REPLACE|TBD", var.newrelic_user_group_oid))
    error_message = "newrelic_user_group_oid must be a real GUID (not a placeholder like REPLACE/TBD)."
  }
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
