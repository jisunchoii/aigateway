# Single Foundry Account with GPT-5.6 — Design

## Context

The gateway currently provisions and operates three model accounts:

- a regular `AIServices` account for GPT-5.4, DeepSeek, and grok;
- a project-enabled `AIServices` account for GLM, DeepSeek, and grok; and
- a separate `OpenAI` account for GPT-5.4 and GPT-5.4-mini.

This topology duplicates deployments, makes API behavior depend on which account a policy
selects, and lets the Admin UI advertise models that an API's backend cannot actually serve.
The separate OpenAI account is especially misleading because the shared APIM policy overrides
its API `service_url` and sends inference to the regular AIServices account.

The desired result is one model account, one deployment catalog, and one source of truth for
APIM, Codex, VS Code BYOK, and the Admin UI.

## Decision

Use the existing live project-enabled account, `aisproj-c0gvf2`, as the canonical model
account. A fresh Terraform deployment creates the equivalent resource directly:

- kind: `AIServices`;
- `allowProjectManagement = true`;
- local/key authentication disabled;
- public network access disabled;
- one private endpoint with the Cognitive Services, OpenAI, and Foundry AI private DNS zones;
- one child project, `codexproj`; and
- one deployment map shared by every client surface.

The canonical deployment set is:

| Deployment | Model format | Version | Initial SKU/capacity |
|---|---|---|---|
| `gpt-5.6-sol` | `OpenAI` | `2026-07-09` | `GlobalStandard`, 500 |
| `FW-GLM-5.2` | `Fireworks` | `1` | `DataZoneStandard`, 500 |
| `DeepSeek-V4-Pro` | `DeepSeek` | `2026-04-23` | `GlobalStandard`, 500 |
| `grok-4.3` | `xAI` | `1` | `GlobalStandard`, 10 |

`gpt-5.4` and `gpt-5.4-mini` are not part of the final catalog. Existing deployments remain
available only during migration and are removed after the replacement route is verified.
Kimi is outside this gateway and must not be changed.

GPT-5.6 is currently a preview, phased-rollout model. The live account catalog exposes
`gpt-5.6-sol` version `2026-07-09` in eastus2 with both `GlobalStandard` and
`DataZoneStandard`, and the subscription currently has enough unused quota for the selected
500-unit GlobalStandard deployment.

## Considered approaches

### 1. Promote the existing project-enabled account — selected

Add GPT-5.6 to `aisproj-c0gvf2`, attach private networking, grant APIM access, switch all API
surfaces, verify, and then remove the two obsolete accounts.

This is the only approach that preserves GLM without downtime. The eastus2 Fireworks quota is
already fully allocated to the deployment on this account, so GLM cannot be duplicated onto a
new account before deleting the working deployment.

### 2. Upgrade the regular AIServices account in place

This would preserve its existing private endpoint, GPT deployment, and APIM role assignments.
It is rejected because the account is not project-enabled, GLM cannot be copied to it while
quota is exhausted, and an in-place `allowProjectManagement` conversion is less proven than
retaining the already-working project account.

### 3. Create another canonical account

This provides a clean Terraform resource history but requires temporary duplicate capacity for
every model. It is rejected because Fireworks quota prevents the required safe duplication and
because it would create a fourth account before cleanup.

## Target architecture

```text
VS Code BYOK ───────────────┐
OpenAI-compatible clients ─┼──▶ APIM
Foundry clients ────────────┤     ├─ /openai
Codex CLI ──────────────────┘     ├─ /foundry
                                  ├─ /vscode/models
                                  └─ /responses ─▶ codex-proxy
                                           │
                                           ▼
                              one project-enabled AIServices account
                              ├─ gpt-5.6-sol
                              ├─ FW-GLM-5.2
                              ├─ DeepSeek-V4-Pro
                              └─ grok-4.3
```

APIM owns client authentication, authorization, rate limits, budget downgrade, and token
metrics. The Codex proxy remains only because Codex Responses payloads require normalization
that APIM policy cannot safely perform for streamed traffic. It does not justify a second model
account.

## Terraform design

### Canonical Foundry module

Refactor `infra/modules/foundry` so its primary account is the project-enabled account rather
than creating a regular account plus an optional project account.

- Create the account with AzAPI because the pinned AzureRM provider does not expose
  `allowProjectManagement`.
- Keep the existing live AzAPI resource addresses for the project account, project, and project
  deployments where practical so Terraform adopts them without replacement.
