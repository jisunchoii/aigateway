"""Cosmos repository for consumer<->subscription mappings. Stores ONLY non-secret metadata
(key id, consumer label, who/when). The actual key lives in APIM. created_at is set by the caller
(passed in) to keep this layer pure/testable; main.py supplies a UTC timestamp."""
from typing import Optional

from azure.cosmos.exceptions import CosmosResourceNotFoundError


class MappingStore:
    def __init__(self, container):
        self._c = container

    def record(self, *, key_id: str, consumer: str, display_name: str,
               created_by: str, created_at: Optional[str] = None) -> dict:
        body = {
            "id": key_id,
            "consumer": consumer,
            "display_name": display_name,
            "created_by": created_by,
            "created_at": created_at,
        }
        return self._c.upsert_item(body=body)

    def list(self) -> list[dict]:
        return list(self._c.read_all_items())

    def remove(self, key_id: str) -> None:
        # Idempotent: a revoke flow deletes the APIM subscription first, then the mapping, so the
        # mapping may already be gone. "Delete something already absent" is a no-op, not an error.
        try:
            self._c.delete_item(item=key_id, partition_key=key_id)
        except CosmosResourceNotFoundError:
            pass
