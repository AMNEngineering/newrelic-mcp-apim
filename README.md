# New Relic MCP behind APIM

> **Un-deprecated 2026-07-30.** This is the **default** New Relic MCP install
> path for AMN engineers on APIM-backed Claude and GitHub Copilot clients. See
> [`DEPRECATION.md`](DEPRECATION.md) for the status history. The 2026-07-29
> soft-deprecation was reversed after clarification that most AMN users continue
> to route Claude Code through APIM and centralized KV-key custody is preferred
> over per-user OAuth for that population. Client-side install lives in
> [`client/`](client/); server-side infrastructure below.

APIM gateway that fronts New Relic's hosted MCP server so AI-assisted developers
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

Rides the shared **AI-API-RR** edge route (`/ai/*`) per the AMN EdgeTopology
standard — see [`docs/topology.md`](docs/topology.md).

```
MCP client (Claude Code, Copilot CLI/App, VS Code, ...)
  │  GET https://api.{env}.amnhealthcare.io/ai/new-relic-mcp/{env}
  │  Authorization: Bearer <Entra JWT>   (aud = NR MCP app; member of the NR MCP AD group)
  ▼
AFD  amn-wus2-hub-afd-{env}01   route AI-API-RR (/ai/*)   [TLS, WAF, DDoS]
  ▼
AGW  amn-wus2-hub-agw-{env}01   path /ai/*  [WAF 2nd pass]
  ▼
APIM  amn-wus2-hub-apim-{env}02  (internal mode — no public host)
  API: api-new-relic-mcp-{env}   type=mcp   path: ai/new-relic-mcp/{env}   (native MCP, like amn-passport-mcp)
  │  inbound: validate-azure-ad-token (dual audience) + AD group-membership gate (groups claim)
  │  inbound: audit (x-apim-user-id, x-correlation-id)
  │  inbound: rate-limit-by-key (per user OID)          ← flood/cost guardrail
  │  inbound: strip Authorization, inject Api-Key {{nv-newrelic-mcp-api-key}}  ← from Key Vault
  │  (routing native to type=mcp — backendId + mcpProperties; no response buffering)
  ▼
https://mcp.newrelic.com/mcp/          New Relic hosted MCP (external SaaS — APIM egresses out)
```

## Layout

```
infrastructure/          Terraform root (main/variables/outputs/backend)
  environments/{dev,int,prod}.tfvars
  modules/{named-values, mcp-api, mcp-policy}   (mcp-api/mcp-policy are azapi — type=mcp)
policies/
  apim-policy-newrelic-mcp.xml   JWT + AD group gate + rate limit + Api-Key injection
.ado/pipelines/deploy.yml        Build → Plan → Apply (CAB-gated) → Verify, per env
identity/                        app-registration + access-group bootstrap (New-NewRelicMcpAppReg.ps1)
docs/topology.md                 per-project edge view (AFD → AGW → APIM), EdgeTopology model
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
  "url": "https://api.<env>.amnhealthcare.io/ai/new-relic-mcp/<env>",
  "headers": { "Authorization": "Bearer ${NEWRELIC_MCP_TOKEN}" }
}
```
The token is an Entra bearer for the dedicated New Relic MCP app `api://<app-id>`
(same acquisition pattern as the model gateway). The `NEW_RELIC_API_KEY` env var
can be dropped from developer setup entirely.

**Connecting any MCP client** (Claude Code, Copilot CLI/App, VS Code, Copilot Studio, curl) — see
[`docs/CONNECT-MCP-CLIENT.md`](docs/CONNECT-MCP-CLIENT.md) for endpoint URLs, token
acquisition, the access-group requirement, and per-client config snippets.

## Merge gate

Pull requests follow the
[AMN GitHub merge-gate standard](https://github.com/AMNEngineering/github-merge-bdd-ci/blob/main/STANDARD.md).
Run the hosted-safe Pester gate locally with:

```powershell
pwsh -File ./Run-Tests.ps1
```

GitHub Actions also runs the same suite under Windows PowerShell 5.1. Live
Azure and network checks are tagged `Integration` and excluded from the
blocking `gate` job.
