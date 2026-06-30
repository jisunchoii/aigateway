"""FastAPI app factory. Dependencies are injected via AppDeps so the app is testable with fakes.
Routes:
  GET    /api/config   anonymous   -> MSAL config for the SPA
  GET    /api/me       auth        -> current principal (name + is_admin)
  GET    /api/keys     admin       -> list APIM subscriptions (joined with consumer mapping)
  POST   /api/keys     admin       -> issue an APIM subscription (returns primary key ONCE)
  DELETE /api/keys/{id} admin      -> revoke an APIM subscription
  GET    /healthz      anonymous
  GET    /api/consumers          admin  -> distinct consumers + key counts
  GET    /api/consumers/{consumer}/config  admin -> consumer config (or global fallback, isDefault)
  PUT    /api/consumers/{consumer}/config  admin -> upsert consumer config (merge; 400 on invalid)
  GET    /{full_path}  anonymous   -> serve the built SPA (index.html fallback)
"""
import datetime
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from bff.apim import ApimKeys
from bff.auth import Principal
from bff.config import Settings
from bff.deps import current_principal, require_admin
from bff.metrics import MetricsQuery, RANGES
from bff.store import MappingStore
from bff.consumerconfig import ConsumerConfigStore
from bff.consumerregistry import ConsumerRegistryStore
from bff.cost import cost_usd


def _consumer_config_response(consumer: str, doc: dict, *, is_default: bool,
                          default_models: list | None = None,
                          usage_usd: float | None = None, pct: float | None = None) -> dict:
    # An absent/empty allowed_models means "inherit the global allowlist" — the same semantics the
    # APIM policy uses (effectiveAllowedModels falls back to {{allowed-models}}). The live `global`
    # Cosmos doc carries no allowed_models, so without this fallback the Models UI shows every box
    # unchecked for an inheriting consumer. Fall back to the gateway's configured aliases.
    return {
        "consumer": consumer,
        "isDefault": is_default,
        "allowed_models": doc.get("allowed_models") or list(default_models or []),
        "tier": doc.get("tier"),
        "daily_budget": doc.get("daily_budget"),
        "daily_budget_usd": doc.get("daily_budget_usd"),
        "downgrade_ladder": doc.get("downgrade_ladder", []),
        # usage_usd/pct are computed LIVE (Log Analytics x pricing) so a budget change reflects in
        # the percent immediately, without waiting for the worker. None when no budget / no metrics.
        "usage_usd": usage_usd,
        "pct": pct,
        # active_downgrade is worker-written (the enforced level); SPA reads .level for the badge.
        "active_downgrade": doc.get("active_downgrade"),
    }


def _translate_by_consumer(data: dict, group_to_consumer: dict) -> dict:
    """Display-only: rewrite dashboard by_consumer rows whose `consumer` is an Entra group GUID into the
    mapped human-readable consumer name. Unmapped values pass through unchanged. Does not touch KQL."""
    rows = data.get("by_consumer")
    if isinstance(rows, list):
        for r in rows:
            g = r.get("consumer")
            if g in group_to_consumer:
                r["consumer"] = group_to_consumer[g]
    return data


@dataclass
class AppDeps:
    settings: Settings
    apim: ApimKeys
    store: MappingStore
    spa_dir: Optional[Path]
    consumerconfig: ConsumerConfigStore
    metrics: MetricsQuery
    consumerregistry: ConsumerRegistryStore
    model_prices: dict = field(default_factory=dict)  # model id -> {prompt, completion} per-1k (Part 2)
    job_starter: object = None  # JobStarter: triggers config-sync on a budget change (instant re-eval)


class CreateKeyRequest(BaseModel):
    consumer: str


class ConsumerConfigRequest(BaseModel):
    allowed_models: list[str] | None = None
    tier: str | None = None
    daily_budget: int | None = None
    daily_budget_usd: float | None = None
    downgrade_ladder: list[str] | None = None


class ConsumerRegistryRequest(BaseModel):
    consumer: str | None = None
    entra_group_id: str | None = None
    display_name: str | None = None
    description: str | None = None


