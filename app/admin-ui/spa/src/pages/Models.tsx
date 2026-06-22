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
  // The model list is built dynamically from the aliasModels (Terraform→BFF) keys — OpenAI +
  // Foundry OSS are auto-exposed. Keys = real model names (= APIM deployment names), used directly
  // as identifiers. Sorted by price (expensive → cheap) for display.
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
        if (!r.ok) { setMsg({ intent: "error", text: `Load failed: ${r.status}` }); return; }
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
      if (!r.ok) { setMsg({ intent: "error", text: `Save failed: ${r.status}` }); return; }
      setIsDefault(false);
      setMsg({ intent: "success", text: `Saved allowed models for consumer ${consumer}.` });
    } catch (e) {
      setMsg({ intent: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 600 }}>
      <Title3>Models — allowed models per consumer</Title3>
      <Text>Select the models this consumer may call. Requests for any other model are rejected by the gateway with 403.</Text>
      <ConsumerPicker config={config} selected={consumer} onSelect={setConsumer} />
      {consumer && (loading ? <Spinner label="Loading…" /> : (
        <>
          {isDefault && <Badge appearance="tint" color="informative">Inheriting global default (no per-consumer config yet)</Badge>}
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            {aliases.map((a) => (
              <Checkbox key={a} label={modelLabel(a, config)}
                        checked={models.includes(a)}
                        onChange={(_, d) => toggle(a, !!d.checked)} />
            ))}
          </div>
          <Button appearance="primary" disabled={busy} onClick={save} style={{ alignSelf: "flex-start" }}>Save</Button>
        </>
      ))}
      {msg && <MessageBar intent={msg.intent}><MessageBarBody>{msg.text}</MessageBarBody></MessageBar>}
    </div>
  );
}
