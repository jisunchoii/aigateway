# Codex Proxy Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the local Codex↔Foundry proxy to a Container App sidecar behind APIM `/responses`, so payload normalization runs server-side with full APIM governance in front.

**Architecture:** APIM `/responses` runs the existing governance policy (consumerId → allowed-models → downgrade → rate limit → metrics), injects a master key on the hop, and forwards to a sidecar Container App that hosts our Python proxy. The sidecar validates the master key, normalizes Codex's gpt-only payload shapes, authenticates to a new project-enabled Foundry account via Managed Identity, and forwards to the project's native Responses route. GLM+DeepSeek (+ ladder models) are consolidated onto the new account; Kimi is out of scope.

**Tech Stack:** Terraform (azurerm ~> 4.20, azapi ~> 2.0, random ~> 3.6), Azure Container Apps, Azure AI Foundry, Python 3 (stdlib + azure-identity 1.19.0), Docker.

## Global Constraints

- Passwordless only: backend auth via Managed Identity (`ManagedIdentityCredential`), never keys. (project rule + spec §32)
- The proxy MUST NOT rewrite the body `model` field — APIM downgrade depends on it. (spec §62)
- Preserve SSE streaming: sidecar flushes event-by-event; APIM keeps `buffer-response="false"` timeout=300. (spec §102)
- Kimi-K2.7-Code stays deployed and untouched but is NOT wired through the sidecar. Never delete it. (spec §23, §92)
- No deletion of any Azure deployment runs without a live quota re-audit and explicit confirmation first. (spec §95)
- `azure-identity` pinned to `==1.19.0` (matches `app/admin-ui/bff/requirements.txt`). (spec §76)
- Terraform verify gate: `terraform fmt -recursive` + `terraform validate` from `infra/` before declaring any infra task done. (docs/step-by-step-deployment-guide.md:210)
- Proxy verify gate: `python app/codex-proxy/foundry_codex_proxy.py --selftest` prints `selftest OK`. (spec §105)
- New identifiers use `codexproxy` (e.g. `id-codexproxy-<suffix>`, `ca-codexproxy-<suffix>`, named value `codexproxy-key`). (spec §66-73)

---

### Task 1: Sidecar code — MI auth + master-key + single backend

Move the proxy into `app/codex-proxy/`, replace az-CLI token acquisition with `ManagedIdentityCredential`, add master-key validation, and collapse `ROUTES` to a single env-driven backend. All normalization logic (tool shapes, namespace flatten+restore, history filtering, verbosity, include, reasoning) stays byte-for-byte.

**Files:**
- Create: `app/codex-proxy/foundry_codex_proxy.py` (moved + edited from `scripts/foundry_codex_proxy.py`)
- Create: `app/codex-proxy/requirements.txt`
- Delete: `scripts/foundry_codex_proxy.py` (and its profile mirrors stay in CODEX_HOME, untouched)

**Interfaces:**
- Produces: an HTTP server on `PORT` (env, default 8789) accepting `POST *…/responses`; env contract `FOUNDRY_PROJECT_BASE` (backend base URL, no trailing slash), `PROXY_KEY` (hop secret; if unset, key check is skipped for local dev), `AZURE_CLIENT_ID` (MI selection), `MI_SCOPE` (default `https://cognitiveservices.azure.com/.default`).
- Produces: `normalize_request(body) -> (route, ns_map)` unchanged; `--selftest` entrypoint unchanged.

- [ ] **Step 1: Move the file (preserve git history where possible)**

```bash
cd /c/Users/jisunchoi/projects/llm-gateway
mkdir -p app/codex-proxy
git mv scripts/foundry_codex_proxy.py app/codex-proxy/foundry_codex_proxy.py
```

- [ ] **Step 2: Run the selftest at the new path to confirm the move is clean**

Run: `python app/codex-proxy/foundry_codex_proxy.py --selftest`
Expected: `selftest OK`

- [ ] **Step 3: Add a failing selftest assertion for master-key validation**

In `app/codex-proxy/foundry_codex_proxy.py`, inside `selftest()` (before the final `print("selftest OK")`), add:

```python
    # master-key check: helper returns True only when the header matches PROXY_KEY
    assert _key_ok("Bearer secret", "secret") is True
    assert _key_ok("Bearer wrong", "secret") is False
    assert _key_ok("", "secret") is False
    assert _key_ok("anything", "") is True   # empty PROXY_KEY (local dev) disables the check
```

- [ ] **Step 4: Run selftest to verify it fails**

