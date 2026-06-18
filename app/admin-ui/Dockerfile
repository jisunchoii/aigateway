# syntax=docker/dockerfile:1

# --- stage 1: build the SPA ---
FROM node:20-alpine AS spa
WORKDIR /spa
COPY spa/package.json spa/package-lock.json ./
RUN npm ci
COPY spa/ ./
# vite.config.ts outDir is ../bff/static; inside the container that resolves to /bff/static.
RUN npm run build

# --- stage 2: python runtime serving BFF + built SPA ---
FROM python:3.12-slim AS runtime
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
COPY bff/requirements.txt ./bff/requirements.txt
RUN pip install --no-cache-dir -r bff/requirements.txt
COPY bff/ ./bff/
# Bring in the built SPA from stage 1 (FastAPI serves it from bff/static).
COPY --from=spa /bff/static ./bff/static
EXPOSE 8000
CMD ["uvicorn", "bff.main:app", "--host", "0.0.0.0", "--port", "8000"]
