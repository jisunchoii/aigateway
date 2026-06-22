import { RuntimeConfig } from "./auth";

/** Return the list of model ids sorted by price (expensive → cheap). Descending completion
 *  unit price is the primary key (output tokens dominate cost); prompt unit price is the
 *  tiebreak. Models with no price go last. Operates on all config.aliasModels keys, reading
 *  unit prices from modelPrices. (Shared by the Models and Budget pages.) */
export function modelsByPrice(config: RuntimeConfig): string[] {
  const ids = Object.keys(config.aliasModels ?? {});
  const prices = config.modelPrices ?? {};
  const rank = (id: string): [number, number] => {
    const p = prices[id];
    return p ? [p.completion, p.prompt] : [-1, -1]; // no price → treat as lowest, sort last
  };
  return ids.slice().sort((a, b) => {
    const [ac, ap] = rank(a);
    const [bc, bp] = rank(b);
    if (bc !== ac) return bc - ac;       // higher completion price first
    if (bp !== ap) return bp - ap;       // higher prompt price first
    return a.localeCompare(b);           // tie → by name (stable)
  });
}

/** Checkbox/label text for a model id, e.g. "gpt-5.4 (GPT-5.4 · in $2.50 / out $15 per 1M)".
 *  The display label is only appended when it adds information (not equal to the id), and the
 *  price only when configured — so it degrades to just the id when neither is present.
 *  Prices are stored per 1K tokens; shown per 1M (×1000) for human readability. */
export function modelLabel(id: string, config: RuntimeConfig): string {
  const label = config.aliasModels?.[id];
  const price = config.modelPrices?.[id];
  const parts: string[] = [];
  if (label && label !== id) parts.push(label);
  if (price) {
    const inM = (price.prompt * 1000).toLocaleString(undefined, { maximumFractionDigits: 2 });
    const outM = (price.completion * 1000).toLocaleString(undefined, { maximumFractionDigits: 2 });
    parts.push(`in $${inM} / out $${outM} per 1M`);
  }
  return parts.length ? `${id} (${parts.join(" · ")})` : id;
}
