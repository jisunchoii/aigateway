import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "verify_model_topology_plan.py"
SPEC = importlib.util.spec_from_file_location("verify_model_topology_plan", MODULE_PATH)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


def plan(*changes):
    return {"resource_changes": list(changes)}


def change(address, actions):
    return {"address": address, "change": {"actions": actions}}


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


def test_migration_plan_rejects_fallback_deletion():
    value = plan(
        change("module.foundry.azurerm_cognitive_account.foundry[0]", ["delete"]),
    )
    errors = verify.verify_plan(value, "migration")
    assert any("protected fallback" in error for error in errors)


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
