from bff.apim import ApimKeys, Subscription


class FakeSub:
    def __init__(self, name, display_name, state="active"):
        self.name = name
        self.display_name = display_name
        self.state = state


class FakeSecrets:
    primary_key = "PRIMARY"
    secondary_key = "SECONDARY"


class FakeSubscriptionOps:
    def __init__(self):
        self.created = []
        self.deleted = []
        self._store = [FakeSub("sub-existing", "consumer-a"), FakeSub("master", "Built-in all-access")]

    def create_or_update(self, resource_group_name, service_name, sid, parameters, **kw):
        self.created.append((sid, parameters))
        return FakeSub(sid, parameters["display_name"])

    def list_secrets(self, resource_group_name, service_name, sid, **kw):
        return FakeSecrets()

    def list(self, resource_group_name, service_name, **kw):
        return list(self._store)

    def delete(self, resource_group_name, service_name, sid, if_match, **kw):
        self.deleted.append((sid, if_match))


class FakeClient:
    def __init__(self):
        self.subscription = FakeSubscriptionOps()


def _keys():
    return ApimKeys(
        client=FakeClient(), subscription_id="s", resource_group="rg",
        service_name="apim",
    )


def test_create_scopes_to_all_apis_and_returns_primary_key():
    k = _keys()
    vk = k.create(display_name="consumer-a")
    assert isinstance(vk, Subscription)
    assert vk.primary_key == "PRIMARY"
    sid, params = k._client.subscription.created[0]
    # service-wide scope (no api id) so the key reaches every API (openai + foundry)
    assert params["scope"] == (
        "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement"
        "/service/apim/apis"
    )
    assert params["display_name"] == "consumer-a"


def test_list_returns_subscriptions_without_keys():
    k = _keys()
    items = k.list()
    ids = [i.id for i in items]
    assert ids == ["sub-existing"]            # master is filtered out
    assert "master" not in ids
    assert all(i.primary_key is None and i.secondary_key is None for i in items)


def test_delete_passes_wildcard_if_match():
    k = _keys()
    k.delete("sub-existing")
    assert k._client.subscription.deleted == [("sub-existing", "*")]
