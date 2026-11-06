import type {
  ApplicationID,
  QuotaAccount,
  QuotaManagementProvider,
  ServiceBrand,
} from "@ccbar/host-api/window";

export interface QuotaProviderGroup {
  id: QuotaManagementProvider;
  name: string;
  application: ApplicationID;
  brand: ServiceBrand;
  add?: "codexImport" | "kimi" | "deepSeek";
  hint: readonly [string, string];
}

export const quotaProviderGroups: readonly QuotaProviderGroup[] = [
  {
    id: "claude",
    name: "Claude",
    application: "claude",
    brand: "claude",
    hint: [
      "Sign in to Claude Code or Claude Desktop to detect your account.",
      "登录 Claude Code 或 Claude 桌面版后自动读取账号。",
    ],
  },
  {
    id: "chatgpt",
    name: "ChatGPT",
    application: "codex",
    brand: "codex",
    add: "codexImport",
    hint: [
      "Sign in to Codex or add an authorized account.",
      "登录 Codex 后自动读取，或添加已授权的账号。",
    ],
  },
  {
    id: "kimi",
    name: "Kimi Code",
    application: "kimi",
    brand: "kimi",
    add: "kimi",
    hint: [
      "Sign in to Kimi Code or add an account.",
      "登录 Kimi Code 后自动读取，或添加账号。",
    ],
  },
  {
    id: "xai",
    name: "xAI",
    application: "grok",
    brand: "grok",
    hint: [
      "Sign in to Grok to detect your account.",
      "登录 Grok 后自动读取账号。",
    ],
  },
  {
    id: "deepseekHarness",
    name: "DeepSeek Harness",
    application: "dsh",
    brand: "deepseek",
    add: "deepSeek",
    hint: [
      "Sign in to DeepSeek Harness or add an account.",
      "登录 DeepSeek Harness 后自动读取，或添加账号。",
    ],
  },
  {
    id: "antigravity",
    name: "Antigravity",
    application: "antigravity",
    brand: "antigravity",
    hint: [
      "Sign in to Antigravity to detect your account.",
      "登录 Antigravity 后自动读取账号。",
    ],
  },
];

export function accountsForProvider(
  accounts: readonly QuotaAccount[],
  provider: QuotaManagementProvider,
) {
  return accounts
    .filter((account) => account.quotaManagement?.provider === provider)
    .sort(
      (a, b) =>
        Number(b.quotaManagement?.isDefault) -
        Number(a.quotaManagement?.isDefault),
    );
}
