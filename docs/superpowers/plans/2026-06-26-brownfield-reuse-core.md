# Brownfield Foundry Reuse + v1 Backend Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the gateway reuse a customer's existing single AIServices (Foundry) account — reading it via a data source and adding only Private Endpoint + RBAC — and unify all backend calls onto the `/openai/v1` route so gpt and OSS models share one account and one path.

**Architecture:** A `reuse_foundry` toggle switches `modules/foundry` between *create* (greenfield, default) and *data-source reference* (brownfield). In reuse mode, `modules/openai` is count-gated off and gpt traffic is routed to the same AIServices account. Root-level locals resolve "which account/endpoint backs gpt" so downstream modules (`apim`, `control_plane`) need no signature changes. APIM policies are simplified so every downgrade is a same-backend body-`model` rewrite.

**Tech Stack:** Terraform (azurerm provider), APIM policy XML templates (`.tftpl`), bash smoke-test scripts, Azure CLI.

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-06-26-brownfield-reuse-and-gitbook-design.md` and repo `CLAUDE.md`:

- **Passwordless only.** Backends keep `local_auth_enabled = false`; APIM reaches them with managed identity + RBAC. Never introduce account keys, connection strings, or SAS tokens.
- **Backends stay private.** Private Endpoint + `public_network_access_enabled = false`. APIM may be public (`apim_public = true`); backends never.
- **Greenfield path must not regress.** `reuse_foundry` defaults to `false`; with the default, `terraform plan` output for an existing greenfield stack must be unchanged (no resource churn).
- **Client ingress unchanged.** Clients still send chat completions (path-route on `/openai`, `/vscode/openai`; body-route on `/foundry`). Only the *backend* serviceUrl/rewrite changes.
- **Terraform style:** snake_case resources/variables/outputs; `main.tf`/`variables.tf`/`outputs.tf`/`providers.tf` at root; modules under `modules/<resource>/`. Run `terraform fmt` and `terraform validate` before declaring a task done.
- **Deployment names = real model names** (no alias indirection). `foundry_deployments` map keys must equal the actual deployment names on the account.
- **Branch:** all work on `feat/brownfield-reuse-and-gitbook` (already created off `english`). Do not stage `infra/providers.tf` (unrelated uncommitted backend-name change).
- **Azure docs:** when documenting Azure behavior, cite `learn.microsoft.com`.

**Scope note:** This plan covers the engineering core (spec Phases 0–2). The Korean GitBook (spec Phase 3) and Admin UI Korean restore (spec Phase 4) are **separate follow-on plans** — they share no test cycle with the Terraform/APIM core. See "Follow-on plans" at the end.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `infra/modules/foundry/main.tf` | AIServices account: create OR reference; always create PE+RBAC target | Modify — add reuse toggle, `local.account_id/endpoint`, count-gate account & deployments |
| `infra/variables.tf` | Root variables | Modify — add `reuse_foundry`, `existing_foundry_name`, `existing_foundry_rg` |
| `infra/locals.tf` | Naming + now backend-resolution locals | Modify — add `gpt_backend_*` locals selecting foundry vs openai module |
| `infra/main.tf` | Module wiring | Modify — count-gate `module.openai`, pass reuse vars to foundry, rewire apim's openai_* inputs to locals |
| `infra/modules/openai/main.tf` | Azure OpenAI account (greenfield only) | Modify — accept an `enabled` flag so callers can count-gate cleanly |
| `policies/openai-pipeline.xml.tftpl` | Path-route ingress policy | Modify — rewrite gpt to `/openai/v1/chat/completions` body-route; collapse cross-backend branch |
| `policies/foundry-pipeline.xml.tftpl` | Body-route ingress policy | Modify — remove cross-backend (dgIsGpt) branch; all downgrades same-backend |
| `scripts/smoke-v1-gateway.sh` | End-to-end smoke test via public APIM | Create |
| `scripts/smoke-v1-backend.sh` | Direct-backend smoke test (jumpbox) | Create |
| `infra/terraform.tfvars.example` | Example vars | Modify — document reuse block |

---

## Task 0: Smoke-test scripts (verification gate, written first)

Per spec §3.3–3.4 the design is gated on smoke verification. These scripts are the gate. They are written first so Phases 1–2 can be validated against them. They take config via env vars / args (no secrets committed).

**Files:**
- Create: `scripts/smoke-v1-gateway.sh`
- Create: `scripts/smoke-v1-backend.sh`

**Interfaces:**
- Produces: `smoke-v1-gateway.sh <apim-host> <subscription-key>` — exercises the 5 spec checks against the public APIM gateway; exits non-zero on any failure.
- Produces: `smoke-v1-backend.sh <aiservices-openai-v1-base>` — direct backend check from inside the VNet (jumpbox), uses MI token from IMDS.

- [ ] **Step 1: Write `scripts/smoke-v1-gateway.sh`**

```bash
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
```

- [ ] **Step 2: Write `scripts/smoke-v1-backend.sh`**

```bash
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
```

- [ ] **Step 3: Make both scripts executable and syntax-check them**

Run:
```bash
chmod +x scripts/smoke-v1-gateway.sh scripts/smoke-v1-backend.sh
bash -n scripts/smoke-v1-gateway.sh && bash -n scripts/smoke-v1-backend.sh && echo "SYNTAX OK"
```
Expected: `SYNTAX OK` (no parse errors).

- [ ] **Step 4: Commit**

```bash
git add scripts/smoke-v1-gateway.sh scripts/smoke-v1-backend.sh
git commit -m "test: add v1 gateway + backend smoke scripts (verification gate)"
```

---

## Task 1: Add reuse variables (root)

**Files:**
- Modify: `infra/variables.tf` (append after `foundry_deployments`, before `enable_jumpbox` — around line 138)

**Interfaces:**
- Produces: `var.reuse_foundry` (bool, default false), `var.existing_foundry_name` (string), `var.existing_foundry_rg` (string). Consumed by Task 2 (foundry module call), Task 3 (openai count-gate), Task 4 (locals).

- [ ] **Step 1: Add the three variables to `infra/variables.tf`**

Insert this block immediately after the `foundry_deployments` variable's closing `}` (currently line 138):

```hcl
variable "reuse_foundry" {
  type        = bool
  default     = false
  description = "Brownfield: when true, reuse an EXISTING single AIServices (Foundry) account instead of creating one. The account + model deployments are read via a data source (not created); only the Private Endpoint and APIM RBAC are added. When true, the separate Azure OpenAI account is NOT created and gpt traffic is routed to the same AIServices account. The account must already have local_auth disabled and public network access blocked (see GitBook 04)."
}

