import React from "react";
import { useMsal } from "@azure/msal-react";
import { Dropdown, Option, Spinner, Text, tokens } from "@fluentui/react-components";
import { RuntimeConfig, apiScopes } from "../auth";
import { apiFetch } from "../api";

interface ConsumerRow { consumer: string; keyCount: number }

export default function ConsumerPicker(
  { config, selected, onSelect }:
  { config: RuntimeConfig; selected: string | null; onSelect: (t: string) => void },
) {
  const { instance } = useMsal();
  const scopes = React.useMemo(() => apiScopes(config), [config]);
  const [consumers, setConsumers] = React.useState<ConsumerRow[] | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    apiFetch(instance, scopes, "/api/consumers")
      .then(async (r) => {
        if (!r.ok) { setError(`consumers failed: ${r.status}`); return; }
        setConsumers(await r.json());
      })
      .catch((e) => setError(String(e)));
  }, [instance, scopes]);

  if (error) return <Text style={{ color: tokens.colorPaletteRedForeground1 }}>{error}</Text>;
  if (consumers === null) return <Spinner label="Loading consumers…" size="tiny" />;
  if (consumers.length === 0) return <Text>No consumers yet — register a consumer or issue a subscription key first (② Consumers & Keys).</Text>;

  return (
    <Dropdown
      placeholder="Select a consumer"
      value={selected ?? ""}
      selectedOptions={selected ? [selected] : []}
      onOptionSelect={(_, d) => d.optionValue && onSelect(d.optionValue)}
    >
      {consumers.map((t) => (
        <Option key={t.consumer} value={t.consumer}>{`${t.consumer} (${t.keyCount} key${t.keyCount === 1 ? "" : "s"})`}</Option>
      ))}
    </Dropdown>
  );
}
