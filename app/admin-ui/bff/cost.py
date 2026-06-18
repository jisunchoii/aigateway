"""Shared USD cost formula for budget display. Mirrors the worker's budget.cost_for (the BFF can't
import the worker package), so the live percentage the UI shows matches what the worker computes."""


def cost_usd(model_usage: dict, pricing: dict) -> float:
    """USD cost. model_usage: {model: {"prompt","completion"}}; pricing: {model: {"prompt","completion"}}
    per-1k rates. A model with no price contributes $0 (matches the worker's fail-safe)."""
    total = 0.0
    for model, toks in model_usage.items():
        rate = pricing.get(model)
        if not rate:
            continue
        total += (toks.get("prompt", 0) / 1000.0) * rate.get("prompt", 0.0)
        total += (toks.get("completion", 0) / 1000.0) * rate.get("completion", 0.0)
    return round(total, 6)
