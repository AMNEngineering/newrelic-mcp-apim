#Requires -Version 7.0

<#
.SYNOPSIS
Create (or find) the dedicated Entra app registration for the New Relic MCP APIM
gateway + the AD security group that gates access, using AMN's canonical ADM
elevation pattern. Outputs the Application (client) ID and the group Object ID.

.DESCRIPTION
These are PREREQUISITES the Terraform contract references (JWT audience + the
required groups claim); it does not create them.

ADM ELEVATION (mandated pattern — plugins/amn-ops-identity/skills/adm-elevation):
scripts that perform ADM-required Graph writes MUST use the Microsoft Graph SDK
via setup/scripts/Connect-AdmGraph.ps1 — NEVER `az login` (that changes auth
globally and breaks Claude Code + other tools). Four stages:
  1. Elevate  — Connect-AdmGraph.ps1 (device-code sign-in as .adm; this is where
                you enter the Safeguard-checked-out password + complete OneLogin MFA)
  2. Run      — the Mg* writes below
  3. Deelevate— Disconnect-MgGraph in finally { }
  4. Verify   — re-read via the daily az CLI (guarded), throw on failure

Design: ONE dedicated app (JWT audience) for all NR MCP actions; access gated by
membership in ONE dedicated security group (groups claim), groupMembershipClaims=
ApplicationGroup with the group assigned to the app (overage-proof). Group
membership is managed independently — add members deliberately.

Gate: dry-run by default (prints the plan, no elevation). Pass -Execute to apply.

.PARAMETER Execute
Perform the elevation + writes. Without it, prints the plan and exits.

.PARAMETER ConnectAdmGraphPath
Path to setup/scripts/Connect-AdmGraph.ps1 (in the amn-ops-ai-plugin-marketplace
repo). Auto-resolved from -ConnectAdmGraphPath, then $env:AMN_MARKETPLACE_ROOT,
then a sibling marketplace checkout.

.PARAMETER SkipPrompt
Forwarded to Connect-AdmGraph (skip its one Y/N elevation confirmation).

.EXAMPLE
pwsh ./identity/New-NewRelicMcpAppReg.ps1            # dry-run (plan only)
pwsh ./identity/New-NewRelicMcpAppReg.ps1 -Execute   # elevate + create
#>
[CmdletBinding()]
param(
    [string]$DisplayName = 'AMN New Relic MCP',
    [string]$GroupName = 'AZ_JobRole_Observability_NewRelicMcp_User',
    [string]$TenantId = '6232c2ec-fa42-4f27-92cd-787913fba489',
    [string]$ConnectAdmGraphPath,
    [switch]$SkipPrompt,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

$scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All')

# --- Plan (always shown) ----------------------------------------------------
Write-Host ""
Write-Host "=== New Relic MCP identity plan ===" -ForegroundColor Cyan
Write-Host "  App registration : $DisplayName  (single-tenant; identifier URI api://<appId>)"
Write-Host "  groups claim     : ApplicationGroup (only the access group emits — overage-proof)"
Write-Host "  Access group     : $GroupName  (security group; membership gates access)"
Write-Host "  Group -> app      : appRoleAssignment (default access) so the group emits in the token"
Write-Host "  Tenant           : $TenantId"
Write-Host "  Elevation        : Connect-AdmGraph.ps1 (device-code sign-in as .adm) — Graph SDK, not az login"
Write-Host "  Graph scopes     : $($scopes -join ', ')"
Write-Host ""

if (-not $Execute) {
    Write-Host "DRY-RUN — nothing created. Re-run with -Execute to elevate (device code as your" -ForegroundColor Yellow
    Write-Host ".adm account) and create the above. Needs the Microsoft.Graph module installed." -ForegroundColor Yellow
    return
}

# --- Ensure the Microsoft Graph SDK modules are available -------------------
$needed = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications', 'Microsoft.Graph.Groups')
$missing = @($needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missing.Count -gt 0) {
    throw "Missing PowerShell module(s): $($missing -join ', '). Install with: Install-Module Microsoft.Graph -Scope CurrentUser -Force"
}

# --- Resolve the sanctioned Connect-AdmGraph helper -------------------------
$candidates = @()
if ($ConnectAdmGraphPath) { $candidates += $ConnectAdmGraphPath }
if ($env:AMN_MARKETPLACE_ROOT) { $candidates += (Join-Path $env:AMN_MARKETPLACE_ROOT 'setup' 'scripts' 'Connect-AdmGraph.ps1') }
$candidates += (Join-Path $PSScriptRoot '..' '..' 'amn-ops-ai-plugin-marketplace' 'setup' 'scripts' 'Connect-AdmGraph.ps1')
$connectAdmGraph = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $connectAdmGraph) {
    throw "Could not find Connect-AdmGraph.ps1 (it lives in amn-ops-ai-plugin-marketplace/setup/scripts/). Pass -ConnectAdmGraphPath <file> or set `$env:AMN_MARKETPLACE_ROOT to your marketplace checkout. Checked: $($candidates -join '; ')"
}

