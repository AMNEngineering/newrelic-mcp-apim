terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}

resource "azurerm_api_management_api_operation_policy" "this" {
  api_name            = var.api_name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  operation_id        = var.operation_id

  xml_content = var.policy_xml_content
}
