import React from "react";
import { useMsal } from "@azure/msal-react";
import {
  Title3, Text, Dropdown, Option, Button, Spinner, Badge,
  Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell,
  MessageBar, MessageBarBody, tokens,
} from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";

interface RequestRow {
  TimeGenerated?: string; Name?: string; ResultCode?: string; DurationMs?: number;
}
interface MonitoringData { recent: RequestRow[]; blocked: RequestRow[] }

const RANGES = ["1h", "24h", "7d"];

function codeColor(code?: string): "success" | "warning" | "danger" {
  const c = Number(code);
  if (c >= 500 || c === 403) return "danger";
  if (c >= 400) return "warning";
  return "success";
}

function fmtTime(t?: string): string {
  if (!t) return "—";
  const d = new Date(t);
  return isNaN(d.getTime()) ? t : d.toLocaleString();
}

export default function Monitoring({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  const [range, setRange] = React.useState("1h");
  const [data, setData] = React.useState<MonitoringData | null>(null);
  const [loading, setLoading] = React.useState(false);
  const [err, setErr] = React.useState<string | null>(null);

  const load = React.useCallback(() => {
    setLoading(true); setErr(null);
    apiFetch(instance, scopes, `/api/metrics/monitoring?range=${range}`)
      .then(async (r) => {
        if (!r.ok) { setErr(`불러오기 실패: ${r.status}`); return; }
        setData(await r.json());
      })
      .catch((e) => setErr(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false));
  }, [instance, scopes, range]);

  React.useEffect(() => { load(); }, [load]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 1000 }}>
      <Title3>로그 — 최근 요청 &amp; 차단 이벤트</Title3>
      <Text>게이트웨이의 최근 요청과 403/429 차단 이벤트를 Log Analytics에서 보여줍니다. 사용량 집계 반영에는 몇 분이 걸릴 수 있습니다.</Text>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <Dropdown value={range} selectedOptions={[range]}
                  onOptionSelect={(_, d) => d.optionValue && setRange(d.optionValue)} style={{ minWidth: 100 }}>
          {RANGES.map((r) => <Option key={r} value={r}>{r}</Option>)}
        </Dropdown>
        <Button onClick={load} disabled={loading}>새로고침</Button>
      </div>
      {err && <MessageBar intent="error"><MessageBarBody>{err}</MessageBarBody></MessageBar>}
      {loading ? <Spinner label="불러오는 중…" /> : data && (
        <>
          <Text weight="semibold">차단 이벤트 (403 / 429)</Text>
          <Table aria-label="차단 이벤트" size="small">
            <TableHeader><TableRow>
              <TableHeaderCell>시각</TableHeaderCell><TableHeaderCell>작업</TableHeaderCell>
              <TableHeaderCell>코드</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.blocked.length === 0
                ? <TableRow><TableCell colSpan={3}><Text style={{ color: tokens.colorNeutralForeground3 }}>기간 내 차단 이벤트가 없습니다.</Text></TableCell></TableRow>
                : data.blocked.map((r, i) => (
                  <TableRow key={i}>
                    <TableCell>{fmtTime(r.TimeGenerated)}</TableCell>
                    <TableCell>{r.Name ?? "—"}</TableCell>
                    <TableCell><Badge appearance="tint" color={codeColor(r.ResultCode)}>{r.ResultCode ?? "—"}</Badge></TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Text weight="semibold">최근 요청</Text>
          <Table aria-label="최근 요청" size="small">
            <TableHeader><TableRow>
              <TableHeaderCell>시각</TableHeaderCell><TableHeaderCell>작업</TableHeaderCell>
              <TableHeaderCell>코드</TableHeaderCell><TableHeaderCell>소요(ms)</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.recent.length === 0
                ? <TableRow><TableCell colSpan={4}><Text style={{ color: tokens.colorNeutralForeground3 }}>기간 내 요청이 없습니다.</Text></TableCell></TableRow>
                : data.recent.map((r, i) => (
                  <TableRow key={i}>
                    <TableCell>{fmtTime(r.TimeGenerated)}</TableCell>
                    <TableCell>{r.Name ?? "—"}</TableCell>
                    <TableCell><Badge appearance="tint" color={codeColor(r.ResultCode)}>{r.ResultCode ?? "—"}</Badge></TableCell>
                    <TableCell>{r.DurationMs ?? "—"}</TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
        </>
      )}
    </div>
  );
}
