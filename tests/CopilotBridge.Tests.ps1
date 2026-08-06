#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Copilot APIM bridge authentication' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $testPath = Join-Path $repoRoot 'client/copilot/auth.test.mjs'
    }

    It 'passes the Node authentication behavior tests' {
        $output = & node --test $testPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }
}
