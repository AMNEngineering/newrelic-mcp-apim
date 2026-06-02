#!/bin/bash
# Create ADO Variable Group for New Relic MCP APIM deployment
# Prerequisites: az devops extension installed, az login completed

set -e

echo "=================================================="
echo "New Relic MCP APIM - Variable Group Setup"
echo "=================================================="

# Configuration
ORG_URL="https://dev.azure.com/amnhealthcare"
PROJECT="CloudOps"
GROUP_NAME="newrelic-mcp-apim-vars"

# Check if logged in
if ! az devops project show --project "$PROJECT" --org "$ORG_URL" &>/dev/null; then
  echo "❌ Not logged in to Azure DevOps. Run: az login"
  exit 1
fi

echo "✅ Connected to ADO: $ORG_URL/$PROJECT"
echo ""

# Prompt for values
read -p "Enter ARM_CLIENT_ID (Service Principal App ID): " ARM_CLIENT_ID
read -sp "Enter ARM_CLIENT_SECRET (Service Principal Secret): " ARM_CLIENT_SECRET
echo ""
read -p "Enter ARM_SUBSCRIPTION_ID: " ARM_SUBSCRIPTION_ID
ARM_TENANT_ID="6232c2ec-fa42-4f27-92cd-787913fba489"

echo ""
read -p "Enter TF_STATE_RESOURCE_GROUP (default: rg-cloudops-terraform-state): " TF_STATE_RG
TF_STATE_RG=${TF_STATE_RG:-rg-cloudops-terraform-state}

read -p "Enter TF_STATE_STORAGE_ACCOUNT (default: stcloudopstfstatedev): " TF_STATE_SA
TF_STATE_SA=${TF_STATE_SA:-stcloudopstfstatedev}

read -p "Enter TF_STATE_CONTAINER (default: tfstate): " TF_STATE_CONTAINER
TF_STATE_CONTAINER=${TF_STATE_CONTAINER:-tfstate}

echo ""
read -p "Enter APIM_NAME (default: apim-amnhealthcare-dev): " APIM_NAME
APIM_NAME=${APIM_NAME:-apim-amnhealthcare-dev}

read -p "Enter APIM_RESOURCE_GROUP (default: rg-apim-dev): " APIM_RG
APIM_RG=${APIM_RG:-rg-apim-dev}

echo ""
echo "Fetching Entra App Registration for 'New Relic MCP Reader'..."
NEWRELIC_MCP_APP_ID=$(az ad app list --display-name "New Relic MCP Reader" --query "[0].appId" -o tsv)

if [ -z "$NEWRELIC_MCP_APP_ID" ]; then
  echo "❌ App registration 'New Relic MCP Reader' not found"
  echo "Creating now..."
  az ad app create \
    --display-name "New Relic MCP Reader" \
    --identifier-uris "api://newrelic-mcp-reader"

  NEWRELIC_MCP_APP_ID=$(az ad app list --display-name "New Relic MCP Reader" --query "[0].appId" -o tsv)
  echo "✅ Created app registration: $NEWRELIC_MCP_APP_ID"
else
  echo "✅ Found app registration: $NEWRELIC_MCP_APP_ID"
fi

echo ""
echo "Fetching New Relic API key from Key Vault..."
NEWRELIC_API_KEY=$(az keyvault secret show \
  --vault-name co-wus2-newrelic-kv-p01 \
  --name NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace \
  --query value -o tsv)

if [ -z "$NEWRELIC_API_KEY" ]; then
  echo "❌ Failed to retrieve New Relic API key from Key Vault"
  exit 1
fi

echo "✅ Retrieved New Relic API key (${NEWRELIC_API_KEY:0:10}...)"
echo ""

# Check if variable group exists
echo "Checking if variable group exists..."
GROUP_ID=$(az pipelines variable-group list \
  --org "$ORG_URL" \
  --project "$PROJECT" \
  --query "[?name=='$GROUP_NAME'].id | [0]" -o tsv)

if [ -n "$GROUP_ID" ]; then
  echo "⚠️  Variable group '$GROUP_NAME' already exists (ID: $GROUP_ID)"
  read -p "Delete and recreate? (y/N): " RECREATE
  if [[ "$RECREATE" =~ ^[Yy]$ ]]; then
    az pipelines variable-group delete \
      --id "$GROUP_ID" \
      --org "$ORG_URL" \
      --project "$PROJECT" \
      --yes
    echo "✅ Deleted existing variable group"
  else
    echo "Exiting. To update manually, use ADO portal."
    exit 0
  fi
fi

# Create variable group
echo ""
echo "Creating variable group: $GROUP_NAME"

az pipelines variable-group create \
  --name "$GROUP_NAME" \
  --org "$ORG_URL" \
  --project "$PROJECT" \
  --variables \
    TF_STATE_RESOURCE_GROUP="$TF_STATE_RG" \
    TF_STATE_STORAGE_ACCOUNT="$TF_STATE_SA" \
    TF_STATE_CONTAINER="$TF_STATE_CONTAINER" \
    ARM_CLIENT_ID="$ARM_CLIENT_ID" \
    ARM_SUBSCRIPTION_ID="$ARM_SUBSCRIPTION_ID" \
    ARM_TENANT_ID="$ARM_TENANT_ID" \
    APIM_NAME="$APIM_NAME" \
    APIM_RESOURCE_GROUP="$APIM_RG" \
    NEWRELIC_MCP_APP_ID="$NEWRELIC_MCP_APP_ID" \
  --authorize true

GROUP_ID=$(az pipelines variable-group list \
  --org "$ORG_URL" \
  --project "$PROJECT" \
  --query "[?name=='$GROUP_NAME'].id | [0]" -o tsv)

echo "✅ Variable group created (ID: $GROUP_ID)"
echo ""

# Add secret variables (must be done separately)
echo "Adding secret variables..."

az pipelines variable-group variable create \
  --group-id "$GROUP_ID" \
  --name ARM_CLIENT_SECRET \
  --value "$ARM_CLIENT_SECRET" \
  --secret true \
  --org "$ORG_URL" \
  --project "$PROJECT"

az pipelines variable-group variable create \
  --group-id "$GROUP_ID" \
  --name NEWRELIC_API_KEY \
  --value "$NEWRELIC_API_KEY" \
  --secret true \
  --org "$ORG_URL" \
  --project "$PROJECT"

echo "✅ Secret variables added"
echo ""
echo "=================================================="
echo "✅ Variable Group Setup Complete"
echo "=================================================="
echo ""
echo "Variable Group: $GROUP_NAME (ID: $GROUP_ID)"
echo "Next steps:"
echo "  1. Create pipeline in ADO pointing to .ado/pipelines/deploy.yml"
echo "  2. Link variable group to pipeline (done automatically with --authorize)"
echo "  3. Run pipeline with environment=dev and action=plan"
echo ""