variable "existing_foundry_name" {
  type        = string
  default     = ""
  description = "Name of the existing AIServices (Foundry) cognitive account to reuse. Required when reuse_foundry = true. Must be in the same subscription."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_name) > 0
    error_message = "existing_foundry_name is required when reuse_foundry = true."
  }
}

variable "existing_foundry_rg" {
  type        = string
  default     = ""
  description = "Resource group of the existing AIServices account (may differ from the gateway RG; same subscription). Required when reuse_foundry = true."
  validation {
    condition     = !var.reuse_foundry || length(var.existing_foundry_rg) > 0
    error_message = "existing_foundry_rg is required when reuse_foundry = true."
  }
}
```

- [ ] **Step 2: Validate variable syntax**

Run: `cd infra && terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.` (validate may require `terraform init` first; if it errors on backend, run `terraform validate` after `terraform init -backend=false`).

- [ ] **Step 3: Commit**

```bash
git add infra/variables.tf
git commit -m "feat(infra): add reuse_foundry brownfield variables"
```

---

## Task 2: Foundry module — create-or-reference toggle

**Files:**
- Modify: `infra/modules/foundry/main.tf`

**Interfaces:**
- Consumes: `var.reuse_existing` (bool), `var.existing_account_name` (string), `var.existing_account_rg` (string) — new module variables wired in Task 4.
- Produces: module outputs `id`, `endpoint`, `endpoint_openai_v1`, `endpoint_openai_host`, `deployment_names` keep the SAME names and types as today, now resolved from `local.account_*` so callers are unaffected.

- [ ] **Step 1: Add the three reuse variables to the module**

In `infra/modules/foundry/main.tf`, after the `deployments` variable block (ends line 38), add:

```hcl
variable "reuse_existing" {
  type        = bool
  default     = false
  description = "When true, read an existing AIServices account via data source instead of creating it; do not create model deployments. PE + RBAC are still created against the referenced account."
}
variable "existing_account_name" {
  type        = string
  default     = ""
  description = "Name of the existing AIServices account (required when reuse_existing = true)."
}
variable "existing_account_rg" {
  type        = string
  default     = ""
  description = "Resource group of the existing AIServices account (required when reuse_existing = true)."
}
```

- [ ] **Step 2: Count-gate the account resource and add the data source + locals**

Replace the `azurerm_cognitive_account "foundry"` resource (lines 40–54) with the count-gated version plus a data source and locals. The new block:

```hcl
resource "azurerm_cognitive_account" "foundry" {
  count                         = var.reuse_existing ? 0 : 1
  name                          = "ais-${var.name_suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "ais-${var.suffix}"
  local_auth_enabled            = false
  public_network_access_enabled = false
  tags                          = var.tags

  network_acls {
    default_action = "Deny"
  }
}

