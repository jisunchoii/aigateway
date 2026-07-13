import { RuntimeConfig } from "./auth";

/** 모델 id 목록을 가격순(비쌈 → 쌈)으로 정렬해 반환. completion 단가 내림차순이 1차 기준(출력
 *  토큰이 비용을 지배), prompt 단가가 tiebreak. 단가가 없는 모델은 맨 뒤로. config.aliasModels의
 *  키 전체가 대상이며, modelPrices에서 단가를 읽는다. (Models·Budget 페이지가 공유) */
export function modelsByPrice(config: RuntimeConfig): string[] {
  const ids = Object.keys(config.aliasModels ?? {});
  const prices = config.modelPrices ?? {};
  const rank = (id: string): [number, number] => {
    const p = prices[id];
    return p ? [p.completion, p.prompt] : [-1, -1]; // 단가 없으면 가장 낮게 → 뒤로
  };
  return ids.slice().sort((a, b) => {
    const [ac, ap] = rank(a);
    const [bc, bp] = rank(b);
    if (bc !== ac) return bc - ac;       // completion 단가 비쌈 먼저
    if (bp !== ap) return bp - ap;       // prompt 단가 비쌈 먼저
    return a.localeCompare(b);           // 동률이면 이름순(안정적)
  });
}

/** Checkbox/label text for a model id, e.g. "gpt-5.6-sol (GPT-5.6 Sol - in $2.50 / out $15 per 1M)".
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
