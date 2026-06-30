import { Text, tokens } from "@fluentui/react-components";
import {
  DataPieRegular, PeopleTeamRegular, CubeRegular, MoneyRegular, GaugeRegular, DocumentBulletListRegular,
} from "@fluentui/react-icons";
import { Link, useLocation } from "react-router-dom";
import TopBar from "./TopBar";

type NavItem = { to: string; label: string; icon: React.ReactElement };
const NAV: { group: string; items: NavItem[] }[] = [
  {
    group: "Monitor",
    items: [
      { to: "/dashboard", label: "대시보드", icon: <DataPieRegular /> },
      { to: "/monitoring", label: "로그", icon: <DocumentBulletListRegular /> },
    ],
  },
  {
    group: "Manage",
    items: [
      { to: "/consumers", label: "컨슈머 & 키", icon: <PeopleTeamRegular /> },
      { to: "/models", label: "모델", icon: <CubeRegular /> },
      { to: "/budget", label: "예산", icon: <MoneyRegular /> },
      { to: "/limits", label: "속도 제한", icon: <GaugeRegular /> },
    ],
  },
];

const ALL = NAV.flatMap((g) => g.items);

export default function Layout({ children }: { children: React.ReactNode }) {
  const loc = useLocation();
  const section = ALL.find((n) => n.to === loc.pathname)?.label ?? "";

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}>
      <TopBar section={section} />
      <div style={{ display: "grid", gridTemplateColumns: "240px 1fr", flex: 1, minHeight: 0 }}>
        <nav
          style={{
            background: tokens.colorNeutralBackground2,
            borderRight: `1px solid ${tokens.colorNeutralStroke2}`,
            padding: "12px 8px",
            display: "flex",
            flexDirection: "column",
            gap: 4,
            overflowY: "auto",
          }}
        >
          {NAV.map((g) => (
            <div key={g.group} style={{ marginBottom: 8 }}>
              <Text
                size={200}
                style={{
                  display: "block",
                  padding: "8px 12px 4px",
                  color: tokens.colorNeutralForeground4,
                  textTransform: "uppercase",
                  letterSpacing: "0.04em",
                }}
              >
                {g.group}
              </Text>
              {g.items.map((n) => {
                const active = loc.pathname === n.to;
                return (
                  <Link
                    key={n.to}
                    to={n.to}
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 10,
                      padding: "8px 12px",
                      borderRadius: tokens.borderRadiusMedium,
                      textDecoration: "none",
                      fontSize: tokens.fontSizeBase300,
                      borderLeft: `3px solid ${active ? tokens.colorBrandStroke1 : "transparent"}`,
                      color: active ? tokens.colorNeutralForeground2BrandSelected : tokens.colorNeutralForeground2,
                      background: active ? tokens.colorBrandBackground2 : "transparent",
                      fontWeight: active ? tokens.fontWeightSemibold : tokens.fontWeightRegular,
                    }}
                  >
                    <span style={{ fontSize: 18, display: "inline-flex" }}>{n.icon}</span>
                    {n.label}
                  </Link>
                );
              })}
            </div>
          ))}
        </nav>
        <main style={{ padding: 24, overflow: "auto", background: tokens.colorNeutralBackground1 }}>
          {children}
        </main>
      </div>
    </div>
  );
}
