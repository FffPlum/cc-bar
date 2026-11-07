import { expect, it } from "vitest";
import type { DashboardHeatmap } from "@ccbar/host-api/window";
import { buildHeatmapSeries } from "@/lib/heatmap-series";
import usage from "../../host-api/fixtures/window-usage.json";

const total = usage["window.usage.overview"].totals;

function block(
  fromDay: string,
  toDay: string,
  days: [string, number][],
  prefix = 0,
  firstDay: string | null = [...days].sort(([a], [b]) =>
    a.localeCompare(b),
  )[0]?.[0] ?? null,
): Pick<DashboardHeatmap, "fromDay" | "toDay" | "days" | "cumulativeFromDay"> {
  // Model the authoritative values supplied by the host, including older history.
  const cumulative = new Map<string, number>();
  for (const [day, tokens] of [...days].sort(([a], [b]) =>
    a.localeCompare(b),
  )) {
    prefix += tokens;
    cumulative.set(day, prefix);
  }
  return {
    fromDay,
    toDay,
    cumulativeFromDay: firstDay,
    days: days.map(([day, tokens]) => ({
      day,
      cumulativeTokens: cumulative.get(day)!,
      totals: { ...total, totalTokens: tokens },
      value: 999,
      label: "$999",
      normalizedValue: 1,
    })),
  };
}

it("groups Monday through Sunday across the year boundary using raw Tokens", () => {
  const series = buildHeatmapSeries(
    [
      block("2026-12-28", "2027-01-11", [
        ["2027-01-04", 100],
        ["2027-01-03", 7],
        ["2027-01-02", 6],
        ["2027-01-01", 5],
        ["2026-12-31", 4],
        ["2026-12-30", 3],
        ["2026-12-29", 2],
        ["2026-12-28", 1],
      ]),
    ],
    "2027-01-04",
  );
  expect(series.weekly).toEqual([
    {
      day: "2026-12-28",
      fromDay: "2026-12-28",
      toDay: "2027-01-03",
      tokens: 28,
      dayCount: 7,
      partial: false,
    },
    {
      day: "2027-01-04",
      fromDay: "2027-01-04",
      toDay: "2027-01-10",
      tokens: 100,
      dayCount: 1,
      partial: true,
    },
  ]);
});

it("deduplicates overlapping pages, excludes future dates and sorts without mutation", () => {
  const latest = block(
    "2026-11-02",
    "2026-11-09",
    [
      ["2026-11-04", 10_000],
      ["2026-11-03", 3],
      ["2026-11-02", 2],
    ],
    1,
    "2026-11-01",
  );
  const earlier = block("2026-10-26", "2026-11-03", [
    ["2026-11-02", 200],
    ["2026-11-01", 1],
  ]);
  const originalDays = latest.days.map(({ day }) => day);
  const series = buildHeatmapSeries([latest, earlier], "2026-11-03");
  expect(series.cumulative.map(({ day, tokens }) => [day, tokens])).toEqual([
    ["2026-11-01", 1],
    ["2026-11-02", 3],
    ["2026-11-03", 6],
  ]);
  expect(series.weekly.at(-1)).toMatchObject({ tokens: 5, dayCount: 2 });
  expect(latest.days.map(({ day }) => day)).toEqual(originalDays);
});

it("retains history before the display window and holds flat on known zero-usage days", () => {
  const series = buildHeatmapSeries(
    [
      block(
        "2026-11-02",
        "2026-11-09",
        [
          ["2026-11-02", 100],
          ["2026-11-03", 0],
          ["2026-11-04", 5],
        ],
        1_000_000_000,
        "2024-01-01",
      ),
    ],
    "2026-11-04",
  );
  expect(series.cumulative.map(({ tokens }) => tokens)).toEqual([
    1_000_000_100, 1_000_000_100, 1_000_000_105,
  ]);
  expect(series.cumulative.at(-1)).toEqual({
    day: "2026-11-04",
    fromDay: "2024-01-01",
    toDay: "2026-11-04",
    tokens: 1_000_000_105,
  });
  expect(series.weekly[0]?.tokens).toBe(105);
});

it("keeps earlier usage after seven days instead of dropping it from the total", () => {
  const series = buildHeatmapSeries(
    [
      block("2026-11-02", "2026-11-16", [
        ["2026-11-02", 100],
        ["2026-11-03", 0],
        ["2026-11-04", 0],
        ["2026-11-05", 0],
        ["2026-11-06", 0],
        ["2026-11-07", 0],
        ["2026-11-08", 0],
        ["2026-11-09", 0],
        ["2026-11-10", 1],
      ]),
    ],
    "2026-11-10",
  );
  expect(series.cumulative.map(({ tokens }) => tokens)).toEqual([
    100, 100, 100, 100, 100, 100, 100, 100, 101,
  ]);
  expect(series.cumulative.at(-1)?.fromDay).toBe("2026-11-02");
  expect(series.cumulative.at(-1)?.partial).toBeUndefined();
});

it("begins the cumulative curve at the first recorded day, including a zero-Token record", () => {
  const series = buildHeatmapSeries(
    [
      block(
        "2026-11-02",
        "2026-11-09",
        [
          ["2026-11-02", 0],
          ["2026-11-03", 0],
          ["2026-11-04", 5],
        ],
        0,
        "2026-11-03",
      ),
    ],
    "2026-11-04",
  );
  expect(series.cumulative.map(({ day, tokens }) => [day, tokens])).toEqual([
    ["2026-11-03", 0],
    ["2026-11-04", 5],
  ]);
});

it("does not invent cumulative observations for missing DTO dates or an empty history", () => {
  const series = buildHeatmapSeries(
    [
      block("2026-11-02", "2026-11-09", [
        ["2026-11-02", 1],
        ["2026-11-04", 2],
      ]),
    ],
    "2026-11-04",
  );
  expect(series.cumulative.map(({ day }) => day)).toEqual([
    "2026-11-02",
    "2026-11-04",
  ]);
  expect(
    buildHeatmapSeries(
      [block("2026-11-02", "2026-11-09", [["2026-11-02", 0]], 0, null)],
      "2026-11-02",
    ).cumulative,
  ).toEqual([]);
});

it("returns no series when there are no loaded dates at or before today", () => {
  expect(buildHeatmapSeries([], "2026-11-02")).toEqual({
    weekly: [],
    cumulative: [],
  });
  expect(
    buildHeatmapSeries(
      [block("2026-11-02", "2026-11-09", [["2026-11-03", 10]])],
      "2026-11-02",
    ),
  ).toEqual({ weekly: [], cumulative: [] });
});