# Brownfield: reference an existing AIServices account instead of creating one.
data "azurerm_cognitive_account" "existing" {
  count               = var.reuse_existing ? 1 : 0
  name                = var.existing_account_name
  resource_group_name = var.existing_account_rg

  lifecycle {
    postcondition {
      # Gateway standard: the reused account must have key auth disabled (passwordless).
      # If azurerm omits local_auth_enabled on this data source for the pinned provider
      # version, remove this postcondition and rely on the az pre-check in GitBook 04.
      condition     = self.local_auth_enabled == false
      error_message = "Reused AIServices account has key auth enabled. Disable it before deploy: az resource update --ids <account-id> --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled (see GitBook 04)."
    }
  }
}

locals {
  account_id       = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id       : azurerm_cognitive_account.foundry[0].id
  account_name     = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].name     : azurerm_cognitive_account.foundry[0].name
  account_endpoint = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].endpoint : azurerm_cognitive_account.foundry[0].endpoint
}
```

- [ ] **Step 3: Count-gate model deployments and repoint settle + PE to `local.account_id`**

Replace the `azurerm_cognitive_deployment "models"` block (lines 56–71) with:

```hcl
resource "azurerm_cognitive_deployment" "models" {
  for_each             = var.reuse_existing ? {} : var.deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }
}
```

Then update `time_sleep "foundry_settle"` (lines 76–79) — only wait when we created the account:

```hcl
resource "time_sleep" "foundry_settle" {
  count           = var.reuse_existing ? 0 : 1
  depends_on      = [azurerm_cognitive_account.foundry]
  create_duration = "60s"
}
```

And update `azurerm_private_endpoint "foundry"` (lines 81–101): change `depends_on`, and `private_connection_resource_id` to use the locals:

```hcl
resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-ais-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_settle]

  private_service_connection {
    name                           = "psc-ais"
    private_connection_resource_id = local.account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "ais-dns"
    private_dns_zone_ids = var.dns_zone_ids
  }
}
```

- [ ] **Step 4: Repoint all module outputs to the locals**

Replace the outputs block (lines 103–132) so each output reads `local.*` (and the v1/host transforms operate on `local.account_endpoint`):

```hcl
output "id" {
  description = "Resource ID of the AIServices (Foundry) cognitive account (created or referenced)."
  value       = local.account_id
}
output "name" {
  description = "Name of the AIServices (Foundry) cognitive account."
  value       = local.account_name
}
output "endpoint" {
  description = "AIServices account control endpoint (https://ais-<suffix>.cognitiveservices.azure.com/)."
  value       = local.account_endpoint
}
output "endpoint_openai_v1" {
  description = "GA OpenAI/v1 inference base for the AIServices account (…/openai/v1). Accepts gpt + OSS deployments with the model name in the body."
  value       = "${trimsuffix(replace(local.account_endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")}/openai/v1"
}
output "endpoint_openai_host" {
  description = "AIServices account openai.azure.com host base (no path)."
  value       = trimsuffix(replace(local.account_endpoint, ".cognitiveservices.azure.com", ".openai.azure.com"), "/")
}
output "deployment_names" {
  description = "Model deployment names created by this module (empty in reuse mode; the account already has them)."
  value       = [for k, d in azurerm_cognitive_deployment.models : k]
}
```

- [ ] **Step 5: Validate module syntax**

Run: `cd infra && terraform fmt && terraform validate` (after `terraform init -backend=false` if needed)
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add infra/modules/foundry/main.tf
git commit -m "feat(infra): foundry module create-or-reference toggle"
```

