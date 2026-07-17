# New Relic MCP behind APIM

APIM gateway that fronts New Relic's hosted MCP server so Claude Code developers
authenticate with Entra ID and **never hold the New Relic key** — APIM injects it
server-side. This moves the New Relic key off laptops into central Key Vault
custody and governs the MCP (tool) data plane the same way the Claude Code model
gateway governs the model plane.

Built on AMN's gold-standard MCP-behind-APIM pattern
([`sfdc-read-mcp-apim`](https://github.com/AMNEngineering/sfdc-read-mcp-apim)):
Terraform + APIM policy + an ADO `Build → Plan → Apply (gated) → Verify` pipeline
on the shared CloudOps service connections into the shared hub APIM.

> This repo was modernized from an earlier prototype. See [`DECISIONS.md`](DECISIONS.md)
> for the design decisions and how they differ from the prototype and from the
> SFDC reference.

## Architecture

```
Claude Code (MCP client)
  │  Authorization: Bearer <Entra JWT>   (aud = dedicated NR MCP app; member of the NR MCP AD group)
  ▼
APIM  amn-wus2-hub-apim-{d02,i02,p02}
  API: api-newrelic-{env}   path: mcp/newrelic/{env}   ops: /health, /mcp (POST/GET/DELETE)
  │  inbound: validate-azure-ad-token (dual audience) + MCP.Read role gate
  │  inbound: audit (x-apim-user-id, x-correlation-id)
  │  inbound: rate-limit-by-key (per user OID)          ← flood/cost guardrail
  │  inbound: strip Authorization, inject Api-Key {{nv-newrelic-mcp-api-key}}  ← from Key Vault
  │  inbound: route + rewrite-uri /mcp/                 (no response buffering — streamable HTTP)
  ▼
https://mcp.newrelic.com/mcp/          New Relic hosted MCP (read-only)
```

## Layout

```
infrastructure/          Terraform root (main/variables/outputs/backend)
  environments/{dev,int,prod}.tfvars
  modules/{named-values, backend-pool, mcp-api, mcp-policy, mcp-api-operation-policy}
policies/
  apim-policy-newrelic-mcp.xml   JWT + MCP.Read role + rate limit + Api-Key injection + routing
  apim-policy-health-check.xml   /health, no JWT (liveness probe)
.ado/pipelines/deploy.yml        Build → Plan → Apply (CAB-gated) → Verify, per env
test-harness/Invoke-ApimSmokeTest.ps1   MCP initialize + tools/list + negative-auth smoke test
```

## Deploy (governed)

1. **Preflight** — create identity: `identity/New-NewRelicMcpAppReg.ps1`
   (creates the app + `AZ_JobRole_Observability_NewRelicMcp_User` group, ApplicationGroup
   claims, assigns the group). Add members to the group deliberately — it is managed
   independently and is not tied to any other New Relic membership. Paste the app id +
   group OID into the env `*.tfvars`. Confirm the key secret
   (`AMNHealthcare-NR-Terraform-UserKey` in `co-wus2-newrelic-kv-p01`) and that APIM's
   managed identity has Key Vault `get`.
2. **Register the pipeline** in the ADO *Cloud Operations* project — see
   [`.ado/CREATE-PIPELINE-MANUAL.md`](.ado/CREATE-PIPELINE-MANUAL.md). Add approvers
   to the `newrelic-mcp-int` ADO Environment (CAB gate).
3. **Plan → Apply → Verify** via the pipeline (dev auto, int behind manual approval).
4. **Verify** — the pipeline runs `test-harness/Invoke-ApimSmokeTest.ps1`; also
   confirm the injected key's cross-subaccount reach (DECISIONS.md #1).
5. **Client cutover** — point the observability plugin's `.mcp.json` at the gateway
   URL (tracked in `amn-ops-ai-plugin-marketplace#170`). Merge only after Verify.

## Client config

```jsonc
"newrelic": {
  "type": "http",
  "url": "https://<gateway>/mcp/newrelic/<env>/mcp",
  "headers": { "Authorization": "Bearer ${NEWRELIC_MCP_TOKEN}" }
}
```
The token is an Entra bearer for the dedicated New Relic MCP app `api://<app-id>`
(same acquisition pattern as the model gateway). The `NEW_RELIC_API_KEY` env var
can be dropped from developer setup entirely.
