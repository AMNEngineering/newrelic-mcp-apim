terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}

data "azurerm_api_management" "apim" {
  name                = var.apim_name
  resource_group_name = var.resource_group
}

locals {
  # Default path: mcp/{service}/{env}
  api_path        = var.api_path != "" ? var.api_path : "mcp/${var.service_name}/${var.environment}"
  api_name        = "api-${var.service_name}-${var.environment}"
  api_description = var.api_description != "" ? var.api_description : "MCP API for ${var.service_name} (${var.environment})"
}

resource "azurerm_api_management_api" "this" {
  name                  = local.api_name
  resource_group_name   = var.resource_group
  api_management_name   = var.apim_name
  revision              = "1"
  display_name          = upper("${var.service_name} MCP ${var.environment}")
  path                  = local.api_path
  protocols             = var.protocols
  subscription_required = var.subscription_required
  description           = local.api_description

  # API type - HTTP for MCP JSON-RPC
  service_url = "" # Backend routing handled by policy

  # Bind OAuth2 authorization server so APIM's exported OpenAPI carries the
  # correct authorize/token URLs and scope. Power Automate / Copilot Studio
  # use this metadata when building custom connectors against this API.
  dynamic "oauth2_authorization" {
    for_each = var.oauth2_authorization_server_name != "" ? [1] : []
    content {
      authorization_server_name = var.oauth2_authorization_server_name
      scope                     = var.oauth2_scope
    }
  }
}

# Health check endpoint (no auth required)
resource "azurerm_api_management_api_operation" "health_check" {
  operation_id        = "health-check"
  api_name            = azurerm_api_management_api.this.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
  description         = "Liveness probe for AFD and network routing verification"

  response {
    status_code = 200
    description = "Healthy"
    representation {
      content_type = "application/json"
    }
  }
}

# MCP streamable HTTP endpoint (native MCP shape)
resource "azurerm_api_management_api_operation" "mcp_post" {
  operation_id        = "mcp-post"
  api_name            = azurerm_api_management_api.this.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  display_name        = "MCP POST"
  method              = "POST"
  url_template        = "/mcp"
  description         = "MCP streamable HTTP POST endpoint"

  response {
    status_code = 200
    description = "Success"
    representation {
      content_type = "application/json"
    }
    representation {
      content_type = "text/event-stream"
    }
  }

  response {
    status_code = 202
    description = "Accepted"
  }

  response {
    status_code = 401
    description = "Unauthorized"
  }

  response {
    status_code = 429
    description = "Too Many Requests"
  }

  response {
    status_code = 500
    description = "Internal Server Error"
  }
}

resource "azurerm_api_management_api_operation" "mcp_get" {
  operation_id        = "mcp-get"
  api_name            = azurerm_api_management_api.this.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  display_name        = "MCP GET"
  method              = "GET"
  url_template        = "/mcp"
  description         = "MCP streamable HTTP GET endpoint"

  response {
    status_code = 200
    description = "Success"
    representation {
      content_type = "text/event-stream"
    }
  }

  response {
    status_code = 401
    description = "Unauthorized"
  }

  response {
    status_code = 429
    description = "Too Many Requests"
  }

  response {
    status_code = 500
    description = "Internal Server Error"
  }
}

resource "azurerm_api_management_api_operation" "mcp_delete" {
  operation_id        = "mcp-delete"
  api_name            = azurerm_api_management_api.this.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  display_name        = "MCP DELETE"
  method              = "DELETE"
  url_template        = "/mcp"
  description         = "MCP streamable HTTP session termination"

  response {
    status_code = 200
    description = "Success"
  }

  response {
    status_code = 204
    description = "No Content"
  }

  response {
    status_code = 401
    description = "Unauthorized"
  }

  response {
    status_code = 429
    description = "Too Many Requests"
  }

  response {
    status_code = 500
    description = "Internal Server Error"
  }
}

# Legacy endpoint for backward compatibility (existing clients)
resource "azurerm_api_management_api_operation" "mcp_invoke_legacy" {
  operation_id        = "invoke-mcp-legacy"
  api_name            = azurerm_api_management_api.this.name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  display_name        = "Invoke MCP (Legacy)"
  method              = "POST"
  url_template        = "/"
  description         = "MCP JSON-RPC 2.0 endpoint for backward compatibility (initialize, tools/list, tools/call)"

  response {
    status_code = 200
    description = "Success"
    representation {
      content_type = "application/json"
    }
  }

  response {
    status_code = 401
    description = "Unauthorized"
  }

  response {
    status_code = 429
    description = "Too Many Requests"
  }

  response {
    status_code = 500
    description = "Internal Server Error"
  }
}
