# Single Foundry GPT-5.6 Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three-account model topology with one private project-enabled AIServices account serving `gpt-5.6-sol`, `FW-GLM-5.2`, `DeepSeek-V4-Pro`, and `grok-4.3` consistently through APIM, Codex, VS Code BYOK, and the Admin UI.

**Architecture:** Promote the existing live `aisproj-c0gvf2` resource by preserving its Terraform addresses, adding GPT-5.6 and private networking, and routing every API surface to it. Terraform defaults create the same one-account topology from scratch; legacy account resources are forgotten without destruction during migration and deleted manually only after private cutover verification.

**Tech Stack:** Terraform 1.15+, AzureRM 4.x, AzAPI 2.x, Azure API Management, Microsoft Foundry/AIServices, Azure Container Apps, Python 3/pytest, Azure CLI, PowerShell, Bash.

## Global Constraints

- The only final gateway model deployments are `gpt-5.6-sol`, `FW-GLM-5.2`, `DeepSeek-V4-Pro`, and `grok-4.3`.
- `gpt-5.6-sol` uses model version `2026-07-09`, `GlobalStandard`, capacity `500`.
- The final backend is one project-enabled `AIServices` account with project `codexproj`.
- Final account settings are `allowProjectManagement=true`, `disableLocalAuth=true`, `publicNetworkAccess=Disabled`, and private endpoint/DNS enabled.
- APIM gets both `Cognitive Services OpenAI User` and `Cognitive Services User` on the canonical account.
- The Codex proxy remains only for Responses payload normalization and calls the same canonical project.
- APIM allowed models and Admin UI `ALIAS_MODELS_JSON` derive from the unified deployment map.
- `legacy_gpt_compat_enabled` and `admin_ui_legacy_gpt_aliases_enabled` default to `false`; they
  exist only for the staged Task 7-9 migration.
- Current live state is the managed `reuse_foundry=false` history and must retain the existing
  canonical project account/project/deployment addresses. Sidecar-era reuse history with those
  managed addresses is converted to this same path by exact account name, never by moving old APIM
  fallback roles.
- No obsolete account, deployment, private endpoint, or role assignment is destroyed in the first migration apply.
- Never apply the ignored local `infra/terraform.tfstate` to live resources; live changes use the private remote backend from the VNet jumpbox.
- Kimi resources are outside this gateway topology and must never appear in a deletion command.
- Do not invent GPT-5.6 prices. As of 2026-07-10, the Azure retail-price feed does not expose a GPT-5.6 meter; document the temporary budget-accounting limitation explicitly.
- Every Azure implementation decision must stay consistent with:
  - https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56
  - https://learn.microsoft.com/azure/foundry/openai/how-to/responses#supported-models
  - https://learn.microsoft.com/azure/foundry/how-to/configure-private-link
  - https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity

## File map

| Responsibility | Files |
|---|---|
| GPT-5.6 Responses normalization | `app/codex-proxy/foundry_codex_proxy.py`, `app/codex-proxy/tests/test_server.py` |
| Canonical account/project/deployments/PE | `infra/modules/foundry/main.tf`, `infra/modules/foundry/tests/single_account.tftest.hcl` |
| Unified model input and root wiring | `infra/variables.tf`, `infra/locals.tf`, `infra/main.tf`, `infra/outputs.tf`, `infra/responses.tf`, `infra/tests/default_topology.tftest.hcl` |
| APIM one-account routing/RBAC | `infra/modules/apim/main.tf`, `policies/openai-pipeline.xml.tftpl`, `policies/foundry-pipeline.xml.tftpl` |
| Remove split OpenAI implementation | `infra/modules/openai/main.tf` |
| Catalog defaults | `app/admin-ui/bff/config.py`, `app/admin-ui/bff/tests/test_config.py`, `infra/modules/control_plane/main.tf` |
| Plan safety gate | `scripts/verify_model_topology_plan.py`, `scripts/tests/test_verify_model_topology_plan.py` |
| Deployment examples/smokes | `infra/terraform.tfvars.example`, `scripts/seed-cosmos-jumpbox.sh`, `scripts/seed-pricing-jumpbox.sh`, `scripts/smoke-v1-backend.sh`, `scripts/smoke-v1-gateway.sh` |
| User documentation | `README.md`, `docs/01-overview.md`, `docs/03-deploy.md`, `docs/03-deploy/case-all-in-one.md`, `docs/03-deploy/case-apim-core-first.md`, `docs/03-deploy/case-foundry-greenfield.md`, `docs/04-reuse-foundry.md`, `docs/07-connect-clients/codex-cli.md`, `docs/07-connect-clients/direct-api.md`, `docs/07-connect-clients/vscode-byok.md`, `docs/08-architecture.md`, `docs/10-reference.md` |
| Live-only configuration | ignored `infra/terraform.tfvars`, `C:\Users\jisunchoi\AppData\Roaming\Code\User\chatLanguageModels.json`, Cosmos `global` and `consumer:*` documents |

---

### Task 1: Preserve GPT-5.6 reasoning in the Codex proxy

**Files:**
- Modify: `app/codex-proxy/tests/test_server.py`
- Modify: `app/codex-proxy/foundry_codex_proxy.py:158-197`

**Interfaces:**
- Consumes: request body field `model` and optional `reasoning`.
- Produces: route field `reasoning_mode` with values `required`, `passthrough`, or `unsupported`.
- Produces: `normalize_request()` that preserves GPT-5.6 reasoning, injects GLM reasoning when absent, and strips unsupported effort fields for DeepSeek/grok.

- [ ] **Step 1: Add failing reasoning-mode tests**

Append:

```python
def _enable_project_route(monkeypatch):
    monkeypatch.setattr(
        proxy,
        "FOUNDRY_PROJECT_BASE",
        "https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1",
    )


def test_gpt_56_preserves_reasoning(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "gpt-5.6-sol",
        "reasoning": {"effort": "high", "summary": "auto"},
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "passthrough"
    assert body["reasoning"] == {"effort": "high", "summary": "auto"}


def test_glm_injects_required_reasoning(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {"model": "FW-GLM-5.2"}

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "required"
    assert body["reasoning"] == {"effort": "medium"}


def test_deepseek_strips_reasoning_effort(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "DeepSeek-V4-Pro",
        "reasoning": {"effort": "high", "summary": "auto"},
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "unsupported"
    assert body["reasoning"] == {"summary": "auto"}
```

- [ ] **Step 2: Run the tests and confirm the new contract fails**

