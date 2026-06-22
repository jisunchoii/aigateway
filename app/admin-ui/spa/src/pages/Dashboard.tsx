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
      <Title3>Dashboard — usage &amp; errors</Title3>
      <Text>This dashboard shows the gateway's own per-consumer and per-model token usage and error rate. For full analytics (overall API traffic, regions, response codes), use APIM's native Analytics in the Azure portal (Monitoring → Analytics).</Text>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <Dropdown value={range} selectedOptions={[range]}
                  onOptionSelect={(_, d) => d.optionValue && setRange(d.optionValue)} style={{ minWidth: 100 }}>
          {RANGES.map((r) => <Option key={r} value={r}>{r}</Option>)}
        </Dropdown>
        <Button onClick={load} disabled={loading}>Refresh</Button>
        {analyticsUrl && (
          <Button appearance="secondary" as="a" href={analyticsUrl} target="_blank" rel="noopener noreferrer"
                  title="Opens the APIM resource in the Azure portal. See full analytics under Monitoring → Analytics in the left menu.">
            Open APIM in Azure portal ↗
          </Button>
        )}
      </div>
      {err && <MessageBar intent="error"><MessageBarBody>{err}</MessageBarBody></MessageBar>}
      {loading ? <Spinner label="Loading…" /> : data && (
        <>
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
            <Kpi label="Total tokens" value={data.total_tokens.toLocaleString()} />
            <Kpi label="Total requests" value={data.total_requests.toLocaleString()} />
            <Kpi label="Error rate" value={`${(data.error_rate * 100).toFixed(1)}%`} />
            <Kpi label="Active consumers" value={String(data.by_consumer.length)} />
            <Kpi label="Model rejections (403)" value={(data.blocked_403 ?? 0).toLocaleString()} />
            <Kpi label="Rate exceeded (429)" value={(data.blocked_429 ?? 0).toLocaleString()} />
          </div>

          <Title3>Consumers under budget downgrade</Title3>
          {data.downgrades && data.downgrades.length > 0
            ? <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                {data.downgrades.map((d) => (
                  <Badge key={d.consumer} appearance="tint" color={d.level >= 2 ? "danger" : "warning"}>
                    {`${d.consumer} — level ${d.level}`}
                  </Badge>
                ))}
              </div>
            : <Text style={{ color: tokens.colorNeutralForeground3 }}>No consumers are currently downgraded.</Text>}
          <Title3>Tokens by consumer</Title3>
          <Table aria-label="Tokens by consumer">
            <TableHeader><TableRow>
              <TableHeaderCell>Consumer</TableHeaderCell><TableHeaderCell>Tokens</TableHeaderCell>
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
          <Title3>Tokens · requests by model</Title3>
          <Table aria-label="Tokens and requests by model">
            <TableHeader><TableRow>
              <TableHeaderCell>Model (deployment)</TableHeaderCell><TableHeaderCell>Tokens</TableHeaderCell><TableHeaderCell>Requests</TableHeaderCell>
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
