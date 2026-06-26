#!/usr/bin/env bash
# Direct backend smoke test (run on the jumpbox, inside the VNet). Confirms the AIServices
# account answers the GA OpenAI/v1 route with an MI token — isolates backend issues from the
# APIM policy. Cosmos-style IMDS token, cognitiveservices audience.
#
# Usage (on jumpbox):
#   ./smoke-v1-backend.sh https://ais-xxxx.openai.azure.com/openai/v1
set -euo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "Usage: $0 <aiservices-openai-v1-base>" >&2; exit 2
fi

imds="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fcognitiveservices.azure.com"
token="$(curl -sS -H "Metadata: true" "$imds" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
if [[ -z "$token" ]]; then echo "Failed to get MI token from IMDS." >&2; exit 1; fi

code="$(curl -sS -o /tmp/smoke_be.json -w '%{http_code}' -X POST "${BASE%/}/chat/completions" \
  -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  --data '{"model":"gpt-5.4","messages":[{"role":"user","content":"ping"}],"max_completion_tokens":16}' || echo 000)"

if [[ "$code" == "200" ]] && grep -q '"choices"' /tmp/smoke_be.json; then
  echo "PASS  backend direct v1 (200)"; exit 0
else
  echo "FAIL  backend direct v1 (http=$code)"; sed -n '1,5p' /tmp/smoke_be.json; exit 1
fi