Run: `python app/codex-proxy/foundry_codex_proxy.py --selftest`
Expected: FAIL with `NameError: name '_key_ok' is not defined`

- [ ] **Step 5: Implement `_key_ok` and the env/MI wiring**

Near the top constants (replacing the `TOKEN_RESOURCE` / `_AZ` block at lines 41-42), set:

```python
import os
PORT = int(os.environ.get("PORT", "8789"))
FOUNDRY_PROJECT_BASE = os.environ.get("FOUNDRY_PROJECT_BASE", "").rstrip("/")
PROXY_KEY = os.environ.get("PROXY_KEY", "")
MI_SCOPE = os.environ.get("MI_SCOPE", "https://cognitiveservices.azure.com/.default")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")


def _key_ok(auth_header, expected):
    if not expected:
        return True  # local dev: no key configured, skip the check
    token = auth_header[7:] if auth_header.lower().startswith("bearer ") else ""
    return token == expected
```

Replace the `get_token()` function (current lines 221-245, az-CLI subprocess) with a Managed Identity version. Keep the module-level lock; drop the manual expiry cache (azure-identity caches internally):

```python
from azure.identity import ManagedIdentityCredential

_cred = None
_cred_lock = threading.Lock()


def _credential():
    global _cred
    with _cred_lock:
        if _cred is None:
            _cred = (ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)
                     if AZURE_CLIENT_ID else ManagedIdentityCredential())
        return _cred


def get_token(now=None, force=False):
    try:
        return _credential().get_token(MI_SCOPE).token
    except Exception as e:
        log("MI token acquisition failed: %s" % e)
        return None
```

Collapse `ROUTES` (lines 26-39) to a single backend driven by env. Replace the dict and its use in `normalize_request`:

```python
# Single backend: the sidecar fronts one project-enabled Foundry account. The body "model"
# selects the deployment; base_url is fixed (never per-model). reasoning_effort handling is
# per-model, keyed by model name, since GLM needs an effort object and DeepSeek rejects it.
REASONING_EFFORT_MODELS = {"FW-GLM-5.2"}  # models that REQUIRE reasoning.effort; others get it stripped


def _route_for(model):
    if not FOUNDRY_PROJECT_BASE:
        return None
    return {
        "base_url": FOUNDRY_PROJECT_BASE,
        "reasoning_effort": model in REASONING_EFFORT_MODELS,
    }
```

In `normalize_request`, replace `route = ROUTES.get(body.get("model"))` with `route = _route_for(body.get("model"))`.

- [ ] **Step 6: Add the master-key guard at the top of `do_POST`**

At the start of `do_POST` (current line 289, before the path check), add:

```python
        if not _key_ok(self.headers.get("Authorization", ""), PROXY_KEY):
            self._json(401, {"error": "invalid or missing proxy key"})
            return
```

Then change the backend-token section (current lines 307-310) so the token comes only from MI (the incoming Authorization is now the hop key, not a backend token):

```python
        tok = get_token()
        if not tok:
            self._json(502, {"error": "backend auth unavailable (MI token failed)"})
            return
```

Remove the now-unused 401-retry-on-expiry branch that keyed off `az_tok` (current lines ~322-348): on `send()` HTTPError just relay the backend status as before (keep the reject logging). `_incoming_bearer` may remain unused; delete it to avoid dead code.

- [ ] **Step 7: Run selftest to verify it passes**

Run: `python app/codex-proxy/foundry_codex_proxy.py --selftest`
Expected: `selftest OK`

- [ ] **Step 8: Create requirements.txt**

Create `app/codex-proxy/requirements.txt`:

```
azure-identity==1.19.0
```

- [ ] **Step 9: Commit**

```bash
git add app/codex-proxy/ scripts/foundry_codex_proxy.py
git commit -m "feat(codex-proxy): sidecar-ready proxy — MI auth, master-key, single backend"
```

---

### Task 2: Sidecar Dockerfile

Containerize the proxy on a slim Python base, exposing 8789.

**Files:**
- Create: `app/codex-proxy/Dockerfile`

**Interfaces:**
- Consumes: `app/codex-proxy/foundry_codex_proxy.py`, `app/codex-proxy/requirements.txt` (Task 1)
- Produces: an image whose `CMD` runs the proxy listening on `$PORT` (8789).

- [ ] **Step 1: Write the Dockerfile**

