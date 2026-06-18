"""Reconcile gateway config: read the authoritative config document from Cosmos DB and
write each value to its matching APIM named value. Passwordless (managed identity) only.

Env vars (set by the Container Apps Job):
  COSMOS_ENDPOINT     - https://cosmos-...documents.azure.com:443/
  COSMOS_DATABASE     - gateway
  COSMOS_CONTAINER    - config
  SUBSCRIPTION_ID     - Azure subscription id
  APIM_RG             - APIM resource group
  APIM_NAME           - APIM service name
Also bundles all Cosmos consumer_config docs (doc_type="consumer_config") into the base64-encoded "consumer-config-json" named value for per-consumer policy enforcement (Phase 3c).
"""
import base64
import json
import logging
import os
import sys

import datetime

from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient
from azure.cosmos.exceptions import CosmosResourceNotFoundError
from azure.mgmt.apimanagement import ApiManagementClient
from azure.monitor.query import LogsQueryClient, LogsQueryStatus

import budget

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("config-sync")

# Cosmos config doc field -> APIM named value name. The config doc has id="global".
FIELD_TO_NAMED_VALUE = {
    "allowed_models": "allowed-models",
    "tokens_per_minute": "tokens-per-minute",
    "token_quota": "token-quota",
    "token_quota_period": "token-quota-period",
}


def read_config(cred) -> dict:
    client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=cred)
    container = client.get_database_client(os.environ["COSMOS_DATABASE"]).get_container_client(
        os.environ["COSMOS_CONTAINER"]
    )
    doc = container.read_item(item="global", partition_key="global")
    log.info("read config doc: %s", {k: doc.get(k) for k in FIELD_TO_NAMED_VALUE})
    return doc


def to_named_value_string(field: str, value) -> str:
    # allowed_models is stored as a JSON array; APIM named value is a comma-joined string.
    if field == "allowed_models" and isinstance(value, list):
        return ",".join(str(v) for v in value)
    return str(value)


# consumer_config bundle: only the fields the APIM policy reads — model allowlist (③) + rate tier (⑤).
# Raw token fields are gone (tier replaces them); budget/ladder excluded (Phase 4 reads from Cosmos).
CONSUMER_BUNDLE_FIELDS = ("allowed_models", "tier", "active_downgrade", "downgrade_ladder")
CONSUMER_CONFIG_NAMED_VALUE = "consumer-config-json"
BUNDLE_RAW_WARN_CHARS = 3000  # base64 is +33%; ~3KB raw keeps us under the ~4096-char NV limit


def build_consumer_bundle(docs: list) -> dict:
    bundle = {}
    for doc in docs:
        consumer = doc.get("consumer")
        if not consumer:
            continue
        entry = {}
        for f in CONSUMER_BUNDLE_FIELDS:
            if f not in doc:
                continue
            if f in ("allowed_models", "downgrade_ladder") and isinstance(doc[f], list):
                entry[f] = ",".join(str(v) for v in doc[f])
            else:
                entry[f] = doc[f]
        bundle[consumer] = entry
    return bundle


def encode_bundle(bundle: dict) -> str:
    raw = json.dumps(bundle, separators=(",", ":"), sort_keys=True)
    if len(raw) > BUNDLE_RAW_WARN_CHARS:
        log.warning("consumer-config bundle raw size %d chars nearing the named-value limit "
                    "(base64 +33%%); consider splitting", len(raw))
    return base64.b64encode(raw.encode("utf-8")).decode("ascii")


def sync_consumer_config(cred, config_container) -> None:
    docs = list(config_container.query_items(
        query='SELECT * FROM c WHERE c.doc_type = "consumer_config"',
        enable_cross_partition_query=True,
    ))
    bundle = build_consumer_bundle(docs)
    encoded = encode_bundle(bundle)
    apim = ApiManagementClient(cred, os.environ["SUBSCRIPTION_ID"])
    apim.named_value.begin_create_or_update(
        resource_group_name=os.environ["APIM_RG"],
        service_name=os.environ["APIM_NAME"],
        named_value_id=CONSUMER_CONFIG_NAMED_VALUE,
        parameters={"properties": {"displayName": CONSUMER_CONFIG_NAMED_VALUE,
                                   "value": encoded, "secret": False}},
    ).result()
    log.info("synced %d consumer config entries to %s", len(bundle), CONSUMER_CONFIG_NAMED_VALUE)


# Prompt + Completion token sums per consumer + model (effectiveModel = what was actually served
# after any downgrade, falling back to the requested deployment). tok_kind tags which metric the row
# came from so the cost engine can apply the right per-1k rate. NOTE: the column is tok_kind, not
# 'kind' — 'kind' is a reserved KQL keyword and using it as a summarize-by column fails to parse.
_USAGE_KQL = (
    'AppMetrics | where Name in ("Prompt Tokens", "Completion Tokens") '
    'and TimeGenerated >= startofday(now()) '
    '| extend p=parse_json(Properties) '
    '| extend tok_kind = iff(Name == "Prompt Tokens", "prompt", "completion") '
    '| summarize tokens=sum(Sum) by consumer=tostring(p.consumer), '
    'model=tostring(coalesce(p.effectiveModel, p.deployment)), tok_kind'
)

