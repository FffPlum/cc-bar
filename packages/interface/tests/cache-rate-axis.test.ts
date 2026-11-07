import { expect, it } from "vitest";
import type { DashboardSample } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { cacheRateAxisMinimum } from "@/features/stats/cache-rate-axis";

const totals = usage["window.usage.overview"].totals;

function sample(rate: number, inputWithCacheTokens = 100): DashboardSample {
  return {
    key: String(rate),
    start: "2026-11-02T00:00:00Z",
    totals: { ...totals, cacheHitRate: 0.99 },
    value: 0.99,
    label: "99%",
    normalizedValue: 1,
    segments: [
      {
        service: "kimi",
        totals: { ...totals, inputWithCacheTokens, cacheHitRate: rate },
        value: rate,
        label: String(rate),
        share: 1,
      },
    ],
  };
}

it.each([
  [0.98, 0.95],
  [0.95, 0.9],
  [0.9, 0.85],
  [0.88, 0.8],
  [0.6, 0],
  [1, 0.95],
])("matches the host cache-rate axis boundary for %s", (rate, minimum) => {
  expect(cacheRateAxisMinimum([sample(rate)])).toBeCloseTo(minimum);
});

it("excludes zero-input buckets and falls back to the full range when no rate is available", () => {
  expect(
    cacheRateAxisMinimum([sample(0.98), sample(0, 0), sample(0.88)]),
  ).toBeCloseTo(0.8);
  expect(cacheRateAxisMinimum([sample(0, 0)])).toBe(0);
  expect(cacheRateAxisMinimum([])).toBe(0);
});
