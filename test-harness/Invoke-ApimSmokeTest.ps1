<#
.SYNOPSIS
End-to-end smoke test for the New Relic MCP APIM gateway.

.DESCRIPTION
Drives real MCP JSON-RPC over streamable HTTP through the deployed APIM route
with an Entra bearer token, and asserts the auth plane works:

  1. MCP `initialize` handshake returns a valid JSON-RPC 2.0 result + serverInfo.
  2. `tools/list` returns a non-empty tool set (New Relic read tools).
  3. A request with NO / an invalid token is rejected (401).

Modeled on sfdc-read-mcp-apim/test-harness/Invoke-ApimSmokeTest.ps1. New Relic is
simpler (static Api-Key backend, no OAuth exchange), so there is no SF-style
boundary/SOQL assertion here.

Coverage limit (same as the SFDC harness): -TokenMode AzCli produces an app-only
token under the pipeline SPN. A delegated user token (what an interactive Claude
Code developer carries) cannot be minted in CI — verify that path manually.

.PARAMETER Environment
dev | int | prod. Selects the gateway host and reads the app id from
../infrastructure/environments/<env>.tfvars.

.PARAMETER TokenMode
AzCli (default) = `az account get-access-token --resource api://<app-id>` (works
under WIF). AppOnly = client_credentials with <app-id>/.default (needs a secret;
exercises the bare-GUID audience branch).

.PARAMETER GatewayBaseUrl
Override the gateway base URL. Defaults to the AFD apex for the environment
(https://api.<env>.amnhealthcare.io) — APIM is internal-mode, so the client path
is always via AFD, not the *.azure-api.net host.

.PARAMETER AppId
Override the Entra app id. Defaults to newrelic_mcp_app_id from the env tfvars.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('dev', 'int', 'prod')]
    [string]$Environment = 'int',
    [ValidateSet('AzCli', 'AppOnly')]
    [string]$TokenMode = 'AzCli',
    [string]$GatewayBaseUrl,
    [string]$AppId,
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fail = 0
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "  ->    $m" -ForegroundColor Cyan }

# --- Resolve gateway + app id ------------------------------------------------
# Client traffic goes through the AFD apex — APIM is internal-mode (not publicly
# reachable at *.azure-api.net). The service rides the shared AI-API-RR /ai/* route.
if (-not $GatewayBaseUrl) { $GatewayBaseUrl = "https://api.$Environment.amnhealthcare.io" }
# Native type=mcp API: the MCP endpoint IS the API path (no trailing /mcp operation).
$mcpUrl = "$GatewayBaseUrl/ai/new-relic-mcp/$Environment"

if (-not $AppId) {
    $tfvars = Join-Path $PSScriptRoot ".." "infrastructure" "environments" "$Environment.tfvars"
    if (-not (Test-Path $tfvars)) { throw "Cannot find $tfvars to read newrelic_mcp_app_id; pass -AppId." }
    $line = Select-String -Path $tfvars -Pattern '^\s*newrelic_mcp_app_id\s*=\s*"([^"]+)"' | Select-Object -First 1
    if (-not $line) { throw "newrelic_mcp_app_id not found in $tfvars; pass -AppId." }
    $AppId = $line.Matches[0].Groups[1].Value
}
if ($AppId -match 'REPLACE|TBD') { throw "App id is still a placeholder ($AppId). Set the real app id in $Environment.tfvars or pass -AppId." }

Write-Host ""
Write-Host "New Relic MCP smoke test" -ForegroundColor Cyan
Write-Host "  Environment : $Environment"
Write-Host "  MCP URL     : $mcpUrl"
Write-Host "  App id      : $AppId"
Write-Host "  Token mode  : $TokenMode"
Write-Host ""

# --- Acquire token -----------------------------------------------------------
function Get-Token {
    if ($TokenMode -eq 'AzCli') {
        return (az account get-access-token --resource "api://$AppId" --query accessToken -o tsv)
    }
    else {
        if (-not $ClientSecret) { throw "-TokenMode AppOnly requires -ClientSecret (cannot run under WIF)." }
        $tenant = '6232c2ec-fa42-4f27-92cd-787913fba489'
        $body = @{ client_id = $AppId; client_secret = $ClientSecret; scope = "$AppId/.default"; grant_type = 'client_credentials' }
        return (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body $body).access_token
    }
}
$token = Get-Token
if ([string]::IsNullOrWhiteSpace($token)) { Fail "Could not acquire an Entra token"; exit 1 }
Info "Token acquired."

$headers = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
    Accept         = 'application/json, text/event-stream'
}

function Invoke-Mcp($bodyObj, $authHeaders) {
    $json = $bodyObj | ConvertTo-Json -Depth 8 -Compress
    $resp = Invoke-WebRequest -Method Post -Uri $mcpUrl -Headers $authHeaders -Body $json -SkipHttpErrorCheck
    $text = $resp.Content
    # Parse SSE (text/event-stream) or plain JSON.
    if ($text -match '(?m)^data:\s*(\{.*\})\s*$') { $text = $Matches[1] }
    return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $text }
}

# --- Test 1: initialize ------------------------------------------------------
Info "Test 1: MCP initialize handshake"
$init = Invoke-Mcp @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'apim-smoke-test'; version = '1.0.0' } } } $headers
if ($init.Status -eq 200 -and $init.Body -match '"jsonrpc"\s*:\s*"2.0"' -and $init.Body -match '"serverInfo"') {
    Pass "initialize returned a valid JSON-RPC result with serverInfo (HTTP 200)"
}
else {
    Fail "initialize failed (HTTP $($init.Status)): $($init.Body)"
}

# --- Test 2: tools/list ------------------------------------------------------
Info "Test 2: tools/list returns a non-empty tool set"
$tools = Invoke-Mcp @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } $headers
if ($tools.Status -eq 200 -and $tools.Body -match '"tools"\s*:\s*\[\s*\{') {
    Pass "tools/list returned a non-empty tool set"
}
else {
    Fail "tools/list failed or empty (HTTP $($tools.Status)): $($tools.Body)"
}

# --- Test 3: negative auth ---------------------------------------------------
Info "Test 3: invalid token is rejected (401)"
$bad = Invoke-Mcp @{ jsonrpc = '2.0'; id = 3; method = 'initialize'; params = @{} } @{ Authorization = 'Bearer invalid.token.value'; 'Content-Type' = 'application/json'; Accept = 'application/json' }
if ($bad.Status -eq 401) { Pass "invalid token rejected with 401" } else { Fail "expected 401 for invalid token, got HTTP $($bad.Status)" }

Write-Host ""
if ($fail -eq 0) { Write-Host "SMOKE TEST PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "SMOKE TEST FAILED ($fail failure(s))" -ForegroundColor Red; exit 1 }
