import { expect, it } from "vitest";
import type { ProjectDetail, UsageTotals } from "@ccbar/host-api/window";
import { projectUsageShareRows } from "@/features/stats/project-usage-share-data";

function totals(totalTokens: number, costUSD = "0"): UsageTotals {
  return {
    inputTokens: totalTokens,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    inputWithCacheTokens: totalTokens,
    totalTokens,
    costUSD,
    costDisplay: "<localized rounded amount>",
    requestCount: 0,
    cacheHitRate: 0,
    hasUnpricedUsage: false,
    costIncomplete: false,
    averageFirstTokenSeconds: null,
    outputTokensPerSecond: null,
    usesEstimatedSpeed: false,
  };
}

function detail(overrides: Partial<ProjectDetail> = {}): ProjectDetail {
  return {
    project: {
      key: "project",
      name: "Project",
      path: "/project",
      status: "available",
    },
    totals: totals(0),
    previousTotals: null,
    comparison: { tokens: null, costUSD: null, requests: null },
    conversationCount: 0,
    activeDays: 0,
    rangeDayCount: 1,
    daily: [],
    totalsByService: {},
    sharesByService: {},
    models: [],
    branches: [],
    topConversations: [],
    worktrees: [],
    allTimeTotals: totals(0),
    firstUsedDay: null,
    gitRepository: null,
    ...overrides,
  };
}

it("recomputes service shares and ranks from the selected metric's raw values", () => {
  const input = detail({
    totals: totals(100, "0.00000003"),
    totalsByService: {
      claude: totals(20, "0.00000002"),
      codex: totals(80, "0.00000001"),
    },
    sharesByService: { claude: 0.99, codex: 0.01 },
  });
  const tokens = projectUsageShareRows(input, "service", "tokens");
  expect(tokens.map((row) => [row.service, row.share])).toEqual([
    ["codex", 0.8],
    ["claude", 0.2],
  ]);
  expect(tokens[0]).toMatchObject({ title: "Codex", services: ["codex"] });
  const cost = projectUsageShareRows(input, "service", "cost");
  expect(cost.map((row) => row.service)).toEqual(["claude", "codex"]);
  expect(cost[0]!.share).toBeCloseTo(2 / 3);
  expect(cost[1]!.share).toBeCloseTo(1 / 3);
  expect(cost[0]!.totals).toBe(input.totalsByService.claude);
});

it("gives tied services a stable order independent of object insertion order", () => {
  const make = (totalsByService: ProjectDetail["totalsByService"]) =>
    projectUsageShareRows(
      detail({ totals: totals(20), totalsByService }),
      "service",
      "tokens",
    );
  const first = make({ codex: totals(10), claude: totals(10) });
  const second = make({ claude: totals(10), codex: totals(10) });
  expect(first.map((row) => row.id)).toEqual(second.map((row) => row.id));
});

it("keeps the complete project denominator beyond the first five displayed models", () => {
  const input = detail({
    totals: totals(210, "21"),
    models: [60, 50, 40, 30, 20, 10].map((tokens, index) => ({
      model: `model-${index}`,
      services: ["codex", "claude"],
      totals: totals(tokens, String(tokens / 10)),
    })),
  });
  for (const metric of ["tokens", "cost"] as const) {
    const rows = projectUsageShareRows(input, "model", metric);
    expect(rows).toHaveLength(6);
    expect(rows[0]!.share).toBeCloseTo(60 / 210);
    expect(
      rows.slice(0, 5).reduce((sum, row) => sum + row.share, 0),
    ).toBeCloseTo(200 / 210);
    expect(rows.reduce((sum, row) => sum + row.share, 0)).toBeCloseTo(1);
    expect(rows.map((row) => row.title)).toEqual(
      input.models.map((model) => model.model),
    );
    expect(rows[0]!.services).toEqual(["codex", "claude"]);
  }
});

it("preserves host branch order, counts and distinct missing or empty-name IDs", () => {
  const input = detail({
    totals: totals(100, "10"),
    branches: [
      { branch: "", conversationCount: 1, totals: totals(10, "5") },
      { branch: "main", conversationCount: 4, totals: totals(40, "2") },
      { branch: null, conversationCount: 2, totals: totals(20, "2") },
      { branch: null, conversationCount: 3, totals: totals(30, "1") },
    ],
  });
  const rows = projectUsageShareRows(input, "branch", "cost");
  expect(new Set(rows.map((row) => row.id)).size).toBe(4);
  expect(rows.map((row) => row.title)).toEqual(["", "main", "", ""]);
  expect(rows.map((row) => row.conversationCount)).toEqual([1, 4, 2, 3]);
  expect(rows.map((row) => row.share)).toEqual([0.5, 0.2, 0.2, 0.1]);
  expect(rows.every((row) => row.services.length === 0)).toBe(true);
});

it("cleans model labels without merging distinct raw model identifiers", () => {
  const models: ProjectDetail["models"] = [
    "kimi-code/kimi-for-coding",
    "deepseek/deepseek-chat",
    "deepseek-chat",
    "other/model",
  ].map((model) => ({
    model,
    services: ["kimi"],
    totals: totals(25),
  }));
  const input = detail({
    totals: totals(100),
    models,
  });
  const rows = projectUsageShareRows(input, "model", "tokens");
  expect(rows.map((row) => row.title)).toEqual([
    "kimi-for-coding",
    "deepseek-chat",
    "deepseek-chat",
    "other/model",
  ]);
  expect(rows.map((row) => row.id)).toEqual(
    models.map((model) => `model:${model.model}`),
  );
  expect(new Set(rows.map((row) => row.id)).size).toBe(4);
  expect(rows.map((row) => row.share)).toEqual([0.25, 0.25, 0.25, 0.25]);
});

it("keeps zero or wholly unpriced cost shares at zero instead of falling back to Tokens", () => {
  const unknown = { ...totals(100), hasUnpricedUsage: true };
  const input = detail({
    totals: unknown,
    totalsByService: { codex: unknown },
    models: [{ model: "unknown", services: ["codex"], totals: unknown }],
    branches: [{ branch: null, conversationCount: 1, totals: unknown }],
  });
  for (const dimension of ["service", "model", "branch"] as const) {
    expect(projectUsageShareRows(input, dimension, "cost")[0]!.share).toBe(0);
    expect(projectUsageShareRows(input, dimension, "tokens")[0]!.share).toBe(1);
    expect(projectUsageShareRows(detail(), dimension, "cost")).toEqual([]);
  }
  const zero = detail({ totalsByService: { codex: totals(0) } });
  expect(projectUsageShareRows(zero, "service", "tokens")[0]!.share).toBe(0);
});

it("uses the known portion of partially priced usage and rejects nonfinite cost values", () => {
  const input = detail({
    totals: { ...totals(100, "2"), hasUnpricedUsage: true },
    totalsByService: {
      codex: { ...totals(60, "1"), hasUnpricedUsage: true },
      claude: totals(40, "1"),
      pi: totals(0, `1${"0".repeat(400)}`),
    },
  });
  const rows = projectUsageShareRows(input, "service", "cost");
  expect(rows.find((row) => row.service === "codex")!.share).toBe(0.5);
  expect(rows.find((row) => row.service === "pi")!.share).toBe(0);
  expect(rows.every((row) => Number.isFinite(row.share))).toBe(true);
});