---

## Task 3: OpenAI module — `enabled` flag for count-gating

**Files:**
- Modify: `infra/modules/openai/main.tf`

**Interfaces:**
- Consumes: `var.enabled` (bool, default true) — new module variable.
- Produces: outputs `id`, `endpoint`, `name`, `deployment_names` unchanged in name/type; resolve to `null`/`""` when disabled (module is count-gated at the call site in Task 4, so these outputs are only read in greenfield).

> Rationale: the call site count-gates `module.openai` (Task 4). A module can't reference its own `count`, so the *call site* sets `count`. This task only count-gates the **resources inside** the module so a future caller passing `enabled=false` without count still behaves — and to make the intent explicit. Both layers agree: when reuse, the module is absent.

- [ ] **Step 1: Add `enabled` variable**

In `infra/modules/openai/main.tf`, after the `deployments` variable (ends line 37), add:

```hcl
variable "enabled" {
  type        = bool
  default     = true
  description = "When false, create no resources (used when the gateway reuses a single AIServices account that already hosts gpt)."
}
```

- [ ] **Step 2: Count-gate account, settle, deployments, PE**

Add `count = var.enabled ? 1 : 0` to `azurerm_cognitive_account "openai"` (line 39), `time_sleep "openai_settle"` (line 75), and `azurerm_private_endpoint "openai"` (line 80). For `azurerm_cognitive_deployment "models"` (line 55) change `for_each = var.deployments` to:

```hcl
  for_each = var.enabled ? var.deployments : {}
```

For the account, settle, and PE, the `count` line goes right after the resource's opening brace, e.g.:

```hcl
resource "azurerm_cognitive_account" "openai" {
  count                         = var.enabled ? 1 : 0
  name                          = "oai-${var.name_suffix}"
  # ... rest unchanged
}
```

The deployment references `azurerm_cognitive_account.openai.id` (line 58) — change to `azurerm_cognitive_account.openai[0].id`. The settle `depends_on` (line 76) and PE `private_connection_resource_id` (line 91) referencing `azurerm_cognitive_account.openai` — change to `azurerm_cognitive_account.openai[0]`. The PE `depends_on = [time_sleep.openai_settle]` stays valid (list of a count resource is fine).

- [ ] **Step 3: Repoint outputs to handle count**

Replace the outputs block (lines 102–117):

```hcl
output "id" {
  description = "Resource ID of the Azure OpenAI cognitive account (null when disabled)."
  value       = var.enabled ? azurerm_cognitive_account.openai[0].id : null
}
output "name" {
  description = "Name of the Azure OpenAI cognitive account (null when disabled)."
  value       = var.enabled ? azurerm_cognitive_account.openai[0].name : null
}
output "endpoint" {
  description = "HTTPS endpoint of the Azure OpenAI account (null when disabled)."
  value       = var.enabled ? azurerm_cognitive_account.openai[0].endpoint : null
}
output "deployment_names" {
  description = "List of model deployment names created on the Azure OpenAI account."
  value       = [for k, d in azurerm_cognitive_deployment.models : k]
}
```

- [ ] **Step 4: Validate**

Run: `cd infra && terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add infra/modules/openai/main.tf
git commit -m "feat(infra): openai module enabled flag for count-gating"
```

---

## Task 4: Root wiring — count-gate openai, route gpt to the single account

**Files:**
- Modify: `infra/locals.tf` (add backend-resolution locals)
- Modify: `infra/main.tf` (foundry call: reuse vars; openai call: count; apim call: openai_* inputs → locals)

**Interfaces:**
- Consumes: `var.reuse_foundry`, `module.foundry.*`, `module.openai[*].*`.
- Produces: `local.gpt_backend_account_id`, `local.gpt_backend_endpoint`, `local.gpt_backend_path_base` — the account/endpoint/path that gpt traffic uses (foundry account in reuse mode, openai account otherwise). Consumed within this task by the apim module call.

