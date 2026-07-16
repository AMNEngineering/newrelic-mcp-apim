terraform {
  backend "azurerm" {
    # Backend config provided at init time via -backend-config flags or environment variables
    # Example:
    #   terraform init \
    #     -backend-config="resource_group_name=tfstate-rg" \
    #     -backend-config="storage_account_name=tfstatestorage" \
    #     -backend-config="container_name=tfstate" \
    #     -backend-config="key=newrelic-{environment}.tfstate"
  }
}
