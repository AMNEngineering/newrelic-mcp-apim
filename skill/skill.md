---
name: new-relic-observability
version: 1.0.0
summary: Query logs, metrics, and alerts from New Relic via AMN-managed APIM proxy. Developers authenticate with Entra ID; APIM centrally manages the New Relic API key. Use for incident investigation, deployment validation, alert monitoring, and APIM gateway diagnostics.
whenToUse:
  - Investigate errors, latency, or failures in any AMN service after a deployment
  - Query APIM gateway logs for request diagnostics (status codes, backend responses, correlation IDs)
  - Verify synthetic monitors and alert policies are in place for new endpoints
  - Check active alert conditions and open violations
  - Correlate Azure Event Hub diagnostic log ingestion with NR Log data
  - Support post-deployment smoke test validation with real telemetry
  - Any time the user asks "what do the logs say" or "is there anything in New Relic"
integrates-with:
  - apim-foundry-backend-onboarding
  - mcp-apim-onboarding
  - new-relic-observability-guardrails
---

# New Relic Observability Skill

## What Changed (v1.0.0)

**New Relic MCP is now accessed via APIM proxy:**

- ✅ **No API keys in developer machines** - APIM manages the NR API key centrally
- ✅ **Entra ID authentication** - Developers auth with `az login`, no New Relic credentials needed
- ✅ **Centralized audit trail** - All NR queries logged in APIM Analytics with user identity
- ✅ **Rate limiting** - 300 calls/min per user (prevents runaway queries)
- ✅ **Single source of truth** - Key Vault `co-wus2-newrelic-kv-p01` → APIM → Developers

**Old way** (deprecated):
```json
{
  "mcpServers": {
    "newrelic": {
      "url": "https://mcp.newrelic.com/mcp/",
      "headers": {
        "Api-Key": "NRAK-..." // ❌ API key on every developer machine
      }
    }
  }
}
```

**New way** (use this):
```json
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://api.amnhealthcare.io/mcp/newrelic/dev/mcp/",
      "auth": {
        "type": "bearer",
        "token": {
          "command": "az",
          "args": ["account", "get-access-token", "--resource", "api://newrelic-mcp-reader", "--query", "accessToken", "-o", "tsv"]
        }
      }
    }
  }
}
```

---

## Developer Setup

### 1. Update `.mcp.json`

**Project-level** (recommended):
```bash
# Copy to your project
cp examples/client-config.json .mcp.json
```

**User-level** (applies to all projects):
```bash
# Copy to ~/.claude/
cp examples/client-config.json ~/.claude/.mcp.json
```

### 2. Login to Azure

```bash
az login
```

That's it! The APIM endpoint auto-refreshes your token and injects the NR API key.

---

## Purpose

New Relic is the **AMN source of record** for all observability: logs, metrics, traces, and alerts.
Azure Monitor, Application Insights, and Log Analytics are **disallowed** in AMN project resource groups.
All APIM gateway diagnostic logs are forwarded via Azure Event Hub to New Relic.

Always use the **New Relic MCP server tools** to query — do NOT attempt raw REST/GraphQL calls against `api.newrelic.com`. The MCP server handles authentication and account scoping correctly.

---

## AMN New Relic Account

| Field              | Value                                          |
|--------------------|------------------------------------------------|
| Account ID         | `6264783` (Shared Services - AMN IPS)          |
| Key Vault          | `co-wus2-newrelic-kv-p01`                      |
| KV Subscription    | AMN Intelligent Platform Services Prod         |
| Project API Key    | `NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace` (NRAK-...) |
| User Key (Terraform) | `AIEngineering-NR-Terraform-UserKey`        |
| APIM Log Ingestion | Azure Event Hub → `nr-eventhub-amnips`         |
| **APIM Proxy Endpoint** | `https://api.amnhealthcare.io/mcp/newrelic/{env}/mcp/` |

**Note:** All APIM instances (DEV/QA/INT/TRAIN/PROD) log to this single Shared Services account. Filter by `properties.url` to isolate project-specific logs.

