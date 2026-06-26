import { useMsal } from "@azure/msal-react";
import { Button, Text, tokens } from "@fluentui/react-components";
import { BotSparkleRegular, SignOutRegular } from "@fluentui/react-icons";

// Foundry-style slim top app bar: product mark + name + section breadcrumb on the left,
// signed-in user + sign out on the right.
export default function TopBar({ section }: { section: string }) {
  const { instance, accounts } = useMsal();
  return (
    <header
      style={{
        height: 48,
        flex: "0 0 48px",
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "0 16px",
        background: tokens.colorNeutralBackground1,
        borderBottom: `1px solid ${tokens.colorNeutralStroke2}`,
      }}
    >
      <BotSparkleRegular style={{ fontSize: 20, color: tokens.colorBrandForeground1 }} />
      <Text weight="semibold">AI Gateway</Text>
      <Text style={{ color: tokens.colorNeutralForeground4 }}>/</Text>
      <Text style={{ color: tokens.colorNeutralForeground2 }}>{section}</Text>
      <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 12 }}>
        <Text size={200} style={{ color: tokens.colorNeutralForeground2 }}>{accounts[0]?.name}</Text>
        <Button appearance="subtle" size="small" icon={<SignOutRegular />}
                onClick={() => instance.logoutRedirect()}>
          로그아웃
        </Button>
      </div>
    </header>
  );
}
