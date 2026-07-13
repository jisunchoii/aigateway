#!/usr/bin/env python3
import hmac
import json
import os
import socket
import threading
import urllib.error
import urllib.request
from typing import Any

from azure.identity import ManagedIdentityCredential
from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

PORT = int(os.environ.get("PORT", "8790"))
FOUNDRY_PROJECT_BASE = os.environ.get("FOUNDRY_PROJECT_BASE", "").rstrip("/")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")
PROXY_KEY = os.environ.get("PROXY_KEY", "")
SEARCH_MODEL = os.environ.get("SEARCH_MODEL", "gpt-5.6-sol")

QUERY_MAX_LENGTH = 2000
RESPONSES_TIMEOUT_SECONDS = 60
WEB_SEARCH_SOURCES_INCLUDE = "web_search_call.action.sources"

_cred = None
_cred_lock = threading.Lock()


def _credential() -> ManagedIdentityCredential:
    global _cred
    with _cred_lock:
        if _cred is None:
            _cred = (
                ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)
                if AZURE_CLIENT_ID
                else ManagedIdentityCredential()
            )
        return _cred


def _proxy_key_ok(auth_header: str, expected_key: str) -> bool:
    if not expected_key or not isinstance(auth_header, str):
        return False
    scheme, _, token = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        return False
    return hmac.compare_digest(token, expected_key)


class ProxyKeyMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, expected_key: str):
        super().__init__(app)
        self.expected_key = expected_key

    async def dispatch(self, request: Request, call_next):
        if not _proxy_key_ok(request.headers.get("Authorization", ""), self.expected_key):
            return JSONResponse({"error": "invalid or missing proxy key"}, status_code=401)
        return await call_next(request)


def mi_scope_for(base_url: str) -> str:
    if ".services.ai.azure.com/" in (base_url or ""):
        return "https://ai.azure.com/.default"
    return "https://cognitiveservices.azure.com/.default"


def _responses_url(base_url: str) -> str:
    if not base_url:
        raise RuntimeError("FOUNDRY_PROJECT_BASE is not configured")
    return base_url.rstrip("/") + "/responses"


def _validate_query(query: str) -> str:
    if not isinstance(query, str):
        raise ValueError("query must be a string")
    if len(query) > QUERY_MAX_LENGTH:
        raise ValueError(f"query must be {QUERY_MAX_LENGTH} characters or fewer")
    normalized = query.strip()
    if not normalized:
        raise ValueError("query must contain non-whitespace text")
    return normalized


def _build_search_body(query: str) -> dict[str, Any]:
    return {
        "model": SEARCH_MODEL,
        "input": query,
        "tools": [{"type": "web_search"}],
        "tool_choice": "required",
        "max_tool_calls": 1,
        "reasoning": {"effort": "low"},
        "include": [WEB_SEARCH_SOURCES_INCLUDE],
        "stream": False,
    }


def _extract_output_text(response_body: dict[str, Any]) -> str:
    output_text = response_body.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text

    parts: list[str] = []
    for item in response_body.get("output", []):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "message":
            for content in item.get("content", []):
                if isinstance(content, dict) and content.get("type") == "output_text":
                    text = content.get("text")
                    if isinstance(text, str):
                        parts.append(text)
    return "".join(parts).strip()


def _extract_sources(response_body: dict[str, Any]) -> list[dict[str, str]]:
    unique_sources: list[dict[str, str]] = []
    seen_urls: set[str] = set()

    for item in response_body.get("output", []):
        if not isinstance(item, dict) or item.get("type") != "web_search_call":
            continue
        action = item.get("action")
        if not isinstance(action, dict):
            continue
        for source in action.get("sources", []):
            if not isinstance(source, dict):
                continue
            url = source.get("url")
            if not isinstance(url, str) or not url or url in seen_urls:
                continue
            seen_urls.add(url)
            title = source.get("title")
            unique_sources.append(
                {
                    "title": title if isinstance(title, str) and title else url,
                    "url": url,
                }
            )

    return unique_sources


def _get_bearer_token(base_url: str) -> str:
    try:
        return _credential().get_token(mi_scope_for(base_url)).token
    except Exception as exc:
        raise RuntimeError(f"managed identity token acquisition failed: {exc}") from exc


def _read_error_body(exc: urllib.error.HTTPError) -> str:
    try:
        payload = exc.read()
    except Exception:
        payload = b""
    if isinstance(payload, bytes):
        return payload.decode("utf-8", errors="replace")
    return str(payload)


def web_search(query: str) -> dict[str, Any]:
    normalized_query = _validate_query(query)
    url = _responses_url(FOUNDRY_PROJECT_BASE)
    bearer_token = _get_bearer_token(FOUNDRY_PROJECT_BASE)
    body = _build_search_body(normalized_query)
    payload = json.dumps(body).encode("utf-8")

    request = urllib.request.Request(url, data=payload, method="POST")
    request.add_header("Authorization", f"Bearer {bearer_token}")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json")

    try:
        response = urllib.request.urlopen(request, timeout=RESPONSES_TIMEOUT_SECONDS)
        response_body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"backend request failed: HTTP {exc.code}: {_read_error_body(exc)}"
        ) from exc
    except (TimeoutError, socket.timeout) as exc:
        raise RuntimeError(
            f"backend request timed out after {RESPONSES_TIMEOUT_SECONDS} seconds"
        ) from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"backend request failed: {exc.reason}") from exc

    return {
        "answer": _extract_output_text(response_body),
        "sources": _extract_sources(response_body),
    }


def _build_mcp_server() -> FastMCP:
    mcp = FastMCP(
        "search-mcp",
        host="0.0.0.0",
        port=PORT,
        stateless_http=True,
        json_response=True,
    )

    @mcp.tool(
        name="web_search",
        description="Search the public web and return an answer with source URLs.",
        annotations=ToolAnnotations(
            readOnlyHint=True,
            destructiveHint=False,
            idempotentHint=True,
            openWorldHint=True,
        ),
        structured_output=True,
    )
    def web_search_tool(query: str) -> dict[str, Any]:
        return web_search(query)

    return mcp


def create_app(expected_key: str = PROXY_KEY):
    app = _build_mcp_server().streamable_http_app()
    app.add_middleware(ProxyKeyMiddleware, expected_key=expected_key)
    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT)
