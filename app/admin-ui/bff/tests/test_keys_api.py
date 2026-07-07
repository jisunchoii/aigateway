import pytest
from fastapi.testclient import TestClient

from bff.app import AppDeps, app_factory
from bff.auth import Principal
from bff.config import Settings
from bff.deps import current_principal


# --- fakes -------------------------------------------------------------------
class FakeApim:
    def __init__(self):
        self.deleted = []
        self._subs = []

    def create(self, *, display_name):
        from bff.apim import Subscription
        vk = Subscription(id="vk-new", display_name=display_name, state="active",
                        primary_key="PK", secondary_key="SK")
        self._subs.append(vk)
        return vk

    def list(self):
        from bff.apim import Subscription
        return [Subscription(id=s.id, display_name=s.display_name, state=s.state) for s in self._subs]

    def delete(self, key_id):
        self.deleted.append(key_id)
        self._subs = [s for s in self._subs if s.id != key_id]


class FakeStore:
    def __init__(self):
        self.rows = {}

    def record(self, *, key_id, consumer, display_name, created_by, created_at=None):
        self.rows[key_id] = {"id": key_id, "consumer": consumer, "display_name": display_name,
                             "created_by": created_by, "created_at": created_at}
        return self.rows[key_id]

    def list(self):
        return list(self.rows.values())

    def remove(self, key_id):
        self.rows.pop(key_id, None)


class FakeMetrics:
    def consumer_usage(self, consumer, span):
        # 100k prompt + 40k completion of gpt-5.4 -> with the test pricing = $0.85
        return {"gpt-5.4": {"prompt": 100000, "completion": 40000}}

    def monitoring(self, span):
        return {"recent": [{"TimeGenerated": "t", "Name": "POST /openai", "ResultCode": "200", "DurationMs": 12}],
                "blocked": [{"TimeGenerated": "t", "Name": "POST /openai", "ResultCode": "429"}],
                "downgrades": [{"TimeGenerated": "t", "consumer": "ghcp",
                                "requestedModel": "gpt-5.4", "effectiveModel": "grok-4.3",
                                "downgradeLevel": "2"}]}

    def dashboard(self, span):
        return {"total_tokens": 999,
                "by_consumer": [{"consumer": "a3b801e9-1a17-4af8-b1ef-3103a1e0f075", "tokens": 500},
                            {"consumer": "smoke", "tokens": 499}],
                "by_model": [{"deployment": "gpt-5.4-mini", "tokens": 999}],
                "requests_by_model": [{"deployment": "gpt-5.4-mini", "requests": 10}],
                "total_requests": 10, "error_rate": 0.1,
                "blocked_403": 2, "blocked_429": 1}


class FakeConsumerConfig:
    def __init__(self):
        self.docs = {}

    def get(self, consumer):
        return self.docs.get(consumer)

    def put(self, consumer, fields, valid_aliases=None):
        from bff.consumerconfig import validate
        validate(fields, valid_aliases=valid_aliases)
        doc = {"id": f"consumer:{consumer}", "doc_type": "consumer_config", "consumer": consumer, **fields}
        self.docs[consumer] = doc
        return doc

    def global_defaults(self):
        # Mirror live: the `global` Cosmos doc carries no allowed_models. The BFF must fall back
        # to Settings.allowed_model_aliases so an inheriting consumer still shows the global allowlist.
        return {}

    def list(self):
        # consumer + active_downgrade projected (matches the real ConsumerConfigStore.list query).
        return [{"consumer": t, "active_downgrade": d.get("active_downgrade")} for t, d in self.docs.items()]

    def remove(self, consumer):
        self.docs.pop(consumer, None)


class FakeJobStarter:
    def __init__(self):
        self.started = 0

    def start(self):
        self.started += 1
        return True


class FakeConsumerRegistry:
    def __init__(self):
        self.docs = {}  # consumer -> doc

    def get(self, consumer):
        return self.docs.get(consumer)

    def put(self, consumer, fields, existing_group_owners=None):
        from bff.consumerregistry import validate
        validate({**fields, "consumer": consumer}, existing_group_owners=existing_group_owners)
        doc = {"id": f"consumerreg:{consumer}", "doc_type": "consumer_registry", "consumer": consumer, **fields}
        self.docs[consumer] = doc
        return doc

    def remove(self, consumer):
        self.docs.pop(consumer, None)

    def list(self):
        return list(self.docs.values())

    def group_index(self):
        return {d["entra_group_id"]: d["consumer"] for d in self.docs.values() if d.get("entra_group_id")}


