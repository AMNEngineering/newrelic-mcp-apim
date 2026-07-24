#Requires -Version 7.0

<#
.SYNOPSIS
Expose the New Relic MCP app's API scope (user_impersonation) and pre-authorize
the Azure CLI client so clients can mint a token for it
(`az account get-access-token --resource api://<app-id>`). Fixes AADSTS65001.

.DESCRIPTION
The dedicated NR MCP app (audience api://<app-id>) was created without an exposed
API scope, so no client can obtain a token for it without an interactive consent
prompt. This adds a delegated `user_impersonation` scope and pre-authorizes the
Microsoft Azure CLI client (04b07795-8ddb-461a-bbee-02f9e1bf7b46) — the same shape
sfdc-read-mcp-apim uses (Add-AzureCliPreAuth) so its smoke test / bootstrap can get
tokens silently. Elevated Graph write via Connect-AdmGraph (device-code as .adm).

Idempotent: reuses an existing user_impersonation scope if present. Dry-run by
default; pass -Execute.

.PARAMETER AppId
The NR MCP app's Application (client) ID. Default 709bbe94-....

.PARAMETER ClientId
Client app id to pre-authorize. Default Microsoft Azure CLI. Repeatable via -ExtraClientIds.
#>
[CmdletBinding()]
param(
    [string]$AppId = '709bbe94-f759-422f-b7fa-28f1fde28ae1',
    [string]$ClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46',
    [string[]]$ExtraClientIds = @(),
    [string]$TenantId = '6232c2ec-fa42-4f27-92cd-787913fba489',
    [string]$ConnectAdmGraphPath,
    [switch]$SkipPrompt,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  OK $m" -ForegroundColor Green }

Write-Host ""
Write-Host "=== NR MCP app — expose scope + pre-authorize clients ===" -ForegroundColor Cyan
Write-Host "  App (audience) : api://$AppId"
Write-Host "  Scope          : user_impersonation (delegated)"
Write-Host "  Pre-authorize  : $ClientId (Azure CLI)$([string]::Join('', ($ExtraClientIds | ForEach-Object { ', ' + $_ })))"
Write-Host ""
if (-not $Execute) { Write-Host "DRY-RUN — re-run with -Execute to elevate + apply." -ForegroundColor Yellow; return }

$needed = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
$missing = @($needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missing.Count -gt 0) { throw "Missing module(s): $($missing -join ', '). Install-Module Microsoft.Graph -Scope CurrentUser -Force" }

$candidates = @()
if ($ConnectAdmGraphPath) { $candidates += $ConnectAdmGraphPath }
if ($env:AMN_MARKETPLACE_ROOT) { $candidates += (Join-Path $env:AMN_MARKETPLACE_ROOT 'setup' 'scripts' 'Connect-AdmGraph.ps1') }
$candidates += (Join-Path $PSScriptRoot '..' '..' 'amn-ops-ai-plugin-marketplace' 'setup' 'scripts' 'Connect-AdmGraph.ps1')
$connectAdmGraph = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $connectAdmGraph) { throw "Could not find Connect-AdmGraph.ps1. Pass -ConnectAdmGraphPath or set `$env:AMN_MARKETPLACE_ROOT." }

$admCtx = & $connectAdmGraph -TenantId $TenantId -Scopes @('Application.ReadWrite.All') -SkipPrompt:$SkipPrompt

try {
    $app = Get-MgApplication -Filter "appId eq '$AppId'" -All | Select-Object -First 1
    if (-not $app) { throw "App $AppId not found." }

    # Reuse or create the user_impersonation scope
    $api = $app.Api
    $scope = @($api.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'user_impersonation' }) | Select-Object -First 1
    if ($scope) {
        $scopeId = $scope.Id
        Ok "Scope 'user_impersonation' already exists ($scopeId)."
    }
    else {
        $scopeId = (New-Guid).Guid
        $newScope = @{
            Id                      = $scopeId
            Value                   = 'user_impersonation'
            Type                    = 'User'
            IsEnabled               = $true
            AdminConsentDisplayName = 'Access the New Relic MCP gateway'
            AdminConsentDescription = 'Allow the app to access the New Relic MCP gateway on behalf of the signed-in user.'
            UserConsentDisplayName  = 'Access the New Relic MCP gateway'
            UserConsentDescription  = 'Allow access to the New Relic MCP gateway on your behalf.'
        }
        $existingScopes = @($api.Oauth2PermissionScopes)
        Update-MgApplication -ApplicationId $app.Id -Api @{ Oauth2PermissionScopes = ($existingScopes + $newScope) }
        Ok "Added scope 'user_impersonation' ($scopeId)."
    }

    # Pre-authorize the client app(s) for that scope
    $clients = @($ClientId) + $ExtraClientIds
    $preAuth = @()
    foreach ($c in $clients) { $preAuth += @{ AppId = $c; DelegatedPermissionIds = @($scopeId) } }
    Update-MgApplication -ApplicationId $app.Id -Api @{ PreAuthorizedApplications = $preAuth }
    Ok "Pre-authorized: $($clients -join ', ')"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Ok "Deelevated."
}

Write-Host ""
Write-Host "Done. Test:  az account get-access-token --resource api://$AppId" -ForegroundColor Green
Write-Host "(may take a minute to propagate.)" -ForegroundColor Green
