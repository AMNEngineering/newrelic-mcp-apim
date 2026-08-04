<#
.SYNOPSIS
Regression test for preserving existing JSON shapes during the PowerShell client install.

.DESCRIPTION
Runs the real client/install.ps1 in an isolated home directory with fake az and
claude commands, then verifies that the merge only adds mcpServers.newrelic.
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = 0
function Pass([string]$Message) {
    Write-Host "  PASS  $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    Write-Host "  FAIL  $Message" -ForegroundColor Red
    $script:failures++
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Pass $Message } else { Fail $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -eq $Actual) {
        Pass $Message
    } else {
        Fail "$Message (expected '$Expected', got '$Actual')"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoRoot 'client' 'install.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "newrelic-mcp-apim-$([guid]::NewGuid())"
$homePath = Join-Path $tempRoot 'home'
$configPath = Join-Path $homePath '.claude.json'
$runnerPath = Join-Path $tempRoot 'Invoke-InstallerWithFakeCommands.ps1'
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

$inputJson = @'
{
  "theme": "dark",
  "scalarString": "keep me",
  "integer": 42,
  "decimal": 3.5,
  "enabled": true,
  "disabled": false,
  "nothing": null,
  "emptyArray": [],
  "singleArray": [
    "only"
  ],
  "multiArray": [
    1,
    "two",
    false,
    null,
    {
      "nested": "value"
    },
    [
      "inner"
    ]
  ],
  "nestedObject": {
    "string": "nested",
    "number": 7,
    "boolean": true,
    "null": null,
    "emptyArray": [],
    "singleArray": [
      {
        "name": "one"
      }
    ]
  },
  "mcpServers": {
    "other": {
      "type": "stdio",
      "command": "other-command",
      "args": [],
      "env": {
        "FLAG": true,
        "COUNT": 2,
        "VALUE": null
      },
      "features": [
        "one"
      ],
      "disabled": false
    }
  }
}
'@

$runner = @'
$ErrorActionPreference = 'Stop'

function global:az {
    param(
        [Parameter(Position = 0)][string]$Group,
        [Parameter(Position = 1)][string]$Action,
        [string]$Resource,
        [string]$Query,
        [Alias('o')][string]$OutputFormat,
        [Parameter(Position = 2, ValueFromRemainingArguments = $true)][object[]]$RemainingArguments
    )

    $global:LASTEXITCODE = 0
    if ($Group -eq 'account' -and $Action -eq 'show') {
        '{}'
    } else {
        'fake-token'
    }
}

function global:claude {
    $global:LASTEXITCODE = 0
}

if ($HOME -ne $args[1]) {
    throw "Isolated HOME was not applied. Expected '$($args[1])', got '$HOME'."
}

& $args[0] -Env dev
'@

$originalHome = $env:HOME
$originalUserProfile = $env:USERPROFILE

try {
    New-Item -ItemType Directory -Path $homePath -Force | Out-Null
    [System.IO.File]::WriteAllText($configPath, $inputJson, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($runnerPath, $runner, [System.Text.UTF8Encoding]::new($false))

    $env:HOME = $homePath
    $env:USERPROFILE = $homePath
    $installerOutput = & $pwshPath -NoLogo -NoProfile -File $runnerPath $installerPath $homePath 2>&1
    $installerExitCode = $LASTEXITCODE

    Assert-Equal 0 $installerExitCode 'installer completed successfully'
    if ($installerExitCode -ne 0) {
        $installerOutput | ForEach-Object { Write-Host "        $_" }
        throw 'Installer failed; JSON assertions cannot run.'
    }

    $expected = $inputJson | ConvertFrom-Json
    $actual = Get-Content -Raw -Path $configPath | ConvertFrom-Json
    $written = Get-Content -Raw -Path $configPath | ConvertFrom-Json
    $hasNewRelic = $actual.mcpServers.PSObject.Properties.Name -contains 'newrelic'
    Assert-True $hasNewRelic 'newrelic MCP entry is added'
    if (-not $hasNewRelic) {
        $installerOutput | ForEach-Object { Write-Host "        $_" }
        throw 'Installer did not update the isolated config.'
    }

    Assert-True ($actual.scalarString -is [string]) 'string remains a scalar'
    Assert-Equal 'keep me' $actual.scalarString 'string value is preserved'
    Assert-Equal 42 $actual.integer 'integer value is preserved'
    Assert-Equal 3.5 $actual.decimal 'decimal value is preserved'
    Assert-True ($actual.enabled -is [bool] -and $actual.enabled) 'true remains a boolean'
    Assert-True ($actual.disabled -is [bool] -and -not $actual.disabled) 'false remains a boolean'
    Assert-True (
        $actual.PSObject.Properties.Name -contains 'nothing' -and
        $null -eq $actual.nothing
    ) 'null remains an explicit null property'

    Assert-Equal 0 @($actual.emptyArray).Count 'empty array remains empty'
    Assert-Equal 1 @($actual.singleArray).Count 'single-element array remains an array'
    Assert-Equal 'only' $actual.singleArray[0] 'single-element array value is preserved'
    Assert-Equal 6 @($actual.multiArray).Count 'multi-element array retains every element'
    Assert-True ($actual.multiArray[2] -is [bool] -and -not $actual.multiArray[2]) 'array boolean remains a scalar'
    Assert-True ($null -eq $actual.multiArray[3]) 'array null remains null'
    Assert-Equal 'value' $actual.multiArray[4].nested 'array object remains nested'
    Assert-Equal 1 @($actual.multiArray[5]).Count 'nested single-element array remains an array'
    Assert-Equal 'inner' $actual.multiArray[5][0] 'nested array value is preserved'

    Assert-Equal 'nested' $actual.nestedObject.string 'nested object string is preserved'
    Assert-Equal 0 @($actual.nestedObject.emptyArray).Count 'nested empty array remains empty'
    Assert-Equal 1 @($actual.nestedObject.singleArray).Count 'nested single-element array remains an array'
    Assert-Equal 'one' $actual.nestedObject.singleArray[0].name 'nested array object is preserved'

    $actual.mcpServers.PSObject.Properties.Remove('newrelic')
    $expectedJson = $expected | ConvertTo-Json -Depth 20 -Compress
    $actualJson = $actual | ConvertTo-Json -Depth 20 -Compress
    Assert-Equal $expectedJson $actualJson 'all unrelated top-level config and MCP servers preserve their semantic JSON shape'

    Assert-Equal 'http' $written.mcpServers.newrelic.type 'newrelic MCP type is correct'
    Assert-Equal 'https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev' $written.mcpServers.newrelic.url 'newrelic MCP URL is correct'
    Assert-True (
        $written.mcpServers.newrelic.headersHelper -match '^az account get-access-token '
    ) 'newrelic headersHelper is present'
} finally {
    if ($null -eq $originalHome) {
        Remove-Item Env:HOME -ErrorAction SilentlyContinue
    } else {
        $env:HOME = $originalHome
    }

    if ($null -eq $originalUserProfile) {
        Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
    } else {
        $env:USERPROFILE = $originalUserProfile
    }

    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force
    }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'CLIENT INSTALL JSON MERGE TEST PASSED' -ForegroundColor Green
    exit 0
}

Write-Host "CLIENT INSTALL JSON MERGE TEST FAILED ($failures failure(s))" -ForegroundColor Red
exit 1
