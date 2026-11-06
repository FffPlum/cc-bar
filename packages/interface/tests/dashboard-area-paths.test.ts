import { expect, it } from "vitest";
import type { DashboardSample, UsageService } from "@ccbar/host-api/window";
import usage from "../../host-api/fixtures/window-usage.json";
import { dashboardAreaPaths } from "@/features/stats/dashboard-area-paths";

const totals = usage["window.usage.overview"].totals;
function sample(
  key: string,
  height: number,
  codexShare: number,
): DashboardSample {
  return {
    key,
    start: `${key}T00:00:00Z`,
    value: height * 100,
    normalizedValue: height,
    label: String(height * 100),
    totals,
    segments: (["codex", "claude"] as const).map((service) => ({
      service,
      totals,
      value: height * 100 * (service === "codex" ? codexShare : 1 - codexShare),
      label: "",
      share: service === "codex" ? codexShare : 1 - codexShare,
    })),
  };
}

// Sample the rendered Bezier curves, including the midpoints where independent
// smoothing of adjacent stack boundaries can otherwise create negative bands.
function curveValues(path: string): number[] {
  const [move, ...curves] = path.split(" C ");
  let previousY = Number(move!.split(" ")[2]);
  return curves.flatMap((curve) => {
    const values = curve.split(/[, ]+/).map(Number);
    const startY = previousY;
    previousY = values[5]!;
    return Array.from({ length: 21 }, (_, index) => {
      const t = index / 20;
      return (
        (1 - t) ** 3 * startY +
        3 * (1 - t) ** 2 * t * values[1]! +
        3 * (1 - t) * t ** 2 * values[3]! +
        t ** 3 * values[5]!
      );
    });
  });
}

it("keeps curved stack boundaries ordered and bounded through sharp changes", () => {
  const samples = [
    sample("2026-11-01", 0.2, 1),
    sample("2026-11-02", 0.9, 0),
    sample("2026-11-08", 0.1, 0.75),
    sample("2026-11-09", 0, 0),
  ];
  for (const order of [
    ["codex", "claude"],
    ["claude", "codex"],
  ] as UsageService[][]) {
    const bands = dashboardAreaPaths(samples, order, "tokens");
    expect(bands.map((band) => band.service)).toEqual(order);
    const lower = curveValues(bands[0]!.line);
    const upper = curveValues(bands[1]!.line);
    for (let index = 0; index < lower.length; index++) {
      expect(upper[index]).toBeGreaterThanOrEqual(10 - 1e-10);
      expect(lower[index]).toBeLessThanOrEqual(100 + 1e-10);
      expect(upper[index]!).toBeLessThanOrEqual(lower[index]! + 1e-10);
    }
    // Sparse dates remain four categories; no in-between data is generated.
    expect(bands[0]!.line.match(/ C /g)).toHaveLength(samples.length + 1);
  }
});

it("handles empty, all-zero and single-bucket series without invalid paths", () => {
  expect(dashboardAreaPaths([], [], "tokens")).toEqual([]);
  const zero = dashboardAreaPaths([sample("2026-11-01", 0, 0)], [], "tokens");
  expect(
    curveValues(zero[0]!.line).every((value) => Math.abs(value - 100) < 1e-10),
  ).toBe(true);
  const single = dashboardAreaPaths(
    [sample("2026-11-01", 0.5, 1)],
    ["codex"],
    "tokens",
  );
  expect(single[0]!.line).toContain("50 50");
  expect(
    curveValues(single[0]!.line).every((value) => Math.abs(value - 50) < 1e-10),
  ).toBe(true);
  expect(single[0]!.fill).toMatch(/ Z$/);
  expect(single[0]!.fill).not.toMatch(/NaN|Infinity/);
});

it("uses the aggregate height for cache rate without stacking percentages", () => {
  const paths = dashboardAreaPaths(
    [sample("2026-11-01", 0.5, 0.75)],
    ["codex", "claude"],
    "cacheHitRate",
  );
  expect(paths).toHaveLength(1);
  expect(paths[0]!.service).toBeNull();
  expect(
    curveValues(paths[0]!.line).every((value) => Math.abs(value - 50) < 1e-10),
  ).toBe(true);
});
