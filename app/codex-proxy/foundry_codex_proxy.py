#!/usr/bin/env python3
"""Local proxy: Codex CLI (Responses API) -> Azure AI Foundry native Responses.

Codex sends gpt-only tool shapes and payload fields that Foundry's OpenAI-compat
layer rejects. This proxy CONVERTS them into the equivalent the backend accepts so
Codex keeps full agent capability (shell + file edit + tools); it only REMOVES pure
gpt-only metadata that carries no capability (reasoning.encrypted_content).

Phase-1 verification artifact: stdlib only, no session store, no governance.
Run:      python foundry_codex_proxy.py           (serves 127.0.0.1:8789)
Selftest: python foundry_codex_proxy.py --selftest (no network)
"""
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8789"))
FOUNDRY_PROJECT_BASE = os.environ.get("FOUNDRY_PROJECT_BASE", "").rstrip("/")
PROXY_KEY = os.environ.get("PROXY_KEY", "")
MI_SCOPE = os.environ.get("MI_SCOPE", "https://cognitiveservices.azure.com/.default")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")


def _key_ok(auth_header, expected):
    if not expected:
        return True  # local dev: no key configured, skip the check
    token = auth_header[7:] if auth_header.lower().startswith("bearer ") else ""
    return token == expected


def log(msg):
    sys.stderr.write("[proxy] %s\n" % msg)
    sys.stderr.flush()


# --- tool shapes the backend accepts (Codex's local_shell/custom map to these) ---

def _shell_function_tool():
    return {
        "type": "function",
        "name": "shell",
        "description": "Run a shell command. Provide argv as a JSON array of strings.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {"type": "array", "items": {"type": "string"}},
                "workdir": {"type": "string"},
                "timeout_ms": {"type": "number"},
            },
            "required": ["command"],
            "additionalProperties": False,
        },
    }


def _apply_patch_function_tool():
    return {
        "type": "function",
        "name": "apply_patch",
        "description": (
            "Edit files. Pass the full apply_patch envelope as a string that starts "
            "with '*** Begin Patch' and ends with '*** End Patch'."
        ),
        "parameters": {
            "type": "object",
            "properties": {"input": {"type": "string"}},
            "required": ["input"],
            "additionalProperties": False,
        },
    }


# --- request normalization (Codex -> backend) ---

def _normalize_tools(tools):
    """Return (normalized_tools, name->namespace map for flattened namespace tools)."""
    if not isinstance(tools, list):
        return tools, {}
    out = []
    ns_map = {}
    for t in tools:
        ttype = t.get("type") if isinstance(t, dict) else None
        if ttype == "local_shell":
            out.append(_shell_function_tool())      # CONVERT: keep shell capability
        elif ttype == "custom":
            out.append(_apply_patch_function_tool())  # CONVERT: keep edit capability
        elif ttype == "namespace":
            # FLATTEN: the backend throws a mid-stream server_error on namespace-type
            # tools (verified: multi_agent_v1 fails ~7/8; hoisting its nested function
            # tools to top level passes 8/8). But Codex's executor keys tools by
            # {namespace,name} (registry.rs/router.rs ToolName), and the backend returns
            # the call with NO namespace -> Codex 400s "unsupported call: spawn_agent".
            # So we remember name->namespace here and RESTORE it on the response (SSE)
            # and on echoed-back history items, so sub-agent spawning actually works.
            ns = t.get("name")
            for nt in t.get("tools", []):
                nm = nt.get("name")
                if nm and ns:
                    ns_map[nm] = ns
                out.append(nt)
        else:
            out.append(t)                            # function / web_search / ... pass through
    return out, ns_map


def _normalize_input(items):
    """Round-trip typed tool items in the history so multi-turn loops keep working."""
    if not isinstance(items, list):
        return items
    out = []
    for it in items:
        itype = it.get("type") if isinstance(it, dict) else None
        if itype in ("reasoning", "web_search_call"):
            # Backend rejects these item types echoed back in input history (verified
            # 400 "does not match expected schema"). reasoning: item type refused even
            # after stripping encrypted_content. web_search_call: refused in input; it's
            # only a marker (results already sit in the following assistant message), so
            # dropping is safe. This is the "web_search then multi-agent -> 400" cause.
            continue
        if itype == "local_shell_call":
            action = it.get("action") or {}
            args = {"command": action.get("command", [])}
            if action.get("timeout_ms") is not None:
                args["timeout_ms"] = action["timeout_ms"]
            out.append({
                "type": "function_call",
                "call_id": it.get("call_id"),
                "name": "shell",
                "arguments": json.dumps(args),
            })
        elif itype == "custom_tool_call":
            out.append({
                "type": "function_call",
                "call_id": it.get("call_id"),
                "name": it.get("name", "apply_patch"),
                "arguments": json.dumps({"input": it.get("input", "")}),
            })
        elif itype in ("local_shell_call_output", "custom_tool_call_output"):
            out.append({
                "type": "function_call_output",
                "call_id": it.get("call_id"),
                "output": it.get("output", ""),
            })
        elif itype in ("function_call", "function_call_output") and it.get("namespace"):
            # Codex echoes flattened sub-agent calls back WITH the namespace we restored;
            # the backend has no namespace concept, so strip it on the way back out.
            clean = {k: v for k, v in it.items() if k != "namespace"}
            out.append(clean)
        else:
            out.append(it)
    return out


