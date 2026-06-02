# New Relic MCP APIM Proxy

APIM proxy for New Relic MCP server that centralizes API key management and provides Entra ID authentication for Claude Code developers.

## Architecture

```
Developer (Claude Code)
  → Azure CLI JWT token (api://newrelic-mcp-reader)
    → APIM Gateway
      → Validates JWT
      → Rate limits (300 calls/min per user)
      → Strips JWT, injects NR API key
      → Routes to mcp.newrelic.com
```

## Repository Structure

```
.
├── .ado/pipelines/
│   └── deploy.yml              # ADO deployment pipeline
├── terraform/
│   ├── main.tf                 # APIM infrastructure
│   └── terraform.tfvars.example
├── apim-policy-newrelic-mcp.xml # APIM policy contract
├── examples/
│   └── client-config.json      # Developer .mcp.json template
└── skill/
    └── skill.md                # Updated New Relic skill docs
```

## Deployment

### Prerequisites

1. **Entra App Registration:**
   - Create app with identifier URI: `api://newrelic-mcp-reader`
   - Note the application (client) ID

2. **New Relic API Key:**
   - Retrieve from Key Vault: `co-wus2-newrelic-kv-p01`
   - Secret name: `NewRelic-AMNHealthcare-AMN-Ops-AI-Plugin-Marketplace`
   - Format: `NRAK-...`

3. **ADO Variable Group:**
   - Create variable group in CloudOps project
   - Add variables:
     - `ARM_CLIENT_ID` - Service principal ID
     - `ARM_CLIENT_SECRET` - Service principal secret (secret)
     - `ARM_SUBSCRIPTION_ID` - Target subscription
     - `ARM_TENANT_ID` - AMN tenant ID
     - `TF_STATE_RESOURCE_GROUP` - Terraform state RG
     - `TF_STATE_STORAGE_ACCOUNT` - Terraform state storage
     - `TF_STATE_CONTAINER` - Terraform state container
     - `APIM_NAME` - Target APIM instance name (e.g., `apim-amnhealthcare-dev`)
     - `APIM_RESOURCE_GROUP` - APIM resource group
     - `NEWRELIC_MCP_APP_ID` - App registration ID from step 1
     - `NEWRELIC_API_KEY` - New Relic API key (secret)

### Pipeline Deployment

1. **Create ADO Pipeline:**
   - Go to Azure DevOps → CloudOps project
   - Pipelines → New Pipeline
   - Choose GitHub → Select `AMNEngineering/newrelic-mcp-apim`
   - Select existing YAML: `.ado/pipelines/deploy.yml`
   - Link variable group created in prerequisites

2. **Run Pipeline:**
   - Select environment: `dev`, `staging`, or `prod`
   - Select action: `plan` (first run) or `apply` (deploy)
   - Pipeline will:
     - Run `terraform plan/apply`
     - Apply APIM policy
     - Test endpoint
     - Publish outputs

3. **Verify Deployment:**
   - Check pipeline output for endpoint URL
   - Review APIM portal for API and policy
   - Test with: `az account get-access-token --resource api://newrelic-mcp-reader`

## Developer Setup

1. **Copy client config:**
   ```bash
   cp examples/client-config.json ~/.claude/.mcp.json
   # or project-level: .mcp.json
   ```

2. **Login to Azure:**
   ```bash
   az login
   ```

3. **Test in Claude Code:**
   ```
   > Show me recent APIM logs from New Relic
   ```

## Security

- **Client → APIM:** Entra JWT validation
- **APIM → New Relic:** API key from named value (secret)
- **Rate Limiting:** 300 calls/min per user
- **Audit Logging:** APIM Analytics captures user identity, correlation ID, queries

## Support

- **Slack:** #cloudops-ai-platform
- **Issues:** Contact CloudOps team
- **New Relic Account:** Shared Services (6264783)
