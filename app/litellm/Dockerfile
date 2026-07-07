# syntax=docker/dockerfile:1

# LiteLLM Responses bridge. Pins the upstream stable image and bakes in our config so the
# Container App needs no mounted volume. Backend auth is Entra ID (managed identity) — no keys
# in the image or config; see config.yaml.
FROM ghcr.io/berriai/litellm:main-stable

COPY config.yaml /app/config.yaml

# LiteLLM reads --config; the master key (APIM<->LiteLLM hop auth) comes from LITELLM_MASTER_KEY env.
CMD ["--config", "/app/config.yaml", "--port", "4000"]
