output "apim_mcp_endpoint" {
  description = "Full APIM MCP endpoint URL (replaces the direct mcp.newrelic.com URL in the client .mcp.json)."
  value       = module.mcp_api.api_url
}

output "api_id" {
  description = "APIM API resource ID"
  value       = module.mcp_api.api_id
}

output "api_name" {
  description = "APIM API name"
  value       = module.mcp_api.api_name
}

output "api_path" {
  description = "API path relative to the APIM gateway URL"
  value       = module.mcp_api.api_path
}

output "backend_id" {
  description = "Backend resource name"
  value       = module.mcp_api.backend_id
}

output "environment" {
  description = "Deployment environment"
  value       = var.environment
}

output "next_steps" {
  description = "Post-deployment instructions"
  value       = <<-EOT
    Deployment complete for ${var.environment}.

    Next steps:
    1. Verify named values in APIM (NewRelic-MCP-App-ID, NewRelic-MCP-Api-Key).
    2. Get a token:  az account get-access-token --resource api://${var.newrelic_mcp_app_id}
    3. Smoke test:   ./test-harness/Invoke-ApimSmokeTest.ps1 -Environment ${var.environment}
    4. MCP endpoint: ${module.mcp_api.api_url}

    Security:
    - Entra JWT validation + AD group-membership gate
    - Per-user rate limit: ${var.rate_limit_calls} calls / ${var.rate_limit_period_seconds}s
    - New Relic key injected server-side (client never holds it)
  EOT
}
