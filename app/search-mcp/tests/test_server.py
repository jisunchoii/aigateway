import asyncio
import json
import socket
import sys
import urllib.error
from pathlib import Path

import pytest
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import search_mcp_server as server


def test_build_search_body_uses_single_required_web_search():
    body = server._build_search_body("query")

    assert body == {
        "model": "gpt-5.6-sol",
        "input": "query",
        "tools": [{"type": "web_search"}],
        "tool_choice": "required",
        "max_tool_calls": 1,
        "reasoning": {"effort": "low"},
        "include": ["web_search_call.action.sources"],
        "stream": False,
    }


def test_validate_query_requires_non_blank_text_and_2000_char_limit():
    with pytest.raises(ValueError, match="query must contain non-whitespace text"):
        server._validate_query("   ")

    with pytest.raises(ValueError, match="query must be 2000 characters or fewer"):
        server._validate_query("x" * 2001)

    assert server._validate_query("  latest foundry news  ") == "latest foundry news"


def test_validate_query_rejects_raw_overlong_whitespace_padded_input():
    with pytest.raises(ValueError, match="query must be 2000 characters or fewer"):
        server._validate_query((" " * 2001) + "x")


def test_web_search_calls_foundry_once_and_returns_unique_sources(monkeypatch):
    monkeypatch.setattr(
        server,
        "FOUNDRY_PROJECT_BASE",
        "https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1",
    )
    monkeypatch.setattr(server, "SEARCH_MODEL", "gpt-5.6-sol")

    scope_calls = []

    class FakeToken:
        token = "mi-token"

    class FakeCredential:
        def get_token(self, scope):
            scope_calls.append(scope)
            return FakeToken()

    monkeypatch.setattr(server, "_credential", lambda: FakeCredential())

    payloads = []

    class FakeResponse:
        status = 200

        def read(self):
            return json.dumps(
                {
                    "output": [
                        {
                            "type": "web_search_call",
                            "action": {
                                "sources": [
                                    {"title": "Alpha", "url": "https://example.com/a"},
                                    {"title": "Duplicate", "url": "https://example.com/a"},
                                    {"title": "Beta", "url": "https://example.com/b"},
                                ]
                            },
                        },
                        {
                            "type": "message",
                            "content": [
                                {"type": "output_text", "text": "Answer"},
                                {"type": "output_text", "text": " text"},
                            ],
                        },
                    ]
                }
            ).encode("utf-8")

    def fake_urlopen(request, timeout):
        payloads.append(
            {
                "url": request.full_url,
                "authorization": request.get_header("Authorization"),
                "content_type": request.get_header("Content-type"),
                "accept": request.get_header("Accept"),
                "timeout": timeout,
                "body": json.loads(request.data.decode("utf-8")),
            }
        )
        return FakeResponse()

    monkeypatch.setattr(server.urllib.request, "urlopen", fake_urlopen)

    result = server.web_search("what changed?")

    assert result == {
        "answer": "Answer text",
        "sources": [
            {"title": "Alpha", "url": "https://example.com/a"},
            {"title": "Beta", "url": "https://example.com/b"},
        ],
    }
    assert scope_calls == ["https://ai.azure.com/.default"]
    assert payloads == [
        {
            "url": "https://aisproj-c0gvf2.services.ai.azure.com/api/projects/codexproj/openai/v1/responses",
            "authorization": "Bearer mi-token",
            "content_type": "application/json",
            "accept": "application/json",
            "timeout": 60,
            "body": server._build_search_body("what changed?"),
        }
    ]


def test_web_search_turns_backend_failures_into_tool_errors(monkeypatch):
    monkeypatch.setattr(server, "FOUNDRY_PROJECT_BASE", "https://example.test/openai/v1")
    monkeypatch.setattr(server, "_credential", lambda: type("Cred", (), {"get_token": lambda self, scope: type("Tok", (), {"token": "mi-token"})()})())

    error = urllib.error.HTTPError(
        url="https://example.test/openai/v1/responses",
        code=502,
        msg="Bad Gateway",
        hdrs=None,
        fp=None,
    )
    error.read = lambda: b'{"error":"upstream exploded"}'
    monkeypatch.setattr(server.urllib.request, "urlopen", lambda request, timeout: (_ for _ in ()).throw(error))

    with pytest.raises(RuntimeError, match='backend request failed: HTTP 502: \\{"error":"upstream exploded"\\}'):
        server.web_search("what changed?")


