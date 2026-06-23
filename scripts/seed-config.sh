#!/usr/bin/env bash
# Seed the authoritative gateway config document into Cosmos DB (passwordless).
# Cosmos has public access disabled and key auth disabled, so data-plane writes must use
# Entra ID auth from inside the VNet (jumpbox) OR the Azure portal Data Explorer.
set -euo pipefail

COSMOS_ENDPOINT="${1:-}"   # terraform output: config_store endpoint
DATABASE="${2:-gateway}"
CONTAINER="${3:-config}"

if [[ -z "$COSMOS_ENDPOINT" ]]; then
  echo "Usage: $0 <CosmosEndpoint> [Database] [Container]" >&2
  exit 1
fi

read -r -d '' doc <<'JSON' || true
{
  "id": "global",
  "allowed_models": [
    "gpt-5.4",
    "gpt-5.4-mini",
    "grok-4.3",
    "DeepSeek-V4-Pro"
  ],
  "tokens_per_minute": 1000,
  "token_quota": 50000,
  "token_quota_period": "Daily"
}
JSON

echo "Canonical config document for $COSMOS_ENDPOINT  ->  $DATABASE/$CONTAINER :"
echo ""
echo "$doc"
echo ""
echo "To seed it (Cosmos is private + key-auth-disabled — choose one):"
echo "  A) Azure portal -> the Cosmos account -> Data Explorer -> gateway/config -> New Item -> paste the JSON above."
echo "  B) From the jumpbox (inside the VNet), with an identity holding 'Cosmos DB Built-in Data Contributor',"
echo "     run ./seed-cosmos-jumpbox.sh to upsert the document via the VM managed identity."
echo ""
echo "The config-sync job reads id='global' and pushes these values to the APIM named values."