> The key in `amn-wus2-hub-kv-d01` named `NewRelic-AMNIPS-Dev-AMNIntelligentPlatformServicesDev` is an **Azure client secret** (format `Z8.8Q~...`), NOT a NR key. Use `co-wus2-newrelic-kv-p01` for all NR keys.

---

## MCP Tool Usage

### Preferred: Natural Language
Use `mcp_newrelic_natural_language_to_nrql_query` when you want to describe what you're looking for:

```
Show me failed requests to the MCP codeveloperaifp01 endpoint in the last hour
```

### Direct NRQL
Use `mcp_newrelic_execute_nrql_query` for precise queries:

```nrql
SELECT * FROM Log
WHERE message LIKE '%codeveloperaifp01%'
SINCE 1 hour ago
LIMIT 50
```

---

## Common NRQL Patterns

*(Same as before - patterns unchanged)*

### APIM Gateway Logs

```nrql
-- All requests to a specific APIM API path
SELECT timestamp, requestMethod, requestUrl, responseCode, backendResponseCode, durationMs, correlationId
FROM Log
WHERE requestUrl LIKE '%mcp/codeveloperaifp01%'
   OR requestUrl LIKE '%ai/mcp/codeveloperaifp01%'
SINCE 2 hours ago
ORDER BY timestamp DESC
LIMIT 100
```

```nrql
-- APIM error rate by status code
SELECT count(*) FROM Log
WHERE responseCode >= 400
  AND requestUrl LIKE '%amnhealthcare%'
FACET responseCode
SINCE 1 hour ago
```

*(... rest of NRQL patterns from original skill.md ...)*

---

## Architecture

```
┌──────────────────┐
│ Developer        │
│ Claude Code      │
└────────┬─────────┘
         │ az login → JWT token (api://newrelic-mcp-reader)
         ↓
┌─────────────────────────────────────────────────────────┐
│                  APIM Gateway                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │ validate-azure-ad-token                           │  │
│  │ - Tenant: 6232c2ec-fa42-4f27-92cd-787913fba489    │  │
│  │ - Audience: api://newrelic-mcp-reader             │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Strip JWT, inject NR API key                      │  │
│  │ - Api-Key: {{nv-newrelic-mcp-api-key}}            │  │
│  │ - Rate limit: 300 calls/min per user              │  │
│  └───────────────────────────────────────────────────┘  │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTPS with Api-Key header
                       ↓
              ┌────────────────────┐
              │  New Relic MCP     │
              │  mcp.newrelic.com  │
              └────────────────────┘
```

---

## Security & Compliance

### Authentication Flow

1. **Developer → APIM:**
   - Developer runs `az login`
   - Claude Code gets JWT token for `api://newrelic-mcp-reader`
   - APIM validates token (tenant + audience + expiration)

2. **APIM → New Relic:**
   - APIM strips developer's JWT
   - APIM injects `Api-Key` from named value (secret, from Key Vault)
   - Request forwarded to `mcp.newrelic.com`

3. **No credentials on developer machines:**
   - Developers never see the NR API key
   - Key rotated centrally in APIM named value
   - Key source of truth: `co-wus2-newrelic-kv-p01`

### Audit Trail

**APIM Analytics captures:**
- User identity (oid/upn from JWT)
- Correlation ID
- Timestamp
- Request body (NRQL query)
- Response status

**Query APIM logs in New Relic:**
```nrql
SELECT timestamp, userOid, requestUrl, requestBody, responseCode
FROM Log
WHERE requestUrl LIKE '%mcp/newrelic%'
SINCE 1 hour ago
```

### Rate Limiting

- **300 calls/minute per user** (APIM enforced)
- Prevents runaway Claude Code loops
- Returns `429 Too Many Requests` + `Retry-After` header

### SOC2 Controls

- **CC6.1 (Logical Access):** Entra JWT validation
- **CC6.6 (Audit Logging):** APIM Analytics + user tracking
- **CC6.7 (Access Restrictions):** Rate limiting + centralized key management
- **CC8.1 (Monitoring):** APIM telemetry + NR queries logged

