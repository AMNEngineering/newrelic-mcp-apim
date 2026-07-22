output "named_value_ids" {
  description = "Map of named value names to their resource IDs"
  value       = { for k, v in azurerm_api_management_named_value.this : k => v.id }
}

output "named_value_names" {
  description = "Map of named value keys to their APIM reference names (for use in policies)"
  value       = { for k, v in azurerm_api_management_named_value.this : k => v.name }
}
