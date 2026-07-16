# Decision log — New Relic MCP behind APIM

Design decisions, resolved with Bart (Cloud Ops) on 2026-07-16.

## Design decisions

| # | Decision | Resolution |
|---|----------|------------|
| 1 | New Relic key storage | **Key Vault reference** to the existing NerdGraph **User key** (`co-wus2-newrelic-kv-p01`). New Relic has no read-only key type — a User key inherits its user's permissions — so read/write is enforced at the **skill layer**, not the credential. Never inline in TF state. |
| 2 | Identity | **Reuse Bart's `api://newrelic-mcp-reader` app** + an `MCP.Read` app role (roles-claim gate), matching the sfdc gold-standard identity model. Split to a dedicated per-env app + `AZ_AMN_AAD_NewRelicMcp_{env}_User` group before broad rollout. |
| 3 | Rate limit | **Per-user `rate-limit-by-key`, default 300 calls / 60s.** Unlike the SFDC reference (which documents but does not implement a limit), New Relic has a real flood/cost vector — arbitrary NRQL — so we implement one. Tunable in `*.tfvars`. |
| 4 | Write path (`newrelic-rw`) | **Read-only first.** `newrelic-rw` (dashboard writes) stays local (ask/deny) until rehosted as an HTTP/Functions MCP; then it can front through APIM as a follow-on. |
| 5 | Repo home | **This repo** (`newrelic-mcp-apim`), modernized in place onto the sfdc pattern. |

## How this differs from the prior prototype (June)

The prototype (`terraform/main.tf` + a manually-applied policy) was a spike:
inline key in TF state, no groups/roles gate, policy applied out-of-band via
`az apim api policy create`, its own `Azure-MCP-ServiceConnection`, no CAB gate,
generic placeholder APIM. This rewrite replaces all of that with the governed
gold-standard pattern and the decisions above.

## How this differs from the SFDC gold standard

- **Much simpler backend auth.** SFDC does an OAuth `client_credentials` exchange
  *inside* the policy (cache + send-request). New Relic uses a **static Api-Key**,
  so that whole dance collapses to one injected header.
- **Rate limit is real here** (SFDC's is doc-only).
- **No `oauth2-auth-server` module.** That exists in SFDC only to export connector
  metadata for Power Automate / Copilot Studio. New Relic's client is Claude Code
  (Entra JWT), so it's omitted.
- **No dev-mock policy.** New Relic's hosted MCP is reachable directly, so dev uses
  the real backend.

## Caveats to resolve at deploy

- **#1 secret name** — the exact Key Vault secret is unsettled (candidates:
  `AMNHealthcare-NR-Terraform-UserKey`, `NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace`).
  Confirm at Preflight; set `newrelic_api_key_secret_name`.
- **#1 account reach** — the `…-Terraform-UserKey` service-user keys may be scoped
  narrower than a developer's laptop `NEW_RELIC_API_KEY`. Confirm cross-subaccount
  reach at Verify via `list_available_new_relic_accounts` through the gateway.
- **#2 app id** — fill the real `newrelic-mcp-reader` app id into the env `*.tfvars`
  (`REPLACE-WITH-…` placeholders).
