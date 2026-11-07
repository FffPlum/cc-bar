import { useEffect, useState, type ReactNode } from "react";
import { HostAPI } from "@ccbar/host-api";
import { WindowAPI } from "@ccbar/host-api/window";
import { createMacOSTransport } from "@ccbar/host-api/macos";
import { ErrorState } from "@/components/workspace";
import { useTranslation } from "@/lib/i18n";
import { errorMessage, HostProvider } from "@/host/host-context";

export function BridgeGate({ children }: { children: ReactNode }) {
  const [attempt, setAttempt] = useState(0);
  const [session, setSession] = useState<{
    api: WindowAPI;
    host: HostAPI;
  } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const t = useTranslation();

  useEffect(() => {
    let host: HostAPI | null = null;
    let api: WindowAPI | null = null;
    try {
      host = new HostAPI(createMacOSTransport());
      api = new WindowAPI(host);
      setSession({ api, host });
      setError(null);
      return () => {
        api?.dispose();
        host?.dispose();
      };
    } catch (reason) {
      api?.dispose();
      host?.dispose();
      setError(errorMessage(reason));
      setSession(null);
    }
  }, [attempt]);

  if (error) {
    return (
      <ErrorState
        title={t(
          "CCBar’s data connection is unavailable",
          "无法连接 CCBar 数据服务",
        )}
        message={
          t(
            "Reopen this window from CCBar. If it still cannot connect, restart the app.",
            "请从 CCBar 重新打开此窗口；若仍无法连接，请重启应用。",
          ) + `\n\n${error}`
        }
        onRetry={() => setAttempt((value) => value + 1)}
      />
    );
  }
  if (!session) return null;
  return <HostProvider api={session.api}>{children}</HostProvider>;
}
