import base64
import json

import sync


def test_build_consumer_bundle_shape():
    docs = [
        {"id": "consumer:consumer-a", "doc_type": "consumer_config", "consumer": "consumer-a",
         "allowed_models": ["gpt-5.6-sol", "FW-GLM-5.2"], "tier": "medium",
         "tokens_per_minute": 5000, "token_quota": 200000, "token_quota_period": "Daily",
         "daily_budget": 100, "downgrade_ladder": ["gpt-5.6-sol", "FW-GLM-5.2"]},
        {"id": "consumer:consumer-b", "doc_type": "consumer_config", "consumer": "consumer-b",
         "tier": "large"},
    ]
    bundle = sync.build_consumer_bundle(docs)
    # allowed_models (comma-joined) + tier + downgrade_ladder (comma-joined) bundled; raw token fields + budget EXCLUDED
    assert bundle["consumer-a"] == {"allowed_models": "gpt-5.6-sol,FW-GLM-5.2", "tier": "medium", "downgrade_ladder": "gpt-5.6-sol,FW-GLM-5.2"}
    assert bundle["consumer-b"] == {"tier": "large"}


def test_encode_bundle_is_base64_json():
    bundle = {"consumer-a": {"allowed_models": "FW-GLM-5.2"}}
    encoded = sync.encode_bundle(bundle)
    assert all(c.isalnum() or c in "+/=" for c in encoded)
    assert json.loads(base64.b64decode(encoded).decode("utf-8")) == bundle


def test_empty_bundle_encodes_to_empty_object():
    assert json.loads(base64.b64decode(sync.encode_bundle({})).decode("utf-8")) == {}


def test_build_consumer_bundle_skips_docs_without_consumer():
    docs = [
        {"id": "global", "allowed_models": ["gpt-5.6-sol"]},  # no "consumer" → skipped
        {"consumer": "consumer-a", "allowed_models": ["FW-GLM-5.2"]},
    ]
    bundle = sync.build_consumer_bundle(docs)
    assert set(bundle) == {"consumer-a"}


def test_build_consumer_bundle_preserves_string_allowed_models():
    # If a doc already stores allowed_models as a comma string (not a list), pass it through as-is.
    docs = [{"consumer": "consumer-a", "allowed_models": "gpt-5.6-sol,FW-GLM-5.2"}]
    bundle = sync.build_consumer_bundle(docs)
    assert bundle["consumer-a"] == {"allowed_models": "gpt-5.6-sol,FW-GLM-5.2"}


def test_bundle_includes_active_downgrade():
    docs = [
        {"consumer": "smoke", "tier": "small",
         "active_downgrade": {"level": 1, "usage_tokens": 800, "pct": 0.8, "evaluated_at": "x"}},
    ]
    bundle = sync.build_consumer_bundle(docs)
    assert bundle["smoke"]["tier"] == "small"
    assert bundle["smoke"]["active_downgrade"]["level"] == 1


def test_bundle_includes_downgrade_ladder_csv():
    docs = [{"consumer": "smoke", "tier": "small",
             "downgrade_ladder": ["gpt-5.6-sol", "FW-GLM-5.2", "grok-4.3"]}]
    bundle = sync.build_consumer_bundle(docs)
    assert bundle["smoke"]["downgrade_ladder"] == "gpt-5.6-sol,FW-GLM-5.2,grok-4.3"
