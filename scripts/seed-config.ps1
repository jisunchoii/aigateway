# Seed the authoritative gateway config document into Cosmos DB (passwordless).
# Cosmos has public access disabled and key auth disabled, so data-plane writes must use
# Entra ID auth from inside the VNet (jumpbox) OR the Azure portal Data Explorer.
param(
  [Parameter(Mandatory)] [string]$CosmosEndpoint,   # terraform output: config_store endpoint
  [string]$Database  = "gateway",
  [string]$Container = "config"
)
$ErrorActionPreference = "Stop"

$doc = [ordered]@{
  id                 = "global"
  allowed_models     = @("gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro")
  tokens_per_minute  = 1000
  token_quota        = 50000
  token_quota_period = "Daily"
} | ConvertTo-Json -Depth 5

Write-Host "Canonical config document for $CosmosEndpoint  ->  $Database/$Container :"
Write-Host ""
Write-Host $doc
Write-Host ""
Write-Host "To seed it (Cosmos is private + key-auth-disabled — choose one):"
Write-Host "  A) Azure portal -> the Cosmos account -> Data Explorer -> gateway/config -> New Item -> paste the JSON above."
Write-Host "  B) From the jumpbox (inside the VNet), with an identity holding 'Cosmos DB Built-in Data Contributor',"
Write-Host "     use a short python azure-cosmos script with DefaultAzureCredential to upsert the document."
Write-Host ""
Write-Host "The config-sync job reads id='global' and pushes these values to the APIM named values."
