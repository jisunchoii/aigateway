import os

from bff.config import Settings


def test_settings_read_from_env(monkeypatch):
    for k in [
        "ENTRA_TENANT_ID", "BFF_API_AUDIENCE", "SPA_CLIENT_ID",
        "ADMIN_GROUP_OBJECT_ID", "SUBSCRIPTION_ID", "APIM_RG",
        "APIM_NAME", "COSMOS_ENDPOINT",
        "COSMOS_DATABASE", "COSMOS_MAP_CONTAINER",
        "LOG_ANALYTICS_WORKSPACE_ID",
    ]:
        monkeypatch.setenv(k, k.lower())
    s = Settings.from_env()
    assert s.entra_tenant_id == "entra_tenant_id"
    assert s.bff_api_audience == "bff_api_audience"
    assert s.spa_client_id == "spa_client_id"
    assert s.admin_group_object_id == "admin_group_object_id"
    assert s.cosmos_map_container == "cosmos_map_container"
    # With no explicit ALLOWED_MODEL_ALIASES and no ALIAS_MODELS_JSON, the validator allowlist
    # derives from the default alias-models map keys (incl. the Foundry OSS aliases).
    assert set(s.allowed_model_aliases) == set(s.alias_models.keys())
    assert "grok-4.3" in s.allowed_model_aliases
    assert set(s.rate_tiers.keys()) == {"small", "medium", "large"}
    assert s.rate_tiers["medium"]["tpm"] == 150000
    assert s.issuer == "https://login.microsoftonline.com/entra_tenant_id/v2.0"
    assert s.jwks_uri == (
        "https://login.microsoftonline.com/entra_tenant_id/discovery/v2.0/keys"
    )
    assert s.log_analytics_workspace_id == "log_analytics_workspace_id"


def test_allowed_aliases_default_to_alias_models_keys(monkeypatch):
    """REGRESSION: the Models page offers every alias in ALIAS_MODELS_JSON, so the BFF validator
    must accept them all. Previously allowed_model_aliases defaulted to a hardcoded gpt-only list,
    so saving a consumer with an OSS model 400'd ('unknown alias')."""
    for k in ["ENTRA_TENANT_ID", "BFF_API_AUDIENCE", "SPA_CLIENT_ID", "ADMIN_GROUP_OBJECT_ID",
              "SUBSCRIPTION_ID", "APIM_RG", "APIM_NAME", "COSMOS_ENDPOINT",
              "COSMOS_DATABASE", "COSMOS_MAP_CONTAINER"]:
        monkeypatch.setenv(k, k.lower())
    monkeypatch.delenv("ALLOWED_MODEL_ALIASES", raising=False)
    monkeypatch.setenv("ALIAS_MODELS_JSON",
                       '{"gpt-5.4":"gpt-5.4","grok-4.3":"grok-4.3","DeepSeek-V4-Pro":"DeepSeek-V4-Pro"}')
    s = Settings.from_env()
    assert set(s.allowed_model_aliases) == {"gpt-5.4", "grok-4.3", "DeepSeek-V4-Pro"}


def test_explicit_allowed_aliases_env_overrides(monkeypatch):
    for k in ["ENTRA_TENANT_ID", "BFF_API_AUDIENCE", "SPA_CLIENT_ID", "ADMIN_GROUP_OBJECT_ID",
              "SUBSCRIPTION_ID", "APIM_RG", "APIM_NAME", "COSMOS_ENDPOINT",
              "COSMOS_DATABASE", "COSMOS_MAP_CONTAINER"]:
        monkeypatch.setenv(k, k.lower())
    monkeypatch.setenv("ALLOWED_MODEL_ALIASES", "gpt-5.4,gpt-5.4-mini")
    monkeypatch.setenv("ALIAS_MODELS_JSON", '{"gpt-5.4":"gpt-5.4","grok-4.3":"grok-4.3"}')
    s = Settings.from_env()
    assert s.allowed_model_aliases == ("gpt-5.4", "gpt-5.4-mini")
