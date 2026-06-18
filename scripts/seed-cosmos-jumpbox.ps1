# Seed the authoritative gateway config document into Cosmos DB from the jumpbox,
# using ONLY PowerShell + the VM's managed identity. No Python, no winget, no internet
# egress: the MI token comes from IMDS (169.254.169.254) and Cosmos is reached over its
# private endpoint inside the VNet. Cosmos has key auth disabled, so this uses an Entra ID
# (aad) bearer token in the REST Authorization header.
#
# The jumpbox MI must hold "Cosmos DB Built-in Data Contributor" on the account (data-plane
# RBAC propagation can take a few minutes after the assignment).
#
# Usage (paste into PowerShell on the jumpbox):
#   .\seed-cosmos-jumpbox.ps1 -Endpoint https://<account>.documents.azure.com:443/
param(
  [Parameter(Mandatory)] [string]$Endpoint,
  [string]$Database  = "gateway",
  [string]$Container = "config"
)
$ErrorActionPreference = "Stop"

# 1) Get a managed-identity token for the Cosmos data-plane audience from IMDS.
$imds = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fcosmos.azure.com"
$token = (Invoke-RestMethod -Uri $imds -Headers @{ Metadata = "true" }).access_token

# 2) Build the AAD authorization header: type=aad&ver=1.0&sig=<oauth token>, URL-encoded.
$authHeader = [System.Uri]::EscapeDataString("type=aad&ver=1.0&sig=$token")

$date = [System.DateTime]::UtcNow.ToString("r")  # RFC1123 GMT, e.g. "Tue, 01 Nov 1994 08:12:31 GMT"

# 3) Upsert the document (POST to the docs collection with the is-upsert header).
$doc = @{
  id                 = "global"
  allowed_models     = @("gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro")
  tokens_per_minute  = 1000
  token_quota        = 50000
  token_quota_period = "Daily"
} | ConvertTo-Json -Depth 5

$uri = "$($Endpoint.TrimEnd('/'))/dbs/$Database/colls/$Container/docs"
$headers = @{
  Authorization                       = $authHeader
  "x-ms-date"                         = $date
  "x-ms-version"                      = "2018-12-31"
  "x-ms-documentdb-is-upsert"         = "true"
  "x-ms-documentdb-partitionkey"      = '["global"]'
}

$resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $doc -ContentType "application/json"
Write-Host "Upserted config doc id='global' into $Database/$Container :"
$resp | ConvertTo-Json -Depth 5
