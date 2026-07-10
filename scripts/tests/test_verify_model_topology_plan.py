import importlib.util
import re
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).parents[1] / "verify_model_topology_plan.py"
APIM_MODULE_PATH = Path(__file__).parents[2] / "infra" / "modules" / "apim" / "main.tf"
SPEC = importlib.util.spec_from_file_location("verify_model_topology_plan", MODULE_PATH)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)

CANONICAL_ACCOUNT = "module.foundry.azapi_resource.project_account[0]"
CANONICAL_PROJECT = "module.foundry.azapi_resource.project[0]"
CANONICAL_PRIVATE_ENDPOINT = "module.foundry.azurerm_private_endpoint.project_account"
CANONICAL_APIM_OPENAI_ROLE = (
    "module.apim.azurerm_role_assignment.apim_to_model_openai"
)
CANONICAL_APIM_FOUNDRY_ROLE = (
    "module.apim.azurerm_role_assignment.apim_to_model_foundry"
)
EXPECTED_MODELS = {
    "gpt-5.6-sol",
    "FW-GLM-5.2",
    "DeepSeek-V4-Pro",
    "grok-4.3",
}


def plan(*changes):
    return {"resource_changes": list(changes)}


def canonical_deployment_address(model):
    return (
        "module.foundry.azurerm_cognitive_deployment."
        f'project_models["{model}"]'
    )


def change(
    address,
    actions,
    previous_address=None,
    resource_type=None,
    before=None,
    after=None,
):
    change_data = {"actions": actions}
    if before is not None:
        change_data["before"] = before
    if after is not None:
        change_data["after"] = after
    value = {"address": address, "change": change_data}
    if previous_address is not None:
        value["previous_address"] = previous_address
    if resource_type is not None:
        value["type"] = resource_type
    return value


def canonical_fresh_changes():
    changes = [
        change(
            CANONICAL_ACCOUNT,
            ["create"],
            resource_type="azapi_resource",
            after={"type": "Microsoft.CognitiveServices/accounts@2025-04-01-preview"},
        ),
        change(
            CANONICAL_PROJECT,
            ["create"],
            resource_type="azapi_resource",
            after={
                "type": "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview",
            },
        ),
        change(
            CANONICAL_PRIVATE_ENDPOINT,
            ["create"],
            resource_type="azurerm_private_endpoint",
        ),
        change(
            CANONICAL_APIM_OPENAI_ROLE,
            ["create"],
            resource_type="azurerm_role_assignment",
        ),
        change(
            CANONICAL_APIM_FOUNDRY_ROLE,
            ["create"],
            resource_type="azurerm_role_assignment",
        ),
    ]
    changes.extend(
        change(
            canonical_deployment_address(model),
            ["create"],
            resource_type="azurerm_cognitive_deployment",
            after={"name": model},
        )
        for model in sorted(EXPECTED_MODELS)
    )
    return changes


def test_fresh_plan_accepts_complete_canonical_topology():
    assert verify.verify_plan(plan(*canonical_fresh_changes()), "fresh") == []


@pytest.mark.parametrize(
    "required_address",
    [
        "module.foundry.azapi_resource.project[0]",
        "module.foundry.azurerm_private_endpoint.project_account",
        "module.apim.azurerm_role_assignment.apim_to_model_openai",
        "module.apim.azurerm_role_assignment.apim_to_model_foundry",
    ],
)
def test_fresh_plan_requires_every_canonical_non_deployment_resource(required_address):
    value = plan(
        *[
            item
            for item in canonical_fresh_changes()
            if item["address"] != required_address
        ]
    )

    errors = verify.verify_plan(value, "fresh")

    assert any(required_address in error for error in errors), errors


def test_fresh_plan_rejects_split_openai_module():
    value = plan(
        *canonical_fresh_changes(),
        change("module.openai[0].azurerm_cognitive_account.openai[0]", ["create"]),
    )
    errors = verify.verify_plan(value, "fresh")
    assert any("module.openai" in error for error in errors)


@pytest.mark.parametrize(
    "address",
    [
        "module.foundry.azurerm_cognitive_account.foundry[0]",
        'module.foundry.azurerm_cognitive_deployment.models["legacy"]',
        "module.foundry.azurerm_private_endpoint.foundry[0]",
        "module.apim.azurerm_role_assignment.apim_to_openai[0]",
        "module.apim.azurerm_role_assignment.apim_to_foundry[0]",
    ],
)
def test_fresh_plan_rejects_legacy_fallback_creates(address):
    value = plan(
        *canonical_fresh_changes(),
        change(address, ["create"]),
    )
    errors = verify.verify_plan(value, "fresh")
    assert any(address in error for error in errors), errors