Create `app/codex-proxy/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

# Codex↔Foundry Responses proxy sidecar. Normalizes Codex's gpt-only payload shapes for the
# Foundry project route. Backend auth is Entra ID (Managed Identity) via azure-identity — no keys.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY foundry_codex_proxy.py .

EXPOSE 8789
CMD ["python", "foundry_codex_proxy.py"]
```

- [ ] **Step 2: Build locally to verify it assembles**

Run: `docker build -t codexproxy:local app/codex-proxy`
Expected: build succeeds, final image tagged `codexproxy:local`.

- [ ] **Step 3: Smoke the container boots and serves (selftest inside the image)**

Run: `docker run --rm codexproxy:local python foundry_codex_proxy.py --selftest`
Expected: `selftest OK`

- [ ] **Step 4: Commit**

```bash
git add app/codex-proxy/Dockerfile
git commit -m "feat(codex-proxy): add sidecar Dockerfile"
```

---

### Task 3: New project-enabled Foundry account + project (azapi)

Create a NEW AIServices account with `allowProjectManagement=true` and one child project via `azapi_resource` (net-new pattern; repo only used `azapi_update_resource` before). Expose the project's Responses base URL as a module output.

**Files:**
- Modify: `infra/modules/foundry/main.tf` (add azapi account + project + output)
- Modify: `infra/modules/foundry/variables.tf` (add a toggle var)

**Interfaces:**
- Consumes: existing module vars `name_suffix`, `suffix`, `resource_group_name`, `location`, `tags`, `dns_zone_ids`.
- Produces: outputs `project_account_id` (account resource id, for RBAC + deployments), `project_responses_base` (`https://<acct>.services.ai.azure.com/api/projects/<proj>/openai/v1`), gated on a new `enable_project_account` var.

- [ ] **Step 1: Add the master toggle variable (root) — defined here because Tasks 3-7 all gate on it**

In `infra/variables.tf`, add the root master toggle first (referenced by every subsequent task; defining it here keeps `terraform validate` green as tasks land in order):

```hcl
variable "enable_codexproxy" {
  type        = bool
  default     = false
  description = "Master toggle for the Codex proxy sidecar: the project-enabled Foundry account, its deployments, the identity/hop-key/RBAC, and the Container App. When false, none are created and /responses stays on its current backend."
}
```

Then in `infra/modules/foundry/variables.tf`, add the module-level toggle:

```hcl
variable "enable_project_account" {
  type        = bool
  default     = false
  description = "Create a NEW project-enabled AIServices account (allowProjectManagement=true) + one project for the Codex proxy sidecar backend. Fireworks models need the project route for Responses."
}

variable "project_account_name" {
  type        = string
  default     = ""
  description = "Name of the project-enabled AIServices account. Defaults to aisproj-<suffix> when empty."
}
```

- [ ] **Step 2: Add the azapi account + project resources**

In `infra/modules/foundry/main.tf`, add (uses `azapi` provider, already pinned `~> 2.0`):

```hcl
locals {
  project_account_name = var.project_account_name != "" ? var.project_account_name : "aisproj-${var.suffix}"
  project_name         = "codexproj"
}

# NEW project-enabled AIServices account. azapi (not azurerm) because azurerm ~>4.20 has no
# allowProjectManagement argument. Fireworks models require the project route for Responses.
resource "azapi_resource" "project_account" {
  count     = var.enable_project_account ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name      = local.project_account_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  body = {
    kind = "AIServices"
    sku  = { name = "S0" }
    identity = { type = "SystemAssigned" }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.project_account_name
      disableLocalAuth       = true
      publicNetworkAccess    = "Enabled"
    }
  }
  response_export_values = ["properties.endpoints", "properties.endpoint"]
}

# Child project. Its inference route is /api/projects/<name>/openai/v1.
resource "azapi_resource" "project" {
  count     = var.enable_project_account ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = local.project_name
  parent_id = azapi_resource.project_account[0].id
  location  = var.location
  body = {
    identity   = { type = "SystemAssigned" }
    properties = {}
  }
}
```

