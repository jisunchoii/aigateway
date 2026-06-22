import React from "react";
import { useMsal } from "@azure/msal-react";
import {
  Title3, Text, Dropdown, Option, Button, Spinner, Badge, Label, tokens,
  MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";
import ConsumerPicker from "../components/ConsumerPicker";

interface Tier { name: string; tpm: number; quota: number; period: string }

const PERIOD_KO: Record<string, string> = {
  Hourly: "hour", Daily: "day", Weekly: "week", Monthly: "month",
};
const periodKo = (p: string) => PERIOD_KO[p] ?? p;

export default function RateLimits({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  const [tiers, setTiers] = React.useState<Tier[]>([]);
  const [consumer, setConsumer] = React.useState<string | null>(null);
  const [tier, setTier] = React.useState<string>("");
  const [isDefault, setIsDefault] = React.useState(false);
  const [loading, setLoading] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ intent: "success" | "error"; text: string } | null>(null);

  React.useEffect(() => {
    apiFetch(instance, scopes, "/api/tiers")
      .then(async (r) => { if (r.ok) setTiers(await r.json()); })
      .catch(() => { /* tiers list is best-effort for display */ });
  }, [instance, scopes]);

  React.useEffect(() => {
    if (!consumer) return;
    setLoading(true); setMsg(null); setTier(""); setIsDefault(false);
    apiFetch(instance, scopes, `/api/consumers/${consumer}/config`)
      .then(async (r) => {
        if (!r.ok) { setMsg({ intent: "error", text: `Load failed: ${r.status}` }); return; }
        const b = await r.json();
        setTier(b.tier ?? "");
        setIsDefault(b.isDefault);
      })
      .catch((e) => setMsg({ intent: "error", text: String(e) }))
      .finally(() => setLoading(false));
  }, [consumer, instance, scopes]);

  const selected = tiers.find((t) => t.name === tier);

  async function save() {
    if (!consumer || !tier || busy) return;
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, `/api/consumers/${consumer}/config`, {
        method: "PUT", body: JSON.stringify({ tier }),
      });
      if (!r.ok) { setMsg({ intent: "error", text: `Save failed: ${r.status}` }); return; }
      setIsDefault(false);
      setMsg({ intent: "success", text: `Set consumer ${consumer} to tier '${tier}'.` });
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20, maxWidth: 640 }}>
      <Title3>Rate limits</Title3>
      <MessageBar intent="info">
        <MessageBarBody>
          Assign a <b>rate-limit tier</b> to a consumer. The gateway applies the tier's <b>tokens per minute</b>
          and <b> period quota</b> per consumer and blocks requests that exceed them. Unlike the budget limit,
          this guards against sudden bursts to protect other consumers.
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
              <Text weight="semibold">Current tier</Text>
              {isDefault || !tier
                ? <Badge appearance="tint" color="informative">Not set — global default</Badge>
                : <Badge appearance="tint" color="brand">{tier}</Badge>}
            </div>
            {selected ? (
              <div style={{ display: "flex", gap: 32, flexWrap: "wrap" }}>
                <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                  <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>Tokens per minute</Text>
                  <Text size={500} weight="semibold">{selected.tpm.toLocaleString()}</Text>
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                  <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>Period quota</Text>
                  <Text size={500} weight="semibold">
                    {selected.quota.toLocaleString()}
                    <Text size={300} style={{ color: tokens.colorNeutralForeground2, fontWeight: 400 }}>
                      {`  / ${periodKo(selected.period)}`}
                    </Text>
                  </Text>
                </div>
              </div>
            ) : (
              <Text size={300} style={{ color: tokens.colorNeutralForeground3 }}>
                Select a tier to see the limits it applies.
              </Text>
            )}
          </div>

          {/* settings */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6, maxWidth: 280 }}>
            <Label htmlFor="tier-select" weight="semibold">Select tier</Label>
            <Dropdown id="tier-select" placeholder="Select tier" value={tier}
                      selectedOptions={tier ? [tier] : []}
                      onOptionSelect={(_, d) => d.optionValue && setTier(d.optionValue)}>
              {tiers.map((t) => (
                <Option key={t.name} value={t.name}>
                  {`${t.name} — ${t.tpm.toLocaleString()} tokens/min / ${t.quota.toLocaleString()} per ${periodKo(t.period)}`}
                </Option>
              ))}
            </Dropdown>
          </div>

          <Button appearance="primary" disabled={busy || !tier} onClick={save} style={{ alignSelf: "flex-start" }}>Save</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
