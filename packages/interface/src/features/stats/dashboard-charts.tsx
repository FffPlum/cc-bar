import type { DashboardHeatmap, UsageDashboard } from "@ccbar/host-api/window";
import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from "@/components/ui/tooltip";
import { Button } from "@/components/ui/button";
import { chartBarWidth } from "@/components/stacked-bar-chart";
import { brandColor, serviceDisplayName } from "@/lib/display";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";

export function DashboardChart({
  data,
  title,
  empty = false,
}: {
  data: UsageDashboard;
  title: string;
  empty?: boolean;
}) {
  const { bootstrap, settings } = useHost();
  const t = useTranslation();
  if (
    data.resolvedRange.granularity === "hour" &&
    data.coverage.precision === "day"
  )
    return (
      <div className="p-4">
        <h2 className="font-semibold">
          {title} · {t("Hourly", "按小时")}
        </h2>
        <p className="py-12 text-center text-muted-foreground">
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
    <div className="p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-semibold">
          {title} ·{" "}
          {data.resolvedRange.granularity === "hour"
            ? t("Hourly", "按小时")
            : data.resolvedRange.granularity === "month"
              ? t("Monthly", "按月")
              : t("Daily", "按天")}
        </h2>
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
      </div>
      <div className="mt-4 flex gap-2">
        <div className="relative h-40 w-20 shrink-0 text-right text-[11px] text-muted-foreground">
          {data.axisTicks.map((tick) => (
            <span
              key={tick.position}
              className="absolute right-0 translate-y-1/2"
              style={{ bottom: `${tick.position * 100}%` }}
            >
              {tick.label}
            </span>
          ))}
        </div>
        <div className="min-w-[5rem] flex-1">
          <div className="relative flex h-40 items-end border-b">
            <div className="pointer-events-none absolute inset-x-0 top-0 border-t" />
            <div className="pointer-events-none absolute inset-x-0 top-1/2 border-t" />
            {(empty ? [] : samples).map((s) => (
              <Tooltip key={s.key}>
                <TooltipTrigger
                  render={
                    <button
                      type="button"
                      className="z-0 flex h-full min-w-0 flex-1 items-end justify-center"
                      aria-label={`${fmt.format(new Date(s.start))}: ${s.label}; ${s.segments
                        .map(
                          (segment) =>
                            `${serviceDisplayName(segment.service)}: ${segment.label}, ${(segment.share * 100).toFixed(1)}%`,
                        )
                        .join("; ")}`}
                    />
                  }
                >
                  <span
                    data-slot="dashboard-bar"
                    className="flex shrink-0 flex-col-reverse overflow-hidden rounded-t-[2px]"
                    style={{
                      width: chartBarWidth(samples.length),
                      maxWidth: "100%",
                      height: `${Math.max(0, Math.min(1, s.normalizedValue)) * 100}%`,
                    }}
                  >
                    {s.segments
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
                </TooltipTrigger>
                <TooltipContent className="w-[260px] max-w-none flex-col items-stretch gap-1 bg-popover text-popover-foreground border p-3 shadow-md">
                  <strong>
                    {new Date(s.start).toLocaleString(
                      bootstrap.resolvedLanguage,
                      { timeZone: bootstrap.timeZone },
                    )}
                  </strong>
                  <span>
                    {title}: {s.label}
                  </span>
                  {s.segments.map((segment) => (
                    <span
                      key={segment.service}
                      className="flex items-center gap-1.5"
                    >
                      <span
                        aria-hidden="true"
                        className="size-2 shrink-0 rounded-sm"
                        style={{ backgroundColor: colorFor(segment.service) }}
                      />
                      <span className="min-w-0 flex-1">
                        {serviceDisplayName(segment.service)}
                      </span>
                      <span className="max-w-[55%] break-words text-right">
                        {segment.label} · {(segment.share * 100).toFixed(1)}%
                      </span>
                    </span>
                  ))}
                  <span>Tokens: {s.totals.totalTokens.toLocaleString()}</span>
                  <span>
                    {t("Requests", "请求")}:{" "}
                    {s.totals.requestCount.toLocaleString()}
                  </span>
                  <span>
                    {t("Cost", "成本")}: {s.totals.costDisplay}
                  </span>
                </TooltipContent>
              </Tooltip>
            ))}
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
export function HeatmapBlocks({
  blocks,
  onOlder,
  loading,
  today,
}: {
  blocks: DashboardHeatmap[];
  onOlder: (day: string) => void;
  loading: boolean;
  today?: string;
}) {
  const { bootstrap } = useHost();
  const t = useTranslation();
  const last = blocks.at(-1);
  return (
    <div className="space-y-5 p-4">
      <div>
        <h2 className="font-semibold">{t("Usage heatmap", "用量热力图")}</h2>
        <p className="text-muted-foreground">
          {t("Daily usage in 53-week windows", "按 53 周分组显示每日用量")}
        </p>
      </div>
      {blocks.map((block) => (
        <div key={block.fromDay}>
          <h3 className="mb-2 font-medium">
            {block.fromDay} –{" "}
            {(() => {
              const lastDay = new Date(
                Date.parse(`${block.toDay}T00:00:00Z`) - 86400000,
              )
                .toISOString()
                .slice(0, 10);
              return today && today < lastDay ? today : lastDay;
            })()}
          </h3>
          <p className="mb-2 text-muted-foreground">
            {block.totals.totalTokens.toLocaleString()} Tokens ·{" "}
            {block.totals.requestCount.toLocaleString()}{" "}
            {t("requests", "次请求")} · {block.totals.costDisplay}
          </p>
          <div className="overflow-x-auto">
            <div className="min-w-[700px]">
              <div className="ml-9 grid grid-cols-[repeat(53,minmax(0,1fr))] text-[10px] text-muted-foreground">
                {Array.from({ length: 53 }, (_, i) => {
                  const day = block.days[i * 7]?.day;
                  const previous = block.days[(i - 1) * 7]?.day;
                  const show =
                    day &&
                    (!previous || day.slice(0, 7) !== previous.slice(0, 7));
                  return (
                    <span
                      key={i}
                      className="overflow-visible whitespace-nowrap"
                    >
                      {show
                        ? new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
                            month: "short",
                            timeZone: "UTC",
                          }).format(new Date(`${day}T00:00:00Z`))
                        : ""}
                    </span>
                  );
                })}
              </div>
              <div className="flex gap-1">
                <div className="flex w-8 shrink-0 flex-col justify-between text-[10px] text-muted-foreground">
                  <span>{t("Mon", "周一")}</span>
                  <span>{t("Wed", "周三")}</span>
                  <span>{t("Fri", "周五")}</span>
                  <span>{t("Sun", "周日")}</span>
                </div>
                <div className="grid flex-1 grid-flow-col grid-rows-7 grid-cols-[repeat(53,minmax(0,1fr))] gap-[3px]">
                  {block.days.map((day) =>
                    today && day.day > today ? (
                      <span
                        key={day.day}
                        aria-hidden="true"
                        className="aspect-square max-h-4"
                      />
                    ) : (
                      <Tooltip key={day.day}>
                        <TooltipTrigger
                          render={
                            <button
                              type="button"
                              aria-label={`${day.day}: ${day.label}`}
                              className="aspect-square max-h-4 rounded-[3px]"
                              style={{
                                backgroundColor:
                                  day.normalizedValue > 0
                                    ? `rgba(8,145,178,${Math.max(0.2, Math.min(1, day.normalizedValue))})`
                                    : "var(--muted)",
                              }}
                            />
                          }
                        />
                        <TooltipContent className="w-[200px] max-w-none flex-col items-stretch gap-1 bg-popover text-popover-foreground border p-3 shadow-md">
                          <strong>{day.day}</strong>
                          <span>
                            Tokens: {day.totals.totalTokens.toLocaleString()}
                          </span>
                          <span>
                            {t("Requests", "请求")}:{" "}
                            {day.totals.requestCount.toLocaleString()}
                          </span>
                          <span>
                            {t("Cost", "成本")}: {day.totals.costDisplay}
                          </span>
                        </TooltipContent>
                      </Tooltip>
                    ),
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>
      ))}
      <div className="flex items-center justify-between">
        <div>
          {last?.nextBeforeDay && (
            <Button
              variant="outline"
              size="sm"
              disabled={loading}
              onClick={() => onOlder(last.nextBeforeDay!)}
            >
              {t("Load older", "加载更早")}
            </Button>
          )}
        </div>
        <div className="flex items-center gap-1 text-muted-foreground">
          <span>{t("Less", "少")}</span>
          {[0, 0.2, 0.4, 0.7, 1].map((level) => (
            <span
              key={level}
              className="size-3 rounded-sm"
              style={{
                backgroundColor: level
                  ? `rgba(8,145,178,${level})`
                  : "var(--muted)",
              }}
            />
          ))}
          <span>{t("More", "多")}</span>
        </div>
      </div>
    </div>
  );
}
