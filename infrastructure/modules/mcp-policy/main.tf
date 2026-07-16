terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}

data "azurerm_api_management_api" "this" {
  name                = var.api_name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group
  revision            = "1"
}

resource "azurerm_api_management_api_policy" "this" {
  api_name            = var.api_name
  api_management_name = var.apim_name
  resource_group_name = var.resource_group

  xml_content = var.policy_xml_content
}