The foundry module does NOT currently have `azurerm_client_config` (confirmed — it's only at root `infra/main.tf:1`). Add this data block at the top of `infra/modules/foundry/main.tf`:

```hcl
data "azurerm_client_config" "current" {}
```

- [ ] **Step 3: Add outputs**

In `infra/modules/foundry/main.tf` (or the module's outputs section):

```hcl
output "project_account_id" {
  description = "Resource id of the project-enabled AIServices account (for RBAC + deployments). Null when disabled."
  value       = one(azapi_resource.project_account[*].id)
}

output "project_responses_base" {
  description = "Project-route OpenAI/v1 base for the sidecar backend: https://<acct>.services.ai.azure.com/api/projects/<proj>/openai/v1. Null when disabled."
  value = var.enable_project_account ? "https://${local.project_account_name}.services.ai.azure.com/api/projects/${local.project_name}/openai/v1" : null
}
```

- [ ] **Step 4: fmt + validate**

Run: `cd infra && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add infra/modules/foundry/
git commit -m "feat(infra): project-enabled Foundry account + project via azapi"
```

---

### Task 4: Model deployments on the new account (GLM + ladder)

Deploy GLM + DeepSeek + all downgrade-ladder targets onto the new account so a downgraded `model` always resolves. Ladder (docs/02-governance.md:127): `gpt-5.4 → gpt-5.4-mini → grok-4.3`; plus the sidecar's own models GLM/DeepSeek.

> **Quota gate (Global Constraint):** before applying, re-audit live quota and confirm/execute the deletions in Task 8 first. This task only defines the Terraform; the apply happens after quota is freed.

**Files:**
- Modify: `infra/modules/foundry/main.tf` (deployments bound to the new account)
- Modify: `infra/variables.tf` (`project_deployments` variable)
- Modify: `infra/main.tf` (pass `project_deployments` into the module)

**Interfaces:**
- Consumes: `azapi_resource.project_account[0].id` (Task 3).
- Produces: `azurerm_cognitive_deployment` resources on the new account, keyed by client-facing model name.

- [ ] **Step 1: Add the `project_deployments` variable**

In `infra/variables.tf`, add (GLM version/format/sku from live bench account: `FW-GLM-5.2`, `Fireworks`, `1`, `DataZoneStandard`):

```hcl
variable "project_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = {
    "FW-GLM-5.2" = {
      model_name    = "FW-GLM-5.2"
      model_format  = "Fireworks"
      model_version = "1"
      sku_name      = "DataZoneStandard"
      capacity      = 500
    }
    "DeepSeek-V4-Pro" = {
      model_name    = "DeepSeek-V4-Pro"
      model_format  = "DeepSeek"
      model_version = "2026-04-23"
      sku_name      = "GlobalStandard"
      capacity      = 500
    }
    "grok-4.3" = {
      model_name    = "grok-4.3"
      model_format  = "xAI"
      model_version = "1"
      sku_name      = "GlobalStandard"
      capacity      = 10
    }
  }
  description = "Model deployments on the project-enabled account fronted by the Codex proxy sidecar. Includes the sidecar's models (GLM, DeepSeek) plus every downgrade-ladder target that could arrive via APIM downgrade, so a rewritten model always resolves. gpt-5.4/mini stay on the OpenAI path (not deployed here)."
}
```

Note in the description that gpt-5.4/gpt-5.4-mini are Azure OpenAI (openai module) — they are NOT reachable through the sidecar route, so a consumer whose ladder downgrades a sidecar model down to gpt-5.4 would 404 at the sidecar. The plan's scope is sidecar models (GLM/DeepSeek) whose ladders stay within Foundry models (→ grok-4.3). Document this boundary; do not silently deploy gpt to Foundry.

- [ ] **Step 2: Add deployments bound to the new account**

In `infra/modules/foundry/main.tf`, add (mirrors the existing `azurerm_cognitive_deployment.models` at lines 95-110, but targets the azapi account):

```hcl
variable "project_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default     = {}
  description = "Deployments for the project-enabled account (passed from root)."
}

resource "azurerm_cognitive_deployment" "project_models" {
  for_each             = var.enable_project_account ? var.project_deployments : {}
  name                 = each.key
  cognitive_account_id = azapi_resource.project_account[0].id

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

- [ ] **Step 3: Wire the variable through root main.tf**

In `infra/main.tf`, in the `module "foundry"` block, add:

```hcl
  enable_project_account = var.enable_codexproxy
  project_deployments    = var.project_deployments
```

(`var.enable_codexproxy` is defined in Task 6; for now this references it — apply happens after Task 6.)

- [ ] **Step 4: fmt + validate**

Run: `cd infra && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.` (`enable_codexproxy` was defined in Task 3 Step 1, so this validates cleanly.)

- [ ] **Step 5: Commit**

```bash
git add infra/variables.tf infra/modules/foundry/ infra/main.tf
git commit -m "feat(infra): project-account model deployments (GLM + ladder targets)"
```

---

### Task 5: Sidecar identity + hop secret + RBAC

Create the sidecar's user-assigned identity, the generated master key + APIM named value, and the backend + ACR RBAC. Mirrors the removed LiteLLM identity/secret/role pattern.

**Files:**
- Modify: `infra/modules/identity/main.tf` (identity + 3 outputs)
- Modify: `infra/main.tf` (random_password, named value, role assignments, `enable_codexproxy` local)

**Interfaces:**
- Consumes: `module.foundry.project_account_id` (Task 3), `module.identity.codexproxy_*` (this task), ACR id, APIM name.
- Produces: `local.codexproxy_key`, APIM named value `codexproxy-key`, MI outputs `codexproxy_principal_id`/`codexproxy_client_id`/`codexproxy_id`.

- [ ] **Step 1: Add the identity + outputs**

In `infra/modules/identity/main.tf`, add (mirrors `config_sync_worker` at lines 65-85):

```hcl
# Codex proxy sidecar identity. Calls the project-enabled Foundry account with this identity
# (ManagedIdentityCredential), so it needs Cognitive Services User on that account.
resource "azurerm_user_assigned_identity" "codex_proxy" {
  name                = "id-codexproxy-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

output "codexproxy_principal_id" {
  description = "Object ID of the Codex proxy identity (for backend Cognitive Services + ACR RBAC)."
  value       = azurerm_user_assigned_identity.codex_proxy.principal_id
}

output "codexproxy_client_id" {
  description = "Client ID of the Codex proxy identity (AZURE_CLIENT_ID for ManagedIdentityCredential)."
  value       = azurerm_user_assigned_identity.codex_proxy.client_id
}

output "codexproxy_id" {
  description = "Resource ID of the Codex proxy identity (to attach to the Container App)."
  value       = azurerm_user_assigned_identity.codex_proxy.id
}
```

- [ ] **Step 2: Add the enable local, master key, and named value in root**

In `infra/main.tf`, add near the top locals and resources:

```hcl
resource "random_password" "codexproxy_key" {
  count   = var.enable_codexproxy ? 1 : 0
  length  = 48
  special = false
}

locals {
  codexproxy_key = var.enable_codexproxy ? "sk-${random_password.codexproxy_key[0].result}" : ""
}

# APIM<->sidecar hop secret, presented by the policy as Authorization: Bearer {{codexproxy-key}}.
resource "azurerm_api_management_named_value" "codexproxy_key" {
  count               = var.enable_codexproxy ? 1 : 0
  name                = "codexproxy-key"
  api_management_name = module.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "codexproxy-key"
  value               = local.codexproxy_key
  secret              = true
}
```

- [ ] **Step 3: Add backend + ACR RBAC for the sidecar identity**

In `infra/main.tf`, add (mirrors the removed `litellm_to_foundry`, scoped to the NEW account):

```hcl
resource "azurerm_role_assignment" "codexproxy_to_project_account" {
  count                = var.enable_codexproxy ? 1 : 0
  scope                = module.foundry.project_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.identity.codexproxy_principal_id
}
```

(ACR pull is granted inside the control_plane module in Task 6, following the `admin_ui_acr_pull` pattern.)

- [ ] **Step 4: fmt + validate**

Run: `cd infra && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.` (`enable_codexproxy` defined in Task 3 Step 1.)

- [ ] **Step 5: Commit**

```bash
git add infra/modules/identity/main.tf infra/main.tf
git commit -m "feat(infra): codex-proxy identity, hop key, backend RBAC"
```

---

### Task 6: Container App + wiring

Add the `codexproxy` Container App to the control_plane module (mirroring `admin_ui`), the `codexproxy_image`/`enable_codexproxy` variables, ACR-pull RBAC, the FQDN output, and the private-DNS toggle update. Wire module inputs in root.

**Files:**
- Modify: `infra/variables.tf` (`enable_codexproxy`, `codexproxy_image`)
- Modify: `infra/modules/control_plane/main.tf` (container app, vars, local, acr-pull, output, dns toggle)
- Modify: `infra/main.tf` (`module "control_plane"` passthroughs)

**Interfaces:**
- Consumes: `module.identity.codexproxy_id/principal_id/client_id`, `local.codexproxy_key`, `module.foundry.project_responses_base`, ACR login server/id.
- Produces: `module.control_plane.codexproxy_fqdn` (internal FQDN for `responses.tf` service_url).

- [ ] **Step 1: Add the image variable (root)**

`enable_codexproxy` was already defined in Task 3 Step 1. Here add only the image variable to `infra/variables.tf` (mirrors `admin_ui_image`):

```hcl
variable "codexproxy_image" {
  type        = string
  default     = ""
  description = "Full image reference for the Codex proxy sidecar, e.g. acrllmgwxxxx.azurecr.io/codexproxy:latest. Empty disables the Container App."
}
```

- [ ] **Step 2: Add control_plane module variables + local**

In `infra/modules/control_plane/main.tf`, add module input vars (mirror `admin_ui_*`):

```hcl
variable "codexproxy_image" {
  type        = string
  default     = ""
  description = "Codex proxy sidecar image reference. Empty disables the app."
}
variable "codexproxy_identity_id" {
  type        = string
  default     = ""
  description = "Resource ID of the Codex proxy user-assigned identity."
}
variable "codexproxy_principal_id" {
  type        = string
  default     = ""
  description = "Principal (object) ID of the Codex proxy identity (for ACR pull RBAC)."
}
variable "codexproxy_client_id" {
  type        = string
  default     = ""
  description = "Client ID of the Codex proxy identity (AZURE_CLIENT_ID)."
}
variable "codexproxy_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "APIM<->sidecar hop secret (PROXY_KEY env)."
}
variable "codexproxy_project_base" {
  type        = string
  default     = ""
  description = "Foundry project Responses base URL (FOUNDRY_PROJECT_BASE env)."
}
```

Update the `locals` block (currently line ~164) to add the enable flag and extend the private-DNS toggle:

```hcl
locals {
  worker_enabled     = var.worker_image != ""
  admin_ui_enabled   = var.admin_ui_image != ""
  codexproxy_enabled = var.codexproxy_image != ""
  aca_private_dns_enabled = (local.admin_ui_enabled || local.codexproxy_enabled) && !var.admin_ui_public
}
```

(Match the existing locals keys already present; only add `codexproxy_enabled` and extend `aca_private_dns_enabled`.)

- [ ] **Step 3: Add ACR-pull RBAC + Container App + FQDN output**

In `infra/modules/control_plane/main.tf`, add (mirrors `admin_ui_acr_pull` + `admin_ui` container app + `admin_ui_fqdn`):

```hcl
resource "azurerm_role_assignment" "codexproxy_acr_pull" {
  count                = local.codexproxy_enabled ? 1 : 0
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = var.codexproxy_principal_id
}

# Codex proxy sidecar. Same CAE as the Admin UI; internal ingress on 8789. APIM's /responses API
# routes here and authenticates with the hop key. The proxy calls the Foundry project backend with
# its managed identity (ManagedIdentityCredential), no keys.
resource "azurerm_container_app" "codexproxy" {
  count                        = local.codexproxy_enabled ? 1 : 0
  name                         = "ca-codexproxy-${var.name_suffix}"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.cp.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.codexproxy_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.codexproxy_identity_id
  }

  ingress {
    external_enabled = true
    target_port      = 8789
    transport        = "auto"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "codexproxy"
      image  = var.codexproxy_image
      cpu    = 0.5
      memory = "1Gi"

      startup_probe {
        transport               = "TCP"
        port                    = 8789
        initial_delay           = 5
        interval_seconds        = 5
        failure_count_threshold = 30
      }

      env {
        name  = "FOUNDRY_PROJECT_BASE"
        value = var.codexproxy_project_base
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = var.codexproxy_client_id
      }
      env {
        name  = "PROXY_KEY"
        value = var.codexproxy_key
      }
      env {
        name  = "PORT"
        value = "8789"
      }
    }
  }
}

