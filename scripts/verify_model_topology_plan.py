#!/usr/bin/env python3
import json
import sys
from pathlib import Path


CANONICAL_ACCOUNT = "module.foundry.azapi_resource.project_account[0]"
EXPECTED_MODELS = {
    "gpt-5.6-sol",
    "FW-GLM-5.2",
    "DeepSeek-V4-Pro",
    "grok-4.3",
}
MODEL_PREFIX = "module.foundry.azurerm_cognitive_deployment.project_models["
LEGACY_FALLBACK_PREFIXES = (
    "module.openai",
    "module.foundry.azurerm_cognitive_account.foundry",
    "module.foundry.azurerm_cognitive_deployment.models",
    "module.foundry.azurerm_private_endpoint.foundry",
    "module.apim.azurerm_role_assignment.apim_to_openai",
    "module.apim.azurerm_role_assignment.apim_to_foundry",
)
PROTECTED_MIGRATION_PREFIXES = LEGACY_FALLBACK_PREFIXES + (
    "module.apim.azurerm_role_assignment.apim_to_model_openai",
    "module.apim.azurerm_role_assignment.apim_to_model_foundry",
)


def _changes(plan):
    return plan.get("resource_changes") or []


def _actions(change):
    return change.get("change", {}).get("actions") or []


def _addresses(change):
    return [
        address
        for address in (change.get("previous_address"), change.get("address"))
        if address
    ]


def _model_name(address):
    if not address.startswith(MODEL_PREFIX):
        return None
    return address.split('["', 1)[1].rsplit('"]', 1)[0]


def verify_plan(plan, mode):
    errors = []
    changes = _changes(plan)
    if mode == "fresh":
        for change in changes:
            address = change.get("address", "")
            if "create" in _actions(change) and address.startswith(LEGACY_FALLBACK_PREFIXES):
                errors.append(f"fresh plan contains protected fallback create: {address}")
        models = {
            name
            for change in changes
            if (name := _model_name(change.get("address", ""))) is not None
            and "create" in _actions(change)
        }
        if models != EXPECTED_MODELS:
            errors.append(
                "fresh plan model set mismatch: "
                f"expected={sorted(EXPECTED_MODELS)} actual={sorted(models)}"
            )
        if not any(
            change.get("address") == CANONICAL_ACCOUNT and "create" in _actions(change)
            for change in changes
        ):
            errors.append("fresh plan does not create the canonical project-enabled account")
    elif mode == "migration":
        for change in changes:
            address = change.get("address", "")
            actions = _actions(change)
            protected_addresses = [
                candidate
                for candidate in _addresses(change)
                if candidate.startswith(PROTECTED_MIGRATION_PREFIXES)
            ]
            if "delete" in actions and protected_addresses:
                errors.append(
                    "protected fallback or adopted RBAC would be destroyed: "
                    + ", ".join(protected_addresses)
                )
            if address == CANONICAL_ACCOUNT and "delete" in actions:
                errors.append("canonical account replacement is forbidden")
    else:
        errors.append(f"unsupported mode: {mode}")
    return errors


def main(argv):
    if len(argv) != 3:
        print("usage: verify_model_topology_plan.py PLAN_JSON_PATH {fresh|migration}", file=sys.stderr)
        return 2
    plan = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
    errors = verify_plan(plan, argv[2])
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("model topology plan OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
