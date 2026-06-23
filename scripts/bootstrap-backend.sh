#!/usr/bin/env bash
# One-time bootstrap of the remote Terraform state backend.
# Run once per subscription before `terraform init`.
#
# Usage:
#   ./bootstrap-backend.sh \
#     --location eastus2 \
#     --backend-rg rg-aigw-tfstate-dev-eastus2 \
#     --storage-prefix staigwtfstate \
#     --state-key ai-gateway-eus2.tfstate
# set -euo pipefail

LOCATION="koreacentral"
BACKEND_RG="rg-llmgw-tfstate-dev-koreacentral"
STORAGE_PREFIX="stllmgwtfstate"
STATE_KEY="llm-gateway.tfstate"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)       LOCATION="$2";       shift 2 ;;
    --backend-rg)     BACKEND_RG="$2";     shift 2 ;;
    --storage-prefix) STORAGE_PREFIX="$2"; shift 2 ;;
    --state-key)      STATE_KEY="$2";      shift 2 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1 ;;
  esac
done

if (( ${#STORAGE_PREFIX} + 6 > 24 )); then
  echo "StoragePrefix must be <= 18 characters (leaves room for a 6-char suffix)." >&2
  exit 1
fi

# storage names: lowercase+digits, <=24 chars
suffix="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
account="${STORAGE_PREFIX}${suffix}"

az group create --name "$BACKEND_RG" --location "$LOCATION"

# NOTE: the Terraform state backend is OPERATOR infrastructure, not the gateway itself.
# It must be reachable from wherever you run `terraform` (e.g. a workstation outside the VNet),
# so public network access is Enabled. Anonymous/public blob access stays disabled
# (--allow-blob-public-access false), so Entra ID auth is still required to read/write state.
# Some subscription policies default storage to public-access Disabled; set it explicitly here
# to avoid a 403 "not authorized" at `terraform init`/`apply` time.
az storage account create \
  --name "$account" --resource-group "$BACKEND_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --min-tls-version TLS1_2 \
  --public-network-access Enabled

oid=$(az ad signed-in-user show --query id -o tsv)
subId="$(az account show --query id -o tsv)"
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "$oid" \
  --scope "/subscriptions/$subId/resourceGroups/$BACKEND_RG/providers/Microsoft.Storage/storageAccounts/$account"

sleep 15   # allow role assignment to propagate before container create
az storage container create \
  --name tfstate --account-name "$account" --auth-mode login >/dev/null

# Auto-update infra/providers.tf backend "azurerm" block with the values above.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_TF="$SCRIPT_DIR/../infra/providers.tf"
if [[ -f "$PROVIDERS_TF" ]] && grep -q 'backend "azurerm"' "$PROVIDERS_TF"; then
  sed -i -E \
    -e "s|^([[:space:]]*resource_group_name[[:space:]]*=[[:space:]]*).*|\1\"$BACKEND_RG\"|" \
    -e "s|^([[:space:]]*storage_account_name[[:space:]]*=[[:space:]]*).*|\1\"$account\"|" \
    -e "s|^([[:space:]]*container_name[[:space:]]*=[[:space:]]*).*|\1\"tfstate\"|" \
    -e "s|^([[:space:]]*key[[:space:]]*=[[:space:]]*).*|\1\"$STATE_KEY\"|" \
    "$PROVIDERS_TF"
  echo "Updated backend block in $PROVIDERS_TF."
else
  echo "WARNING: could not find $PROVIDERS_TF with a backend \"azurerm\" block; update it manually." >&2
fi

echo "Backend ready. Values written to infra/providers.tf backend block:"
echo "  resource_group_name  = \"$BACKEND_RG\""
echo "  storage_account_name = \"$account\""
echo "  container_name       = \"tfstate\""
echo "  key                  = \"$STATE_KEY\""
