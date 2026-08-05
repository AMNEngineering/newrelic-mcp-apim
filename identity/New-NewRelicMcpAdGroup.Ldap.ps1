#Requires -Version 7.0

<#
.SYNOPSIS
Create the New Relic MCP access job-role group in on-prem AD **over LDAP** — works
from macOS/Linux (no ActiveDirectory RSAT module needed), over the VPN to a DC.

.DESCRIPTION
AZ_JobRole_* groups are on-prem AD objects that sync to Entra (~30 min). The RSAT
ActiveDirectory module is Windows-only, but LDAP (System.DirectoryServices.Protocols)
is cross-platform. This script:
  1. LDAPS-binds to a DC as your on-prem .adm credential.
  2. Searches for an existing AZ_JobRole_* group to auto-derive the target OU + the
     exact groupType (so the new group lands in the same place, same shape).
  3. (with -Execute) creates AZ_JobRole_Observability_NewRelicMcp_User there, and
     optionally adds -Members.

Dry-run by default: binds + shows the OU/groupType it WOULD use (also validates your
connectivity + credential). Pass -Execute to actually create.

.PARAMETER Server
DC / domain to target. Default 'ahs.int' (DNS-resolves a DC over the VPN). If that
doesn't connect, pass a specific DC FQDN.

.PARAMETER SearchBase
Base DN to search/create under. Default derived from the domain ('ahs.int' -> 'DC=ahs,DC=int').

.PARAMETER Members
Optional samAccountNames to add (must be resolvable under SearchBase).

.PARAMETER Port
LDAP port. Default 636 (LDAPS — required for AD writes).

.PARAMETER SkipCertCheck
Skip DC certificate validation (use only if the DC's LDAPS cert chain isn't trusted
on this Mac; prefer trusting the corp CA).

.PARAMETER Execute
Actually create the group. Without it, read-only discovery/validation.

.EXAMPLE
pwsh ./identity/New-NewRelicMcpAdGroup.Ldap.ps1                 # validate + show OU
pwsh ./identity/New-NewRelicMcpAdGroup.Ldap.ps1 -Execute        # create it
#>
[CmdletBinding()]
param(
    [string]$GroupName = 'AZ_JobRole_Observability_NewRelicMcp_User',
    [string]$Description = 'Access to the New Relic MCP gateway (APIM). Managed independently; not tied to other New Relic groups.',
    [string]$Server = 'ahs.int',
    [string]$SearchBase,
    [string]$TemplateFilter = '(&(objectClass=group)(cn=AZ_JobRole_*))',
    [string[]]$Members,
    [int]$Port = 636,
    [switch]$SkipCertCheck,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.DirectoryServices.Protocols
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

if (-not $SearchBase) {
    $SearchBase = ($Server.Split('.') | ForEach-Object { "DC=$_" }) -join ','
}

Write-Host ""
Write-Host "New Relic MCP AD group (LDAP)" -ForegroundColor Cyan
Write-Host "  Server     : $Server`:$Port (LDAPS)"
Write-Host "  SearchBase : $SearchBase"
Write-Host "  Group      : $GroupName"
Write-Host ""

# --- Credential (your on-prem .adm — enter the Safeguard-checked-out password) ---
$cred = Get-Credential -Message "On-prem admin (e.g. AHS\casey.allard.adm or casey.allard.adm@ahs.int)"

# --- Bind (LDAPS) -----------------------------------------------------------
$identifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port)
$conn = [System.DirectoryServices.Protocols.LdapConnection]::new($identifier)
$conn.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
$conn.SessionOptions.ProtocolVersion = 3
$conn.SessionOptions.SecureSocketLayer = $true
if ($SkipCertCheck) {
    $conn.SessionOptions.VerifyServerCertificate = [System.DirectoryServices.Protocols.VerifyServerCertificateCallback] { param($c, $cert) $true }
}
$conn.Credential = $cred.GetNetworkCredential()
Info "Binding to $Server ..."
$conn.Bind()
Ok "Bound as $($cred.UserName)."

