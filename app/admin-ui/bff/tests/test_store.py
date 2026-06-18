from azure.cosmos.exceptions import CosmosResourceNotFoundError

from bff.store import MappingStore


class FakeContainer:
    def __init__(self):
        self.items = {}

    def upsert_item(self, body):
        self.items[body["id"]] = body
        return body

    def read_all_items(self):
        return list(self.items.values())

    def delete_item(self, item, partition_key):
        self.items.pop(item, None)


def test_record_and_list_mapping():
    c = FakeContainer()
    s = MappingStore(c)
    s.record(key_id="vk-1", consumer="consumer-a", display_name="consumer-a", created_by="ada")
    rows = s.list()
    assert len(rows) == 1
    assert rows[0]["id"] == "vk-1"
    assert rows[0]["consumer"] == "consumer-a"
    assert rows[0]["created_by"] == "ada"
    assert "primary_key" not in rows[0]  # never persist key material


def test_remove_mapping():
    c = FakeContainer()
    s = MappingStore(c)
    s.record(key_id="vk-1", consumer="consumer-a", display_name="consumer-a", created_by="ada")
    s.remove("vk-1")
    assert s.list() == []


def test_remove_nonexistent_is_silent():
    class RaisingContainer:
        def delete_item(self, item, partition_key):
            raise CosmosResourceNotFoundError(message="not found")

    s = MappingStore(RaisingContainer())
    s.remove("vk-missing")  # must not raise


def test_record_multiple_consumers_all_listed():
    c = FakeContainer()
    s = MappingStore(c)
    s.record(key_id="vk-1", consumer="consumer-a", display_name="consumer-a", created_by="ada")
    s.record(key_id="vk-2", consumer="consumer-b", display_name="consumer-b", created_by="bob")
    ids = sorted(r["id"] for r in s.list())
    assert ids == ["vk-1", "vk-2"]
