# ADO Pipeline Setup Guide

This guide walks through setting up the Azure DevOps pipeline for deploying the New Relic MCP APIM proxy.

## Prerequisites

- Access to Azure DevOps CloudOps project
- Azure subscription access (Dev/QA/Prod)
- Access to Key Vault: `co-wus2-newrelic-kv-p01`
- Permissions to create Entra app registrations

## Step 1: Create Entra App Registration

Create the app registration that developers will authenticate against:

```bash
# Create app registration
az ad app create \
  --display-name "New Relic MCP Reader" \
  --identifier-uris "api://newrelic-mcp-reader"

# Get the app ID (save this for variable group)
APP_ID=$(az ad app list --display-name "New Relic MCP Reader" --query "[0].appId" -o tsv)
echo "App ID: $APP_ID"
```

**Important:** No additional permissions or API access needed. The app is only used for audience validation in APIM.

## Step 2: Get New Relic API Key

Retrieve the API key from Key Vault:

```bash
# Get New Relic API key
NR_API_KEY=$(az keyvault secret show \
  --vault-name co-wus2-newrelic-kv-p01 \
  --name NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace \
  --query value -o tsv)
echo "NR API Key: ${NR_API_KEY:0:10}..." # Show first 10 chars only
```

## Step 3: Create Service Principal for Terraform

If you don't already have a service principal for CloudOps automation:

```bash
# Create service principal
az ad sp create-for-rbac \
  --name "sp-cloudops-newrelic-mcp-terraform" \
  --role Contributor \
  --scopes /subscriptions/<subscription-id>

# Output will show:
# {
#   "appId": "...",        # This is ARM_CLIENT_ID
#   "password": "...",     # This is ARM_CLIENT_SECRET
#   "tenant": "..."        # This is ARM_TENANT_ID
# }
```

**Note:** If using existing CloudOps service principal, skip this step and use existing credentials.

## Step 4: Create Variable Group in ADO

Go to Azure DevOps → CloudOps Project → Pipelines → Library → Variable Groups

1. Click **+ Variable group**
2. Name: `newrelic-mcp-apim-vars`
3. Add the following variables:

### Terraform Backend Variables

| Variable Name | Value | Secret? | Description |
|---------------|-------|---------|-------------|
| `TF_STATE_RESOURCE_GROUP` | `rg-cloudops-terraform-state` | No | Terraform state storage RG |
| `TF_STATE_STORAGE_ACCOUNT` | `stcloudopstfstatedev` | No | Terraform state storage account |
| `TF_STATE_CONTAINER` | `tfstate` | No | Terraform state container name |

### Azure Authentication Variables

| Variable Name | Value | Secret? | Description |
|---------------|-------|---------|-------------|
| `ARM_CLIENT_ID` | `<service-principal-app-id>` | No | Service principal application ID |
| `ARM_CLIENT_SECRET` | `<service-principal-secret>` | ✅ **Yes** | Service principal password |
| `ARM_SUBSCRIPTION_ID` | `<target-subscription-id>` | No | Target Azure subscription |
| `ARM_TENANT_ID` | `6232c2ec-fa42-4f27-92cd-787913fba489` | No | AMN Healthcare tenant ID |

### Environment-Specific Variables (DEV)

| Variable Name | Value | Secret? | Description |
|---------------|-------|---------|-------------|
| `APIM_NAME` | `apim-amnhealthcare-dev` | No | APIM instance name |
| `APIM_RESOURCE_GROUP` | `rg-apim-dev` | No | APIM resource group name |

### New Relic MCP Variables

| Variable Name | Value | Secret? | Description |
|---------------|-------|---------|-------------|
| `NEWRELIC_MCP_APP_ID` | `<app-id-from-step-1>` | No | Entra app registration ID |
| `NEWRELIC_API_KEY` | `NRAK-...` | ✅ **Yes** | New Relic API key from Key Vault |

4. Click **Save**

### For Multiple Environments

For QA/Staging/Prod, create additional variable groups:
- `newrelic-mcp-apim-vars-qa`
- `newrelic-mcp-apim-vars-staging`
- `newrelic-mcp-apim-vars-prod`

Update `APIM_NAME` and `APIM_RESOURCE_GROUP` for each environment.

## Step 5: Create Azure Service Connection

If the service connection `Azure-MCP-ServiceConnection` doesn't exist:

