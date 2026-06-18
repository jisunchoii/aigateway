"""Production entrypoint: build real dependencies (DefaultAzureCredential + Azure SDK clients),
wire the JWKS verifier, and expose `app` for uvicorn (uvicorn bff.main:app)."""
import logging
from pathlib import Path

import httpx
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from azure.mgmt.apimanagement import ApiManagementClient
from azure.monitor.query import LogsQueryClient

from bff.apim import ApimKeys
from bff.app import AppDeps, app_factory
from bff.config import Settings
from bff.deps import build_verifier, get_verifier
from bff.jobs import JobStarter
from bff.metrics import MetricsQuery
from bff.store import MappingStore
from bff.consumerconfig import ConsumerConfigStore
from bff.consumerregistry import ConsumerRegistryStore

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

SPA_DIR = Path(__file__).resolve().parent / "static"


def _read_model_prices(config_container) -> dict:
    """The operator-owned `pricing` Cosmos doc -> {model: {prompt, completion}} per-1k rates, for the
    UI price labels. Read once at startup (prices change rarely; an edit needs a BFF restart to
    reflect). Empty dict if the doc is absent."""
    from azure.cosmos.exceptions import CosmosResourceNotFoundError
    try:
        doc = config_container.read_item(item="pricing", partition_key="pricing")
    except CosmosResourceNotFoundError:
        return {}
    return doc.get("models", {})


def build_app():
    settings = Settings.from_env()
    cred = DefaultAzureCredential()

    apim_client = ApiManagementClient(cred, settings.subscription_id)
    apim = ApimKeys(
        client=apim_client, subscription_id=settings.subscription_id,
        resource_group=settings.apim_rg, service_name=settings.apim_name,
    )

    cosmos = CosmosClient(settings.cosmos_endpoint, credential=cred)
    container = cosmos.get_database_client(settings.cosmos_database).get_container_client(
        settings.cosmos_map_container
    )
    store = MappingStore(container)

    config_container = cosmos.get_database_client(settings.cosmos_database).get_container_client("config")
    consumerconfig = ConsumerConfigStore(config_container)
    consumerregistry = ConsumerRegistryStore(config_container)
    model_prices = _read_model_prices(config_container)

    metrics = MetricsQuery(LogsQueryClient(cred), settings.log_analytics_workspace_id)

    # The config-sync job lives in the same resource group as APIM (the stack RG).
    job_starter = JobStarter(cred, httpx.Client(), sub=settings.subscription_id,
                             rg=settings.apim_rg, job=settings.config_sync_job_name)

    deps = AppDeps(settings=settings, apim=apim, store=store,
                   spa_dir=SPA_DIR if SPA_DIR.is_dir() else None,
                   consumerconfig=consumerconfig, metrics=metrics, consumerregistry=consumerregistry,
                   model_prices=model_prices, job_starter=job_starter)
    app = app_factory(deps)

    verifier = build_verifier(settings)
    app.dependency_overrides[get_verifier] = lambda: verifier
    return app


app = build_app()
