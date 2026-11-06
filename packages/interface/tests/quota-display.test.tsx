import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import type { QuotaAccount, QuotaAccountsResult } from "@ccbar/host-api/window";
import { QuotaPage } from "@/features/quota/quota-page";
import { HostProvider } from "@/host/host-context";
import { LanguageProvider } from "@/lib/i18n";
import { bootstrap, deferred, makeAPI, settings } from "./fixtures";

const sessions: ReturnType<typeof makeAPI>[] = [];
afterEach(() => sessions.splice(0).forEach((session) => session.close()));

function account(id: string, patch: Partial<QuotaAccount> = {}): QuotaAccount {
  return {
    id,
    kind: "primary",
    service: "codex",
    name: id,
    subtitle: "Synthetic plan",
    plan: null,
    region: null,
    detected: true,
    current: true,
    personalAccessToken: false,
    quotaManagement: { provider: "chatgpt", isDefault: true },
    enabled: true,
    showInMenuBar: true,
    showInFloatingHUD: false,
    supportsMenuBar: true,
    supportsFloatingHUD: true,
    keychainAccessBlocked: false,
    authorizationRequired: null,
    sourceLines: [],
    sourceOwned: true,
    sourceApplication: "codex",
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

function renderQuota(accounts: QuotaAccount[], floatingEnabled = true) {
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
    accounts,
    serviceOrder: [
      "codex",
      "claude",
      "antigravity",
      "cursor",
      "commandCode",
      "opencodeGo",
      "kimi",
    ],
    floatingEnabled,
    kimiAuthorization: authorization,
    deepSeekAuthorization: authorization,
    operationError: null,
  };
  session.transport.handler = (request) => {
    if (
      request.method === "window.bootstrap" ||
      request.method === "window.navigate"
    )
      return bootstrap;
    if (request.method === "window.settings.get")
      return {
        ...settings,
        appearance: { ...settings.appearance, floatingEnabled },
      };
    if (request.method === "applications.list")
      return { applications: [], error: null };
    return result;
  };
  render(
    <LanguageProvider language="zh">
      <HostProvider api={session.api}>
        <QuotaPage />
      </HostProvider>
    </LanguageProvider>,
  );
  return session;
}

it("keeps local and manually added accounts together and marks only the local source as default", async () => {
  renderQuota([
    account("Manual ChatGPT", {
      kind: "importedCodex",
      sourceOwned: false,
      sourceApplication: null,
      quotaManagement: { provider: "chatgpt", isDefault: false },
    }),
    account("Managed Kimi", {
      kind: "managedKimi",
      service: "kimi",
      subtitle: "国内版",
      region: "china",
      sourceOwned: false,
      sourceApplication: null,
      quotaManagement: { provider: "kimi", isDefault: false },
    }),
    account("Local ChatGPT"),
    account("Local Kimi", {
      service: "kimi",
      subtitle: "Primary synthetic plan",
      region: "china",
      sourceApplication: "kimi",
      quotaManagement: { provider: "kimi", isDefault: true },
    }),
  ]);

  const chatgpt = await screen.findByRole("region", { name: "ChatGPT" });
  const kimi = screen.getByRole("region", { name: "Kimi Code" });
  expect(
    within(chatgpt)
      .getAllByRole("heading", { level: 3 })
      .map((node) => node.textContent),
  ).toEqual(["Local ChatGPT", "Manual ChatGPT"]);
  expect(
    within(kimi)
      .getAllByRole("heading", { level: 3 })
      .map((node) => node.textContent),
  ).toEqual(["Local Kimi", "Managed Kimi"]);
  for (const group of [chatgpt, kimi]) {
    expect(within(group).getAllByText("默认")).toHaveLength(1);
  }
  for (const name of ["Manual ChatGPT", "Managed Kimi"]) {
    const heading = screen.getByRole("heading", { name });
    expect(within(heading.parentElement!).queryByText("默认")).toBeNull();
  }
  expect(screen.queryByText("Kimi 在用")).toBeNull();
  expect(screen.queryByRole("heading", { name: "已连接账号" })).toBeNull();
  expect(screen.queryByRole("heading", { name: "连接订阅账号" })).toBeNull();
  expect(screen.getByText("国内版", { exact: true })).toBeTruthy();
  expect(screen.queryByText("国内版 · 国内版")).toBeNull();
  expect(screen.getByText("Primary synthetic plan · 国内版")).toBeTruthy();
  expect(screen.queryByRole("switch")).toBeNull();
  expect(screen.queryByText("额度显示")).toBeNull();
});

it("retains all six provider groups, login guidance and brand placeholders when no accounts or icons are available", async () => {
  renderQuota([]);
  await screen.findByRole("region", { name: "Claude" });
  const names = [
    "Claude",
    "ChatGPT",
    "Kimi Code",
    "xAI",
    "DeepSeek Harness",
    "Antigravity",
  ];
  expect(
    screen
      .getAllByRole("region")
      .map((group) => group.getAttribute("aria-labelledby")),
  ).toEqual(
    names.map((name) => screen.getByRole("heading", { name, exact: true }).id),
  );
  for (const name of names) {
    const group = screen.getByRole("region", { name, exact: true });
    expect(within(group).getByText("暂无账号")).toBeTruthy();
    expect(within(group).getByText(/登录.*后自动读取/)).toBeTruthy();
    const placeholder = within(group).getByText(name[0]!.toUpperCase(), {
      exact: true,
    });
    expect(placeholder.getAttribute("aria-hidden")).toBe("true");
  }
  expect(screen.getAllByRole("button", { name: "添加账号" })).toHaveLength(3);
  expect(screen.queryByRole("switch")).toBeNull();
});

it("excludes unsupported credentials and providers even when they are detected or mirror a current account", async () => {
  renderQuota([
    account("OAuth account"),
    account("Imported PAT", {
      kind: "importedCodex",
      personalAccessToken: true,
      quotaManagement: null,
    }),
    account("Kimi API Key", { service: "kimi", quotaManagement: null }),
    account("Cursor account", { service: "cursor", quotaManagement: null }),
    account("Gemini account", {
      kind: "localLogin",
      service: "gemini",
      quotaManagement: null,
    }),
    account("Legacy account without metadata", { quotaManagement: undefined }),
  ]);
  await screen.findByRole("heading", { name: "OAuth account" });
  expect(screen.getAllByRole("heading", { level: 3 })).toHaveLength(1);
  for (const name of [
    "Imported PAT",
    "Kimi API Key",
    "Cursor account",
    "Gemini account",
    "Legacy account without metadata",
  ]) {
    expect(screen.queryByRole("heading", { name })).toBeNull();
  }
});

it("keeps xAI login identity read-only until quota is supported and links to its application", async () => {
  const { transport } = renderQuota([
    account("Local Grok", {
      kind: "localLogin",
      service: "grok",
      current: false,
      enabled: false,
      showInMenuBar: false,
      showInFloatingHUD: false,
      supportsMenuBar: false,
      supportsFloatingHUD: false,
      sourceApplication: "grok",
      quotaManagement: { provider: "xai", isDefault: true },
    }),
  ]);
  const group = await screen.findByRole("region", { name: "xAI" });
  expect(within(group).getByText("默认")).toBeTruthy();
  expect(within(group).getByText("暂未接入额度查询")).toBeTruthy();
  for (const name of ["Local Grok 菜单栏", "Local Grok 悬浮窗"]) {
    expect(
      within(group)
        .getByRole("checkbox", { name })
        .getAttribute("aria-disabled"),
    ).toBe("true");
  }
  expect(within(group).queryByRole("switch")).toBeNull();
  fireEvent.click(within(group).getByRole("button", { name: "更多操作" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "应用配置" }));
  await waitFor(() =>
    expect(
      transport.requests.find((request) => request.method === "window.navigate")
        ?.params,
    ).toEqual({ route: { page: "application", application: "grok" } }),
  );
  expect(
    transport.requests.some(
      (request) => request.method === "quota.updateAccount",
    ),
  ).toBe(false);
});

it("preserves account display changes without moving a manual account into a separate group", async () => {
  const { transport } = renderQuota([
    account("Manual ChatGPT", {
      kind: "importedCodex",
      quotaManagement: { provider: "chatgpt", isDefault: false },
      sourceOwned: false,
      sourceApplication: null,
    }),
  ]);
  const group = await screen.findByRole("region", { name: "ChatGPT" });
  fireEvent.click(
    within(group).getByRole("checkbox", { name: "Manual ChatGPT 菜单栏" }),
  );
  await waitFor(() =>
    expect(
      transport.requests.find(
        (request) => request.method === "quota.updateAccount",
      )?.params,
    ).toEqual({ id: "Manual ChatGPT", patch: { showInMenuBar: false } }),
  );
  expect(
    within(group).getByRole("heading", { name: "Manual ChatGPT" }),
  ).toBeTruthy();
  expect(within(group).queryByText("默认")).toBeNull();
});

it.each([
  { label: "菜单栏", field: "showInMenuBar", checked: false },
  { label: "菜单栏", field: "showInMenuBar", checked: true },
  { label: "悬浮窗", field: "showInFloatingHUD", checked: false },
  { label: "悬浮窗", field: "showInFloatingHUD", checked: true },
] as const)(
  "changes $label independently from $checked while the legacy account and desktop window are disabled",
  async ({ label, field, checked }) => {
    const { transport } = renderQuota(
      [
        account("Local ChatGPT", {
          enabled: false,
          showInMenuBar: false,
          showInFloatingHUD: false,
          [field]: checked,
        }),
      ],
      false,
    );
    const checkbox = await screen.findByRole("checkbox", {
      name: `Local ChatGPT ${label}`,
    });
    expect(checkbox.getAttribute("aria-disabled")).not.toBe("true");
    expect(screen.queryByRole("switch")).toBeNull();
    fireEvent.click(checkbox);
    await waitFor(() =>
      expect(
        transport.requests.find(
          (request) => request.method === "quota.updateAccount",
        )?.params,
      ).toEqual({
        id: "Local ChatGPT",
        patch: { [field]: !checked },
      }),
    );
    expect(
      transport.requests.some(
        (request) => request.method === "window.settings.update",
      ),
    ).toBe(false);
    expect(
      screen.getByText("桌面悬浮窗已关闭，菜单栏展开面板仍会显示选中的账号。"),
    ).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "前往设置" }));
    await waitFor(() =>
      expect(
        transport.requests.find(
          (request) => request.method === "window.navigate",
        )?.params,
      ).toEqual({ route: { page: "settings" } }),
    );
  },
);