- Set `publicNetworkAccess = "Disabled"` and `disableLocalAuth = true`.
- Attach the module's private endpoint to this account and include all three model-related
  private DNS zones.
- Create the child project unconditionally for managed greenfield deployments.
- Use one deployment map for OpenAI and partner models.
- Reserve brownfield reuse mode for an external already-final project-enabled AIServices account.
  Preflight and import any existing child project, gateway private endpoint, and APIM role
  assignments by exact resource ID before apply.

The former regular account and its deployments are removed from Terraform state without
destroying them during the topology refactor. They are deleted explicitly only after cutover
verification. This prevents a single Terraform apply from deleting the fallback backend.

Historical state is classified before planning:

- the current live `reuse_foundry=false` path already owns the canonical project account, project,
  and project deployments at their preserved addresses and remains unchanged;
- a sidecar-era `reuse_foundry=true` state that also owns those managed project resources must
  capture the exact project-account ID/name, set `reuse_foundry=false`, and set
  `foundry_account_name` to that exact name; and
- only a state with no managed project account may retain `reuse_foundry=true` for an external
  already-final account.

Legacy APIM role assignments are not moved to the new canonical addresses during the sidecar-era
upgrade. They point to the old reused regular account and remain rollback fallbacks until cleanup.
Leaving `reuse_foundry=true` on that history would delete managed project resources and replace the
project parent, so the migration verifier intentionally rejects it.

### Remove the separate OpenAI module

Remove the root `module.openai` call and all backend-selection locals. The former module is
removed from Terraform state without destruction during migration, then its account and private
endpoint are deleted explicitly after verification.

The unused `infra/modules/openai` implementation is deleted from the repository so a fresh
deployment cannot recreate the split topology.

### One deployment and catalog variable

Replace `openai_deployments`, `foundry_deployments`, and `project_deployments` with a single
`model_deployments` map whose schema includes `model_format`.

The following values derive from that map:

- APIM global allowed models;
- Admin UI `ALIAS_MODELS_JSON` (canonical-only by default, with an explicit migration-only union
  of the two legacy GPT aliases);
- per-model token limits; and
- documented client model identifiers.

There is no independent global `allowed_models` input. Per-consumer restrictions remain in
Cosmos configuration. Outside the explicit migration-only Admin UI alias union, Terraform cannot
advertise a model that it did not deploy.

### APIM and identities

The APIM module accepts one model account ID and one OpenAI/v1 base URL.

- Grant APIM both `Cognitive Services OpenAI User` and `Cognitive Services User` on the canonical
  account.
- Route `/openai`, `/foundry`, and `/vscode/models` to the same canonical OpenAI/v1 endpoint.
- Keep the existing policy transformations and governance behavior.
- Route `/responses` through the Codex proxy.
- Grant the Codex proxy identity `Cognitive Services User` on the same account.
- Configure the proxy's project base from the canonical account name and project name. In the
  live environment this resolves to
  `https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1`.
- Preserve reasoning fields for `gpt-5.6-sol` and GLM while retaining the existing per-model
  normalization for backends that reject those fields.
- Add `legacy_gpt_compat_enabled`, default `false`. When enabled, all three policy families treat
  `gpt-5.4`, `gpt-5.4-mini`, and `gpt-5.6-sol` as authorization-equivalent, select any budget
  downgrade first, then canonicalize a selected GPT-family member to `gpt-5.6-sol` before token
  limits and backend dispatch.
- Add `admin_ui_legacy_gpt_aliases_enabled`, default `false`. When enabled, the Admin UI catalog is
  the canonical four plus `gpt-5.4` and `gpt-5.4-mini`; it does not change config-sync ownership of
  APIM runtime named values.
- Preserve the originally requested model and the final effective model in metrics, traces, and
  response headers, including compatibility rewrites with downgrade level zero.

The sidecar image remains an explicit input because ACR must exist before the image can be
built. A first deployment nevertheless creates the final one-account model topology. The
documented bootstrap is: provision infrastructure and ACR, push the immutable sidecar image,
then apply the image and route values.

## Request flows

### OpenAI-compatible and VS Code requests

1. Client sends the requested deployment name to `/openai` or `/vscode/models`.
2. APIM authenticates the caller and checks the requested model against the effective allowlist.
   GPT-family equivalence applies only while migration compatibility is enabled.
