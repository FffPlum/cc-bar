import { expect, it } from "vitest";
import {
  heatmapColorAtIntensity,
  heatmapTokenIntensity,
} from "@/lib/heatmap-scale";

it.each([
  [100_000, 0],
  [1_000_000, 0.25],
  [10_000_000, 0.5],
  [100_000_000, 0.75],
  [1_000_000_000, 1],
])("maps %i Tokens to the fixed logarithmic intensity", (tokens, intensity) => {
  expect(heatmapTokenIntensity(tokens)).toBeCloseTo(intensity);
});

it("clamps the endpoints and handles zero before taking its logarithm", () => {
  expect(heatmapTokenIntensity(0)).toBe(0);
  expect(heatmapTokenIntensity(1)).toBe(0);
  expect(heatmapTokenIntensity(99_999)).toBe(0);
  expect(heatmapTokenIntensity(10_000_000_000)).toBe(1);
});

it("keeps values continuous between 100M and 1B", () => {
  const intensity = heatmapTokenIntensity(300_000_000);
  expect(intensity).toBeCloseTo((Math.log10(3) + 3) / 4);
  expect(intensity).toBeGreaterThan(heatmapTokenIntensity(200_000_000));
  expect(intensity).toBeLessThan(heatmapTokenIntensity(500_000_000));
  expect(intensity - heatmapTokenIntensity(30_000_000)).toBeCloseTo(0.25);
});

it.each([
  [0, "oklch(0.98 0.01 237)"],
  [0.1, "oklch(0.95 0.03 237)"],
  [0.2, "oklch(0.90 0.06 231)"],
  [0.3, "oklch(0.83 0.10 230)"],
  [0.4, "oklch(0.75 0.14 233)"],
  [0.5, "oklch(0.68 0.15 237)"],
  [0.6, "oklch(0.59 0.14 242)"],
  [0.7, "oklch(0.50 0.12 243)"],
  [0.8, "oklch(0.44 0.10 241)"],
  [0.9, "oklch(0.39 0.08 241)"],
  [1, "oklch(0.29 0.06 243)"],
] as const)(
  "matches the official Sky swatch at intensity %s",
  (intensity, color) => {
    expect(heatmapColorAtIntensity(intensity)).toBe(color);
  },
);

it("interpolates adjacent swatches instead of washing out the middle", () => {
  expect(heatmapColorAtIntensity(heatmapTokenIntensity(10_000_000))).toBe(
    "oklch(0.68 0.15 237)",
  );
  expect(heatmapColorAtIntensity(heatmapTokenIntensity(1_000_000))).toBe(
    "color-mix(in oklab, oklch(0.90 0.06 231), oklch(0.83 0.10 230) 50%)",
  );
  expect(heatmapColorAtIntensity(heatmapTokenIntensity(100_000_000))).toBe(
    "color-mix(in oklab, oklch(0.50 0.12 243), oklch(0.44 0.10 241) 50%)",
  );
  expect(heatmapColorAtIntensity(0.95)).toBe(
    "color-mix(in oklab, oklch(0.39 0.08 241), oklch(0.29 0.06 243) 50%)",
  );
});

it("keeps colors within the official palette endpoints", () => {
  expect(heatmapColorAtIntensity(-1)).toBe("oklch(0.98 0.01 237)");
  expect(heatmapColorAtIntensity(2)).toBe("oklch(0.29 0.06 243)");
});
