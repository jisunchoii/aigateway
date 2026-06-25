# Azure AI Gateway

An enterprise **AI gateway** built on Azure API Management. It places **Azure OpenAI**
(the gpt-5.4 family) and **Azure AI Foundry** (OSS/partner models such as grok-4.3 and
DeepSeek-V4-Pro) behind a single governance endpoint. All backends are passwordless
(managed identity), and it provides per-consumer model permissions, token rate limits, and
cost-based budget downgrade — all managed from a self-service Admin UI.

![Architecture](docs/images/architecture.png)

## What it provides

- **Bundles multiple model backends (Azure OpenAI + Foundry OSS/partner) behind one governance
  endpoint.** Each backend is reachable only over a **private endpoint** with **key auth disabled**,
  so APIM authenticates with its own managed identity — no model keys exist on the gateway.
- **Per-consumer governance** — edit it directly in the Admin UI with no redeploy:
  - **Allowed models** — a consumer can call only the models granted to it (anything else returns 403).
  - **Rate limits** — per-consumer TPM + token quota tiers (small/medium/large) → 429 when exceeded.
  - **Cost budget** — a daily **USD** spend limit. When exceeded, requests are
    **automatically downgraded** to a cheaper model along a configured ladder (cross-backend
    downgrade is also supported, e.g. gpt → OSS or OSS → gpt).
- **Self-service Admin UI** (React + FastAPI, Entra ID login, admin-group gated) — issue consumer
  keys, set model/limit/budget policies, and view the usage dashboard + request logs.
- **Observability** — per-call token metrics (consumer + requested/effective model dimensions) sent
  to Application Insights. The Admin UI provides a usage dashboard, request/blocked-event logs, and
  budget-downgrade events.
- **Client authentication** — APIM subscription key by default, or an Entra ID JWT (`client_auth_mode`).
  Client surfaces use different APIM subscription key header names:
  - Copilot CLI / Azure-provider clients: `/openai/...` with `api-key`.
  - VS Code BYOK custom endpoint: `/vscode/openai/...` with `Ocp-Apim-Subscription-Key`.
  - Direct Foundry body-route API: `/foundry/...` with `Ocp-Apim-Subscription-Key`.

## Demo

![AI Gateway demo](docs/images/aigateway.gif)

## How it works

- **APIM (VNet-injected)** is the gateway. It is private by default and can be exposed publicly with
  `apim_public = true`. The client-facing APIs share the same governance policy (consumer
  identification, allowed models, rate limits, token metrics, budget downgrade):
  - `/openai` — Azure OpenAI path-route facade for Copilot CLI / Azure-provider clients. It accepts
    the APIM subscription key in the `api-key` header.
  - `/vscode/openai` — VS Code BYOK facade with the same path-route shape. It accepts the APIM
    subscription key in the `Ocp-Apim-Subscription-Key` header, keeping keys out of URLs.
  - `/foundry` — Foundry/AIServices OpenAI/v1 body-route API for direct OSS/partner model calls.
- **Cosmos DB** holds the authoritative configuration (global defaults + per-consumer documents +
  a model price table). It is private with key auth disabled, and the gateway reads it indirectly
  through named values.
- The **config-sync worker** (a Container Apps Job, roughly every 5 minutes) syncs Cosmos → APIM
  named values and computes daily usage × unit price to record the budget downgrade level.
- The **Admin UI** (a Container App) reads and writes Cosmos and Log Analytics with managed identity.
  Changing a budget triggers an immediate re-evaluation.
- When a request is budget-downgraded, APIM adds response headers and emits an App Insights trace:
  `x-ai-gateway-requested-model`, `x-ai-gateway-effective-model`, and
  `x-ai-gateway-downgrade-level`. The Admin UI Monitoring page shows these downgrade events.
- All control/observability flows use **managed identity + RBAC** — no account keys, connection
  strings, or secrets in source or config. Secrets live in **Key Vault**.

## Repository layout

| Path | Description |
|---|---|
| `infra/` | Terraform (azurerm) — the entire gateway: network, APIM, OpenAI, Foundry, Cosmos, Key Vault, observability, Container Apps, jumpbox. |
| `policies/` | APIM policy templates rendered by Terraform (`openai-pipeline`, `foundry-pipeline`). |
| `app/admin-ui/` | Admin UI — FastAPI BFF (`bff/`) + React SPA (`spa/`), a single container image. |
| `app/config-sync-worker/` | Python worker that performs Cosmos → APIM sync + budget evaluation. |
| `scripts/` | Operational tools — backend bootstrap, config/pricing seeding, in-VNet smoke tests (see the table below). |

