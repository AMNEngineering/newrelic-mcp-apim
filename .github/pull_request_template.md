<!--
  Use a Conventional Commit title, such as feat:, fix:, docs:, or ci:.
-->

## What & why



## Checklist
- [ ] **Merge gate green** - Pester passes in Windows PowerShell 5.1 and PowerShell 7 (`./Run-Tests.ps1` locally), with no PSScriptAnalyzer Errors
- [ ] **Test sweep** - added or updated `tests/*.Tests.ps1` behavior specs; live Azure/network checks are tagged `Integration`
- [ ] **Doc sweep** - documentation describing changed behavior is updated
- [ ] **UTF-8 BOM** - every new or edited `.ps1` uses UTF-8 with BOM
- [ ] **Self-contained scripts** - no new cross-repository runtime dependencies

<!-- The merge queue re-runs `gate` against the latest default branch before landing. -->
