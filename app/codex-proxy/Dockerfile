# syntax=docker/dockerfile:1

# Codex↔Foundry Responses proxy sidecar. Normalizes Codex's gpt-only payload shapes for the
# Foundry project route. Backend auth is Entra ID (Managed Identity) via azure-identity — no keys.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY foundry_codex_proxy.py .

EXPOSE 8789
CMD ["python", "foundry_codex_proxy.py"]