---

## Troubleshooting

### "401 Unauthorized" from APIM

**Cause:** Invalid/expired JWT token

**Fix:**
```bash
# Refresh token
az login

# Test token acquisition
az account get-access-token --resource api://newrelic-mcp-reader
```

### "403 Forbidden" from APIM

**Cause:** User not in authorized Entra group

**Fix:** Contact CloudOps to add you to the MCP access group

### "429 Too Many Requests"

**Cause:** Exceeded 300 calls/min rate limit

**Fix:** Wait for rate limit window to reset (shown in `Retry-After` header)

### "MCP capabilities/list fails"

**Cause:** APIM named value API key incorrect or expired

**Fix:** Platform team needs to update named value:
```bash
# Get key from Key Vault
NEW_API_KEY=$(az keyvault secret show \
  --vault-name co-wus2-newrelic-kv-p01 \
  --name NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace \
  --query value -o tsv)

# Update APIM named value
az apim nv update \
  --resource-group rg-apim-dev \
  --service-name apim-amnhealthcare-dev \
  --named-value-id nv-newrelic-mcp-api-key \
  --value "$NEW_API_KEY" \
  --secret true
```

---

## For Platform Teams

### Deployment

See repository: `https://github.com/AMNEngineering/newrelic-mcp-apim`

**One-time setup:**
1. Create Entra app registration: `api://newrelic-mcp-reader`
2. Get NR API key from Key Vault: `co-wus2-newrelic-kv-p01`
3. Run Terraform to create APIM API + Backend + Named Values
4. Apply APIM policy
5. Test endpoint

**Ongoing:**
- Rotate NR API key annually (update APIM named value)
- Monitor APIM Analytics for abuse
- Review rate limiting if 429 errors spike

### Monitoring

**Key metrics:**
- Request count per user (detect excessive queries)
- 401 rate (auth failures)
- 429 rate (rate limit exceeded)
- Latency to New Relic (network issues)

**Alerts:**
- 401 rate > 10% for 5 min → Auth configuration issue
- 429 rate > 20% for 5 min → Consider increasing rate limit
- P95 latency > 5s for 5 min → New Relic API degradation

---

## Guardrails

- Do NOT query Log Analytics or Application Insights — they are disallowed in AMN project resource groups.
- Do NOT create Azure Monitor alert rules — all alerts must be in New Relic.
- Do NOT use the NRAK key directly via REST/GraphQL — always use the APIM-proxied MCP endpoint.
- Always scope queries to the minimum time window needed.
- Redact sensitive values (tokens, secrets) from log query results before sharing.
- **New:** Do NOT put NR API keys in .mcp.json files (use APIM proxy instead)

---

## Migration from Direct MCP Access

If you have an old `.mcp.json` with direct `mcp.newrelic.com` access:

**Before:**
```json
{
  "mcpServers": {
    "newrelic": {
      "url": "https://mcp.newrelic.com/mcp/",
      "headers": {
        "Api-Key": "NRAK-..."
      }
    }
  }
}
```

**After:**
```json
{
  "mcpServers": {
    "newrelic": {
      "type": "http",
      "url": "https://api.amnhealthcare.io/mcp/newrelic/dev/mcp/",
      "auth": {
        "type": "bearer",
        "token": {
          "command": "az",
          "args": ["account", "get-access-token", "--resource", "api://newrelic-mcp-reader", "--query", "accessToken", "-o", "tsv"]
        }
      }
    }
  }
}
```

**Then:**
```bash
# Remove old API key from environment
unset NEW_RELIC_API_KEY

# Remove from .env files
# Delete from password managers

# Test new endpoint
claude
> Show me recent APIM logs
```

---

## Contact

**Questions:** #cloudops-ai-platform (Slack)  
**APIM Issues:** Contact CloudOps team  
**Repository:** https://github.com/AMNEngineering/newrelic-mcp-apim  
**New Relic Account:** Shared Services (6264783)
