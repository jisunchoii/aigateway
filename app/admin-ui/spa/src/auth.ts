import { PublicClientApplication } from "@azure/msal-browser";

export interface ModelPrice { prompt: number; completion: number; }  // USD per 1K tokens

export interface RuntimeConfig {
  tenantId: string;
  clientId: string;
  apiScope: string;
  aliasModels?: Record<string, string>;        // model id -> display label (from /api/config)
  modelPrices?: Record<string, ModelPrice>;     // model id -> per-1K price (from /api/config)
}

export async function loadConfig(): Promise<RuntimeConfig> {
  const res = await fetch("/api/config");
  if (!res.ok) throw new Error(`failed to load config: ${res.status}`);
  return res.json();
}

export function makeMsal(cfg: RuntimeConfig): PublicClientApplication {
  return new PublicClientApplication({
    auth: {
      clientId: cfg.clientId,
      authority: `https://login.microsoftonline.com/${cfg.tenantId}`,
      redirectUri: window.location.origin,
    },
    cache: { cacheLocation: "sessionStorage" },
  });
}

export const apiScopes = (cfg: RuntimeConfig): string[] => [cfg.apiScope];