@pytest.mark.parametrize(
    "extra_change",
    [
        change(
            "module.rogue.azurerm_cognitive_account.extra",
            ["create"],
            resource_type="azurerm_cognitive_account",
            after={"name": "extra-account", "kind": "AIServices"},
        ),
        change(
            "module.rogue.azapi_resource.extra",
            ["create"],
            resource_type="azapi_resource",
            after={
                "name": "extra-account",
                "type": "Microsoft.CognitiveServices/accounts@2025-04-01-preview",
            },
        ),
    ],
)
def test_fresh_plan_rejects_any_additional_cognitive_services_account(extra_change):
    errors = verify.verify_plan(
        plan(*canonical_fresh_changes(), extra_change),
        "fresh",
    )

    assert any(extra_change["address"] in error for error in errors), errors


def test_fresh_plan_does_not_classify_child_project_as_an_account():
    child_project = next(
        item
        for item in canonical_fresh_changes()
        if item["address"] == CANONICAL_PROJECT
    )

    assert verify.verify_plan(plan(*canonical_fresh_changes()), "fresh") == []
    assert child_project["change"]["after"]["type"].startswith(
        "Microsoft.CognitiveServices/accounts/projects@"
    )


def test_fresh_plan_rejects_previous_address_bypass_for_account():
    previous_address = "module.rogue.azapi_resource.extra_account"
    changes = canonical_fresh_changes()
    account_change = next(
        item for item in changes if item["address"] == CANONICAL_ACCOUNT
    )
    account_change["previous_address"] = previous_address

    errors = verify.verify_plan(plan(*changes), "fresh")

    assert any(previous_address in error for error in errors), errors


@pytest.mark.parametrize("extra_name", ["rogue-model", "gpt-5.6-sol"])
def test_fresh_plan_rejects_any_additional_cognitive_deployment(extra_name):
    extra_address = 'module.rogue.azurerm_cognitive_deployment.extra["duplicate"]'
    errors = verify.verify_plan(
        plan(
            *canonical_fresh_changes(),
            change(
                extra_address,
                ["create"],
                resource_type="azurerm_cognitive_deployment",
                after={"name": extra_name},
            ),
        ),
        "fresh",
    )

    assert any(extra_address in error for error in errors), errors


def test_fresh_plan_rejects_previous_address_bypass_for_deployment():
    previous_address = "module.rogue.azurerm_cognitive_deployment.extra"
    changes = canonical_fresh_changes()
    deployment_change = next(
        item
        for item in changes
        if item["address"] == canonical_deployment_address("gpt-5.6-sol")
    )
    deployment_change["previous_address"] = previous_address

    errors = verify.verify_plan(plan(*changes), "fresh")

    assert any(previous_address in error for error in errors), errors


def test_fresh_plan_classifies_replacement_deployment_from_before_name():
    extra_address = "module.rogue.azurerm_cognitive_deployment.replacement"
    errors = verify.verify_plan(
        plan(
            *canonical_fresh_changes(),
            change(
                extra_address,
                ["delete", "create"],
                resource_type="azurerm_cognitive_deployment",
                before={"name": "rogue-model"},
                after=None,
            ),
        ),
        "fresh",
    )

    assert any(extra_address in error for error in errors), errors


def test_migration_plan_rejects_fallback_deletion():
    value = plan(
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["delete"]),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("protected fallback" in error for error in errors)


@pytest.mark.parametrize(
    "address",
    [
        "module.apim.azurerm_role_assignment.apim_to_model_openai",
        "module.apim.azurerm_role_assignment.apim_to_model_foundry",
    ],
)
def test_migration_plan_rejects_canonical_rbac_deletion(address):
    errors = verify.verify_plan(plan(change(address, ["delete"])), "migration")
    assert any(address in error for error in errors), errors


def test_migration_plan_checks_previous_address_for_moved_fallback():
    legacy_address = "module.apim.azurerm_role_assignment.apim_to_foundry"
    value = plan(
        change(
            "module.apim.azurerm_role_assignment.future_name",
            ["delete", "create"],
            previous_address=legacy_address,
        ),
    )
    errors = verify.verify_plan(value, "migration")
    assert any(legacy_address in error for error in errors), errors


