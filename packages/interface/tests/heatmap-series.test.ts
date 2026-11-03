import { expect, it } from "vitest";
import type { DashboardHeatmap } from "@ccbar/host-api/window";
import { buildHeatmapSeries } from "@/lib/heatmap-series";
import usage from "../../host-api/fixtures/window-usage.json";

const total = usage["window.usage.overview"].totals;

function block(
  fromDay: string,
  toDay: string,
  days: [string, number][],
): Pick<DashboardHeatmap, "fromDay" | "toDay" | "days"> {
  return {
    fromDay,
    toDay,
    days: days.map(([day, tokens]) => ({
      day,
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
  const latest = block("2026-11-02", "2026-11-09", [
    ["2026-11-04", 10_000],
    ["2026-11-03", 3],
    ["2026-11-02", 2],
  ]);
  const earlier = block("2026-10-26", "2026-11-03", [
    ["2026-11-02", 200],
    ["2026-11-01", 1],
  ]);
  const originalDays = latest.days.map(({ day }) => day);
  const series = buildHeatmapSeries([latest, earlier], "2026-11-03");
  expect(series.rolling.map(({ day }) => day)).toEqual([
    "2026-11-01",
    "2026-11-02",
    "2026-11-03",
  ]);
  expect(series.rolling.at(-1)).toMatchObject({ tokens: 6, dayCount: 3 });
  expect(series.weekly.at(-1)).toMatchObject({ tokens: 5, dayCount: 2 });
  expect(latest.days.map(({ day }) => day)).toEqual(originalDays);
});

it("uses the previous six calendar days across a page boundary", () => {
  const earlier = block("2026-10-26", "2026-11-02", [
    ["2026-10-26", 100],
    ["2026-10-27", 1],
    ["2026-10-28", 2],
    ["2026-10-29", 3],
    ["2026-10-30", 4],
    ["2026-10-31", 5],
    ["2026-11-01", 6],
  ]);
  const latest = block("2026-11-02", "2026-11-09", [
    ["2026-11-02", 7],
    ["2026-11-03", 8],
  ]);
  const series = buildHeatmapSeries([latest, earlier], "2026-11-03");
  expect(series.rolling.find(({ day }) => day === "2026-11-02")).toEqual({
    day: "2026-11-02",
    fromDay: "2026-10-27",
    toDay: "2026-11-02",
    tokens: 28,
    dayCount: 7,
    partial: false,
  });
  expect(series.rolling.at(-1)).toMatchObject({
    fromDay: "2026-10-28",
    tokens: 35,
    dayCount: 7,
    partial: false,
  });
});

it("marks the first six rolling points partial instead of assuming unloaded days are zero", () => {
  const series = buildHeatmapSeries(
    [
      block("2026-11-02", "2026-11-09", [
        ["2026-11-02", 0],
        ["2026-11-03", 0],
        ["2026-11-04", 0],
        ["2026-11-05", 0],
        ["2026-11-06", 0],
        ["2026-11-07", 0],
        ["2026-11-08", 0],
      ]),
    ],
    "2026-11-08",
  );
  expect(series.rolling.map(({ dayCount }) => dayCount)).toEqual([
    1, 2, 3, 4, 5, 6, 7,
  ]);
  expect(series.rolling.map(({ partial }) => partial)).toEqual([
    true, true, true, true, true, true, false,
  ]);
  expect(series.weekly[0]).toMatchObject({
    tokens: 0,
    dayCount: 7,
    partial: false,
  });
});

it("does not substitute older samples for missing calendar days in a rolling window", () => {
  const series = buildHeatmapSeries(
    [
      block("2026-10-26", "2026-11-09", [
        ["2026-10-26", 100],
        ["2026-10-27", 1],
        ["2026-10-28", 1],
        ["2026-10-30", 1],
        ["2026-10-31", 1],
        ["2026-11-01", 1],
        ["2026-11-02", 1],
      ]),
    ],
    "2026-11-02",
  );
  expect(series.rolling.at(-1)).toMatchObject({
    fromDay: "2026-10-27",
    toDay: "2026-11-02",
    tokens: 6,
    dayCount: 6,
    partial: true,
  });
});

it("returns no series when there are no loaded dates at or before today", () => {
  expect(buildHeatmapSeries([], "2026-11-02")).toEqual({
    weekly: [],
    rolling: [],
  });
  expect(
    buildHeatmapSeries(
      [block("2026-11-02", "2026-11-09", [["2026-11-03", 10]])],
      "2026-11-02",
    ),
  ).toEqual({ weekly: [], rolling: [] });
});
