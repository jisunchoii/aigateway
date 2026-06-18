import { IPublicClientApplication } from "@azure/msal-browser";

// Acquires an access token for the BFF scope (silent, falling back to popup) and calls /api/*.
export async function apiFetch(
  msal: IPublicClientApplication,
  scopes: string[],
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const account = msal.getAllAccounts()[0];
  if (!account) {
    await msal.loginRedirect({ scopes });
    return new Response(null, { status: 401 });
  }
  const result = await msal.acquireTokenSilent({ scopes, account }).catch(() =>
    msal.acquireTokenPopup({ scopes }),
  );
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${result.accessToken}`);
  if (init.body) headers.set("Content-Type", "application/json");
  return fetch(path, { ...init, headers });
}
