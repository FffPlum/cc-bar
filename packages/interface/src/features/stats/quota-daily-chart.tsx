import { useLayoutEffect, useRef, useState } from "react";
import type { QuotaAccount, UsageService } from "@ccbar/host-api/window";
import {
  ChartDataTooltip,
  ChartDataTooltipContent,
  ChartDataTooltipTrigger,
  createChartDataTooltipHandle,
} from "@/components/chart-data-tooltip";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { formatDate, formatInteger, serviceDisplayName } from "@/lib/display";
import { cn } from "@/lib/utils";
import { quotaAccountSubtitle } from "./quota-account-presentation";

export interface QuotaDailyPoint {
  day: string;
  tokens: number | null;
  estimatedUsedPercent: number | null;
  partial?: boolean;
}

export interface QuotaDailyChartRow {
  account: QuotaAccount;
  points: QuotaDailyPoint[];
  color: string;
  loading?: boolean;
  error?: boolean;
  unavailable?: boolean;
}

interface PlotPoint {
  key: string;
  day: string;
  dayIndex: number;
  value: number;
  label: string;
  tokens: number | null;
  partial: boolean;
  accountLabel: string;
  color: string;
}

interface LabelRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

const labelHeight = 16;
const labelGap = 4;

function percentage(value: number, digits = 1) {
  if (value > 0 && value < 10 ** -digits) return `<${10 ** -digits}%`;
  return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: digits }).format(value)}%`;
}

/** A zero-based percentage scale. Estimates above 100 are real chart values. */
export function quotaDailyAxis(values: number[]) {
  const peak = Math.max(0, ...values.filter(Number.isFinite));
  const roughStep = (peak || 100) / 4;
  const magnitude = 10 ** Math.floor(Math.log10(roughStep));
  const unit =
    [1, 2, 2.5, 5, 10].find((item) => item >= roughStep / magnitude) ?? 10;
  const step = unit * magnitude;
  const maximum = Math.ceil((peak || 100) / step) * step;
  const digits = Math.min(6, Math.max(0, -Math.floor(Math.log10(step)) + 1));
  return {
    maximum,
    ticks: Array.from(
      { length: Math.round(maximum / step) + 1 },
      (_, index) => {
        const value = index * step;
        return { value, label: percentage(value, digits) };
      },
    ),
  };
}

function overlaps(left: LabelRect, right: LabelRect) {
  return (
    left.left < right.left + right.width + labelGap &&
    left.left + left.width + labelGap > right.left &&
    left.top < right.top + right.height + labelGap &&
    left.top + left.height + labelGap > right.top
  );
}

/** Place every measured label, expanding the plot when dense days need room.
 * Leader lines preserve the association after a label moves off its point. */
export function layoutQuotaDailyLabels(
  points: { key: string; x: number; normalizedY: number; width: number }[],
  plotWidth: number,
) {
  const dayDensity = new Map<number, number>();
  for (const point of points)
    dayDensity.set(point.x, (dayDensity.get(point.x) ?? 0) + 1);
  const density = Math.max(1, ...dayDensity.values());
  const initialHeight = Math.max(
    208,
    density * (labelHeight + labelGap) * 2 + 32,
  );

  const place = (height: number) => {
    const positions = new Map<string, LabelRect>();
    const dots = points.map((point) => ({
      left: point.x - 4,
      top: (1 - point.normalizedY) * height - 4,
      width: 8,
      height: 8,
    }));
    for (const point of points) {
      const pointY = (1 - point.normalizedY) * height;
      const width = Math.min(plotWidth, point.width);
      const left = Math.max(
        0,
        Math.min(plotWidth - width, point.x - width / 2),
      );
      // Try positions immediately above/below the dot before using distant
      // lanes. A grid alone can push labels past several adjacent series.
      const lanes = Array.from(
        {
          length:
            Math.floor((height - labelHeight) / (labelHeight + labelGap)) + 1,
        },
        (_, index) => index * (labelHeight + labelGap),
      );
      const candidates = [pointY - labelHeight - 8, pointY + 8, ...lanes]
        .filter((top) => top >= 0 && top + labelHeight <= height)
        .sort(
          (a, b) =>
            Math.abs(a + labelHeight / 2 - pointY) -
            Math.abs(b + labelHeight / 2 - pointY),
        );
      const top = candidates.find((candidate) => {
        const rect = { left, top: candidate, width, height: labelHeight };
        return (
          ![...positions.values()].some((other) => overlaps(rect, other)) &&
          !dots.some((dot) => overlaps(rect, dot))
        );
      });
      if (top === undefined) return null;
      positions.set(point.key, { left, top, width, height: labelHeight });
    }
    return positions;
  };

  for (let attempt = 0; attempt < 5; attempt++) {
    const height = initialHeight + attempt * Math.max(40, density * 20);
    const positions = place(height);
    if (positions) return { height, positions };
  }
  // Pathological density still keeps all annotations: reserve a separate row
  // per label instead of dropping values or allowing overlapping text.
  const height = Math.max(
    initialHeight,
    points.length * (labelHeight + labelGap) + 32,
  );
  const positions = new Map(
    points.map((point, index) => {
      const width = Math.min(plotWidth, point.width);
      return [
        point.key,
        {
          left: Math.max(0, Math.min(plotWidth - width, point.x - width / 2)),
          top: index * (labelHeight + labelGap),
          width,
          height: labelHeight,
        },
      ] as const;
    }),
  );
  return { height, positions };
}

export function QuotaDailyChart({ rows }: { rows: QuotaDailyChartRow[] }) {
  const { bootstrap } = useHost();
  const t = useTranslation();
  const plot = useRef<HTMLDivElement>(null);
  const labelElements = useRef(new Map<string, HTMLSpanElement>());
  const [plotWidth, setPlotWidth] = useState(640);
  const [labelWidths, setLabelWidths] = useState<Record<string, number>>({});
  const [tooltipHandle] = useState(() =>
    createChartDataTooltipHandle<string>(),
  );
  const days = [
    ...new Set(rows.flatMap((row) => row.points.map((point) => point.day))),
  ].sort((a, b) => Date.parse(a) - Date.parse(b));
  const edgePadding = Math.min(
    plotWidth / 4,
    Math.max(22, ...Object.values(labelWidths).map((width) => width / 2 + 2)),
  );
  const x = (index: number) =>
    days.length <= 1
      ? plotWidth / 2
      : edgePadding +
        (index / (days.length - 1)) * (plotWidth - edgePadding * 2);
  const numberFormat = new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
    timeZone: bootstrap.timeZone,
    month: "numeric",
    day: "numeric",
  });
  const dayLabel = (day: string) => numberFormat.format(new Date(day));
  const fullDayLabel = (day: string) =>
    formatDate(day, bootstrap.resolvedLanguage, bootstrap.timeZone);
  const charts = rows.map((row) => {
    const accountLabel = [
      ...new Set(
        [
          serviceDisplayName(row.account.service as UsageService),
          row.account.name,
          quotaAccountSubtitle(row.account),
        ].filter(Boolean),
      ),
    ].join(" · ");
    const byDay = new Map(row.points.map((point) => [point.day, point]));
    const segments: PlotPoint[][] = [];
    let segment: PlotPoint[] = [];
    days.forEach((day, dayIndex) => {
      const point = byDay.get(day);
      const value = point?.estimatedUsedPercent;
      if (
        value === null ||
        value === undefined ||
        !Number.isFinite(value) ||
        value < 0
      ) {
        if (segment.length) segments.push(segment);
        segment = [];
        return;
      }
      segment.push({
        key: `${row.account.id}:${day}`,
        day,
        dayIndex,
        value,
        label: percentage(value),
        tokens: point?.tokens ?? null,
        partial: point?.partial ?? false,
        accountLabel,
        color: row.color,
      });
    });
    if (segment.length) segments.push(segment);
    return {
      ...row,
      accountLabel,
      segments,
      incomplete: row.points.some((point) => point.partial),
      points: segments.flat(),
    };
  });
  const points = charts
    .flatMap((chart) => chart.points)
    .sort((a, b) => a.dayIndex - b.dayIndex || b.value - a.value);
  const axis = quotaDailyAxis(points.map((point) => point.value));
  const labels = layoutQuotaDailyLabels(
    points.map((point) => ({
      key: point.key,
      x: x(point.dayIndex),
      normalizedY: point.value / axis.maximum,
      width: labelWidths[point.key] ?? point.label.length * 7 + 4,
    })),
    plotWidth,
  );
  const y = (value: number) => (1 - value / axis.maximum) * labels.height;
  const labelSignature = points
    .map((point) => `${point.key}:${point.label}`)
    .join("|");

  useLayoutEffect(() => {
    const element = plot.current;
    if (!element) return;
    const measure = () => {
      const width = element.getBoundingClientRect().width;
      if (width > 0)
        setPlotWidth((previous) =>
          Math.abs(previous - width) < 0.5 ? previous : width,
        );
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useLayoutEffect(() => {
    const widths = Object.fromEntries(
      [...labelElements.current].flatMap(([key, element]) => {
        const width = element.getBoundingClientRect().width;
        return width > 0 ? [[key, Math.ceil(width) + 4]] : [];
      }),
    );
    setLabelWidths((previous) =>
      Object.keys(previous).length === Object.keys(widths).length &&
      Object.entries(widths).every(([key, width]) => previous[key] === width)
        ? previous
        : widths,
    );
  }, [labelSignature]);

  const locations = new Map<string, PlotPoint[]>();
  for (const point of points) {
    const key = `${point.day}:${point.value}`;
    locations.set(key, [...(locations.get(key) ?? []), point]);
  }
  const loading = rows.some((row) => row.loading);
  const errors = rows.some((row) => row.error);
  const emptyMessage = loading
    ? t("Loading daily usage…", "正在读取每日用量…")
    : errors || rows.some((row) => row.unavailable)
      ? t("Daily usage is temporarily unavailable.", "每日用量暂不可用。")
      : t(
          "No daily estimates yet. A weekly allowance estimate and recorded usage are needed.",
          "暂无每日估算，需要周额度预估与已记录用量。",
        );
  const tickStride = Math.max(
    1,
    Math.ceil(days.length / Math.max(2, Math.floor(plotWidth / 65))),
  );
  const visibleDays = days.filter(
    (_, index) =>
      index === 0 ||
      index === days.length - 1 ||
      (index % tickStride === 0 && index < days.length - 1 - tickStride / 2),
  );
  const tooltipPoints = new Map(points.map((point) => [point.key, [point]]));
  for (const [key, location] of locations)
    tooltipPoints.set(`location:${key}`, location);

  return (
    <section className="min-w-0 rounded-lg border" aria-busy={loading}>
      <header className="space-y-1 border-b px-4 py-3">
        <h3 className="text-[13px] font-semibold">
          {t("Daily quota trend", "每日额度趋势")}
        </h3>
        <p className="text-[11px] text-muted-foreground">
          {t(
            "Estimated from local Token usage and the weekly allowance.",
            "按本机 Token 用量与周额度折算，数值为估算。",
          )}
        </p>
      </header>
      <div className="space-y-4 p-4">
        <ul
          className="flex min-w-0 flex-wrap gap-x-4 gap-y-2 text-[11px] text-muted-foreground"
          aria-label={t("Quota accounts", "额度账号")}
        >
          {charts.map((chart) => (
            <li
              key={chart.account.id}
              className="flex min-w-0 max-w-full flex-wrap items-center gap-1.5"
            >
              <span
                aria-hidden="true"
                className="h-0.5 w-5 shrink-0 rounded-full"
                style={{ backgroundColor: chart.color }}
              />
              <span className="min-w-0 break-words">{chart.accountLabel}</span>
              {(chart.loading ||
                chart.error ||
                chart.unavailable ||
                !chart.points.length ||
                chart.incomplete) && (
                <span className="shrink-0">
                  ·{" "}
                  {chart.loading
                    ? t("Updating…", "更新中…")
                    : chart.error
                      ? t("Update failed", "更新失败")
                      : chart.unavailable
                        ? t("Daily usage unavailable", "每日用量暂不可用")
                        : !chart.points.length
                          ? chart.incomplete
                            ? t(
                                "Incomplete · no estimate",
                                "记录不完整 · 暂无估算",
                              )
                            : t("No estimate", "暂无估算")
                          : t("Incomplete", "记录不完整")}
                </span>
              )}
            </li>
          ))}
        </ul>
        <div
          className="flex gap-2 pt-2"
          role="group"
          aria-label={t(
            "Estimated daily share of weekly quota",
            "每日用量占周额度的估算比例",
          )}
        >
          <div
            className="cc-number relative w-max shrink-0 whitespace-nowrap text-right text-[11px] text-muted-foreground"
            style={{ height: labels.height }}
            aria-hidden="true"
          >
            <div className="invisible flex flex-col">
              {axis.ticks.map((tick) => (
                <span key={tick.value}>{tick.label}</span>
              ))}
            </div>
            {axis.ticks.map((tick) => (
              <span
                key={tick.value}
                className="absolute right-0 -translate-y-1/2"
                style={{ top: y(tick.value) }}
              >
                {tick.label}
              </span>
            ))}
          </div>
          <div className="min-w-0 flex-1">
            <div
              ref={plot}
              className="relative"
              style={{ height: labels.height }}
            >
              {axis.ticks.map((tick) => (
                <div
                  key={tick.value}
                  className="pointer-events-none absolute inset-x-0 border-t border-border/60"
                  style={{ top: y(tick.value) }}
                  aria-hidden="true"
                />
              ))}
              <svg
                viewBox={`0 0 ${plotWidth} ${labels.height}`}
                preserveAspectRatio="none"
                className="pointer-events-none absolute inset-0 h-full w-full overflow-visible"
                aria-hidden="true"
              >
                {charts.flatMap((chart) =>
                  chart.segments.map((segment, index) => (
                    <polyline
                      key={`${chart.account.id}:${index}`}
                      data-slot="quota-daily-segment"
                      fill="none"
                      stroke={chart.color}
                      strokeWidth="2"
                      vectorEffect="non-scaling-stroke"
                      strokeLinejoin="round"
                      points={segment
                        .map(
                          (point) => `${x(point.dayIndex)},${y(point.value)}`,
                        )
                        .join(" ")}
                    />
                  )),
                )}
                {points.map((point) => {
                  const label = labels.positions.get(point.key)!;
                  return (
                    <line
                      key={point.key}
                      x1={x(point.dayIndex)}
                      y1={y(point.value)}
                      x2={label.left + label.width / 2}
                      y2={label.top + label.height / 2}
                      stroke={point.color}
                      strokeWidth="0.75"
                      opacity="0.45"
                      vectorEffect="non-scaling-stroke"
                    />
                  );
                })}
              </svg>
              {[...locations.entries()].map(([key, location]) => {
                const first = location[0]!;
                const background =
                  location.length === 1
                    ? first.color
                    : `conic-gradient(${location.map((point, index) => `${point.color} ${(index / location.length) * 100}% ${((index + 1) / location.length) * 100}%`).join(",")})`;
                return (
                  <ChartDataTooltipTrigger
                    key={key}
                    handle={tooltipHandle}
                    payload={`location:${key}`}
                    render={
                      <button
                        type="button"
                        tabIndex={-1}
                        className="absolute z-10 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full"
                        style={{ left: x(first.dayIndex), top: y(first.value) }}
                        aria-label={`${fullDayLabel(first.day)}: ${location.map((point) => `${point.accountLabel} ≈ ${point.label}`).join("; ")}`}
                      />
                    }
                  >
                    <span
                      data-slot="quota-daily-dot"
                      aria-hidden="true"
                      className="absolute inset-0 m-auto size-1.5 rounded-full"
                      style={{ background }}
                    />
                  </ChartDataTooltipTrigger>
                );
              })}
              {points.map((point) => {
                const label = labels.positions.get(point.key)!;
                return (
                  <ChartDataTooltipTrigger
                    key={point.key}
                    handle={tooltipHandle}
                    payload={point.key}
                    render={
                      <button
                        type="button"
                        className="cc-number absolute z-20 whitespace-nowrap rounded-sm bg-background/90 px-0.5 text-[11px] leading-4 outline-none focus-visible:ring-1 focus-visible:ring-ring"
                        style={{
                          left: label.left,
                          top: label.top,
                          height: label.height,
                          color: point.color,
                        }}
                        aria-label={`${point.accountLabel} · ${fullDayLabel(point.day)} · ${t("Estimated", "估算")} ${point.label}`}
                      />
                    }
                  >
                    <span
                      ref={(element) => {
                        if (element)
                          labelElements.current.set(point.key, element);
                        else labelElements.current.delete(point.key);
                      }}
                    >
                      {point.label}
                    </span>
                  </ChartDataTooltipTrigger>
                );
              })}
              {!points.length && (
                <p
                  role="status"
                  className="absolute inset-0 flex items-center justify-center px-6 text-center text-[12px] text-muted-foreground"
                >
                  {emptyMessage}
                </p>
              )}
              <ChartDataTooltip
                handle={tooltipHandle}
                placement="bar"
                plotRef={plot}
              >
                {({ payload: key }) => {
                  const active = key ? tooltipPoints.get(key) : undefined;
                  if (!active?.length) return null;
                  return (
                    <ChartDataTooltipContent className="cc-number w-[240px]">
                      <strong>{fullDayLabel(active[0]!.day)}</strong>
                      {active.map((point) => (
                        <div
                          key={point.key}
                          className="grid min-w-0 gap-1.5 border-t border-border/50 pt-1.5"
                        >
                          <span className="flex items-start gap-1.5 font-medium">
                            <span
                              className="mt-1 size-2 shrink-0 rounded-sm"
                              style={{ backgroundColor: point.color }}
                            />
                            <span className="min-w-0 break-words">
                              {point.accountLabel}
                            </span>
                          </span>
                          <span className="flex justify-between gap-3">
                            <span>{t("Local Tokens", "本机 Token")}</span>
                            <span>
                              {point.tokens === null
                                ? "—"
                                : formatInteger(
                                    point.tokens,
                                    bootstrap.resolvedLanguage,
                                  )}
                            </span>
                          </span>
                          <span className="flex justify-between gap-3">
                            <span>
                              {t("Estimated quota usage", "估算额度用量")}
                            </span>
                            <span>≈ {point.label}</span>
                          </span>
                          {point.partial && (
                            <span className="text-muted-foreground">
                              {t(
                                "Incomplete local usage",
                                "本机用量记录不完整",
                              )}
                            </span>
                          )}
                        </div>
                      ))}
                    </ChartDataTooltipContent>
                  );
                }}
              </ChartDataTooltip>
            </div>
            <div
              className="cc-number relative h-7 text-[11px] text-muted-foreground"
              aria-hidden="true"
            >
              {visibleDays.map((day) => {
                const index = days.indexOf(day);
                return (
                  <span
                    key={day}
                    className={cn(
                      "absolute top-2 whitespace-nowrap",
                      index === 0
                        ? ""
                        : index === days.length - 1
                          ? "-translate-x-full"
                          : "-translate-x-1/2",
                    )}
                    style={{ left: x(index) }}
                  >
                    {dayLabel(day)}
                  </span>
                );
              })}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
