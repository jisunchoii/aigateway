import sync


def test_shape_usage_groups_by_consumer_model_kind():
    rows = [
        {"consumer": "smoke", "model": "gpt-5.6-sol", "tok_kind": "prompt", "tokens": 1000},
        {"consumer": "smoke", "model": "gpt-5.6-sol", "tok_kind": "completion", "tokens": 200},
        {"consumer": "smoke", "model": "grok-4.3", "tok_kind": "prompt", "tokens": 50},
        {"consumer": "other", "model": "FW-GLM-5.2", "tok_kind": "completion", "tokens": 9},
    ]
    out = sync._shape_usage(rows)
    assert out["smoke"]["gpt-5.6-sol"] == {"prompt": 1000, "completion": 200}
    assert out["smoke"]["grok-4.3"] == {"prompt": 50, "completion": 0}
    assert out["other"]["FW-GLM-5.2"] == {"prompt": 0, "completion": 9}


def test_shape_usage_ignores_rows_without_consumer_or_model():
    rows = [{"consumer": "", "model": "gpt-5.6-sol", "tok_kind": "prompt", "tokens": 5},
            {"consumer": "x", "model": "", "tok_kind": "prompt", "tokens": 5},
            {"consumer": "x", "model": "gpt-5.6-sol", "tok_kind": "bogus", "tokens": 5}]
    assert sync._shape_usage(rows) == {}


def test_shape_usage_sums_duplicate_rows():
    rows = [{"consumer": "a", "model": "gpt-5.6-sol", "tok_kind": "prompt", "tokens": 100},
            {"consumer": "a", "model": "gpt-5.6-sol", "tok_kind": "prompt", "tokens": 50}]
    assert sync._shape_usage(rows)["a"]["gpt-5.6-sol"]["prompt"] == 150


def test_usage_kql_avoids_reserved_keyword_kind():
    # REGRESSION: 'kind' is a reserved KQL keyword; using it as a summarize-by column name fails to
    # parse server-side (BadArgumentError). The column must be tok_kind.
    assert " kind" not in sync._USAGE_KQL
    assert "tok_kind" in sync._USAGE_KQL


def test_read_pricing_parses_models_map():
    class FakeContainer:
        def read_item(self, item, partition_key):
            assert item == "pricing"
            return {"id": "pricing", "models": {"gpt-5.6-sol": {"prompt": 0.0025, "completion": 0.015}}}
    p = sync.read_pricing(FakeContainer())
    assert p == {"gpt-5.6-sol": {"prompt": 0.0025, "completion": 0.015}}


def test_read_pricing_missing_doc_returns_empty():
    from azure.cosmos.exceptions import CosmosResourceNotFoundError

    class FakeContainer:
        def read_item(self, item, partition_key):
            raise CosmosResourceNotFoundError(message="nope")
    assert sync.read_pricing(FakeContainer()) == {}
