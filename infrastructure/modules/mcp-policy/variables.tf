variable "apim_name" {
  description = "Name of the APIM instance"
  type        = string
}

variable "resource_group" {
  description = "Resource group containing the APIM instance"
  type        = string
}

variable "api_name" {
  description = "API name to apply policy to"
  type        = string
}

variable "policy_xml_content" {
  description = "Complete policy XML content"
  type        = string
}