# --- Stage 1: ELEVATE -------------------------------------------------------
# Assign the helper's return to a var (do NOT pipe to Out-Null): piping runs the
# call in a pipeline, which makes stdout look redirected to MSAL and suppresses
# the interactive device-code prompt (it then just spins to a 120s timeout).
# First run may be slow (cold Graph module load + Zscaler TLS) — wait for the code.
$admCtx = & $connectAdmGraph -TenantId $TenantId -Scopes $scopes -SkipPrompt:$SkipPrompt

$appId = ''
$groupOid = ''
try {
    # --- Stage 2: RUN -------------------------------------------------------
    # App registration
    $existingApp = @(Get-MgApplication -Filter "displayName eq '$DisplayName'" -All)
    if ($existingApp.Count -gt 0) {
        $app = $existingApp[0]
        Ok "Found existing app: $($app.AppId)"
    }
    else {
        Info "Creating app '$DisplayName'..."
        $app = New-MgApplication -DisplayName $DisplayName -SignInAudience 'AzureADMyOrg'
        Ok "Created app: $($app.AppId)"
    }
    $appId = $app.AppId

    # Identifier URI + ApplicationGroup claims
    Info "Setting identifier URI api://$appId + groupMembershipClaims=ApplicationGroup..."
    Update-MgApplication -ApplicationId $app.Id -IdentifierUris @("api://$appId") -GroupMembershipClaims 'ApplicationGroup'
    Ok "App configured."

    # Service principal (enterprise app) — needed to assign the group
    $existingSp = @(Get-MgServicePrincipal -Filter "appId eq '$appId'" -All)
    if ($existingSp.Count -gt 0) { $spId = $existingSp[0].Id; Ok "Service principal exists: $spId" }
    else { $spId = (New-MgServicePrincipal -AppId $appId).Id; Ok "Service principal created: $spId" }

    # Access group (security group)
    $existingGrp = @(Get-MgGroup -Filter "displayName eq '$GroupName'" -All)
    if ($existingGrp.Count -gt 0) {
        $groupOid = $existingGrp[0].Id
        Ok "Found existing group: $groupOid"
    }
    else {
        $nick = ($GroupName -replace '[^a-zA-Z0-9]', '')
        Info "Creating SECURITY group '$GroupName'..."
        $groupOid = (New-MgGroup -DisplayName $GroupName -MailEnabled:$false -MailNickname $nick -SecurityEnabled -GroupTypes @()).Id
        Ok "Created group: $groupOid"
    }

    # Assign the group to the app (ApplicationGroup emits only app-assigned groups).
    # Default-access app role = all-zero GUID.
    $assigned = @(Get-MgGroupAppRoleAssignment -GroupId $groupOid | Where-Object { $_.ResourceId -eq $spId })
    if ($assigned.Count -gt 0) {
        Ok "Group already assigned to the app."
    }
    else {
        Info "Assigning group to the app..."
        New-MgGroupAppRoleAssignment -GroupId $groupOid -PrincipalId $groupOid -ResourceId $spId -AppRoleId '00000000-0000-0000-0000-000000000000' | Out-Null
        Ok "Group assigned — its OID will now appear in the groups claim."
    }
}
finally {
    # --- Stage 3: DEELEVATE -------------------------------------------------
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Ok "Deelevated (Graph session disconnected)."
}

# --- Stage 4: VERIFY-AS-DAILY-DRIVER ----------------------------------------
Write-Host ""
Write-Host "--- Verify (daily-driver read) ---" -ForegroundColor Cyan
$azUser = az account show --query "user.name" -o tsv --only-show-errors 2>$null
if (-not $azUser) { throw "Stage 4 needs a daily-driver az session. Run 'az login' as your daily account, then re-verify." }
if ($azUser -like '*.adm*') { throw "Stage 4 requires a daily-driver context but az CLI is '$azUser' (.adm). Run 'az logout' + 'az login' as daily." }

$appSeen = az ad app show --id $appId --query appId -o tsv --only-show-errors 2>$null
if ($appSeen -ne $appId) { throw "Stage 4 FAILED: app $appId not visible to daily-driver ($azUser)." }
Ok "App $appId visible to daily-driver."
if ($groupOid) {
    $grpSeen = az ad group show --group $groupOid --query id -o tsv --only-show-errors 2>$null
    if ($grpSeen -ne $groupOid) { throw "Stage 4 FAILED: group $groupOid not visible to daily-driver." }
    Ok "Group $groupOid visible to daily-driver."
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " New Relic MCP identity ready" -ForegroundColor Green
Write-Host "   Application (client) ID : $appId" -ForegroundColor Green
Write-Host "   Audience                : api://$appId" -ForegroundColor Green
Write-Host "   Access group OID         : $groupOid" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next — set in infrastructure/environments/*.tfvars:"
Write-Host "  newrelic_mcp_app_id     = `"$appId`""
Write-Host "  newrelic_user_group_oid = `"$groupOid`""
Write-Host ""
Write-Host "Then add members deliberately (managed independently — do NOT tie to other NR memberships):"
Write-Host "  Entra -> Groups -> $GroupName -> Members -> Add"
