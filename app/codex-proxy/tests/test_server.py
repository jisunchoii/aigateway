import json
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


@pytest.mark.parametrize("model", ["FW-GLM-5.2", "DeepSeek-V4-Pro", "grok-4.3"])
def test_oss_models_strip_all_hosted_tools(monkeypatch, model):
    _enable_project_route(monkeypatch)
    body = {
        "model": model,
        "tools": [
            {"type": "web_search"},
            {"type": "code_interpreter", "container": {"type": "auto"}},
            {"type": "file_search", "vector_store_ids": ["vs_x"]},
            {"type": "image_generation"},
            {"type": "mcp", "server_label": "search", "server_url": "https://example.com/mcp"},
            {"type": "function", "name": "keep_me", "parameters": {"type": "object"}},
        ],
    }

    proxy.normalize_request(body)

    assert body["tools"] == [
        {"type": "function", "name": "keep_me", "parameters": {"type": "object"}}
    ]
    assert "include" not in body


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

    assert [t["type"] for t in body["tools"]] == ["function"]


def test_gpt_native_hosted_tools_are_preserved(monkeypatch):
    _enable_project_route(monkeypatch)
    hosted_tools = [
        {"type": "web_search"},
        {"type": "web_search_2025_08_26"},
        {"type": "web_search_preview"},
        {"type": "web_search_preview_2025_03_11"},
        {"type": "code_interpreter", "container": {"type": "auto"}},
        {"type": "file_search", "vector_store_ids": ["vs_x"]},
        {"type": "image_generation"},
        {"type": "mcp", "server_label": "search", "server_url": "https://example.com/mcp"},
        {"type": "computer"},
        {"type": "computer_use_preview", "environment": "browser"},
        {"type": "tool_search"},
        {"type": "shell"},
        {"type": "programmatic_tool_calling"},
    ]
    body = {"model": "gpt-5.6-sol", "tools": hosted_tools}

    proxy.normalize_request(body)

    assert body["tools"] == hosted_tools
    assert body["include"] == ["web_search_call.action.sources"]


def test_mcp_namespace_is_flattened_and_restored(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "FW-GLM-5.2",
        "tools": [
            {
                "type": "namespace",
                "name": "mcp__web_search__",
                "tools": [
                    {
                        "type": "function",
                        "name": "search",
                        "parameters": {"type": "object"},
                    }
                ],
            }
        ],
    }

    _, ns_map = proxy.normalize_request(body)

    assert body["tools"] == [
        {"type": "function", "name": "search", "parameters": {"type": "object"}}
    ]
    assert ns_map == {"search": "mcp__web_search__"}

    event = (
        b"event: response.output_item.done\n"
        b'data: {"type":"response.output_item.done","item":{"type":"function_call",'
        b'"name":"search","call_id":"call_1","arguments":"{}"}}'
    )
    restored, count = proxy._restore_ns_in_event(event, ns_map)

    assert count == 1
    data_line = next(line for line in restored.split(b"\n") if line.startswith(b"data:"))
    assert json.loads(data_line[5:])["item"]["namespace"] == "mcp__web_search__"


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
