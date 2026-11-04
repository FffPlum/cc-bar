import { useMemo, useRef, useState, type CSSProperties } from "react";
import type { DashboardHeatmap } from "@ccbar/host-api/window";
import {
  ChartDataTooltip,
  ChartDataTooltipContent,
  ChartDataTooltipTrigger,
  createChartDataTooltipHandle,
} from "@/components/chart-data-tooltip";
import { ChartViewTransition } from "@/components/chart-view-transition";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useHost } from "@/host/host-context";
import { formatTokensCompact } from "@/lib/display";
import {
  heatmapColorAtIntensity,
  heatmapTokenIntensity,
} from "@/lib/heatmap-scale";
import {
  buildHeatmapSeries,
  type HeatmapSeriesPoint,
} from "@/lib/heatmap-series";
import { useTranslation } from "@/lib/i18n";
import { buildTokenAxisScale, type TokenAxisMode } from "@/lib/token-axis-scale";
import "./dashboard-heatmap.css";

type HeatmapView = "daily" | "weekly" | "cumulative";
const dayMilliseconds = 86_400_000;
const chartColor = heatmapColorAtIntensity(0.5);

export function HeatmapBlocks({
  blocks,
  today,
  weeklyScale = "linear",
}: {
  blocks: DashboardHeatmap[];
  today?: string;
  weeklyScale?: TokenAxisMode;
}) {
  const [view, setView] = useState<HeatmapView>("daily");
  const t = useTranslation();
  // Keep a single latest 53-week window, even if an older cache contains pages.
  const block = blocks.reduce<DashboardHeatmap | undefined>(
    (latest, item) =>
      !latest || item.fromDay > latest.fromDay ? item : latest,
    undefined,
  );
  const series = useMemo(
    () => buildHeatmapSeries(block ? [block] : [], today ?? block?.toDay ?? ""),
    [block, today],
  );
  if (!block) return null;
  const titles = {
    daily: t("Usage heatmap", "用量热力图"),
    weekly: t("Weekly token usage", "每周 Token 用量"),
    cumulative: t("Cumulative Token Usage", "历史累计用量"),
  };
  const descriptions = {
    daily: t(
      "Daily Tokens over the last 53 weeks",
      "最近 53 周的每日 Token 用量",
    ),
    weekly: t(
      "Monday–Sunday totals over the last 53 weeks",
      "最近 53 周，按周一至周日汇总",
    ),
    cumulative: t(
      "Lifetime total through each day; showing the last 53 weeks",
      "从首次记录累计至每天，展示最近 53 周",
    ),
  };
  return (
    <Tabs
      value={view}
      onValueChange={(value) => {
        if (value === "daily" || value === "weekly" || value === "cumulative")
          setView(value);
      }}
      className="min-w-0 gap-0 p-4"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="font-semibold">{titles[view]}</h2>
          <p className="text-muted-foreground">{descriptions[view]}</p>
        </div>
        <TabsList
          aria-label={t("Token usage view", "Token 用量视图")}
          className="shrink-0"
        >
          <TabsTrigger value="daily">{t("Daily", "每天")}</TabsTrigger>
          <TabsTrigger value="weekly">{t("Weekly", "每周")}</TabsTrigger>
          <TabsTrigger value="cumulative">
            {t("Cumulative", "历史累计")}
          </TabsTrigger>
        </TabsList>
      </div>
      <TabsContent value={view} className="cc-token-chart-window mt-3">
        <ChartViewTransition view={view}>
          {(displayedView, interactive) =>
            displayedView === "daily" ? (
              <DailyHeatmap
                block={block}
                today={today}
                interactive={interactive}
              />
            ) : (
              <TokenSeriesChart
                key={displayedView}
                block={block}
                points={series[displayedView]}
                view={displayedView}
                interactive={interactive}
                scale={displayedView === "weekly" ? weeklyScale : "linear"}
              />
            )
          }
        </ChartViewTransition>
      </TabsContent>
    </Tabs>
  );
}

