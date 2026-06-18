# Upsert the operator-owned `pricing` doc (per-1k token rates) from the jumpbox via managed identity
# (Cosmos key-auth disabled + private endpoint). The worker (cost budget) + BFF (UI price labels)
# both read id="pricing". Operator edits prices here, then re-runs to publish. Idempotent (upsert).
#
# Prices = the confirmed per-1M values / 1000:
#   gpt-5.4         in $2.50/out $15   -> prompt 0.0025  / completion 0.015
#   gpt-5.4-mini    in $0.75/out $4.5  -> prompt 0.00075 / completion 0.0045
#   grok-4.3        in $1.25/out $2.5  -> prompt 0.00125 / completion 0.0025
#   DeepSeek-V4-Pro in $1.74/out $3.48 -> prompt 0.00174 / completion 0.00348
#
# Usage (controller invokes via az vm run-command):
#   .\seed-pricing-jumpbox.ps1 -Endpoint https://<account>.documents.azure.com:443/
param(
  [Parameter(Mandatory)] [string]$Endpoint,
  [string]$Database  = "gateway",
  [string]$Container = "config"
)
$ErrorActionPreference = "Stop"
$tok = (Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fcosmos.azure.com" -Headers @{Metadata = "true" }).access_token
$doc = [ordered]@{
  id       = "pricing"
  doc_type = "pricing"
  currency = "USD"
  unit     = "per_1k_tokens"
  models   = [ordered]@{
    "gpt-5.4"         = @{ prompt = 0.0025; completion = 0.015 }
    "gpt-5.4-mini"    = @{ prompt = 0.00075; completion = 0.0045 }
    "grok-4.3"        = @{ prompt = 0.00125; completion = 0.0025 }
    "DeepSeek-V4-Pro" = @{ prompt = 0.00174; completion = 0.00348 }
  }
} | ConvertTo-Json -Depth 6
$uri = "$($Endpoint.TrimEnd('/'))/dbs/$Database/colls/$Container/docs"
$h = @{
  Authorization                  = [System.Uri]::EscapeDataString("type=aad&ver=1.0&sig=$tok")
  "x-ms-date"                    = [DateTime]::UtcNow.ToString("r")
  "x-ms-version"                 = "2018-12-31"
  "x-ms-documentdb-is-upsert"    = "true"
  "x-ms-documentdb-partitionkey" = '["pricing"]'
}
Invoke-RestMethod -Method Post -Uri $uri -Headers $h -Body $doc -ContentType "application/json" | Out-Null
Write-Host "Upserted pricing doc into $Database/$Container :"
Write-Host $doc