PRICING_DOC_ID = "pricing"


def _shape_usage(rows: list) -> dict:
    """rows of {consumer, model, tok_kind, tokens} -> {consumer: {model: {"prompt","completion"}}}."""
    out: dict = {}
    for d in rows:
        consumer = d.get("consumer")
        model = d.get("model")
        tok_kind = d.get("tok_kind")
        if not consumer or not model or tok_kind not in ("prompt", "completion"):
            continue
        slot = out.setdefault(consumer, {}).setdefault(model, {"prompt": 0, "completion": 0})
        slot[tok_kind] = slot.get(tok_kind, 0) + int(d.get("tokens") or 0)
    return out


def query_usage(cred) -> dict:
    """{consumer: {model: {"prompt","completion"}}} from Log Analytics. Empty on missing workspace."""
    ws = os.environ.get("LOG_ANALYTICS_WORKSPACE_ID", "")
    if not ws:
        log.warning("LOG_ANALYTICS_WORKSPACE_ID unset; skipping budget usage query")
        return {}
    client = LogsQueryClient(cred)
    resp = client.query_workspace(workspace_id=ws, query=_USAGE_KQL,
                                  timespan=datetime.timedelta(days=1))
    if resp.status != LogsQueryStatus.SUCCESS:
        tables = getattr(resp, "partial_data", None) or []
    else:
        tables = resp.tables
    rows = []
    if tables:
        t = tables[0]
        cols = [str(c) for c in t.columns]
        rows = [dict(zip(cols, row)) for row in t.rows]
    return _shape_usage(rows)


def read_pricing(container) -> dict:
    """The operator-owned `pricing` doc -> {model: {"prompt","completion"}} per-1k rates. {} if absent
    (a missing price makes a model cost $0 in budget.cost_for — fail-safe, never blocks downgrade)."""
    try:
        doc = container.read_item(item=PRICING_DOC_ID, partition_key=PRICING_DOC_ID)
    except CosmosResourceNotFoundError:
        log.warning("pricing doc absent; budget cost will be $0 for all models")
        return {}
    return doc.get("models", {})


def sync_budget_downgrades(cred, config_container) -> None:
    """Evaluate daily USD budgets and persist active_downgrade changes to consumer_config docs.
    Fail-safe: if the usage query raises, log and return WITHOUT touching existing state."""
    try:
        usage = query_usage(cred)
    except Exception:
        log.exception("budget usage query failed; leaving existing downgrades untouched")
        return
    pricing = read_pricing(config_container)
    docs = list(config_container.query_items(
        query='SELECT * FROM c WHERE c.doc_type = "consumer_config"',
        enable_cross_partition_query=True,
    ))
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    changed = budget.evaluate_downgrades(docs, usage, pricing, now_iso=now_iso)
    for consumer, updated in changed.items():
        config_container.upsert_item(body=updated)
        lvl = (updated.get("active_downgrade") or {}).get("level", 0)
        log.info("consumer %s downgrade level -> %d (cost eval)", consumer, lvl)
    log.info("budget eval: %d consumer(s) changed", len(changed))


def sync_named_values(cred, config: dict) -> None:
    apim = ApiManagementClient(cred, os.environ["SUBSCRIPTION_ID"])
    rg, name = os.environ["APIM_RG"], os.environ["APIM_NAME"]
    for field, nv_name in FIELD_TO_NAMED_VALUE.items():
        if field not in config:
            log.warning("config doc missing field %s; skipping", field)
            continue
        value = to_named_value_string(field, config[field])
        apim.named_value.begin_create_or_update(
            resource_group_name=rg,
            service_name=name,
            named_value_id=nv_name,
            parameters={
                "properties": {
                    "displayName": nv_name,
                    "value": value,
                    "secret": False,
                }
            },
        ).result()
        log.info("updated named value %s = %s", nv_name, value)


def main() -> int:
    cred = DefaultAzureCredential()
    try:
        client = CosmosClient(os.environ["COSMOS_ENDPOINT"], credential=cred)
        container = client.get_database_client(
            os.environ["COSMOS_DATABASE"]
        ).get_container_client(os.environ["COSMOS_CONTAINER"])
        config = container.read_item(item="global", partition_key="global")
        log.info("read config doc: %s", {k: config.get(k) for k in FIELD_TO_NAMED_VALUE})
        sync_named_values(cred, config)
        sync_budget_downgrades(cred, container)
        sync_consumer_config(cred, container)
    except Exception:  # noqa: BLE001 - top-level job boundary; log and fail the execution
        log.exception("config sync failed")
        return 1
    log.info("config sync complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
