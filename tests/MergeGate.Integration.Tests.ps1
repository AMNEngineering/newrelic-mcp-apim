#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Optional live verification. This suite is tagged Integration and excluded
    from the blocking merge gate.
#>

Describe 'Deployed APIM gateway' -Tag 'Integration' {
    It 'passes the existing MCP smoke test when explicitly enabled' {
        if ($env:NEWRELIC_MCP_RUN_INTEGRATION -ne '1') {
            Set-ItResult -Skipped -Because 'set NEWRELIC_MCP_RUN_INTEGRATION=1 to call the deployed gateway'
            return
        }
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Azure CLI is not installed'
            return
        }
        if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'the smoke test requires PowerShell 7'
            return
        }

        $repoRoot = Split-Path -Parent $PSScriptRoot
        $smokeTest = Join-Path $repoRoot 'test-harness/Invoke-ApimSmokeTest.ps1'
        $environment = if ($env:NEWRELIC_MCP_INTEGRATION_ENVIRONMENT) {
            $env:NEWRELIC_MCP_INTEGRATION_ENVIRONMENT
        }
        else {
            'int'
        }

        & pwsh -NoProfile -File $smokeTest -Environment $environment -TokenMode AzCli
        $LASTEXITCODE | Should -Be 0
    }
}