def _settings():
    return Settings(
        entra_tenant_id="tid", bff_api_audience="api://bff", spa_client_id="spa",
        admin_group_object_id="gid", subscription_id="s", apim_rg="rg",
        apim_name="apim", cosmos_endpoint="https://c",
        cosmos_database="gateway", cosmos_map_container="team_subscription_map",
        allowed_model_aliases=("gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"),
        rate_tiers={"small": {"tpm": 50000, "quota": 5000000, "period": "Daily"},
                    "medium": {"tpm": 150000, "quota": 30000000, "period": "Daily"},
                    "large": {"tpm": 300000, "quota": 1000000000, "period": "Monthly"}},
    )


@pytest.fixture
def ctx():
    apim, store = FakeApim(), FakeStore()
    deps = AppDeps(settings=_settings(), apim=apim, store=store, spa_dir=None,
                   consumerconfig=FakeConsumerConfig(), metrics=FakeMetrics(),
                   consumerregistry=FakeConsumerRegistry(),
                   model_prices={"gpt-5.4": {"prompt": 0.0025, "completion": 0.015}})
    app = app_factory(deps)
    client = TestClient(app)
    return app, client, apim, store


def _as(app, principal):
    app.dependency_overrides[current_principal] = lambda: principal


ADMIN = Principal(oid="ada", name="Ada", is_admin=True)
USER = Principal(oid="bob", name="Bob", is_admin=False)


def test_config_is_anonymous(ctx):
    _, client, *_ = ctx
    r = client.get("/api/config")
    assert r.status_code == 200
    body = r.json()
    assert body["tenantId"] == "tid"
    assert body["clientId"] == "spa"
    assert body["apiScope"] == "api://bff/access_as_user"
    # model id -> display label map (non-secret), for the Models page. Keys are the real model
    # names (= APIM deployment names); values are friendly labels. _settings() uses the default map.
    assert body["aliasModels"]["gpt-5.4"] == "GPT-5.4"
    assert body["aliasModels"]["gpt-5.4-mini"] == "GPT-5.4 mini"
    # OSS/partner models (Phase 5, PAYG-first set) appear in the default map too.
    assert body["aliasModels"]["grok-4.3"] == "Grok 4.3 (xAI)"
    assert body["aliasModels"]["DeepSeek-V4-Pro"] == "DeepSeek V4 Pro"
    # per-model prices (Part 2) for the UI price labels.
    assert "modelPrices" in body


def test_config_exposes_model_prices(ctx):
    _, client, *_ = ctx
    body = client.get("/api/config").json()
    assert body["modelPrices"]["gpt-5.4"] == {"prompt": 0.0025, "completion": 0.015}


def test_create_key_requires_admin(ctx):
    app, client, *_ = ctx
    _as(app, USER)
    r = client.post("/api/keys", json={"consumer": "consumer-a"})
    assert r.status_code == 403


def test_admin_can_issue_key_and_sees_primary_once(ctx):
    app, client, apim, store = ctx
    _as(app, ADMIN)
    r = client.post("/api/keys", json={"consumer": "consumer-a"})
    assert r.status_code == 201
    body = r.json()
    assert body["primaryKey"] == "PK"
    assert body["consumer"] == "consumer-a"
    assert store.rows["vk-new"]["consumer"] == "consumer-a"
    assert store.rows["vk-new"]["created_by"] == "ada"


def test_list_joins_consumer_label_and_hides_keys(ctx):
    app, client, apim, store = ctx
    _as(app, ADMIN)
    client.post("/api/keys", json={"consumer": "consumer-a"})
    r = client.get("/api/keys")
    assert r.status_code == 200
    rows = r.json()
    assert rows[0]["id"] == "vk-new"
    assert rows[0]["consumer"] == "consumer-a"
    assert "primaryKey" not in rows[0]
    assert "secondaryKey" not in rows[0]


def test_delete_removes_from_apim_and_mapping(ctx):
    app, client, apim, store = ctx
    _as(app, ADMIN)
    client.post("/api/keys", json={"consumer": "consumer-a"})
    r = client.delete("/api/keys/vk-new")
    assert r.status_code == 204
    assert apim.deleted == ["vk-new"]
    assert "vk-new" not in store.rows


