#Requires -Version 7.0

<#
.SYNOPSIS
Perform the two privileged Azure-resource prerequisites for the New Relic MCP
gateway under ADM elevation: (1) grant APIM's managed identity read access to the
New Relic Key Vault, and (2) create the Terraform state container. Uses AMN's
canonical Connect-AdmAzure.ps1 (Az PowerShell SDK, device-code) — NOT `az login`.

.DESCRIPTION
Both are RBAC/resource writes your daily account isn't authorized for. Four-stage
ADM pattern (plugins/amn-ops-identity/skills/adm-elevation):
  1. Elevate  — Connect-AdmAzure.ps1 (device-code sign-in as .adm; enter the
                Safeguard-checked-out password + OneLogin MFA), isolated Az context.
  2. Run      — New-AzRoleAssignment (KV Secrets User -> APIM MI) + New-AzStorageContainer.
  3. Deelevate— Disconnect-AzAccount in finally.
  4. Verify   — re-read both via the daily az CLI (guarded), throw on failure.

Dry-run by default (prints the plan). Pass -Execute to apply. Idempotent.

Prereqs: Install-Module Az -Scope CurrentUser (Az.Accounts/Resources/Storage), and
your .adm must hold User Access Administrator (or Owner) on the KV + Storage Blob
Data Contributor (or Contributor) on the tfstate account. If a step 403s under
elevation, that role is what your .adm is missing.

.PARAMETER Execute
Apply. Without it, prints the plan and exits.

.PARAMETER ConnectAdmAzurePath
Path to setup/scripts/Connect-AdmAzure.ps1 (marketplace repo). Auto-resolved from
-ConnectAdmAzurePath, then $env:AMN_MARKETPLACE_ROOT, then a sibling checkout.

.PARAMETER SkipPrompt
Forwarded to Connect-AdmAzure (skip its Y/N elevation confirmation).
#>
[CmdletBinding()]
param(
    [string]$TenantId = '6232c2ec-fa42-4f27-92cd-787913fba489',
    [string]$SubscriptionId = '43c5a646-c00c-4c59-a332-df854c5dd08c',
    [string]$ConnectAdmAzurePath,
    [switch]$SkipPrompt,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

# --- Constants (all resolved) ------------------------------------------------
$apimMiObjectId = 'a92d1808-15a6-4c50-a1fa-a849730e6af1'   # amn-wus2-hub-apim-d02 system-assigned MI
$kvRgName = 'co-wus2-newreliceventforwarder-rg-s01'
$kvName = 'co-wus2-newrelic-kv-p01'
$kvScope = "/subscriptions/$SubscriptionId/resourceGroups/$kvRgName/providers/Microsoft.KeyVault/vaults/$kvName"
$kvRole = 'Key Vault Secrets User'
$storageAccount = 'amncowus2tfstatesad01'
$container = 'new-relic-mcp'

Write-Host ""
Write-Host "=== New Relic MCP — Azure resource prerequisites ===" -ForegroundColor Cyan
Write-Host "  1. Role assignment : '$kvRole' -> APIM MI ($apimMiObjectId)"
Write-Host "     on KV           : $kvName"
Write-Host "  2. State container : '$container' in $storageAccount"
Write-Host "  Subscription       : $SubscriptionId   Tenant: $TenantId"
Write-Host "  Elevation          : Connect-AdmAzure.ps1 (device-code as .adm) — Az SDK, not az login"
Write-Host ""

if (-not $Execute) {
    Write-Host "DRY-RUN — nothing changed. Re-run with -Execute to elevate + apply." -ForegroundColor Yellow
    return
}

# --- Az modules present? ----------------------------------------------------
$needed = @('Az.Accounts', 'Az.Resources', 'Az.Storage')
$missing = @($needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missing.Count -gt 0) { throw "Missing module(s): $($missing -join ', '). Install with: Install-Module Az -Scope CurrentUser -Force" }

# --- Resolve Connect-AdmAzure.ps1 -------------------------------------------
$candidates = @()
if ($ConnectAdmAzurePath) { $candidates += $ConnectAdmAzurePath }
if ($env:AMN_MARKETPLACE_ROOT) { $candidates += (Join-Path $env:AMN_MARKETPLACE_ROOT 'setup' 'scripts' 'Connect-AdmAzure.ps1') }
$candidates += (Join-Path $PSScriptRoot '..' '..' 'amn-ops-ai-plugin-marketplace' 'setup' 'scripts' 'Connect-AdmAzure.ps1')
$connectAdmAzure = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $connectAdmAzure) { throw "Could not find Connect-AdmAzure.ps1 (amn-ops-ai-plugin-marketplace/setup/scripts/). Pass -ConnectAdmAzurePath or set `$env:AMN_MARKETPLACE_ROOT. Checked: $($candidates -join '; ')" }