output "codexproxy_fqdn" {
  description = "Internal FQDN of the Codex proxy Container App (null until codexproxy_image is set). APIM /responses service_url."
  value       = one(azurerm_container_app.codexproxy[*].ingress[0].fqdn)
}
```

- [ ] **Step 4: Wire module inputs in root main.tf**

In `infra/main.tf`, in the `module "control_plane"` block, add:

```hcl
  codexproxy_image        = var.codexproxy_image
  codexproxy_identity_id  = module.identity.codexproxy_id
  codexproxy_principal_id = module.identity.codexproxy_principal_id
  codexproxy_client_id    = module.identity.codexproxy_client_id
  codexproxy_key          = local.codexproxy_key
  codexproxy_project_base = module.foundry.project_responses_base
```

- [ ] **Step 5: fmt + validate**

Run: `cd infra && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add infra/variables.tf infra/modules/control_plane/main.tf infra/main.tf
git commit -m "feat(infra): codex-proxy Container App + wiring"
```

---

### Task 7: APIM `/responses` repoint + policy hop auth

Point `/responses` `service_url` at the sidecar FQDN (when enabled), and swap the policy's backend MI auth for master-key injection. Both gated so that with `enable_codexproxy=false` the current direct-to-Foundry path is unchanged.

**Files:**
- Modify: `infra/responses.tf` (`service_url` conditional)
- Modify: `policies/responses-pipeline.xml.tftpl` (backend boundary)

**Interfaces:**
- Consumes: `module.control_plane.codexproxy_fqdn` (Task 6), `var.enable_codexproxy`, named value `codexproxy-key` (Task 5).
- Produces: `/responses` routing to the sidecar with hop auth.

- [ ] **Step 1: Make `service_url` conditional**

In `infra/responses.tf`, replace line 30 (`service_url = module.foundry.endpoint_openai_v1`) with:

```hcl
  # When the Codex proxy sidecar is enabled, /responses fronts the sidecar (which normalizes Codex
  # payloads + forwards to the Foundry project route). Otherwise it hits the AIServices account直接.
  service_url = var.enable_codexproxy ? "https://${module.control_plane.codexproxy_fqdn}" : module.foundry.endpoint_openai_v1
