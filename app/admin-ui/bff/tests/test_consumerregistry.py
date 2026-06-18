import pytest

from bff.consumerregistry import ConsumerRegistryStore, validate


class FakeContainer:
    """In-memory stand-in for a Cosmos container (id-keyed)."""
    def __init__(self):
        self.items = {}

    def upsert_item(self, body):
        self.items[body["id"]] = body
        return body

    def read_item(self, item, partition_key):
        if item not in self.items:
            from azure.cosmos.exceptions import CosmosResourceNotFoundError as E
            raise E(message="nf")
        return self.items[item]

    def delete_item(self, item, partition_key):
        if item not in self.items:
            from azure.cosmos.exceptions import CosmosResourceNotFoundError as E
            raise E(message="nf")
        del self.items[item]

    def query_items(self, query, enable_cross_partition_query=False):
        return [v for v in self.items.values() if v.get("doc_type") == "consumer_registry"]


GUID = "a3b801e9-1a17-4af8-b1ef-3103a1e0f075"


def test_validate_group_optional_but_format_checked_when_present():
    validate({"consumer": "t"})  # no entra_group_id -> ok (optional)
    validate({"consumer": "t", "entra_group_id": ""})  # blank -> ok (optional)
    validate({"consumer": "t", "entra_group_id": None})  # null -> ok (optional)
    with pytest.raises(ValueError):
        validate({"consumer": "t", "entra_group_id": "not-a-guid"})  # present but malformed
    validate({"consumer": "t", "entra_group_id": GUID})  # present + valid -> ok


def test_validate_rejects_duplicate_group():
    owners = {GUID: "payments"}
    with pytest.raises(ValueError):
        validate({"consumer": "other", "entra_group_id": GUID}, existing_group_owners=owners)
    validate({"consumer": "payments", "entra_group_id": GUID}, existing_group_owners=owners)


def test_put_get_roundtrip_and_forces_identity():
    store = ConsumerRegistryStore(FakeContainer())
    store.put("payments", {"entra_group_id": GUID, "display_name": "Pay",
                           "id": "consumerreg:hacker", "doc_type": "evil", "consumer": "spoof"})
    doc = store.get("payments")
    assert doc["id"] == "consumerreg:payments"
    assert doc["doc_type"] == "consumer_registry"
    assert doc["consumer"] == "payments"
    assert doc["entra_group_id"] == GUID
    assert doc["display_name"] == "Pay"


def test_get_missing_returns_none():
    assert ConsumerRegistryStore(FakeContainer()).get("nope") is None


def test_remove_is_idempotent():
    store = ConsumerRegistryStore(FakeContainer())
    store.put("p", {"entra_group_id": GUID})
    store.remove("p")
    store.remove("p")
    assert store.get("p") is None


def test_list_and_group_index():
    store = ConsumerRegistryStore(FakeContainer())
    store.put("payments", {"entra_group_id": GUID})
    store.put("data", {"entra_group_id": "11111111-1111-1111-1111-111111111111"})
    consumers = {d["consumer"] for d in store.list()}
    assert consumers == {"payments", "data"}
    idx = store.group_index()
    assert idx[GUID] == "payments"
