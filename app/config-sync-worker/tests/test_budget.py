import budget

PRICING = {
    "gpt-5.4": {"prompt": 0.0025, "completion": 0.015},
    "gpt-5.4-mini": {"prompt": 0.00075, "completion": 0.0045},
    "grok-4.3": {"prompt": 0.00125, "completion": 0.0025},
}


def test_level_thresholds():
    # pct < 0.8 -> 0, 0.8<=pct<1.0 -> 1, pct>=1.0 -> 2
    assert budget.level_for(0.0) == 0
    assert budget.level_for(0.79) == 0
    assert budget.level_for(0.8) == 1
    assert budget.level_for(0.99) == 1
    assert budget.level_for(1.0) == 2
    assert budget.level_for(5.0) == 2


def test_cost_for_consumer_sums_prompt_and_completion():
    # 10k prompt @0.0025/1k = 0.025 ; 2k completion @0.015/1k = 0.03 -> 0.055
    usage = {"gpt-5.4": {"prompt": 10000, "completion": 2000}}
    assert budget.cost_for(usage, PRICING) == 0.055


def test_cost_for_multi_model():
    usage = {"gpt-5.4": {"prompt": 1000, "completion": 0},        # 0.0025
             "grok-4.3": {"prompt": 1000, "completion": 1000}}    # 0.00125+0.0025=0.00375
    assert budget.cost_for(usage, PRICING) == 0.00625


def test_cost_for_missing_price_contributes_zero():
    usage = {"unknownmodel": {"prompt": 1_000_000, "completion": 1_000_000}}
    assert budget.cost_for(usage, PRICING) == 0.0


def test_evaluate_sets_active_downgrade_usd():
    docs = [{"consumer": "smoke", "daily_budget_usd": 1.0,
             "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"]}]
    # cost 0.25 (100k prompt) + 0.6 (40k completion) = 0.85 -> 85% -> level 1
    usage = {"smoke": {"gpt-5.4": {"prompt": 100000, "completion": 40000}}}
    out = budget.evaluate_downgrades(docs, usage, PRICING)
    ad = out["smoke"]["active_downgrade"]
    assert ad["level"] == 1
    assert ad["usage_usd"] == 0.85
    assert ad["pct"] == 0.85


def test_evaluate_skips_no_usd_budget():
    # token-only daily_budget is IGNORED now (USD-only decision)
    docs = [{"consumer": "legacy", "daily_budget": 1000,
             "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"]}]
    usage = {"legacy": {"gpt-5.4": {"prompt": 9_999_999, "completion": 0}}}
    out = budget.evaluate_downgrades(docs, usage, PRICING)
    assert "legacy" not in out


def test_evaluate_skips_no_ladder():
    docs = [{"consumer": "noladder", "daily_budget_usd": 1.0}]
    out = budget.evaluate_downgrades(docs, {"noladder": {"gpt-5.4": {"prompt": 9_999_999}}}, PRICING)
    assert "noladder" not in out


def test_evaluate_clears_when_back_under_usd():
    docs = [{"consumer": "smoke", "daily_budget_usd": 1.0,
             "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"],
             "active_downgrade": {"level": 2, "usage_usd": 1.2, "pct": 1.2, "evaluated_at": "x"}}]
    usage = {"smoke": {"gpt-5.4": {"prompt": 1000, "completion": 0}}}  # 0.0025 -> 0% -> cleared
    out = budget.evaluate_downgrades(docs, usage, PRICING)
    assert "active_downgrade" not in out["smoke"]


def test_evaluate_no_change_returns_nothing_usd():
    docs = [{"consumer": "smoke", "daily_budget_usd": 1.0,
             "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"],
             "active_downgrade": {"level": 1, "usage_usd": 0.85, "pct": 0.85, "evaluated_at": "x"}}]
    # still 0.85 -> level 1 -> no upsert
    usage = {"smoke": {"gpt-5.4": {"prompt": 100000, "completion": 40000}}}
    out = budget.evaluate_downgrades(docs, usage, PRICING)
    assert "smoke" not in out


def test_evaluate_missing_usage_is_zero_usd():
    docs = [{"consumer": "quiet", "daily_budget_usd": 1.0,
             "downgrade_ladder": ["gpt-5.4", "gpt-5.4-mini"],
             "active_downgrade": {"level": 1, "usage_usd": 0.9, "pct": 0.9, "evaluated_at": "x"}}]
    out = budget.evaluate_downgrades(docs, {}, PRICING)  # no usage -> 0% -> clear
    assert "active_downgrade" not in out["quiet"]
