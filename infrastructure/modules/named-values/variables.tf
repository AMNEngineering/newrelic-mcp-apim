variable "apim_name" {
  description = "Name of the APIM instance"
  type        = string
}

variable "resource_group" {
  description = "Resource group containing the APIM instance"
  type        = string
}

variable "named_values" {
  description = "Map of named values to create. Each entry can have 'value' (plain), 'secret_value' (marked secret), or 'key_vault_secret_id' (KV reference)"
  type = map(object({
    display_name        = string
    value               = optional(string)
    secret_value        = optional(string)
    key_vault_secret_id = optional(string)
  }))
}

variable "tags" {
  description = "Tags to apply to named values"
  type        = map(string)
  default     = {}
}