def _ctx_with_consumerconfig():
    apim, store = FakeApim(), FakeStore()
    store.rows["vk-1"] = {"id": "vk-1", "consumer": "consumer-a"}
    store.rows["vk-2"] = {"id": "vk-2", "consumer": "consumer-b"}
    tc = FakeConsumerConfig()
    jobs = FakeJobStarter()
    deps = AppDeps(settings=_settings(), apim=apim, store=store, spa_dir=None, consumerconfig=tc,
                   metrics=FakeMetrics(), consumerregistry=FakeConsumerRegistry(),
                   model_prices={"gpt-5.4": {"prompt": 0.0025, "completion": 0.015}},
                   job_starter=jobs)
    app = app_factory(deps)
    app.state.fake_jobs = jobs  # tests reach the job starter here without changing the 3-tuple
    return app, TestClient(app), tc


def test_list_consumers_distinct_from_mappings():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.get("/api/consumers")
    assert r.status_code == 200
    consumers = {t["consumer"]: t for t in r.json()}
    assert set(consumers) == {"consumer-a", "consumer-b"}
    assert consumers["consumer-a"]["keyCount"] == 1


def test_get_consumer_config_falls_back_to_global_when_absent():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.get("/api/consumers/consumer-a/config")
    assert r.status_code == 200
    body = r.json()
    assert body["isDefault"] is True
    assert body["allowed_models"] == ["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"]


def test_put_then_get_consumer_config():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.put("/api/consumers/consumer-a/config",
                   json={"allowed_models": ["gpt-5.4"], "daily_budget": 100})
    assert r.status_code == 200
    g = client.get("/api/consumers/consumer-a/config")
    body = g.json()
    assert body["isDefault"] is False
    assert body["allowed_models"] == ["gpt-5.4"]
    assert body["daily_budget"] == 100


def test_put_then_get_daily_budget_usd():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.put("/api/consumers/consumer-a/config", json={"daily_budget_usd": 5.0})
    assert r.status_code == 200
    body = client.get("/api/consumers/consumer-a/config").json()
    assert body["daily_budget_usd"] == 5.0


def test_consumer_config_includes_live_usage_usd():
    # usage_usd/pct are computed live from metrics.consumer_usage x model_prices, NOT from
    # active_downgrade — so a budget change reflects in pct on the next GET without a worker run.
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.put("/api/consumers/consumer-a/config", json={"daily_budget_usd": 1.0})
    body = client.get("/api/consumers/consumer-a/config").json()
    # 100k prompt @0.0025/1k = 0.25 + 40k completion @0.015/1k = 0.6 = 0.85 ; pct = 0.85/1.0
    assert body["usage_usd"] == 0.85
    assert body["pct"] == 0.85


def test_consumer_config_pct_none_without_budget():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    body = client.get("/api/consumers/consumer-a/config").json()  # no budget set
    assert body["pct"] is None


def test_budget_put_triggers_worker():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.put("/api/consumers/consumer-a/config", json={"daily_budget_usd": 5.0})
    assert app.state.fake_jobs.started == 1


def test_nonbudget_put_does_not_trigger_worker():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.put("/api/consumers/consumer-a/config", json={"allowed_models": ["gpt-5.4"]})
    assert app.state.fake_jobs.started == 0


def test_put_unknown_alias_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.put("/api/consumers/consumer-a/config", json={"allowed_models": ["gpt-4o"]})
    assert r.status_code == 400


def test_consumer_endpoints_require_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.get("/api/consumers").status_code == 403
    assert client.put("/api/consumers/consumer-a/config", json={"tokens_per_minute": 10}).status_code == 403


def test_partial_put_preserves_other_fields():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    # First set tier (rate-limit page)
    assert client.put("/api/consumers/consumer-a/config",
                      json={"tier": "large"}).status_code == 200
    # Then set ONLY allowed_models (model page) — must NOT wipe tier
    assert client.put("/api/consumers/consumer-a/config",
                      json={"allowed_models": ["gpt-5.4"]}).status_code == 200
    body = client.get("/api/consumers/consumer-a/config").json()
    assert body["allowed_models"] == ["gpt-5.4"]
    assert body["tier"] == "large"             # preserved across the second PUT


