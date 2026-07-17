# Registering the ADO pipeline (manual)

The `az pipelines create` GitHub flow tends to lock up on interactive OAuth, so
register the pipeline through the portal.

## Steps

1. Azure DevOps → org **AMNEngineering** → project **Cloud Operations**.
2. **Pipelines → New Pipeline**.
3. **GitHub** → select repo **`AMNEngineering/newrelic-mcp-apim`**
   (authorize the ADO GitHub app if prompted).
4. **Existing Azure Pipelines YAML file** → branch `main` (or `master`) →
   path **`/.ado/pipelines/deploy.yml`**.
5. **Save** (do not run yet). Suggested pipeline name: `newrelic-mcp-apim-deploy`.

## Before the first run

- **Service connections** (already shared, no action if they exist):
  `ADO-AMNEngineering-CloudOps-lower-AMN-IPS-ServiceConnection` (dev) and
  `ADO-AMNEngineering-CloudOps-Upper-AMN-IPS-AutomaticSC` (int/prod, WIF).
- **ADO Environments** — create `newrelic-mcp-dev` (no gate) and
  `newrelic-mcp-int`; add CAB approvers to `newrelic-mcp-int` (the pipeline also
  has a `ManualValidation` gate notifying bart.elia@amnhealthcare.com).
- **State container** — the backend uses container `newrelic` in the shared
  tfstate storage (`amncowus2tfstatesad01` lower / `amncowus2tfstatesap01` upper),
  RG `co-wus2-tfstate-rg-p01`. Create the `newrelic` container if it doesn't exist.
- **Preflight inputs** — create the app reg + access group
  (`identity/New-NewRelicMcpAppReg.ps1`; group `AZ_JobRole_Observability_NewRelicMcp_User`), fill
  `newrelic_mcp_app_id` + `newrelic_user_group_oid` in the env `*.tfvars`, add
  developers to the group, and grant APIM's managed identity KV `get` on
  `co-wus2-newrelic-kv-p01` (secret `AMNHealthcare-NR-Terraform-UserKey`). See ../DECISIONS.md.

## Flow

`Build → dev_plan → dev_apply → dev_verify → int_plan → int_apply (manual approval) → int_verify (+ smoke test)`.
Prod stages are commented out in `deploy.yml` until CAB approval.
