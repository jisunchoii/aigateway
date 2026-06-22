import React from "react";
import {
  Title3, Text, Input, Label, Button, Spinner, Badge, Checkbox, tokens,
  MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { useMsal } from "@azure/msal-react";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";
import { modelLabel, modelsByPrice } from "../modelLabel";
import ConsumerPicker from "../components/ConsumerPicker";

// USD amount format: amounts >= $0.01 show 2 decimals. Below that (e.g. a $0.00005 limit),
// fixed precision would hide the value (0.00005 -> 0.0001), so increase decimals enough to show
// the first non-zero significant digit. Find the first significant digit and show +1 place (no
// exponential notation), e.g. $1.23 / $0.005 / $0.00005 / $0.
function usd(v: number): string {
  if (!v) return "0";
  const a = Math.abs(v);
  if (a >= 0.01) return v.toFixed(2);
  // decimal places of first significant digit = ceil(-log10(a)); +1 place of headroom.
  const digits = Math.min(10, Math.ceil(-Math.log10(a)) + 1);
  return v.toFixed(digits);
}

export default function Budget({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  // Model list = sorted by price (expensive → cheap). This order IS the downgrade ladder's cost
  // order, so regardless of check order it is always stored in correct descending-cost order.
  // (Same sort as the Models page.)
  const aliases = React.useMemo(() => modelsByPrice(config), [config]);
  const [consumer, setConsumer] = React.useState<string | null>(null);
  const [budget, setBudget] = React.useState("");  // daily_budget_usd ($)
  const [ladder, setLadder] = React.useState<string[]>([]);
  const [isDefault, setIsDefault] = React.useState(false);
  // level (downgrade step) comes from worker-written active_downgrade; usage_usd/pct are LIVE from the
  // config response (BFF computes them from Log Analytics x pricing each GET).
  const [level, setLevel] = React.useState<number | null>(null);
  const [usageUsd, setUsageUsd] = React.useState<number | null>(null);
  const [pct, setPct] = React.useState<number | null>(null);
  const [allowedModels, setAllowedModels] = React.useState<string[]>([]);  // models this consumer may call (③)
  const [loading, setLoading] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ intent: "success" | "error"; text: string } | null>(null);

  const load = React.useCallback(async () => {
    if (!consumer) return;
    const cr = await apiFetch(instance, scopes, `/api/consumers/${consumer}/config`);
    if (!cr.ok) { setMsg({ intent: "error", text: `Load failed: ${cr.status}` }); return; }
    const b = await cr.json();
    setBudget(String(b.daily_budget_usd ?? ""));
    setLadder(b.downgrade_ladder ?? []);
    setIsDefault(b.isDefault);
    setLevel(b.active_downgrade?.level ?? null);
    setUsageUsd(b.usage_usd ?? null);
    setPct(b.pct ?? null);
    setAllowedModels(b.allowed_models ?? []);
  }, [consumer, instance, scopes]);

  React.useEffect(() => {
    if (!consumer) return;
    setLoading(true); setMsg(null);
    setBudget(""); setLadder([]); setIsDefault(false);
    setLevel(null); setUsageUsd(null); setPct(null); setAllowedModels([]);
    load().catch((e) => setMsg({ intent: "error", text: String(e) })).finally(() => setLoading(false));
  }, [consumer, load]);

  function toggle(alias: string, checked: boolean) {
    // sort the selected set into fixed cost order before saving (aliases order = expensive→cheap regardless of check order).
    setLadder((cur) => {
      const next = checked ? [...new Set([...cur, alias])] : cur.filter((x) => x !== alias);
      return aliases.filter((a) => next.includes(a));
    });
  }

  async function save() {
    if (!consumer || busy) return;
    setBusy(true); setMsg(null);
    try {
      const body: Record<string, unknown> = {};
      if (budget) body.daily_budget_usd = Number(budget);
      if (ladder.length) body.downgrade_ladder = ladder;
      const r = await apiFetch(instance, scopes, `/api/consumers/${consumer}/config`, {
        method: "PUT", body: JSON.stringify(body),
      });
      if (!r.ok) { setMsg({ intent: "error", text: `Save failed: ${r.status}` }); return; }
      setIsDefault(false);
      const saved = await r.json().catch(() => ({}));
      setMsg({
        intent: "success",
        text: saved.reevaluationTriggered
          ? `Saved the budget for consumer ${consumer} and requested re-evaluation. Usage aggregation may take a few minutes to apply.`
          : `Saved the budget for consumer ${consumer}.`,
      });
      await load();  // refresh live percentage against the new limit
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20, maxWidth: 640 }}>
      <Title3>Budget</Title3>
      <MessageBar intent="info">
        <MessageBarBody>
          Set a <b>daily cost ($) limit</b> and <b>model priority (expensive → cheap)</b>. About every 5 minutes
          the estimated cost is computed from per-model token usage × unit price; above 80% of the limit,
          requests switch to the next cheaper model in priority, and above 100% to the cheapest model.
          Resets daily at midnight (UTC).
        </MessageBarBody>
      </MessageBar>
      <ConsumerPicker config={config} selected={consumer} onSelect={setConsumer} />
      {consumer && (loading ? <Spinner label="Loading…" /> : (
        <>
          {/* current status card */}
          <div style={{
            display: "flex", flexDirection: "column", gap: 12,
            border: `1px solid ${tokens.colorNeutralStroke2}`,
            borderRadius: tokens.borderRadiusLarge,
            background: tokens.colorNeutralBackground1,
            padding: 20,
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <Text weight="semibold">Current status</Text>
              {isDefault && <Badge appearance="tint" color="informative">No per-consumer config</Badge>}
              {level && level > 0
                ? <Badge appearance="tint" color={level >= 2 ? "danger" : "warning"}>
                    {`Auto-switch level ${level}`}
                  </Badge>
                : <Badge appearance="tint" color="success">Normal</Badge>}
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>Estimated cost today</Text>
              {usageUsd !== null
                ? <Text size={500} weight="semibold">
                    {`$${usd(usageUsd)}`}
                    {pct !== null
                      ? <Text size={300} style={{ color: tokens.colorNeutralForeground2, fontWeight: 400 }}>
                          {`  ·  ${(pct * 100).toFixed(0)}% of $${usd(Number(budget || 0))} limit`}
                        </Text>
                      : <Text size={300} style={{ color: tokens.colorNeutralForeground3, fontWeight: 400 }}>{"  ·  no limit set"}</Text>}
                  </Text>
                : <Text size={400} style={{ color: tokens.colorNeutralForeground3 }}>—</Text>}
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>Available models</Text>
              <Text size={300}>
                {allowedModels.length > 0
                  ? allowedModels.map((a) => modelLabel(a, config)).join(", ")
                  : "Inheriting global default — set it in the ‘Models’ menu"}
              </Text>
            </div>
          </div>

          {/* settings */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6, maxWidth: 280 }}>
            <Label htmlFor="daily-budget" weight="semibold">Daily cost ($) limit</Label>
            <Input id="daily-budget" type="number" placeholder="e.g. 5.00"
                   value={budget} onChange={(_, d) => setBudget(d.value)} />
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <Label weight="semibold">Model priority (expensive → cheap)</Label>
            <Text size={200} style={{ color: tokens.colorNeutralForeground3, marginTop: -4 }}>
              Check every model this consumer may use, from most to least expensive. When the budget is
              exceeded, the model in use steps down one level at a time through this order to a cheaper model.
            </Text>
            <Text size={200} style={{ color: tokens.colorNeutralForeground3, marginTop: -4 }}>
              For downgrade to work, <b>the model the client calls must also be in this list</b> (usually keep
              it the same as the allowed models in the ‘Models’ menu). You may mix OpenAI and Foundry OSS
              models; downgrade switches across types to the next cheaper model in order regardless of kind.
            </Text>
            <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 4 }}>
              {aliases.map((a) => {
                const allowed = allowedModels.includes(a);
                return (
                  <Checkbox key={a}
                            label={allowed ? modelLabel(a, config) : `${modelLabel(a, config)}  (not allowed)`}
                            checked={ladder.includes(a)}
                            onChange={(_, d) => toggle(a, !!d.checked)} />
                );
              })}
            </div>
            {/* warn if an allowed model is missing from the priority list — that model is excluded from downgrade */}
            {allowedModels.some((a) => !ladder.includes(a)) && (
              <Text size={200} style={{ color: tokens.colorPaletteDarkOrangeForeground1, marginTop: 2 }}>
                ⚠ Allowed models missing from priority: {allowedModels.filter((a) => !ladder.includes(a)).join(", ")}
                {" "}— calls to these models are not downgraded.
              </Text>
            )}
          </div>

          <Button appearance="primary" disabled={busy} onClick={save} style={{ alignSelf: "flex-start" }}>Save</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
