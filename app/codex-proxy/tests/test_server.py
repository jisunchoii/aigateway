import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import foundry_codex_proxy as proxy


def test_make_server_binds_all_interfaces():
    server = proxy.make_server(port=0)
    try:
        assert server.server_address[0] == "0.0.0.0"
    finally:
        server.server_close()


def test_project_routes_use_ai_studio_token_scope():
    assert (
        proxy.mi_scope_for("https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1")
        == "https://ai.azure.com/.default"
    )


def _enable_project_route(monkeypatch):
    monkeypatch.setattr(
        proxy,
        "FOUNDRY_PROJECT_BASE",
        "https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1",
    )


def test_gpt_56_preserves_reasoning(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "gpt-5.6-sol",
        "reasoning": {"effort": "high", "summary": "auto"},
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "passthrough"
    assert body["reasoning"] == {"effort": "high", "summary": "auto"}


def test_gpt_56_preserves_reasoning_history_items(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "gpt-5.6-sol",
        "input": [
            {"type": "message", "id": "msg_1", "role": "assistant", "content": []},
            {"type": "reasoning", "id": "rs_1", "summary": []},
        ],
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "passthrough"
    assert body["input"] == [
        {"type": "message", "id": "msg_1", "role": "assistant", "content": []},
        {"type": "reasoning", "id": "rs_1", "summary": []},
    ]


def test_glm_injects_required_reasoning(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {"model": "FW-GLM-5.2"}

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "required"
    assert body["reasoning"] == {"effort": "medium"}


@pytest.mark.parametrize(
    ("model", "reasoning_mode"),
    [
        ("gpt-5.6-sol", "passthrough"),
        ("FW-GLM-5.2", "required"),
        ("DeepSeek-V4-Pro", "unsupported"),
        ("grok-4.3", "unsupported"),
    ],
)
def test_final_catalog_preserves_selected_model(monkeypatch, model, reasoning_mode):
    _enable_project_route(monkeypatch)
    body = {"model": model}

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == reasoning_mode
    assert body["model"] == model


def test_deepseek_strips_reasoning_effort(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "DeepSeek-V4-Pro",
        "reasoning": {"effort": "high", "summary": "auto"},
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "unsupported"
    assert body["reasoning"] == {"summary": "auto"}


def test_web_search_passes_and_injects_sources_include(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {"model": "FW-GLM-5.2", "tools": [{"type": "web_search"}]}

    proxy.normalize_request(body)

    # web_search runs on GLM; keep it and inject the include so Codex sees results
    # (otherwise web_search_call.action.sources is empty -> infinite re-search).
    assert body["tools"] == [{"type": "web_search"}]
    assert body["include"] == ["web_search_call.action.sources"]


def test_unsupported_hosted_tool_stripped_but_request_survives(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "grok-4.3",  # code_interpreter is a repeatable 500 on grok
        "tools": [
            {"type": "code_interpreter", "container": {"type": "auto"}},
            {"type": "web_search"},
            {"type": "function", "name": "shell_command", "parameters": {"type": "object"}},
        ],
    }

    proxy.normalize_request(body)

    assert [t["type"] for t in body["tools"]] == ["web_search", "function"]


def test_computer_use_stripped_for_all_sidecar_models(monkeypatch):
    _enable_project_route(monkeypatch)
    for model in ("FW-GLM-5.2", "DeepSeek-V4-Pro", "grok-4.3"):
        body = {"model": model, "tools": [{"type": "computer_use_preview", "environment": "browser"}]}
        proxy.normalize_request(body)
        assert body["tools"] == [], model


def test_unknown_tool_type_stripped(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {"model": "FW-GLM-5.2", "tools": [{"type": "totally_made_up_tool_v9"}]}

    proxy.normalize_request(body)

    assert body["tools"] == []


def test_unknown_model_strips_all_hosted_tools_keeps_functions(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "Some-New-Model",
        "tools": [
            {"type": "web_search"},
            {"type": "function", "name": "shell_command", "parameters": {"type": "object"}},
        ],
    }

    proxy.normalize_request(body)

    assert [t["type"] for t in body["tools"]] == ["function"]
    assert "include" not in body  # no web_search survived -> no sources include
