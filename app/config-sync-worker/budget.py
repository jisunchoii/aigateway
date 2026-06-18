"""Pure budget-evaluation logic for daily COST ($) downgrade (Phase 4 + Part 2).

No Azure I/O here — sync.py supplies consumer_config docs, a per-consumer per-model usage map,
and the pricing table; this computes the new active_downgrade state. Kept pure so it unit-tests
without Cosmos/Monitor.

Levels: 0 = normal, 1 = >=80% of daily_budget_usd, 2 = >=100%. The APIM policy reads
active_downgrade.level and rewrites the request model down the consumer's downgrade_ladder.
"""


def level_for(pct: float) -> int:
    if pct >= 1.0:
        return 2
    if pct >= 0.8:
        return 1
    return 0


def cost_for(model_usage: dict, pricing: dict) -> float:
    """Estimated USD cost for one consumer. model_usage: {model: {"prompt": int, "completion": int}}.
    pricing: {model: {"prompt": rate_per_1k, "completion": rate_per_1k}}. A model with no price
    contributes $0 (the caller logs it — this stays pure)."""
    total = 0.0
    for model, toks in model_usage.items():
        rate = pricing.get(model)
        if not rate:
            continue
        total += (toks.get("prompt", 0) / 1000.0) * rate.get("prompt", 0.0)
        total += (toks.get("completion", 0) / 1000.0) * rate.get("completion", 0.0)
    return round(total, 6)


def evaluate_downgrades(docs: list, usage: dict, pricing: dict, *, now_iso: str = "") -> dict:
    """Return {consumer: updated_doc} ONLY for consumers whose active_downgrade level CHANGED.

    docs: consumer_config dicts. usage: {consumer: {model: {"prompt","completion"}}}. pricing:
    {model: {"prompt","completion"}} per-1k rates. now_iso: timestamp stamped into the state
    (sync.py passes a real one; tests may omit). A consumer with no daily_budget_usd or no
    downgrade_ladder is skipped (the legacy token daily_budget is intentionally ignored — USD only).
    Level 0 removes the active_downgrade field.
    """
    changed = {}
    for doc in docs:
        consumer = doc.get("consumer")
        budget_usd = doc.get("daily_budget_usd")
        ladder = doc.get("downgrade_ladder")
        if not consumer or not budget_usd or not ladder:
            continue
        cost = cost_for(usage.get(consumer, {}), pricing)
        pct = round(cost / budget_usd, 4)
        new_level = level_for(pct)
        old_level = (doc.get("active_downgrade") or {}).get("level", 0)
        if new_level == old_level:
            continue  # no change -> no upsert
        updated = {k: v for k, v in doc.items() if k != "active_downgrade"}
        if new_level > 0:
            updated["active_downgrade"] = {
                "level": new_level, "usage_usd": cost, "pct": pct, "evaluated_at": now_iso,
            }
        changed[consumer] = updated
    return changed
