# Create ADO Pipeline for New Relic MCP APIM deployment
# Prerequisites: az login, az devops extension installed

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Creating ADO Pipeline in Cloud Operations" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Configuration
$OrgUrl = "https://dev.azure.com/AMNEngineering"
$Project = "Cloud Operations"
$PipelineName = "newrelic-mcp-apim"
$RepoName = "AMNEngineering/newrelic-mcp-apim"
$YamlPath = ".ado/pipelines/deploy.yml"
$Branch = "master"

# Get project ID
Write-Host "Getting project ID..." -ForegroundColor Yellow
$ProjectId = az devops project show --project $Project --org $OrgUrl --query id -o tsv
Write-Host "✅ Project ID: $ProjectId" -ForegroundColor Green

# Get GitHub service connection
Write-Host "Getting GitHub service connection..." -ForegroundColor Yellow
$ServiceConnections = az devops service-endpoint list --org $OrgUrl --project $Project --query "[?type=='github']" | ConvertFrom-Json

if ($ServiceConnections.Count -eq 0) {
    Write-Host "❌ No GitHub service connections found in Cloud Operations project" -ForegroundColor Red
    Write-Host "Please create a GitHub service connection first or use the Azure DevOps portal to create the pipeline manually." -ForegroundColor Yellow
    exit 1
}

$GitHubConnection = $ServiceConnections[0]
$ServiceConnectionId = $GitHubConnection.id
Write-Host "✅ Using GitHub connection: $($GitHubConnection.name) (ID: $ServiceConnectionId)" -ForegroundColor Green

# Check if pipeline already exists
Write-Host "Checking if pipeline already exists..." -ForegroundColor Yellow
$ExistingPipeline = az pipelines list --org $OrgUrl --project $Project --query "[?name=='$PipelineName']" | ConvertFrom-Json

if ($ExistingPipeline.Count -gt 0) {
    Write-Host "⚠️  Pipeline '$PipelineName' already exists (ID: $($ExistingPipeline[0].id))" -ForegroundColor Yellow
    $Overwrite = Read-Host "Delete and recreate? (y/N)"
    if ($Overwrite -match "^[Yy]$") {
        Write-Host "Deleting existing pipeline..." -ForegroundColor Yellow
        az pipelines delete --id $ExistingPipeline[0].id --org $OrgUrl --project $Project --yes
        Write-Host "✅ Deleted existing pipeline" -ForegroundColor Green
    } else {
        Write-Host "Exiting. Pipeline already exists." -ForegroundColor Yellow
        Write-Host "URL: $OrgUrl/$Project/_build?definitionId=$($ExistingPipeline[0].id)" -ForegroundColor Cyan
        exit 0
    }
}

# Create pipeline definition
Write-Host "Creating pipeline definition..." -ForegroundColor Yellow

$PipelineDefinition = @{
    name = $PipelineName
    type = "build"
    quality = "definition"
    path = "\"
    process = @{
        type = 2
        yamlFilename = $YamlPath
    }
    repository = @{
        type = "GitHub"
        name = $RepoName
        url = "https://github.com/$RepoName.git"
        defaultBranch = "refs/heads/$Branch"
        properties = @{
            connectedServiceId = $ServiceConnectionId
            apiUrl = "https://api.github.com/repos/$RepoName"
            branchesUrl = "https://api.github.com/repos/$RepoName/branches"
            cloneUrl = "https://github.com/$RepoName.git"
            fullName = $RepoName
            refsUrl = "https://api.github.com/repos/$RepoName/git/refs"
        }
    }
    queue = @{
        name = "Azure Pipelines"
    }
} | ConvertTo-Json -Depth 10

# Create pipeline using REST API
Write-Host "Creating pipeline via ADO Build Definitions API..." -ForegroundColor Yellow

$Headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv)"
}

$Uri = "$OrgUrl/$ProjectId/_apis/build/definitions?api-version=6.0"

try {
    $Response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $PipelineDefinition -ContentType "application/json"

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "✅ Pipeline Created Successfully" -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pipeline Name: $($Response.name)" -ForegroundColor Cyan
    Write-Host "Pipeline ID: $($Response.id)" -ForegroundColor Cyan
    Write-Host "Folder: $($Response.folder)" -ForegroundColor Cyan
    Write-Host "YAML Path: $($Response.configuration.path)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pipeline URL: $OrgUrl/$Project/_build?definitionId=$($Response.id)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Run: .\.ado\scripts\create-variable-group.ps1 (if not already done)"
    Write-Host "  2. Go to pipeline URL above"
    Write-Host "  3. Click 'Run pipeline'"
    Write-Host "  4. Select environment: dev, action: plan"
    Write-Host "  5. Review plan output"
    Write-Host "  6. Run again with action: apply to deploy"
    Write-Host ""

} catch {
    Write-Host "❌ Failed to create pipeline" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

    if ($_.Exception.Response) {
        $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $Reader.BaseStream.Position = 0
        $ResponseBody = $Reader.ReadToEnd()
        Write-Host "Response: $ResponseBody" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "You can create the pipeline manually:" -ForegroundColor Yellow
    Write-Host "  1. Go to: $OrgUrl/$Project/_build" -ForegroundColor Yellow
    Write-Host "  2. New Pipeline → GitHub → $RepoName" -ForegroundColor Yellow
    Write-Host "  3. Select existing YAML: $YamlPath" -ForegroundColor Yellow
    Write-Host "  4. Save (don't run yet)" -ForegroundColor Yellow
    exit 1
}