def _normalize_reasoning(body, route):
    r = body.get("reasoning")
    if route["reasoning_effort"]:
        # GLM: reasoning must be a non-null object (null -> 400).
        if not isinstance(r, dict):
            body["reasoning"] = {"effort": "medium"}
    else:
        # DeepSeek/Kimi: reject reasoning.effort; {} or {summary} is fine.
        if isinstance(r, dict):
            r.pop("effort", None)
        elif "reasoning" in body:
            del body["reasoning"]


def _normalize_include(body):
    inc = body.get("include")
    if isinstance(inc, list):
        # REMOVE gpt o-series-only metadata (no agent capability; backend 400s on it).
        body["include"] = [x for x in inc if x != "reasoning.encrypted_content"]


def _normalize_text(body):
    t = body.get("text")
    if isinstance(t, dict) and "verbosity" in t:
        t["verbosity"] = "medium"  # REPLACE value (only one backend allows); keep text


# Single backend: the sidecar fronts one project-enabled Foundry account. The body "model"
# selects the deployment; base_url is fixed (never per-model). reasoning_effort handling is
# per-model, keyed by model name, since GLM needs an effort object and DeepSeek rejects it.
REASONING_EFFORT_MODELS = {"FW-GLM-5.2"}  # models that REQUIRE reasoning.effort; others get it stripped


def _route_for(model):
    if not FOUNDRY_PROJECT_BASE:
        return None
    return {
        "base_url": FOUNDRY_PROJECT_BASE,
        "reasoning_effort": model in REASONING_EFFORT_MODELS,
    }


def normalize_request(body):
    """Mutate body in place; return (route, ns_map) or (None, {}) for unknown model.

    ns_map maps flattened tool name -> namespace, used to restore `namespace` on the
    response stream and history so Codex's executor recognizes sub-agent calls.
    """
    route = _route_for(body.get("model"))
    if route is None:
        return None, {}
    ns_map = {}
    if "tools" in body:
        body["tools"], ns_map = _normalize_tools(body["tools"])
    if "input" in body:
        body["input"] = _normalize_input(body["input"])
    _normalize_text(body)
    _normalize_include(body)
    _normalize_reasoning(body, route)
    return route, ns_map


# --- Managed Identity token (proxy-side injection; azure-identity caches internally) ---

from azure.identity import ManagedIdentityCredential

_cred = None
_cred_lock = threading.Lock()


def _credential():
    global _cred
    with _cred_lock:
        if _cred is None:
            _cred = (ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)
                     if AZURE_CLIENT_ID else ManagedIdentityCredential())
        return _cred


def get_token(now=None, force=False):
    try:
        return _credential().get_token(MI_SCOPE).token
    except Exception as e:
        log("MI token acquisition failed: %s" % e)
        return None


def _tool_summary(body):
    ts = body.get("tools")
    if not ts:
        return "none"
    return ",".join(str(t.get("name", t.get("type"))) for t in ts if isinstance(t, dict))