# --- Discover OU + groupType from an existing AZ_JobRole_* group ------------
Info "Finding a template AZ_JobRole_* group to copy OU + groupType..."
$search = [System.DirectoryServices.Protocols.SearchRequest]::new(
    $SearchBase, $TemplateFilter,
    [System.DirectoryServices.Protocols.SearchScope]::Subtree,
    @('distinguishedName', 'groupType'))
$resp = [System.DirectoryServices.Protocols.SearchResponse]$conn.SendRequest($search)
if ($resp.Entries.Count -eq 0) { throw "No AZ_JobRole_* group found under $SearchBase to derive the OU. Pass -SearchBase to the correct container." }
$tmplDn = $resp.Entries[0].DistinguishedName
$groupType = [string]$resp.Entries[0].Attributes['groupType'][0]
$ou = ($tmplDn -replace '^CN=[^,]+,', '')
Ok "Template: $tmplDn"
Write-Host "  OU        : $ou"
Write-Host "  groupType : $groupType"

$newDn = "CN=$GroupName,$ou"

# --- Already exists? --------------------------------------------------------
$exists = [System.DirectoryServices.Protocols.SearchRequest]::new($SearchBase, "(&(objectClass=group)(cn=$GroupName))", 'Subtree', @('distinguishedName'))
$existsResp = [System.DirectoryServices.Protocols.SearchResponse]$conn.SendRequest($exists)
if ($existsResp.Entries.Count -gt 0) {
    Ok "Group already exists: $($existsResp.Entries[0].DistinguishedName)"
    $conn.Dispose(); return
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "DRY-RUN — bind + discovery OK. Would create:" -ForegroundColor Yellow
    Write-Host "  $newDn  (Security, groupType $groupType)" -ForegroundColor Yellow
    Write-Host "Re-run with -Execute to create it." -ForegroundColor Yellow
    $conn.Dispose(); return
}

# --- Create the group -------------------------------------------------------
Info "Creating $newDn ..."
$add = [System.DirectoryServices.Protocols.AddRequest]::new()
$add.DistinguishedName = $newDn
$add.Attributes.Add([System.DirectoryServices.Protocols.DirectoryAttribute]::new('objectClass', 'group')) | Out-Null
$add.Attributes.Add([System.DirectoryServices.Protocols.DirectoryAttribute]::new('sAMAccountName', $GroupName)) | Out-Null
$add.Attributes.Add([System.DirectoryServices.Protocols.DirectoryAttribute]::new('groupType', $groupType)) | Out-Null
$add.Attributes.Add([System.DirectoryServices.Protocols.DirectoryAttribute]::new('description', $Description)) | Out-Null
$conn.SendRequest($add) | Out-Null
Ok "Created: $newDn"

# --- Optional members -------------------------------------------------------
foreach ($m in $Members) {
    $mSearch = [System.DirectoryServices.Protocols.SearchRequest]::new($SearchBase, "(sAMAccountName=$m)", 'Subtree', @('distinguishedName'))
    $mResp = [System.DirectoryServices.Protocols.SearchResponse]$conn.SendRequest($mSearch)
    if ($mResp.Entries.Count -eq 0) { Write-Host "  ! member '$m' not found — skipped" -ForegroundColor Yellow; continue }
    $modify = [System.DirectoryServices.Protocols.ModifyRequest]::new($newDn, [System.DirectoryServices.Protocols.DirectoryAttributeOperation]::Add, 'member', $mResp.Entries[0].DistinguishedName)
    $conn.SendRequest($modify) | Out-Null
    Ok "  + $m"
}

$conn.Dispose()
Write-Host ""
Write-Host "Done. Syncs to Entra via Entra Connect (~30 min). Then assign it to the app +" -ForegroundColor Green
Write-Host "capture its Entra group OID (docs/PREFLIGHT-RUNBOOK.md step 1b)." -ForegroundColor Green
