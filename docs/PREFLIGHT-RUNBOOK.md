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

## 1. Identity — create the app registration + access group
The script **self-elevates**: it signs your `<you>.adm` account into an isolated
`AZURE_CONFIG_DIR`, runs the privileged Graph commands, then discards that session
— your daily `az` login (subscription and all) is never touched. Your `.adm`
account must hold **Application Administrator/Developer** + **Groups Administrator**
(activate via PIM first if eligible).
```bash
pwsh ./identity/New-NewRelicMcpAppReg.ps1
# A browser opens — sign in as <you>.adm@amnhealthcare.com.
# Creates app "AMN New Relic MCP" (api://<appId>) + group
# AZ_JobRole_Observability_NewRelicMcp_User, ApplicationGroup claims, assigns the
# group to the app, then de-elevates. Prints APP ID and GROUP OID — copy both.
# Headless/SSH: add -UseDeviceCode.
```
Then add the intended developers to the group (Entra → Groups →
`AZ_JobRole_Observability_NewRelicMcp_User` → Members), or:
```bash
az ad group member add --group AZ_JobRole_Observability_NewRelicMcp_User --member-id <userObjectId>
```

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
