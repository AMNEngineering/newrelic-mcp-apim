<#
.SYNOPSIS
Installs the APIM-fronted New Relic MCP for GitHub Copilot CLI and App.

.DESCRIPTION
Installs a version-pinned local stdio bridge and merges a `newrelic` entry into
the Copilot user MCP configuration. The bridge obtains short-lived Entra tokens
from Azure CLI in memory and never writes the bearer token to disk.
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [ValidateSet('dev', 'int')]
    [string]$Env = 'dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Ok([string]$Message) { Write-Host "[ok] $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message) { Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[error] $Message" -ForegroundColor Red }
function Write-Info([string]$Message) { Write-Host "  $Message" }

function ConvertTo-HashtableRecursive {
    param([Parameter(ValueFromPipeline = $true)]$Object)
    process {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $Object.Keys) {
                $result[$key] = ConvertTo-HashtableRecursive $Object[$key]
            }
            return $result
        }
        if ($Object -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in $Object.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-HashtableRecursive $property.Value
            }
            return $result
        }
        if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
            $items = @($Object)
            $converted = [object[]]::new($items.Count)
            for ($index = 0; $index -lt $items.Count; $index++) {
                $converted[$index] = ConvertTo-HashtableRecursive $items[$index]
            }
            return ,$converted
        }
        return $Object
    }
}

function Get-RequiredCommand([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        Write-Fail "$Name is required and was not found on PATH."
        exit 1
    }
    return $command.Source
}

function Assert-AssetHash([string]$Path, [string]$Name, [hashtable]$ExpectedHashes) {
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHashes[$Name]) {
        throw "Checksum verification failed for $Name."
    }
}

$nrMcpAppId = 'api://709bbe94-f759-422f-b7fa-28f1fde28ae1'
$assetRef = '2bb4f81a3fa83d10143280925395b6c4a9685dc1'
$rawBase = "https://raw.githubusercontent.com/AMNEngineering/newrelic-mcp-apim/$assetRef/client/copilot"
$expectedHashes = @{
    'bridge.mjs' = '9aebe36f9e378a97238828b2044d929e7e61b420a51277e9ed24a3429ad02cc9'
    'auth.mjs' = 'ffc4c24921c446099873363f09f75fc080e1f4a8b27d1cf707df3ddb7b6da4e2'
    'azure-cli.mjs' = '5dab75efa0d631ff9b03b3dcc55546b48899b06c92c56d90391e275e90054833'
    'package.json' = 'd970c21eed2ffdd38a3b177bc53febb64bcdf1021c46c631597ad0f966f2fee9'
    'package-lock.copilot' = '5678872d626f239d3b7ba51a16d1ca1ae7e207d9cfdcf0912104d0e0fc1099f4'
}
$mcpUrl = "https://api.$Env.amnhealthcare.io/ai/new-relic-mcp/$Env"
$azPath = Get-RequiredCommand 'az'
$nodePath = Get-RequiredCommand 'node'
$npmCommand = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'npm.cmd' } else { 'npm' }
$npmPath = Get-RequiredCommand $npmCommand

$nodeMajor = [int]((& $nodePath -p 'Number(process.versions.node.split(".")[0])').Trim())
if ($nodeMajor -lt 20) {
    Write-Fail "Node.js 20 or newer is required (found $(& $nodePath --version))."
    exit 1
}

$copilotRoot = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
$configFile = Join-Path $copilotRoot 'mcp-config.json'
$installDir = Join-Path (Join-Path $copilotRoot 'servers') 'newrelic-apim'
$bridgePath = Join-Path $installDir 'bridge.mjs'

$newRelicEntry = [ordered]@{
    type = 'stdio'
    command = $nodePath
    args = @(
        $bridgePath,
        '--url', $mcpUrl,
        '--audience', $nrMcpAppId,
        '--az-path', $azPath
    )
    tools = @('*')
}

Write-Info "Copilot config: $configFile"
Write-Info "Bridge install: $installDir"
Write-Info "Endpoint: $mcpUrl"

& $azPath account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "No active Azure CLI session. Run 'az login' before using New Relic."
} elseif (-not $Check) {
    & $azPath account get-access-token `
        --resource $nrMcpAppId `
        --query accessToken `
        --output tsv `
        --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Entra token acquisition succeeded.'
    } else {
        Write-Warn2 'Token acquisition failed. Verify Azure login and AZ_JobRole_Observability_NewRelicMcp_User membership.'
    }
}

$existing = $null
$hadConfig = Test-Path $configFile
if ($hadConfig) {
    try {
        $existing = Get-Content -Raw -Path $configFile |
            ConvertFrom-Json -ErrorAction Stop |
            ConvertTo-HashtableRecursive
    } catch {
        Write-Fail "$configFile is not valid JSON; refusing to modify it."
        exit 1
    }
    if (-not ($existing -is [System.Collections.IDictionary])) {
        Write-Fail "$configFile must contain a JSON object."
        exit 1
    }
    if (
        $existing.Contains('mcpServers') -and
        $null -ne $existing.mcpServers -and
        -not ($existing.mcpServers -is [System.Collections.IDictionary])
    ) {
        Write-Fail "$configFile mcpServers must be a JSON object."
        exit 1
    }

    if (
        $existing.Contains('mcpServers') -and
        $existing.mcpServers -and
        $existing.mcpServers.Contains('newrelic')
    ) {
        $currentJson = $existing.mcpServers.newrelic | ConvertTo-Json -Depth 20 -Compress
        $desiredJson = $newRelicEntry | ConvertTo-Json -Depth 20 -Compress
        if ($currentJson -ne $desiredJson) {
            if ($Check) {
                Write-Warn2 'A different mcpServers.newrelic entry exists and would be replaced.'
            } elseif (-not $Force) {
                Write-Warn2 'A different mcpServers.newrelic entry already exists.'
                $response = Read-Host 'Replace it with the APIM Copilot bridge? (y/N)'
                if ($response -notmatch '^[yY]') {
                    Write-Info 'Aborted.'
                    exit 0
                }
            }
        }
    }
}

