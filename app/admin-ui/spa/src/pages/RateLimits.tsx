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
  Hourly: "시간", Daily: "하루", Weekly: "주", Monthly: "월",
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
        if (!r.ok) { setMsg({ intent: "error", text: `불러오기 실패: ${r.status}` }); return; }
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
      if (!r.ok) { setMsg({ intent: "error", text: `저장 실패: ${r.status}` }); return; }
      setIsDefault(false);
      setMsg({ intent: "success", text: `${consumer} 컨슈머를 '${tier}' 등급으로 설정했습니다.` });
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20, maxWidth: 640 }}>
      <Title3>속도 제한</Title3>
      <MessageBar intent="info">
        <MessageBarBody>
          컨슈머에 <b>속도 제한 등급</b>을 지정합니다. 게이트웨이가 등급의 <b>분당 토큰</b>과
          <b> 기간 한도</b>를 컨슈머별로 적용하고, 초과하면 요청을 차단합니다. 예산 한도와 달리
          순간적인 폭주를 막아 다른 컨슈머를 보호하는 용도입니다.
        </MessageBarBody>
      </MessageBar>
      <ConsumerPicker config={config} selected={consumer} onSelect={setConsumer} />
      {consumer && (loading ? <Spinner label="불러오는 중…" /> : (
        <>
          {/* 현재 상태 카드 */}
          <div style={{
            display: "flex", flexDirection: "column", gap: 12,
            border: `1px solid ${tokens.colorNeutralStroke2}`,
            borderRadius: tokens.borderRadiusLarge,
            background: tokens.colorNeutralBackground1,
            padding: 20,
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <Text weight="semibold">현재 등급</Text>
              {isDefault || !tier
                ? <Badge appearance="tint" color="informative">미설정 — 전역 기본값</Badge>
                : <Badge appearance="tint" color="brand">{tier}</Badge>}
            </div>
            {selected ? (
              <div style={{ display: "flex", gap: 32, flexWrap: "wrap" }}>
                <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                  <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>분당 토큰</Text>
                  <Text size={500} weight="semibold">{selected.tpm.toLocaleString()}</Text>
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                  <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>기간 한도</Text>
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
                등급을 선택하면 적용되는 한도가 표시됩니다.
              </Text>
            )}
          </div>

          {/* 설정 */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6, maxWidth: 280 }}>
            <Label htmlFor="tier-select" weight="semibold">등급 선택</Label>
            <Dropdown id="tier-select" placeholder="등급 선택" value={tier}
                      selectedOptions={tier ? [tier] : []}
                      onOptionSelect={(_, d) => d.optionValue && setTier(d.optionValue)}>
              {tiers.map((t) => (
                <Option key={t.name} value={t.name}>
                  {`${t.name} — 분당 ${t.tpm.toLocaleString()} 토큰 / ${t.quota.toLocaleString()} per ${periodKo(t.period)}`}
                </Option>
              ))}
            </Dropdown>
          </div>

          <Button appearance="primary" disabled={busy || !tier} onClick={save} style={{ alignSelf: "flex-start" }}>저장</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
