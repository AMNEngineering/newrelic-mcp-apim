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

data "azurerm_api_management" "apim" {
  name                = var.apim_name
  resource_group_name = var.resource_group
}

locals {
  api_name     = "api-${var.service_name}-${var.environment}"
  backend_name = "backend-${var.service_name}-${var.environment}"
  api_path     = var.api_path != "" ? var.api_path : "mcp/${var.service_name}/${var.environment}"
  api_desc     = var.api_description != "" ? var.api_description : "MCP API for ${var.service_name} (${var.environment})"
}

# Backend: the upstream MCP server (New Relic's hosted MCP).
resource "azurerm_api_management_backend" "this" {
  name                = local.backend_name
  resource_group_name = var.resource_group
  api_management_name = var.apim_name
  protocol            = "http"
  url                 = var.backend_url
  description         = "New Relic hosted MCP (${var.environment})"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# Native APIM MCP API (type=mcp), modeled on amn-passport-mcp on this same APIM.
# azapi because azurerm cannot express type=mcp / mcpProperties. Routing to the
# backend is native (backendId + mcpProperties.endpoints.mcp.uriTemplate) — no
# hand-declared operations and no set-backend-service in the policy.
resource "azapi_resource" "mcp_api" {
  type                      = "Microsoft.ApiManagement/service/apis@2024-06-01-preview"
  name                      = local.api_name
  parent_id                 = data.azurerm_api_management.apim.id
  schema_validation_enabled = false

  body = jsonencode({
    properties = {
      displayName          = upper("${var.service_name} MCP ${var.environment}")
      description          = local.api_desc
      path                 = local.api_path
      protocols            = ["https"]
      type                 = "mcp"
      subscriptionRequired = var.subscription_required
      backendId            = azurerm_api_management_backend.this.name
      mcpProperties = {
        endpoints = {
          mcp = {
            # Path appended to the backend URL. NR's MCP lives at /mcp/ on
            # mcp.newrelic.com; confirm at plan (Passport uses /runtime/webhooks/mcp).
            uriTemplate = var.backend_mcp_path
          }
        }
      }
    }
  })

  depends_on = [azurerm_api_management_backend.this]
}
