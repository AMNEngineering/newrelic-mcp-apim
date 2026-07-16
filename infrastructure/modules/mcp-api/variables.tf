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
  description = "API path suffix (default: mcp/{service}/{env})"
  type        = string
  default     = ""
}

variable "subscription_required" {
  description = "Whether APIM subscription key is required"
  type        = bool
  default     = false
}

variable "protocols" {
  description = "Allowed protocols"
  type        = list(string)
  default     = ["https"]
}

variable "api_description" {
  description = "API description"
  type        = string
  default     = ""
}

variable "oauth2_authorization_server_name" {
  description = "Name of the APIM OAuth2 authorization server to bind to this API. Empty string disables binding."
  type        = string
  default     = ""
}

variable "oauth2_scope" {
  description = "OAuth2 scope advertised in the API's OAuth2 binding (typically api://<client-app-id>/user_impersonation)."
  type        = string
  default     = ""
}
