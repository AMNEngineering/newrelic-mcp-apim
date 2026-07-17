<#
.SYNOPSIS
Idempotently create (or find) the dedicated Entra app registration for the New
Relic MCP APIM gateway, and (optionally) the AD group that gates access. Outputs
the Application (client) ID and the group Object ID for the tfvars.

.DESCRIPTION
The Terraform contract in this repo does NOT create identity — it only references
the app id and group OID (the JWT audience + the required groups claim the APIM
policy validates). So these are PREREQUISITES that must exist before the pipeline
runs.

Design (decided 2026-07-16/17):
  * ONE dedicated New Relic MCP app registration, used for ALL New Relic MCP
    actions — both read and write. New Relic does not distinguish read vs write at
    the token/User-key level, so the app registration does not either. Read/write
    is enforced at the marketplace + skill layer (only read is allowed unless write
    is explicitly requested; the write path is provisioned separately via Terraform
    in the pipeline, staged for CAB approval).
  * Access is gated by MEMBERSHIP IN A DEDICATED AD GROUP (a groups-claim check in
    the APIM policy) — NOT an app role. The app emits the groups claim
    (groupMembershipClaims = SecurityGroup).

The app registration is created here; the AD group is created only if you pass
-GroupName (its name was still TBD at authoring time).

Safe to re-run: existing objects are reused and reconciled.

.PARAMETER DisplayName
App registration display name. Default 'AMN New Relic MCP'.

.PARAMETER GroupName
If provided, create/find this security group and print its Object ID for the
newrelic_user_group_oid tfvars value. If omitted, only the app is handled.

.PARAMETER CreateServicePrincipal
Also ensure an enterprise app (service principal) exists. Default: $true.

.EXAMPLE
./New-NewRelicMcpAppReg.ps1
Create/find the app; print its Application (client) ID.

.EXAMPLE
./New-NewRelicMcpAppReg.ps1 -GroupName 'AZ_JobRole_Observability_NewRelicMcp_User'
Also create/find the access group and print its Object ID.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DisplayName = 'AMN New Relic MCP',
    [string]$GroupName = '',
    [bool]$CreateServicePrincipal = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

# --- Find or create the app -------------------------------------------------
Info "Looking for existing app '$DisplayName'..."
$appId = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null

if ($appId) {
    Ok "Found existing app: $appId"
}
else {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Create Entra app registration")) { return }
    Info "Creating app '$DisplayName'..."
    $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv
    Ok "Created app: $appId"
}

# --- Identifier URI api://<appId> -------------------------------------------
Info "Ensuring identifier URI api://$appId ..."
az ad app update --id $appId --identifier-uris "api://$appId" | Out-Null
Ok "Identifier URI set."

# --- Emit the groups claim (so the policy's required groups claim is present) -
Info "Setting groupMembershipClaims = SecurityGroup ..."
az ad app update --id $appId --set groupMembershipClaims=SecurityGroup | Out-Null
Ok "groups claim enabled."

# --- Service principal ------------------------------------------------------
if ($CreateServicePrincipal) {
    $spExists = az ad sp show --id $appId --query id -o tsv 2>$null
    if (-not $spExists) {
        Info "Creating service principal (enterprise app)..."
        az ad sp create --id $appId | Out-Null
        Ok "Service principal created."
    }
    else { Ok "Service principal already exists." }
}

# --- Optional: the access group ---------------------------------------------
$groupOid = ''
if ($GroupName) {
    Info "Looking for security group '$GroupName'..."
    $groupOid = az ad group list --display-name $GroupName --query "[0].id" -o tsv 2>$null
    if ($groupOid) {
        Ok "Found existing group: $groupOid"
    }
    elseif ($PSCmdlet.ShouldProcess($GroupName, "Create security group")) {
        $nick = ($GroupName -replace '[^a-zA-Z0-9]', '')
        Info "Creating security group '$GroupName'..."
        $groupOid = az ad group create --display-name $GroupName --mail-nickname $nick --query id -o tsv
        Ok "Created group: $groupOid"
    }
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " New Relic MCP identity ready" -ForegroundColor Green
Write-Host "   Application (client) ID : $appId" -ForegroundColor Green
Write-Host "   Audience                : api://$appId" -ForegroundColor Green
if ($groupOid) { Write-Host "   Access group OID         : $groupOid" -ForegroundColor Green }
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next — set in infrastructure/environments/*.tfvars:"
Write-Host "  newrelic_mcp_app_id     = `"$appId`""
if ($groupOid) {
    Write-Host "  newrelic_user_group_oid = `"$groupOid`""
    Write-Host "Then add developers to the '$GroupName' group."
}
else {
    Write-Host "  newrelic_user_group_oid = `"<create the access group, then its Object ID>`""
    Write-Host "Re-run with -GroupName '<name>' once the group name is decided to create it."
}
