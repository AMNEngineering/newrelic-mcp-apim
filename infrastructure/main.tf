terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}

provider "azurerm" {
  features {}
}

# ---------------------------------------------------------------------------
# Named values consumed by the API policy.
#
# New Relic is far simpler than the Salesforce reference this repo is modeled
# on: there is NO OAuth token exchange. New Relic's hosted MCP authenticates
# with a single static NerdGraph User key sent as an `Api-Key` header, so we
# only need the app id (for JWT audience) and the key itself.
#
# DECISION #1: the key is delivered as a Key Vault REFERENCE (never inline in
# TF state) when var.key_vault_name is set. There is no read-only key type in
# New Relic — a User key inherits its user's permissions — so read/write is
# enforced at the skill layer, not the credential.
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

# Backend: New Relic's hosted MCP endpoint.
module "backend_pool" {
  source = "./modules/backend-pool"

  apim_name      = var.apim_name
  resource_group = var.apim_resource_group
  service_name   = "newrelic"
  environment    = var.environment
  backend_url    = var.backend_url

  tls_validate_certificate_chain = true
  tls_validate_certificate_name  = true

  description = "New Relic hosted MCP server (${var.environment})"

  depends_on = [module.named_values]
}

# The MCP API + operations (health, mcp POST/GET/DELETE).
# Plain azurerm REST API with MCP modeled as HTTP operations, routing handled
# in policy — matches the sfdc-read-mcp-apim gold-standard pattern (no azapi,
# no native type=mcp). No OAuth2 authorization server: New Relic clients are
# Claude Code (Entra JWT), not Power Automate / Copilot Studio connectors.
module "mcp_api" {
  source = "./modules/mcp-api"

  apim_name      = var.apim_name
  resource_group = var.apim_resource_group
  service_name   = "newrelic"
  environment    = var.environment

  api_path              = "mcp/newrelic/${var.environment}"
  subscription_required = false
  api_description       = "Claude Code -> APIM -> New Relic hosted MCP (${var.environment}). Entra JWT; role-gated; New Relic key injected server-side."

  depends_on = [module.backend_pool]
}

# API-level policy: JWT (dual audience) + MCP.Read role gate + audit +
# per-user rate limit + Api-Key injection + backend routing.
module "mcp_policy" {
  source = "./modules/mcp-policy"

  apim_name      = var.apim_name
  resource_group = var.apim_resource_group
  api_name       = module.mcp_api.api_name

  policy_xml_content = templatefile("${path.root}/../policies/apim-policy-newrelic-mcp.xml", {
    tenant_id                 = var.tenant_id
    environment               = var.environment
    rate_limit_calls          = var.rate_limit_calls
    rate_limit_period_seconds = var.rate_limit_period_seconds
    backend_url               = var.backend_url
  })

  depends_on = [module.mcp_api, module.named_values]
}

# Health check operation policy (no JWT — liveness probe for AFD/network).
module "health_check_policy" {
  source = "./modules/mcp-api-operation-policy"

  apim_name      = var.apim_name
  resource_group = var.apim_resource_group
  api_name       = module.mcp_api.api_name
  operation_id   = "health-check"

  policy_xml_content = templatefile("${path.root}/../policies/apim-policy-health-check.xml", {
    environment = var.environment
  })

  depends_on = [module.mcp_api]
}
