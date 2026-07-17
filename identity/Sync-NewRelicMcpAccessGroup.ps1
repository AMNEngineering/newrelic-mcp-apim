<#
.SYNOPSIS
One-time seed of the New Relic MCP access group with everyone currently in the
New Relic notification distribution lists.

.DESCRIPTION
There are no existing New Relic *security* groups — the ~36 NewRelic_* groups are
all mail-only distribution lists (per-subaccount alert lists). To realize "everyone
already in an NR group gets access," this script takes the union of the (transitive)
USER members of those DLs and adds them to the dedicated NR MCP access security
group (the one the APIM policy gates on).

IMPORTANT — this is a SNAPSHOT, not a live sync. It reflects DL membership at run
time; it does not auto-update when the DLs change later. Re-run to refresh.

.PARAMETER TargetGroupOid
Object ID of the NR MCP access security group (newrelic_user_group_oid).

.PARAMETER SourceFilter
OData filter selecting the source NR groups. Default matches the NewRelic_ DLs.

.PARAMETER WhatIf
Report what would be added without modifying membership.

.EXAMPLE
./Sync-NewRelicMcpAccessGroup.ps1 -TargetGroupOid <oid>
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$TargetGroupOid,
    [string]$SourceFilter = "startswith(displayName,'NewRelic_') or startswith(displayName,'NewRelic ') or displayName eq 'AMN -NewRelic'"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com/v1.0'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

# Paged GET helper.
function Get-GraphAll([string]$url) {
    $items = @()
    while ($url) {
        $page = az rest --method GET --url $url -o json 2>$null | ConvertFrom-Json
        if ($page.value) { $items += $page.value }
        $url = $page.'@odata.nextLink'
    }
    return $items
}

Info "Confirming target group $TargetGroupOid ..."
$targetName = az ad group show --group $TargetGroupOid --query displayName -o tsv 2>$null
if (-not $targetName) { throw "Target group $TargetGroupOid not found." }
Ok "Target: $targetName"

Info "Finding source NR groups..."
$srcUrl = "$graph/groups?`$filter=$([uri]::EscapeDataString($SourceFilter))&`$select=id,displayName&`$top=999"
$srcGroups = Get-GraphAll $srcUrl
Ok "Source NR groups: $($srcGroups.Count)"
if (-not $srcGroups.Count) { throw "No source groups matched the filter." }

# Union of transitive USER members across all source groups.
$userIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($g in $srcGroups) {
    $members = Get-GraphAll "$graph/groups/$($g.id)/transitiveMembers/microsoft.graph.user?`$select=id,userPrincipalName&`$top=999"
    foreach ($m in $members) { [void]$userIds.Add($m.id) }
    Info "  $($g.displayName): +$($members.Count) users (running unique total $($userIds.Count))"
}
Ok "Unique users across all NR DLs: $($userIds.Count)"

# Who is already in the target (skip those).
$current = [System.Collections.Generic.HashSet[string]]::new()
foreach ($m in (Get-GraphAll "$graph/groups/$TargetGroupOid/members/microsoft.graph.user?`$select=id&`$top=999")) { [void]$current.Add($m.id) }
$toAdd = $userIds | Where-Object { -not $current.Contains($_) }
Ok "Already in target: $($current.Count). To add: $($toAdd.Count)."

if (-not $toAdd) { Ok "Nothing to add — target already up to date."; return }
if (-not $PSCmdlet.ShouldProcess($targetName, "Add $($toAdd.Count) members")) {
    Write-Host "WhatIf: would add $($toAdd.Count) users to $targetName."; return
}

$added = 0; $failed = 0
foreach ($uid in $toAdd) {
    try {
        $tmp = New-TemporaryFile
        @{ '@odata.id' = "$graph/directoryObjects/$uid" } | ConvertTo-Json | Set-Content $tmp -Encoding utf8
        az rest --method POST --url "$graph/groups/$TargetGroupOid/members/`$ref" --headers "Content-Type=application/json" --body "@$tmp" 2>$null | Out-Null
        Remove-Item $tmp -Force
        $added++
    }
    catch { $failed++; Write-Host "  ! failed to add $uid" -ForegroundColor Yellow }
}
Write-Host ""
Ok "Done. Added $added, failed $failed. Target '$targetName' now reflects NR DL membership (snapshot)."
