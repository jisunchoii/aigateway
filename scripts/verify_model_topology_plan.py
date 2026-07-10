#!/usr/bin/env python3
import json
import sys
from pathlib import Path


CANONICAL_ACCOUNT = "module.foundry.azapi_resource.project_account[0]"
CANONICAL_PROJECT = "module.foundry.azapi_resource.project[0]"
CANONICAL_PRIVATE_ENDPOINT = "module.foundry.azurerm_private_endpoint.project_account"
CANONICAL_APIM_OPENAI_ROLE = (
    "module.apim.azurerm_role_assignment.apim_to_model_openai"
)
CANONICAL_APIM_FOUNDRY_ROLE = (
    "module.apim.azurerm_role_assignment.apim_to_model_foundry"
)
CANONICAL_PROXY_ROLE = "azurerm_role_assignment.codexproxy_to_project_account[0]"
EXPECTED_MODELS = {
    "gpt-5.6-sol",
    "FW-GLM-5.2",
    "DeepSeek-V4-Pro",
    "grok-4.3",
}
MODEL_PREFIX = "module.foundry.azurerm_cognitive_deployment.project_models["
CANONICAL_REQUIRED_CREATES = (
    CANONICAL_ACCOUNT,
    CANONICAL_PROJECT,
    CANONICAL_PRIVATE_ENDPOINT,
    CANONICAL_APIM_OPENAI_ROLE,
    CANONICAL_APIM_FOUNDRY_ROLE,
)
CANONICAL_EXACT_MIGRATION_ADDRESSES = {
    CANONICAL_ACCOUNT,
    CANONICAL_PROJECT,
    CANONICAL_PRIVATE_ENDPOINT,
    CANONICAL_APIM_OPENAI_ROLE,
    CANONICAL_APIM_FOUNDRY_ROLE,
    CANONICAL_PROXY_ROLE,
}
LEGACY_FALLBACK_PREFIXES = (
    "module.openai",
    "module.foundry.azurerm_cognitive_account.foundry",
    "module.foundry.azurerm_cognitive_deployment.models",
    "module.foundry.azurerm_private_endpoint.foundry",
    "module.apim.azurerm_role_assignment.apim_to_openai",
    "module.apim.azurerm_role_assignment.apim_to_foundry",
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


def _delete_like(change):
    return "delete" in _actions(change)


def _created(change):
    return "create" in _actions(change)


def _normalized_azure_type(value):
    if not isinstance(value, str):
        return ""
    return value.split("@", 1)[0].rstrip("/").lower()


def _before_after_values(change, key):
    values = []
    details = change.get("change") or {}
    for phase in ("after", "before"):
        phase_value = details.get(phase)
        if isinstance(phase_value, dict):
            value = phase_value.get(key)
            if isinstance(value, str):
                values.append(value)
    return values


def _is_cognitive_account(change):
    resource_type = change.get("type")
    if resource_type == "azurerm_cognitive_account":
        return True
    if resource_type != "azapi_resource":
        return False
    return any(
        _normalized_azure_type(value) == "microsoft.cognitiveservices/accounts"
        for value in _before_after_values(change, "type")
    )


def _is_cognitive_project(change):
    if change.get("type") != "azapi_resource":
        return False
    return any(
        _normalized_azure_type(value)
        == "microsoft.cognitiveservices/accounts/projects"
        for value in _before_after_values(change, "type")
    )


def _is_cognitive_deployment(change):
    return change.get("type") == "azurerm_cognitive_deployment"


def _deployment_name(change):
    names = _before_after_values(change, "name")
    return names[0] if names else None


def canonical_deployment_address(model):
    return f'{MODEL_PREFIX}"{model}"]'


def _nested_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, nested_value in value.items():
            yield from _nested_strings(key)
            yield from _nested_strings(nested_value)
    elif isinstance(value, (list, tuple)):
        for nested_value in value:
            yield from _nested_strings(nested_value)


def _mentions_kimi(change):
    values = list(_addresses(change))
    details = change.get("change") or {}
    values.extend(_nested_strings(details.get("before")))
    values.extend(_nested_strings(details.get("after")))
    return any("kimi" in value.lower() for value in values)


def _fresh_required_change(changes, address):
    matches = [
        change
        for change in changes
        if change.get("address") == address and _created(change)
    ]
    if len(matches) != 1:
        return False
    change = matches[0]
    if address == CANONICAL_ACCOUNT:
        return _is_cognitive_account(change)
    if address == CANONICAL_PROJECT:
        return _is_cognitive_project(change)
    if address == CANONICAL_PRIVATE_ENDPOINT:
        return change.get("type") == "azurerm_private_endpoint"
    return change.get("type") == "azurerm_role_assignment"


def verify_plan(plan, mode):
    errors = []
    changes = _changes(plan)
    if mode == "fresh":
        for change in changes:
            address = change.get("address", "")
            addresses = _addresses(change)
            fallback_addresses = [
                candidate
                for candidate in addresses
                if candidate.startswith(LEGACY_FALLBACK_PREFIXES)
            ]
            if _created(change) and fallback_addresses:
                errors.append(
                    "fresh plan contains protected fallback create: "
                    + ", ".join(fallback_addresses)
                )

            noncanonical_account_addresses = [
                candidate
                for candidate in addresses
                if candidate != CANONICAL_ACCOUNT
            ]
            if _created(change) and _is_cognitive_account(
                change
            ) and noncanonical_account_addresses:
                errors.append(
                    "fresh plan creates additional Cognitive Services account: "
                    + ", ".join(noncanonical_account_addresses)
                )

        for address in CANONICAL_REQUIRED_CREATES:
            if not _fresh_required_change(changes, address):
                errors.append(
                    "fresh plan does not create required canonical resource: "
                    f"{address}"
                )

        deployment_creates = [
            change
            for change in changes
            if _created(change) and _is_cognitive_deployment(change)
        ]
        valid_deployments = set()
        for change in deployment_creates:
            address = change.get("address", "")
            addresses = _addresses(change)
            name = _deployment_name(change)
            expected_address = (
                canonical_deployment_address(name)
                if name in EXPECTED_MODELS
                else None
            )
            if (
                expected_address is not None
                and address == expected_address
                and all(candidate == expected_address for candidate in addresses)
            ):
                valid_deployments.add(name)
            else:
                errors.append(
                    "fresh plan creates additional or noncanonical cognitive "
                    f"deployment: {', '.join(addresses)} name={name!r}"
                )

        if valid_deployments != EXPECTED_MODELS or len(deployment_creates) != len(
            EXPECTED_MODELS
        ):
            errors.append(
                "fresh plan model set mismatch: "
                f"expected={sorted(EXPECTED_MODELS)} "
                f"actual={sorted(valid_deployments)}"
            )
    elif mode == "migration":
        for change in changes:
            if not _delete_like(change):
                continue

            addresses = _addresses(change)
            fallback_addresses = [
                candidate
                for candidate in addresses
                if candidate.startswith(LEGACY_FALLBACK_PREFIXES)
            ]
            if fallback_addresses:
                errors.append(
                    "protected fallback would be destroyed by delete-like action: "
                    + ", ".join(fallback_addresses)
                )

            canonical_addresses = [
                candidate
                for candidate in addresses
                if candidate in CANONICAL_EXACT_MIGRATION_ADDRESSES
                or candidate.startswith(MODEL_PREFIX)
            ]
            deployment_name = (
                _deployment_name(change)
                if _is_cognitive_deployment(change)
                else None
            )
            if deployment_name in EXPECTED_MODELS and not canonical_addresses:
                canonical_addresses.append(
                    f"cognitive deployment named {deployment_name!r}"
                )

            if CANONICAL_ACCOUNT in canonical_addresses:
                errors.append(
                    "canonical account replacement or deletion is forbidden: "
                    f"{CANONICAL_ACCOUNT}"
                )
                canonical_addresses.remove(CANONICAL_ACCOUNT)
            if canonical_addresses:
                errors.append(
                    "canonical resource delete/replacement is forbidden: "
                    + ", ".join(canonical_addresses)
                )

            if _mentions_kimi(change):
                errors.append(
                    "Kimi-related delete/replacement is forbidden: "
                    + ", ".join(addresses)
                )
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
