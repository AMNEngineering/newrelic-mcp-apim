# Deprecation notice

**Status: superseded on 2026-07-29.** This repo is no longer the active auth
path for the AMN New Relic MCP. Kept here for reference; do not extend.

## What replaced it

`amn-ops-observability` **v1.2.0+** (in `AMNEngineering/amn-ops-ai-plugin-marketplace`)
now points `mcp.newrelic.com` directly and authenticates via **OAuth 2.0**,
federated through OneLogin. See
[`plugins/amn-ops-observability/MCP-APIM-MIGRATION.md`](https://github.com/AMNEngineering/amn-ops-ai-plugin-marketplace/blob/main/plugins/amn-ops-observability/MCP-APIM-MIGRATION.md)
for the full switch narrative.

## Why we're deprecating

This repo was built to translate an Entra token into a NerdGraph User key at
the gateway, on the assumption that New Relic's API only accepted static keys.
Direct probing on 2026-07-29 showed the **New Relic MCP endpoint supports
OAuth natively** (`/.well-known/oauth-protected-resource` + a canonical
`WWW-Authenticate: Bearer resource_metadata=…` on 401). NR MCP federates
through the customer's IdP — OneLogin in AMN's case — so no translation layer
is needed for that endpoint. The APIM route worked correctly; it was just
solving a problem this particular service doesn't have.

## What's still in play, and what's not

| Artifact | Status | Notes |
|---|---|---|
| APIM route (`/ai/new-relic-mcp/{env}/mcp`) | **Deployed, unused** | Kept live during a bake period. Will be `terraform destroy`'d in a follow-up PR (see below). |
| Key Vault secret `AMNHealthcare-NR-Terraform-UserKey` | **Kept** | It's a general-purpose NR Terraform key, not APIM-specific. Still used for out-of-band NR provisioning (Terraform-managed dashboards, alert conditions, etc.). Do **not** delete. |
| Entra app registration `api://709bbe94-…` + assigned AD groups | **Kept for now** | Deleting is destructive and hard to undo. Will re-evaluate ~90 days after this deprecation lands; if nothing needs it, delete then. |
| This repo | **Archived** | Read-only from GitHub archival. Reversible if we ever need to bring the pattern back. |

## Hard-teardown checklist (not yet run)

When the retirement PR is opened:

- [ ] Confirm NR MCP OAuth (`plugin:amn-ops-observability:newrelic` under v1.2.0+) has been the sole consumer for 2+ weeks with no rollback.
- [ ] Confirm no other Azure workload references this APIM API.
- [ ] `terraform destroy` in `infrastructure/environments/{dev,int,prod}` — removes the APIM API, backend, policy, named values.
- [ ] Verify APIM API `/ai/new-relic-mcp/*` is gone from the gateway.
- [ ] KV secret and Entra app reg remain untouched at this step.
- [ ] After 90 days total, evaluate whether to remove the Entra app reg + group assignments too.

## If we ever need to bring the APIM route back

The Terraform + policy + identity provisioning scripts are all preserved in
this repo. Unarchive, re-apply, and the marketplace plugin's `.mcp.json` reverts
to the v1.1.0 headersHelper form (see the marketplace's `MCP-APIM-MIGRATION.md`
historical section). Nothing has been deleted; the design lives on paper.

## The general lesson

Before designing a translation layer for an MCP server's auth, probe the
endpoint's `/.well-known/oauth-protected-resource` and its unauthenticated
`WWW-Authenticate` response. If the endpoint advertises OAuth and your IdP
federates to it, that's Tier 2 (direct OAuth) and no gateway is needed.
Reserve Tier 3 (APIM key injection) for services with genuinely static-key-only
APIs. See the marketplace repo's
[`MCP-REQUEST-FLOW.md`](https://github.com/AMNEngineering/amn-ops-ai-plugin-marketplace/blob/main/plugins/amn-ops-observability/MCP-REQUEST-FLOW.md)
for the three-tier taxonomy.