Run:

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway
python -m pytest app\codex-proxy\tests\test_server.py -q
```

Expected: the three new tests fail because routes expose `reasoning_effort`, not `reasoning_mode`, and GPT-5.6 effort is stripped.

- [ ] **Step 3: Implement explicit reasoning modes**

Replace `_normalize_reasoning`, the model set, and `_route_for` with:

```python
def _normalize_reasoning(body, route):
    mode = route["reasoning_mode"]
    r = body.get("reasoning")
    if mode == "required":
        if not isinstance(r, dict):
            body["reasoning"] = {"effort": "medium"}
    elif mode == "unsupported":
        if isinstance(r, dict):
            r.pop("effort", None)
        elif "reasoning" in body:
            del body["reasoning"]


REASONING_MODES = {
    "FW-GLM-5.2": "required",
    "gpt-5.6-sol": "passthrough",
}


def _route_for(model):
    if not FOUNDRY_PROJECT_BASE:
        return None
    return {
        "base_url": FOUNDRY_PROJECT_BASE,
        "reasoning_mode": REASONING_MODES.get(model, "unsupported"),
    }
```

- [ ] **Step 4: Run proxy tests and self-test**

Run:

```powershell
python -m pytest app\codex-proxy\tests\test_server.py -q
python app\codex-proxy\foundry_codex_proxy.py --selftest
```

Expected: all tests pass and self-test prints `selftest OK`.

- [ ] **Step 5: Commit**

```powershell
git add app\codex-proxy\foundry_codex_proxy.py app\codex-proxy\tests\test_server.py
git commit -m "feat(codex-proxy): support GPT-5.6 reasoning"
```

---

### Task 2: Add a Terraform plan safety gate

**Files:**
- Create: `scripts/verify_model_topology_plan.py`
- Create: `scripts/tests/test_verify_model_topology_plan.py`

**Interfaces:**
- Consumes: a JSON file produced by `terraform show -json` and mode `fresh` or `migration`.
- Produces: exit `0` with `model topology plan OK`, or exit `1` with one error per violated invariant.

- [ ] **Step 1: Write failing unit tests**

Create `scripts/tests/test_verify_model_topology_plan.py`:

```python
import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "verify_model_topology_plan.py"
SPEC = importlib.util.spec_from_file_location("verify_model_topology_plan", MODULE_PATH)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


def plan(*changes):
    return {"resource_changes": list(changes)}


def change(address, actions):
    return {"address": address, "change": {"actions": actions}}


