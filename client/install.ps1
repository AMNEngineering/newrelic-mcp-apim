<#
.SYNOPSIS
Adds the APIM-fronted New Relic MCP to Claude Code (headersHelper pattern).

.DESCRIPTION
Merges a `newrelic` MCP server entry into $HOME/.claude.json using the
headersHelper pattern: `az account get-access-token` mints an Entra bearer on
connection/reconnect and after a 401/403, APIM validates the JWT + AD-group
membership and injects the KV-stored NerdGraph key server-side. No NR key on
your laptop; no static Authorization header on disk.

For AMN engineers on the APIM Claude Code path (the default at AMN). If you're
on the Anthropic-direct Claude Code subscription cohort, install from
AMNEngineering/newrelic-mcp-sso instead.

Idempotent — re-running is a no-op. Use -Check to validate + report without
modifying.

.PARAMETER Check
Validate + report only. No modifications.

.PARAMETER Env
Which APIM environment to point at. Allowed: dev, int. Default: dev.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Env int

.EXAMPLE
    .\install.ps1 -Check
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [ValidateSet('dev', 'int')]
    [string]$Env = 'dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------ ui helpers ------
function Write-Ok    ([string]$m) { Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn2 ([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Fail  ([string]$m) { Write-Host "✗ $m" -ForegroundColor Red }
function Write-Info  ([string]$m) { Write-Host "  $m" }
function Write-Head  ([string]$m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor Cyan }

# PowerShell 5.1 lacks ConvertFrom-Json -AsHashtable; use recursive conversion.
function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline = $true)]$Object)
    process {
        if ($null -eq $Object) { return $null }

        if ($Object -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($key in $Object.Keys) {
                $h[$key] = ConvertTo-HashtableRecursive $Object[$key]
            }
            return $h
        }

        if ($Object -is [pscustomobject]) {
            $h = [ordered]@{}
            foreach ($p in $Object.PSObject.Properties) {
                $h[$p.Name] = ConvertTo-HashtableRecursive $p.Value
            }
            return $h
        }

        if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
            $items = @($Object)
            $converted = [object[]]::new($items.Count)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $converted[$i] = ConvertTo-HashtableRecursive $items[$i]
            }
            return ,$converted
        }

        return $Object
    }
}

$NrMcpAppId = 'api://709bbe94-f759-422f-b7fa-28f1fde28ae1'
$McpUrl = "https://api.$Env.amnhealthcare.io/ai/new-relic-mcp/$Env"
$HeadersHelperCommand = "az account get-access-token --resource `"$NrMcpAppId`" --query `"{Authorization: join(' ', ['Bearer', accessToken])}`" -o json"

Write-Head "New Relic MCP — APIM install (env=$Env)"

# ------ locate config file ------
$cfgFile = Join-Path $HOME '.claude.json'

# ------ prereq check: Claude Code CLI ------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warn2 "'claude' CLI not found on PATH. Install Claude Code first (AMNEngineering/amn-claude-code-client)."
}

# ------ prereq check: az ------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Fail "Azure CLI (az) is required. Install: winget install Microsoft.AzureCLI"
    exit 1
}
Write-Ok "az on PATH"

# ------ prereq check: active az session ------
$azShow = & az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "no active 'az' session. Run 'az login' before Claude Code starts (the APIM client bootstrap does this)."
} else {
    Write-Ok "active az session detected"
}

# ------ prereq check: token acquisition works ------
if (-not $Check) {
    Write-Info "Testing token acquisition against $NrMcpAppId..."
    $token = & az account get-access-token --resource $NrMcpAppId --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($token) -and $token -notmatch 'ERROR') {
        Write-Ok "Entra token acquired successfully ($($token.Length) chars)"
    } else {
        Write-Warn2 "token acquisition failed. Membership in AZ_JobRole_Observability_NewRelicMcp_User is required."
        Write-Info "Continuing install; you can fix the group membership later."
    }
    Remove-Variable token -ErrorAction SilentlyContinue
}

# ------ current state ------
$existing = $null
$hadFile  = Test-Path $cfgFile

if ($hadFile) {
    Write-Info "Found existing $cfgFile"
    try {
        $existing = Get-Content -Raw -Path $cfgFile | ConvertFrom-Json -ErrorAction Stop | ConvertTo-HashtableRecursive
        Write-Ok "existing config is valid JSON"
    } catch {
        Write-Fail "existing $cfgFile is not valid JSON — refusing to touch it. Fix or move aside and re-run."
        exit 1
    }

    if ($existing.Contains('mcpServers') -and $existing.mcpServers.Contains('newrelic')) {
        Write-Warn2 "an 'newrelic' MCP entry already exists in $cfgFile."
        Write-Info "Current entry:"
        ($existing.mcpServers.newrelic | ConvertTo-Json -Depth 10) -split "`n" | ForEach-Object { Write-Info "    $_" }
        if ($Check) {
            Write-Info "Check-only: no changes made."
            exit 0
        }
        Write-Info "This installer will OVERWRITE the existing 'newrelic' entry with the APIM/headersHelper config."
        $resp = Read-Host "Continue? (y/N)"
        if ($resp -notmatch '^[yY]') { Write-Info "Aborted."; exit 0 }
    }
}

# ------ the APIM/headersHelper entry ------
$newRelicEntry = [ordered]@{
    type          = 'http'
    url           = $McpUrl
    headersHelper = $HeadersHelperCommand
}

if ($Check) {
    Write-Ok "Check-only mode. Would merge this into ${cfgFile}:"
    ($newRelicEntry | ConvertTo-Json -Depth 10) -split "`n" | ForEach-Object { Write-Info "    $_" }
    exit 0
}

# ------ backup ------
$backup = $null
if ($hadFile) {
    $backup = "$cfgFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $cfgFile -Destination $backup -Force
    Write-Ok "backed up existing config → $backup"
}

# ------ merge ------
if (-not $existing) { $existing = [ordered]@{} }
if (-not $existing.Contains('mcpServers') -or -not $existing.mcpServers) {
    $existing.mcpServers = [ordered]@{}
}
$existing.mcpServers.newrelic = $newRelicEntry

# UTF-8 with BOM for Windows PowerShell 5.1 rendering fidelity.
$json  = $existing | ConvertTo-Json -Depth 10
$bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($json)
[System.IO.File]::WriteAllBytes($cfgFile, $bytes)

Write-Ok "newrelic MCP (APIM $Env) added to $cfgFile"

# ------ post-write validation ------
try {
    Get-Content -Raw -Path $cfgFile | ConvertFrom-Json -ErrorAction Stop | Out-Null
} catch {
    Write-Fail "post-write validation failed. Restoring backup."
    if ($backup) { Copy-Item -Path $backup -Destination $cfgFile -Force; Write-Info "restored from $backup" }
    exit 1
}

Write-Head "Next steps"
Write-Info "1. Fully quit Claude Code and relaunch."
Write-Info "2. Run /mcp — 'newrelic' should show ✔ Connected (no OAuth prompt — headersHelper mints a token from your az session when Claude Code connects)."
Write-Info "3. If it shows 'Failed to connect', check: az account show (session active?) and group membership (AZ_JobRole_Observability_NewRelicMcp_User)."
Write-Host ""
Write-Info "Endpoint: $McpUrl"
Write-Info "Audience: $NrMcpAppId"
Write-Host ""