1. Go to Project Settings → Service connections
2. Click **New service connection**
3. Select **Azure Resource Manager**
4. Authentication method: **Service principal (manual)**
5. Fill in:
   - Subscription ID: `<target-subscription-id>`
   - Subscription Name: `AMN Intelligent Platform Services Dev` (or appropriate)
   - Service Principal ID: `<ARM_CLIENT_ID>`
   - Service principal key: `<ARM_CLIENT_SECRET>`
   - Tenant ID: `6232c2ec-fa42-4f27-92cd-787913fba489`
6. Service connection name: `Azure-MCP-ServiceConnection`
7. Click **Verify and save**

## Step 6: Create ADO Pipeline

1. Go to Pipelines → New Pipeline
2. Select **GitHub**
3. Select repository: `AMNEngineering/newrelic-mcp-apim`
4. Select **Existing Azure Pipelines YAML file**
5. Path: `.ado/pipelines/deploy.yml`
6. Click **Continue**
7. **Do not run yet** - click the dropdown next to Run and select **Save**

## Step 7: First Deployment (DEV)

### Plan First

1. Run pipeline with parameters:
   - Environment: `dev`
   - Action: `plan`
2. Review Terraform plan output
3. Verify resources to be created:
   - APIM Backend (backend-newrelic-mcp-dev)
   - APIM Named Values (nv-newrelic-mcp-api-key, newrelic-mcp-app-id)
   - APIM API (api-newrelic-mcp-dev)
   - APIM Operation (mcp-all)

### Apply Deployment

If plan looks good:

1. Run pipeline with parameters:
   - Environment: `dev`
   - Action: `apply`
2. Pipeline will:
   - Apply Terraform changes
   - Apply APIM policy
   - Test endpoint
   - Output endpoint URL

### Verify Deployment

Check pipeline output for:
```
✅ APIM policy applied successfully
✅ MCP endpoint test passed

APIM Endpoint: https://api.amnhealthcare.io/mcp/newrelic/dev/mcp/
```

Test manually:
```bash
# Get token
TOKEN=$(az account get-access-token --resource api://newrelic-mcp-reader --query accessToken -o tsv)

# Test endpoint
curl -X POST "https://api.amnhealthcare.io/mcp/newrelic/dev/mcp/" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"capabilities/list","id":1}'
```

Should return MCP capabilities list.

## Step 8: Deploy to Other Environments

For QA/Staging/Prod:

1. Update variable group or create environment-specific groups
2. Update `APIM_NAME` and `APIM_RESOURCE_GROUP` values
3. Run pipeline with appropriate environment parameter
4. Follow same plan → apply flow

## Rollback

If deployment fails or needs rollback:

```bash
# Run pipeline with:
# - Environment: <env>
# - Action: destroy

# This will remove APIM resources
# Then re-deploy with action: apply
```

**Warning:** Destroy will remove the APIM API and policy. Only use for complete teardown.

## Monitoring

After deployment, monitor:

1. **APIM Analytics:** Check request logs, status codes, user identity
2. **New Relic:** Query APIM logs:
   ```nrql
   SELECT * FROM Log
   WHERE requestUrl LIKE '%mcp/newrelic%'
   SINCE 1 hour ago
   ```
3. **Rate Limiting:** Watch for 429 responses in APIM Analytics

## Troubleshooting

### "401 Unauthorized" during pipeline test

**Cause:** Service connection or app registration issue

**Fix:**
- Verify `NEWRELIC_MCP_APP_ID` is correct
- Check service connection credentials
- Ensure app registration exists in Entra

### "403 Forbidden" during Terraform

**Cause:** Service principal lacks permissions

**Fix:**
- Grant Contributor role on APIM resource group
- Grant Key Vault Secret User on Key Vault (if reading from KV)

### "Named value already exists"

**Cause:** Previous deployment exists

**Fix:**
- Run `destroy` action first
- Or remove conflicting named values manually in APIM portal

### Pipeline can't find variable group

**Cause:** Variable group not linked to pipeline

**Fix:**
- Edit pipeline → Variables → Variable groups
- Click "Link variable group" and select `newrelic-mcp-apim-vars`
- Save and re-run

## Support

- **Slack:** #cloudops-ai-platform
- **Issues:** Contact CloudOps team
- **Repository:** https://github.com/AMNEngineering/newrelic-mcp-apim
