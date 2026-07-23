"""Environment-driven BFF settings. All values are injected by the Container App
(see modules/control_plane admin_ui env). No secrets here — auth is via managed identity."""
import json
import os
from dataclasses import dataclass, field

_DEFAULT_RATE_TIERS = {
    "small": {"tpm": 50000, "quota": 5000000, "period": "Daily"},
    "medium": {"tpm": 150000, "quota": 30000000, "period": "Daily"},
    "large": {"tpm": 300000, "quota": 1000000000, "period": "Monthly"},
}

# model id (= APIM deployment name) -> display label. No alias indirection: the deployment name
# IS the real model name. Authoritative source is Terraform (alias_models_json display map)
# injected via ALIAS_MODELS_JSON; this default mirrors it for local dev / when the env is absent.
_DEFAULT_ALIAS_MODELS = {
    "gpt-5.4": "GPT-5.4", "gpt-5.4-mini": "GPT-5.4 mini",
    "grok-4.3": "Grok 4.3 (xAI)", "DeepSeek-V4-Pro": "DeepSeek V4 Pro",
}


@dataclass(frozen=True)
class Settings:
    entra_tenant_id: str
    bff_api_audience: str
    spa_client_id: str
    admin_group_object_id: str
    subscription_id: str
    apim_rg: str
    apim_name: str
    cosmos_endpoint: str
    cosmos_database: str
    cosmos_map_container: str
    allowed_model_aliases: tuple[str, ...]
    rate_tiers: dict
    log_analytics_workspace_id: str = ""
    config_sync_job_name: str = ""  # Container Apps job the BFF starts on a budget change (instant re-eval)
    alias_models: dict = field(default_factory=lambda: dict(_DEFAULT_ALIAS_MODELS))

    @classmethod
    def from_env(cls) -> "Settings":
        alias_models = (json.loads(os.environ["ALIAS_MODELS_JSON"])
                        if os.environ.get("ALIAS_MODELS_JSON") else dict(_DEFAULT_ALIAS_MODELS))
        # The validator allowlist (which aliases a consumer may be granted) must equal the alias
        # universe the Models page offers — i.e. the keys of alias_models. An explicit
        # ALLOWED_MODEL_ALIASES env still overrides; otherwise derive from alias_models so the two
        # can never drift (a stale hardcoded default 400'd saves of Foundry OSS models).
        env_allowed = os.environ.get("ALLOWED_MODEL_ALIASES")
        allowed_aliases = (tuple(a for a in env_allowed.split(",") if a)
                           if env_allowed else tuple(alias_models.keys()))
        return cls(
            entra_tenant_id=os.environ["ENTRA_TENANT_ID"],
            bff_api_audience=os.environ["BFF_API_AUDIENCE"],
            spa_client_id=os.environ["SPA_CLIENT_ID"],
            admin_group_object_id=os.environ["ADMIN_GROUP_OBJECT_ID"],
            subscription_id=os.environ["SUBSCRIPTION_ID"],
            apim_rg=os.environ["APIM_RG"],
            apim_name=os.environ["APIM_NAME"],
            cosmos_endpoint=os.environ["COSMOS_ENDPOINT"],
            cosmos_database=os.environ["COSMOS_DATABASE"],
            cosmos_map_container=os.environ["COSMOS_MAP_CONTAINER"],
            allowed_model_aliases=allowed_aliases,
            rate_tiers=json.loads(os.environ["RATE_TIERS_JSON"]) if os.environ.get("RATE_TIERS_JSON") else _DEFAULT_RATE_TIERS,
            log_analytics_workspace_id=os.environ.get("LOG_ANALYTICS_WORKSPACE_ID", ""),
            config_sync_job_name=os.environ.get("CONFIG_SYNC_JOB_NAME", ""),
            alias_models=alias_models,
        )

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.entra_tenant_id}/v2.0"

    @property
    def jwks_uri(self) -> str:
        return f"https://login.microsoftonline.com/{self.entra_tenant_id}/discovery/v2.0/keys"

    @property
    def apim_resource_id(self) -> str:
        return (f"/subscriptions/{self.subscription_id}/resourceGroups/{self.apim_rg}"
                f"/providers/Microsoft.ApiManagement/service/{self.apim_name}")

    @property
    def apim_analytics_url(self) -> str:
        """Azure portal deep-link to the APIM resource. The native Analytics (Azure Monitor
        workbook over ApiManagementGatewayLogs) lives under this resource's Monitoring > Analytics
        blade — it can't be embedded, so the UI links out to it. Tenant-scoped so the portal opens
        in the right directory."""
        return (f"https://portal.azure.com/#@{self.entra_tenant_id}"
                f"/resource{self.apim_resource_id}/overview")
