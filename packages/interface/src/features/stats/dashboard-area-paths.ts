import type {
  DashboardMetric,
  DashboardSample,
  UsageService,
} from "@ccbar/host-api/window";

interface Point {
  x: number;
  y: number;
}

export interface DashboardAreaBand {
  service: UsageService | null;
  fill: string;
  line: string;
}

const fraction = (value: number) =>
  Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;

// All boundaries use the same interpolation weight between category centres.
// Each cubic is a convex blend of its two values, so it cannot overshoot or
// cross the neighbouring stack boundary, even when a service falls to zero.
function curve(points: readonly Point[]): string {
  const first = points[0];
  if (!first) return "";
  let path = `M ${first.x} ${first.y}`;
  for (let i = 1; i < points.length; i++) {
    const previous = points[i - 1]!;
    const current = points[i]!;
    const third = (current.x - previous.x) / 3;
    path += ` C ${previous.x + third} ${previous.y}, ${current.x - third} ${current.y}, ${current.x} ${current.y}`;
  }
  return path;
}

function bandPath(
  service: UsageService | null,
  lower: readonly number[],
  upper: readonly number[],
): DashboardAreaBand {
  const points = (values: readonly number[]): Point[] => {
    const centres = values.map((value, index) => ({
      x: ((index + 0.5) / values.length) * 100,
      y: (1 - value) * 100,
    }));
    // Extend only to the edges of the existing first/last category. A single
    // bucket remains visible as a flat band; no extra dates or samples appear.
    return [
      { ...centres[0]!, x: 0 },
      ...centres,
      { ...centres[centres.length - 1]!, x: 100 },
    ];
  };
  const line = curve(points(upper));
  const bottom = curve(points(lower).reverse());
  return { service, line, fill: `${line} ${bottom.replace(/^M/, "L")} Z` };
}

export function dashboardAreaPaths(
  samples: readonly DashboardSample[],
  services: readonly UsageService[],
  metric: DashboardMetric,
): DashboardAreaBand[] {
  if (samples.length === 0) return [];
  const heights = samples.map((sample) => fraction(sample.normalizedValue));
  if (metric === "cacheHitRate" || services.length === 0) {
    return [
      bandPath(
        null,
        samples.map(() => 0),
        heights,
      ),
    ];
  }
  let lower = samples.map(() => 0);
  return services
    .filter((service) =>
      samples.some((sample) =>
        sample.segments.some(
          (segment) => segment.service === service && segment.share > 0,
        ),
      ),
    )
    .map((service) => {
      const upper = samples.map((sample, index) => {
        const share =
          sample.segments.find((segment) => segment.service === service)
            ?.share ?? 0;
        return Math.min(
          heights[index]!,
          lower[index]! + heights[index]! * fraction(share),
        );
      });
      const band = bandPath(service, lower, upper);
      lower = upper;
      return band;
    });
}
