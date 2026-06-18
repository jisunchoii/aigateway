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

// USD 금액 포맷: $0.01 이상은 2자리. 그 미만(예: $0.00005 한도)은 고정 자릿수로 반올림하면
// 값이 가려지므로(0.00005 -> 0.0001), 0이 아닌 유효숫자가 보일 만큼 소수 자리를 늘린다.
// 첫 유효숫자 위치를 찾아 +1자리까지 표시(지수표기 없이). $1.23 / $0.005 / $0.00005 / $0 처럼.
function usd(v: number): string {
  if (!v) return "0";
  const a = Math.abs(v);
  if (a >= 0.01) return v.toFixed(2);
  // 첫 유효숫자의 소수 자리수 = ceil(-log10(a)); 거기에 1자리 여유.
  const digits = Math.min(10, Math.ceil(-Math.log10(a)) + 1);
  return v.toFixed(digits);
}

export default function Budget({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  // 모델 목록 = 가격순(비쌈 → 쌈)으로 정렬. 이 순서가 곧 강등 사다리의 비용 순서가 되므로
  // 체크 순서와 무관하게 항상 올바른 비용 내림차순으로 저장된다. (Models 페이지와 동일 정렬)
  const aliases = React.useMemo(() => modelsByPrice(config), [config]);
  const [consumer, setConsumer] = React.useState<string | null>(null);
  const [budget, setBudget] = React.useState("");  // daily_budget_usd ($)
  const [ladder, setLadder] = React.useState<string[]>([]);
  const [isDefault, setIsDefault] = React.useState(false);
  // level (강등 단계) comes from worker-written active_downgrade; usage_usd/pct are LIVE from the
  // config response (BFF computes them from Log Analytics x pricing each GET).
  const [level, setLevel] = React.useState<number | null>(null);
  const [usageUsd, setUsageUsd] = React.useState<number | null>(null);
  const [pct, setPct] = React.useState<number | null>(null);
  const [allowedModels, setAllowedModels] = React.useState<string[]>([]);  // 이 컨슈머가 호출 가능한 모델(③)
  const [loading, setLoading] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ intent: "success" | "error"; text: string } | null>(null);

  const load = React.useCallback(async () => {
    if (!consumer) return;
    const cr = await apiFetch(instance, scopes, `/api/consumers/${consumer}/config`);
    if (!cr.ok) { setMsg({ intent: "error", text: `불러오기 실패: ${cr.status}` }); return; }
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
    // 선택 집합을 고정 비용 순서로 정렬해 저장 (체크 순서와 무관하게 aliases 순서 = 비쌈→쌈).
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
      if (!r.ok) { setMsg({ intent: "error", text: `저장 실패: ${r.status}` }); return; }
      setIsDefault(false);
      const saved = await r.json().catch(() => ({}));
      setMsg({
        intent: "success",
        text: saved.reevaluationTriggered
          ? `${consumer} 컨슈머의 예산을 저장하고 재평가를 요청했습니다. 사용량 집계 반영에는 몇 분이 걸릴 수 있습니다.`
          : `${consumer} 컨슈머의 예산을 저장했습니다.`,
      });
      await load();  // refresh live 퍼센트 against the new limit
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20, maxWidth: 640 }}>
      <Title3>예산</Title3>
      <MessageBar intent="info">
        <MessageBarBody>
          <b>하루 비용($) 한도</b>와 <b>모델 우선순위(비쌈 → 쌈)</b>를 설정합니다. 약 5분마다 모델별
          토큰 사용량 × 단가로 추정 비용을 계산해, 한도의 80%를 넘으면 우선순위에서 한 단계 저렴한
          모델로, 100%를 넘으면 가장 저렴한 모델로 자동 전환합니다. 매일 자정(UTC)에 초기화됩니다.
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
              <Text weight="semibold">현재 상태</Text>
              {isDefault && <Badge appearance="tint" color="informative">컨슈머별 설정 없음</Badge>}
              {level && level > 0
                ? <Badge appearance="tint" color={level >= 2 ? "danger" : "warning"}>
                    {`자동 전환 ${level}단계`}
                  </Badge>
                : <Badge appearance="tint" color="success">정상</Badge>}
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>오늘 추정 비용</Text>
              {usageUsd !== null
                ? <Text size={500} weight="semibold">
                    {`$${usd(usageUsd)}`}
                    {pct !== null
                      ? <Text size={300} style={{ color: tokens.colorNeutralForeground2, fontWeight: 400 }}>
                          {`  ·  한도 $${usd(Number(budget || 0))}의 ${(pct * 100).toFixed(0)}%`}
                        </Text>
                      : <Text size={300} style={{ color: tokens.colorNeutralForeground3, fontWeight: 400 }}>{"  ·  한도 미설정"}</Text>}
                  </Text>
                : <Text size={400} style={{ color: tokens.colorNeutralForeground3 }}>—</Text>}
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>사용 가능한 모델</Text>
              <Text size={300}>
                {allowedModels.length > 0
                  ? allowedModels.map((a) => modelLabel(a, config)).join(", ")
                  : "전역 기본값 상속 — ‘모델’ 메뉴에서 설정"}
              </Text>
            </div>
          </div>

          {/* 설정 */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6, maxWidth: 280 }}>
            <Label htmlFor="daily-budget" weight="semibold">하루 비용($) 한도</Label>
            <Input id="daily-budget" type="number" placeholder="예: 5.00"
                   value={budget} onChange={(_, d) => setBudget(d.value)} />
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <Label weight="semibold">모델 우선순위 (비쌈 → 쌈)</Label>
            <Text size={200} style={{ color: tokens.colorNeutralForeground3, marginTop: -4 }}>
              이 컨슈머가 쓸 모델을 비싼 것부터 저렴한 것 순으로 모두 체크하세요. 예산을 넘으면 지금
              쓰는 모델에서 이 순서를 따라 더 저렴한 모델로 한 단계씩 내려갑니다.
            </Text>
            <Text size={200} style={{ color: tokens.colorNeutralForeground3, marginTop: -4 }}>
              <b>클라이언트가 호출하는 모델도 이 목록에 포함</b>되어야 강등이 동작합니다(보통 ‘모델’
              메뉴의 허용 모델과 같게 맞춥니다). OpenAI·Foundry OSS 모델을 섞어도 되며, 종류와 관계없이
              순서상 더 저렴한 모델로 교차 전환됩니다.
            </Text>
            <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 4 }}>
              {aliases.map((a) => {
                const allowed = allowedModels.includes(a);
                return (
                  <Checkbox key={a}
                            label={allowed ? modelLabel(a, config) : `${modelLabel(a, config)}  (허용 안 됨)`}
                            checked={ladder.includes(a)}
                            onChange={(_, d) => toggle(a, !!d.checked)} />
                );
              })}
            </div>
            {/* 허용 모델 중 우선순위에 빠진 게 있으면 경고 — 그 모델은 강등 대상에서 누락됨 */}
            {allowedModels.some((a) => !ladder.includes(a)) && (
              <Text size={200} style={{ color: tokens.colorPaletteDarkOrangeForeground1, marginTop: 2 }}>
                ⚠ 허용 모델 중 우선순위에 빠진 것: {allowedModels.filter((a) => !ladder.includes(a)).join(", ")}
                {" "}— 이 모델로 호출하면 강등이 적용되지 않습니다.
              </Text>
            )}
          </div>

          <Button appearance="primary" disabled={busy} onClick={save} style={{ alignSelf: "flex-start" }}>저장</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