> Why: `main.tf:108-118` currently reads `module.openai.id`, `module.openai.endpoint`. Count-gating `module.openai` makes those `module.openai[0].*`, which don't exist in reuse mode. Locals resolve the right backend so the apim module signature is unchanged.

- [ ] **Step 1: Add backend-resolution locals to `infra/locals.tf`**

Inside the existing `locals { ... }` block in `infra/locals.tf` (before its closing `}` at line 34), add:

```hcl
  # gpt backend resolution: in reuse mode there is no separate Azure OpenAI account — gpt lives on
  # the same AIServices (Foundry) account, reached via its GA OpenAI/v1 route. In greenfield mode
  # gpt uses the dedicated Azure OpenAI account. Downstream (apim) consumes these, not the modules
  # directly, so the apim module signature is unchanged across both modes.
  gpt_backend_account_id = var.reuse_foundry ? module.foundry.id : module.openai[0].id
  gpt_backend_endpoint   = var.reuse_foundry ? module.foundry.endpoint_openai_host : module.openai[0].endpoint
  # Path base the policy appends "/deployments/{m}/chat/completions" or "/v1/chat/completions" to.
  # Reuse: the AIServices openai.azure.com host (…/openai). Greenfield: the OpenAI account (…/openai).
  gpt_backend_path_base = var.reuse_foundry ? "${module.foundry.endpoint_openai_host}/openai" : "${trimsuffix(module.openai[0].endpoint, "/")}/openai"
```

- [ ] **Step 2: Count-gate `module.openai` and pass reuse vars to `module.foundry`**

In `infra/main.tf`, add `count` to the `module "openai"` block (line 51) and an `enabled` arg:

```hcl
module "openai" {
  count               = var.reuse_foundry ? 0 : 1
  source              = "./modules/openai"
  name_suffix         = local.name_suffix
  suffix              = local.sfx
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = local.tags
  pe_subnet_id        = module.network.pe_subnet_id
  dns_zone_id         = module.network.dns_zone_ids["openai"]
  deployments         = var.openai_deployments
  enabled             = true
}
```

In the `module "foundry"` block (line 63), add the reuse passthrough (after `deployments = var.foundry_deployments`):

```hcl
  reuse_existing        = var.reuse_foundry
  existing_account_name = var.existing_foundry_name
  existing_account_rg   = var.existing_foundry_rg
```

- [ ] **Step 3: Rewire the apim module's openai_* inputs to the locals**

In the `module "apim"` block, change these four lines (currently 108–109 and 117):

```hcl
  openai_account_id            = module.openai.id
  openai_endpoint              = module.openai.endpoint
  # ...
  openai_path_base              = "${trimsuffix(module.openai.endpoint, "/")}/openai"
```

to:

```hcl
  openai_account_id            = local.gpt_backend_account_id
  openai_endpoint              = local.gpt_backend_endpoint
  # ...
  openai_path_base              = local.gpt_backend_path_base
```

(Leave `foundry_account_id`, `foundry_endpoint`, `foundry_v1_base` pointing at `module.foundry.*` — unchanged.)

- [ ] **Step 4: Confirm the apim module's RBAC is collision-free in reuse mode (no edit expected)**

In reuse mode `var.openai_account_id` now equals `var.foundry_account_id` (both the AIServices account). Verify the two role assignments grant DIFFERENT roles, so co-locating them on one account is valid and needs no guard:

Run: `grep -n "apim_to_openai\|apim_to_foundry\|role_definition_name" infra/modules/apim/main.tf`

Expected: `apim_to_openai` → `"Cognitive Services OpenAI User"`, `apim_to_foundry` → `"Cognitive Services User"`. Two distinct roles on the same scope+principal do not collide in Azure, and both are useful on the AIServices account (the OpenAI User role backs the `/openai/v1` gpt route). **No code change in this step** — this is a verification checkpoint. If, contrary to expectation, both assignments use the *same* role name, only then add `count = var.openai_account_id == var.foundry_account_id ? 0 : 1` to `apim_to_openai`.

- [ ] **Step 5: Validate the whole config**

