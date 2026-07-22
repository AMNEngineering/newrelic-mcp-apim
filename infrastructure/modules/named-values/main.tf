terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}


resource "azurerm_api_management_named_value" "this" {
  for_each = var.named_values

  name                = each.key
  resource_group_name = var.resource_group
  api_management_name = var.apim_name
  display_name        = each.value.display_name

  # Set value: use secret_value if provided, otherwise use value (unless using Key Vault)
  value = each.value.key_vault_secret_id == null ? (each.value.secret_value != null ? each.value.secret_value : each.value.value) : null

  # Mark as secret if secret_value is provided or using Key Vault
  secret = each.value.secret_value != null ? true : (each.value.key_vault_secret_id != null ? true : false)

  # Key Vault reference (use dynamic block syntax)
  dynamic "value_from_key_vault" {
    for_each = each.value.key_vault_secret_id != null ? [1] : []
    content {
      secret_id = each.value.key_vault_secret_id
    }
  }

  # Note: azurerm_api_management_named_value does not support tags

}