def test_web_search_turns_timeouts_into_tool_errors(monkeypatch):
    monkeypatch.setattr(server, "FOUNDRY_PROJECT_BASE", "https://example.test/openai/v1")
    monkeypatch.setattr(server, "_credential", lambda: type("Cred", (), {"get_token": lambda self, scope: type("Tok", (), {"token": "mi-token"})()})())
    monkeypatch.setattr(
        server.urllib.request,
        "urlopen",
        lambda request, timeout: (_ for _ in ()).throw(socket.timeout("timed out")),
    )

    with pytest.raises(RuntimeError, match="backend request timed out after 60 seconds"):
        server.web_search("what changed?")


def test_web_search_turns_url_errors_into_tool_errors(monkeypatch):
    monkeypatch.setattr(server, "FOUNDRY_PROJECT_BASE", "https://example.test/openai/v1")
    monkeypatch.setattr(server, "_credential", lambda: type("Cred", (), {"get_token": lambda self, scope: type("Tok", (), {"token": "mi-token"})()})())
    monkeypatch.setattr(
        server.urllib.request,
        "urlopen",
        lambda request, timeout: (_ for _ in ()).throw(urllib.error.URLError("name resolution failed")),
    )

    with pytest.raises(RuntimeError, match="backend request failed: name resolution failed"):
        server.web_search("what changed?")


def test_proxy_key_ok_uses_constant_time_compare(monkeypatch):
    compare_calls = []

    def fake_compare_digest(left, right):
        compare_calls.append((left, right))
        return left == right

    monkeypatch.setattr(server.hmac, "compare_digest", fake_compare_digest)

    assert server._proxy_key_ok("Bearer hop-secret", "hop-secret") is True
    assert server._proxy_key_ok("Bearer wrong-secret", "hop-secret") is False
    assert server._proxy_key_ok("Basic hop-secret", "hop-secret") is False
    assert compare_calls == [
        ("hop-secret", "hop-secret"),
        ("wrong-secret", "hop-secret"),
    ]


async def _ok_endpoint(request):
    return JSONResponse({"ok": True})


async def _invoke_asgi(app, headers=None):
    response = {"status": None, "headers": {}, "body": b""}
    request_headers = [
        (name.lower().encode("latin-1"), value.encode("latin-1"))
        for name, value in (headers or {}).items()
    ]

    scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/mcp",
        "raw_path": b"/mcp",
        "query_string": b"",
        "root_path": "",
        "headers": request_headers,
        "client": ("testclient", 123),
        "server": ("testserver", 80),
        "state": {},
    }

    body_sent = False

    async def receive():
        nonlocal body_sent
        if body_sent:
            return {"type": "http.disconnect"}
        body_sent = True
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        if message["type"] == "http.response.start":
            response["status"] = message["status"]
            response["headers"] = {
                key.decode("latin-1"): value.decode("latin-1")
                for key, value in message.get("headers", [])
            }
        elif message["type"] == "http.response.body":
            response["body"] += message.get("body", b"")

    await app(scope, receive, send)
    return response


def test_proxy_key_middleware_rejects_bad_tokens_and_allows_matching_bearer():
    app = Starlette(routes=[Route("/mcp", _ok_endpoint, methods=["POST"])])
    app.add_middleware(server.ProxyKeyMiddleware, expected_key="hop-secret")
    missing = asyncio.run(_invoke_asgi(app))
    wrong_scheme = asyncio.run(_invoke_asgi(app, headers={"Authorization": "Basic hop-secret"}))
    allowed = asyncio.run(_invoke_asgi(app, headers={"Authorization": "Bearer hop-secret"}))

    assert missing["status"] == 401
    assert wrong_scheme["status"] == 401
    assert allowed["status"] == 200
    assert json.loads(allowed["body"]) == {"ok": True}


def test_create_app_exposes_mcp_route_with_proxy_key_middleware():
    app = server.create_app(expected_key="hop-secret")

    assert any(route.path == "/mcp" for route in app.routes)
    assert any(middleware.cls is server.ProxyKeyMiddleware for middleware in app.user_middleware)


def test_mcp_server_exposes_web_search_tool():
    tools = asyncio.run(server._build_mcp_server().list_tools())

    assert [tool.name for tool in tools] == ["web_search"]
    assert tools[0].annotations is not None
    assert tools[0].annotations.readOnlyHint is True


def test_mcp_web_search_tool_has_non_empty_description():
    tools = asyncio.run(server._build_mcp_server().list_tools())

    assert tools[0].description.strip()