def test_empty_put_body_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.put("/api/consumers/consumer-a/config", json={}).status_code == 400


def test_list_tiers():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.get("/api/tiers")
    assert r.status_code == 200
    tiers = {t["name"]: t for t in r.json()}
    assert set(tiers) == {"small", "medium", "large"}
    assert tiers["medium"]["tpm"] == 150000
    assert tiers["large"]["period"] == "Monthly"


def test_tiers_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.get("/api/tiers").status_code == 403


def test_put_consumer_tier_roundtrip():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.put("/api/consumers/consumer-a/config", json={"tier": "large"}).status_code == 200
    body = client.get("/api/consumers/consumer-a/config").json()
    assert body["tier"] == "large"


def test_put_bad_tier_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.put("/api/consumers/consumer-a/config", json={"tier": "platinum"}).status_code == 400


def test_dashboard_metrics():
    app, client, tc = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    # a consumer with a worker-written downgrade -> should surface in the dashboard's downgrades list
    tc.docs["smoke"] = {"id": "consumer:smoke", "doc_type": "consumer_config", "consumer": "smoke",
                        "active_downgrade": {"level": 2, "usage_tokens": 9, "pct": 1.2, "evaluated_at": "x"}}
    body = client.get("/api/metrics/dashboard?range=24h").json()
    assert body["total_tokens"] == 999
    assert body["blocked_403"] == 2
    assert body["blocked_429"] == 1
    assert body["requests_by_model"] == [{"deployment": "gpt-5.4-mini", "requests": 10}]
    assert body["downgrades"] == [{"consumer": "smoke", "level": 2}]


def test_monitoring_returns_recent_and_blocked():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    body = client.get("/api/metrics/monitoring?range=1h").json()
    assert body["recent"][0]["ResultCode"] == "200"
    assert body["blocked"][0]["ResultCode"] == "429"


def test_monitoring_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.get("/api/metrics/monitoring?range=1h").status_code == 403


def test_monitoring_bad_range_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.get("/api/metrics/monitoring?range=99y").status_code == 400


def test_metrics_bad_range_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.get("/api/metrics/dashboard?range=99y").status_code == 400


def test_metrics_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.get("/api/metrics/dashboard?range=24h").status_code == 403


GUID_A = "a3b801e9-1a17-4af8-b1ef-3103a1e0f075"
GUID_B = "11111111-1111-1111-1111-111111111111"


def test_create_consumer_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.post("/api/consumers", json={"consumer": "t", "entra_group_id": GUID_A}).status_code == 403


def test_update_consumer_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.put("/api/consumers/t", json={"entra_group_id": GUID_A}).status_code == 403


def test_delete_consumer_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.delete("/api/consumers/t").status_code == 403


def test_create_consumer_persists_and_lists():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.post("/api/consumers", json={"consumer": "payments", "entra_group_id": GUID_A, "display_name": "Pay"})
    assert r.status_code == 201
    rows = {t["consumer"]: t for t in client.get("/api/consumers").json()}
    assert rows["payments"]["entraGroupId"] == GUID_A
    assert rows["payments"]["displayName"] == "Pay"
    assert rows["payments"]["source"] in ("registry", "both")


def test_create_consumer_without_group_ok():
    # entra_group_id is optional (only meaningful in entra-id auth mode); a consumer registers fine
    # with just a name in the default subscription-key mode.
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.post("/api/consumers", json={"consumer": "t"}).status_code == 201
    rows = {x["consumer"]: x for x in client.get("/api/consumers").json()}
    assert rows["t"]["entraGroupId"] is None
    assert rows["t"]["source"] in ("registry", "both")


def test_create_consumer_malformed_group_400():
    # ...but a present-yet-malformed group id is still rejected.
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    assert client.post("/api/consumers", json={"consumer": "t", "entra_group_id": "nope"}).status_code == 400


def test_create_duplicate_consumer_409():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "t", "entra_group_id": GUID_A})
    assert client.post("/api/consumers", json={"consumer": "t", "entra_group_id": GUID_B}).status_code == 409


def test_create_duplicate_group_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "a", "entra_group_id": GUID_A})
    assert client.post("/api/consumers", json={"consumer": "b", "entra_group_id": GUID_A}).status_code == 400


