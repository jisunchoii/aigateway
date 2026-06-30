import React from "react";
import { useMsal } from "@azure/msal-react";
import {
  Title3, Text, Checkbox, Button, Spinner, Badge, MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";
import { modelLabel, modelsByPrice } from "../modelLabel";
import ConsumerPicker from "../components/ConsumerPicker";

export default function Models({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  // 모델 목록은 aliasModels(Terraform→BFF) 키에서 동적 생성 — OpenAI + Foundry OSS가 자동 노출.
  // 키 = 실제 모델명(= APIM 배포 이름)이라 그대로 식별자로 쓴다. 가격순(비쌈→쌈)으로 정렬해 표시.
  const aliases = React.useMemo(() => modelsByPrice(config), [config]);
  const [consumer, setConsumer] = React.useState<string | null>(null);
  const [models, setModels] = React.useState<string[]>([]);
  const [isDefault, setIsDefault] = React.useState(false);
  const [loading, setLoading] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ intent: "success" | "error"; text: string } | null>(null);

  React.useEffect(() => {
    if (!consumer) return;
    setLoading(true); setMsg(null);
    setModels([]); setIsDefault(false);
    apiFetch(instance, scopes, `/api/consumers/${consumer}/config`)
      .then(async (r) => {
        if (!r.ok) { setMsg({ intent: "error", text: `불러오기 실패: ${r.status}` }); return; }
        const b = await r.json();
        setModels(b.allowed_models ?? []);
        setIsDefault(b.isDefault);
      })
      .catch((e) => setMsg({ intent: "error", text: String(e) }))
      .finally(() => setLoading(false));
  }, [consumer, instance, scopes]);

  function toggle(alias: string, checked: boolean) {
    setModels((m) => (checked ? [...new Set([...m, alias])] : m.filter((x) => x !== alias)));
  }

  async function save() {
    if (!consumer || busy) return;
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, `/api/consumers/${consumer}/config`, {
        method: "PUT", body: JSON.stringify({ allowed_models: models }),
      });
      if (!r.ok) { setMsg({ intent: "error", text: `저장 실패: ${r.status}` }); return; }
      setIsDefault(false);
      setMsg({ intent: "success", text: `${consumer} 컨슈머의 허용 모델을 저장했습니다.` });
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 600 }}>
      <Title3>모델 — 컨슈머별 허용 모델</Title3>
      <Text>컨슈머가 호출할 수 있는 모델을 선택하세요. 그 외 모델로 요청하면 게이트웨이에서 403으로 거부됩니다.</Text>
      <ConsumerPicker config={config} selected={consumer} onSelect={setConsumer} />
      {consumer && (loading ? <Spinner label="불러오는 중…" /> : (
        <>
          {isDefault && <Badge appearance="tint" color="informative">전역 기본값 상속 중 (아직 컨슈머별 설정 없음)</Badge>}
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {aliases.map((a) => (
              <Checkbox key={a} label={modelLabel(a, config)}
                        checked={models.includes(a)}
                        onChange={(_, d) => toggle(a, !!d.checked)} />
            ))}
          </div>
          <Button appearance="primary" disabled={busy} onClick={save} style={{ alignSelf: "flex-start" }}>저장</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