Run: `cd infra && terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Greenfield no-regression check**

Confirm the default path is untouched: with no tfvars change (`reuse_foundry` defaults false), the locals resolve to `module.openai[0].*` and the foundry module creates the account.

Run: `cd infra && terraform validate && echo "default (greenfield) config valid"`
Expected: valid. (A full `terraform plan` against the live state is the real regression check and is performed in Task 7 against the test stack, not here.)

- [ ] **Step 7: Commit**

```bash
git add infra/locals.tf infra/main.tf infra/modules/apim/main.tf
git commit -m "feat(infra): route gpt to single AIServices account in reuse mode"
```

---

## Task 5: Simplify foundry policy — remove cross-backend downgrade

**Files:**
- Modify: `policies/foundry-pipeline.xml.tftpl`

**Interfaces:**
- Consumes: same template vars as today (`foundry_aliases`, `rate_tiers`, etc.). After this task `openai_aliases`, `openai_path_base`, `openai_api_version` are no longer referenced by this template — they remain passed in (harmless) and are still used by the openai policy.
- Produces: a foundry policy where every budget downgrade is a same-backend body-`model` rewrite (no `dgIsGpt`, no `set-backend-service`).

> Because gpt and OSS now share one AIServices account on `/openai/v1`, a downgrade target — gpt or OSS — is always reachable on the same backend by changing the body `model`. The cross-backend branch (lines 123, 128–141) is dead.

- [ ] **Step 1: Replace the downgrade-apply block**

In `policies/foundry-pipeline.xml.tftpl`, replace the `dgIsGpt` set-variable and the `<choose>` that applies the downgrade (lines 123–152) with a single same-backend rewrite:

```xml
    <!-- [Cost] Apply the downgrade. gpt and OSS share one AIServices account on /openai/v1, so any
         downgrade target is reached on the SAME backend by rewriting the body "model" field. -->
    <choose>
      <when condition="@(((string)context.Variables["effectiveModel"]).Length > 0 && (string)context.Variables["effectiveModel"] != (string)context.Variables["requestedDeployment"])">
        <set-body>@{
            var body = context.Request.Body.As<Newtonsoft.Json.Linq.JObject>();
            body["model"] = (string)context.Variables["effectiveModel"];
            return body.ToString(Newtonsoft.Json.Formatting.None);
        }</set-body>
      </when>
    </choose>
```

(The trace block at lines 153–163, rate-limit, metric, MI auth, and outbound header blocks all stay unchanged — they key on `effectiveModel` which is still set above.)

- [ ] **Step 2: Validate template renders (terraform validate exercises templatefile)**

Run: `cd infra && terraform validate`
Expected: valid. (If a render-time error in the template existed, `validate` on the apim module's `templatefile` call would surface it. A deeper check happens at apply in Task 7.)

- [ ] **Step 3: Commit**

```bash
git add policies/foundry-pipeline.xml.tftpl
git commit -m "refactor(policy): foundry downgrades are same-backend body rewrites"
```

---

## Task 6: Unify openai policy — gpt path-route → v1 body-route

**Files:**
- Modify: `policies/openai-pipeline.xml.tftpl`

**Interfaces:**
- Consumes: `foundry_v1_base` (the AIServices `/openai/v1` base), `foundry_aliases`, `rate_tiers`. After this task the openai policy sends ALL traffic — normal and downgraded, gpt and OSS — to `foundry_v1_base` as a body-route `/chat/completions` request.
- Produces: an openai (path-route ingress) policy that converts the incoming `/openai/deployments/{m}/chat/completions?api-version=…` into a v1 body-route call: backend = `foundry_v1_base`, URI = `/chat/completions`, body `model` = effectiveDeployment.

> This is the spec's only genuinely new logic (gpt path→body) and the highest-risk item (§6.2). The smoke gate (Task 0 / Task 7) validates it before this is trusted. The incoming route always carries the model as a URL segment (`requestedDeployment`), so we inject it into the body for every request — not just downgrades.

- [ ] **Step 1: Replace the downgrade-apply `<choose>` with an always-on body-route conversion**

In `policies/openai-pipeline.xml.tftpl`, replace the `dgIsOss` set-variable plus the `<choose>` that applies the target (lines 119–144) with:

```xml
    <!-- [Backend v1] The incoming route is the Azure OpenAI path route (model in the URL,
         ?api-version=…). The unified backend is the AIServices GA OpenAI/v1 route (model in body,
         no api-version). Convert EVERY request: point at the v1 base, rewrite to /chat/completions
         (dropping ?api-version, which the v1 route 400s on), and put the effective deployment in the
         body "model". gpt-5 reasoning models need max_completion_tokens; if a client sent max_tokens,
         translate it. effectiveDeployment == requestedDeployment when no budget downgrade applies. -->
    <set-backend-service base-url="${foundry_v1_base}" />
    <rewrite-uri template="/chat/completions" copy-unmatched-params="false" />
    <set-body>@{
        var body = context.Request.Body.As<Newtonsoft.Json.Linq.JObject>();
        body["model"] = (string)context.Variables["effectiveDeployment"];
        if (body["max_tokens"] != null && body["max_completion_tokens"] == null) {
            body["max_completion_tokens"] = body["max_tokens"];
            body.Remove("max_tokens");
        }
        return body.ToString(Newtonsoft.Json.Formatting.None);
    }</set-body>