### `scripts/` file descriptions

| File | One-line description |
|---|---|
| `bootstrap-backend.ps1` | Creates the Terraform remote state backend (storage account + RG) once per subscription. |
| `seed-config.ps1` | Builds the authoritative global config document (`id=global`: allowed models · token limits) — prints JSON to show how to seed (for local preview). |
| `seed-cosmos-jumpbox.ps1` | Upserts the global config document directly into Cosmos using the jumpbox managed identity (PowerShell only, no dependencies). |
| `seed_cosmos.py` | Python version of the same global config seed (`azure-cosmos` + `DefaultAzureCredential`). |
| `seed-pricing-jumpbox.ps1` | Upserts the per-model price table (`id=pricing`, prompt/completion rates per 1K tokens) into Cosmos from the jumpbox (for cost-based budgeting). |

## Prerequisites

- An **Azure subscription** with model quota (Azure OpenAI and, optionally, Azure AI Foundry models).
- **Tools:** [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.7,
  [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), and `az login` to the
  subscription. Container images are built remotely in Azure Container Registry, so **Docker is not required.**
- **Entra ID objects** (one-time, directory objects Terraform cannot create). Required by the Admin
  UI; you can deploy the gateway core first and add them before turning the UI on:
  1. **Admin security group** — members are gateway admins → `admin_group_object_id`.
  2. **BFF API app registration** — expose the `access_as_user` scope and set
     `api.requestedAccessTokenVersion = 2` → `bff_api_audience` (`api://<app-id>`).
  3. **SPA public-client app registration** — PKCE, no secret, redirect URI = the Admin UI address →
     `spa_client_id`.

> All Azure access uses **managed identity / Entra ID** and never account keys.

---

## Deployment

Export these variables with your own custom values if needed.
```bash
export location=eastus2
export backend-rg=rg-aigw-tfstate-dev-eastus2
export storage-prefix=staigwtfstate
export state-key=ai-gateway-eus2.tfstate
```

### 1. Bootstrap the Terraform state backend (once per subscription)

```bash
./scripts/bootstrap-backend.sh \
  --location $location \
  --backend-rg $backend-rg \
  --storage-prefix $storage-prefix \
  --state-key $state-key
```

Creates an eastus2 resource group + storage account for remote state (Entra auth, public blob access blocked).

### 2. Set variables

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit infra/terraform.tfvars: prefix, location, owner, cost_center, apim_publisher_*, budget_*.
# Set apim_public = true before the first apply if the APIM gateway must be internet reachable.
```

### 3. First apply — the gateway core

On the first apply, leave `worker_image` and `admin_ui_image` empty (default `""`). The images
don't exist yet, and the worker Job / Admin UI app are count-gated on these variables.

```bash
cd infra
terraform init
# If you are moving an existing state from another backend, run `terraform init -migrate-state` instead.
terraform apply
```

> APIM Developer/Premium VNet injection can take about 45 minutes on the first apply. This is normal.
> Choose `apim_public` before the first apply; switching Internal/External later recreates APIM.

### 4. Build + push the container images

After the registry is created, build the worker and Admin UI images remotely (no local Docker needed):

```bash
acr=$(terraform output -raw registry_login_server)
reg=$(terraform output -raw registry_name)
az acr build --registry $reg --image config-sync-worker:latest ../app/config-sync-worker
az acr build --registry $reg --image admin-ui:latest ../app/admin-ui
```

### 5. Second apply — enable the worker + Admin UI

Before you can access the UI, you will need to register an app registration in EntraID.
```bash
./scripts/app-registration.sh
```

Put the image references and the three Entra variables from the prerequisites into
`infra/terraform.tfvars` and apply again:

```hcl
worker_image          = "<registry_login_server>/config-sync-worker:latest"
admin_ui_image        = "<registry_login_server>/admin-ui:latest"
admin_ui_public       = true   # external FQDN (still Entra-gated). false = VNet-only
admin_group_object_id = "<entra security group object id>"
bff_api_audience      = "api://<bff app id>"
spa_client_id         = "<spa app id>"
```

```bash
terraform apply
```

### 6. Seed configuration (from inside the VNet)

Cosmos is private with key auth disabled, so the initial config is seeded from a **jumpbox** inside
the VNet. Enable it with `enable_jumpbox = true` and Terraform handles the rest: it provisions the
jumpbox VM, grants its managed identity the `Cosmos DB Built-in Data Contributor` role (scoped to the
`config` container), and runs a **VM run-command** that seeds both documents automatically:

- **Global config** (`id=global`) — allowed models + token limits.
- **Per-model pricing** (`id=pricing`) — prompt/completion rates for cost-based budgeting.

The run-command retries (10 × 30s) to absorb RBAC propagation delay, so no manual step is required —
seeding completes as part of `terraform apply`. To re-run it on demand (e.g. after editing the seed
scripts), taint and re-apply:

```bash
terraform apply -replace='module.jumpbox.azurerm_virtual_machine_run_command.seed[0]'
```

To seed manually instead (jumpbox connected via Bastion), the same scripts can be run directly:

```bash
# Global allowed models + limits
./scripts/seed-cosmos-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
# Per-model pricing (for cost-based budgeting)
./scripts/seed-pricing-jumpbox.sh https://<cosmos-account>.documents.azure.com:443/
```

The config-sync worker publishes to APIM on its next run (trigger it immediately with:
`az containerapp job start -g <rg> -n <config_sync_job_name>`).

### 7. Use it

Update the SPA with your containerapps url
```bash
spa_app_id="$(az ad app list --display-name "AI Gateway SPA" --query "[].appId" -o tsv)" # spa_client_id
fqdn=$(terraform output -raw admin_ui_fqdn) # run from infra/
oid=$(az ad app show --id "$spa_app_id" --query id -o tsv)

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$oid" \
  --headers 'Content-Type=application/json' \
  --body "{\"spa\":{\"redirectUris\":[\"https://$fqdn\"]}}"
```

- **Admin UI** — connect via the `admin_ui_fqdn` output and sign in (you must be a member of the
  admin group). Register consumers, issue keys, set allowed models/tiers/budgets, and view the
  dashboard + request, blocked, and downgrade logs.
- **Call the gateway**:
  - Copilot CLI / Azure-provider clients call
    `POST https://<apim-host>/openai/deployments/<model>/chat/completions` with the APIM subscription
    key in the `api-key` header.
  - VS Code BYOK custom endpoint models call
    `POST https://<apim-host>/vscode/openai/deployments/<model>/chat/completions` with the APIM
    subscription key in the `Ocp-Apim-Subscription-Key` header.
  - Direct Foundry calls use `POST https://<apim-host>/foundry/chat/completions` with the model in
    the body and the APIM subscription key in the `Ocp-Apim-Subscription-Key` header.

### VS Code BYOK example

Add models to `chatLanguageModels.json` using the `/vscode/openai` facade:

```json
{
  "id": "gpt-5.4",
  "name": "GPT-5.4 via APIM",
  "url": "https://<apim-host>/vscode/openai/deployments/gpt-5.4/chat/completions?api-version=2025-01-01-preview",
  "toolCalling": true,
  "vision": false,
  "maxInputTokens": 128000,
  "maxOutputTokens": 16000,
  "requestHeaders": {
    "Ocp-Apim-Subscription-Key": "<APIM subscription key>"
  }
}
```

Register one entry per model that a consumer may choose directly (`gpt-5.4`, `gpt-5.4-mini`,
`grok-4.3`, `DeepSeek-V4-Pro`). APIM still enforces each consumer's allowed-model policy.

### Copilot CLI BYOK example

Use the APIM host as the Azure provider base URL. Do not include `/openai` or `/vscode/openai`; the
CLI constructs the Azure OpenAI path itself.

```bash
export COPILOT_PROVIDER_TYPE=azure
export COPILOT_PROVIDER_BASE_URL=https://<apim-host>
export COPILOT_PROVIDER_API_KEY="<APIM subscription key>"
export COPILOT_PROVIDER_AZURE_API_VERSION=2025-01-01-preview
export COPILOT_PROVIDER_WIRE_API=completions
export COPILOT_PROVIDER_MODEL_ID=gpt-5.4
export COPILOT_PROVIDER_WIRE_MODEL=gpt-5.4
```

## Cost & cleanup

- APIM **Developer_1** has no SLA (dev/demo only) — use `Premium_1` for production. VNet injection
  requires the Developer or Premium SKU.
- Azure OpenAI / Foundry bill per token, and a monthly Cost Management budget only **alerts** — it
  does not hard-stop spend. **Clean up when idle:** `terraform destroy` in `infra/`.

## Security model

- Backends: private endpoints + **key auth disabled**. APIM accesses them with **managed identity** +
  RBAC (Cognitive Services OpenAI User / Cognitive Services User).
- Control plane (worker, Admin UI): managed identity + least-privilege RBAC (Cosmos data roles, Log
  Analytics Reader, scoped APIM / Container Apps Jobs roles). No keys or connection strings anywhere.
- Secrets: **Key Vault**. Non-secret config: Cosmos + APIM named values provisioned by IaC.
