# Create ADO Variable Group for New Relic MCP APIM deployment
# Prerequisites: az devops extension installed, az login completed

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "New Relic MCP APIM - Variable Group Setup" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Configuration
$OrgUrl = "https://dev.azure.com/amnhealthcare"
$Project = "CloudOps"
$GroupName = "newrelic-mcp-apim-vars"

# Check if logged in
try {
    az devops project show --project $Project --org $OrgUrl | Out-Null
    Write-Host "✅ Connected to ADO: $OrgUrl/$Project" -ForegroundColor Green
} catch {
    Write-Host "❌ Not logged in to Azure DevOps. Run: az login" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Prompt for values
$ArmClientId = Read-Host "Enter ARM_CLIENT_ID (Service Principal App ID)"
$ArmClientSecret = Read-Host "Enter ARM_CLIENT_SECRET (Service Principal Secret)" -AsSecureString
$ArmClientSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ArmClientSecret))
$ArmSubscriptionId = Read-Host "Enter ARM_SUBSCRIPTION_ID"
$ArmTenantId = "6232c2ec-fa42-4f27-92cd-787913fba489"

Write-Host ""
$TfStateRg = Read-Host "Enter TF_STATE_RESOURCE_GROUP (default: rg-cloudops-terraform-state)"
if ([string]::IsNullOrWhiteSpace($TfStateRg)) { $TfStateRg = "rg-cloudops-terraform-state" }

$TfStateSa = Read-Host "Enter TF_STATE_STORAGE_ACCOUNT (default: stcloudopstfstatedev)"
if ([string]::IsNullOrWhiteSpace($TfStateSa)) { $TfStateSa = "stcloudopstfstatedev" }

$TfStateContainer = Read-Host "Enter TF_STATE_CONTAINER (default: tfstate)"
if ([string]::IsNullOrWhiteSpace($TfStateContainer)) { $TfStateContainer = "tfstate" }

Write-Host ""
$ApimName = Read-Host "Enter APIM_NAME (default: apim-amnhealthcare-dev)"
if ([string]::IsNullOrWhiteSpace($ApimName)) { $ApimName = "apim-amnhealthcare-dev" }

$ApimRg = Read-Host "Enter APIM_RESOURCE_GROUP (default: rg-apim-dev)"
if ([string]::IsNullOrWhiteSpace($ApimRg)) { $ApimRg = "rg-apim-dev" }

Write-Host ""
Write-Host "Fetching Entra App Registration for 'New Relic MCP Reader'..." -ForegroundColor Yellow
$NewRelicMcpAppId = az ad app list --display-name "New Relic MCP Reader" --query "[0].appId" -o tsv

if ([string]::IsNullOrWhiteSpace($NewRelicMcpAppId)) {
    Write-Host "❌ App registration 'New Relic MCP Reader' not found" -ForegroundColor Red
    Write-Host "Creating now..." -ForegroundColor Yellow
    az ad app create `
        --display-name "New Relic MCP Reader" `
        --identifier-uris "api://newrelic-mcp-reader"

    $NewRelicMcpAppId = az ad app list --display-name "New Relic MCP Reader" --query "[0].appId" -o tsv
    Write-Host "✅ Created app registration: $NewRelicMcpAppId" -ForegroundColor Green
} else {
    Write-Host "✅ Found app registration: $NewRelicMcpAppId" -ForegroundColor Green
}

Write-Host ""
Write-Host "Fetching New Relic API key from Key Vault..." -ForegroundColor Yellow
$NewRelicApiKey = az keyvault secret show `
    --vault-name co-wus2-newrelic-kv-p01 `
    --name NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace `
    --query value -o tsv

if ([string]::IsNullOrWhiteSpace($NewRelicApiKey)) {
    Write-Host "❌ Failed to retrieve New Relic API key from Key Vault" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Retrieved New Relic API key ($($NewRelicApiKey.Substring(0,10))...)" -ForegroundColor Green
Write-Host ""

# Check if variable group exists
Write-Host "Checking if variable group exists..." -ForegroundColor Yellow
$GroupId = az pipelines variable-group list `
    --org $OrgUrl `
    --project $Project `
    --query "[?name=='$GroupName'].id | [0]" -o tsv

if (![string]::IsNullOrWhiteSpace($GroupId)) {
    Write-Host "⚠️  Variable group '$GroupName' already exists (ID: $GroupId)" -ForegroundColor Yellow
    $Recreate = Read-Host "Delete and recreate? (y/N)"
    if ($Recreate -match "^[Yy]$") {
        az pipelines variable-group delete `
            --id $GroupId `
            --org $OrgUrl `
            --project $Project `
            --yes
        Write-Host "✅ Deleted existing variable group" -ForegroundColor Green
    } else {
        Write-Host "Exiting. To update manually, use ADO portal." -ForegroundColor Yellow
        exit 0
    }
}

# Create variable group
Write-Host ""
Write-Host "Creating variable group: $GroupName" -ForegroundColor Yellow

az pipelines variable-group create `
    --name $GroupName `
    --org $OrgUrl `
    --project $Project `
    --variables `
        TF_STATE_RESOURCE_GROUP=$TfStateRg `
        TF_STATE_STORAGE_ACCOUNT=$TfStateSa `
        TF_STATE_CONTAINER=$TfStateContainer `
        ARM_CLIENT_ID=$ArmClientId `
        ARM_SUBSCRIPTION_ID=$ArmSubscriptionId `
        ARM_TENANT_ID=$ArmTenantId `
        APIM_NAME=$ApimName `
        APIM_RESOURCE_GROUP=$ApimRg `
        NEWRELIC_MCP_APP_ID=$NewRelicMcpAppId `
    --authorize true

$GroupId = az pipelines variable-group list `
    --org $OrgUrl `
    --project $Project `
    --query "[?name=='$GroupName'].id | [0]" -o tsv

Write-Host "✅ Variable group created (ID: $GroupId)" -ForegroundColor Green
Write-Host ""

# Add secret variables (must be done separately)
Write-Host "Adding secret variables..." -ForegroundColor Yellow

az pipelines variable-group variable create `
    --group-id $GroupId `
    --name ARM_CLIENT_SECRET `
    --value $ArmClientSecretPlain `
    --secret true `
    --org $OrgUrl `
    --project $Project

az pipelines variable-group variable create `
    --group-id $GroupId `
    --name NEWRELIC_API_KEY `
    --value $NewRelicApiKey `
    --secret true `
    --org $OrgUrl `
    --project $Project

Write-Host "✅ Secret variables added" -ForegroundColor Green
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "✅ Variable Group Setup Complete" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Variable Group: $GroupName (ID: $GroupId)" -ForegroundColor Cyan
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Create pipeline in ADO pointing to .ado/pipelines/deploy.yml"
Write-Host "  2. Link variable group to pipeline (done automatically with --authorize)"
Write-Host "  3. Run pipeline with environment=dev and action=plan"
Write-Host ""