def _restore_ns_in_event(event, ns_map):
    """Given one raw SSE event block, if it carries a function_call item whose name was
    flattened from a namespace tool, inject the `namespace` field so Codex matches it.
    Returns (possibly-rewritten bytes, count_restored). Only touches matching events."""
    if b"function_call" not in event or b"namespace" in event:
        return event, 0
    # SSE block is lines: "event: <type>" then "data: <json>". Find the data line.
    lines = event.split(b"\n")
    for i, line in enumerate(lines):
        if not line.startswith(b"data:"):
            continue
        raw = line[5:].strip()
        if not raw.startswith(b"{"):
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            return event, 0
        item = obj.get("item")
        if (isinstance(item, dict) and item.get("type") == "function_call"
                and item.get("name") in ns_map and not item.get("namespace")):
            item["namespace"] = ns_map[item["name"]]
            lines[i] = b"data: " + json.dumps(obj).encode()
            return b"\n".join(lines), 1
        return event, 0
    return event, 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # silence default per-request logging
        pass

    def do_POST(self):
        if not _key_ok(self.headers.get("Authorization", ""), PROXY_KEY):
            self._json(401, {"error": "invalid or missing proxy key"})
            return
        if not self.path.rstrip("/").endswith("/responses"):
            self._json(404, {"error": "only /responses is proxied"})
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except Exception:
            self._json(400, {"error": "invalid JSON body"})
            return

        model = body.get("model")
        route, ns_map = normalize_request(body)
        if route is None:
            self._json(400, {"error": "unknown model '%s'" % model})
            return

        tok = get_token()
        if not tok:
            self._json(502, {"error": "backend auth unavailable (MI token failed)"})
            return

        url = route["base_url"].rstrip("/") + "/responses"
        payload = json.dumps(body).encode()
        log("-> %s model=%s tools=%s" % (url, model, _tool_summary(body)))

        def send(bearer):
            r = urllib.request.Request(url, data=payload, method="POST")
            r.add_header("Authorization", "Bearer " + bearer)
            r.add_header("Content-Type", "application/json")
            r.add_header("Accept", "text/event-stream")
            return urllib.request.urlopen(r, timeout=600)

        try:
            resp = send(tok)
        except urllib.error.HTTPError as e:
            err = e.read()
            log("<- %d BACKEND REJECT: %s" % (e.code, err[:600]))
            self._raw(e.code, e.headers.get_content_type() or "application/json", err)
            return
        except Exception as e:
            self._json(502, {"error": "upstream failed: %s" % e})
            return

        self.send_response(resp.status)
        self.send_header("Content-Type", resp.headers.get("Content-Type", "text/event-stream"))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        if ns_map:
            self._relay_sse_restoring_ns(resp, ns_map)
        else:
            self._relay_passthrough(resp)

    def _relay_passthrough(self, resp):
        """Fast byte relay when there are no namespaced tools to restore."""
        saw_failed = False
        try:
            while True:
                chunk = resp.read(1024)
                if not chunk:
                    break
                if b"response.failed" in chunk or b"event: error" in chunk:
                    saw_failed = True
                self.wfile.write(chunk)
                self.wfile.flush()
            if saw_failed:
                log("<- backend emitted response.failed/error mid-stream")
        except Exception as e:
            log("stream relay ended: %s" % e)

    def _relay_sse_restoring_ns(self, resp, ns_map):
        """Relay SSE events, restoring `namespace` on function_call items whose name was
        flattened out of a namespace tool, so Codex's executor matches {namespace,name}.
        Buffers only up to one event ("\\n\\n"-delimited); text/reasoning still stream live."""
        buf = b""
        restored = 0
        try:
            while True:
                chunk = resp.read(1024)
                if not chunk:
                    break
                buf += chunk
                while b"\n\n" in buf:
                    event, buf = buf.split(b"\n\n", 1)
                    out, did = _restore_ns_in_event(event, ns_map)
                    restored += did
                    self.wfile.write(out + b"\n\n")
                    self.wfile.flush()
            if buf:
                out, did = _restore_ns_in_event(buf, ns_map)
                restored += did
                self.wfile.write(out)
                self.wfile.flush()
            if restored:
                log("<- restored namespace on %d sub-agent call item(s)" % restored)
        except Exception as e:
            log("stream relay ended: %s" % e)

    def _json(self, code, obj):
        self._raw(code, "application/json", json.dumps(obj).encode())

    def _raw(self, code, ctype, data):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