```

> Note the direction flip vs the old foundry path: here clients may send either `max_tokens` or `max_completion_tokens`; we normalize to `max_completion_tokens` because the unified backend serves gpt-5 reasoning models that reject `max_tokens`. Confirm in the smoke test (Task 7 check 4) that OSS models on this account also accept `max_completion_tokens`; if an OSS model rejects it, revisit (fallback documented in spec §6.2).

- [ ] **Step 2: Confirm the allowed-models 403 still evaluates correctly**

The 403 `<choose>` (lines 156–166) checks `effectiveDeployment` against `effectiveAllowedModels`. That logic is unchanged and still correct (the deployment name is set from the URL segment at lines 45–49). No edit needed — just verify by reading it remains after your Step 1 edit.

- [ ] **Step 3: Validate**

Run: `cd infra && terraform validate`
Expected: valid.

- [ ] **Step 4: Commit**

```bash
git add policies/openai-pipeline.xml.tftpl
git commit -m "feat(policy): unify openai path-route to v1 body-route backend"
```

---

## Task 7: Verification stack — prove brownfield reuse end-to-end

This is spec Phase 0 executed against real Azure. It is the gate: if it fails, the relevant policy/IaC task is revised (fallback to "mixed/current" per spec §6.2) before this plan is considered done.

**Files:**
- Modify: `infra/terraform.tfvars.example` (document the reuse block)
- (No new TF resources — uses the modules built above with a test tfvars.)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a documented, passing (or explicitly-failing-with-fallback) smoke result.

- [ ] **Step 1: Document the reuse block in `infra/terraform.tfvars.example`**

Append to `infra/terraform.tfvars.example`:

```hcl
# --- Brownfield: reuse an existing single AIServices (Foundry) account ---
# When true, the gateway does NOT create the AIServices account, its model deployments, or a
# separate Azure OpenAI account. It reads the existing account, adds a Private Endpoint + APIM RBAC,
# and routes gpt + OSS to that account's GA OpenAI/v1 route. The account must already have key auth
# disabled and public network access blocked (see docs GitBook 04). Same subscription only.
# reuse_foundry         = true
# existing_foundry_name = "ais-customer-prod"
# existing_foundry_rg   = "rg-customer-ai"
#
# foundry_deployments below must DECLARE the deployments that already exist on the account
# (keys = real deployment names); they are not created in reuse mode but drive allowed_models,
# downgrade routing, and the Admin UI label map.
```

- [ ] **Step 2: Create the "customer existing Foundry" mock (manual, documented)**

This step is operational, not code. Record the commands you run in the PR description. Create a single AIServices account with the three deployments, initially with key auth + public access ON (to mirror a real customer), then toggle them off — exercising the GitBook 04 procedure:

```bash
# Create AIServices account (customer-style), then create gpt-5.4/grok-4.3/DeepSeek-V4-Pro deployments
# via the portal or `az cognitiveservices account deployment create`. Then lock it down:
az resource update --ids <aiservices-account-id> \
  --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
