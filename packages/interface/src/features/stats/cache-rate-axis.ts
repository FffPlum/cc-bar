import type { DashboardSample } from "@ccbar/host-api/window";

// Match HostWindowDashboard.DashboardAxisScale.cacheHitRate, using the lowest
// valid application rate so every application shares the same visible range.
export function cacheRateAxisMinimum(
  samples: readonly DashboardSample[],
): number {
  let minimum: number | undefined;
  for (const sample of samples) {
    for (const { totals } of sample.segments) {
      if (
        totals.inputWithCacheTokens <= 0 ||
        !Number.isFinite(totals.inputWithCacheTokens) ||
        !Number.isFinite(totals.cacheHitRate)
      )
        continue;
      const rate = Math.max(0, Math.min(1, totals.cacheHitRate));
      minimum = minimum === undefined ? rate : Math.min(minimum, rate);
    }
  }
  if (minimum === undefined) return 0;
  const padding = Math.max((1 - minimum) / 2, 0.02);
  const rounded =
    Math.floor(Math.max(0, minimum - padding) / 0.05 + 1e-9) * 0.05;
  return rounded < 0.5 ? 0 : rounded;
}
