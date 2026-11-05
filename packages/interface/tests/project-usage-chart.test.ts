import { expect, it } from "vitest";
import type {
  UsageSample,
  UsageService,
  UsageTotals,
} from "@ccbar/host-api/window";
import { projectUsageChartData } from "@/features/stats/project-usage-chart";

const visibleUsageServices: readonly UsageService[] = ["codex", "claude", "pi"];

function totals(totalTokens: number, costUSD = "0"): UsageTotals {
  return {
    inputTokens: totalTokens,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheCreationTokens: 0,
    inputWithCacheTokens: totalTokens,
    totalTokens,
    costUSD,
    costDisplay: `$${costUSD}`,
    requestCount: 0,
    cacheHitRate: 0,
    hasUnpricedUsage: false,
    costIncomplete: false,
    averageFirstTokenSeconds: null,
    outputTokensPerSecond: null,
    usesEstimatedSpeed: false,
  };
}

function sample(totalTokens: number): UsageSample {
  return {
    key: "2026-11-05",
    start: "2026-11-04T16:00:00Z",
    totals: totals(totalTokens),
    byService: {},
    highlighted: false,
  };
}

it("uses each bucket's Token shares even when cost shares differ", () => {
  const input = {
    ...sample(100),
    totals: totals(100, "100"),
    byService: {
      codex: totals(80, "1"),
      claude: totals(20, "99"),
      pi: totals(0),
    },
  };
  const mapped = projectUsageChartData(
    [input],
    "day",
    "en",
    visibleUsageServices,
  ).samples[0]!;
  expect(mapped.value).toBe(100);
  expect(mapped.label).toBe("100.00");
  expect(
    mapped.segments.map(({ service, value, share, label }) => ({
      service,
      value,
      share,
      label,
    })),
  ).toEqual([
    { service: "codex", value: 80, share: 0.8, label: "80.00" },
    { service: "claude", value: 20, share: 0.2, label: "20.00" },
    { service: "pi", value: 0, share: 0, label: "0.00" },
  ]);
  expect(mapped.totals).toBe(input.totals);
  expect(mapped.segments[0]!.totals).toBe(input.byService.codex);
});

it("keeps zero buckets finite and does not invent samples or coverage", () => {
  const empty = projectUsageChartData([], "day", "en", visibleUsageServices);
  expect(empty.samples).toEqual([]);
  expect(empty.axisTicks).toEqual([
    { position: 0, label: "0" },
    { position: 0.5, label: "1" },
    { position: 1, label: "2" },
  ]);
  expect(empty).not.toHaveProperty("coverage");
  const input = { ...sample(0), byService: { codex: totals(0) } };
  const mapped = projectUsageChartData(
    [input],
    "day",
    "zh",
    visibleUsageServices,
  ).samples[0]!;
  expect(mapped.normalizedValue).toBe(0);
  expect(mapped.segments).toHaveLength(1);
  expect(mapped.segments[0]!.share).toBe(0);
});

it("keeps every day's segments in application order when response key order changes", () => {
  const codex = totals(60);
  const claude = totals(30);
  const pi = totals(10);
  const input: UsageSample[] = [
    { ...sample(100), byService: { claude, pi, codex } },
    {
      ...sample(100),
      key: "2026-11-06",
      start: "2026-11-05T16:00:00Z",
      byService: { pi, codex, claude },
    },
  ];
  const refreshed = input.map((bucket) => ({
    ...bucket,
    byService: Object.fromEntries(Object.entries(bucket.byService).reverse()),
  }));
  for (const response of [input, refreshed]) {
    const result = projectUsageChartData(
      response,
      "day",
      "en",
      visibleUsageServices,
    );
    expect(
      result.samples.map((bucket) =>
        bucket.segments.map(({ service, value }) => ({ service, value })),
      ),
    ).toEqual([
      [
        { service: "codex", value: 60 },
        { service: "claude", value: 30 },
        { service: "pi", value: 10 },
      ],
      [
        { service: "codex", value: 60 },
        { service: "claude", value: 30 },
        { service: "pi", value: 10 },
      ],
    ]);
  }
});

it("applies a new application order without inserting segments for absent services", () => {
  const input: UsageSample[] = [
    {
      ...sample(100),
      byService: { claude: totals(30), codex: totals(60), pi: totals(10) },
    },
    {
      ...sample(30),
      key: "2026-11-06",
      start: "2026-11-05T16:00:00Z",
      byService: { claude: totals(30) },
    },
  ];
  const first = projectUsageChartData(input, "day", "en", visibleUsageServices);
  const reordered = projectUsageChartData(input, "day", "en", [
    "pi",
    "claude",
    "codex",
  ]);
  expect(
    first.samples.map((bucket) => bucket.segments.map((x) => x.service)),
  ).toEqual([["codex", "claude", "pi"], ["claude"]]);
  expect(
    reordered.samples.map((bucket) => bucket.segments.map((x) => x.service)),
  ).toEqual([["pi", "claude", "codex"], ["claude"]]);
  expect(reordered.samples[1]!.segments[0]!.share).toBe(1);
});

it.each([
  [1, 1, "0.5", "1"],
  [999, 1_000, "500", "1k"],
  [1_001, 1_100, "550", "1.1k"],
  [24_001, 30_000, "15k", "30k"],
  [48_210_000, 50_000_000, "25M", "50M"],
  [837_200_000, 900_000_000, "450M", "900M"],
  [1_010_000_000, 1_100_000_000, "550M", "1.1B"],
] as const)(
  "uses the dashboard's standard scale for a %i-Token peak",
  (peak, maximum, middleLabel, topLabel) => {
    const result = projectUsageChartData(
      [sample(peak)],
      "day",
      "en",
      visibleUsageServices,
    );
    expect(result.samples[0]!.normalizedValue).toBeCloseTo(peak / maximum);
    expect(result.axisTicks).toEqual([
      { position: 0, label: "0" },
      { position: 0.5, label: middleLabel },
      { position: 1, label: topLabel },
    ]);
  },
);

it.each([
  [9_000, ["0", "4,500", "9,000"]],
  [24_001, ["0", "1.5万", "3万"]],
  [149_000_001, ["0", "7,500万", "1.5亿"]],
] as const)("uses Chinese axis units for %i Tokens", (peak, labels) => {
  const result = projectUsageChartData(
    [sample(peak)],
    "day",
    "zh",
    visibleUsageServices,
  );
  expect(result.axisTicks.map((tick) => tick.label)).toEqual(labels);
});

it.each(["day", "week", "month"] as const)(
  "preserves sparse dates, keys and highlighting for %s buckets",
  (granularity) => {
    const first = { ...sample(10_000), highlighted: true };
    const last = {
      ...sample(48_210),
      key: "2026-11-09",
      start: "2026-11-08T16:00:00Z",
    };
    const input = [first, last] as const;
    const result = projectUsageChartData(
      input,
      granularity,
      "zh",
      visibleUsageServices,
    );
    expect(result.resolvedRange.granularity).toBe(granularity);
    expect(
      result.samples.map(({ key, start, highlighted }) => ({
        key,
        start,
        highlighted,
      })),
    ).toEqual(
      input.map(({ key, start, highlighted }) => ({
        key,
        start,
        highlighted,
      })),
    );
    expect(result.samples.map(({ label }) => label)).toEqual([
      "10.00K",
      "48.21K",
    ]);
    expect(result.samples.every(({ segments }) => segments.length === 0)).toBe(
      true,
    );
  },
);