def test_update_consumer():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "t", "entra_group_id": GUID_A})
    r = client.put("/api/consumers/t", json={"entra_group_id": GUID_B, "display_name": "T2"})
    assert r.status_code == 200
    rows = {x["consumer"]: x for x in client.get("/api/consumers").json()}
    assert rows["t"]["entraGroupId"] == GUID_B
    assert rows["t"]["displayName"] == "T2"


def test_update_consumer_blank_group_400():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "t", "entra_group_id": GUID_A})
    assert client.put("/api/consumers/t", json={"entra_group_id": ""}).status_code == 400


def test_delete_consumer_with_live_keys_409():
    # consumer-a has a key (vk-1) seeded by _ctx_with_consumerconfig -> refuse delete.
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "consumer-a", "entra_group_id": GUID_A})
    r = client.delete("/api/consumers/consumer-a")
    assert r.status_code == 409
    # registry + config still intact (nothing deleted)
    rows = {x["consumer"]: x for x in client.get("/api/consumers").json()}
    assert rows["consumer-a"]["entraGroupId"] == GUID_A


def test_delete_consumer_no_keys_removes_registry_and_config():
    app, client, tc = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    # a registry-only consumer with a config doc but NO keys
    client.post("/api/consumers", json={"consumer": "ghost", "entra_group_id": GUID_A})
    tc.put("ghost", {"allowed_models": ["gpt-5.4"], "daily_budget_usd": 1.0})
    assert tc.get("ghost") is not None
    r = client.delete("/api/consumers/ghost")
    assert r.status_code == 200
    assert r.json()["deleted"] is True
    # both registry and config gone
    assert tc.get("ghost") is None
    rows = {x["consumer"]: x for x in client.get("/api/consumers").json()}
    assert "ghost" not in rows


def test_get_consumers_union_and_keeps_keycount():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "registryonly", "entra_group_id": GUID_A})
    rows = {x["consumer"]: x for x in client.get("/api/consumers").json()}
    assert rows["consumer-a"]["keyCount"] == 1
    assert rows["consumer-a"]["source"] == "keys"
    assert rows["registryonly"]["keyCount"] == 0
    assert rows["registryonly"]["source"] == "registry"


def test_dashboard_maps_registered_group_guid():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    client.post("/api/consumers", json={"consumer": "payments", "entra_group_id": GUID_A})
    d = client.get("/api/metrics/dashboard?range=24h").json()
    consumers = [r["consumer"] for r in d["by_consumer"]]
    assert "payments" in consumers
    assert GUID_A not in consumers
    assert "smoke" in consumers


def test_links_returns_apim_analytics_deep_link():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    r = client.get("/api/links")
    assert r.status_code == 200
    url = r.json()["apimAnalyticsUrl"]
    assert url == ("https://portal.azure.com/#@tid/resource/subscriptions/s/resourceGroups/rg"
                   "/providers/Microsoft.ApiManagement/service/apim/overview")


def test_links_requires_admin():
    app, client, _ = _ctx_with_consumerconfig()
    _as(app, USER)
    assert client.get("/api/links").status_code == 403


def test_consumer_config_exposes_active_downgrade_readonly():
    app, client, tc = _ctx_with_consumerconfig()
    _as(app, ADMIN)
    tc.docs["smoke"] = {"id": "consumer:smoke", "doc_type": "consumer_config", "consumer": "smoke",
                        "daily_budget": 1000, "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"],
                        "active_downgrade": {"level": 1, "usage_tokens": 800, "pct": 0.8,
                                             "evaluated_at": "2026-06-16T00:00:00Z"}}
    body = client.get("/api/consumers/smoke/config").json()
    assert body["daily_budget"] == 1000
    assert body["active_downgrade"]["level"] == 1
    # PUT must not let an admin set active_downgrade (worker-only); a legit field still updates
    r2 = client.put("/api/consumers/smoke/config",
                    json={"active_downgrade": {"level": 2}, "daily_budget": 2000})
    assert r2.status_code == 200
    # active_downgrade is worker-written: the admin PUT must NEITHER set it (the level=2 in the
    # body is ignored) NOR wipe it — it's preserved from the existing doc at its worker value.
    assert tc.docs["smoke"]["active_downgrade"]["level"] == 1  # preserved, not the body's 2
    assert tc.docs["smoke"]["daily_budget"] == 2000            # legit field updated
