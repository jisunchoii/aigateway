# Codex↔Foundry Proxy Sidecar — Design (Phase 2)

## Context

Phase 1 (committed `f05635f`) built a **local** stdlib Python proxy
(`scripts/foundry_codex_proxy.py`) that lets Codex CLI drive Fireworks-served Foundry
models (GLM/DeepSeek/Kimi) over the native Responses API. It normalizes Codex's gpt-only
tool shapes and payload fields the backend rejects. But it runs on the developer's machine,
injects tokens via `az` CLI, and **bypasses all APIM governance** (consumerId, allowed-models,
rate limit, budget downgrade, metrics).

Phase 2 promotes that proxy to a **sidecar Container App behind APIM `/responses`**, so the
normalization runs server-side for every user with APIM governance in front. The proxy exists
because APIM policy cannot reshape a streamed SSE response or rewrite tool shapes — the sidecar
owns exactly that, while APIM owns governance (keyed on the body `model`, which the proxy never
changes).

This re-introduces the Container-App / user-assigned-identity / hop-secret pattern that
`f05635f` removed (the LiteLLM bridge) — now hosting our own proxy instead of LiteLLM.

**Decisions locked in brainstorming:**
- Model topology: **consolidate GLM+Kimi+DeepSeek onto one managed Foundry account** so the
  sidecar sees a single backend.
- **That account must support projects** (`allowProjectManagement=true`) — the existing
  `ais-<suffix>` account has it `false`, and Fireworks models require the **project route**
  (`/api/projects/<project>/openai/v1/responses`) for Responses, not the resource-level path.
  So Phase 2 provisions a NEW project-enabled Foundry account; the existing one can't be reused.
- Hosting: **Container App**, reusing the removed LiteLLM pattern.
- Backend auth: **sidecar Managed Identity** via `azure-identity` (`ManagedIdentityCredential`),
  matching the removed LiteLLM `use_azure_ad` pattern and the passwordless project rule.
- APIM→sidecar hop: **generated master key** (`random_password` → APIM named value), exactly
  the removed LiteLLM hop.
- Code: **keep Python**, reuse the Phase-1 normalization verbatim; swap the az-CLI token step
  for `azure-identity` and add master-key validation.

## Approach

```
Codex CLI ──(Responses, Ocp-Apim-Subscription-Key)──▶ APIM /responses
   [existing governance policy runs: consumerId → allowed-models 403 →
    downgrade(body model) → rate limit → token metrics]
   + injects Authorization: Bearer <master-key>  (hop auth)
        │
        ▼
   Sidecar Container App  (ca-codexproxy-<suffix>, internal ingress)
     · validate master key (else 401)
     · normalize Codex payload  (Phase-1 logic, unchanged)
     · backend auth: MI token via azure-identity
        │
        ▼
   NEW project-enabled Foundry account
   .../api/projects/<project>/openai/v1/responses
   (GLM · Kimi · DeepSeek all deployed here → single backend)
```

Unchanged from the local proxy: **all normalization** (local_shell/custom→function,
namespace flatten + response-side namespace restore, drop reasoning/web_search_call history
items [openai/codex#24612], verbosity→medium, strip include reasoning.encrypted_content,
per-model reasoning.effort). The body `model` is never rewritten → APIM downgrade stays compatible.

### Components

| Component | File | Change |
|---|---|---|
| New project-enabled Foundry account + one project | `infra/modules/foundry/main.tf` (or new module) | Create the account with `allowProjectManagement=true` and a child project via **`azapi`** (already a pinned provider, used in `responses.tf`/apim module; avoids relying on azurerm 4.20 supporting the flag). Fireworks Responses needs the project route. |
| Model deployments | `infra/variables.tf` `foundry_deployments` | GLM, Kimi, DeepSeek on the new account — **plus every model on the downgrade ladder** (see Consistency A). |
| Sidecar identity | `infra/modules/identity/main.tf` | `id-codexproxy-<suffix>` user-assigned MI + principal/client/id outputs. |
| Backend + ACR RBAC | `infra/main.tf` | Sidecar MI → `Cognitive Services User` on the new account (data plane) + ACR pull. |
| Hop secret | `infra/main.tf` | `random_password.codexproxy_key` → APIM named value `{{codexproxy-key}}`. |
| Container App | `infra/modules/control_plane/main.tf` | `ca-codexproxy-<suffix>`, internal ingress, user-assigned MI, ACR registry, env: Foundry project base URL, `AZURE_CLIENT_ID`, `PROXY_KEY`. |
| `/responses` backend | `infra/responses.tf` | `service_url` → sidecar FQDN (was the Foundry endpoint). |
| Policy hop auth | `policies/responses-pipeline.xml.tftpl` | Final `authentication-managed-identity` block → inject `Authorization: Bearer {{codexproxy-key}}` for the sidecar hop. Governance blocks above stay. |
| Sidecar code | `app/codex-proxy/` | Move `foundry_codex_proxy.py`; swap `get_token()` az-CLI → `ManagedIdentityCredential`; single-backend `ROUTES`; add master-key validation. `requirements.txt` (`azure-identity==1.19.0`, matches BFF). `Dockerfile` (slim Python, per removed litellm Dockerfile). |

### Consistency, error handling, verification

**A. Downgrade × consolidated account (must-do).** APIM rewrites body `model` down the ladder
before the sidecar sees it. Every ladder target model must be deployed on the new account/project,
or a downgraded request 404s. Include all ladder models in `foundry_deployments` and re-check the
ladder definition against the consolidated account.

**B. Sidecar error handling.**
- Missing/invalid master key → 401 (blocks direct non-APIM access).
- MI token acquisition failure → 502 + log (azure-identity handles CAE/refresh).
- Backend 4xx/5xx → relay as-is, with reject logging (Phase-1 behavior).
- SSE: event-by-event flush preserved; APIM side keeps `buffer-response=false`, `timeout=300`.

**C. Verification (post-deploy e2e).**
1. `python app/codex-proxy/foundry_codex_proxy.py --selftest` — normalization asserts, no network.
2. Through APIM `/responses`, `codex --profile <model>` for GLM/DeepSeek (Kimi if quota):
   file edit + shell + multi-agent complete; **governance observed** — allowed-models 403 on a
   disallowed model, 429 on rate limit, downgrade rewrites model down the ladder (and the target
   resolves, per A), consumer + token metrics in Application Insights.
3. Hop: direct call to the sidecar without the master key → 401.

**D. Deploy order (dependencies).** New account + project + model deployments (quota first) →
build sidecar image + push to ACR → sidecar identity + RBAC → Container App → **last**, switch
APIM `service_url` + policy hop auth (keep the old path working until the final switch).

## Out of scope
- Kimi quota (429) resolution — deployment quota, tracked separately.
- Codex↔non-gpt-reasoning intermittent mid-stream disconnects — Codex client limitation, not
  fixable in the sidecar.

## Verification summary
Selftest green + APIM-fronted e2e for each model with all four governance behaviors
(allowed-models, rate limit, downgrade-with-resolvable-target, metrics) observed + hop 401.
