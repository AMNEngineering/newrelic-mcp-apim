output "api_id" {
  description = "APIM API resource ID (azapi resource id) — parent for the policy."
  value       = azapi_resource.mcp_api.id
}

output "api_name" {
  description = "API name"
  value       = azapi_resource.mcp_api.name
}

output "api_path" {
  description = "Client-facing API path"
  value       = local.api_path
}

output "api_url" {
  description = "Full MCP endpoint URL clients connect to"
  value       = "${data.azurerm_api_management.apim.gateway_url}/${local.api_path}"
}

output "backend_id" {
  description = "Backend resource name"
  value       = azurerm_api_management_backend.this.name
}
