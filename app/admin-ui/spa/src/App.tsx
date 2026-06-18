import {
  AuthenticatedTemplate,
  UnauthenticatedTemplate,
  useMsal,
} from "@azure/msal-react";
import { Button } from "@fluentui/react-components";
import { Routes, Route, Navigate } from "react-router-dom";
import { RuntimeConfig, apiScopes } from "./auth";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Consumers from "./pages/Consumers";
import Models from "./pages/Models";
import Budget from "./pages/Budget";
import RateLimits from "./pages/RateLimits";
import Monitoring from "./pages/Monitoring";

export default function App({ config }: { config: RuntimeConfig }) {
  const { instance } = useMsal();
  return (
    <>
      <UnauthenticatedTemplate>
        <div style={{ display: "grid", placeItems: "center", height: "100vh" }}>
          <Button appearance="primary" onClick={() => instance.loginRedirect({ scopes: apiScopes(config) })}>
            Sign in with Entra ID
          </Button>
        </div>
      </UnauthenticatedTemplate>
      <AuthenticatedTemplate>
        <Layout>
          <Routes>
            <Route path="/" element={<Navigate to="/consumers" replace />} />
            <Route path="/dashboard" element={<Dashboard config={config} />} />
            <Route path="/consumers" element={<Consumers config={config} />} />
            <Route path="/models" element={<Models config={config} />} />
            <Route path="/budget" element={<Budget config={config} />} />
            <Route path="/limits" element={<RateLimits config={config} />} />
            <Route path="/monitoring" element={<Monitoring config={config} />} />
            <Route path="/keys" element={<Navigate to="/consumers" replace />} />
          </Routes>
        </Layout>
      </AuthenticatedTemplate>
    </>
  );
}
