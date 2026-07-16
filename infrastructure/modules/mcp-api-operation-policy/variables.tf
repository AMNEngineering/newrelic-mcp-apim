variable "apim_name" {
  description = "Name of the APIM instance"
  type        = string
}

variable "resource_group" {
  description = "Resource group name"
  type        = string
}

variable "api_name" {
  description = "Name of the API"
  type        = string
}

variable "operation_id" {
  description = "Operation ID to apply policy to"
  type        = string
}

variable "policy_xml_content" {
  description = "XML content of the policy"
  type        = string
}
