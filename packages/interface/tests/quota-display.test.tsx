import { render, screen, within } from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import type { QuotaAccount, QuotaAccountsResult } from "@ccbar/host-api/window";
import { QuotaPage } from "@/features/quota/quota-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, makeAPI, settings } from "./fixtures";
const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));
function account(id: string, patch: Partial<QuotaAccount>): QuotaAccount {
  return {
    id,
    kind: "primary",
    service: "codex",
    name: "Codex",
    subtitle: "Synthetic plan",
    plan: null,
    region: null,
    detected: true,
    current: true,
    personalAccessToken: false,
    enabled: true,
    showInMenuBar: true,
    showInFloatingHUD: false,
    supportsMenuBar: true,
    supportsFloatingHUD: true,
    keychainAccessBlocked: false,
    authorizationRequired: null,
    sourceLines: [],
    sourceOwned: false,
    sourceApplication: null,
    needsRefresh: false,
    snapshot: null,
    balance: null,
    refresh: {
      inFlight: false,
      backoffUntil: null,
      lastSuccessAt: null,
      lastAttemptAt: null,
      failed: false,
      source: null,
      error: null,
    },
    ...patch,
  };
}
it("keeps Kimi current badges specific to Kimi and renders each region once", async () => {
  const session = makeAPI();
  sessions.push(session);
  const authorization = {
    inProgress: false,
    awaitingBrowser: false,
    error: null,
    region: null,
    replacingAccountID: null,
  };
  const result: QuotaAccountsResult = {
    accounts: [
      account("codex", {}),
      account("kimi", {
        service: "kimi",
        name: "Kimi Code",
        subtitle: "Primary synthetic plan",
        region: "china",
      }),
      account("managed", {
        kind: "managedKimi",
        service: "kimi",
        name: "Managed Kimi",
        subtitle: "国内版",
        region: "china",
      }),
    ],
    serviceOrder: ["codex", "kimi"],
    floatingEnabled: false,
    kimiAuthorization: authorization,
    deepSeekAuthorization: authorization,
    operationError: null,
  };
  session.transport.handler = (request) =>
    request.method === "window.bootstrap"
      ? bootstrap
      : request.method === "window.settings.get"
        ? settings
        : request.method === "applications.list"
          ? { applications: [], error: null }
          : result;
  render(
    <LanguageProvider language="zh">
      <HostProvider api={session.api}>
        <QuotaPage />
      </HostProvider>
    </LanguageProvider>,
  );
  const codex = await screen.findByRole("heading", { name: "Codex" });
  expect(within(codex.parentElement!).queryByText(/在用/)).toBeNull();
  expect(screen.getAllByText("Kimi 在用")).toHaveLength(2);
  expect(screen.getByText("国内版", { exact: true })).toBeTruthy();
  expect(screen.queryByText("国内版 · 国内版")).toBeNull();
  expect(screen.getByText("Primary synthetic plan · 国内版")).toBeTruthy();
});
