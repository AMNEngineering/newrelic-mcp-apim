<#
.SYNOPSIS
Idempotently create (or find) the dedicated Entra app registration for the New
Relic MCP APIM gateway, plus the AD security group that gates access, and wire
them together. Outputs the Application (client) ID and the group Object ID.

.DESCRIPTION
The Terraform contract in this repo does NOT create identity — it only references
the app id and group OID (the JWT audience + the required groups claim the APIM
policy validates). So these are PREREQUISITES that must exist before the pipeline.

Design (decided 2026-07-16/17):
  * ONE dedicated New Relic MCP app registration = the JWT audience. Used for ALL
    New Relic MCP actions (read AND write); New Relic does not distinguish them at
    the token level, so neither does the app. Read/write is enforced at the
    marketplace + skill layer.
  * Access is gated by MEMBERSHIP IN ONE dedicated AD SECURITY group (groups-claim
    check in the policy) — NOT an app role.
  * groupMembershipClaims = ApplicationGroup, and the access group is assigned to
    the app, so ONLY that group emits in the token. This is overage-proof: it works
    no matter how many groups a user belongs to (SecurityGroup mode would drop the
    claim past ~200 groups).

Seed the new group's membership with Sync-NewRelicMcpAccessGroup.ps1 (one-time
import of everyone currently in the NewRelic_*_Notification-DL lists).

Safe to re-run: existing objects are reused and reconciled.

.PARAMETER DisplayName
App registration display name. Default 'AMN New Relic MCP'.

.PARAMETER GroupName
Access security group display name (name was TBD at authoring time). When provided,
the group is created/found, made assignable, and assigned to the app.

.PARAMETER CreateServicePrincipal
Ensure an enterprise app (service principal) exists. Default: $true (required for
the ApplicationGroup assignment).

.EXAMPLE
./New-NewRelicMcpAppReg.ps1 -GroupName 'AZ_JobRole_Observability_NewRelicMcp_User'
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
$graph = 'https://graph.microsoft.com/v1.0'
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

# --- Emit ONLY app-assigned groups in the groups claim (overage-proof) ------
Info "Setting groupMembershipClaims = ApplicationGroup ..."
az ad app update --id $appId --set groupMembershipClaims=ApplicationGroup | Out-Null
Ok "groups claim mode = ApplicationGroup."

# --- Service principal (required for group assignment) ----------------------
$spId = az ad sp show --id $appId --query id -o tsv 2>$null
if (-not $spId) {
    Info "Creating service principal (enterprise app)..."
    $spId = az ad sp create --id $appId --query id -o tsv
    Ok "Service principal created: $spId"
}
else { Ok "Service principal exists: $spId" }

# --- Access group: create/find + assign to the app --------------------------
$groupOid = ''
if ($GroupName) {
    Info "Looking for security group '$GroupName'..."
    $groupOid = az ad group list --display-name $GroupName --query "[0].id" -o tsv 2>$null
    if ($groupOid) {
        Ok "Found existing group: $groupOid"
    }
    elseif ($PSCmdlet.ShouldProcess($GroupName, "Create security group")) {
        $nick = ($GroupName -replace '[^a-zA-Z0-9]', '')
        Info "Creating SECURITY group '$GroupName'..."
        $groupOid = az ad group create --display-name $GroupName --mail-nickname $nick --query id -o tsv
        Ok "Created group: $groupOid"
    }

    if ($groupOid -and $PSCmdlet.ShouldProcess($GroupName, "Assign group to the app (ApplicationGroup)")) {
        # ApplicationGroup only emits groups assigned to the app. Assign via an
        # appRoleAssignment with the default-access role (all-zero GUID).
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
    Write-Host "Then seed membership (one-time):"
    Write-Host "  ./Sync-NewRelicMcpAccessGroup.ps1 -TargetGroupOid $groupOid"
}
else {
    Write-Host "  newrelic_user_group_oid = `"<re-run with -GroupName '<name>'>`""
}
