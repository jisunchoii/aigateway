# Consumer Config Flow v2 Design

## Goal

Create `internal/consumer-config-flow-v2.html` as a separate internal reference document that reflects the current APIM inference policy and config-sync worker. The existing `internal/consumer-config-flow.html` remains unchanged.

## Scope

Keep the existing dark theme, tables, code blocks, and internal-document style, but reorganize the content around the policy execution order:

1. Resolve `consumerId` from the Entra claim when enabled, otherwise from the subscription name or ID.
2. Validate the JSON request body and extract the requested model from the body or route parameter.
3. Decode the `consumer-config-json` APIM Named Value and select the consumer entry, with global Named Value fallback.
4. Enforce both the deployed-model catalog and the consumer `allowed_models` list.
5. Select the consumer rate `tier`, falling back to the default tier.
6. Apply the worker-computed `active_downgrade.level` through the consumer's `downgrade_ladder`.
7. Rewrite the request body as needed and route Responses native models, Responses proxy models, and non-Responses requests to their current backends.
8. Apply token limits and emit requested/effective model metrics and headers.
9. Document synchronization timing and the source-of-truth boundaries.

## Data model corrections

The v2 document will show the bundle fields currently emitted by `sync.py`:

- `allowed_models`: comma-separated string
- `tier`: validated rate-tier name
- `active_downgrade`: object containing `level`, `usage_usd`, `pct`, and `evaluated_at` when active
- `downgrade_ladder`: comma-separated ordered model list

The document will explain that the worker reads `consumer_config` documents, queries Log Analytics usage, reads the Cosmos `pricing` document, evaluates `daily_budget_usd`, persists only changed downgrade state, and then publishes the consumer bundle to the APIM Named Value. APIM does not query Cosmos at request time and does not receive raw budget data in the bundle.

## Error and routing coverage

The document will explicitly cover the policy's observable validation behavior: invalid JSON and missing model return `400`, while a model outside the deployed catalog or consumer allowlist returns `403`. It will describe the current Responses routing distinction: configured native Responses models use the Foundry OpenAI-compatible endpoint, while other Responses models use the Codex proxy when enabled; non-Responses traffic uses the Foundry OpenAI-compatible endpoint.

## Validation

After creating the v2 HTML, compare its terminology and field names against `policies/inference-pipeline.xml.tftpl` and `app/config-sync-worker/sync.py`, confirm the original HTML is unchanged, and inspect the generated file for the corrected examples and current routing sections.
