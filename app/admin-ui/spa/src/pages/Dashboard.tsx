import React from "react";
import { useMsal } from "@azure/msal-react";
import {
  Title3, Text, Dropdown, Option, Button, Spinner, Badge, tokens,
  Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell,
  MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";

interface ConsumerTokens { consumer: string; tokens: number }
interface ModelTokens { deployment: string; tokens: number }
interface ModelRequests { deployment: string; requests: number }
interface Downgrade { consumer: string; level: number }
interface DashboardData {
  total_tokens: number;
  by_consumer: ConsumerTokens[];
  by_model: ModelTokens[];
  requests_by_model: ModelRequests[];
  total_requests: number;
  error_rate: number;
  blocked_403: number;
  blocked_429: number;
  downgrades: Downgrade[];
}

const RANGES = ["1h", "24h", "7d"];

function Kpi({ label, value }: { label: string; value: string }) {
  return (
    <div style={{
      border: `1px solid ${tokens.colorNeutralStroke2}`,
      borderRadius: tokens.borderRadiusLarge,
      background: tokens.colorNeutralBackground1,
      padding: "16px 20px",
      minWidth: 180,
      flex: "1 1 180px",
    }}>
      <Text size={200} block style={{ color: tokens.colorNeutralForeground3 }}>{label}</Text>
      <Text size={700} weight="semibold" block style={{ marginTop: 4 }}>{value}</Text>
    </div>
  );
}

export default function Dashboard({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  const [range, setRange] = React.useState("24h");
  const [data, setData] = React.useState<DashboardData | null>(null);
  const [loading, setLoading] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);
  const [analyticsUrl, setAnalyticsUrl] = React.useState<string | null>(null);

  React.useEffect(() => {
    apiFetch(instance, scopes, "/api/links")
      .then(async (r) => { if (r.ok) setAnalyticsUrl((await r.json()).apimAnalyticsUrl); })
      .catch(() => { /* deep-link is best-effort */ });
  }, [instance, scopes]);

  const load = React.useCallback(() => {
    setLoading(true); setErr(null);
    apiFetch(instance, scopes, `/api/metrics/dashboard?range=${range}`)
      .then(async (r) => {
        if (!r.ok) { setErr(`load failed: ${r.status}`); return; }
        setData(await r.json());
      })
      .catch((e) => setErr(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false));
  }, [instance, scopes, range]);

  React.useEffect(() => { load(); }, [load]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 900 }}>
      <Title3>대시보드 — 사용량 &amp; 오류</Title3>
      <Text>이 대시보드는 게이트웨이 고유의 컨슈머·모델별 토큰 사용량과 오류율을 보여줍니다. 일반 API 트래픽·지역·응답코드 등 전체 분석은 Azure 포털의 APIM 네이티브 Analytics(Monitoring → Analytics)에서 확인하세요.</Text>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <Dropdown value={range} selectedOptions={[range]}
                  onOptionSelect={(_, d) => d.optionValue && setRange(d.optionValue)} style={{ minWidth: 100 }}>
          {RANGES.map((r) => <Option key={r} value={r}>{r}</Option>)}
        </Dropdown>
        <Button onClick={load} disabled={loading}>새로고침</Button>
        {analyticsUrl && (
          <Button appearance="secondary" as="a" href={analyticsUrl} target="_blank" rel="noopener noreferrer"
                  title="Azure 포털에서 APIM 리소스를 엽니다. 왼쪽 메뉴 Monitoring → Analytics에서 전체 분석을 확인하세요.">
            Azure 포털에서 APIM 열기 ↗
          </Button>
        )}
      </div>
      {err && <MessageBar intent="error"><MessageBarBody>{err}</MessageBarBody></MessageBar>}
      {loading ? <Spinner label="불러오는 중…" /> : data && (
        <>
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
            <Kpi label="총 토큰" value={data.total_tokens.toLocaleString()} />
            <Kpi label="총 요청" value={data.total_requests.toLocaleString()} />
            <Kpi label="오류율" value={`${(data.error_rate * 100).toFixed(1)}%`} />
            <Kpi label="활성 컨슈머" value={String(data.by_consumer.length)} />
            <Kpi label="모델 거부 (403)" value={(data.blocked_403 ?? 0).toLocaleString()} />
            <Kpi label="속도 초과 (429)" value={(data.blocked_429 ?? 0).toLocaleString()} />
          </div>

          <Title3>예산 강등 중인 컨슈머</Title3>
          {data.downgrades && data.downgrades.length > 0
            ? <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                {data.downgrades.map((d) => (
                  <Badge key={d.consumer} appearance="tint" color={d.level >= 2 ? "danger" : "warning"}>
                    {`${d.consumer} — ${d.level}단계`}
                  </Badge>
                ))}
              </div>
            : <Text style={{ color: tokens.colorNeutralForeground3 }}>현재 강등 중인 컨슈머가 없습니다.</Text>}
          <Title3>컨슈머별 토큰</Title3>
          <Table aria-label="컨슈머별 토큰">
            <TableHeader><TableRow>
              <TableHeaderCell>컨슈머</TableHeaderCell><TableHeaderCell>토큰</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.by_consumer.length === 0
                ? <TableRow><TableCell>—</TableCell><TableCell>0</TableCell></TableRow>
                : data.by_consumer.map((t) => (
                  <TableRow key={t.consumer || "(none)"}>
                    <TableCell>{t.consumer || "(none)"}</TableCell>
                    <TableCell>{(t.tokens ?? 0).toLocaleString()}</TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Title3>모델별 토큰 · 요청</Title3>
          <Table aria-label="모델별 토큰 및 요청">
            <TableHeader><TableRow>
              <TableHeaderCell>모델(배포)</TableHeaderCell><TableHeaderCell>토큰</TableHeaderCell><TableHeaderCell>요청 수</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.by_model.length === 0
                ? <TableRow><TableCell>—</TableCell><TableCell>0</TableCell><TableCell>0</TableCell></TableRow>
                : data.by_model.map((m) => {
                  const reqs = (data.requests_by_model ?? []).find((r) => r.deployment === m.deployment)?.requests ?? 0;
                  return (
                    <TableRow key={m.deployment || "(none)"}>
                      <TableCell>{m.deployment || "(none)"}</TableCell>
                      <TableCell>{(m.tokens ?? 0).toLocaleString()}</TableCell>
                      <TableCell>{reqs.toLocaleString()}</TableCell>
                    </TableRow>
                  );
                })}
            </TableBody>
          </Table>
        </>
      )}
    </div>
  );
}
