variable "api_resource_id" {
  description = "Resource ID of the type=mcp API (azapi) to attach the policy to."
  type        = string
}

variable "policy_xml_content" {
  description = "Rendered API-level policy XML."
  type        = string
}
