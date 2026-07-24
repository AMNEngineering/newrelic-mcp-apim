# Preflight runbook — stand up the New Relic MCP gateway (dev)

Exact, ordered steps to deploy the dev environment. Steps need **Entra app-admin**,
**ADO Cloud Ops**, and **ADM elevation** — run as the operator. Values below are
pre-filled for dev.

Constants:
- APIM (dev): `amn-wus2-hub-apim-d02` / rg `amn-wus2-hub-rg-d01` (internal mode)
- APIM system-assigned MI principal: `a92d1808-15a6-4c50-a1fa-a849730e6af1`
- Key Vault: `co-wus2-newrelic-kv-p01` — sub `43c5a646-c00c-4c59-a332-df854c5dd08c`,
  rg `co-wus2-newreliceventforwarder-rg-s01`, **RBAC-enabled**, secret `AMNHealthcare-NR-Terraform-UserKey`
- tfstate (lower): storage `amncowus2tfstatesad01`, rg `co-wus2-tfstate-rg-p01`, sub `43c5a646-…`, container `new-relic-mcp`
- Client endpoint (dev): `https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev`

---

## 0. Prerequisite — PR #2 merged to master ✅
The pipeline runs off `master`. (Merged during prep.)

## 1. Identity — app registration (Graph) + access group (on-prem AD)

### 1a. On-prem AD group (service desk / AD admin; ~30 min sync)
`AZ_JobRole_Observability_NewRelicMcp_User` is an **on-prem AD** group (all
`AZ_JobRole_*` groups are `onPremisesSyncEnabled`) — created in AD (`ahs.int`), then
synced to Entra (~30 min). Run **`identity/New-NewRelicMcpAdGroup.ps1`** on a **Windows
host with the `ActiveDirectory` module (RSAT)** + DC line-of-sight (the service desk's
environment — not the Mac; there's no AD module for macOS). It auto-discovers the OU +
scope from the existing `AZ_JobRole_*` groups and lands the new one in the same place:
```powershell
.\identity\New-NewRelicMcpAdGroup.ps1 -WhatIf         # preview OU + plan
.\identity\New-NewRelicMcpAdGroup.ps1                 # create it
.\identity\New-NewRelicMcpAdGroup.ps1 -Members jdoe,asmith   # create + add members
```
Membership is managed here in AD, ongoing, by the service desk (`Add-ADGroupMember` or
ADUC) — deliberately, not tied to any other New Relic group.

### 1b. App registration + group assignment (Graph, via the script)
Uses AMN's sanctioned ADM pattern (Microsoft Graph SDK via `Connect-AdmGraph.ps1`,
**not** `az login`). Elevates via **device-code sign-in as your `.adm` account**
— where you enter the Safeguard-checked-out password + complete OneLogin MFA — creates
the app, and (once the AD group has synced) finds + assigns it, then verifies.

One-time setup on your Mac:
```bash
pwsh -Command "Install-Module Microsoft.Graph -Scope CurrentUser -Force"
# (Connect-AdmGraph.ps1 is read from your ~/amn-ops-ai-plugin-marketplace checkout;
#  or pass -ConnectAdmGraphPath / set $env:AMN_MARKETPLACE_ROOT.)
```
Run it (dry-run first, then execute):
```bash
pwsh ./identity/New-NewRelicMcpAppReg.ps1            # prints the plan, no changes
pwsh ./identity/New-NewRelicMcpAppReg.ps1 -Execute   # device-code prompt -> sign in as .adm
```
Your `.adm` account needs **Application Administrator/Developer** (app writes; group
creation is not attempted). Creates app "AMN New Relic MCP" (`api://<appId>`); once
the AD group (1a) has synced, finds + assigns it (ApplicationGroup claims) and prints
**APP ID** + **GROUP OID**. If the group hasn't synced yet, it creates the app, says
the group link is pending, and you re-run after sync. Group membership is managed in
**on-prem AD** (1a), not Entra.

## 2. Fill the two GUIDs into the tfvars
Edit `infrastructure/environments/dev.tfvars` (repeat for int/prod when those deploy):
```hcl
newrelic_mcp_app_id     = "<APP ID from step 1>"
newrelic_user_group_oid = "<GROUP OID from step 1>"
```
Commit + push to master. (Plan is blocked while these are `REPLACE-WITH-…` — a
deliberate GUID validation guard.) *Claude can make this edit for you given the values.*

## 3. Grant APIM's managed identity read access to the Key Vault
Needs RBAC write on the vault (ADM). The KV-reference named value fails to create without this.
```bash
az role assignment create \
  --assignee-object-id a92d1808-15a6-4c50-a1fa-a849730e6af1 \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/43c5a646-c00c-4c59-a332-df854c5dd08c/resourceGroups/co-wus2-newreliceventforwarder-rg-s01/providers/Microsoft.KeyVault/vaults/co-wus2-newrelic-kv-p01"
```

## 4. Create the Terraform state container
Needs write on the shared tfstate storage (ADM).
```bash
az storage container create \
  --account-name amncowus2tfstatesad01 \
  --name new-relic-mcp \
  --subscription 43c5a646-c00c-4c59-a332-df854c5dd08c \
  --auth-mode login
```

## 5. Register the ADO pipeline + approvals
ADO → org **AMNEngineering** → project **Cloud Operations**:
1. Pipelines → New Pipeline → GitHub → `AMNEngineering/newrelic-mcp-apim` → existing
   YAML `/.ado/pipelines/deploy.yml` → Save (name `newrelic-mcp-apim-deploy`).
2. Create ADO Environments `newrelic-mcp-dev` (no gate) and `newrelic-mcp-int`; add
   CAB approvers to `newrelic-mcp-int`.
3. Confirm the shared service connections exist:
   `ADO-AMNEngineering-CloudOps-lower-AMN-IPS-ServiceConnection` (dev),
   `ADO-AMNEngineering-CloudOps-Upper-AMN-IPS-AutomaticSC` (int/prod).
(Details: `.ado/CREATE-PIPELINE-MANUAL.md`.)

## 6. Confirm with the edge team (before apply)
- The shared **AI-API-RR** route's `patternsToMatch` is a `/ai/*` wildcard (covers
  `/ai/new-relic-mcp/*`) — so no new AFD route / AGW path rule is needed.
- The AGW → APIM health probe uses a **shared** `/liveness` (a `type=mcp` API has
  no per-op `/liveness`).

## 7. Run the pipeline (dev)
Queue `newrelic-mcp-apim-deploy`. Flow: Build → dev_plan → dev_apply → dev_verify.
- `dev_verify` runs `test-harness/Invoke-ApimSmokeTest.ps1` (MCP `initialize` +
  `tools/list` + negative-auth) against `https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev`.

## 8. Post-deploy verification
- Confirm the `initialize` handshake passes (in the pipeline log) — this validates
  the `mcpProperties` compose to `mcp.newrelic.com/mcp/`.
- Confirm the injected User key's **cross-subaccount reach** via
  `list_available_new_relic_accounts` through the gateway (DECISIONS.md #1 caveat).

## 9. Client cutover (after dev verifies)
De-draft `amn-ops-ai-plugin-marketplace#170`; bootstrap sets `NEWRELIC_MCP_URL`
(= `https://api.dev.amnhealthcare.io/ai/new-relic-mcp/dev`) and `NEWRELIC_MCP_TOKEN`
(Entra bearer for `api://<appId>`; the dev must be in the access group).
