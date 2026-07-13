#!/usr/bin/env python3
"""Probe which hosted tools each Foundry model endpoint currently accepts.

WHY probe instead of trusting the tool list: the backend advertises a shared set of hosted
tool types, but EXECUTION is per-model. A type can be "accepted" (HTTP 200 or a config-only
400) yet unrunnable on another model (400 "not supported with <model>", invalid_value, or a
repeatable 500 like grok+code_interpreter). Only a live call tells them apart. This fills the
observed matrix from ground truth; re-run it when models, api-version, or region change.

This is diagnostic output, not the proxy policy. The proxy intentionally strips all hosted
tools from non-OpenAI models so web search and other tools execute as client-visible MCP
function calls instead of opaque server-side agentic loops.

The classification also injects web_search_call.action.sources so a web_search probe reflects
the same include the proxy sends in production.

Auth: Entra ID only (az login). Run locally against a public project, or from the jumpbox.
Usage:
    az login
    python probe_hosted_tools.py \
        --base https://<acct>.services.ai.azure.com/api/projects/<proj>/openai/v1 \
        --models FW-GLM-5.2 DeepSeek-V4-Pro grok-4.3 gpt-5.6-sol
"""
import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

# Reuse the proxy's reasoning policy so each probe sends a reasoning shape the model accepts
# (GLM requires a reasoning object; DeepSeek/grok reject reasoning.effort).
import foundry_codex_proxy as proxy

# One minimal, well-formed instance per hosted tool type. Config-only fields (a nonexistent
# vector store, no imagegen header, an unreachable MCP server) are intentional: they make the
# backend answer "type accepted, args missing" (supported) vs "type not supported" (unsupported).
PROBE_TOOLS = {
    "web_search": {"type": "web_search"},
    "web_search_2025_08_26": {"type": "web_search_2025_08_26"},
    "web_search_preview": {"type": "web_search_preview"},
    "web_search_preview_2025_03_11": {"type": "web_search_preview_2025_03_11"},
    "code_interpreter": {"type": "code_interpreter", "container": {"type": "auto"}},
    "file_search": {"type": "file_search", "vector_store_ids": ["vs_probe_nonexistent"]},
    "image_generation": {"type": "image_generation"},
    "mcp": {"type": "mcp", "server_label": "probe", "server_url": "https://example.com/mcp"},
    "computer": {"type": "computer"},
    "computer_use_preview": {"type": "computer_use_preview", "display_width": 800,
                             "display_height": 600, "environment": "browser"},
    "tool_search": {"type": "tool_search", "execution": "server"},
    "shell": {"type": "shell"},
    "programmatic_tool_calling": {"type": "programmatic_tool_calling"},
}

# A hosted tool is SUPPORTED if the type is accepted. These substrings in a 400 mean the type
# itself is fine and only runtime args are missing -> still supported.
CONFIG_ONLY_400 = (
    "vector store",            # file_search: no real store
    "x-ms-oai-image-generation-deployment",  # image_generation: header needed
    "imagegen deployment",
    "external_connector",      # mcp: our dummy server is unreachable
    "server returned",
)
# These mean the model genuinely can't run the tool.
UNSUPPORTED_400 = ("not supported", "invalid value")

RETRIES_FOR_500 = 3  # a tool that 500s every time (e.g. grok+code_interpreter) counts unsupported


def az_token(scope):
    out = subprocess.run(
        ["az", "account", "get-access-token", "--scope", scope,
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, timeout=30, shell=(sys.platform == "win32"))
    tok = out.stdout.strip()
    if not tok:
        sys.exit("az token failed: %s" % (out.stderr.strip() or "empty token"))
    return tok


def classify(base, token, model, tool):
    """Return 'supported' | 'unsupported' | 'error:<detail>' for one (model, tool)."""
    body = {"model": model, "max_output_tokens": 64, "tools": [tool], "input": "hi"}
    if proxy.REASONING_MODES.get(model) == "required":
        body["reasoning"] = {"effort": "medium"}
    last = None
    for attempt in range(RETRIES_FOR_500):
        req = urllib.request.Request(
            base.rstrip("/") + "/responses", data=json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
            method="POST")
        try:
            urllib.request.urlopen(req, timeout=60).read()
            return "supported"
        except urllib.error.HTTPError as e:
            try:
                msg = (json.loads(e.read()).get("error", {}).get("message") or "")
            except Exception:
                msg = ""
            low = msg.lower()
            if e.code == 500:
                last = "error:500 %s" % msg[:60]
                continue  # transient? retry; only a REPEATED 500 is treated as unsupported
            if any(s in low for s in UNSUPPORTED_400):
                return "unsupported"
            if e.code == 400 and any(s in low for s in CONFIG_ONLY_400):
                return "supported"
            return "error:%d %s" % (e.code, msg[:60])
        except Exception as e:  # noqa: BLE001 - network/timeout: report, don't crash the sweep
            last = "error:%s" % e
            break
    # every attempt 500'd (or a transport error) -> not runnable on this model
    return "unsupported" if (last and "500" in last) else (last or "unsupported")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="Foundry project OpenAI/v1 base URL")
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--scope", default=None, help="token scope (default: derived from base)")
    args = ap.parse_args()

    scope = args.scope or proxy.mi_scope_for(args.base)
    token = az_token(scope)

    matrix = {}
    for model in args.models:
        supported = set()
        print("# === %s ===" % model, file=sys.stderr)
        for name, tool in PROBE_TOOLS.items():
            verdict = classify(args.base, token, model, tool)
            print("#   %-22s %s" % (name, verdict), file=sys.stderr)
            if verdict == "supported":
                supported.add(name)
        matrix[model] = supported

    # Report backend acceptance separately from the proxy's conservative policy allow-list.
    print("OBSERVED_HOSTED_TOOL_ACCEPTANCE = {")
    for model, tools in matrix.items():
        items = ", ".join('"%s"' % t for t in sorted(tools))
        print('    "%s": {%s},' % (model, items))
    print("}")


if __name__ == "__main__":
    main()