function DailyHeatmap({
  block,
  today,
  interactive,
}: {
  block: DashboardHeatmap;
  today?: string;
  interactive: boolean;
}) {
  const [handle] = useState(() => createChartDataTooltipHandle<string>());
  const { bootstrap } = useHost();
  return (
    <div
      className="w-full min-w-0 max-w-[1004px]"
      data-slot="daily-token-chart"
    >
      <div className="cc-token-chart-plot">
        <div className="grid h-full w-full min-w-0 grid-flow-col grid-rows-7 grid-cols-[repeat(53,minmax(0,1fr))] gap-[3px]">
          {block.days.map((day) =>
            today && day.day > today ? (
              <span
                key={day.day}
                aria-hidden="true"
                className="aspect-square w-full min-w-0 max-h-4"
              />
            ) : (
              <ChartDataTooltipTrigger
                key={day.day}
                handle={handle}
                payload={day.day}
                render={
                  <button
                    type="button"
                    aria-label={`${day.day}: ${day.totals.totalTokens.toLocaleString(bootstrap.resolvedLanguage)} Tokens`}
                    className="cc-heatmap-color aspect-square w-full min-w-0 max-h-4 rounded-[3px]"
                    data-empty={day.totals.totalTokens > 0 ? undefined : ""}
                    style={
                      {
                        "--cc-heatmap-color": heatmapColorAtIntensity(
                          heatmapTokenIntensity(day.totals.totalTokens),
                        ),
                      } as CSSProperties
                    }
                  />
                }
              />
            ),
          )}
        </div>
      </div>
      <MonthLabels block={block} />
      <ChartDataTooltip
        handle={handle}
        placement="cell"
        disabled={!interactive}
      >
        {({ payload: key }) => {
          const day = block.days.find((item) => item.day === key);
          if (!day || (today && day.day > today)) return null;
          return (
            <ChartDataTooltipContent className="w-[200px]">
              <strong>{day.day}</strong>
              <span>
                Tokens: {formatTokensCompact(day.totals.totalTokens, 2)}
              </span>
            </ChartDataTooltipContent>
          );
        }}
      </ChartDataTooltip>
    </div>
  );
}

