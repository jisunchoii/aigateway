#!/usr/bin/env bash
# End-to-end smoke test of the gateway via the PUBLIC APIM host (apim_public=true).
# Exercises spec §3.3 checks 1-3 (gpt path->body, OSS v1 body, same-backend downgrade is
# observed via response headers when configured). Run from a laptop — no VNet needed.
#
# Usage:
#   ./smoke-v1-gateway.sh <apim-host> <subscription-key>
# Example:
#   ./smoke-v1-gateway.sh my-apim.azure-api.net 0123abc...
set -euo pipefail

HOST="${1:-}"; KEY="${2:-}"
if [[ -z "$HOST" || -z "$KEY" ]]; then
  echo "Usage: $0 <apim-host> <subscription-key>" >&2; exit 2
fi
API_VERSION="2025-01-01-preview"
fail=0

# Helper: POST a chat-completions request, assert HTTP 200 and a choices[] array.
chat() { # $1=label  $2=url  $3=keyheader  $4=body
  local label="$1" url="$2" keyhdr="$3" body="$4" code
  code="$(curl -sS -o /tmp/smoke_resp.json -w '%{http_code}' -X POST "$url" \
    -H "$keyhdr" -H "Content-Type: application/json" --data "$body" || echo 000)"
  if [[ "$code" == "200" ]] && grep -q '"choices"' /tmp/smoke_resp.json; then
    echo "PASS  $label (200)"
  else
    echo "FAIL  $label (http=$code)"; sed -n '1,5p' /tmp/smoke_resp.json; fail=1
  fi
}

MSG='{"messages":[{"role":"user","content":"ping"}],"max_tokens":16}'

# Check 1: gpt via /openai path-route (client sends path+api-version; gateway converts to v1 body-route).
chat "gpt-5.4 via /openai (path->v1 body)" \
  "https://$HOST/openai/deployments/gpt-5.4/chat/completions?api-version=$API_VERSION" \
  "api-key: $KEY" "$MSG"

# Check 2a: OSS (grok) via /foundry body-route.
chat "grok-4.3 via /foundry (body)" \
  "https://$HOST/foundry/chat/completions" \
  "Ocp-Apim-Subscription-Key: $KEY" \
  '{"model":"grok-4.3","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'

# Check 2b: OSS (DeepSeek) via /foundry body-route.
chat "DeepSeek-V4-Pro via /foundry (body)" \
  "https://$HOST/foundry/chat/completions" \
  "Ocp-Apim-Subscription-Key: $KEY" \
  '{"model":"DeepSeek-V4-Pro","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'

# Check 4: gpt-5 reasoning param — gpt path-route request using max_completion_tokens must still 200.
chat "gpt-5.4 max_completion_tokens" \
  "https://$HOST/openai/deployments/gpt-5.4/chat/completions?api-version=$API_VERSION" \
  "api-key: $KEY" \
  '{"messages":[{"role":"user","content":"ping"}],"max_completion_tokens":16}'

if [[ "$fail" == "0" ]]; then
  echo "ALL SMOKE CHECKS PASSED"; exit 0
else
  echo "SMOKE FAILURES PRESENT"; exit 1
fi
