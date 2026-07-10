import importlib.util
import re
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).parents[1] / "verify_model_topology_plan.py"
APIM_MODULE_PATH = Path(__file__).parents[2] / "infra" / "modules" / "apim" / "main.tf"
SPEC = importlib.util.spec_from_file_location("verify_model_topology_plan", MODULE_PATH)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


def plan(*changes):
    return {"resource_changes": list(changes)}


def change(address, actions, previous_address=None):
    value = {"address": address, "change": {"actions": actions}}
    if previous_address is not None:
        value["previous_address"] = previous_address
    return value


def test_fresh_plan_accepts_only_canonical_models():
    value = plan(
        change("module.foundry.azapi_resource.project_account[0]", ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["gpt-5.6-sol"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["FW-GLM-5.2"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["DeepSeek-V4-Pro"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["grok-4.3"]', ["create"]),
    )
    assert verify.verify_plan(value, "fresh") == []


def test_fresh_plan_rejects_split_openai_module():
    value = plan(
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
        change("module.foundry.azapi_resource.project_account[0]", ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["gpt-5.6-sol"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["FW-GLM-5.2"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["DeepSeek-V4-Pro"]', ["create"]),
        change('module.foundry.azurerm_cognitive_deployment.project_models["grok-4.3"]', ["create"]),
        change(address, ["create"]),
    )
    errors = verify.verify_plan(value, "fresh")
    assert any(address in error for error in errors), errors


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


def test_migration_plan_allows_forget_without_destroy():
    value = plan(
        change("module.openai[0].azurerm_cognitive_account.openai[0]", ["forget"]),
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["forget"]),
        change("module.foundry.azapi_resource.project_account[0]", ["update"]),
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
