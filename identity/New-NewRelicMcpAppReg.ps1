<#
.SYNOPSIS
Idempotently create (or find) the dedicated Entra app registration for the New
Relic MCP APIM gateway, plus the AD security group that gates access, and wire
them together. Outputs the Application (client) ID and the group Object ID.

.DESCRIPTION
The Terraform contract in this repo does NOT create identity — it only references
the app id and group OID (the JWT audience + the required groups claim the APIM
policy validates). So these are PREREQUISITES that must exist before the pipeline.

ADM ELEVATION: registering an app + creating a group needs elevated Entra roles
(Application Administrator/Developer + Groups Administrator). This script briefly
signs in your `<you>.adm` admin account into an ISOLATED az config dir (a temp
AZURE_CONFIG_DIR), runs the privileged Graph commands there, then discards that
session. Your daily `az` login (`~/.azure`) — subscription and all — is never
touched, so there is nothing to "move back".

Design (decided 2026-07-16/17):
  * ONE dedicated New Relic MCP app registration = the JWT audience, for ALL NR
    MCP actions (read AND write). Access is gated by membership in ONE dedicated
    AD security group (groups-claim check) — not an app role.
  * groupMembershipClaims = ApplicationGroup, group assigned to the app, so only
    that group emits in the token (overage-proof).
  * Group membership is managed INDEPENDENTLY (add members deliberately) — NOT
    tied to any other New Relic membership.

Safe to re-run: existing objects are reused and reconciled.

.PARAMETER DisplayName
App registration display name. Default 'AMN New Relic MCP'.

.PARAMETER GroupName
Access security group display name. Default 'AZ_JobRole_Observability_NewRelicMcp_User'.

.PARAMETER AdminUpn
Admin account to elevate as. Default: derived from your daily az login by inserting
`.adm` (casey.allard@... -> casey.allard.adm@...).

.PARAMETER TenantId
AMN tenant. Default 6232c2ec-fa42-4f27-92cd-787913fba489.

.PARAMETER UseDeviceCode
Use device-code login instead of the browser (for headless/SSH sessions).

.PARAMETER CreateServicePrincipal
Ensure an enterprise app (service principal) exists. Default: $true.

.EXAMPLE
pwsh ./New-NewRelicMcpAppReg.ps1
Elevates to <you>.adm in a browser, creates the app + group, prints the ids.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DisplayName = 'AMN New Relic MCP',
    [string]$GroupName = 'AZ_JobRole_Observability_NewRelicMcp_User',
    [string]$AdminUpn = '',
    [string]$TenantId = '6232c2ec-fa42-4f27-92cd-787913fba489',
    [switch]$UseDeviceCode,
    [bool]$CreateServicePrincipal = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Make failed `az` calls (non-zero exit) terminate instead of barreling on. PS 7.3+.
$PSNativeCommandUseErrorActionPreference = $true
$graph = 'https://graph.microsoft.com/v1.0'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

$rolesHint = @'
This needs Entra directory roles the elevated account must hold:
  - Application Administrator (or Application Developer) — to register the app
  - Groups Administrator — to create the security group
Activate them via PIM for the .adm account, then re-run. Nothing was created.
'@
function Fail-Privileged($m) { Write-Host $rolesHint -ForegroundColor Yellow; throw $m }

# --- Derive the admin UPN from the DAILY az context (before elevating) -------
$dailyUpn = az account show --query user.name -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($dailyUpn)) {
    throw "No daily az session found. Run 'az login' as your normal account first, then re-run."
}
if (-not $AdminUpn) {
    if ($dailyUpn -notmatch '^(?<local>[^@]+)@(?<domain>.+)$') { throw "Could not parse daily UPN '$dailyUpn'." }
    $AdminUpn = '{0}.adm@{1}' -f $Matches.local.ToLower(), $Matches.domain
}

# --- ELEVATE into an isolated az config dir ----------------------------------
$admDir = Join-Path ([IO.Path]::GetTempPath()) ('az-adm-nrmcp-' + (New-Guid).Guid)
$prevConfigDir = [Environment]::GetEnvironmentVariable('AZURE_CONFIG_DIR')
$appId = ''
$groupOid = ''

