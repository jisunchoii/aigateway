"""Upsert the authoritative gateway config document into Cosmos DB (passwordless).

Run this from inside the VNet (the jumpbox), where the Cosmos private endpoint is
reachable. Authenticates with DefaultAzureCredential — on the jumpbox this resolves to
the VM's managed identity, which must hold "Cosmos DB Built-in Data Contributor" on the
account. Cosmos has key auth disabled, so Entra ID is the only option.

Usage (on the jumpbox):
    pip install azure-identity azure-cosmos
    python seed_cosmos.py --endpoint https://<account>.documents.azure.com:443/

The document mirrors scripts/seed-config.ps1 and what the config-sync worker reads
(id="global"). Override individual fields with the optional flags if needed.
"""
import argparse

from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

DATABASE = "gateway"
CONTAINER = "config"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="Cosmos document endpoint URL")
    parser.add_argument("--database", default=DATABASE)
    parser.add_argument("--container", default=CONTAINER)
    parser.add_argument("--allowed-models", nargs="+",
                        default=["gpt-5.4", "gpt-5.4-mini", "grok-4.3", "DeepSeek-V4-Pro"])
    parser.add_argument("--tokens-per-minute", type=int, default=1000)
    parser.add_argument("--token-quota", type=int, default=50000)
    parser.add_argument("--token-quota-period", default="Daily",
                        choices=["Hourly", "Daily", "Weekly", "Monthly"])
    args = parser.parse_args()

    doc = {
        "id": "global",
        "allowed_models": args.allowed_models,
        "tokens_per_minute": args.tokens_per_minute,
        "token_quota": args.token_quota,
        "token_quota_period": args.token_quota_period,
    }

    client = CosmosClient(args.endpoint, credential=DefaultAzureCredential())
    container = client.get_database_client(args.database).get_container_client(args.container)
    container.upsert_item(doc)
    print(f"upserted config doc id='global' into {args.database}/{args.container}:")
    print(doc)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
