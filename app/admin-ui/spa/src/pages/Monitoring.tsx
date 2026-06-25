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
interface DowngradeRow {
  TimeGenerated?: string;
  Message?: string;
  consumer?: string;
  requestedModel?: string;
  effectiveModel?: string;
  downgradeLevel?: string;
}
interface MonitoringData { recent: RequestRow[]; blocked: RequestRow[]; downgrades?: DowngradeRow[] }

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
        if (!r.ok) { setErr(`Load failed: ${r.status}`); return; }
        setData(await r.json());
      })
      .catch((e) => setErr(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false));
  }, [instance, scopes, range]);

  React.useEffect(() => { load(); }, [load]);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 1000 }}>
      <Title3>Logs — recent requests &amp; blocked events</Title3>
      <Text>Shows the gateway's recent requests and 403/429 blocked events from Log Analytics. Usage aggregation may take a few minutes to appear.</Text>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <Dropdown value={range} selectedOptions={[range]}
                  onOptionSelect={(_, d) => d.optionValue && setRange(d.optionValue)} style={{ minWidth: 100 }}>
          {RANGES.map((r) => <Option key={r} value={r}>{r}</Option>)}
        </Dropdown>
        <Button onClick={load} disabled={loading}>Refresh</Button>
      </div>
      {err && <MessageBar intent="error"><MessageBarBody>{err}</MessageBarBody></MessageBar>}
      {loading ? <Spinner label="Loading…" /> : data && (
        <>
          <Text weight="semibold">Blocked events (403 / 429)</Text>
          <Table aria-label="Blocked events" size="small">
            <TableHeader><TableRow>
              <TableHeaderCell>Time</TableHeaderCell><TableHeaderCell>Operation</TableHeaderCell>
              <TableHeaderCell>Code</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.blocked.length === 0
                ? <TableRow><TableCell colSpan={3}><Text style={{ color: tokens.colorNeutralForeground3 }}>No blocked events in this period.</Text></TableCell></TableRow>
                : data.blocked.map((r, i) => (
                  <TableRow key={i}>
                    <TableCell>{fmtTime(r.TimeGenerated)}</TableCell>
                    <TableCell>{r.Name ?? "—"}</TableCell>
                    <TableCell><Badge appearance="tint" color={codeColor(r.ResultCode)}>{r.ResultCode ?? "—"}</Badge></TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Text weight="semibold">Downgrade events</Text>
          <Table aria-label="Downgrade events" size="small">
            <TableHeader><TableRow>
              <TableHeaderCell>Time</TableHeaderCell><TableHeaderCell>Consumer</TableHeaderCell>
              <TableHeaderCell>Requested</TableHeaderCell><TableHeaderCell>Effective</TableHeaderCell>
              <TableHeaderCell>Level</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {(data.downgrades ?? []).length === 0
                ? <TableRow><TableCell colSpan={5}><Text style={{ color: tokens.colorNeutralForeground3 }}>No downgrades in this period.</Text></TableCell></TableRow>
                : (data.downgrades ?? []).map((r, i) => (
                  <TableRow key={i}>
                    <TableCell>{fmtTime(r.TimeGenerated)}</TableCell>
                    <TableCell>{r.consumer || "—"}</TableCell>
                    <TableCell>{r.requestedModel || "—"}</TableCell>
                    <TableCell>{r.effectiveModel || "—"}</TableCell>
                    <TableCell><Badge appearance="tint" color="warning">{r.downgradeLevel || "—"}</Badge></TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          <Text weight="semibold">Recent requests</Text>
          <Table aria-label="Recent requests" size="small">
            <TableHeader><TableRow>
              <TableHeaderCell>Time</TableHeaderCell><TableHeaderCell>Operation</TableHeaderCell>
              <TableHeaderCell>Code</TableHeaderCell><TableHeaderCell>Duration (ms)</TableHeaderCell>
            </TableRow></TableHeader>
            <TableBody>
              {data.recent.length === 0
                ? <TableRow><TableCell colSpan={4}><Text style={{ color: tokens.colorNeutralForeground3 }}>No requests in this period.</Text></TableCell></TableRow>
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
