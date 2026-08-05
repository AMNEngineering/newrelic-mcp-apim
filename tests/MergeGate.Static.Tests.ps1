#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Hosted-runnable merge-safety invariants. These tests perform only local
    parsing and byte inspection; live Azure/network checks belong in the
    Integration-tagged suite.
#>

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    function Get-TrackedFiles {
        param([string[]]$Extensions)

        @(
            & git -C $script:RepoRoot ls-files |
                Where-Object { [System.IO.Path]::GetExtension($_) -in $Extensions } |
                ForEach-Object {
                    @{
                        Name = $_
                        Path = Join-Path $script:RepoRoot $_
                    }
                }
        )
    }

    $script:AllPowerShell = Get-TrackedFiles -Extensions '.ps1'
    $script:AllJson = Get-TrackedFiles -Extensions '.json'
    $script:AllXml = Get-TrackedFiles -Extensions '.xml'
    $script:AllYaml = Get-TrackedFiles -Extensions '.yml', '.yaml'
}

Describe 'PowerShell source hygiene' {
    It '<Name> parses with no syntax errors' -ForEach $script:AllPowerShell {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        $parseErrors | Should -BeNullOrEmpty -Because "$Name must parse cleanly"
    }

    It '<Name> is UTF-8 with BOM' -ForEach $script:AllPowerShell {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $bytes.Length | Should -BeGreaterThan 3
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeTrue -Because "$Name must support Windows PowerShell 5.1 text decoding"
    }
}

Describe 'Repository configuration syntax' {
    It '<Name> is valid JSON' -ForEach $script:AllJson {
        { Get-Content -Raw -Path $Path | ConvertFrom-Json -ErrorAction Stop } |
            Should -Not -Throw
    }

    It '<Name> is valid XML' -ForEach $script:AllXml {
        { [xml](Get-Content -Raw -Path $Path -ErrorAction Stop) } |
            Should -Not -Throw
    }

    It '<Name> is valid YAML' -ForEach $script:AllYaml {
        & ruby -e "require 'yaml'; YAML.parse_file(ARGV.fetch(0))" $Path
        $LASTEXITCODE | Should -Be 0 -Because "$Name must be valid YAML"
    }
}

Describe 'Merge gate contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $workflowPath = Join-Path $repoRoot '.github/workflows/merge-gate.yml'
        $workflow = Get-Content -Raw -Path $workflowPath
        $policy = Get-Content -Raw -Path (Join-Path $repoRoot 'AGENTS.md')
    }

    It 'runs for pull requests and merge queue groups' {
        $workflow | Should -Match '(?m)^\s{2}pull_request:\s*$'
        $workflow | Should -Match '(?m)^\s{2}merge_group:\s*$'
    }

    It 'exposes the required gate job on Windows' {
        $workflow | Should -Match '(?m)^\s{2}gate:\s*$'
        $workflow | Should -Match '(?m)^\s{4}runs-on:\s*windows-latest\s*$'
    }

    It 'runs Pester in both PowerShell runtimes' {
        $workflow | Should -Match '(?m)^\s{8}shell:\s*pwsh\s*$'
        $workflow | Should -Match '(?m)^\s{8}shell:\s*powershell\s*$'
    }

    It 'pins Pester to the 5.x line' {
        $workflow | Should -Match 'Pester -MinimumVersion 5\.0\.0 -MaximumVersion 5\.99\.99'
    }

    It 'documents the upstream policy and local gate command' {
        $policy | Should -Match 'github-merge-bdd-ci/blob/main/STANDARD\.md'
        $policy | Should -Match 'pwsh -File \./Run-Tests\.ps1'
    }
}