@pytest.mark.parametrize(
    "address",
    [
        "module.foundry.azapi_resource.project_account[0]",
        "module.foundry.azapi_resource.project[0]",
        'module.foundry.azurerm_cognitive_deployment.project_models["gpt-5.6-sol"]',
        "module.foundry.azurerm_private_endpoint.project_account",
        "module.apim.azurerm_role_assignment.apim_to_model_openai",
        "module.apim.azurerm_role_assignment.apim_to_model_foundry",
        "azurerm_role_assignment.codexproxy_to_project_account[0]",
    ],
)
def test_migration_plan_rejects_delete_of_every_canonical_resource(address):
    errors = verify.verify_plan(plan(change(address, ["delete"])), "migration")

    assert any(address in error for error in errors), errors


@pytest.mark.parametrize(
    "actions",
    [
        ["delete"],
        ["delete", "create"],
        ["create", "delete"],
    ],
)
def test_migration_plan_treats_any_action_containing_delete_as_delete_like(actions):
    errors = verify.verify_plan(
        plan(change(CANONICAL_PROJECT, actions)),
        "migration",
    )

    assert any(CANONICAL_PROJECT in error for error in errors), errors


def test_migration_plan_rejects_previous_address_bypass_for_canonical_deployment():
    canonical_address = canonical_deployment_address("FW-GLM-5.2")
    errors = verify.verify_plan(
        plan(
            change(
                "module.foundry.azurerm_cognitive_deployment.renamed",
                ["create", "delete"],
                previous_address=canonical_address,
                resource_type="azurerm_cognitive_deployment",
                before={"name": "FW-GLM-5.2"},
                after={"name": "FW-GLM-5.2"},
            )
        ),
        "migration",
    )

    assert any(canonical_address in error for error in errors), errors


@pytest.mark.parametrize(
    "kimi_change",
    [
        change("module.kimi.azurerm_cognitive_account.model", ["delete"]),
        change(
            "module.safe.azurerm_cognitive_account.model",
            ["delete"],
            previous_address="module.KIMI.azurerm_cognitive_account.model",
        ),
        change(
            "module.safe.azurerm_private_endpoint.model",
            ["delete"],
            before={"private_dns": {"zones": ["privatelink.KiMi.example"]}},
        ),
        change(
            "module.safe.azurerm_role_assignment.model",
            ["create", "delete"],
            after={"metadata": [{"resource_id": "/accounts/kimi-production"}]},
        ),
    ],
)
def test_migration_plan_rejects_delete_like_kimi_changes(kimi_change):
    errors = verify.verify_plan(plan(kimi_change), "migration")

    assert any("kimi" in error.lower() for error in errors), errors


def test_migration_plan_allows_forget_without_destroy():
    value = plan(
        change("module.openai[0].azurerm_cognitive_account.openai[0]", ["forget"]),
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["forget"]),
        change(CANONICAL_ACCOUNT, ["forget"]),
    )
    assert verify.verify_plan(value, "migration") == []


def test_migration_plan_allows_safe_canonical_updates():
    value = plan(
        change(
            CANONICAL_ACCOUNT,
            ["update"],
            resource_type="azapi_resource",
            before={
                "type": "Microsoft.CognitiveServices/accounts@2025-04-01-preview",
                "body": {"properties": {"publicNetworkAccess": "Enabled"}},
            },
            after={
                "type": "Microsoft.CognitiveServices/accounts@2025-04-01-preview",
                "body": {"properties": {"publicNetworkAccess": "Disabled"}},
            },
        ),
        change(
            canonical_deployment_address("gpt-5.6-sol"),
            ["update"],
            resource_type="azurerm_cognitive_deployment",
            before={"name": "gpt-5.6-sol", "sku": [{"capacity": 400}]},
            after={"name": "gpt-5.6-sol", "sku": [{"capacity": 500}]},
        ),
    )

    assert verify.verify_plan(value, "migration") == []


def test_migration_plan_rejects_canonical_account_replacement():
    value = plan(
        change("module.foundry.azapi_resource.project_account[0]", ["delete", "create"]),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("canonical account replacement" in error for error in errors)


def test_migration_plan_rejects_moved_canonical_account_replacement():
    value = plan(
        change(
            "module.foundry.azapi_resource.project_account_replacement[0]",
            ["delete", "create"],
            previous_address="module.foundry.azapi_resource.project_account[0]",
        ),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("canonical account replacement" in error for error in errors), errors


def test_apim_rbac_transition_forgets_both_legacy_assignments():
    source = APIM_MODULE_PATH.read_text(encoding="utf-8")
    assert re.search(r"(?m)^moved \{", source) is None
    for legacy_address in (
        "azurerm_role_assignment.apim_to_openai",
        "azurerm_role_assignment.apim_to_foundry",
    ):
        assert f"from = {legacy_address}" in source
    assert source.count("destroy = false") >= 2
