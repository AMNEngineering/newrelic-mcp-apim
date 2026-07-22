terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 1.13"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {
  # Hosted ADO agents have no system MI — azapi's default chain hits IMDS first
  # and 400s. Disable MSI so it falls through to the AzureCLI@2 session.
  use_msi = false
}

# ---------------------------------------------------------------------------
# Named values consumed by the API policy.
#
# New Relic is far simpler than the Salesforce reference: there is NO OAuth token
# exchange. New Relic's hosted MCP authenticates with a single static NerdGraph
# User key sent as an `Api-Key` header. We only need the app id (JWT audience),
# the authorized group OID (groups-claim gate), and the key itself.
#
# DECISION #1: the key is a Key Vault REFERENCE (never inline in TF state) when
# var.key_vault_name is set. New Relic has no read-only key type — read/write is
# enforced at the marketplace/skill layer, not the credential.
# ---------------------------------------------------------------------------
module "named_values" {
  source = "./modules/named-values"

  apim_name      = var.apim_name
  resource_group = var.apim_resource_group

  named_values = merge(
    {
      # Entra app id (plain text; policy validates JWT audience against it)
      "newrelic-mcp-app-id" = {
        display_name = "NewRelic-MCP-App-ID"
        value        = var.newrelic_mcp_app_id
      }

      # Authorized AD group OID (policy requires this in the JWT groups claim)
      "nv-newrelic-user-group-oid" = {
        display_name = "NewRelic-MCP-User-Group-OID"
        value        = var.newrelic_user_group_oid
      }
    },

    # New Relic User key: Key Vault reference when key_vault_name is set
    # (recommended, DECISION #1), otherwise inline (fallback only).
    var.key_vault_name != "" ? {
      "nv-newrelic-mcp-api-key" = {
        display_name        = "NewRelic-MCP-Api-Key"
        key_vault_secret_id = "https://${var.key_vault_name}.vault.azure.net/secrets/${var.newrelic_api_key_secret_name}"
      }
      } : {
      "nv-newrelic-mcp-api-key" = {
        display_name = "NewRelic-MCP-Api-Key"
        secret_value = var.newrelic_api_key
      }
    }
  )

  tags = var.tags
}

# Native APIM MCP API (type=mcp) + backend = New Relic's hosted MCP. Modeled on
# amn-passport-mcp on this same APIM. Clients connect to it as a first-class MCP
# server; routing to New Relic is native (backendId + mcpProperties).
module "mcp_api" {
  source = "./modules/mcp-api"

  apim_name       = var.apim_name
  resource_group  = var.apim_resource_group
  service_name    = "newrelic"
  environment     = var.environment
  api_path        = "mcp/newrelic/${var.environment}"
  backend_url     = var.backend_url
  api_description = "Claude Code / MCP clients -> APIM -> New Relic hosted MCP (${var.environment}). Entra JWT; AD group-gated; New Relic key injected server-side."

  depends_on = [module.named_values]
}

# API-level policy: JWT (dual audience) + AD group-membership gate + audit +
# per-user rate limit + Api-Key injection. No set-backend-service/rewrite-uri —
# the type=mcp API routes to the backend natively.
module "mcp_policy" {
  source = "./modules/mcp-policy"

  api_resource_id = module.mcp_api.api_id

  policy_xml_content = templatefile("${path.root}/../policies/apim-policy-newrelic-mcp.xml", {
    tenant_id                 = var.tenant_id
    rate_limit_calls          = var.rate_limit_calls
    rate_limit_period_seconds = var.rate_limit_period_seconds
  })

  depends_on = [module.mcp_api, module.named_values]
}
