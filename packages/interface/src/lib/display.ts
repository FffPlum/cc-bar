import type {
  Comparison,
  ServiceBrand,
  UsageService,
  WindowSettings,
} from "@ccbar/host-api/window";
import type { ResolvedLanguage } from "@/lib/i18n";

export function formatTokens(
  value: number,
  language: ResolvedLanguage,
): string {
  return new Intl.NumberFormat(language === "zh" ? "zh-CN" : "en-US", {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(value);
}

export function formatTokensCompact(
  value: number,
  fractionDigits?: number,
): string {
  const integer = new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits ?? 0,
    maximumFractionDigits: fractionDigits ?? 0,
  });
  if (value < 10_000) return integer.format(value);

  const divisors = [1_000, 1_000_000, 1_000_000_000];
  const suffixes = ["K", "M", "B"];
  let unit = value >= 1_000_000_000 ? 2 : value >= 1_000_000 ? 1 : 0;
  const scaled = value / divisors[unit]!;
  let rounded = Number(scaled.toPrecision(3));
  if (rounded >= 1_000 && unit < suffixes.length - 1) {
    unit += 1;
    rounded = Number((scaled / 1_000).toPrecision(3));
  }
  // Keep the KPI's unit selection, but retain raw precision for tooltip values.
  const compact = new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits ?? 0,
    maximumFractionDigits: fractionDigits ?? 2,
  }).format(fractionDigits === undefined ? rounded : value / divisors[unit]!);
  return compact + suffixes[unit]!;
}

export function formatInteger(
  value: number,
  language: ResolvedLanguage,
): string {
  return new Intl.NumberFormat(language === "zh" ? "zh-CN" : "en-US", {
    maximumFractionDigits: 0,
  }).format(value);
}

export function formatPercent(value: number, digits = 1): string {
  return `${(value * 100).toFixed(digits)}%`;
}

export function formatPercentValue(value: number, digits = 0): string {
  return `${value.toFixed(digits)}%`;
}

export function formatDate(
  value: string | null,
  language: ResolvedLanguage,
  timeZone: string,
  withTime = false,
): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(language === "zh" ? "zh-CN" : "en-US", {
    timeZone: /^\d{4}-\d{2}-\d{2}$/.test(value) ? "UTC" : timeZone,
    year: "numeric",
    month: "short",
    day: "numeric",
    ...(withTime ? { hour: "2-digit", minute: "2-digit" } : {}),
  }).format(date);
}

export function formatTime(value: string | null, timeZone: string): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

export function delta(
  comparison: Comparison,
  key: "tokens" | "costUSD",
): { text: string; direction: "up" | "down" } | null {
  const value = comparison[key];
  if (value === null) return null;
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric === 0) return null;
  return {
    text: `${numeric > 0 ? "↑" : "↓"}${Math.abs(numeric).toFixed(1)}%`,
    direction: numeric > 0 ? "up" : "down",
  };
}

export const fallbackBrands: Record<ServiceBrand, string> = {
  codex: "#6c6c70",
  claude: "#d97757",
  antigravity: "#2f88f8",
  cursor: "#6c6c70",
  commandCode: "#6c6c70",
  opencode: "#6c6c70",
  kimi: "#1783ff",
  pi: "#4d9abf",
  dsh: "#4d6bfe",
  deepseek: "#4d6bfe",
  grok: "#6c6c70",
  gemini: "#3286ff",
};

export function brandColor(
  brand: ServiceBrand,
  settings: WindowSettings,
  dark: boolean,
): string {
  const item = settings.appearance.brandColors.find(
    (candidate) => candidate.brand === brand,
  );
  if (!item) return fallbackBrands[brand] ?? "#6c6c70";
  if (item.mode === "custom" && item.customHex) return item.customHex;
  return dark ? item.defaultDarkHex : item.defaultLightHex;
}

export function supplierBrand(
  supplier: import("@ccbar/host-api/window").Supplier,
): ServiceBrand {
  const brands = {
    openai: "codex",
    anthropic: "claude",
    kimi: "kimi",
    deepseek: "deepseek",
    grok: "grok",
    gemini: "gemini",
    custom: "opencode",
  } as const;
  return brands[supplier];
}

export function usageBrand(service: UsageService): ServiceBrand {
  return service;
}

export const compositionColors = [
  "#3f3a8f",
  "#5e56c2",
  "#8c85d9",
  "#bdb8ec",
  "#dad7f5",
];
export const compositionColorsDark = [
  "#b3adf2",
  "#8f87e6",
  "#6c63cc",
  "#4d469e",
  "#3a3578",
];

export function rankColor(rank: number | undefined, dark: boolean): string {
  const palette = dark ? compositionColorsDark : compositionColors;
  return (
    palette[Math.min(rank ?? palette.length - 1, palette.length - 1)] ??
    palette[0]!
  );
}

export function serviceDisplayName(service: string): string {
  const names: Record<string, string> = {
    codex: "Codex",
    claude: "Claude Code",
    cursor: "Cursor",
    pi: "Pi",
    opencode: "OpenCode",
    dsh: "DSH",
    antigravity: "Antigravity",
    kimi: "Kimi Code",
  };
  return names[service] ?? applicationDisplayName(service);
}

export function applicationDisplayName(id: string): string {
  return (
    (
      {
        codex: "Codex",
        claude: "Claude Code",
        antigravity: "Antigravity",
        cursor: "Cursor",
        commandCode: "Command Code",
        opencode: "OpenCode",
        opencodeGo: "OpenCode Go",
        kimi: "Kimi Code",
        deepseek: "DeepSeek",
        gemini: "Gemini",
        grok: "Grok",
        pi: "Pi",
        dsh: "DSH",
      } as Record<string, string>
    )[id] ?? id
  );
}
