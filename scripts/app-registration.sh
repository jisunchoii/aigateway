#!/usr/bin/env bash

# Admin Security Group
az ad group create \
  --display-name "AI Gateway Admins" \
  --mail-nickname "aigw-admins"

admin_group_object_id=$(az ad group show --group "AI Gateway Admins" --query id -o tsv)

# add yourself as a member
az ad group member add --group "AI Gateway Admins" \
  --member-id "$(az ad signed-in-user show --query id -o tsv)"

# BFF API app registration
bff_app_id=$(az ad app create --display-name "AI Gateway BFF API" --query appId -o tsv)
bff_obj_id=$(az ad app show --id "$bff_app_id" --query id -o tsv)

# identifier URI must be set before/with exposing scopes
az ad app update --id "$bff_app_id" --identifier-uris "api://$bff_app_id"

# build the api object (scope + v2 access tokens) and PATCH via Graph
scope_id=$(cat /proc/sys/kernel/random/uuid)
cat > /tmp/bff-api.json <<EOF
{
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [
      {
        "id": "$scope_id",
        "value": "access_as_user",
        "type": "User",
        "isEnabled": true,
        "adminConsentDisplayName": "Access AI Gateway as a user",
        "adminConsentDescription": "Allow the app to access the AI Gateway BFF API as the signed-in user.",
        "userConsentDisplayName": "Access AI Gateway",
        "userConsentDescription": "Allow the app to access the AI Gateway BFF API on your behalf."
      }
    ]
  }
}
EOF

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$bff_obj_id" \
  --headers "Content-Type=application/json" \
  --body @/tmp/bff-api.json

bff_api_audience="api://$bff_app_id"

az ad app update --id $bff_app_id \
  --set groupMembershipClaims=SecurityGroup

#  SPA public-client app registration
# If you don't have the Admin UI URL yet, use a placeholder and update later.
admin_ui_url="https://REPLACE-with-admin-ui-host"

spa_client_id=$(az ad app create --display-name "AI Gateway SPA" --query appId -o tsv)
spa_obj_id=$(az ad app show --id "$spa_client_id" --query id -o tsv)

# SPA redirect URIs (this platform implies PKCE + no client secret)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$spa_obj_id" \
  --headers "Content-Type=application/json" \
  --body "{\"spa\":{\"redirectUris\":[\"$admin_ui_url\"]}}"

echo "admin_group_object_id = \"$admin_group_object_id\""
echo "bff_api_audience = \"$bff_api_audience\""
echo "spa_client_id = \"$spa_client_id\""