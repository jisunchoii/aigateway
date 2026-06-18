"""APIM subscription operations: issuance/listing/revocation (spec §4 ⑥).
The ApiManagementClient is injected (built with DefaultAzureCredential in main.py) so this is
unit-testable with a fake. Subscriptions are scoped to ALL APIs in the service (service-wide), so a
consumer key reaches every API (e.g. both azure-openai and foundry). Per-model authorization is
enforced separately by the policy's allowed_models check, so scope-wide is safe. Each subscription
has an id (sid, e.g. "vk-44a9723c68dc"; its display name is the consumer name = the consumerId axis)
and a secret primary/secondary key (returned only at creation)."""
import uuid
from dataclasses import dataclass


@dataclass(frozen=True)
class Subscription:
    id: str
    display_name: str
    state: str
    primary_key: str | None = None
    secondary_key: str | None = None


class ApimKeys:
    def __init__(self, *, client, subscription_id: str, resource_group: str,
                 service_name: str):
        self._client = client
        self._sub = subscription_id
        self._rg = resource_group
        self._svc = service_name

    @property
    def _all_apis_scope(self) -> str:
        # Service-wide scope (".../apis", no api id): the key reaches every API in the instance.
        # allowed_models in the policy is the actual per-model gate.
        return (
            f"/subscriptions/{self._sub}/resourceGroups/{self._rg}"
            f"/providers/Microsoft.ApiManagement/service/{self._svc}/apis"
        )

    def create(self, *, display_name: str) -> Subscription:
        sid = f"vk-{uuid.uuid4().hex[:12]}"
        self._client.subscription.create_or_update(
            resource_group_name=self._rg,
            service_name=self._svc,
            sid=sid,
            parameters={
                "scope": self._all_apis_scope,
                "display_name": display_name,
                "state": "active",
                "allow_tracing": False,
            },
        )
        secrets = self._client.subscription.list_secrets(
            resource_group_name=self._rg, service_name=self._svc, sid=sid,
        )
        return Subscription(
            id=sid, display_name=display_name, state="active",
            primary_key=secrets.primary_key, secondary_key=secrets.secondary_key,
        )

    def list(self) -> list[Subscription]:
        subs = self._client.subscription.list(
            resource_group_name=self._rg, service_name=self._svc,
        )
        # Never return key material on list (spec §4 ⑥: APIM is the source of truth, keys
        # are shown only at creation time).
        return [
            Subscription(id=s.name, display_name=s.display_name, state=s.state)
            for s in subs
            if s.name and s.name != "master"
        ]

    def delete(self, key_id: str) -> None:
        self._client.subscription.delete(
            resource_group_name=self._rg, service_name=self._svc,
            sid=key_id, if_match="*",
        )
