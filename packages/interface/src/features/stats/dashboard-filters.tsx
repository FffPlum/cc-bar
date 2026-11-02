import { useState } from "react";
import {
  CalendarDays,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  ListFilter,
} from "lucide-react";
import type {
  DashboardQuery,
  UsageDashboard,
  UsageService,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { HostIcon } from "@/components/host-icon";
import { ServiceIcon } from "@/components/service-icon";
import { useHost } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { brandColor, serviceDisplayName } from "@/lib/display";

const selectionLayer =
  "relative isolate before:absolute before:inset-0 before:-z-10 before:rounded before:bg-muted before:opacity-0 motion-safe:before:transition-opacity motion-safe:before:duration-150 motion-safe:before:ease-[ease]";
type Range = DashboardQuery["range"];
type Custom = { customFrom: string; customTo: string; followNow: boolean };
export function DashboardFilters({
  data,
  range,
  custom,
  service,
  sourceID,
  modelID,
  onRange,
  onService,
  onSource,
  onModel,
}: {
  data: Pick<UsageDashboard, "facets" | "resolvedRange">;
  range: Range;
  custom?: Custom;
  service?: UsageService;
  sourceID?: string;
  modelID?: string;
  onRange: (range: Range, custom?: Custom) => void;
  onService: (service?: UsageService) => void;
  onSource: (source?: string) => void;
  onModel: (model?: string) => void;
}) {
  const { bootstrap, settings } = useHost();
  const t = useTranslation();
  const presets: [Range, string][] = [
    ["today", t("Today", "当天")],
    ["last24h", t("Last 24 hours", "近 24 小时")],
    ["last7", t("Last 7 days", "近 7 天")],
    ["last14", t("Last 14 days", "近 14 天")],
    ["last30", t("Last 30 days", "近 30 天")],
    ["all", t("All", "全部")],
  ];
  const [dateOpen, setDateOpen] = useState(false);
  const [cascadeOpen, setCascadeOpen] = useState(false);
  const [focusedSource, setFocusedSource] = useState<string>();
  const now = civilInput(new Date(), bootstrap.timeZone);
  const [from, setFrom] = useState(now);
  const [to, setTo] = useState(now);
  const [followNow, setFollowNow] = useState(false);
  const [active, setActive] = useState<"from" | "to">("from");
  const [month, setMonth] = useState(now.slice(0, 7));
  const [error, setError] = useState(false);
  const [year, monthIndex] = month.split("-").map(Number);
  const first = new Date(Date.UTC(year!, monthIndex! - 1, 1));
  const cells = Array.from(
    { length: 42 },
    (_, i) =>
      new Date(Date.UTC(year!, monthIndex! - 1, 1 - first.getUTCDay() + i)),
  );
  const shift = (n: number) =>
    setMonth(
      new Date(Date.UTC(year!, monthIndex! - 1 + n, 1))
        .toISOString()
        .slice(0, 7),
    );
  const selectedSource = data.facets.sources.find((x) => x.id === sourceID);
  const chosenFacet = data.facets.sources.find((x) => x.id === focusedSource);
  const models = focusedSource
    ? (chosenFacet?.models ?? [])
    : data.facets.models;
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Popover
        open={dateOpen}
        onOpenChange={(open) => {
          setDateOpen(open);
          if (open) {
            const start = custom
              ? civilInput(new Date(custom.customFrom), bootstrap.timeZone)
              : civilInput(
                  new Date(data.resolvedRange.from),
                  bootstrap.timeZone,
                );
            const end =
              custom && !custom.followNow
                ? civilInput(new Date(custom.customTo), bootstrap.timeZone)
                : civilInput(
                    new Date(data.resolvedRange.to),
                    bootstrap.timeZone,
                  );
            setFrom(start);
            setTo(end);
            setMonth(start.slice(0, 7));
            setFollowNow(custom?.followNow ?? false);
            setError(false);
          }
        }}
      >
        <PopoverTrigger
          render={
            <Button
              variant="outline"
              size="sm"
              className="h-8 rounded-md text-[13px]"
            />
          }
        >
          <CalendarDays className="size-4" />{" "}
          {presets.find((x) => x[0] === range)?.[1] ?? t("Custom", "自定义")}{" "}
          <ChevronDown className="size-4" />
        </PopoverTrigger>
        <PopoverContent
          align="start"
          className="w-[650px] max-w-[calc(100vw-40px)] p-4"
        >
          <div className="flex flex-wrap gap-1 border-b pb-3">
            {presets.map(([id, label]) => (
              <Button
                key={id}
                size="sm"
                variant={range === id ? "secondary" : "outline"}
                onClick={() => {
                  onRange(id);
                  setDateOpen(false);
                }}
              >
                {label}
              </Button>
            ))}
          </div>
          <div className="grid grid-cols-2 gap-4 max-[700px]:grid-cols-1">
            <div className="space-y-2">
              <p className="text-muted-foreground">
                {t("Choose date and time", "支持日期与时间")}
              </p>
              {(
                [
                  ["from", from, setFrom, t("Start", "开始时间")],
                  ["to", to, setTo, t("End", "结束时间")],
                ] as const
              ).map(([id, value, set, label]) => (
                <label
                  key={id}
                  className={`block rounded-md border p-2 ${active === id ? "ring-1 ring-foreground" : ""}`}
                >
                  <span className="block text-muted-foreground">{label}</span>
                  <input
                    type="datetime-local"
                    disabled={id === "to" && followNow}
                    aria-label={label}
                    value={value}
                    onFocus={() => {
                      setActive(id);
                      if (value) setMonth(value.slice(0, 7));
                    }}
                    onChange={(e) => set(e.target.value)}
                    className="mt-1 w-full bg-transparent outline-none"
                  />
                </label>
              ))}
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={followNow}
                  onChange={(e) => setFollowNow(e.target.checked)}
                />
                {t("End follows now", "结束时间跟随当前时刻")}
              </label>
              {error && (
                <p role="alert" className="text-destructive">
                  {t("Check the dates and times.", "请检查日期和时间。")}
                </p>
              )}
              <div className="flex justify-end gap-2">
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setDateOpen(false)}
                >
                  {t("Cancel", "取消")}
                </Button>
                <Button
                  size="sm"
                  onClick={() => {
                    const start = civilToISO(from, bootstrap.timeZone);
                    const end = followNow
                      ? new Date().toISOString()
                      : civilToISO(to, bootstrap.timeZone);
                    if (!start || !end || start >= end) {
                      setError(true);
                      return;
                    }
                    onRange("custom", {
                      customFrom: start,
                      customTo: end,
                      followNow,
                    });
                    setDateOpen(false);
                  }}
                >
                  {t("Apply", "确定")}
                </Button>
              </div>
            </div>
            <div className="rounded-md bg-muted p-2">
              <div className="flex items-center justify-between">
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={t("Previous month", "上个月")}
                  onClick={() => shift(-1)}
                >
                  <ChevronLeft />
                </Button>
                <strong>
                  {new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
                    year: "numeric",
                    month: "long",
                    timeZone: "UTC",
                  }).format(first)}
                </strong>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={t("Next month", "下个月")}
                  onClick={() => shift(1)}
                >
                  <ChevronRight />
                </Button>
              </div>
              <div className="grid grid-cols-7 text-center">
                {Array.from({ length: 7 }, (_, i) => (
                  <span key={i} className="py-1 text-muted-foreground">
                    {new Intl.DateTimeFormat(bootstrap.resolvedLanguage, {
                      weekday: "short",
                      timeZone: "UTC",
                    }).format(new Date(Date.UTC(2024, 0, 7 + i)))}
                  </span>
                ))}
                {cells.map((day) => {
                  const value = day.toISOString().slice(0, 10);
                  return (
                    <button
                      key={value}
                      type="button"
                      aria-label={value}
                      aria-pressed={
                        value === from.slice(0, 10) || value === to.slice(0, 10)
                      }
                      className={`rounded py-1.5 ${value.slice(0, 7) !== month ? "text-muted-foreground" : ""} ${value === from.slice(0, 10) || value === to.slice(0, 10) ? "bg-foreground text-background" : "hover:bg-background"}`}
                      onClick={() => {
                        const current = active === "from" ? from : to;
                        (active === "from" ? setFrom : setTo)(
                          `${value}T${current.slice(11) || "00:00"}`,
                        );
                        setMonth(value.slice(0, 7));
                      }}
                    >
                      {day.getUTCDate()}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
        </PopoverContent>
      </Popover>
      <div className="flex h-8 items-center rounded-md border p-0.5 text-[13px]">
        <button
          type="button"
          aria-pressed={!service}
          onClick={() => onService(undefined)}
          className={`inline-flex h-full items-center justify-center rounded px-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring motion-safe:transition-opacity motion-safe:duration-150 motion-safe:ease-[ease] [@media(hover:hover)_and_(pointer:fine)]:hover:opacity-75 ${selectionLayer} ${!service ? "before:opacity-100 font-medium" : ""}`}
        >
          {t("All", "全部")}
        </button>
        {data.facets.services.map((item) => {
          const app = bootstrap.sidebarApplications.find(
            (x) => x.usageService === item.id,
          );
          const name = serviceDisplayName(item.id as UsageService);
          return (
            <button
              type="button"
              key={item.id}
              title={name}
              aria-label={name}
              aria-pressed={service === item.id}
              onClick={() => onService(item.id as UsageService)}
              className={`inline-flex h-full items-center justify-center rounded px-1 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring motion-safe:transition-opacity motion-safe:duration-150 motion-safe:ease-[ease] [@media(hover:hover)_and_(pointer:fine)]:hover:opacity-75 ${selectionLayer} ${service === item.id ? "before:opacity-100" : ""}`}
            >
              {app ? (
                <HostIcon
                  icon={app.icon}
                  name={name}
                  dark={bootstrap.appearance === "dark"}
                  size={16}
                />
              ) : (
                <ServiceIcon
                  name={name}
                  color={brandColor(
                    item.id as UsageService,
                    settings,
                    bootstrap.appearance === "dark",
                  )}
                  size={16}
                />
              )}
            </button>
          );
        })}
      </div>
      <Popover
        open={cascadeOpen}
        onOpenChange={(open) => {
          setCascadeOpen(open);
          if (open) setFocusedSource(sourceID);
        }}
      >
        <PopoverTrigger
          render={
            <Button
              variant="outline"
              size="sm"
              className="h-8 rounded-md text-[13px]"
            />
          }
        >
          <ListFilter className="size-4" />{" "}
          {selectedSource?.title ?? t("Provider / model", "供应商 / 模型")}
          {modelID ? ` · ${modelID}` : ""} <ChevronDown className="size-4" />
        </PopoverTrigger>
        <PopoverContent
          align="start"
          className="w-[480px] max-w-[calc(100vw-40px)] p-1"
        >
          <div className="grid grid-cols-2 gap-1">
            <div className="border-r pr-1">
              <button
                className={`w-full rounded px-2 py-2 text-left [@media(hover:hover)_and_(pointer:fine)]:hover:opacity-75 ${selectionLayer} ${!focusedSource ? "before:opacity-100" : ""}`}
                aria-pressed={!focusedSource}
                onClick={() => {
                  setFocusedSource(undefined);
                }}
              >
                {!sourceID && "✓ "} {t("All providers", "全部供应商")}{" "}
                <span className="float-right">›</span>
              </button>
              {data.facets.sources.map((x) => (
                <button
                  key={x.id}
                  className={`w-full rounded px-2 py-2 text-left [@media(hover:hover)_and_(pointer:fine)]:hover:opacity-75 ${selectionLayer} ${focusedSource === x.id ? "before:opacity-100" : ""}`}
                  aria-pressed={focusedSource === x.id}
                  onClick={() => {
                    setFocusedSource(x.id);
                  }}
                >
                  {sourceID === x.id && "✓ "}
                  {x.title}
                  <span className="float-right">
                    {x.requestCount.toLocaleString()} ›
                  </span>
                </button>
              ))}
            </div>
            <div>
              <button
                className="w-full rounded px-2 py-2 text-left hover:bg-muted"
                onClick={() => {
                  onSource(focusedSource);
                  onModel(undefined);
                  setCascadeOpen(false);
                }}
              >
                {!modelID && "✓ "} {t("All models", "全部模型")}
              </button>
              {models.map((x) => (
                <button
                  key={x.id}
                  className="w-full rounded px-2 py-2 text-left hover:bg-muted"
                  onClick={() => {
                    onSource(focusedSource);
                    onModel(x.id);
                    setCascadeOpen(false);
                  }}
                >
                  {modelID === x.id && "✓ "}
                  {x.title}
                  <span className="float-right">
                    {x.requestCount.toLocaleString()}
                  </span>
                </button>
              ))}
            </div>
          </div>
        </PopoverContent>
      </Popover>
    </div>
  );
}
export function civilInput(date: Date, timeZone: string): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(date)
      .map((x) => [x.type, x.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}
export function civilToISO(value: string, timeZone: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  const p = match.slice(1).map(Number);
  const target = Date.UTC(p[0]!, p[1]! - 1, p[2]!, p[3]!, p[4]!);
  if (new Date(target).toISOString().slice(0, 16) !== value) return null;
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const civil = (ms: number) => {
    const v = Object.fromEntries(
      formatter.formatToParts(new Date(ms)).map((x) => [x.type, x.value]),
    );
    return Date.UTC(+v.year!, +v.month! - 1, +v.day!, +v.hour!, +v.minute!);
  };
  let result = target;
  for (let i = 0; i < 3; i++) result += target - civil(result);
  return civil(result) === target ? new Date(result).toISOString() : null;
}
