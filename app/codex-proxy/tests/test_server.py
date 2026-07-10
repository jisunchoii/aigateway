import sys
from pathlib import Path

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


def test_glm_injects_required_reasoning(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {"model": "FW-GLM-5.2"}

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "required"
    assert body["reasoning"] == {"effort": "medium"}


def test_deepseek_strips_reasoning_effort(monkeypatch):
    _enable_project_route(monkeypatch)
    body = {
        "model": "DeepSeek-V4-Pro",
        "reasoning": {"effort": "high", "summary": "auto"},
    }

    route, _ = proxy.normalize_request(body)

    assert route["reasoning_mode"] == "unsupported"
    assert body["reasoning"] == {"summary": "auto"}
