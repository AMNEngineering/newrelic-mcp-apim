<#
.SYNOPSIS
Idempotently create (or find) the dedicated Entra app registration for the New
Relic MCP APIM gateway, and output its Application (client) ID.

.DESCRIPTION
The Terraform contract in this repo does NOT create identity — it only references
the app id (as the JWT audience the APIM policy validates, and a named value). So
this app registration is a PREREQUISITE that must exist before the pipeline runs.

Design (decided 2026-07-16):
  * ONE dedicated New Relic MCP app registration, used for ALL New Relic MCP
    actions — both read and write. New Relic does not distinguish read vs write at
    the token/User-key level, so the app registration does not either. Read/write
    is enforced at the marketplace + skill layer (only read is allowed unless write
    is explicitly requested; the write path is provisioned separately via Terraform
    in the pipeline, staged for CAB approval).
  * Single app role `MCP.Access.Developer` (matches the AMN MCP Developer Gateway
    role-naming convention). Grant it to the New Relic MCP AD group / users.
  * Identifier URI api://<appId>; the policy validates both that and the bare GUID.

Safe to re-run: if an app with the display name already exists it is reused, and
the identifier URI + app role are reconciled.

.PARAMETER DisplayName
App registration display name. Default 'AMN New Relic MCP'.

.PARAMETER CreateServicePrincipal
Also ensure an enterprise app (service principal) exists so the app role can be
assigned to users/groups. Default: $true.

.EXAMPLE
./New-NewRelicMcpAppReg.ps1
Creates/*finds the app and prints the Application (client) ID to paste into
infrastructure/environments/*.tfvars (newrelic_mcp_app_id).
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DisplayName = 'AMN New Relic MCP',
    [bool]$CreateServicePrincipal = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

$roleValue = 'MCP.Access.Developer'

# --- Find or create the app -------------------------------------------------
Info "Looking for existing app '$DisplayName'..."
$existing = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null

if ($existing) {
    $appId = $existing
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

# --- App role MCP.Access.Developer (create-or-keep) -------------------------
$currentRoles = az ad app show --id $appId --query "appRoles" -o json | ConvertFrom-Json
$hasRole = $currentRoles | Where-Object { $_.value -eq $roleValue }
if ($hasRole) {
    Ok "App role '$roleValue' already present."
}
else {
    Info "Adding app role '$roleValue'..."
    $roleId = (New-Guid).Guid
    $roles = @(@{
            allowedMemberTypes = @('User', 'Application')  # delegated (devs) + app-only (CI/SPN)
            description        = 'Access to the New Relic MCP gateway (read and write; read/write enforced at the skill layer).'
            displayName        = 'MCP Access (Developer)'
            id                 = $roleId
            isEnabled          = $true
            value              = $roleValue
        })
    # Merge with any pre-existing roles.
    foreach ($r in $currentRoles) { $roles += @{ allowedMemberTypes = $r.allowedMemberTypes; description = $r.description; displayName = $r.displayName; id = $r.id; isEnabled = $r.isEnabled; value = $r.value } }
    $tmp = New-TemporaryFile
    ($roles | ConvertTo-Json -Depth 6 -AsArray) | Set-Content -Path $tmp -Encoding utf8
    az ad app update --id $appId --app-roles "@$tmp" | Out-Null
    Remove-Item $tmp -Force
    Ok "App role '$roleValue' added."
}

# --- Service principal (so the role can be assigned) ------------------------
if ($CreateServicePrincipal) {
    $spExists = az ad sp show --id $appId --query id -o tsv 2>$null
    if (-not $spExists) {
        Info "Creating service principal (enterprise app)..."
        az ad sp create --id $appId | Out-Null
        Ok "Service principal created."
    }
    else { Ok "Service principal already exists." }
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " New Relic MCP app registration ready" -ForegroundColor Green
Write-Host "   Application (client) ID : $appId" -ForegroundColor Green
Write-Host "   Audience                : api://$appId" -ForegroundColor Green
Write-Host "   App role                : $roleValue" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Set newrelic_mcp_app_id = `"$appId`" in infrastructure/environments/*.tfvars"
Write-Host "  2. Assign the '$roleValue' app role to the New Relic MCP AD group / developers"
Write-Host "     (Enterprise apps -> AMN New Relic MCP -> Users and groups)."
