import { expect, it } from "vitest";
import { buildTokenAxisScale } from "@/lib/token-axis-scale";

it.each([
  [48_210_000, 50_000_000, "50M"],
  [837_200_000, 850_000_000, "850M"],
  [850_000_000, 850_000_000, "850M"],
  [850_000_001, 900_000_000, "900M"],
  [999_001, 1_000_000, "1M"],
  [1_010_000_000, 1_500_000_000, "1.5B"],
  [1_500_000_000, 1_500_000_000, "1.5B"],
])(
  "rounds a %i-Token peak up to the nearest 50-multiple at its magnitude",
  (peak, top, label) => {
    const axis = buildTokenAxisScale([0, peak / 10, peak]);
    expect(axis.maximum).toBe(top);
    expect(axis.ticks.at(-1)?.label).toBe(label);
    expect(axis.maximum).toBeGreaterThanOrEqual(peak);
    expect(axis.normalize(peak)).toBeLessThanOrEqual(1);
    expect(axis.normalize(top / 2)).toBe(0.5);
  },
);

it("labels half ticks accurately instead of rounding their displayed values", () => {
  const axis = buildTokenAxisScale([24_001]);
  expect(axis.ticks).toEqual([
    { value: 0, label: "0" },
    { value: 12_500, label: "12.5K" },
    { value: 25_000, label: "25K" },
  ]);
});

it("uses the same rounded ceiling in linear and log modes", () => {
  const values = [1_000_000, 837_200_000];
  for (const mode of ["linear", "log"] as const) {
    const axis = buildTokenAxisScale(values, mode);
    expect(axis.maximum).toBe(850_000_000);
    expect(axis.ticks.at(-1)?.label).toBe("850M");
    expect(axis.normalize(850_000_000)).toBe(1);
    expect(axis.normalize(values[1]!)).toBeLessThan(1);
  }
});

it.each(["linear", "log"] as const)(
  "keeps empty, tiny and invalid data finite with distinct %s ticks",
  (mode) => {
    for (const values of [[], [0], [1], [3], [NaN, Infinity, -5]]) {
      const axis = buildTokenAxisScale(values, mode);
      expect(new Set(axis.ticks.map((tick) => tick.label)).size).toBe(3);
      expect(axis.ticks.every((tick) => Number.isFinite(tick.value))).toBe(
        true,
      );
      expect(axis.normalize(0)).toBe(0);
      expect(axis.normalize(-1)).toBe(0);
      expect(axis.normalize(NaN)).toBe(0);
      expect(axis.normalize(axis.maximum)).toBe(1);
    }
  },
);

it("reveals orders of magnitude on the log axis while preserving zero usage", () => {
  const values = [0, 1, 100_000, 1_000_000, 10_000_000, 100_000_000];
  const axis = buildTokenAxisScale(values, "log");
  const positions = values.map(axis.normalize);
  expect(positions[0]).toBe(0);
  expect(positions[1]).toBeGreaterThan(0);
  expect(positions[3]).toBeCloseTo(0.75, 6);
  expect(positions[4]! - positions[3]!).toBeCloseTo(
    positions[3]! - positions[2]!,
    6,
  );
  expect(positions.at(-1)).toBe(1);
  expect(positions).toEqual([...positions].sort((a, b) => a - b));
  expect(axis.ticks.map((tick) => tick.label)).toEqual(["0", "10K", "100M"]);
});