# --- Stage 1: ELEVATE (assign, do NOT pipe — piping suppresses the device code) ---
$admCtx = & $connectAdmAzure -TenantId $TenantId -SubscriptionId $SubscriptionId -SkipPrompt:$SkipPrompt

try {
    # --- Stage 2: RUN -------------------------------------------------------
    # (1) KV role assignment
    $existingRa = Get-AzRoleAssignment -ObjectId $apimMiObjectId -Scope $kvScope -RoleDefinitionName $kvRole -ErrorAction SilentlyContinue
    if ($existingRa) { Ok "Role assignment already present." }
    else {
        Info "Granting '$kvRole' to the APIM MI on $kvName..."
        New-AzRoleAssignment -ObjectId $apimMiObjectId -RoleDefinitionName $kvRole -Scope $kvScope -ObjectType ServicePrincipal | Out-Null
        Ok "Role assignment created."
    }

    # (2) State container
    $storeCtx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
    if (Get-AzStorageContainer -Name $container -Context $storeCtx -ErrorAction SilentlyContinue) {
        Ok "Container '$container' already exists."
    }
    else {
        Info "Creating container '$container' in $storageAccount..."
        New-AzStorageContainer -Name $container -Context $storeCtx -Permission Off | Out-Null
        Ok "Container created."
    }
}
finally {
    # --- Stage 3: DEELEVATE -------------------------------------------------
    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
    Ok "Deelevated (Az session disconnected)."
}

# --- Stage 4: VERIFY-AS-DAILY-DRIVER ----------------------------------------
Write-Host ""
Write-Host "--- Verify (daily-driver read) ---" -ForegroundColor Cyan
# Ensure the daily az verify trusts the Zscaler-intercepted TLS even if this shell
# session hasn't re-sourced ~/.zshrc yet (else the read SSL-fails -> false negative).
if (-not $env:REQUESTS_CA_BUNDLE) {
    $macBundle = Join-Path $HOME '.az-ca-bundle.pem'
    if (Test-Path $macBundle) { $env:REQUESTS_CA_BUNDLE = $macBundle }
}
$azUser = az account show --query "user.name" -o tsv --only-show-errors 2>$null
if (-not $azUser) { throw "Stage 4 needs a daily-driver az session. Run 'az login' as your daily account." }
if ($azUser -like '*.adm*') { throw "Stage 4 requires a daily-driver context but az CLI is '$azUser' (.adm). Run 'az logout' + 'az login' as daily." }

$raSeen = az role assignment list --assignee $apimMiObjectId --scope $kvScope --subscription $SubscriptionId --query "[?roleDefinitionName=='$kvRole'] | [0].principalId" -o tsv --only-show-errors 2>$null
if (-not $raSeen) { throw "Stage 4 FAILED: KV role assignment not visible to daily-driver." }
Ok "KV role assignment visible."

$cSeen = az storage container show --account-name $storageAccount --name $container --subscription $SubscriptionId --auth-mode login --query "name" -o tsv --only-show-errors 2>$null
if ($cSeen -ne $container) { throw "Stage 4 FAILED: container '$container' not visible to daily-driver." }
Ok "State container visible."

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " Azure prerequisites complete (KV grant + state container)." -ForegroundColor Green
Write-Host " Remaining: register the ADO pipeline (step 5), then run it." -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
