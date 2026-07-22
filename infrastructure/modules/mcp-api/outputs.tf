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

output "apim_internal_url" {
  description = "Internal APIM gateway URL for this API. NOT client-facing — APIM is internal-mode; clients use the AFD apex (see root apim_mcp_endpoint output)."
  value       = "${data.azurerm_api_management.apim.gateway_url}/${local.api_path}"
}

output "backend_id" {
  description = "Backend resource name"
  value       = azurerm_api_management_backend.this.name
}