def test_fresh_plan_accepts_only_canonical_models():
    value = plan(
        change("module.foundry.azapi_resource.project_account[0]", ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["gpt-5.6-sol"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["FW-GLM-5.2"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["DeepSeek-V4-Pro"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["grok-4.3"]', ["create"]),
    )
    assert verify.verify_plan(value, "fresh") == []


def test_fresh_plan_rejects_split_openai_module():
    value = plan(
        change("module.openai[0].azurerm_cognitive_account.openai[0]", ["create"]),
    )
    errors = verify.verify_plan(value, "fresh")
    assert any("module.openai" in error for error in errors)


def test_migration_plan_rejects_fallback_deletion():
    value = plan(
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["delete"]),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("protected fallback" in error for error in errors)


def test_migration_plan_allows_forget_without_destroy():
    value = plan(
        change("module.openai[0].azurerm_cognitive_account.openai[0]", ["forget"]),
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["forget"]),
        change("module.foundry.azapi_resource.project_account[0]", ["update"]),
    )
    assert verify.verify_plan(value, "migration") == []


def test_migration_plan_rejects_canonical_account_replacement():
    value = plan(
        change("module.foundry.azapi_resource.project_account[0]", ["delete", "create"]),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("canonical account replacement" in error for error in errors)
```

- [ ] **Step 2: Run the tests and confirm import failure**

Run:

```powershell
python -m pytest scripts\tests\test_verify_model_topology_plan.py -q
```

Expected: FAIL because `scripts/verify_model_topology_plan.py` does not exist.

- [ ] **Step 3: Implement the verifier**

Create `scripts/verify_model_topology_plan.py`:

```python
#!/usr/bin/env python3
import json
import sys
from pathlib import Path


CANONICAL_ACCOUNT = "module.foundry.azapi_resource.project_account[0]"
EXPECTED_MODELS = {
    "gpt-5.6-sol",
    "FW-GLM-5.2",
    "DeepSeek-V4-Pro",
    "grok-4.3",
}
MODEL_PREFIX = "module.foundry.azurerm_cognitive_deployment.project_models["
PROTECTED_FALLBACK_PREFIXES = (
    "module.openai",
    "module.foundry.azurerm_cognitive_account.foundry",
    "module.foundry.azurerm_cognitive_deployment.models",
    "module.foundry.azurerm_private_endpoint.foundry",
    "module.apim.azurerm_role_assignment.apim_to_openai",
    "module.apim.azurerm_role_assignment.apim_to_foundry",
)


def _changes(plan):
    return plan.get("resource_changes") or []


def _actions(change):
    return change.get("change", {}).get("actions") or []


def _model_name(address):
    if not address.startswith(MODEL_PREFIX):
        return None
    return address.split('["', 1)[1].rsplit('"]', 1)[0]


def verify_plan(plan, mode):
    errors = []
    changes = _changes(plan)
    if mode == "fresh":
        if any(change.get("address", "").startswith("module.openai") for change in changes):
            errors.append("fresh plan contains the removed module.openai topology")
        models = {
            name
            for change in changes
            if (name := _model_name(change.get("address", ""))) is not None
            and "create" in _actions(change)
        }
        if models != EXPECTED_MODELS:
            errors.append(
                "fresh plan model set mismatch: "
                f"expected={sorted(EXPECTED_MODELS)} actual={sorted(models)}"
            )
        if not any(
            change.get("address") == CANONICAL_ACCOUNT and "create" in _actions(change)
            for change in changes
        ):
            errors.append("fresh plan does not create the canonical project-enabled account")
    elif mode == "migration":
        for change in changes:
            address = change.get("address", "")
            actions = _actions(change)
            if "delete" in actions and address.startswith(PROTECTED_FALLBACK_PREFIXES):
                errors.append(f"protected fallback would be destroyed: {address}")
            if address == CANONICAL_ACCOUNT and "delete" in actions:
                errors.append("canonical account replacement is forbidden")
    else:
        errors.append(f"unsupported mode: {mode}")
    return errors


def main(argv):
    if len(argv) != 3:
        print("usage: verify_model_topology_plan.py PLAN_JSON_PATH {fresh|migration}", file=sys.stderr)
        return 2
    plan = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    errors = verify_plan(plan, argv[2])
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("model topology plan OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
```

- [ ] **Step 4: Run verifier tests**

Run:

```powershell
python -m pytest scripts\tests\test_verify_model_topology_plan.py -q
```

Expected: `5 passed`.

- [ ] **Step 5: Commit**

```powershell
git add scripts\verify_model_topology_plan.py scripts\tests\test_verify_model_topology_plan.py
git commit -m "test(infra): guard single-account migration plans"
```

---

### Task 3: Refactor the Foundry module to one project-enabled account

**Files:**
- Create: `infra/modules/foundry/tests/single_account.tftest.hcl`
- Modify: `infra/modules/foundry/main.tf`

**Interfaces:**
- Consumes: `account_name`, `project_name`, `public_network_access_enabled`, and unified `deployments`.
- Produces: `id`, `name`, `endpoint`, `endpoint_openai_v1`, `endpoint_openai_host`, `deployment_names`, `project_account_id`, and `project_responses_base`.
- Preserves live resource addresses `azapi_resource.project_account`, `azapi_resource.project`, and `azurerm_cognitive_deployment.project_models`.

- [ ] **Step 1: Add the failing module test**

Create `infra/modules/foundry/tests/single_account.tftest.hcl`:

```hcl
mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "time" {}

run "greenfield_single_account" {
  command = plan

  variables {
    name_suffix                  = "aigw-test-eus2"
    suffix                       = "abc123"
    resource_group_name          = "rg-aigw-test-eus2"
    location                     = "eastus2"
    tags                         = { env = "test" }
    pe_subnet_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aigw-test-eus2/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe"
    dns_zone_ids                 = ["/dns/openai", "/dns/cognitive", "/dns/ai"]
    account_name                 = "ais-abc123"
    project_name                 = "codexproj"
    public_network_access_enabled = false
    deployments = {
      "gpt-5.6-sol"       = { model_name = "gpt-5.6-sol", model_format = "OpenAI", model_version = "2026-07-09", sku_name = "GlobalStandard", capacity = 500 }
      "FW-GLM-5.2"        = { model_name = "FW-GLM-5.2", model_format = "Fireworks", model_version = "1", sku_name = "DataZoneStandard", capacity = 500 }
      "DeepSeek-V4-Pro"   = { model_name = "DeepSeek-V4-Pro", model_format = "DeepSeek", model_version = "2026-04-23", sku_name = "GlobalStandard", capacity = 500 }
      "grok-4.3"          = { model_name = "grok-4.3", model_format = "xAI", model_version = "1", sku_name = "GlobalStandard", capacity = 10 }
    }
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.allowProjectManagement
    error_message = "The canonical account must support Foundry projects."
  }

  assert {
    condition     = azapi_resource.project_account[0].body.properties.publicNetworkAccess == "Disabled"
    error_message = "Fresh deployments must be private."
  }

  assert {
    condition     = azapi_resource.project[0].parent_id == azapi_resource.project_account[0].id
    error_message = "The project must be a child of the canonical account."
  }

  assert {
    condition = toset(keys(azurerm_cognitive_deployment.project_models)) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "The canonical account must contain exactly the four supported deployments."
  }

  assert {
    condition     = azurerm_private_endpoint.project_account.private_service_connection[0].private_connection_resource_id == azapi_resource.project_account[0].id
    error_message = "The private endpoint must target the canonical account."
  }
}
```

- [ ] **Step 2: Run the module test and confirm interface failure**

From a temporary copy initialized without the live backend:

```powershell
$tmp = Join-Path $env:TEMP "llm-gateway-foundry-test"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item C:\Users\jisunchoi\projects\llm-gateway\infra\modules\foundry $tmp -Recurse
Set-Location $tmp
terraform init -backend=false
terraform test
```

Expected: FAIL because `account_name`, `project_name`, and `public_network_access_enabled` do not exist and the current module creates two accounts.

- [ ] **Step 3: Replace the split-account variables**

In `infra/modules/foundry/main.tf`, retain the common inputs and unified `deployments`, remove
`enable_project_account`, `project_account_name`, and `project_deployments`, then add:

```hcl
variable "account_name" {
  type        = string
  default     = ""
  description = "Managed project-enabled AIServices account name. Defaults to ais- followed by the generated random suffix."
}

variable "project_name" {
  type        = string
  default     = "codexproj"
  description = "Child Foundry project used by Responses clients."
}

variable "public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Migration escape hatch. Keep false for fresh/final deployments; set true only while validating a newly attached private endpoint."
}
```

- [ ] **Step 4: Remove legacy managed resources without destroying live fallbacks**

Delete the configured `azurerm_cognitive_account.foundry`,
`azurerm_cognitive_deployment.models`, and `azurerm_private_endpoint.foundry` blocks. Add:

```hcl
removed {
  from = azurerm_cognitive_account.foundry
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_cognitive_deployment.models
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_private_endpoint.foundry
  lifecycle {
    destroy = false
  }
}
```

These blocks intentionally produce `forget`, not `delete`, in the migration plan.

- [ ] **Step 5: Make the existing project account canonical**

Use the existing resource addresses with these effective blocks:

```hcl
locals {
  managed_account_name = var.account_name != "" ? var.account_name : "ais-${var.suffix}"
  account_id           = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].id : azapi_resource.project_account[0].id
  account_name         = var.reuse_existing ? data.azurerm_cognitive_account.existing[0].name : local.managed_account_name
}

resource "azapi_resource" "project_account" {
  count     = var.reuse_existing ? 0 : 1
  type      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name      = local.managed_account_name
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  body = {
    kind     = "AIServices"
    sku      = { name = "S0" }
    identity = { type = "SystemAssigned" }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.managed_account_name
      disableLocalAuth       = true
      publicNetworkAccess    = var.public_network_access_enabled ? "Enabled" : "Disabled"
      networkAcls = {
        defaultAction = var.public_network_access_enabled ? "Allow" : "Deny"
      }
    }
  }
  response_export_values = ["properties.endpoints", "properties.endpoint"]
}

resource "azapi_resource" "project" {
  count     = 1
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = var.project_name
  parent_id = local.account_id
  location  = var.location
  body = {
    identity   = { type = "SystemAssigned" }
    properties = {}
  }
}

resource "azurerm_cognitive_deployment" "project_models" {
  for_each             = var.reuse_existing ? {} : var.deployments
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

- [ ] **Step 6: Add the canonical private endpoint**

```hcl
resource "time_sleep" "foundry_settle" {
  depends_on      = [azapi_resource.project_account]
  create_duration = "60s"
  triggers = {
    account_id = local.account_id
  }
}

resource "azurerm_private_endpoint" "project_account" {
  name                = "pe-foundry-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_settle]

  private_service_connection {
    name                           = "psc-foundry"
    private_connection_resource_id = local.account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "foundry-dns"
    private_dns_zone_ids = var.dns_zone_ids
  }
}
```

- [ ] **Step 7: Normalize outputs**

```hcl
output "id" {
  value       = local.account_id
  description = "Canonical project-enabled AIServices account resource ID."
}

output "name" {
  value       = local.account_name
  description = "Canonical project-enabled AIServices account name."
}

output "endpoint" {
  value       = "https://${local.account_name}.cognitiveservices.azure.com/"
  description = "Canonical AIServices control endpoint."
}

output "endpoint_openai_v1" {
  value       = "https://${local.account_name}.openai.azure.com/openai/v1"
  description = "Canonical OpenAI/v1 inference base."
}

output "endpoint_openai_host" {
  value       = "https://${local.account_name}.openai.azure.com"
  description = "Canonical OpenAI host."
}

output "deployment_names" {
  value       = sort(keys(var.deployments))
  description = "Configured deployment names; in reuse mode these describe the expected existing catalog."
}

output "project_account_id" {
  value       = local.account_id
  description = "Compatibility alias for the canonical account ID."
}

output "project_responses_base" {
  value       = "https://${local.account_name}.services.ai.azure.com/api/projects/${var.project_name}/openai/v1"
  description = "Canonical project OpenAI/v1 base used by the Codex proxy."
}
```

- [ ] **Step 8: Run module tests**

Repeat the temporary-copy test command from Step 2.

Expected: `Success! 1 passed, 0 failed.`

- [ ] **Step 9: Commit**

```powershell
git add infra\modules\foundry\main.tf infra\modules\foundry\tests\single_account.tftest.hcl
git commit -m "refactor(infra): make Foundry project account canonical"
```

---

### Task 4: Consolidate root variables, APIM routing, RBAC, and catalog generation

**Files:**
- Create: `infra/tests/default_topology.tftest.hcl`
- Modify: `infra/variables.tf`
- Modify: `infra/locals.tf`
- Modify: `infra/main.tf`
- Modify: `infra/outputs.tf`
- Modify: `infra/responses.tf`
- Modify: `infra/modules/apim/main.tf`
- Modify: `infra/modules/control_plane/main.tf`
- Modify: `policies/openai-pipeline.xml.tftpl`
- Modify: `policies/foundry-pipeline.xml.tftpl`
- Delete: `infra/modules/openai/main.tf`

**Interfaces:**
- Consumes: one `model_deployments` map.
- Produces: `local.allowed_models`, `local.model_tokens_per_minute`, one `module.foundry`, and one `model_account_id`/`model_openai_v1_base` APIM contract.
- Produces: `model_account_name` and `model_openai_v1_endpoint` outputs.

- [ ] **Step 1: Add the failing root topology test**

Create `infra/tests/default_topology.tftest.hcl`:

```hcl
mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {
  mock_resource "random_string" {
    defaults = {
      result = "abc123"
    }
  }
}
mock_provider "time" {}

run "default_model_topology" {
  command = plan

  variables {
    location             = "eastus2"
    owner                = "test@example.com"
    cost_center          = "TEST"
    apim_publisher_name  = "Test"
    apim_publisher_email = "test@example.com"
    budget_alert_email   = "test@example.com"
    budget_start_date    = "2026-07-01T00:00:00Z"
  }

  assert {
    condition = toset(local.allowed_models) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Allowed models must derive from the four canonical deployments."
  }

  assert {
    condition = toset(module.foundry.deployment_names) == toset([
      "gpt-5.6-sol",
      "FW-GLM-5.2",
      "DeepSeek-V4-Pro",
      "grok-4.3",
    ])
    error_message = "Fresh deployments must create the canonical model set."
  }

  assert {
    condition     = module.foundry.project_responses_base != null
    error_message = "A fresh deployment must create the project route."
  }
}
```

- [ ] **Step 2: Run the root test and confirm failure**

Use a temporary repository copy so the live backend is never initialized:

```powershell
$tmp = Join-Path $env:TEMP "llm-gateway-root-test"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item $tmp -ItemType Directory | Out-Null
robocopy C:\Users\jisunchoi\projects\llm-gateway $tmp /E /XD .git .terraform /XF terraform.tfstate terraform.tfstate.backup terraform.tfvars | Out-Null
Set-Location (Join-Path $tmp "infra")
terraform init -backend=false
terraform test -filter=tests/default_topology.tftest.hcl
```

Expected: FAIL because `local.allowed_models` still comes from a separate variable and the default topology is split.

- [ ] **Step 3: Replace three deployment variables with one map**

Remove `openai_deployments`, `foundry_deployments`, `project_deployments`, and `allowed_models`.
Add to `infra/variables.tf`:

```hcl
variable "model_deployments" {
  type = map(object({
    model_name    = string
    model_format  = string
    model_version = string
    sku_name      = string
    capacity      = number
  }))
  default = {
    "gpt-5.6-sol" = {
      model_name    = "gpt-5.6-sol"
      model_format  = "OpenAI"
      model_version = "2026-07-09"
      sku_name      = "GlobalStandard"
      capacity      = 500
    }
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
  description = "Canonical model deployments. Keys are client-visible deployment names and drive APIM/Admin UI catalogs."

  validation {
    condition = alltrue([
      for name, deployment in var.model_deployments :
      name == deployment.model_name && deployment.capacity > 0
    ])
    error_message = "Each deployment key must equal model_name and capacity must be positive."
  }
}

variable "foundry_account_name" {
  type        = string
  default     = ""
  description = "Managed canonical account name override. Set to aisproj-c0gvf2 for the live migration."
}

variable "foundry_project_name" {
  type        = string
  default     = "codexproj"
  description = "Canonical child Foundry project name."
}

variable "foundry_public_network_access_enabled" {
  type        = bool
  default     = false
  description = "Temporary migration escape hatch. Final and fresh deployments keep this false."
}
```

Remove `enable_codexproxy`. Change `route_via_codexproxy` validation to:

```hcl
validation {
  condition     = !var.route_via_codexproxy || var.codexproxy_image != ""
  error_message = "route_via_codexproxy=true requires codexproxy_image."
}
```

- [ ] **Step 4: Derive catalogs and token limits**

Replace the GPT backend selection locals in `infra/locals.tf` with:

```hcl
  allowed_models = sort(keys(var.model_deployments))

  model_tokens_per_minute = {
    for model, deployment in var.model_deployments :
    model => deployment.capacity * 1000
  }

  codexproxy_enabled = var.codexproxy_image != ""
```

- [ ] **Step 5: Remove the separate OpenAI module safely**

Delete the root `module "openai"` block and add to `infra/main.tf`:

```hcl
removed {
  from = module.openai
  lifecycle {
    destroy = false
  }
}
```

Delete `infra/modules/openai/main.tf` after no tracked reference remains.

- [ ] **Step 6: Rewire the canonical Foundry module**

Replace its model/project arguments with:

```hcl
  deployments                  = var.model_deployments
  account_name                 = var.foundry_account_name
  project_name                 = var.foundry_project_name
  public_network_access_enabled = var.foundry_public_network_access_enabled
  reuse_existing               = var.reuse_foundry
  existing_account_name        = var.existing_foundry_name
  existing_account_rg          = var.existing_foundry_rg
```

Remove `enable_project_account` and `project_deployments`.

- [ ] **Step 7: Collapse the APIM module interface**

In `infra/modules/apim/main.tf`, replace `openai_account_id`, `openai_endpoint`,
`foundry_account_id`, `foundry_endpoint`, and `foundry_v1_base` with:

```hcl
variable "model_account_id" {
  type        = string
  description = "Canonical project-enabled AIServices account ID."
}

variable "model_openai_v1_base" {
  type        = string
  description = "Canonical OpenAI/v1 inference base."
}
```

Forget old role assignments without deleting fallback access:

```hcl
removed {
  from = azurerm_role_assignment.apim_to_openai
  lifecycle {
    destroy = false
  }
}

removed {
  from = azurerm_role_assignment.apim_to_foundry
  lifecycle {
    destroy = false
  }
}
```

Create the canonical assignments:

```hcl
resource "azurerm_role_assignment" "apim_to_model_openai" {
  scope                = var.model_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_role_assignment" "apim_to_model_foundry" {
  scope                = var.model_account_id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}
```

Set all three API `service_url` values to `var.model_openai_v1_base`, pass that same value into
both policy templates, and update policy dependencies to the two new role assignments.

- [ ] **Step 8: Rewire APIM and sidecar at root**

Pass:

```hcl
  model_account_id       = module.foundry.id
  model_openai_v1_base   = module.foundry.endpoint_openai_v1
  allowed_models         = local.allowed_models
```

Set:

```hcl
  alias_models_json       = jsonencode({ for model in local.allowed_models : model => model })
  codexproxy_project_base = module.foundry.project_responses_base
```

Gate the hop key and proxy RBAC with `local.codexproxy_enabled`; set the role scope to
`module.foundry.id`. Add `module.foundry` to the APIM module's `depends_on`.

- [ ] **Step 9: Update response routing comments and outputs**

Keep the existing two-phase `route_via_codexproxy` behavior, but update comments to name
`gpt-5.6-sol` and the canonical project account.

Replace `openai_endpoint` in `infra/outputs.tf` with:

```hcl
output "model_account_name" {
  description = "Canonical project-enabled AIServices account name."
  value       = module.foundry.name
}

output "model_openai_v1_endpoint" {
  description = "Canonical OpenAI/v1 inference base."
  value       = module.foundry.endpoint_openai_v1
}
```

- [ ] **Step 10: Update policy terminology**

Do not change policy behavior. Replace comments that refer to separate Azure OpenAI and Foundry
backends with “canonical AIServices account”, while retaining
`authentication-managed-identity resource="https://cognitiveservices.azure.com"`.

- [ ] **Step 11: Run root topology tests**

Repeat the temporary-copy command from Step 2.

Expected: `Success! 1 passed, 0 failed.`

- [ ] **Step 12: Run static split-topology scan**

Run:

```powershell
rg 'module "openai"|openai_deployments|foundry_deployments|project_deployments|var\.allowed_models|enable_project_account' infra
```

Expected: no matches outside historical migration comments/removed blocks.

- [ ] **Step 13: Commit**

```powershell
git add infra policies
git commit -m "refactor(infra): unify model routing on one Foundry account"
```

---

### Task 5: Align Admin UI defaults, examples, smoke scripts, and current documentation

**Files:**
- Modify: `app/admin-ui/bff/config.py`
- Modify: `app/admin-ui/bff/tests/test_config.py`
- Modify: `infra/modules/control_plane/main.tf`
- Modify: `infra/terraform.tfvars.example`
- Modify: `scripts/seed-cosmos-jumpbox.sh`
- Modify: `scripts/seed-pricing-jumpbox.sh`
- Modify: `scripts/smoke-v1-backend.sh`
- Modify: `scripts/smoke-v1-gateway.sh`
- Modify: current user-facing docs listed in the file map

**Interfaces:**
- Produces: the same exact four-model catalog in Terraform examples, Admin UI local defaults, Cosmos seed, smoke tests, and docs.
- Produces: no Kimi or GPT-5.4 client examples in current documentation.

- [ ] **Step 1: Add a failing exact-default catalog assertion**

In `app/admin-ui/bff/tests/test_config.py`, add:

```python
def test_default_catalog_matches_canonical_deployments(monkeypatch):
    for key in [
        "ENTRA_TENANT_ID", "BFF_API_AUDIENCE", "SPA_CLIENT_ID",
        "ADMIN_GROUP_OBJECT_ID", "SUBSCRIPTION_ID", "APIM_RG",
        "APIM_NAME", "COSMOS_ENDPOINT", "COSMOS_DATABASE",
        "COSMOS_MAP_CONTAINER",
    ]:
        monkeypatch.setenv(key, key.lower())
    monkeypatch.delenv("ALIAS_MODELS_JSON", raising=False)
    monkeypatch.delenv("ALLOWED_MODEL_ALIASES", raising=False)

    settings = Settings.from_env()

    assert set(settings.alias_models) == {
        "gpt-5.6-sol",
        "FW-GLM-5.2",
        "DeepSeek-V4-Pro",
        "grok-4.3",
    }
```

- [ ] **Step 2: Run the test and confirm failure**

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway\app\admin-ui
python -m pytest bff\tests\test_config.py -q
```

Expected: the new test fails because defaults still contain GPT-5.4 and omit GLM.

- [ ] **Step 3: Replace Admin UI defaults**

Use:

```python
_DEFAULT_ALIAS_MODELS = {
    "gpt-5.6-sol": "GPT-5.6 Sol",
    "FW-GLM-5.2": "GLM 5.2 (Fireworks)",
    "DeepSeek-V4-Pro": "DeepSeek V4 Pro",
    "grok-4.3": "Grok 4.3 (xAI)",
}
```

Update existing test fixtures from GPT-5.4 to GPT-5.6 where they are testing defaults rather
than generic environment override behavior.

- [ ] **Step 4: Update Terraform example**

`infra/terraform.tfvars.example` must contain one `model_deployments` block with the exact four
model definitions from Task 4, no `openai_deployments`, no second project map, and:

```hcl
foundry_project_name                  = "codexproj"
foundry_public_network_access_enabled = false
legacy_gpt_compat_enabled             = false
admin_ui_legacy_gpt_aliases_enabled   = false
```

Document the live-only transitions: Task 7 `true/true`, Task 8 `true/false`, Task 9
`false/false` with private-network lockdown.

Document the sidecar bootstrap:

```hcl
# First apply: leave empty so ACR can be created.
codexproxy_image      = ""
route_via_codexproxy = false

# Second apply after `az acr build`:
# codexproxy_image      = "acraigwabc123.azurecr.io/codexproxy:0123456"
# route_via_codexproxy = true
```

- [ ] **Step 5: Update seed and smoke scripts**

- `seed-cosmos-jumpbox.sh`: use the exact four-model `allowed_models`.
- `smoke-v1-backend.sh`: request `gpt-5.6-sol`.
- `smoke-v1-gateway.sh`: test GPT-5.6 through `/openai` and `/vscode/models`, test GLM,
  DeepSeek, and grok through `/foundry`, and remove Kimi/GPT-5.4 calls.
- `seed-pricing-jumpbox.sh`: remove GPT-5.4/GPT-5.4-mini/Kimi from the canonical example. Do not
  add a guessed GPT-5.6 price. Add a warning that cost-based budget evaluation counts an
  unpriced model as `$0` until the operator adds an official per-1K rate.

- [ ] **Step 6: Update VS Code documentation**

`docs/07-connect-clients/vscode-byok.md` must show exactly:

```text
gpt-5.6-sol
FW-GLM-5.2
DeepSeek-V4-Pro
grok-4.3
```

Use `maxInputTokens: 922000` and `maxOutputTokens: 128000` for GPT-5.6 Sol, per the Microsoft
Foundry model capability table. Retain request headers and Custom Endpoint routing.

- [ ] **Step 7: Update architecture and deployment docs**

Across the current user-facing docs in the file map:

- describe one project-enabled AIServices account and one project;
- replace split `openai_deployments`/`foundry_deployments` instructions with `model_deployments`;
- replace `allowed_models` Terraform input with deployment-derived catalog wording;
- replace `openai_endpoint` output with `model_account_name` and `model_openai_v1_endpoint`;
- use `gpt-5.6-sol -> DeepSeek-V4-Pro -> grok-4.3` in downgrade examples;
- explain that `/responses` uses the Codex proxy while the other surfaces call the same account;
- remove current Kimi examples while preserving historical design documents unchanged;
- include the official Microsoft Learn GPT-5.6, Responses, private-link, and APIM MI links.

- [ ] **Step 8: Run Admin UI tests and stale-current-doc scan**

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway\app\admin-ui
python -m pytest bff\tests\test_config.py -q

Set-Location C:\Users\jisunchoi\projects\llm-gateway
rg 'gpt-5\.4|gpt-5\.4-mini|Kimi-K2\.6|openai_deployments|project_deployments' README.md docs scripts infra\terraform.tfvars.example
```

Expected: tests pass; remaining search matches exist only in explicitly marked historical
specs/plans or migration explanations.

- [ ] **Step 9: Commit**

```powershell
git add app\admin-ui infra\modules\control_plane\main.tf infra\terraform.tfvars.example scripts README.md docs
git commit -m "docs(infra): document unified GPT-5.6 catalog"
```

---

### Task 6: Run local validation and code review

**Files:**
- Review all files changed in Tasks 1-5.

**Interfaces:**
- Produces: a commit range safe to send to the live jumpbox.

- [ ] **Step 1: Format Terraform**

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway\infra
terraform fmt -recursive
```

Expected: command exits `0`.

- [ ] **Step 2: Validate without accessing the live backend**

Create a temporary repository copy as in Task 4 and run:

```powershell
terraform init -backend=false
terraform validate
terraform test
```

Expected: validation succeeds and all Terraform tests pass.

- [ ] **Step 3: Run Python tests**

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway
python -m pytest app\codex-proxy\tests\test_server.py scripts\tests\test_verify_model_topology_plan.py -q
Set-Location app\admin-ui
python -m pytest bff\tests\test_config.py -q
```

Expected: all selected tests pass.

- [ ] **Step 4: Run diff checks**

```powershell
Set-Location C:\Users\jisunchoi\projects\llm-gateway
git diff --check
git status --short
```

Expected: no whitespace errors and only intentional changes.

- [ ] **Step 5: Request a high-confidence code review**

Review the complete implementation diff from `99cc5e5` to `HEAD`, focusing on:

- accidental replacement/deletion of `aisproj-c0gvf2`;
- any fresh path that still creates a separate OpenAI account;
- state `removed` semantics;
- APIM service URL and role assignment dependencies;
- public/private network transition;
- GPT-5.6 reasoning behavior.

- [ ] **Step 6: Address valid findings and re-run Steps 1-4**

- [ ] **Step 7: Commit any review fixes**

Use this focused message:

```powershell
git commit -am "fix(infra): harden single-account migration"
```

---

### Task 7: Prepare and apply the additive live migration

**Files:**
- Modify locally only: ignored `infra/terraform.tfvars`
- Create in session state only: jumpbox workspace/bootstrap/plan scripts and plan JSON
- Live resources: canonical deployment, private endpoint, APIM roles/policies, sidecar revision, Admin UI env

**Interfaces:**
- Consumes: the validated commit and current live tfvars values.
- Produces: a migration apply where old account resources are only forgotten, never destroyed.

**State-history preflight (before Step 1):**

- Confirm the current live state still has `reuse_foundry=false` semantics and owns
  `module.foundry.azapi_resource.project_account[0]`,
  `module.foundry.azapi_resource.project[0]`, and
  `module.foundry.azurerm_cognitive_deployment.project_models[...]`.
- Capture the canonical account's exact state ID/name and keep `reuse_foundry=false`; set
  `foundry_account_name` to that exact name.
- If this runbook is ever used against sidecar-era `reuse_foundry=true` history with the same
  managed project resources, perform the same conversion to `reuse_foundry=false`. Do not move old
  APIM roles because they point to the reused regular-account rollback backend.
- If no managed project account exists and an external already-final account is intentionally
  reused, preflight/import any existing `codexproj`, gateway PE, and APIM roles only after exact
  account ID, APIM principal ID, role, and resource-ID verification.
- Leaving `reuse_foundry=true` on sidecar-era managed history is a stop condition: the hardened
  verifier must reject the resulting canonical account/project/deployment destruction.

- [ ] **Step 1: Re-audit live catalog and quota**

Run:

```powershell
az cognitiveservices account list-models -g rg-aigw-dev-eus2 -n aisproj-c0gvf2 `
  --query "[?name=='gpt-5.6-sol'].[name,version,format,skus[].name]" -o json

az cognitiveservices usage list --location eastus2 `
  --query "[?name.value=='OpenAI.GlobalStandard.gpt-5.6-sol' || name.value=='AIServices.DataZoneStandard.Fireworks' || name.value=='AIServices.GlobalStandard.DeepSeek-V4-Pro' || name.value=='AIServices.GlobalStandard.grok-4.3'].{name:name.value,current:currentValue,limit:limit}" -o table
```

Expected: GPT-5.6 Sol version `2026-07-09` is listed; at least `500` GlobalStandard units are
free; existing partner-model quota/deployments remain intact.

- [ ] **Step 2: Build the immutable sidecar image**

Use the implementation commit SHA:

```powershell
$sha = git rev-parse --short HEAD
az acr build -g rg-aigw-dev-eus2 -r acraigwc0gvf2 `
  --image "codexproxy:$sha" app\codex-proxy
```

Expected: ACR build succeeds and reports a digest.

- [ ] **Step 3: Update ignored live tfvars**

Preserve all unrelated and secret values. Replace only topology fields with:

```hcl
reuse_foundry                         = false
foundry_account_name                  = "aisproj-c0gvf2"
foundry_project_name                  = "codexproj"
foundry_public_network_access_enabled = true
legacy_gpt_compat_enabled             = true
admin_ui_legacy_gpt_aliases_enabled   = true

model_deployments = {
  "gpt-5.6-sol"       = { model_name = "gpt-5.6-sol", model_format = "OpenAI", model_version = "2026-07-09", sku_name = "GlobalStandard", capacity = 500 }
  "FW-GLM-5.2"        = { model_name = "FW-GLM-5.2", model_format = "Fireworks", model_version = "1", sku_name = "DataZoneStandard", capacity = 500 }
  "DeepSeek-V4-Pro"   = { model_name = "DeepSeek-V4-Pro", model_format = "DeepSeek", model_version = "2026-04-23", sku_name = "GlobalStandard", capacity = 500 }
  "grok-4.3"          = { model_name = "grok-4.3", model_format = "xAI", model_version = "1", sku_name = "GlobalStandard", capacity = 10 }
}

route_via_codexproxy = true
```

Both compatibility flags must be enabled in this saved Task 7 plan **before** APIM routes move to
the canonical account. This lets legacy GPT callers reach `gpt-5.6-sol` and lets new GPT-5.6
callers pass authorization while config-sync-owned named values still contain old GPT aliases.

Set `codexproxy_image` to the exact value produced from the build variable:

```powershell
$codexProxyImage = "acraigwc0gvf2.azurecr.io/codexproxy:$sha"
```

Write that resolved value into `terraform.tfvars`; do not write the literal variable name.

Remove `openai_deployments`, `foundry_deployments`, `project_deployments`,
`allowed_models`, and `enable_codexproxy`.

- [ ] **Step 4: Grant temporary jumpbox deployment roles**

Grant the jumpbox MI:

- `Storage Blob Data Contributor` on `staigwtfstate6gnsb0`;
- `Contributor` on `rg-aigw-dev-eus2`; and
- `Role Based Access Control Administrator` on `rg-aigw-dev-eus2`.

Record every created assignment ID for cleanup.

- [ ] **Step 5: Snapshot the current APIM rollback configuration**

Save the current `serviceUrl` and policy XML for `azure-openai`, `vscode-openai`, `foundry`, and
`responses` under the session-state folder. Also save the current Admin UI Container App
environment variables. Redact subscription keys and named-value secrets.

- [ ] **Step 6: Stage the exact commit and tfvars on `vm-jump-aigw-dev-eus2`**

Use `az vm run-command invoke` to:

1. create `/root/single-foundry-migration`;
2. clone the repository at the exact implementation commit, or apply a locally generated patch
   series when the commit is not remote;
3. write `infra/terraform.tfvars` from a base64 parameter with mode `600`;
4. install Terraform `1.15.8`;
5. export `ARM_USE_MSI=true`, `ARM_USE_AZUREAD=true`, subscription ID, and tenant ID.

The script must print the checked-out commit SHA but never print tfvars.

- [ ] **Step 7: Initialize and create the migration plan**

On the jumpbox:

```bash
cd /root/single-foundry-migration/repo/infra
terraform init -input=false
terraform plan -input=false -out=migration.tfplan
terraform show -json migration.tfplan > migration-plan.json
python3 ../scripts/verify_model_topology_plan.py migration-plan.json migration
terraform show -no-color migration.tfplan > migration-plan.txt
```

Expected verifier output: `model topology plan OK`.

- [ ] **Step 8: Review exact migration actions**

The plan must:

- create `gpt-5.6-sol`;
- create `pe-foundry-aigw-dev-eus2`;
- create two APIM role assignments on `aisproj-c0gvf2`;
- update APIM routes/catalog and the sidecar image;
- render GPT-family authorization/canonicalization in OpenAI, Foundry, and Responses policies;
- stage Admin UI aliases for the canonical four plus `gpt-5.4` and `gpt-5.4-mini`;
- show `forget` for old accounts/PEs/role assignments;
- show no canonical account replacement;
- show no `delete` for old model accounts or Kimi.

Stop without applying if any condition differs.

- [ ] **Step 9: Apply the saved plan**

```bash
terraform apply -input=false migration.tfplan
```

Expected: apply succeeds; old model accounts still exist.

- [ ] **Step 10: Verify Azure resource state**

Confirm:

- `gpt-5.6-sol` is `Succeeded` on `aisproj-c0gvf2`;
- `pe-foundry-aigw-dev-eus2` is Approved and has a private IP;
- APIM and sidecar identities have their canonical roles;
- `ais-aigw-dev-eus2` and `oai-aigw-dev-eus2` still exist;
- canonical public access is still Enabled for this phase;
- a legacy GPT request is served by `gpt-5.6-sol` with requested/effective headers, and a
  `gpt-5.6-sol` request is authorized even if the runtime allowlist still contains only a legacy
  GPT-family member.

---

### Task 8: Cut over clients and runtime configuration

**Files:**
- Modify locally only: `C:\Users\jisunchoi\AppData\Roaming\Code\User\chatLanguageModels.json`
- Modify live: Cosmos `global` and `consumer:*` documents

**Interfaces:**
- Produces: all four models callable through the canonical account, a canonical-only Admin UI
  catalog, and policy compatibility still enabled for stragglers before public access is disabled.

- [ ] **Step 1: Update Cosmos global model catalog**

From the jumpbox, use managed-identity Cosmos REST access to update the `global` document while
preserving token-limit fields:

```json
"allowed_models": [
  "gpt-5.6-sol",
  "FW-GLM-5.2",
  "DeepSeek-V4-Pro",
  "grok-4.3"
]
```

- [ ] **Step 2: Migrate consumer documents**

For every `consumer_config` document:

- replace `gpt-5.4` and `gpt-5.4-mini` with `gpt-5.6-sol` in `allowed_models`;
- de-duplicate the resulting list;
- replace old GPT entries in `downgrade_ladder` with `gpt-5.6-sol`;
- preserve tier, budget, keys, and active state.

Run the config-sync job and wait for APIM named-value propagation.

- [ ] **Step 3: Remove only the Admin UI legacy aliases**

Change and apply:

```hcl
legacy_gpt_compat_enabled             = true
admin_ui_legacy_gpt_aliases_enabled   = false
```

Create a saved plan, render JSON, run the migration verifier, and apply that exact plan. Do not
disable policy compatibility in Task 8.

- [ ] **Step 4: Verify APIM catalog and Admin UI environment**

Confirm APIM `allowed-models` and Admin UI `ALIAS_MODELS_JSON` contain exactly the four canonical
models. Confirm the active Admin UI revision is Healthy and all three policy families still render
GPT-family compatibility.

- [ ] **Step 5: Smoke-test all APIM surfaces**

Using the current APIM subscription key without printing it:

- `gpt-5.6-sol`: `/openai`, `/vscode/models`, `/responses`;
- `FW-GLM-5.2`: `/foundry`, `/vscode/models`, `/responses`;
- `DeepSeek-V4-Pro`: `/foundry`, `/vscode/models`, `/responses`;
- `grok-4.3`: `/foundry`, `/vscode/models`, `/responses`.
- one `gpt-5.4` and one `gpt-5.4-mini` straggler request: HTTP `200`, effective
  `gpt-5.6-sol`, and requested/effective headers present.

Expected: HTTP `200` for each supported path.

If any canonical route fails, restore the saved API `serviceUrl` and policy XML from Task 7
before changing Terraform again. The old accounts, private endpoints, and role assignments are
still present specifically for this rollback.

- [ ] **Step 6: Verify governance**

Confirm:

- a nonexistent model returns `403`;
- direct sidecar access without hop auth returns `401`;
- one controlled rate-limit test returns `429`;
- a configured downgrade returns HTTP `200` with requested/effective/level headers;
- Application Insights preserves the requested alias dimension and records the canonical backend
  in the effective-model dimension.

- [ ] **Step 7: Update VS Code BYOK**

Preserve the current APIM key and unrelated providers. Replace the custom provider's model list
with:

- `gpt-5.6-sol`;
- `FW-GLM-5.2`;
- `DeepSeek-V4-Pro`;
- `grok-4.3`.

Validate the JSON and invoke each exact configured URL once.

---

### Task 9: Disable public access and remove obsolete model accounts

**Files:**
- Modify locally only: ignored `infra/terraform.tfvars`
- Live resources: canonical account network setting, old account/PE deletion, temporary runner RBAC cleanup

**Interfaces:**
- Produces: final one-account private topology and reconciled remote state.

- [ ] **Step 1: Confirm legacy GPT request telemetry is empty**

Use the requested-model metric/trace dimension to confirm no `gpt-5.4` or `gpt-5.4-mini` requests
occurred during the agreed observation window. Do not disable compatibility while either alias is
still present.

- [ ] **Step 2: Set the final compatibility and private-network values**

Change together:

```hcl
foundry_public_network_access_enabled = false
legacy_gpt_compat_enabled             = false
admin_ui_legacy_gpt_aliases_enabled   = false
```

Stage the updated tfvars on the jumpbox.

- [ ] **Step 3: Plan and apply compatibility removal plus private lockdown**

```bash
terraform plan -input=false -out=lockdown.tfplan
terraform show -json lockdown.tfplan > lockdown-plan.json
python3 ../scripts/verify_model_topology_plan.py lockdown-plan.json migration
terraform apply -input=false lockdown.tfplan
```

Expected: the canonical account updates to public access Disabled, rendered policies contain no
legacy aliases, and no account/project/deployment/PE/RBAC replacement or fallback deletion appears.

- [ ] **Step 4: Re-run every Task 8 canonical smoke test**

Expected: all canonical requests still return the same successful/governance results through
private DNS. Legacy GPT aliases now return `403` and the requested/effective telemetry remains
correct for canonical and budget-downgraded requests.

- [ ] **Step 5: Verify final Terraform state before manual deletion**

Run:

```bash
terraform state list | grep -E 'module\.openai|azurerm_cognitive_account\.foundry|azurerm_private_endpoint\.foundry|azurerm_role_assignment\.apim_to_(openai|foundry)' && exit 1 || true
```

Expected: no legacy addresses remain in remote state.

- [ ] **Step 6: Delete exact obsolete gateway resources**

Delete only these live resources:

- private endpoint `pe-ais-aigw-dev-eus2`;
- account `ais-aigw-dev-eus2`;
- private endpoint `pe-oai-aigw-dev-eus2`;
- account `oai-aigw-dev-eus2`.

Before every delete, resolve and print the exact resource ID and assert it belongs to
`rg-aigw-dev-eus2`. Do not use wildcard deletion and do not reference any Kimi resource.

- [ ] **Step 7: Verify final topology**

Confirm the resource group contains exactly one Cognitive Services model account,
`aisproj-c0gvf2`, with:

- four canonical deployments;
- one child project;
- one Approved private endpoint;
- public access Disabled;
- local auth disabled.

Re-run one request per model.

- [ ] **Step 8: Remove temporary jumpbox access and workspace**

Delete only the three temporary role assignments created in Task 7 and remove
`/root/single-foundry-migration`. Leave permanent jumpbox seed permissions and the Terraform
backend private endpoint/DNS unchanged.

- [ ] **Step 9: Record completion**

Update `.superpowers/sdd/progress.md` with:

- implementation commit range;
- final canonical account/project;
- four deployment names and capacities;
- sidecar image tag/digest;
- verification results;
- exact removed account names;
- explicit confirmation that Kimi was untouched.

- [ ] **Step 10: Commit the progress ledger**

```powershell
git add .superpowers\sdd\progress.md
git commit -m "docs(infra): record GPT-5.6 consolidation rollout"
```
