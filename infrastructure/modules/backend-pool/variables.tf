variable "apim_name" {
  description = "Name of the APIM instance"
  type        = string
}

variable "resource_group" {
  description = "Resource group containing the APIM instance"
  type        = string
}

variable "service_name" {
  description = "Service name (e.g., 'newrelic', 'newrelic')"
  type        = string
}

variable "environment" {
  description = "Environment (dev, int, prod)"
  type        = string
}

variable "backend_url" {
  description = "Backend URL (e.g., https://mcp.newrelic.com)"
  type        = string
}

variable "backend_protocol" {
  description = "Backend protocol"
  type        = string
  default     = "http"
}

variable "tls_validate_certificate_chain" {
  description = "Validate TLS certificate chain"
  type        = bool
  default     = true
}

variable "tls_validate_certificate_name" {
  description = "Validate TLS certificate name"
  type        = bool
  default     = true
}

variable "description" {
  description = "Backend description"
  type        = string
  default     = ""
}
