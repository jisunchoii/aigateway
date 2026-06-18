import React from "react";
import ReactDOM from "react-dom/client";
import { MsalProvider } from "@azure/msal-react";
import { FluentProvider, webLightTheme, Spinner } from "@fluentui/react-components";
import { BrowserRouter } from "react-router-dom";
import { loadConfig, makeMsal, RuntimeConfig } from "./auth";
import App from "./App";

function Root() {
  const [cfg, setCfg] = React.useState<RuntimeConfig | null>(null);
  const [msal, setMsal] = React.useState<ReturnType<typeof makeMsal> | null>(null);
  const [configError, setConfigError] = React.useState<string | null>(null);

  React.useEffect(() => {
    loadConfig().then(async (c) => {
      const instance = makeMsal(c);
      await instance.initialize();
      setCfg(c);
      setMsal(instance);
    }).catch((e) => setConfigError(String(e)));
  }, []);

  if (configError)
    return (
      <div style={{ display: "grid", placeItems: "center", height: "100vh", padding: 24 }}>
        Failed to load app config: {configError}
      </div>
    );
  if (!cfg || !msal) return <Spinner label="Loading…" />;
  return (
    <MsalProvider instance={msal}>
      <FluentProvider theme={webLightTheme} style={{ height: "100vh" }}>
        <BrowserRouter>
          <App config={cfg} />
        </BrowserRouter>
      </FluentProvider>
    </MsalProvider>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
