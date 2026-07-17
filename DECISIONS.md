# Decision log — New Relic MCP behind APIM

Design decisions, resolved with Bart (Cloud Ops) on 2026-07-16.

## Design decisions

| # | Decision | Resolution |
|---|----------|------------|
| 1 | New Relic key storage | **Key Vault reference** to the existing NerdGraph **User key** — secret `AMNHealthcare-NR-Terraform-UserKey` in `co-wus2-newrelic-kv-p01` (confirmed present + enabled). New Relic has no read-only key type — a User key inherits its user's permissions — so read/write is enforced at the **skill layer**, not the credential. Never inline in TF state. |
| 2 | Identity | **One NEW dedicated New Relic MCP app registration** (the JWT audience) covering **all** NR MCP actions — read AND write. New Relic does not distinguish read vs write at the token/User-key level, so neither does the app. **Access is gated by membership in ONE new dedicated AD security group** (`AZ_JobRole_Observability_NewRelicMcp_User`, a groups-claim check in the policy) — **not** an app role. The app uses **`groupMembershipClaims = ApplicationGroup`** with that group assigned to it, so only that group emits in the token (overage-proof, works regardless of how many groups a user is in). **Group membership is managed independently** — a person is added to this group specifically to grant MCP access; it is intentionally **NOT** tied to or derived from any other New Relic membership (e.g. the notification DLs). App + group created via `identity/New-NewRelicMcpAppReg.ps1`; members added deliberately. Read/write is enforced strictly at the **marketplace + skill layer**. One app + one group across envs for the pilot; per-env split is optional future hardening. |
| 3 | Rate limit | **Per-user `rate-limit-by-key`, default 300 calls / 60s.** Unlike the SFDC reference (which documents but does not implement a limit), New Relic has a real flood/cost vector — arbitrary NRQL — so we implement one. Tunable in `*.tfvars`. |
| 4 | Write path (`newrelic-rw`) | **Read-only first.** The dedicated app (#2) already covers write, but write actions are gated at the skill layer; the actual write MCP host is provisioned separately via Terraform in the pipeline, staged for CAB approval, as a follow-on. |
| 5 | Repo home | **This repo** (`newrelic-mcp-apim`), modernized in place onto the sfdc pattern. |

## How this differs from the prior prototype (June)

The prototype (`terraform/main.tf` + a manually-applied policy) was a spike:
inline key in TF state, no groups/roles gate, policy applied out-of-band via
`az apim api policy create`, its own `Azure-MCP-ServiceConnection`, no CAB gate,
generic placeholder APIM. This rewrite replaces all of that with the governed
gold-standard pattern and the decisions above.

## How this differs from the SFDC gold standard

- **Native `type=mcp` API, not plain REST.** SFDC models MCP as a plain `azurerm`
  REST API with hand-declared `/mcp` operations (shaped by its Power Automate /
  Copilot connector-export needs). New Relic uses APIM's **native `type=mcp`** API
  (`azapi`), fronting NR's hosted MCP via `backendId` + `mcpProperties` — modeled on
  **`amn-passport-mcp`**, which already runs this way on the same APIM. This makes
  it a first-class MCP server that MCP-enabled clients register directly, and routing
  is native (no operations, no `set-backend-service`/`rewrite-uri` in the policy).
- **Much simpler backend auth.** SFDC does an OAuth `client_credentials` exchange
  *inside* the policy (cache + send-request). New Relic uses a **static Api-Key**,
  so that whole dance collapses to one injected header.
- **Rate limit is real here** (SFDC's is doc-only).
- **No `oauth2-auth-server` module.** That exists in SFDC only to export connector
  metadata for Power Automate / Copilot Studio. New Relic's client is Claude Code
  (Entra JWT), so it's omitted.
- **No dev-mock / health-check operation.** New Relic's hosted MCP is reachable
  directly, and a `type=mcp` API has no per-operation surface for a `/health` probe
  (like `amn-passport-mcp`); liveness is covered by the smoke test's MCP `initialize`.

## Caveats to resolve at deploy

- **#1 secret name** — CONFIRMED: `AMNHealthcare-NR-Terraform-UserKey` exists and is
  enabled in `co-wus2-newrelic-kv-p01`. (default of `newrelic_api_key_secret_name`.)
- **#1 account reach** — the `…-Terraform-UserKey` service-user keys may be scoped
  narrower than a developer's laptop `NEW_RELIC_API_KEY`. Confirm cross-subaccount
  reach at Verify via `list_available_new_relic_accounts` through the gateway.
- **#2 app id + group** — run `identity/New-NewRelicMcpAppReg.ps1` (needs app-admin):
  creates the app, creates the `AZ_JobRole_Observability_NewRelicMcp_User` security
  group, sets ApplicationGroup claims, and assigns the group to the app. Add members
  to the group deliberately (Entra → Groups → members, or `az ad group member add`) —
  this group is managed independently and must not be tied to other NR memberships.
  Paste the Application (client) ID → `newrelic_mcp_app_id` and the group Object ID →
  `newrelic_user_group_oid` in the env `*.tfvars`.
