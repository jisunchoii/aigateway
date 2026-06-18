"""Cosmos repository for the consumer registry (the `config` container's consumer_registry docs).
Maps a human-readable consumer name to an OPTIONAL Entra ID group GUID (+ display metadata).
The group id is only meaningful in entra-id auth mode (consumerId = groups claim); in the default
subscription-key mode the gateway counts on the APIM subscription id, so the group is left blank
until/unless Entra ID auth is enabled. SEPARATE from consumer_config by doc_type so it NEVER enters
the config-sync worker's policy bundle — the registry is display/translation only and must not
affect APIM policy."""
import re
from typing import Optional

from azure.cosmos.exceptions import CosmosResourceNotFoundError

_GUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def _doc_id(consumer: str) -> str:
    return f"consumerreg:{consumer}"


def validate(fields: dict, *, existing_group_owners: Optional[dict] = None) -> None:
    """Raise ValueError on invalid registry fields. entra_group_id is OPTIONAL (blank/absent is
    fine — only meaningful in entra-id auth mode); when present it must be a GUID and may map to
    at most one consumer (existing_group_owners = {group_id: consumer})."""
    gid = fields.get("entra_group_id")
    if not gid:
        return
    if not _GUID_RE.match(str(gid)):
        raise ValueError("entra_group_id must be a valid GUID when provided")
    if existing_group_owners:
        owner = existing_group_owners.get(gid)
        if owner is not None and owner != fields.get("consumer"):
            raise ValueError(f"entra_group_id already mapped to consumer '{owner}'")


class ConsumerRegistryStore:
    def __init__(self, container):
        self._c = container

    def get(self, consumer: str) -> Optional[dict]:
        try:
            return self._c.read_item(item=_doc_id(consumer), partition_key=_doc_id(consumer))
        except CosmosResourceNotFoundError:
            return None

    def put(self, consumer: str, fields: dict, *, existing_group_owners: Optional[dict] = None) -> dict:
        validate({**fields, "consumer": consumer}, existing_group_owners=existing_group_owners)
        # Identity wins: spread fields first, then force id/doc_type/consumer so a caller can't
        # override the document identity via fields.
        body = {**fields, "id": _doc_id(consumer), "doc_type": "consumer_registry", "consumer": consumer}
        return self._c.upsert_item(body=body)

    def remove(self, consumer: str) -> None:
        try:
            self._c.delete_item(item=_doc_id(consumer), partition_key=_doc_id(consumer))
        except CosmosResourceNotFoundError:
            pass

    def list(self) -> list[dict]:
        return list(self._c.query_items(
            query='SELECT * FROM c WHERE c.doc_type = "consumer_registry"',
            enable_cross_partition_query=True,
        ))

    def group_index(self) -> dict:
        """{entra_group_id: consumer} reverse index for GUID->consumer translation + dup detection."""
        return {d["entra_group_id"]: d["consumer"] for d in self.list() if d.get("entra_group_id")}
