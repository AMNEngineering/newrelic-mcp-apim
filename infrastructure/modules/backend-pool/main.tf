terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.71"
    }
  }
}

data "azurerm_api_management" "apim" {
  name                = var.apim_name
  resource_group_name = var.resource_group
}

# Backend resource
resource "azurerm_api_management_backend" "this" {
  name                = "backend-${var.service_name}-${var.environment}"
  resource_group_name = var.resource_group
  api_management_name = var.apim_name
  protocol            = var.backend_protocol
  url                 = var.backend_url
  description         = var.description != "" ? var.description : "Backend for ${var.service_name} ${var.environment}"

  tls {
    validate_certificate_chain = var.tls_validate_certificate_chain
    validate_certificate_name  = var.tls_validate_certificate_name
  }
}

# Backend pool (AMN Foundry pattern)
# Note: azurerm provider 3.x does not have native backend pool resource
# We create a pool using the backend's ID as the single member
# This aligns with AMN's naming convention: pool-{service}-{env}
resource "null_resource" "backend_pool" {
  # This is a placeholder for the pool pattern
  # In actual AMN deployments, pools are managed via Azure CLI or Portal
  # The policy references pool-{service}-{env} which wraps this backend

  triggers = {
    backend_id  = azurerm_api_management_backend.this.id
    pool_name   = "pool-${var.service_name}-${var.environment}"
    environment = var.environment
  }

  provisioner "local-exec" {
    when    = create
    command = <<-EOT
      echo "Backend pool naming convention:"
      echo "  Backend: ${azurerm_api_management_backend.this.name}"
      echo "  Pool: pool-${var.service_name}-${var.environment}"
      echo "Note: Pool creation requires manual setup or Azure CLI until azurerm provider supports it natively"
    EOT
  }
}