```

(Sidecar accepts any POST path ending `/responses`; the wildcard operation forwards `/responses`, so the base FQDN with no suffix yields `https://<fqdn>/responses`.)

- [ ] **Step 2: Parameterize the policy's backend auth**

The policy template needs to choose between MI auth (current) and master-key (sidecar). Add a template var. In `infra/responses.tf`, add to the `templatefile(...)` map (line ~55-60):

```hcl
    codexproxy_enabled = var.enable_codexproxy
```

- [ ] **Step 3: Edit the policy backend boundary**

In `policies/responses-pipeline.xml.tftpl`, replace the backend-boundary block (lines 163-171) with a conditional:

```xml
%{ if codexproxy_enabled ~}
    <!-- [Privilege] Backend boundary: the backend is the Codex proxy sidecar. Present the hop key
         (the sidecar validates it, then calls Foundry with ITS managed identity). MUST stay last. -->
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + "{{codexproxy-key}}")</value>
    </set-header>
%{ else ~}
    <!-- [Privilege] Backend boundary: APIM authenticates to the AIServices account with its MI.
         Same as the /foundry pipeline — the backend is the AIServices account directly. MUST stay last. -->
    <authentication-managed-identity resource="https://cognitiveservices.azure.com"
                                     output-token-variable-name="msi-access-token" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
%{ endif ~}
  </inbound>
```

