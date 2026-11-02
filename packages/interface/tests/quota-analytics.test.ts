import { expect, it } from "vitest";
import type {
  CycleSummary,
  QuotaAccount,
  QuotaAnalytics,
  QuotaTimelineEntry,
  QuotaTimelinePeriod,
} from "@ccbar/host-api/window";
import {
  analyticsAccounts,
  currentCycle,
  timelineEntries,
} from "@/features/stats/quota-analytics-page";
function account(id: string, patch: Partial<QuotaAccount> = {}): QuotaAccount {
  return {
    id,
    kind: "primary",
    service: "codex",
    name: "Synthetic",
    subtitle: "Test only",
    plan: null,
    region: null,
    detected: true,
    current: false,
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
it("filters by statistics visibility, not primary quota visibility, and deduplicates mirrors", () => {
  const accounts = [
    account("primary", { enabled: false }),
    account("mirror", { kind: "importedCodex", current: true }),
    account("extra", { kind: "importedCodex" }),
    account("kimi", { service: "kimi", kind: "managedKimi", enabled: false }),
    account("claude", { service: "claude" }),
  ];
  expect(
    analyticsAccounts(accounts, ["codex", "kimi"]).map((item) => item.id),
  ).toEqual(["primary", "extra"]);
  expect(
    analyticsAccounts(accounts, ["claude"]).map((item) => item.id),
  ).toEqual(["claude"]);
  expect(analyticsAccounts(accounts, ["codex"], "claude")).toEqual([]);
});
it("takes the first current cycle in the host's precedence order", () => {
  const preferred = {
    cycle: { id: "observed", current: true },
  } as CycleSummary;
  const secondary = {
    cycle: { id: "inferred", current: true },
  } as CycleSummary;
  const value = {
    cycles: [preferred, secondary],
    window: null,
  } as QuotaAnalytics;
  expect(currentCycle(value)).toBe(preferred);
});
it("orders timeline points across current and previous periods without mutating either", () => {
  const entry = (id: string, time: string): QuotaTimelineEntry => ({
    id,
    sampledAt: time,
    source: "sample",
    remainingPercent: 50,
    deltaPercent: null,
    resetsAt: null,
    windowIndex: 0,
  });
  const current = entry("current", "2026-11-02T00:00:00Z"),
    previous = entry("previous", "2026-11-01T00:00:00Z");
  const period = (
    id: string,
    entries: QuotaTimelineEntry[],
  ): QuotaTimelinePeriod => ({
    id,
    kind: "currentCycle",
    start: "2026-11-01T00:00:00Z",
    end: "2026-11-03T00:00:00Z",
    totalDelta: 0,
    entries,
  });
  const periods = [
    period("current", [current]),
    period("previous", [previous]),
  ];
  expect(timelineEntries(periods).map((item) => item.id)).toEqual([
    "previous",
    "current",
  ]);
  expect(periods[0]?.entries).toEqual([current]);
});