if ($Check) {
    Write-Ok 'Check-only mode; no files changed.'
    ($newRelicEntry | ConvertTo-Json -Depth 20) -split "`n" |
        ForEach-Object { Write-Info "    $_" }
    exit 0
}

$serversRoot = Join-Path $copilotRoot 'servers'
New-Item -ItemType Directory -Path $copilotRoot, $serversRoot -Force | Out-Null
$sourceDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'copilot' } else { $null }
$assets = @('bridge.mjs', 'auth.mjs', 'azure-cli.mjs', 'package.json', 'package-lock.copilot')
$tempDir = $null
$stagingDir = Join-Path $serversRoot ".newrelic-apim-install-$([guid]::NewGuid())"
$configTemp = Join-Path $copilotRoot ".mcp-config-install-$([guid]::NewGuid()).json"
$previousDir = $null
$bridgeActivated = $false
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    $hasLocalAssets = $null -ne $sourceDir -and @(
        $assets | Where-Object { -not (Test-Path (Join-Path $sourceDir $_)) }
    ).Count -eq 0

    if ($hasLocalAssets) {
        foreach ($asset in $assets) {
            Assert-AssetHash -Path (Join-Path $sourceDir $asset) -Name $asset -ExpectedHashes $expectedHashes
            $destinationName = if ($asset -eq 'package-lock.copilot') { 'package-lock.json' } else { $asset }
            Copy-Item -Path (Join-Path $sourceDir $asset) -Destination (Join-Path $stagingDir $destinationName) -Force
        }
    } else {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "newrelic-copilot-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        foreach ($asset in $assets) {
            Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/$asset" -OutFile (Join-Path $tempDir $asset)
            Assert-AssetHash -Path (Join-Path $tempDir $asset) -Name $asset -ExpectedHashes $expectedHashes
            $destinationName = if ($asset -eq 'package-lock.copilot') { 'package-lock.json' } else { $asset }
            Copy-Item -Path (Join-Path $tempDir $asset) -Destination (Join-Path $stagingDir $destinationName) -Force
        }
    }

    & $npmPath ci `
        --prefix $stagingDir `
        --omit=dev `
        --ignore-scripts `
        --no-audit `
        --no-fund `
        --silent
    if ($LASTEXITCODE -ne 0) {
        throw "npm ci failed with exit code $LASTEXITCODE."
    }

    if (-not $existing) { $existing = [ordered]@{} }
    if (-not $existing.Contains('mcpServers') -or -not $existing.mcpServers) {
        $existing.mcpServers = [ordered]@{}
    }
    $existing.mcpServers.newrelic = $newRelicEntry

    if ($hadConfig) {
        $backup = "$configFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $configFile -Destination $backup -Force
    }

    $json = $existing | ConvertTo-Json -Depth 20
    $bytes = [System.Text.UTF8Encoding]::new($true).GetBytes($json)
    [System.IO.File]::WriteAllBytes($configTemp, $bytes)
    Get-Content -Raw -Path $configTemp | ConvertFrom-Json -ErrorAction Stop | Out-Null
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        & chmod 600 $configTemp
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restrict permissions on $configTemp."
        }
        if ($hadConfig) {
            & chmod 600 $backup
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to restrict permissions on $backup."
            }
        }
    }

    if (Test-Path $installDir) {
        $previousDir = "$installDir.previous-$([guid]::NewGuid())"
        Move-Item -Path $installDir -Destination $previousDir
    }
    Move-Item -Path $stagingDir -Destination $installDir
    $bridgeActivated = $true

    try {
        Move-Item -Path $configTemp -Destination $configFile -Force
    } catch {
        Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($previousDir -and (Test-Path $previousDir)) {
            Move-Item -Path $previousDir -Destination $installDir
        }
        throw
    }

    if ($previousDir -and (Test-Path $previousDir)) {
        Remove-Item -Path $previousDir -Recurse -Force
    }
    Write-Ok 'Installed the version-pinned local MCP bridge.'
    if ($hadConfig) {
        Write-Ok "Backed up the previous configuration to $backup."
    }
} catch {
    if (-not $bridgeActivated -and $previousDir -and (Test-Path $previousDir) -and -not (Test-Path $installDir)) {
        Move-Item -Path $previousDir -Destination $installDir
    }
    throw
} finally {
    if ($tempDir -and (Test-Path $tempDir)) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
    if (-not $bridgeActivated -and (Test-Path $stagingDir)) {
        Remove-Item -Path $stagingDir -Recurse -Force
    }
    if (Test-Path $configTemp) {
        Remove-Item -Path $configTemp -Force
    }
}

Write-Ok 'Configured New Relic for Copilot CLI, Copilot App, and VS Code Agent Host.'
Write-Info "Start a new Copilot session, then run '/mcp show newrelic'."
