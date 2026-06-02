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

### Automated Setup (Recommended)

Use the automated setup script to create the variable group:

**Bash (Linux/Mac/WSL):**
```bash
# Login to Azure
az login

# Install Azure DevOps extension
az extension add --name azure-devops

# Run setup script
./.ado/scripts/create-variable-group.sh
```

**PowerShell (Windows):**
```powershell
# Login to Azure
az login

# Install Azure DevOps extension
az extension add --name azure-devops

# Run setup script
.\.ado\scripts\create-variable-group.ps1
```

The script will:
- ✅ Create or find Entra app registration `api://newrelic-mcp-reader`
- ✅ Retrieve New Relic API key from Key Vault
- ✅ Create ADO variable group `newrelic-mcp-apim-vars`
- ✅ Prompt for service principal and APIM configuration
- ✅ Authorize variable group for pipeline use

### Manual Setup

See detailed manual setup instructions: [.ado/SETUP.md](.ado/SETUP.md)

### Create ADO Pipeline

1. **Create Pipeline:**
   - Go to Azure DevOps → CloudOps project
   - Pipelines → New Pipeline
   - Choose GitHub → Select `AMNEngineering/newrelic-mcp-apim`
   - Select existing YAML: `.ado/pipelines/deploy.yml`
   - Variable group automatically linked (if using automated setup)
   - Save (don't run yet)

2. **First Run (Plan):**
   - Environment: `dev`
   - Action: `plan`
   - Review Terraform plan output

3. **Deploy (Apply):**
   - Environment: `dev`
   - Action: `apply`
   - Pipeline will:
     - Run `terraform apply`
     - Apply APIM policy
     - Test endpoint
     - Output endpoint URL

4. **Verify Deployment:**
   - Check pipeline output for endpoint URL
   - Review APIM portal for API and policy
   - Test endpoint (see below)

### Test Deployment

```bash
# Get token
TOKEN=$(az account get-access-token --resource api://newrelic-mcp-reader --query accessToken -o tsv)

# Test MCP endpoint
curl -X POST "https://api.amnhealthcare.io/mcp/newrelic/dev/mcp/" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"capabilities/list","id":1}'
```

Expected response: MCP capabilities list with New Relic tools.

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