it("disables both destinations while an account change is pending without sending another update", async () => {
  const { transport } = renderQuota([
    account("Local ChatGPT", {
      enabled: false,
      showInMenuBar: false,
      showInFloatingHUD: false,
    }),
  ]);
  const pending = deferred<void>();
  const handle = transport.handler;
  transport.handler = (request) =>
    request.method === "quota.updateAccount"
      ? pending.promise.then(() => handle(request))
      : handle(request);
  const menuBar = await screen.findByRole("checkbox", {
    name: "Local ChatGPT 菜单栏",
  });
  const floating = screen.getByRole("checkbox", {
    name: "Local ChatGPT 悬浮窗",
  });
  fireEvent.click(menuBar);
  expect(menuBar.getAttribute("aria-disabled")).toBe("true");
  expect(floating.getAttribute("aria-disabled")).toBe("true");
  await waitFor(() =>
    expect(
      transport.requests.filter(
        (request) => request.method === "quota.updateAccount",
      ),
    ).toHaveLength(1),
  );
  fireEvent.click(floating);
  expect(
    transport.requests.filter(
      (request) => request.method === "quota.updateAccount",
    ),
  ).toHaveLength(1);
  await act(async () => pending.resolve());
  await waitFor(() =>
    expect(floating.getAttribute("aria-disabled")).not.toBe("true"),
  );
});

it("reorders visible imported accounts across a hidden PAT while preserving the full host order", async () => {
  const { transport } = renderQuota([
    account("First OAuth", {
      kind: "importedCodex",
      quotaManagement: { provider: "chatgpt", isDefault: false },
    }),
    account("Hidden PAT", {
      kind: "importedCodex",
      personalAccessToken: true,
      quotaManagement: null,
    }),
    account("Second OAuth", {
      kind: "importedCodex",
      quotaManagement: { provider: "chatgpt", isDefault: false },
    }),
  ]);
  const group = await screen.findByRole("region", { name: "ChatGPT" });
  fireEvent.keyDown(
    within(group).getAllByRole("button", { name: "拖动以排序" })[0]!,
    {
      key: "ArrowDown",
      altKey: true,
    },
  );
  await waitFor(() =>
    expect(
      transport.requests.find((request) => request.method === "quota.reorder")
        ?.params,
    ).toEqual({
      serviceOrder: [
        "codex",
        "claude",
        "antigravity",
        "cursor",
        "commandCode",
        "opencodeGo",
        "kimi",
      ],
      importedCodexOrder: ["Second OAuth", "Hidden PAT", "First OAuth"],
    }),
  );
});
