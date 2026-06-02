terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }

  backend "azurerm" {
    # Backend config provided via pipeline
  }
}

provider "azurerm" {
  features {}
}

#=============================================================================
# Variables
#=============================================================================

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "apim_name" {
  description = "Existing APIM instance name"
  type        = string
}

variable "apim_resource_group" {
  description = "Existing APIM resource group"
  type        = string
}

variable "newrelic_mcp_app_id" {
  description = "Entra app registration ID for New Relic MCP access"
  type        = string
}

variable "newrelic_api_key" {
  description = "New Relic API key (NRAK-...) - sensitive"
  type        = string
  sensitive   = true
}

#=============================================================================
# Data Sources
#=============================================================================

data "azurerm_api_management" "existing" {
  name                = var.apim_name
  resource_group_name = var.apim_resource_group
}

#=============================================================================
# APIM Named Values
#=============================================================================

# Store New Relic API key as secret
resource "azurerm_api_management_named_value" "newrelic_api_key" {
  name                = "nv-newrelic-mcp-api-key"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  display_name        = "nv-newrelic-mcp-api-key"
  secret              = true
  value               = var.newrelic_api_key
}

# Store app registration ID
resource "azurerm_api_management_named_value" "newrelic_mcp_app_id" {
  name                = "newrelic-mcp-app-id"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  display_name        = "newrelic-mcp-app-id"
  value               = var.newrelic_mcp_app_id
}

#=============================================================================
# APIM Backend
#=============================================================================

resource "azurerm_api_management_backend" "newrelic_mcp" {
  name                = "backend-newrelic-mcp-${var.environment}"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  protocol            = "http"
  url                 = "https://mcp.newrelic.com"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

#=============================================================================
# APIM API
#=============================================================================

resource "azurerm_api_management_api" "newrelic_mcp" {
  name                = "api-newrelic-mcp-${var.environment}"
  resource_group_name = var.apim_resource_group
  api_management_name = var.apim_name
  revision            = "1"
  display_name        = "New Relic MCP API (${var.environment})"
  path                = "mcp/newrelic/${var.environment}"
  protocols           = ["https"]
  subscription_required = false # Using JWT validation instead
}

# APIM Operation: ALL methods to /mcp/*
resource "azurerm_api_management_api_operation" "mcp_all" {
  operation_id        = "mcp-all"
  api_name            = azurerm_api_management_api.newrelic_mcp.name
  api_management_name = var.apim_name
  resource_group_name = var.apim_resource_group
  display_name        = "New Relic MCP Proxy"
  method              = "*" # All HTTP methods
  url_template        = "/mcp/*"

  response {
    status_code = 200
  }

  response {
    status_code = 401
  }

  response {
    status_code = 403
  }

  response {
    status_code = 429
  }
}

#=============================================================================
# Outputs
#=============================================================================

output "apim_mcp_endpoint" {
  value       = "https://${data.azurerm_api_management.existing.gateway_url}/mcp/newrelic/${var.environment}/mcp/"
  description = "APIM-proxied New Relic MCP endpoint"
}

output "backend_id" {
  value       = azurerm_api_management_backend.newrelic_mcp.name
  description = "APIM backend ID"
}

output "api_id" {
  value       = azurerm_api_management_api.newrelic_mcp.name
  description = "APIM API ID"
}

output "next_steps" {
  value = <<-EOT
    ============================================================
    New Relic MCP APIM Proxy - Deployment Complete
    ============================================================

    1. Apply APIM policy:
       az apim api policy create \
         --resource-group ${var.apim_resource_group} \
         --service-name ${var.apim_name} \
         --api-id ${azurerm_api_management_api.newrelic_mcp.name} \
         --xml-content @../apim-policy-newrelic-mcp.xml

    2. Update policy placeholders:
       - {{newrelic-mcp-app-id}} → ${azurerm_api_management_named_value.newrelic_mcp_app_id.name}
       - {{nv-newrelic-mcp-api-key}} → ${azurerm_api_management_named_value.newrelic_api_key.name}
       - {{backend-id-newrelic-mcp}} → ${azurerm_api_management_backend.newrelic_mcp.name}

    3. Test endpoint:
       curl -X POST ${output.apim_mcp_endpoint.value} \
         -H "Authorization: Bearer $(az account get-access-token --resource api://${var.newrelic_mcp_app_id} --query accessToken -o tsv)" \
         -H "Content-Type: application/json" \
         -d '{"jsonrpc":"2.0","method":"capabilities/list","id":1}'

    4. Update developer .mcp.json:
       {
         "mcpServers": {
           "newrelic": {
             "type": "http",
             "url": "${output.apim_mcp_endpoint.value}",
             "auth": {
               "type": "bearer",
               "token": {
                 "command": "az",
                 "args": ["account", "get-access-token", "--resource", "api://${var.newrelic_mcp_app_id}", "--query", "accessToken", "-o", "tsv"]
               }
             }
           }
         }
       }

    ============================================================
  EOT
}