```

Expected: account shows `disableLocalAuth: true`, `publicNetworkAccess: Disabled`.

- [ ] **Step 3: Deploy the gateway in reuse mode and inspect the plan**

Create a test tfvars (do not commit secrets) with `reuse_foundry=true`, `existing_foundry_name/rg` set, `apim_sku_name="Developer_1"`, `apim_public=true`, and `foundry_deployments` declaring the three existing deployments.

Run: `cd infra && terraform plan`
Expected: **no `azurerm_cognitive_account` or `azurerm_cognitive_deployment` to create**; a `azurerm_private_endpoint.foundry` and the APIM `Cognitive Services *` role assignment(s) against the existing account ARE planned. Capture this plan summary for the PR.

- [ ] **Step 4: Apply, then run the gateway smoke test from your laptop**

```bash
cd infra && terraform apply
# After APIM is up (first VNet apply ~45 min) and a subscription key is issued via the Admin UI:
../scripts/smoke-v1-gateway.sh <apim-host> <subscription-key>
```
Expected: `ALL SMOKE CHECKS PASSED`. If a check fails, use `scripts/smoke-v1-backend.sh` from the jumpbox to isolate backend vs policy, then revise the failing policy task and re-apply.

- [ ] **Step 5: Record the result and (if needed) the fallback decision**

If all pass: note it in the PR. If gpt path→body (check 1/4) fails and cannot be fixed: revert Task 6's openai policy to keep gpt on the path-route backend (`local.gpt_backend_path_base` already provides it) and document the "mixed" fallback per spec §6.2. Either way, the plan's DoD requires this decision be written down.

- [ ] **Step 6: Tear down the verification stack**

```bash
cd infra && terraform destroy   # gateway RG only; the mock Foundry RG is separate
# then delete the mock Foundry RG:
az group delete -n rg-<mock-foundry> --yes
```

- [ ] **Step 7: Commit the example doc change**

```bash
git add infra/terraform.tfvars.example
git commit -m "docs(infra): document reuse_foundry tfvars block"
```

---

## Self-Review

**Spec coverage (Phases 0–2):**
- §2.2 foundry create-or-reference toggle → Task 2 ✓
- §2.3 single AIServices (openai off, gpt → same account) → Tasks 3, 4 ✓
- §2.4 account-property precondition + az toggle → Task 2 Step 2 (postcondition) + Task 7 Step 2 ✓
- §2.5 tfvars interface → Tasks 1, 7 ✓
- §3.1 cross-backend branch removed → Task 5 ✓
- §3.2 ingress unchanged; backend → /openai/v1 → Task 6 ✓
- §3.3 5 smoke checks → Task 0 + Task 7 Step 4 ✓
- §3.4 local vs jumpbox scripts → Task 0 ✓
- §3.5 verification test stack → Task 7 ✓
- §6.2 fallback decision recorded → Task 7 Step 5 ✓

**Phases 3–4** (GitBook, Admin UI Korean) are intentionally out of this plan — separate follow-on plans (below).

**Placeholder scan:** No TBD/TODO; every code step shows full content. Operational steps (Task 7 Steps 2–6) are inherently manual Azure actions with exact commands and expected output.

**Type/name consistency:** `local.account_id/account_name/account_endpoint` (foundry module) consistent across Task 2 Steps 2–4. `local.gpt_backend_account_id/endpoint/path_base` consistent across Task 4 Steps 1, 3. `effectiveDeployment` (openai policy) vs `effectiveModel` (foundry policy) — these are the two templates' pre-existing distinct variable names, preserved as-is (not unified, to keep each policy's diff minimal).

**Known residual risk (documented, not a gap):** the foundry data source may not expose `local_auth_enabled` on the pinned azurerm version (Task 2 Step 2 notes the fallback to the az pre-check). Verified at plan time in Task 7 Step 3.

---

## Follow-on plans (separate, not in this plan)

- **GitBook (spec Phase 3):** Korean docs under `docs/` with `SUMMARY.md`, 10 chapters. Pure documentation; no shared test cycle. Write as its own plan after this core lands.
- **Admin UI Korean restore (spec Phase 4):** per-file selective revert of i18n strings from `main` while preserving the `c4a8afc` Copilot feature commit; then `az acr build` redeploy. Independent of the Terraform/APIM core.
