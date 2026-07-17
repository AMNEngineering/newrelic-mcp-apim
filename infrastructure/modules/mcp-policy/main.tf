terraform {
  required_version = ">= 1.6"
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 1.13"
    }
  }
}

# Attach the API-level policy to the native type=mcp API via azapi. (azurerm's
# api-policy resource resolves the API by name+revision through a data source,
# which is unreliable against an azapi-created type=mcp API — so we set the policy
# as a child azapi resource of the API instead. amn-passport-mcp proves an
# API-level policy attaches cleanly to a type=mcp API.)
resource "azapi_resource" "this" {
  type                      = "Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview"
  name                      = "policy"
  parent_id                 = var.api_resource_id
  schema_validation_enabled = false

  body = jsonencode({
    properties = {
      format = "rawxml"
      value  = var.policy_xml_content
    }
  })
}
