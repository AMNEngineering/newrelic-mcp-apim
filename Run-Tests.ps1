#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the local Pester merge gate with the same filtering as CI.

.DESCRIPTION
    Runs hosted-safe behavior specs under tests/. Integration specs are excluded
    by default because they require live Azure or network access.

.PARAMETER Integration
    Include live specs tagged Integration.

.PARAMETER Detailed
    Use detailed Pester output.

.EXAMPLE
    powershell -File .\Run-Tests.ps1
    pwsh -File ./Run-Tests.ps1 -Detailed
#>
param(
    [switch]$Integration,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 auto-loads Pester 3.4; force the pinned 5.x line.
Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
if (-not $Integration) {
    $config.Filter.ExcludeTag = 'Integration'
}

Invoke-Pester -Configuration $config
