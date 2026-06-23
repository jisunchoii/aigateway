#!/usr/bin/env bash
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
#   ./seed-pricing-jumpbox.sh https://<account>.documents.azure.com:443/
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

tok="$(curl -sS -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fcosmos.azure.com" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

if [[ -z "$tok" ]]; then
  echo "Failed to acquire managed-identity token from IMDS." >&2
  exit 1
fi

read -r -d '' doc <<'JSON' || true
{
  "id": "pricing",
  "doc_type": "pricing",
  "currency": "USD",
  "unit": "per_1k_tokens",
  "models": {
    "gpt-5.4":         { "prompt": 0.0025,  "completion": 0.015 },
    "gpt-5.4-mini":    { "prompt": 0.00075, "completion": 0.0045 },
    "grok-4.3":        { "prompt": 0.00125, "completion": 0.0025 },
    "DeepSeek-V4-Pro": { "prompt": 0.00174, "completion": 0.00348 }
  }
}
JSON

uri="${ENDPOINT%/}/dbs/$DATABASE/colls/$CONTAINER/docs"
authHeader="$(urlencode "type=aad&ver=1.0&sig=$tok")"
date_hdr="$(LC_ALL=C TZ=GMT date +"%a, %d %b %Y %H:%M:%S GMT")"

curl -sS -X POST "$uri" \
  -H "Authorization: $authHeader" \
  -H "x-ms-date: $date_hdr" \
  -H "x-ms-version: 2018-12-31" \
  -H "x-ms-documentdb-is-upsert: true" \
  -H 'x-ms-documentdb-partitionkey: ["pricing"]' \
  -H "Content-Type: application/json" \
  --data "$doc" >/dev/null

echo "Upserted pricing doc into $DATABASE/$CONTAINER :"
echo "$doc"
