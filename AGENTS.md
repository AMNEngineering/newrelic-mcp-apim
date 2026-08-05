# Repository policy

This repository adopts the
[AMN GitHub merge-gate standard](https://github.com/AMNEngineering/github-merge-bdd-ci/blob/main/STANDARD.md).
That upstream document is authoritative; do not duplicate it here.

Run the hosted-safe gate locally with:

```powershell
pwsh -File ./Run-Tests.ps1
```

Windows PowerShell 5.1 compatibility is enforced by the GitHub Actions `gate`
job and can be checked on Windows with `powershell -File .\Run-Tests.ps1`.
Live Azure and network checks must use the Pester `Integration` tag and remain
excluded from the blocking gate.
