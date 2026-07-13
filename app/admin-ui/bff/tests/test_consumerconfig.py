import pytest

from bff.consumerconfig import ConsumerConfigStore

ALIASES = ["gpt-5.6-sol", "FW-GLM-5.2", "grok-4.3", "DeepSeek-V4-Pro"]


class FakeContainer:
    def __init__(self, seed=None):
        self.items = dict(seed or {})

    def read_item(self, item, partition_key):
        from azure.cosmos.exceptions import CosmosResourceNotFoundError
        if item not in self.items:
            raise CosmosResourceNotFoundError(message="not found")
        return self.items[item]

    def upsert_item(self, body):
        self.items[body["id"]] = body
        return body

    def delete_item(self, item, partition_key):
        from azure.cosmos.exceptions import CosmosResourceNotFoundError
        if item not in self.items:
            raise CosmosResourceNotFoundError(message="not found")
        del self.items[item]


def test_get_returns_none_when_consumer_has_no_doc():
    s = ConsumerConfigStore(FakeContainer())
    assert s.get("consumer-a") is None


def test_remove_deletes_config_doc():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"allowed_models": ["gpt-5.6-sol"]})
    assert s.get("consumer-a") is not None
    s.remove("consumer-a")
    assert s.get("consumer-a") is None


def test_remove_absent_is_noop():
    s = ConsumerConfigStore(FakeContainer())
    s.remove("never-existed")  # must not raise


def test_put_then_get_roundtrip():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"allowed_models": ["gpt-5.6-sol"], "tokens_per_minute": 5000,
                     "daily_budget": 100})
    doc = s.get("consumer-a")
    assert doc["id"] == "consumer:consumer-a"
    assert doc["doc_type"] == "consumer_config"
    assert doc["consumer"] == "consumer-a"
    assert doc["allowed_models"] == ["gpt-5.6-sol"]
    assert doc["tokens_per_minute"] == 5000
    assert doc["daily_budget"] == 100


def test_put_validates_unknown_model_alias():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError, match="gpt-4o"):
        s.put("consumer-a", {"allowed_models": ["gpt-4o"]}, valid_aliases=ALIASES)


def test_put_validates_period():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError, match="Forever"):
        s.put("consumer-a", {"token_quota_period": "Forever"})


def test_put_rejects_nonpositive_numbers():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError):
        s.put("consumer-a", {"tokens_per_minute": 0})


def test_put_rejects_bool_as_int():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError):
        s.put("consumer-a", {"tokens_per_minute": True})


def test_put_accepts_daily_budget_usd_float():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"daily_budget_usd": 12.5})
    assert s.get("consumer-a")["daily_budget_usd"] == 12.5


def test_put_rejects_nonpositive_daily_budget_usd():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError):
        s.put("consumer-a", {"daily_budget_usd": 0})


def test_put_rejects_bool_as_daily_budget_usd():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError):
        s.put("consumer-a", {"daily_budget_usd": True})


def test_put_rejects_nonlist_allowed_models():
    s = ConsumerConfigStore(FakeContainer())
    with pytest.raises(ValueError, match="list"):
        s.put("consumer-a", {"allowed_models": "gpt-5.6-sol"})


def test_put_ignores_reserved_keys_in_fields():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"id": "consumer:evil", "doc_type": "hacked", "tokens_per_minute": 100})
    doc = s.get("consumer-a")
    assert doc["id"] == "consumer:consumer-a"        # not consumer:evil
    assert doc["doc_type"] == "consumer_config"  # not hacked
    assert doc["tokens_per_minute"] == 100


def test_put_partial_only_budget_ok():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"daily_budget": 50})
    assert s.get("consumer-a")["daily_budget"] == 50


def test_global_defaults_reads_global_doc():
    c = FakeContainer(seed={"global": {"id": "global", "allowed_models": ["gpt-5.6-sol"],
                                       "tokens_per_minute": 1000, "token_quota": 50000,
                                       "token_quota_period": "Daily"}})
    s = ConsumerConfigStore(c)
    g = s.global_defaults()
    assert g["tokens_per_minute"] == 1000
    assert g["allowed_models"] == ["gpt-5.6-sol"]


def test_global_defaults_empty_when_no_global_doc():
    s = ConsumerConfigStore(FakeContainer())
    assert s.global_defaults() == {}


def test_put_accepts_valid_tier():
    c = FakeContainer()
    s = ConsumerConfigStore(c)
    s.put("consumer-a", {"tier": "medium"})
    assert s.get("consumer-a")["tier"] == "medium"


def test_put_rejects_unknown_tier():
    s = ConsumerConfigStore(FakeContainer())
    try:
        s.put("consumer-a", {"tier": "platinum"})
        assert False, "expected ValueError"
    except ValueError as e:
        assert "platinum" in str(e)


class FakeContainerForList:
    def __init__(self, items):
        self._items = items

    def query_items(self, query, enable_cross_partition_query=False):
        # crude: only supports the consumer_config doc_type query used by list()
        return [i for i in self._items if i.get("doc_type") == "consumer_config"]


def test_list_returns_consumer_config_docs_only():
    c = FakeContainerForList([
        {"consumer": "a", "doc_type": "consumer_config", "active_downgrade": {"level": 1}},
        {"consumer": "b", "doc_type": "consumer_config"},
        {"consumer": "x", "doc_type": "consumer_registry"},
        {"id": "global"},
    ])
    store = ConsumerConfigStore(c)
    rows = store.list()
    consumers = {d["consumer"] for d in rows}
    assert consumers == {"a", "b"}
    # active_downgrade is projected (used by the dashboard's downgrade panel)
    a = next(d for d in rows if d["consumer"] == "a")
    assert a["active_downgrade"]["level"] == 1