3. APIM selects the budget downgrade, then canonicalizes a selected GPT-family member to
   `gpt-5.6-sol` when compatibility is enabled.
4. APIM applies the final effective model's token limit, rewrites the request to the canonical
   OpenAI/v1 endpoint, and authenticates with its
   managed identity.
5. The response and token metrics retain requested and effective model dimensions.

### Codex Responses requests

1. Codex sends a Responses request to `/responses`.
2. APIM performs the same authorization, downgrade-selection, compatibility canonicalization, and
   token-limit sequence, then injects the internal hop credential.
3. The Codex proxy validates the hop credential and normalizes the payload without changing the
   selected model.
4. The proxy authenticates with managed identity and sends the request to the canonical project
   Responses route.
5. Streaming events are relayed without buffering.

## Live migration

The migration is deliberately additive before it is destructive:

1. Re-audit the live catalog, quota, and remote-state history classification.
2. Set both migration flags to `true` before the canonical APIM route cutover.
3. Add `gpt-5.6-sol`, private networking, canonical RBAC, routes, and the staged Admin UI union on
   `aisproj-c0gvf2`; verify old GPT callers and new GPT-5.6 callers.
4. Migrate Cosmos global/consumer documents and clients, run config-sync, then set only
   `admin_ui_legacy_gpt_aliases_enabled=false` and apply. Keep policy compatibility enabled.
5. Verify all four deployments, governance behavior, and requested/effective telemetry.
6. Confirm telemetry contains no legacy GPT requests.
7. Set `legacy_gpt_compat_enabled=false` together with
   `foundry_public_network_access_enabled=false`, apply the saved verified plan, and re-run every
   smoke test.
8. Reconcile the private remote Terraform state.
9. Delete the obsolete regular AIServices and OpenAI accounts and their private endpoints.

No obsolete account or deployment is deleted before step 7 succeeds. Kimi resources are never
included in deletion commands.

## Failure handling and rollback

- If GPT-5.6 deployment fails, APIM remains on the current backends and no account is removed.
- If private DNS or endpoint connectivity fails, leave public access enabled temporarily and
  keep APIM on the old routes while correcting network configuration.
- If an APIM route fails, restore the previous backend/policy revision; both old accounts remain
  intact until post-cutover verification.
- If the Codex proxy fails, `/responses` can be pointed back to its previously working
  configuration without affecting `/openai`, `/foundry`, or `/vscode/models`.
- Terraform migration commands must use the private remote backend. The ignored local state must
  never be applied to live resources.

## Verification

### Static and Terraform checks

- Terraform formatting and validation pass.
- Terraform tests or equivalent plan assertions prove that a default deployment contains one
  AIServices account, one project, no OpenAI account, and exactly the four canonical model
  deployments.
- Rendered-policy assertions prove compatibility defaults off, GPT-family authorization only when
  enabled, downgrade-before-canonicalization ordering, canonical dispatch, and requested/effective
  observability across OpenAI, Foundry, and Responses policies.
- Plan-verifier tests cover arbitrary extra accounts/deployments, canonical project/deployment/PE/
  RBAC delete or replacement through either address field, nested Kimi references, safe updates,
  and forget-only legacy resources.
- Plan inspection proves that the first migration apply does not destroy the two fallback model
  accounts.
- Codex proxy unit tests and self-test remain green.

### Live checks

- `gpt-5.6-sol` succeeds through `/openai`, `/vscode/models`, and `/responses`.
- `FW-GLM-5.2`, `DeepSeek-V4-Pro`, and `grok-4.3` succeed through `/foundry`,
  `/vscode/models`, and the supported Responses path.
- A disallowed model returns 403.
- Rate limiting returns 429 when exhausted.
- Downgrade returns the requested/effective model headers and resolves to a deployed target.
- Direct sidecar access without the hop key returns 401.
- Requests still succeed after canonical account public access is disabled.
- Admin UI lists exactly the four canonical models.
- VS Code BYOK lists and invokes exactly the four canonical models.

## Documentation references

- [GPT-5.6 model capabilities](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
- [Responses API supported models](https://learn.microsoft.com/azure/foundry/openai/how-to/responses#supported-models)
- [Foundry private networking](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
- [APIM managed identity authentication for model APIs](https://learn.microsoft.com/azure/api-management/api-management-authenticate-authorize-ai-apis#authenticate-with-managed-identity)
