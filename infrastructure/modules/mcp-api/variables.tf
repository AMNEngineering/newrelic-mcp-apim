variable "apim_name" {
  description = "Name of the APIM instance"
  type        = string
}

variable "resource_group" {
  description = "Resource group containing the APIM instance"
  type        = string
}

variable "service_name" {
  description = "Service name (e.g., 'newrelic')"
  type        = string
}

variable "environment" {
  description = "Environment (dev, int, prod)"
  type        = string
}

variable "api_path" {
  description = "API path suffix (default: mcp/{service}/{env}). This is the client-facing MCP endpoint path."
  type        = string
  default     = ""
}

variable "subscription_required" {
  description = "Whether an APIM subscription key is required (auth is Entra JWT, so false)"
  type        = bool
  default     = false
}

variable "api_description" {
  description = "API description"
  type        = string
  default     = ""
}

variable "backend_url" {
  description = "Upstream MCP server base URL (e.g. https://mcp.newrelic.com)"
  type        = string
}

variable "backend_mcp_path" {
  description = "MCP endpoint path appended to backend_url (mcpProperties.endpoints.mcp.uriTemplate)."
  type        = string
  default     = "/mcp/"
}
