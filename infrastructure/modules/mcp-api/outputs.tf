output "api_id" {
  description = "API resource ID"
  value       = azurerm_api_management_api.this.id
}

output "api_name" {
  description = "API name"
  value       = azurerm_api_management_api.this.name
}

output "api_path" {
  description = "API path"
  value       = azurerm_api_management_api.this.path
}

output "api_url" {
  description = "Full API URL"
  value       = "https://${data.azurerm_api_management.apim.gateway_url}/${azurerm_api_management_api.this.path}"
}

output "operation_id" {
  description = "MCP POST operation ID"
  value       = azurerm_api_management_api_operation.mcp_post.operation_id
}

output "mcp_get_operation_id" {
  description = "MCP GET operation ID"
  value       = azurerm_api_management_api_operation.mcp_get.operation_id
}

output "mcp_delete_operation_id" {
  description = "MCP DELETE operation ID"
  value       = azurerm_api_management_api_operation.mcp_delete.operation_id
}

output "legacy_operation_id" {
  description = "Legacy MCP POST operation ID (backward compatibility)"
  value       = azurerm_api_management_api_operation.mcp_invoke_legacy.operation_id
}