function TokenSeriesChart({
  block,
  points,
  view,
  interactive,
  scale,
}: {
  block: DashboardHeatmap;
  points: HeatmapSeriesPoint[];
  view: "weekly" | "cumulative";
  interactive: boolean;
  scale: TokenAxisMode;
}) {
  const [handle] = useState(() => createChartDataTooltipHandle<string>());
  const [activeDay, setActiveDay] = useState<string | null>(null);
  const plot = useRef<HTMLDivElement>(null);
  const t = useTranslation();
  const start = Date.parse(`${block.fromDay}T00:00:00Z`);
  const span = Math.max(
    dayMilliseconds,
    Date.parse(`${block.toDay}T00:00:00Z`) - start,
  );
  const step = view === "weekly" ? 7 : 1;
  const x = (day: string) =>
    (Date.parse(`${day}T00:00:00Z`) - start + (step * dayMilliseconds) / 2) /
    span;
  const axis = useMemo(() => {
    if (view === "weekly") {
      return buildTokenAxisScale(points.map((point) => point.tokens), scale);
    }
    const maximum = Math.max(1, ...points.map((point) => point.tokens));
    const magnitude = 10 ** Math.floor(Math.log10(maximum));
    const ceiling =
      maximum < 10
        ? Math.max(2, Math.ceil(maximum / 2) * 2)
        : Math.ceil(maximum / magnitude) * magnitude;
    return {
      normalize: (tokens: number) => tokens / ceiling,
      ticks: [0, ceiling / 2, ceiling].map((value) => ({
        value,
        label: formatTokensCompact(value),
      })),
    };
  }, [points, scale, view]);
  const { ticks, normalize } = axis;
  const y = (tokens: number) => 156 - normalize(tokens) * 152;
  const active = interactive
    ? points.find((point) => point.day === activeDay)
    : undefined;
  // Missing calendar dates are gaps, not interpolated usage observations.
  const lines = points.reduce<HeatmapSeriesPoint[][]>((groups, point) => {
    const previous = groups.at(-1)?.at(-1);
    if (
      !previous ||
      Date.parse(point.day) - Date.parse(previous.day) !== dayMilliseconds
    )
      groups.push([]);
    groups.at(-1)!.push(point);
    return groups;
  }, []);
  const describe = (point: HeatmapSeriesPoint) =>
    `${point.fromDay} – ${point.toDay}: ${formatTokensCompact(point.tokens, 2)} Tokens${view === "weekly" && point.partial ? ` · ${point.dayCount}/7 ${t("days", "天")}` : ""}`;
  return (
    <div
      className="flex w-full min-w-0 max-w-[1004px] gap-2"
      data-slot={`${view}-token-chart`}
      data-scale={scale}
    >
      <div className="cc-token-chart-plot relative w-max shrink-0 whitespace-nowrap text-right text-[10px] tabular-nums text-muted-foreground">
        <div aria-hidden="true" className="invisible flex w-max flex-col">
          {ticks.map((tick) => (
            <span key={tick.value}>{tick.label}</span>
          ))}
        </div>
        {ticks.map((tick) => (
          <span
            data-slot="token-value-tick"
            key={tick.value}
            className="absolute right-0 -translate-y-1/2"
            style={{ top: `${(y(tick.value) / 160) * 100}%` }}
          >
            {tick.label}
          </span>
        ))}
      </div>
      <div className="min-w-0 flex-1">
        <div
          ref={plot}
          className="cc-token-chart-plot relative"
          onMouseLeave={() => setActiveDay(null)}
          onBlur={() => setActiveDay(null)}
        >
          {ticks.map((tick) => (
            <div
              key={tick.value}
              data-slot="token-value-gridline"
              className="pointer-events-none absolute inset-x-0 border-t"
              style={{ top: `${(y(tick.value) / 160) * 100}%` }}
            />
          ))}
          {view === "cumulative" && (
            <svg
              viewBox="0 0 1000 160"
              preserveAspectRatio="none"
              className="pointer-events-none absolute inset-0 h-full w-full overflow-visible"
              aria-hidden="true"
            >
              {lines.map((line) =>
                line.length > 1 ? (
                  <polyline
                    key={line[0]!.day}
                    data-slot="cumulative-token-line"
                    fill="none"
                    stroke={chartColor}
                    strokeWidth="2"
                    strokeLinejoin="round"
                    strokeLinecap="round"
                    vectorEffect="non-scaling-stroke"
                    points={line
                      .map(
                        (point) => `${x(point.day) * 1000},${y(point.tokens)}`,
                      )
                      .join(" ")}
                  />
                ) : (
                  <line
                    key={line[0]!.day}
                    x1={x(line[0]!.day) * 1000}
                    x2={x(line[0]!.day) * 1000 + 0.1}
                    y1={y(line[0]!.tokens)}
                    y2={y(line[0]!.tokens)}
                    stroke={chartColor}
                    strokeWidth="3"
                    strokeLinecap="round"
                    vectorEffect="non-scaling-stroke"
                  />
                ),
              )}
            </svg>
          )}
          {points.map((point) => (
            <ChartDataTooltipTrigger
              key={point.day}
              handle={handle}
              payload={point.day}
              render={
                <button
                  type="button"
                  aria-label={describe(point)}
                  className={`absolute inset-y-0 flex min-w-0 items-end justify-center ${view === "weekly" ? "cc-chart-column-guide" : "hover:bg-muted/60 focus-visible:bg-muted/60"}`}
                  style={{
                    left: `${(x(point.day) - (step * dayMilliseconds) / span / 2) * 100}%`,
                    width: `${((step * dayMilliseconds) / span) * 100}%`,
                  }}
                  onMouseEnter={() => setActiveDay(point.day)}
                  onFocus={() => setActiveDay(point.day)}
                />
              }
            >
              {view === "weekly" && (
                <span
                  data-slot="weekly-token-bar"
                  className="pointer-events-none absolute bottom-[2.5%] w-2/3 max-w-[12px] rounded-t-[2px]"
                  style={{
                    height: `${normalize(point.tokens) * 95}%`,
                    backgroundColor: chartColor,
                  }}
                />
              )}
            </ChartDataTooltipTrigger>
          ))}
          {view === "cumulative" && active && (
            <span
              aria-hidden="true"
              className="pointer-events-none absolute size-1.5 -translate-x-1/2 -translate-y-1/2 rounded-full"
              style={{
                left: `${x(active.day) * 100}%`,
                top: `${(y(active.tokens) / 160) * 100}%`,
                backgroundColor: chartColor,
              }}
            />
          )}
          <ChartDataTooltip
            handle={handle}
            placement="bar"
            plotRef={plot}
            disabled={!interactive}
          >
            {({ payload: key }) => {
              const point = points.find((item) => item.day === key);
              if (!point) return null;
              return (
                <ChartDataTooltipContent className="w-[220px]">
                  <strong>
                    {point.fromDay} – {point.toDay}
                  </strong>
                  <span>Tokens: {formatTokensCompact(point.tokens, 2)}</span>
                  {view === "weekly" && point.partial && (
                    <span className="text-muted-foreground">
                      {t("Available days", "已统计天数")}: {point.dayCount}/7
                    </span>
                  )}
                </ChartDataTooltipContent>
              );
            }}
          </ChartDataTooltip>
        </div>
        <MonthLabels block={block} />
      </div>
    </div>
  );
}

function MonthLabels({ block }: { block: DashboardHeatmap }) {
  const { bootstrap } = useHost();
  const weeks = Array.from({ length: 53 }, (_, index) => {
    const date = new Date(`${block.fromDay}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + index * 7);
    return date.toISOString().slice(0, 10);
  });
  const starts = weeks.flatMap((day, index) =>
    index === 0 || day.slice(0, 7) !== weeks[index - 1]!.slice(0, 7)
      ? [{ day, start: index }]
      : [],
  );
  const fmt = new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
    month: "short",
    timeZone: "UTC",
  });
  return (
    <div
      data-slot="heatmap-month-labels"
      className="mt-1 grid h-5 min-w-0 grid-cols-[repeat(53,minmax(0,1fr))] gap-[3px] text-[10px] text-muted-foreground"
    >
      {starts.map((month, index) => {
        const count = (starts[index + 1]?.start ?? 53) - month.start;
        if (count < 3) return null;
        return (
          <span
            key={month.day}
            className="min-w-0 truncate"
            style={{ gridColumn: `${month.start + 1} / span ${count}` }}
          >
            {fmt.format(new Date(`${month.day}T00:00:00Z`))}
          </span>
        );
      })}
    </div>
  );
}
