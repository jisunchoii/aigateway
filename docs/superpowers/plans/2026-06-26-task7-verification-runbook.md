# Task 7 — Brownfield Reuse Verification Run-book

> **What this is:** the live-Azure gate for the brownfield-reuse-core plan
> (`2026-06-26-brownfield-reuse-core.md`). Tasks 0–6 (code) are complete and
> reviewed on branch `feat/brownfield-reuse-and-gitbook`. This run-book proves
> the code works against real Azure before merge. Check each box as you go.

## The gate (what "pass" means)

Merge is justified only when **all** of these hold (or a documented fallback is recorded):

- `terraform plan` in reuse mode creates **0** `azurerm_cognitive_account` and **0** `azurerm_cognitive_deployment`, and **does** create the foundry Private Endpoint + APIM role assignments against the existing account.
- gpt-5.4 via the `/openai` path-route returns **200** (this is the new, highest-risk path→body conversion).
- grok-4.3 and DeepSeek-V4-Pro via `/foundry` body-route return **200**.
- a gpt-5.4 request sent with `max_completion_tokens` returns **200** (reasoning-param normalization).
- (optional but recommended) a budget-downgrade returns the `x-ai-gateway-*` headers with a same-backend target.

If gpt path→body cannot be made to pass, record the **§6.2 fallback** (keep gpt on the path-route backend via the retained `foundry_v1_base`/openai-account wiring) instead of forcing it.

## Scope-reducing insight (read before you start)

Routing verification exercises only **client → APIM → policy → backend**. You do **not** need:
- the worker / Admin UI second apply, container images, or `az acr build`
- the three Entra app registrations (admin group / BFF / SPA)
- Cosmos consumer-config seeding (with no per-consumer doc, the policy falls back to the **global** `allowed_models` named value, which the apim module already sets from `var.allowed_models` = the 4 models)

You **do** need: the gateway **core** apply (APIM + the 3 APIs + policies + backend PE/RBAC) and **one APIM subscription key**. That is one `terraform apply` (subscription-key mode is the default) plus a key — not the full stack.

---

## Prerequisites

