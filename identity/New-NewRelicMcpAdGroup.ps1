#Requires -Version 5.1

<#
.SYNOPSIS
Create the New Relic MCP access job-role group in ON-PREM Active Directory, in the
same OU as the other AZ_JobRole_* groups. Run by the service desk / an AD admin on a
Windows host with the ActiveDirectory module (RSAT) and line-of-sight to a DC.

.DESCRIPTION
AZ_JobRole_* groups are on-prem AD objects that sync to Entra via Entra Connect
(~30 min). They cannot be created in Entra/Graph — they must be created here, in AD.
This script:
  1. Auto-discovers the OU + group scope from an existing AZ_JobRole_* group (so the
     new group lands in the same place, same shape) — override with -OUPath / -GroupScope.
  2. Creates AZ_JobRole_Observability_NewRelicMcp_User as a security group there
     (idempotent — skips if it already exists).
  3. Optionally adds members (-Members). Membership is managed here in AD, ongoing,
     by the service desk — it is intentionally NOT tied to any other New Relic group.

After it syncs to Entra, assign the group to the app + set newrelic_user_group_oid
(see docs/PREFLIGHT-RUNBOOK.md step 1b).

.PARAMETER Members
Optional samAccountNames or UPNs to add to the group.

.PARAMETER OUPath
Override the target OU distinguished name. Default: auto-discovered from -TemplateGroup.

.PARAMETER TemplateGroup
Existing AZ_JobRole_* group to copy the OU + scope from. Default AZ_JobRole_ClaudeCode_Azure_User.

.PARAMETER Credential
Optional on-prem admin credential (e.g. AHS\casey.allard.adm). Omit to use the
current logged-on session.

.EXAMPLE
.\New-NewRelicMcpAdGroup.ps1 -WhatIf          # preview (OU + what would be created)
.\New-NewRelicMcpAdGroup.ps1                  # create it
.\New-NewRelicMcpAdGroup.ps1 -Members jdoe,asmith   # create + add members
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GroupName = 'AZ_JobRole_Observability_NewRelicMcp_User',
    [string]$Description = 'Access to the New Relic MCP gateway (APIM). Membership grants MCP access (read + write; enforced at the skill layer). Managed independently — not tied to other New Relic groups.',
    [string]$OUPath,
    [string]$GroupScope,
    [string]$TemplateGroup = 'AZ_JobRole_ClaudeCode_Azure_User',
    [string[]]$Members,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

$common = @{}
if ($Credential) { $common['Credential'] = $Credential }

# --- Discover OU + scope from an existing AZ_JobRole_* group ----------------
if (-not $OUPath -or -not $GroupScope) {
    Write-Host "Discovering OU/scope from template group '$TemplateGroup'..." -ForegroundColor Cyan
    $tmpl = Get-ADGroup -Identity $TemplateGroup -Properties DistinguishedName, GroupScope @common -ErrorAction SilentlyContinue
    if (-not $tmpl) {
        $tmpl = Get-ADGroup -Filter "Name -like 'AZ_JobRole_*'" -Properties DistinguishedName, GroupScope @common | Select-Object -First 1
    }
    if (-not $tmpl) { throw "No AZ_JobRole_* template group found to derive the OU; pass -OUPath and -GroupScope explicitly." }
    if (-not $OUPath) { $OUPath = ($tmpl.DistinguishedName -replace '^CN=[^,]+,', '') }
    if (-not $GroupScope) { $GroupScope = [string]$tmpl.GroupScope }
    Write-Host "  Template : $($tmpl.DistinguishedName)" -ForegroundColor Gray
}
if (-not $GroupScope) { $GroupScope = 'Universal' }

Write-Host ""
Write-Host "Plan:" -ForegroundColor Cyan
Write-Host "  Group : $GroupName  (Security, $GroupScope)"
Write-Host "  OU    : $OUPath"
Write-Host ""

# --- Idempotent create ------------------------------------------------------
$existing = Get-ADGroup -Filter "Name -eq '$GroupName'" @common -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Group already exists: $($existing.DistinguishedName)" -ForegroundColor Green
    $grp = $existing
}
elseif ($PSCmdlet.ShouldProcess($GroupName, "Create AD security group in $OUPath")) {
    $grp = New-ADGroup -Name $GroupName -SamAccountName $GroupName -GroupCategory Security `
        -GroupScope $GroupScope -Path $OUPath -Description $Description -PassThru @common
    Write-Host "Created: $($grp.DistinguishedName)" -ForegroundColor Green
}
else {
    return
}

# --- Optional members -------------------------------------------------------
if ($Members) {
    foreach ($m in $Members) {
        if ($PSCmdlet.ShouldProcess($m, "Add to $GroupName")) {
            Add-ADGroupMember -Identity $GroupName -Members $m @common
            Write-Host "  + $m" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " AD group ready: $GroupName" -ForegroundColor Green
Write-Host "   DN         : $($grp.DistinguishedName)"
Write-Host "   ObjectGUID : $($grp.ObjectGUID)"
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next: it syncs to Entra via Entra Connect (~30 min). Then assign it to the"
Write-Host "New Relic MCP app + capture its Entra group OID (docs/PREFLIGHT-RUNBOOK.md step 1b)."
Write-Host "Service desk manages membership here in AD (Add-ADGroupMember or ADUC)."
