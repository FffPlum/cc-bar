import { useRef, useState } from "react";
import type {
  DashboardMetric,
  DashboardSample,
  DashboardSampleSegment,
  UsageDashboard,
  UsageService,
} from "@ccbar/host-api/window";
import {
  ChartDataTooltip,
  ChartDataTooltipTrigger,
  ChartDataTooltipContent,
  createChartDataTooltipHandle,
} from "@/components/chart-data-tooltip";
import { chartBarWidth } from "@/components/stacked-bar-chart";
import {
  brandColor,
  formatDate,
  formatTokensCompact,
  serviceDisplayName,
} from "@/lib/display";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";
import { dashboardAreaPaths } from "./dashboard-area-paths";

export interface DashboardChartData {
  samples: (DashboardSample & { highlighted?: boolean })[];
  axisTicks: UsageDashboard["axisTicks"];
  resolvedRange: {
    granularity: UsageDashboard["resolvedRange"]["granularity"] | "week";
  };
  coverage?: Pick<UsageDashboard["coverage"], "precision">;
}

export function DashboardChart({
  data,
  title,
  metric,
  service,
  empty = false,
  headerTitle,
  className,
}: {
  data: DashboardChartData;
  title: string;
  metric: DashboardMetric;
  service?: UsageService;
  empty?: boolean;
  headerTitle?: string;
  className?: string;
}) {
  const [tooltipHandle] = useState(() =>
    createChartDataTooltipHandle<string>(),
  );
  const plot = useRef<HTMLDivElement>(null);
  const { bootstrap, settings } = useHost();
  const t = useTranslation();
  const isCacheHitRate = metric === "cacheHitRate";
  const isArea = settings.appearance.statsChartType === "area";
  const valueLabel = (sample: DashboardSample | DashboardSampleSegment) =>
    metric === "tokens"
      ? formatTokensCompact(sample.totals.totalTokens, 2)
      : sample.label;
  if (
    data.resolvedRange.granularity === "hour" &&
    data.coverage?.precision === "day"
  )
    return (
      <div className={cn("p-4", className)}>
        <h2 className="font-semibold">
          {headerTitle ?? `${title} · ${t("Hourly", "按小时")}`}
        </h2>
        <p className="mt-4 flex h-[180px] items-center justify-center text-center text-muted-foreground">
          {t(
            "Hourly data is unavailable for some usage.",
            "部分用量缺少小时级数据，无法绘制小时趋势。",
          )}
        </p>
      </div>
    );
  const samples = data.samples;
  const present = new Set(
    samples.flatMap((sample) =>
      sample.segments.map((segment) => segment.service),
    ),
  );
  const services = [
    ...bootstrap.visibleUsageServices.filter((service) => present.has(service)),
    ...Array.from(present).filter(
      (service) => !bootstrap.visibleUsageServices.includes(service),
    ),
  ];
  const colorFor = (service: (typeof services)[number]) =>
    brandColor(service, settings, bootstrap.appearance === "dark");
  const aggregateColor = service ? colorFor(service) : "var(--foreground)";
  const areaBands =
    isArea && !empty ? dashboardAreaPaths(samples, services, metric) : [];
  const indices = new Set(
    samples
      .map((_, i) => i)
      .filter(
        (i) =>
          i === 0 ||
          i === samples.length - 1 ||
          i % Math.max(1, Math.ceil(samples.length / 8)) === 0,
      ),
  );
  const fmt = new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
    timeZone: bootstrap.timeZone,
    ...(data.resolvedRange.granularity === "hour"
      ? { hour: "2-digit", minute: "2-digit" }
      : data.resolvedRange.granularity === "month"
        ? { year: "numeric", month: "short" }
        : { month: "2-digit", day: "2-digit" }),
  });
  return (
    <div className={cn("p-4", className)}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-semibold">
          {headerTitle ?? (
            <>
              {title} ·{" "}
              {data.resolvedRange.granularity === "hour"
                ? t("Hourly", "按小时")
                : data.resolvedRange.granularity === "month"
                  ? t("Monthly", "按月")
                  : data.resolvedRange.granularity === "week"
                    ? t("Weekly", "按周")
                    : t("Daily", "按天")}
            </>
          )}
        </h2>
        {!isCacheHitRate && (
          <div
            aria-label={t("Applications", "应用")}
            className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted-foreground"
          >
            {services.map((service) => (
              <span key={service} className="inline-flex items-center gap-1">
                <span
                  aria-hidden="true"
                  className="size-2 rounded-sm"
                  style={{ backgroundColor: colorFor(service) }}
                />
                {serviceDisplayName(service)}
              </span>
            ))}
          </div>
        )}
      </div>
      <div className="mt-4 flex gap-2">
        <div
          data-slot="dashboard-y-axis"
          className="relative h-40 w-max shrink-0 whitespace-nowrap text-right text-[11px] text-muted-foreground"
        >
          <div
            data-slot="dashboard-axis-measure"
            aria-hidden="true"
            className="invisible flex w-max flex-col"
          >
            {data.axisTicks.map((tick) => (
              <span key={tick.position}>{tick.label}</span>
            ))}
          </div>
          {data.axisTicks.map((tick) => (
            <span
              data-slot="dashboard-axis-tick"
              key={tick.position}
              className="absolute right-0 translate-y-1/2"
              style={{ bottom: `${tick.position * 100}%` }}
            >
              {tick.label}
            </span>
          ))}
        </div>
        <div className="min-w-[5rem] flex-1">
          <div ref={plot} className="relative flex h-40 items-end border-b">
            <div className="pointer-events-none absolute inset-x-0 top-0 border-t" />
            <div className="pointer-events-none absolute inset-x-0 top-1/2 border-t" />
            {isArea && (
              <svg
                data-slot="dashboard-area"
                aria-hidden="true"
                className="pointer-events-none absolute inset-0 h-full w-full overflow-visible"
                viewBox="0 0 100 100"
                preserveAspectRatio="none"
              >
                {areaBands.map((band) => {
                  const color = band.service
                    ? colorFor(band.service)
                    : aggregateColor;
                  return (
                    <g
                      key={band.service ?? "total"}
                      data-service={band.service ?? undefined}
                    >
                      <path d={band.fill} fill={color} fillOpacity={0.55} />
                      <path
                        d={band.line}
                        fill="none"
                        stroke={color}
                        strokeWidth={1.5}
                        vectorEffect="non-scaling-stroke"
                      />
                    </g>
                  );
                })}
              </svg>
            )}
            {(empty ? [] : samples).map((s) => (
              <ChartDataTooltipTrigger
                key={s.key}
                handle={tooltipHandle}
                payload={s.key}
                render={
                  <button
                    type="button"
                    className="cc-chart-column-guide group relative z-0 flex h-full min-w-0 flex-1 items-end justify-center"
                    aria-label={`${fmt.format(new Date(s.start))}: ${valueLabel(s)}; ${
                      isCacheHitRate
                        ? `${t("Cache read tokens", "命中 Tokens")}: ${formatTokensCompact(s.totals.cacheReadTokens, 2)}`
                        : s.segments
                            .map(
                              (segment) =>
                                `${serviceDisplayName(segment.service)}: ${valueLabel(segment)}, ${(segment.share * 100).toFixed(1)}%`,
                            )
                            .join("; ")
                    }`}
                  />
                }
              >
                {isArea ? (
                  <span
                    aria-hidden="true"
                    className="pointer-events-none absolute z-10 size-1.5 translate-y-1/2 rounded-full border border-background bg-foreground opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
                    style={{
                      bottom: `${Math.max(0, Math.min(1, s.normalizedValue)) * 100}%`,
                    }}
                  />
                ) : (
                  <span
                    data-slot="dashboard-bar"
                    className="relative z-10 flex shrink-0 flex-col-reverse overflow-hidden rounded-t-[2px]"
                    style={{
                      width: chartBarWidth(samples.length),
                      maxWidth: "100%",
                      height: `${Math.max(0, Math.min(1, s.normalizedValue)) * 100}%`,
                      backgroundColor: isCacheHitRate
                        ? service
                          ? colorFor(service)
                          : "var(--foreground)"
                        : undefined,
                    }}
                  >
                    {!isCacheHitRate &&
                      s.segments
                        .filter((segment) => segment.share > 0)
                        .map((segment) => (
                          <span
                            key={segment.service}
                            data-service={segment.service}
                            style={{
                              height: `${Math.max(0, Math.min(1, segment.share)) * 100}%`,
                              backgroundColor: colorFor(segment.service),
                              flexShrink: 0,
                            }}
                          />
                        ))}
                  </span>
                )}
              </ChartDataTooltipTrigger>
            ))}
            <ChartDataTooltip
              handle={tooltipHandle}
              placement="bar"
              plotRef={plot}
            >
              {({ payload: key }) => {
                const s = samples.find((sample) => sample.key === key);
                if (!s || empty) return null;
                return (
                  <ChartDataTooltipContent className="w-[200px]">
                    <strong>
                      {formatDate(
                        s.start,
                        bootstrap.resolvedLanguage,
                        bootstrap.timeZone,
                        data.resolvedRange.granularity === "hour",
                      )}
                    </strong>
                    <span>
                      {title}: {valueLabel(s)}
                    </span>
                    {isCacheHitRate ? (
                      <span>
                        {t("Cache read tokens", "命中 Tokens")}:{" "}
                        {formatTokensCompact(s.totals.cacheReadTokens, 2)}
                      </span>
                    ) : (
                      s.segments.map((segment) => (
                        <span
                          key={segment.service}
                          className="flex items-center gap-1.5"
                        >
                          <span
                            aria-hidden="true"
                            className="size-2 shrink-0 rounded-sm"
                            style={{
                              backgroundColor: colorFor(segment.service),
                            }}
                          />
                          <span className="min-w-0 flex-1">
                            {serviceDisplayName(segment.service)}
                          </span>
                          <span className="max-w-[55%] break-words text-right">
                            {valueLabel(segment)} ·{" "}
                            {(segment.share * 100).toFixed(1)}%
                          </span>
                        </span>
                      ))
                    )}
                  </ChartDataTooltipContent>
                );
              }}
            </ChartDataTooltip>
          </div>
          <div className="relative h-5 text-[10px] text-muted-foreground">
            {samples.map(
              (s, i) =>
                indices.has(i) && (
                  <span
                    key={s.key}
                    className="absolute top-1 -translate-x-1/2 whitespace-nowrap"
                    style={{ left: `${((i + 0.5) / samples.length) * 100}%` }}
                  >
                    {fmt.format(new Date(s.start))}
                  </span>
                ),
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
export { HeatmapBlocks } from "./dashboard-heatmap";
