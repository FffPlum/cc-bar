import { useId } from "react";
import {
  Area,
  AreaChart,
  Dot,
  XAxis,
  YAxis,
  type DotItemDotProps,
} from "recharts";
import type {
  DashboardMetric,
  DashboardSample,
  UsageService,
} from "@ccbar/host-api/window";
import { ChartContainer, type ChartConfig } from "@/components/ui/chart";
import { serviceDisplayName } from "@/lib/display";
import { cacheRateAxisMinimum } from "./cache-rate-axis";

interface DashboardAreaChartProps {
  samples: readonly DashboardSample[];
  services: readonly UsageService[];
  metric: DashboardMetric;
  independentRates: boolean;
  cacheRateMinimum?: number;
  colorFor: (service: UsageService) => string;
  aggregateColor: string;
}

interface AreaSeries {
  key: string;
  service: UsageService | null;
  color: string;
}

interface AreaRow {
  position: number;
  [key: string]: number | null;
}

const fraction = (value: number) =>
  Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;

export function dashboardAreaServices(
  samples: readonly DashboardSample[],
  services: readonly UsageService[],
  metric: DashboardMetric,
  independentRates: boolean,
): (UsageService | null)[] {
  const separateRates = metric === "cacheHitRate" && independentRates;
  if (
    (metric === "cacheHitRate" && !separateRates) ||
    (!separateRates && services.length === 0)
  )
    return [null];
  return services.filter(
    (service) =>
      separateRates ||
      samples.some(
        (sample) =>
          sample.normalizedValue > 0 &&
          sample.segments.some(
            (segment) => segment.service === service && segment.share > 0,
          ),
      ),
  );
}

// Values share the chart's fixed 0...1 axis. Callers pass independentRates only
// for the per-application cache-rate view; missing additive segments remain 0.
export function dashboardAreaValue(
  sample: DashboardSample,
  service: UsageService | null,
  independentRates: boolean,
  metric: DashboardMetric,
  cacheRateMinimum = 0,
): number | null {
  if (service === null) {
    if (metric === "cacheHitRate" && sample.totals.inputWithCacheTokens <= 0)
      return null;
    return fraction(sample.normalizedValue);
  }
  const segment = sample.segments.find((value) => value.service === service);
  if (independentRates) {
    return segment &&
      segment.totals.inputWithCacheTokens > 0 &&
      Number.isFinite(segment.totals.inputWithCacheTokens) &&
      Number.isFinite(segment.totals.cacheHitRate)
      ? fraction(
          (segment.totals.cacheHitRate - cacheRateMinimum) /
            (1 - cacheRateMinimum),
        )
      : null;
  }
  return fraction(sample.normalizedValue) * fraction(segment?.share ?? 0);
}

export function DashboardAreaChart({
  samples,
  services,
  metric,
  independentRates,
  cacheRateMinimum = cacheRateAxisMinimum(samples),
  colorFor,
  aggregateColor,
}: DashboardAreaChartProps) {
  const uniqueID = useId();
  const gradientPrefix = `usage-area-${uniqueID.replace(/:/g, "")}`;
  const separateRates = metric === "cacheHitRate" && independentRates;
  const series: AreaSeries[] = dashboardAreaServices(
    samples,
    services,
    metric,
    independentRates,
  ).map((service) => ({
    key: service ?? "total",
    service,
    color: service === null ? aggregateColor : colorFor(service),
  }));
  const config: ChartConfig = Object.fromEntries(
    series.map((item) => [
      item.key,
      {
        color: item.color,
        ...(item.service ? { label: serviceDisplayName(item.service) } : {}),
      },
    ]),
  );
  const rows: AreaRow[] = samples.map((sample, index) => {
    const row: AreaRow = { position: (index + 0.5) / samples.length };
    for (const item of series) {
      row[item.key] = dashboardAreaValue(
        sample,
        item.service,
        separateRates,
        metric,
        cacheRateMinimum,
      );
    }
    return row;
  });
  // Extend values only to the edge of their existing categories. This also
  // makes a single bucket a visible flat band. These geometry rows introduce
  // no dates or interaction targets; the parent owns the real sample columns.
  const data =
    rows.length > 0
      ? [
          { ...rows[0]!, position: 0 },
          ...rows,
          { ...rows[rows.length - 1]!, position: 1 },
        ]
      : [];

  return (
    <ChartContainer
      config={config}
      data-slot="dashboard-area"
      aria-hidden="true"
      className="pointer-events-none absolute inset-0 h-full w-full"
    >
      <AreaChart
        data={data}
        margin={{ top: 0, right: 0, bottom: 0, left: 0 }}
        accessibilityLayer={false}
      >
        <defs>
          {series.map((item) => (
            <linearGradient
              key={item.key}
              id={`${gradientPrefix}-${item.key}`}
              x1="0"
              y1="0"
              x2="0"
              y2="1"
            >
              <stop
                offset="5%"
                stopColor={`var(--color-${item.key})`}
                stopOpacity={0.3}
              />
              <stop
                offset="95%"
                stopColor={`var(--color-${item.key})`}
                stopOpacity={0.05}
              />
            </linearGradient>
          ))}
        </defs>
        <XAxis
          hide
          dataKey="position"
          type="number"
          domain={[0, 1]}
          allowDataOverflow
          padding={{ left: 0, right: 0 }}
        />
        <YAxis hide type="number" domain={[0, 1]} allowDataOverflow width={0} />
        {series.map((item) => (
          <Area
            key={item.key}
            dataKey={item.key}
            type="monotone"
            stroke={`var(--color-${item.key})`}
            strokeWidth={1.5}
            fill={`url(#${gradientPrefix}-${item.key})`}
            fillOpacity={1}
            connectNulls={false}
            // A valid rate surrounded by missing buckets has no area segment;
            // retain its real observation without drawing through the gaps.
            dot={
              separateRates
                ? ({ cx, cy, payload }: DotItemDotProps) => {
                    const position: unknown = payload?.position;
                    // Edge rows extend the fill, but are not observations.
                    if (
                      typeof position !== "number" ||
                      !(position > 0 && position < 1)
                    )
                      return null;
                    return (
                      <Dot
                        className="recharts-area-dot"
                        cx={cx}
                        cy={cy}
                        r={2}
                        fill={`var(--color-${item.key})`}
                        stroke={`var(--color-${item.key})`}
                        strokeWidth={1}
                      />
                    );
                  }
                : false
            }
            activeDot={false}
            isAnimationActive={false}
          />
        ))}
      </AreaChart>
    </ChartContainer>
  );
}
