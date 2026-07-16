output "backend_id" {
  description = "Backend resource ID"
  value       = azurerm_api_management_backend.this.id
}

output "backend_name" {
  description = "Backend name"
  value       = azurerm_api_management_backend.this.name
}

output "pool_name" {
  description = "Backend pool name (for policy reference)"
  value       = "pool-${var.service_name}-${var.environment}"
}

output "backend_url" {
  description = "Backend URL"
  value       = azurerm_api_management_backend.this.url
}
