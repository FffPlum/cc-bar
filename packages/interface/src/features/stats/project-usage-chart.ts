import type {
  StatsQuery,
  UsageSample,
  UsageService,
} from "@ccbar/host-api/window";
import type { DashboardChartData } from "./dashboard-charts";
import { formatTokensCompact } from "@/lib/display";

export function projectUsageChartData(
  samples: readonly UsageSample[],
  granularity: StatsQuery["granularity"],
  language: "zh" | "en",
  visibleUsageServices: readonly UsageService[],
): DashboardChartData {
  const peak = samples.reduce(
    (maximum, sample) => Math.max(maximum, sample.totals.totalTokens),
    0,
  );
  const maximum = standardAxisMaximum(peak);
  return {
    resolvedRange: { granularity },
    axisTicks: [0, 0.5, 1].map((position) => ({
      position,
      label: axisNumberLabel(position * maximum, language),
    })),
    samples: samples.map((sample) => {
      const value = sample.totals.totalTokens;
      return {
        key: sample.key,
        start: sample.start,
        totals: sample.totals,
        highlighted: sample.highlighted,
        value,
        label: formatTokensCompact(value, 2),
        normalizedValue: Number.isFinite(value)
          ? Math.min(1, Math.max(0, value / maximum))
          : 0,
        segments: visibleUsageServices.flatMap((service) => {
          const totals = sample.byService[service];
          if (!totals) return [];
          const contribution = totals.totalTokens;
          return [
            {
              service,
              totals,
              value: contribution,
              label: formatTokensCompact(contribution, 2),
              share: value > 0 ? contribution / value : 0,
            },
          ];
        }),
      };
    }),
  };
}

// Keep project Token axes aligned with HostWindowDashboard.DashboardAxisScale.
function standardAxisMaximum(peak: number): number {
  if (!Number.isFinite(peak) || peak <= 0) return 2;
  const roughStep = peak / 2;
  const magnitude = 10 ** Math.floor(Math.log10(roughStep));
  const step = (Math.ceil((roughStep / magnitude) * 2) / 2) * magnitude;
  const maximum = step * 2;
  return Number.isFinite(step) && Number.isFinite(maximum) && step > 0
    ? maximum
    : peak;
}

function axisNumberLabel(value: number, language: "zh" | "en"): string {
  const magnitude = Math.abs(value);
  const units: readonly [number, string][] =
    language === "zh"
      ? [
          [100_000_000, "亿"],
          [10_000, "万"],
        ]
      : [
          [1_000_000_000, "B"],
          [1_000_000, "M"],
          [1_000, "k"],
        ];
  const [divisor, suffix] = units.find(
    ([threshold]) => magnitude >= threshold,
  ) ?? [1, ""];
  const label = new Intl.NumberFormat(language === "zh" ? "zh-CN" : "en-US", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 1,
  }).format(value / divisor);
  return label + suffix;
}