try {
    $env:AZURE_CONFIG_DIR = $admDir
    Write-Host ""
    Write-Host "Elevating to $AdminUpn — isolated session; your daily az CLI (subscription and all) is untouched." -ForegroundColor Yellow
    if ($UseDeviceCode) {
        Write-Host "Follow the device-code prompt and sign in as $AdminUpn." -ForegroundColor Yellow
        az login --tenant $TenantId --allow-no-subscriptions --use-device-code --only-show-errors | Out-Null
    }
    else {
        Write-Host "A browser will open — sign in as $AdminUpn." -ForegroundColor Yellow
        az login --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null
    }

    $who = az account show --query user.name -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($who)) { throw "Elevated login did not complete." }
    if ($who -notlike '*.adm@*') {
        throw "Signed in as '$who', which is not an .adm admin account. Aborting (nothing created) — re-run and pick $AdminUpn."
    }
    Ok "Elevated as $who."

    # --- Find or create the app ---------------------------------------------
    Info "Looking for existing app '$DisplayName'..."
    $appId = az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null
    if ($appId) {
        Ok "Found existing app: $appId"
    }
    else {
        if (-not $PSCmdlet.ShouldProcess($DisplayName, "Create Entra app registration")) { return }
        Info "Creating app '$DisplayName'..."
        try { $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv }
        catch { Fail-Privileged "Could not register the app '$DisplayName'. $_" }
        if ([string]::IsNullOrWhiteSpace($appId)) { Fail-Privileged "App registration returned no appId (insufficient privileges)." }
        Ok "Created app: $appId"
    }

    # --- Identifier URI api://<appId> ---------------------------------------
    Info "Ensuring identifier URI api://$appId ..."
    az ad app update --id $appId --identifier-uris "api://$appId" | Out-Null
    Ok "Identifier URI set."

    # --- Emit ONLY app-assigned groups in the groups claim (overage-proof) --
    Info "Setting groupMembershipClaims = ApplicationGroup ..."
    az ad app update --id $appId --set groupMembershipClaims=ApplicationGroup | Out-Null
    Ok "groups claim mode = ApplicationGroup."

    # --- Service principal (required for group assignment) ------------------
    if ($CreateServicePrincipal) {
        $spId = az ad sp show --id $appId --query id -o tsv 2>$null
        if (-not $spId) {
            Info "Creating service principal (enterprise app)..."
            $spId = az ad sp create --id $appId --query id -o tsv
            Ok "Service principal created: $spId"
        }
        else { Ok "Service principal exists: $spId" }
    }

    # --- Access group: create/find + assign to the app ----------------------
    if ($GroupName) {
        Info "Looking for security group '$GroupName'..."
        $groupOid = az ad group list --display-name $GroupName --query "[0].id" -o tsv 2>$null
        if ($groupOid) {
            Ok "Found existing group: $groupOid"
        }
        elseif ($PSCmdlet.ShouldProcess($GroupName, "Create security group")) {
            $nick = ($GroupName -replace '[^a-zA-Z0-9]', '')
            Info "Creating SECURITY group '$GroupName'..."
            try { $groupOid = az ad group create --display-name $GroupName --mail-nickname $nick --query id -o tsv }
            catch { Fail-Privileged "Could not create the security group '$GroupName' (need Groups Administrator). $_" }
            if ([string]::IsNullOrWhiteSpace($groupOid)) { Fail-Privileged "Group creation returned no OID (insufficient privileges)." }
            Ok "Created group: $groupOid"
        }

        if ($groupOid -and $CreateServicePrincipal -and $PSCmdlet.ShouldProcess($GroupName, "Assign group to the app (ApplicationGroup)")) {
            $existing = az rest --method GET --url "$graph/groups/$groupOid/appRoleAssignments" --query "value[?resourceId=='$spId'] | [0].id" -o tsv 2>$null
            if ($existing) {
                Ok "Group already assigned to the app."
            }
            else {
                Info "Assigning group to the app..."
                $tmp = New-TemporaryFile
                @{ principalId = $groupOid; resourceId = $spId; appRoleId = '00000000-0000-0000-0000-000000000000' } | ConvertTo-Json | Set-Content $tmp -Encoding utf8
                az rest --method POST --url "$graph/groups/$groupOid/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
                Remove-Item $tmp -Force
                Ok "Group assigned — its OID will now appear in the groups claim."
            }
        }
    }
}
finally {
    # --- DE-ELEVATE: discard the isolated admin session; restore daily context.
    Info "De-elevating (discarding the isolated admin session)..."
    az logout --only-show-errors 2>$null | Out-Null
    if ($null -ne $prevConfigDir) { $env:AZURE_CONFIG_DIR = $prevConfigDir }
    else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    Remove-Item $admDir -Recurse -Force -ErrorAction SilentlyContinue
    Ok "De-elevated. Your daily az CLI session is unchanged."
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
    Write-Host ""
    Write-Host "Then add members deliberately (this group is managed independently — do NOT"
    Write-Host "tie it to other New Relic memberships):"
    Write-Host "  Entra -> Groups -> $GroupName -> Members -> Add, or"
    Write-Host "  az ad group member add --group $groupOid --member-id <userObjectId>"
}