def selftest():
    global FOUNDRY_PROJECT_BASE
    FOUNDRY_PROJECT_BASE = "https://fake.example.com/api/projects/proj/openai/v1"  # single backend, env-driven

    b = {
        "model": "FW-GLM-5.2",
        "tools": [
            {"type": "local_shell"},
            {"type": "custom", "name": "apply_patch", "format": {"type": "grammar"}},
            {"type": "function", "name": "keep_me", "parameters": {"type": "object"}},
            {"type": "namespace", "name": "multi_agent_v1", "tools": [
                {"type": "function", "name": "spawn_agent", "parameters": {"type": "object"}},
                {"type": "function", "name": "close_agent", "parameters": {"type": "object"}},
            ]},
        ],
        "text": {"verbosity": "low"},
        "include": ["reasoning.encrypted_content", "something.else"],
        "reasoning": None,
        "input": [
            {"type": "reasoning", "summary": [], "encrypted_content": "xxx"},
            {"type": "web_search_call", "status": "completed", "action": {"type": "search"}},
            {"type": "local_shell_call", "call_id": "c1",
             "action": {"type": "exec", "command": ["ls"], "timeout_ms": 5000}},
            {"type": "custom_tool_call", "call_id": "c2", "name": "apply_patch",
             "input": "*** Begin Patch\n*** End Patch"},
            {"type": "custom_tool_call_output", "call_id": "c2", "output": "ok"},
        ],
    }
    route, ns_map = normalize_request(b)
    assert route is not None
    assert all(t["type"] == "function" for t in b["tools"])  # local_shell/custom/namespace all -> function
    assert [t["name"] for t in b["tools"]] == \
        ["shell", "apply_patch", "keep_me", "spawn_agent", "close_agent"]  # namespace flattened
    assert ns_map == {"spawn_agent": "multi_agent_v1", "close_agent": "multi_agent_v1"}
    assert b["text"]["verbosity"] == "medium"
    assert b["include"] == ["something.else"]
    assert isinstance(b["reasoning"], dict) and b["reasoning"]["effort"] == "medium"
    it = b["input"]
    assert all(x["type"] not in ("reasoning", "web_search_call") for x in it)  # dropped from history
    assert it[0]["type"] == "function_call" and it[0]["name"] == "shell"
    assert json.loads(it[0]["arguments"]) == {"command": ["ls"], "timeout_ms": 5000}
    assert it[1]["type"] == "function_call"
    assert json.loads(it[1]["arguments"])["input"].startswith("*** Begin Patch")
    assert it[2] == {"type": "function_call_output", "call_id": "c2", "output": "ok"}

    # response side: restore namespace on a spawn_agent function_call SSE event
    ev = (b'event: response.output_item.done\n'
          b'data: {"type":"response.output_item.done","item":{"type":"function_call",'
          b'"name":"spawn_agent","call_id":"call_1","arguments":"{}"}}')
    out, n = _restore_ns_in_event(ev, ns_map)
    assert n == 1
    dline = [l for l in out.split(b"\n") if l.startswith(b"data:")][0]
    assert json.loads(dline[5:])["item"]["namespace"] == "multi_agent_v1"
    # non-namespaced function_call (shell) untouched
    ev2 = (b'event: response.output_item.done\n'
           b'data: {"type":"response.output_item.done","item":{"type":"function_call","name":"shell"}}')
    _, n2 = _restore_ns_in_event(ev2, ns_map)
    assert n2 == 0
    # text delta event untouched
    _, n3 = _restore_ns_in_event(b'event: response.output_text.delta\ndata: {"delta":"hi"}', ns_map)
    assert n3 == 0

    # incoming history: namespaced function_call gets namespace stripped for the backend
    b_hist = {"model": "FW-GLM-5.2", "input": [
        {"type": "function_call", "name": "spawn_agent", "namespace": "multi_agent_v1",
         "call_id": "c9", "arguments": "{}"},
        {"type": "function_call_output", "namespace": "multi_agent_v1", "call_id": "c9", "output": "id_1"},
    ]}
    normalize_request(b_hist)
    assert all("namespace" not in x for x in b_hist["input"])

    # DeepSeek/Kimi: reasoning.effort stripped, object preserved
    b2 = {"model": "DeepSeek-V4-Pro", "reasoning": {"effort": "high", "summary": "auto"}}
    r2, _ = normalize_request(b2)
    assert r2 is not None
    assert b2["reasoning"] == {"summary": "auto"}

    # DeepSeek: null reasoning removed entirely (backend accepts no reasoning field)
    b3 = {"model": "DeepSeek-V4-Pro", "reasoning": None}
    normalize_request(b3)
    assert "reasoning" not in b3

    # no backend configured (FOUNDRY_PROJECT_BASE unset): route stays None regardless of model
    FOUNDRY_PROJECT_BASE = ""
    r4, _ = normalize_request({"model": "FW-GLM-5.2"})
    assert r4 is None
    FOUNDRY_PROJECT_BASE = "https://fake.example.com/api/projects/proj/openai/v1"

    # master-key check: helper returns True only when the header matches PROXY_KEY
    assert _key_ok("Bearer secret", "secret") is True
    assert _key_ok("Bearer wrong", "secret") is False
    assert _key_ok("", "secret") is False
    assert _key_ok("anything", "") is True   # empty PROXY_KEY (local dev) disables the check

    print("selftest OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log("listening on http://127.0.0.1:%d  (POST .../responses)" % PORT)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
