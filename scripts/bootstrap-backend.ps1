# One-time bootstrap of the remote Terraform state backend.
# Run once per subscription before `terraform init`.
param(
  [string]$Location      = "eastus2",
  [string]$BackendRg     = "",
  [string]$StoragePrefix = "staigwtfstate",
  [string]$StateKey      = "ai-gateway-eus2.tfstate"
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($BackendRg)) {
  $BackendRg = "rg-aigw-tfstate-dev-$Location"
}
if ($StoragePrefix.Length + 6 -gt 24) {
  Write-Error "StoragePrefix must be <= 18 characters (leaves room for a 6-char suffix)."
  exit 1
}
$suffix  = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object {[char]$_})
$account = "$StoragePrefix$suffix"   # storage names: lowercase+digits, <=24 chars

az group create --name $BackendRg --location $Location | Out-Null
# NOTE: the Terraform state backend is OPERATOR infrastructure, not the gateway itself.
# It must be reachable from wherever you run `terraform` (e.g. a workstation outside the VNet),
# so public network access is Enabled. Anonymous/public blob access stays disabled
# (--allow-blob-public-access false), so Entra ID auth is still required to read/write state.
# Some subscription policies default storage to public-access Disabled; set it explicitly here
# to avoid a 403 "not authorized" at `terraform init`/`apply` time.
az storage account create `
  --name $account --resource-group $BackendRg --location $Location `
  --sku Standard_LRS --kind StorageV2 `
  --allow-blob-public-access false --min-tls-version TLS1_2 `
  --public-network-access Enabled | Out-Null
$upn = az account show --query user.name -o tsv
$subId = az account show --query id -o tsv
az role assignment create `
  --role "Storage Blob Data Contributor" `
  --assignee $upn `
  --scope "/subscriptions/$subId/resourceGroups/$BackendRg/providers/Microsoft.Storage/storageAccounts/$account" | Out-Null
Start-Sleep -Seconds 15   # allow role assignment to propagate before container create
az storage container create `
  --name tfstate --account-name $account --auth-mode login | Out-Null

Write-Host "Backend ready. Put these in infra/providers.tf backend block:"
Write-Host "  resource_group_name  = `"$BackendRg`""
Write-Host "  storage_account_name = `"$account`""
Write-Host "  container_name       = `"tfstate`""
Write-Host "  key                  = `"$StateKey`""
