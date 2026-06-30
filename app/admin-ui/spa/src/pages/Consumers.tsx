import React from "react";
import { useMsal } from "@azure/msal-react";
import {
  Title3, Text, Input, Button, Spinner, Badge, tokens,
  Table, TableHeader, TableRow, TableHeaderCell, TableBody, TableCell,
  MessageBar, MessageBarBody,
} from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";

interface ConsumerRow {
  consumer: string;
  keyCount: number;
  displayName: string | null;
  entraGroupId: string | null;
  hasConfig: boolean;
  source: "registry" | "keys" | "both";
}

interface KeyRow { id: string; displayName: string; state: string; consumer: string | null }

const GUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const UNASSIGNED = "(unassigned)";

export default function Consumers({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  const [consumers, setConsumers] = React.useState<ConsumerRow[] | null>(null);
  const [keys, setKeys] = React.useState<KeyRow[]>([]);
  const [expanded, setExpanded] = React.useState<Set<string>>(new Set());
  const [consumer, setConsumer] = React.useState("");
  const [groupId, setGroupId] = React.useState("");
  const [displayName, setDisplayName] = React.useState("");
  const [keyConsumer, setKeyConsumer] = React.useState("");
  const [issued, setIssued] = React.useState<{ consumer: string; primaryKey: string } | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [msg, setMsg] = React.useState<{ intent: "success" | "error" | "warning"; text: string } | null>(null);

  const load = React.useCallback(async () => {
    const [tr, kr] = await Promise.all([
      apiFetch(instance, scopes, "/api/consumers"),
      apiFetch(instance, scopes, "/api/keys"),
    ]);
    if (!tr.ok) { setMsg({ intent: "error", text: `consumers failed: ${tr.status}` }); return; }
    if (!kr.ok) { setMsg({ intent: "error", text: `keys failed: ${kr.status}` }); return; }
    setConsumers(await tr.json());
    setKeys(await kr.json());
  }, [instance, scopes]);

  React.useEffect(() => { load(); }, [load]);

  // Keys grouped by consumer; null-consumer keys collected under UNASSIGNED.
  const keysByConsumer = React.useMemo(() => {
    const m = new Map<string, KeyRow[]>();
    for (const k of keys) {
      const t = k.consumer ?? UNASSIGNED;
      const list = m.get(t) ?? [];
      list.push(k);
      m.set(t, list);
    }
    return m;
  }, [keys]);

  // Display rows: the consumers list (already a union of key-derived + registry consumers), plus a
  // synthetic UNASSIGNED row only if there are keys with no consumer.
  const displayConsumers = React.useMemo(() => {
    const rows = consumers ? [...consumers] : [];
    if (keysByConsumer.has(UNASSIGNED) && !rows.some((r) => r.consumer === UNASSIGNED)) {
      rows.push({ consumer: UNASSIGNED, keyCount: keysByConsumer.get(UNASSIGNED)!.length,
                  displayName: null, entraGroupId: null, hasConfig: false, source: "keys" });
    }
    return rows;
  }, [consumers, keysByConsumer]);

  function toggle(t: string) {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.has(t) ? next.delete(t) : next.add(t);
      return next;
    });
  }

  async function registerConsumer() {
    if (busy) return;
    if (!consumer.trim()) { setMsg({ intent: "error", text: "consumer is required" }); return; }
    if (groupId.trim() && !GUID_RE.test(groupId.trim())) {
      setMsg({ intent: "error", text: "Entra group ID must be a GUID" }); return;
    }
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, "/api/consumers", {
        method: "POST",
        body: JSON.stringify({ consumer: consumer.trim(),
                               entra_group_id: groupId.trim() || undefined,
                               display_name: displayName.trim() || undefined }),
      });
      if (r.status !== 201) {
        const b = await r.json().catch(() => ({}));
        setMsg({ intent: "error", text: `register failed: ${r.status} ${b.detail ?? ""}` });
        return;
      }
      setConsumer(""); setGroupId(""); setDisplayName("");
      setMsg({ intent: "success", text: `컨슈머 '${consumer.trim()}'을(를) 등록했습니다.` });
      load();
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  async function issueKey(forConsumer: string) {
    if (busy) return;
    if (!forConsumer.trim()) { setMsg({ intent: "error", text: "키를 발급하려면 컨슈머가 필요합니다" }); return; }
    setBusy(true); setMsg(null); setIssued(null);
    try {
      const r = await apiFetch(instance, scopes, "/api/keys", {
        method: "POST", body: JSON.stringify({ consumer: forConsumer.trim() }),
      });
      if (r.status !== 201) {
        const b = await r.json().catch(() => ({}));
        setMsg({ intent: "error", text: `issue failed: ${r.status} ${b.detail ?? ""}` });
        return;
      }
      const body = await r.json();
      setIssued({ consumer: body.consumer, primaryKey: body.primaryKey });
      setKeyConsumer("");
      setExpanded((prev) => new Set(prev).add(forConsumer.trim()));
      load();
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  async function editGroup(t: ConsumerRow) {
    if (busy) return;
    const next = window.prompt(`New Entra group GUID for '${t.consumer}' (leave blank to keep):`, t.entraGroupId ?? "");
    if (next === null) return;
    if (!GUID_RE.test(next.trim())) { setMsg({ intent: "error", text: "Entra group ID must be a GUID" }); return; }
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, `/api/consumers/${encodeURIComponent(t.consumer)}`, {
        method: "PUT", body: JSON.stringify({ entra_group_id: next.trim() }),
      });
      if (!r.ok) {
        const b = await r.json().catch(() => ({}));
        setMsg({ intent: "error", text: `update failed: ${r.status} ${b.detail ?? ""}` });
        return;
      }
      setMsg({ intent: "success", text: `Updated '${t.consumer}'.` });
      load();
    } finally {
      setBusy(false);
    }
  }

  async function deleteConsumer(t: ConsumerRow) {
    if (busy) return;
    if (!window.confirm(`Delete consumer registration '${t.consumer}'? Keys and config are NOT removed.`)) return;
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, `/api/consumers/${encodeURIComponent(t.consumer)}`, { method: "DELETE" });
      if (!r.ok) { setMsg({ intent: "error", text: `delete failed: ${r.status}` }); return; }
      const b = await r.json();
      setMsg(b.warning ? { intent: "warning", text: b.warning }
                       : { intent: "success", text: `Deleted '${t.consumer}'.` });
      load();
    } finally {
      setBusy(false);
    }
  }

  async function revokeKey(id: string) {
    if (busy) return;
    if (!window.confirm(`Revoke key '${id}'? This cannot be undone.`)) return;
    setBusy(true); setMsg(null);
    try {
      const r = await apiFetch(instance, scopes, `/api/keys/${id}`, { method: "DELETE" });
      if (r.status !== 204) { setMsg({ intent: "error", text: `revoke failed: ${r.status}` }); return; }
      load();
    } finally {
      setBusy(false);
    }
  }

  function sourceBadge(t: ConsumerRow) {
    if (t.consumer === UNASSIGNED) return <Badge appearance="tint" color="danger">컨슈머 미지정</Badge>;
    if (t.source === "keys") return <Badge appearance="tint" color="warning">Entra 그룹 미연동</Badge>;
    if (t.source === "registry") return <Badge appearance="tint" color="informative">키 없음</Badge>;
    return <Badge appearance="tint" color="success">연동됨</Badge>;
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 1100 }}>
      <Title3>컨슈머 &amp; 키</Title3>
      <Text>컨슈머를 등록·관리하고, 각 컨슈머의 APIM 구독을 발급·폐기합니다. 발급 시 구독 ID(예: vk-…)와 구독 키가 생기며, 키는 발급 순간 한 번만 표시됩니다. 컨슈머 행을 펼치면 그 컨슈머의 구독 ID가 보입니다. Entra 그룹 ID는 선택 사항이며 Entra ID 인증 모드에서만 사용됩니다(현재는 구독 키 모드).</Text>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
        <Input placeholder="컨슈머 이름 (예: payments)" value={consumer} onChange={(_, d) => setConsumer(d.value)} />
        <Input placeholder="Entra 그룹 GUID (선택)" value={groupId} onChange={(_, d) => setGroupId(d.value)} style={{ minWidth: 300 }} />
        <Input placeholder="표시 이름 (선택)" value={displayName} onChange={(_, d) => setDisplayName(d.value)} />
        <Button appearance="primary" disabled={busy} onClick={registerConsumer}>컨슈머 등록</Button>
      </div>
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <Input placeholder="키를 발급할 컨슈머 이름" value={keyConsumer} onChange={(_, d) => setKeyConsumer(d.value)} />
        <Button disabled={busy} onClick={() => issueKey(keyConsumer)}>API 키 발급</Button>
      </div>

      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
      {issued && (
        <MessageBar intent="success">
          <MessageBarBody>
            <b>{issued.consumer}</b> 컨슈머의 키가 발급되었습니다. 지금 복사하세요 — 다시 표시되지 않습니다:
            <pre style={{ whiteSpace: "pre-wrap" }}>{issued.primaryKey}</pre>
          </MessageBarBody>
        </MessageBar>
      )}

      {consumers === null ? <Spinner label="불러오는 중…" /> : (
        <Table aria-label="컨슈머 및 키">
          <TableHeader><TableRow>
            <TableHeaderCell style={{ width: 40 }} />
            <TableHeaderCell>컨슈머 / 키</TableHeaderCell>
            <TableHeaderCell>Entra 그룹 ID</TableHeaderCell>
            <TableHeaderCell>키</TableHeaderCell>
            <TableHeaderCell>설정</TableHeaderCell>
            <TableHeaderCell>상태</TableHeaderCell>
            <TableHeaderCell>작업</TableHeaderCell>
          </TableRow></TableHeader>
          <TableBody>
            {displayConsumers.length === 0
              ? <TableRow><TableCell>아직 컨슈머가 없습니다 — 위에서 컨슈머를 등록하거나 키를 발급하세요.</TableCell></TableRow>
              : displayConsumers.flatMap((t) => {
                const consumerKeys = keysByConsumer.get(t.consumer) ?? [];
                const isOpen = expanded.has(t.consumer);
                const rows = [
                  <TableRow key={t.consumer}>
                    <TableCell>
                      <Button size="small" appearance="subtle" onClick={() => toggle(t.consumer)}
                              disabled={consumerKeys.length === 0}>{isOpen ? "▼" : "▶"}</Button>
                    </TableCell>
                    <TableCell>
                      {t.consumer === UNASSIGNED
                        ? <Text>{t.consumer} <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>· 컨슈머 라벨 없는 키 (펼쳐서 폐기)</Text></Text>
                        : <>{t.consumer}{t.displayName ? ` (${t.displayName})` : ""}</>}
                    </TableCell>
                    <TableCell>{t.entraGroupId ?? "—"}</TableCell>
                    <TableCell>{t.keyCount}</TableCell>
                    <TableCell>{t.hasConfig ? "✓" : "—"}</TableCell>
                    <TableCell>{sourceBadge(t)}</TableCell>
                    <TableCell>
                      {t.consumer !== UNASSIGNED && (
                        <>
                          <Button size="small" disabled={busy} onClick={() => editGroup(t)}>그룹 수정</Button>{" "}
                          <Button size="small" disabled={busy} onClick={() => issueKey(t.consumer)}>+ 키</Button>{" "}
                          {t.source !== "keys"
                            ? <Button size="small" disabled={busy} onClick={() => deleteConsumer(t)}>삭제</Button>
                            : <Text size={200} style={{ color: tokens.colorNeutralForeground3 }}>키로만 존재 · 키 폐기로 제거</Text>}
                        </>
                      )}
                    </TableCell>
                  </TableRow>,
                ];
                if (isOpen) {
                  for (const k of consumerKeys) {
                    rows.push(
                      <TableRow key={k.id}>
                        <TableCell />
                        <TableCell>↳ {k.id}</TableCell>
                        <TableCell />
                        <TableCell />
                        <TableCell />
                        <TableCell>{k.state}</TableCell>
                        <TableCell>
                          <Button size="small" disabled={busy} onClick={() => revokeKey(k.id)}>키 폐기</Button>
                        </TableCell>
                      </TableRow>,
                    );
                  }
                }
                return rows;
              })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