- [ ] `az login` to the **same subscription** the gateway will deploy into (reuse is same-subscription only).
- [ ] Confirm model quota in your chosen region for gpt-5.4, grok-4.3 (xAI), DeepSeek-V4-Pro. (Quota is the customer's in a real reuse; for this test keep capacities small.)
- [ ] Terraform ≥ 1.7, Azure CLI current. `cd` into the repo; you are on `feat/brownfield-reuse-and-gitbook`.
- [ ] Pick two **distinct** resource groups and a region. Suggested:
  ```bash
  export LOC=eastus2
  export MOCK_RG=rg-mockfoundry-eus2          # plays the "customer's existing Foundry"
  export MOCK_AIS=ais-mockcustomer             # the existing AIServices account name
  export MOCK_SUBDOMAIN=ais-mockcustomer        # custom subdomain (globally unique; adjust if taken)
  ```
  > The gateway's own RG is created by `terraform apply` from your tfvars `prefix/env/location` — keep it separate from `$MOCK_RG`.

---

## Phase A — Build the mock "customer existing Foundry"

Creates a single AIServices account hosting gpt + OSS, **initially with key auth + public access ON** (mirrors a real customer), so Phase B can exercise the lock-down procedure.

- [ ] **A1. Resource group**
  ```bash
  az group create -n "$MOCK_RG" -l "$LOC" \
    --tags env=test workload=mockfoundry owner="$(az account show --query user.name -o tsv)" costCenter=CC-TEST
  ```

- [ ] **A2. AIServices account** (kind=AIServices = the unified Foundry resource)
  ```bash
  az cognitiveservices account create \
    --name "$MOCK_AIS" --resource-group "$MOCK_RG" \
    --kind AIServices --sku S0 --location "$LOC" \
    --custom-domain "$MOCK_SUBDOMAIN" --yes
  ```
  Ref: [Create an Azure AI Services resource](https://learn.microsoft.com/azure/ai-services/multi-service-resource)

- [ ] **A3. Model deployments** — names + versions MUST match the repo's `foundry_deployments` so `allowed_models` lets them through. Values copied from `infra/terraform.tfvars`:
  ```bash
  # gpt-5.4 (Azure-direct / OpenAI format)
  az cognitiveservices account deployment create \
    --name "$MOCK_AIS" -g "$MOCK_RG" \
    --deployment-name gpt-5.4 \
    --model-name gpt-5.4 --model-version 2026-03-05 --model-format OpenAI \
    --sku-name GlobalStandard --sku-capacity 10

  # grok-4.3 (partner / xAI format)
  az cognitiveservices account deployment create \
    --name "$MOCK_AIS" -g "$MOCK_RG" \
    --deployment-name grok-4.3 \
    --model-name grok-4.3 --model-version 1 --model-format xAI \
    --sku-name GlobalStandard --sku-capacity 10

  # DeepSeek-V4-Pro (partner / DeepSeek format)
  az cognitiveservices account deployment create \
    --name "$MOCK_AIS" -g "$MOCK_RG" \
    --deployment-name DeepSeek-V4-Pro \
    --model-name DeepSeek-V4-Pro --model-version 2026-04-23 --model-format DeepSeek \
    --sku-name GlobalStandard --sku-capacity 500
  ```
  > If a partner model requires a marketplace/terms acceptance in your tenant, the portal deploy flow surfaces it; accept once, then re-run. Verify exact `--model-format`/version against the catalog if a create 400s. Ref: [Deploy Foundry Models](https://learn.microsoft.com/azure/ai-foundry/how-to/deploy-models-managed)

- [ ] **A4. Capture the account id** (used in Phase B and as `existing_foundry_*`):
  ```bash
  export MOCK_AIS_ID="$(az cognitiveservices account show -n "$MOCK_AIS" -g "$MOCK_RG" --query id -o tsv)"
  echo "$MOCK_AIS_ID"
  ```

---

## Phase B — Lock it down (passwordless) — validates the GitBook §04 procedure

This is the exact step a real customer runs before reuse. It also proves the Task 2 `data` postcondition (`local_auth_enabled == false`) fires correctly.

- [ ] **B1. Disable key auth + public network access**
  ```bash
  az resource update --ids "$MOCK_AIS_ID" \
    --set properties.disableLocalAuth=true properties.publicNetworkAccess=Disabled
  ```
- [ ] **B2. Confirm the lock-down took**
  ```bash
  az resource show --ids "$MOCK_AIS_ID" \
    --query "properties.{disableLocalAuth:disableLocalAuth, publicNetworkAccess:publicNetworkAccess}" -o jsonc
  ```
  Expected: `disableLocalAuth: true`, `publicNetworkAccess: "Disabled"`.
  > Negative check (optional): re-run `terraform plan` in Phase C while the account still has key auth ON and confirm the data-source **postcondition fails** with the GitBook §04 remediation message. Then lock down and re-plan. This proves the guardrail works.

---

## Phase C — Deploy the gateway in reuse mode + inspect the plan (the core assertion)

- [ ] **C1. Write a test tfvars** (do **not** commit; contains your values). Minimum for a routing test:
  ```hcl
  # infra/terraform.tfvars  (test stack)
  prefix      = "gwtest"
  env         = "test"
  location    = "eastus2"
  owner       = "you@example.com"
  cost_center = "CC-TEST"

  apim_publisher_name  = "Platform Team"
  apim_publisher_email = "you@example.com"
  apim_sku_name        = "Developer_1"   # no SLA; fine for verification
  apim_public          = true             # so you can smoke-test from your laptop

  # --- brownfield reuse ---
  reuse_foundry         = true
  existing_foundry_name = "ais-mockcustomer"     # = $MOCK_AIS
  existing_foundry_rg   = "rg-mockfoundry-eus2"  # = $MOCK_RG

  # Declare the deployments that already exist (NOT created in reuse mode);
  # keys must equal the real deployment names so allowed_models/routing line up.
  foundry_deployments = {
    "gpt-5.4"         = { model_name = "gpt-5.4",        model_format = "OpenAI",  model_version = "2026-03-05", sku_name = "GlobalStandard", capacity = 10 }
    "grok-4.3"        = { model_name = "grok-4.3",       model_format = "xAI",     model_version = "1",          sku_name = "GlobalStandard", capacity = 10 }
    "DeepSeek-V4-Pro" = { model_name = "DeepSeek-V4-Pro",model_format = "DeepSeek", model_version = "2026-04-23", sku_name = "GlobalStandard", capacity = 500 }
  }

  # Leave worker_image / admin_ui_image empty (default "") — routing test needs neither.
  ```
  > `allowed_models` defaults to the 4 model names (see `infra/variables.tf`), so the global allowlist already admits all three test models.

- [ ] **C2. Init + plan, and READ the plan for the brownfield assertion**
  ```bash
  cd infra
  terraform init
  terraform plan -out tfplan-reuse
  ```
  Confirm in the plan summary:
  - [ ] **0** to add for `module.foundry.azurerm_cognitive_account.foundry`
  - [ ] **0** to add for `module.foundry.azurerm_cognitive_deployment.models`
  - [ ] **0** resources from `module.openai` (the module is count-gated to 0)
  - [ ] `module.foundry.azurerm_private_endpoint.foundry` **will be created**
  - [ ] `module.apim.azurerm_role_assignment.apim_to_openai` and `...apim_to_foundry` **will be created** (both scoped to the mock AIServices account)
  - [ ] no error from the `data.azurerm_cognitive_account.existing` postcondition (account is locked down from Phase B)

  Capture the plan summary for the PR/merge record:
  ```bash
  terraform show -no-color tfplan-reuse | grep -E "will be created|# module|Plan:" | head -60
  ```

- [ ] **C3. Apply**
  ```bash
  terraform apply tfplan-reuse
  ```
  > APIM Developer/Premium VNet injection can take **~45 min** on first apply. Expected and normal.

- [ ] **C4. Grab the APIM host + a subscription key**
  The root output is `apim_gateway_url` (a full `https://…` URL). The smoke script
  takes a bare **host** (it prepends `https://` itself), so strip the scheme:
  ```bash
  export APIM_URL="$(terraform output -raw apim_gateway_url)"   # e.g. https://gwtest-...azure-api.net
  export APIM_HOST="${APIM_URL#https://}"                        # -> gwtest-...azure-api.net
  echo "APIM_URL=$APIM_URL  APIM_HOST=$APIM_HOST"
  ```
  Issue **one** APIM subscription key (any of):
  - Portal: APIM → Subscriptions → + Add (scope: All APIs) → copy the primary key, **or**
  - the Admin UI if you deployed it, **or**
  - `az rest`/`az apim` against the management API.

  > In subscription-key mode the policy sets `consumerId = subscription.Name`, and with no Cosmos consumer doc it uses the **global** `allowed_models` — the 4 test models are admitted. Give the subscription a human-readable name so dashboards read cleanly.
  ```bash
  export SUB_KEY="<paste primary key>"
  ```

---

## Phase D — Smoke test from your laptop (APIM is public)

The scripts from Task 0 live in `scripts/`. Run the gateway script locally (no jumpbox — `apim_public=true`):

- [ ] **D1. Run the end-to-end gateway smoke**
  ```bash
  cd ..   # repo root
  ./scripts/smoke-v1-gateway.sh "$APIM_HOST" "$SUB_KEY"
  ```
  Expected tail: `ALL SMOKE CHECKS PASSED`. Each line maps to a gate item:
  - [ ] `gpt-5.4 via /openai (path->v1 body)` → 200  ← **highest-risk path→body**
  - [ ] `grok-4.3 via /foundry (body)` → 200
  - [ ] `DeepSeek-V4-Pro via /foundry (body)` → 200
  - [ ] `gpt-5.4 max_completion_tokens` → 200

- [ ] **D2. (If any check fails) isolate backend vs policy from the jumpbox.**
  Set `enable_jumpbox = true` (+ a `jumpbox_admin_password`) and `terraform apply`, connect via Bastion, then:
  ```bash
  # on the jumpbox, against the AIServices v1 base (PE-only, in-VNet):
  ./scripts/smoke-v1-backend.sh "https://${MOCK_SUBDOMAIN}.openai.azure.com/openai/v1"
  ```
  - Backend **200** but gateway fails → the fault is in the APIM policy conversion (Task 6) → inspect / revise the openai policy.
  - Backend **non-200** → the model/account/RBAC is the issue, not the gateway.

- [ ] **D3. (Optional) downgrade observability check.** If you exercise a budget downgrade (set a consumer's `active_downgrade.level`), confirm the response carries `x-ai-gateway-requested-model`, `x-ai-gateway-effective-model`, `x-ai-gateway-downgrade-level`, and that the effective model is served from the **same** AIServices account (no cross-backend).

---

## Phase E — Record the result / fallback decision

- [ ] **E1. All gate items pass** → record in the PR/merge note: plan summary from C2, smoke output from D1, and "Task 7 verified, ready to merge."
- [ ] **E2. gpt path→body cannot pass** → invoke the **§6.2 fallback**:
  - Keep gpt on the Azure-OpenAI path-route backend instead of the unified v1 body-route. The wiring still exists: `local.gpt_backend_*` and the apim openai inputs were retained; the openai policy's always-on conversion is the piece to revert for gpt.
  - This means **not** running reuse as a single-account collapse for gpt, or routing gpt through the path-route. Document exactly what was reverted and why, and update the design spec §3.2/§6.2 status.
- [ ] **E3. Update the progress ledger** (`.superpowers/sdd/progress.md`) with the outcome so the merge record is durable.

---

## Phase F — Teardown (separate RGs make this clean)

- [ ] **F1. Destroy the gateway stack**
  ```bash
  cd infra && terraform destroy
  ```
- [ ] **F2. Delete the mock Foundry RG**
  ```bash
  az group delete -n "$MOCK_RG" --yes
  ```
- [ ] **F3.** Remove the local `infra/terraform.tfvars` test file (uncommitted) and the `tfplan-reuse` plan file.

---

## After the gate passes

The branch is then ready for `superpowers:finishing-a-development-branch`. Note the two **follow-on plans** still pending and independent of this gate:
- GitBook (Korean docs, spec Phase 3) — including the §04 "prepare existing account" page whose `az` lock-down commands are validated by Phase B above.
- Admin UI Korean restore (spec Phase 4).
