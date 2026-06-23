#!/usr/bin/env bash
# Seed the authoritative gateway config document into Cosmos DB from the jumpbox,
# using ONLY the VM's managed identity. No Python, no internet egress: the MI token
# comes from IMDS (169.254.169.254) and Cosmos is reached over its private endpoint
# inside the VNet. Cosmos has key auth disabled, so this uses an Entra ID (aad) bearer
# token in the REST Authorization header.
#
# The jumpbox MI must hold "Cosmos DB Built-in Data Contributor" on the account (data-plane
# RBAC propagation can take a few minutes after the assignment).
#
# Usage (run in bash on the jumpbox):
#   ./seed-cosmos-jumpbox.sh https://<account>.documents.azure.com:443/
set -euo pipefail

ENDPOINT="${1:-}"
DATABASE="${2:-gateway}"
CONTAINER="${3:-config}"

if [[ -z "$ENDPOINT" ]]; then
  echo "Usage: $0 <Endpoint> [Database] [Container]" >&2
  exit 1
fi

# RFC3986 URL-encode helper (ASCII; JWT tokens are ASCII-safe).
urlencode() {
  local s="$1" i c out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# 1) Get a managed-identity token for the Cosmos data-plane audience from IMDS.
imds="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fcosmos.azure.com"
token="$(curl -sS -H "Metadata: true" "$imds" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

if [[ -z "$token" ]]; then
  echo "Failed to acquire managed-identity token from IMDS." >&2
  exit 1
fi

# 2) Build the AAD authorization header: type=aad&ver=1.0&sig=<oauth token>, URL-encoded.
authHeader="$(urlencode "type=aad&ver=1.0&sig=$token")"

# RFC1123 GMT, e.g. "Tue, 01 Nov 1994 08:12:31 GMT"
date_hdr="$(LC_ALL=C TZ=GMT date +"%a, %d %b %Y %H:%M:%S GMT")"

# 3) Upsert the document (POST to the docs collection with the is-upsert header).
read -r -d '' doc <<'JSON' || true
{
  "id": "global",
  "allowed_models": ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"],
  "tokens_per_minute": 1000,
  "token_quota": 50000,
  "token_quota_period": "Daily"
}
JSON

uri="${ENDPOINT%/}/dbs/$DATABASE/colls/$CONTAINER/docs"

resp="$(curl -sS -X POST "$uri" \
  -H "Authorization: $authHeader" \
  -H "x-ms-date: $date_hdr" \
  -H "x-ms-version: 2018-12-31" \
  -H "x-ms-documentdb-is-upsert: true" \
  -H 'x-ms-documentdb-partitionkey: ["global"]' \
  -H "Content-Type: application/json" \
  --data "$doc")"

echo "Upserted config doc id='global' into $DATABASE/$CONTAINER :"
echo "$resp"