def app_factory(deps: AppDeps) -> FastAPI:
    app = FastAPI(title="AI Gateway Admin BFF")
    s = deps.settings

    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/api/config")
    def config():
        # Anonymous: the SPA needs these to initialize MSAL before any login.
        # aliasModels (non-secret deployment metadata) lets the Models page show what each alias is.
        return {
            "tenantId": s.entra_tenant_id,
            "clientId": s.spa_client_id,
            "apiScope": f"{s.bff_api_audience}/access_as_user",
            "aliasModels": s.alias_models,
            "modelPrices": deps.model_prices,  # model id -> {prompt, completion} per-1k (Part 2 UI labels)
        }

    @app.get("/api/me")
    def me(principal: Principal = Depends(current_principal)):
        return {"name": principal.name, "oid": principal.oid, "isAdmin": principal.is_admin}

    @app.get("/api/keys")
    def list_keys(_: Principal = Depends(require_admin)):
        consumers = {row["id"]: row.get("consumer") for row in deps.store.list()}
        return [
            {"id": k.id, "displayName": k.display_name, "state": k.state,
             "consumer": consumers.get(k.id)}
            for k in deps.apim.list()
        ]

    @app.post("/api/keys", status_code=201)
    def create_key(body: CreateKeyRequest, principal: Principal = Depends(require_admin)):
        consumer = body.consumer.strip()
        if not consumer:
            raise HTTPException(status_code=400, detail="consumer is required")
        vk = deps.apim.create(display_name=consumer)
        try:
            deps.store.record(
                key_id=vk.id, consumer=consumer, display_name=vk.display_name,
                created_by=principal.oid,
                created_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            )
        except Exception:
            # Compensate: don't leave a live, untracked (unrevocable) APIM key if the
            # mapping write fails. Roll back the subscription, then surface the error.
            deps.apim.delete(vk.id)
            raise
        # primaryKey is returned exactly once, at creation.
        return {"id": vk.id, "consumer": consumer, "displayName": vk.display_name,
                "primaryKey": vk.primary_key, "secondaryKey": vk.secondary_key}

    @app.delete("/api/keys/{key_id}", status_code=204)
    def delete_key(key_id: str, _: Principal = Depends(require_admin)):
        deps.apim.delete(key_id)
        deps.store.remove(key_id)
        return Response(status_code=204)

    @app.get("/api/tiers")
    def list_tiers(_: Principal = Depends(require_admin)):
        return [{"name": n, "tpm": t["tpm"], "quota": t["quota"], "period": t["period"]}
                for n, t in s.rate_tiers.items()]

    @app.get("/api/consumers")
    def list_consumers(_: Principal = Depends(require_admin)):
        counts: dict[str, int] = {}
        for row in deps.store.list():
            t = row.get("consumer")
            if t:
                counts[t] = counts.get(t, 0) + 1
        reg = {d["consumer"]: d for d in deps.consumerregistry.list()}
        config_consumers = {d["consumer"] for d in deps.consumerconfig.list()}
        consumers = set(counts) | set(reg)
        return [{
            "consumer": t,
            "keyCount": counts.get(t, 0),
            "displayName": reg.get(t, {}).get("display_name"),
            "entraGroupId": reg.get(t, {}).get("entra_group_id"),
            "hasConfig": t in config_consumers,
            "source": "both" if (t in reg and t in counts) else ("registry" if t in reg else "keys"),
        } for t in sorted(consumers)]

    @app.post("/api/consumers", status_code=201)
    def create_consumer(body: ConsumerRegistryRequest, principal: Principal = Depends(require_admin)):
        consumer = (body.consumer or "").strip()
        if not consumer:
            raise HTTPException(status_code=400, detail="consumer is required")
        if deps.consumerregistry.get(consumer) is not None:
            raise HTTPException(status_code=409, detail=f"consumer '{consumer}' already registered")
        fields = {
            "entra_group_id": body.entra_group_id,
            "display_name": body.display_name,
            "description": body.description,
            "created_by": principal.oid,
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        try:
            deps.consumerregistry.put(consumer, fields, existing_group_owners=deps.consumerregistry.group_index())
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        return {"consumer": consumer, "created": True}

    @app.put("/api/consumers/{consumer}")
    def update_consumer(consumer: str, body: ConsumerRegistryRequest, _: Principal = Depends(require_admin)):
        existing = deps.consumerregistry.get(consumer) or {}
        incoming = {k: v for k, v in {
            "entra_group_id": body.entra_group_id,
            "display_name": body.display_name,
            "description": body.description,
        }.items() if v is not None}
        merged = {k: existing[k] for k in
                  ("entra_group_id", "display_name", "description") if k in existing}
        merged.update(incoming)
        if body.entra_group_id is not None and not str(body.entra_group_id).strip():
            raise HTTPException(status_code=400, detail="entra_group_id cannot be blank")
        try:
            deps.consumerregistry.put(consumer, merged, existing_group_owners=deps.consumerregistry.group_index())
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        return {"consumer": consumer, "saved": True}

    @app.delete("/api/consumers/{consumer}")
    def delete_consumer(consumer: str, _: Principal = Depends(require_admin)):
        # Full delete: registry doc + config doc. Refuse if live keys remain — deleting the config
        # while a key is still active would silently drop that consumer to global-default governance
        # (allowed-models/tier/budget all reset). Caller must revoke keys first (6 API Keys menu).
        key_count = sum(1 for row in deps.store.list() if row.get("consumer") == consumer)
        if key_count:
            raise HTTPException(
                status_code=409,
                detail=(f"'{consumer}' still has {key_count} key(s); revoke them in 6 API Keys "
                        "before deleting the consumer"),
            )
        deps.consumerregistry.remove(consumer)
        deps.consumerconfig.remove(consumer)
        return {"consumer": consumer, "deleted": True}

    def _live_spend(consumer: str, doc: dict) -> tuple[float | None, float | None]:
        """Live (usage_usd, pct) for a consumer: today's tokens (Log Analytics) x pricing, divided by
        daily_budget_usd. Computed fresh so a budget change reflects immediately. On any metrics
        error, fall back to the worker-written active_downgrade values rather than failing the GET."""
        budget = doc.get("daily_budget_usd")
        try:
            model_usage = deps.metrics.consumer_usage(consumer, RANGES["24h"])
            usage_usd = cost_usd(model_usage, deps.model_prices)
            pct = round(usage_usd / budget, 4) if budget else None
            return usage_usd, pct
        except Exception:
            ad = doc.get("active_downgrade") or {}
            return ad.get("usage_usd"), ad.get("pct")

    @app.get("/api/consumers/{consumer}/config")
    def get_consumer_config(consumer: str, _: Principal = Depends(require_admin)):
        default_models = list(s.allowed_model_aliases)
        doc = deps.consumerconfig.get(consumer)
        effective = doc if doc is not None else deps.consumerconfig.global_defaults()
        usage_usd, pct = _live_spend(consumer, effective)
        return _consumer_config_response(consumer, effective, is_default=doc is None,
                                         default_models=default_models, usage_usd=usage_usd, pct=pct)

    @app.put("/api/consumers/{consumer}/config")
    def put_consumer_config(consumer: str, body: ConsumerConfigRequest,
                        _: Principal = Depends(require_admin)):
        incoming = body.model_dump(exclude_none=True)
        if not incoming:
            raise HTTPException(status_code=400, detail="request body must contain at least one field")
        # Merge onto the existing doc: Cosmos upsert is a full replace, and each SPA page (Models /
        # RateLimits / Budget) PUTs only its own fields. Without merge, saving one page would wipe
        # the others. Read current persisted fields, overlay the incoming ones.
        # active_downgrade is worker-written (Phase 4): preserve it across an admin PUT (so a save
        # doesn't un-downgrade a consumer) but NEVER accept it from the request body (not in
        # ConsumerConfigRequest, not in `incoming`) — admins can't set or clear it.
        existing = deps.consumerconfig.get(consumer) or {}
        merged = {k: existing[k] for k in
                  ("allowed_models", "tier", "daily_budget", "daily_budget_usd",
                   "downgrade_ladder", "active_downgrade")
                  if k in existing}
        merged.update(incoming)
        aliases = list(s.allowed_model_aliases) if s.allowed_model_aliases else None
        try:
            deps.consumerconfig.put(consumer, merged, valid_aliases=aliases)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        # Any consumer config change should refresh APIM's consumer-config bundle NOW rather than
        # waiting for the ~5-min cron. Budget changes also re-evaluate the downgrade level.
        # Best-effort: start the config-sync job; never fail the save if it doesn't.
        triggered = False
        if deps.job_starter is not None:
            triggered = bool(deps.job_starter.start())
        return {"consumer": consumer, "saved": True, "reevaluationTriggered": triggered}

    def _resolve_range(r: str):
        span = RANGES.get(r)
        if span is None:
            raise HTTPException(status_code=400, detail=f"range must be one of {list(RANGES)}")
        return span

    @app.get("/api/links")
    def links(_: Principal = Depends(require_admin)):
        # Deep-link to APIM's native Azure Monitor analytics (Monitoring > Analytics on the APIM
        # resource). That workbook can't be embedded, so the Dashboard links out to it.
        return {"apimAnalyticsUrl": s.apim_analytics_url}

    @app.get("/api/metrics/dashboard")
    def metrics_dashboard(range: str = "24h", _: Principal = Depends(require_admin)):
        data = deps.metrics.dashboard(_resolve_range(range))
        data = _translate_by_consumer(data, deps.consumerregistry.group_index())
        # Active budget downgrades come from worker-written Cosmos state, not Log Analytics.
        data["downgrades"] = [
            {"consumer": d["consumer"], "level": (d.get("active_downgrade") or {}).get("level", 0)}
            for d in deps.consumerconfig.list()
            if (d.get("active_downgrade") or {}).get("level", 0) > 0
        ]
        return data

    @app.get("/api/metrics/monitoring")
    def metrics_monitoring(range: str = "1h", _: Principal = Depends(require_admin)):
        # Recent request log + 403/429 blocked events from Log Analytics (Monitoring page).
        return deps.metrics.monitoring(_resolve_range(range))

    # Serve the built SPA (only when a dir is provided -- tests pass None).
    if deps.spa_dir is not None:
        assets = deps.spa_dir / "assets"
        if assets.is_dir():
            app.mount("/assets", StaticFiles(directory=str(assets)), name="assets")

        @app.get("/{full_path:path}")
        def spa(full_path: str):
            # Unmatched /api/* must 404, not fall through to the SPA index (which would mask
            # routing/typo errors as a 200 HTML page and break JSON clients).
            if full_path.startswith("api/"):
                raise HTTPException(status_code=404)
            index = deps.spa_dir / "index.html"
            return FileResponse(str(index))

    return app