- [ ] **Step 4: Add depends_on for the named value**

In `infra/responses.tf`, in `azurerm_api_management_api_policy.responses`'s `depends_on` (line ~63), the named value only exists when enabled; add it conditionally is not expressible in a static list, so reference it via the templatefile (already does) and rely on the named value resource's own creation. To be safe, leave `depends_on` as-is (the named value is referenced by `{{...}}` at runtime, not plan-time).

- [ ] **Step 5: fmt + validate**

Run: `cd infra && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add infra/responses.tf policies/responses-pipeline.xml.tftpl
git commit -m "feat(infra): /responses repoint to sidecar + master-key hop (toggled)"
```

---

### Task 8: Quota audit + free (deletion, confirmed)

Free quota for the new deployments by removing gateway-unused benchmark deployments. **Kimi-K2.7-Code MUST survive.** Re-audit live before deleting.

**Files:** none (Azure CLI operations, not Terraform — these are ad-hoc bench resources outside this repo's state).

- [ ] **Step 1: Re-audit live quota**

Run:
```bash
for loc in westus westus3 eastus; do echo "=== $loc ==="; az cognitiveservices usage list -l $loc --query "[?currentValue>\`0\`].{name:name.value,used:currentValue,limit:limit}" -o table; done
```
Expected: current usage per region. Record which SKUs are maxed.

- [ ] **Step 2: Confirm deletion targets exist and are unused**

Run:
```bash
az cognitiveservices account deployment list -n ai-fw-wus3-jc-486745 -g rg-model-benchmark -o table
az cognitiveservices account deployment list -n ais-eastus-demo -g rg-ai-foundry -o table
az cognitiveservices account deployment list -n ai-fw-wus-jc-486745 -g rg-model-benchmark -o table
```
Expected: confirm `bench-glm-52-westus3` (FW-GLM-5.2 dup), `bench-minimax-m25-eastus` (FW-MiniMax), and on the westus account both FW-GLM-5.2 and **Kimi-K2.7-Code (keep this)**.

- [ ] **Step 3: STOP — get explicit human confirmation before any delete**

Print the exact deletion list and wait for confirmation. Per Global Constraint, no deletion runs unconfirmed.

- [ ] **Step 4: Delete the confirmed duplicates (Kimi preserved)**

Run (only after confirmation):
```bash
az cognitiveservices account deployment delete -n ai-fw-wus3-jc-486745 -g rg-model-benchmark --deployment-name bench-glm-52-westus3
az cognitiveservices account deployment delete -n ais-eastus-demo -g rg-ai-foundry --deployment-name bench-minimax-m25-eastus
```
Expected: deletions succeed. Do NOT touch Kimi-K2.7-Code. Leave the westus FW-GLM-5.2 until Step 5 confirms the new account's GLM is live.

- [ ] **Step 5: Verify freed quota**

Run: `az cognitiveservices usage list -l westus3 --query "[?contains(name.value,'DataZone')].{name:name.value,used:currentValue,limit:limit}" -o table`
Expected: the freed FW-GLM capacity is available.

---

### Task 9: Deploy + end-to-end verification

Apply Terraform in dependency order, build/push the image, and verify governance end-to-end.

**Files:** none (deployment + verification).

- [ ] **Step 1: Build and push the sidecar image to ACR**

Run (ACR name from existing infra outputs):
```bash
ACR=$(cd infra && terraform output -raw acr_login_server)
az acr build --registry ${ACR%%.*} --image codexproxy:latest app/codex-proxy
```
Expected: image pushed as `${ACR}/codexproxy:latest`.

- [ ] **Step 2: Apply with the sidecar enabled**

Set in tfvars (or `-var`): `enable_codexproxy=true`, `codexproxy_image="<ACR>/codexproxy:latest"`.
Run:
```bash
cd infra && terraform plan -out=tfplan -var enable_codexproxy=true -var codexproxy_image="${ACR}/codexproxy:latest"
terraform apply -input=false tfplan
```
Expected: new account, project, deployments, identity, key, container app, `/responses` repoint all created. Review the plan before apply.

- [ ] **Step 3: Selftest inside the running container (normalization intact)**

Run: `az containerapp exec -n ca-codexproxy-<suffix> -g <rg> --command "python foundry_codex_proxy.py --selftest"`
Expected: `selftest OK`

- [ ] **Step 4: Hop auth — direct call without the key → 401**

Run: `curl -sS -o /dev/null -w "%{http_code}\n" -X POST "https://<codexproxy-fqdn>/responses" -H "Content-Type: application/json" -d '{"model":"FW-GLM-5.2","input":"hi"}'`
Expected: `401` (no master key).

- [ ] **Step 5: e2e through APIM for GLM and DeepSeek**

Configure Codex to the APIM `/responses` endpoint (subscription key), then run per model:
```
codex --profile glm --sandbox workspace-write "Create hello.txt with 'hi', then shell-print it."
codex --profile deepseek --sandbox workspace-write "Create hello.txt with 'hi', then shell-print it."
```
Expected: file created + contents printed; turn completes; multi-agent prompt also completes.

- [ ] **Step 6: Governance observed**

- allowed-models 403: request a model NOT in `allowed_models` → 403.
- rate limit 429: exceed the consumer's TPM → 429.
- downgrade: set a consumer `active_downgrade` and confirm the served model steps down the ladder AND resolves (per Consistency A).
- metrics: confirm consumer + token dimensions in Application Insights (`requests` + `customMetrics`).

Run the App Insights check:
```bash
az monitor app-insights query -g <rg> -a <appinsights> --analytics-query "requests | where timestamp > ago(10m) | where name contains 'responses' | project timestamp, resultCode" -o table
```
Expected: 200s for allowed calls, 403/429 for the governance probes.

- [ ] **Step 7: Commit any tfvars/docs changes**

```bash
git add -A
git commit -m "chore(infra): enable codex-proxy sidecar; e2e governance verified"
```

---

## Verification summary
- Task 1/2: `--selftest` green locally and in-image.
- Task 3-7: `terraform fmt` + `validate` green after each.
- Task 8: quota freed, Kimi preserved, deletions confirmed.
- Task 9: in-container selftest green; hop 401; GLM+DeepSeek e2e (edit+shell+multi-agent) complete; four governance behaviors (allowed-models 403, rate-limit 429, downgrade-with-resolvable-target, metrics) observed through APIM.
