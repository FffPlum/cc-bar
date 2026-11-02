import { useMemo, useState } from "react";
import {
  BarChart3,
  CircleHelp,
  RefreshCw,
  SlidersHorizontal,
} from "lucide-react";
import type {
  StatsGranularity,
  StatsQuery,
  StatsRange,
  UsageOverview,
  UsageService,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { InlineNotice } from "@/components/workspace";
import { Segmented } from "@/components/segmented";
import { ServiceIcon } from "@/components/service-icon";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { brandColor, formatDate, serviceDisplayName } from "@/lib/display";
import { DashboardPage } from "@/features/stats/dashboard-page";
import { ConversationsPage } from "@/features/stats/conversations-page";
import { ProjectsPage } from "@/features/stats/projects-page";
import { QuotaAnalyticsPage } from "@/features/stats/quota-analytics-page";
import { cn } from "@/lib/utils";

export type StatsView = "overview" | "conversations" | "projects" | "quota";
export interface StatsNavigation {
  conversationID?: string;
  projectKey?: string;
  unattributed?: boolean;
  conversationsByRank?: boolean;
  service?: UsageService;
}
const usageDomains = ["usage"] as const;

export function StatsPage() {
  const { api, bootstrap, navigate } = useHost();
  const t = useTranslation();
  const [view, setView] = useState<StatsView>("overview");
  const [service, setService] = useState<UsageService | undefined>();
  const [granularity, setGranularity] = useState<StatsGranularity>("day");
  const [range, setRange] = useState<StatsRange>("today");
  const [customFrom, setCustomFrom] = useState(() => inputDate(-7));
  const [customTo, setCustomTo] = useState(() => inputDate(0));
  const [navigationRequest, setNavigationRequest] = useState<StatsNavigation>(
    {},
  );
  const query = useMemo<StatsQuery>(
    () => ({
      range,
      granularity,
      ...(range === "custom" ? { customFrom, customTo } : {}),
      ...(service ? { service } : {}),
    }),
    [range, granularity, customFrom, customTo, service],
  );
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const overview = useHostResource<UsageOverview>(
    () => api.usageOverview(query),
    usageDomains,
    [api, range, granularity, customFrom, customTo, service],
  );

  const changeView = (next: StatsView) => {
    if (
      (next === "conversations" || next === "projects") &&
      service === "cursor"
    )
      setService(undefined);
    setView(next);
  };
  const navigateWithinStats = (next: StatsView, request: StatsNavigation) => {
    if (request.service) setService(request.service);
    setNavigationRequest(request);
    changeView(next);
  };
  const refresh = async () => {
    try {
      setRefreshError(null);
      await api.usageRefresh();
      await overview.reload();
    } catch (reason) {
      setRefreshError(errorMessage(reason));
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      {refreshError && <InlineNotice tone="error">{refreshError}</InlineNotice>}
      {overview.data?.status.historyNotice && (
        <InlineNotice>
          <span title={overview.data.status.error ?? undefined}>
            {overview.data.status.historyNotice.message}
            {overview.data.status.historyNotice.restoredAt && (
              <span className="cc-number ml-2">
                {t("Saved", "保存于")}{" "}
                {formatDate(
                  overview.data.status.historyNotice.restoredAt,
                  bootstrap.resolvedLanguage,
                  bootstrap.timeZone,
                  true,
                )}
              </span>
            )}
          </span>
          {overview.data.status.historyNotice.canOpenSettings && (
            <Button
              size="sm"
              variant="outline"
              onClick={() => void navigate({ page: "settings" })}
            >
              {t("Open Settings", "打开设置")}
            </Button>
          )}
        </InlineNotice>
      )}
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b px-5 py-3.5">
        {view === "overview" && (
          <BarChart3 className="size-4" aria-hidden="true" />
        )}
        <h1 className="text-[17px] font-bold tracking-[-0.4px]">
          {view === "overview"
            ? t("Usage statistics", "用量统计")
            : view === "conversations"
              ? t("Conversations", "对话")
              : view === "projects"
                ? t("Projects", "项目")
                : t("Quota", "额度")}
        </h1>
        {view === "overview" && (
          <Popover>
            <PopoverTrigger
              render={
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={t("About usage statistics", "关于用量统计")}
                />
              }
            >
              <CircleHelp />
            </PopoverTrigger>
            <PopoverContent align="start" className="w-72 p-3">
              {t(
                "Usage is based on available local logs and remote metering. Some historical requests may lack precise timestamps.",
                "用量来自可用的本机日志与远端计量，部分历史请求可能缺少精确时间。",
              )}
            </PopoverContent>
          </Popover>
        )}
        {overview.data?.status.scanning && (
          <span
            role="status"
            className="flex items-center gap-1.5 text-[11px] text-muted-foreground"
          >
            <RefreshCw className="size-3 animate-spin" />
            {t("Syncing usage…", "正在同步用量…")}
          </span>
        )}
        <span className="flex-1" />
        {(view === "conversations" || view === "overview") && (
          <>
            <span className="text-[11px] text-muted-foreground">
              {overview.data?.status.lastScanAt
                ? new Date(overview.data.status.lastScanAt).toLocaleString()
                : t("Waiting for data", "等待数据")}
            </span>
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={() => void refresh()}
              aria-label={t("Refresh local usage", "刷新本机用量")}
            >
              <RefreshCw
                className={cn(overview.data?.status.scanning && "animate-spin")}
              />
            </Button>
          </>
        )}
        <Popover>
          <PopoverTrigger
            render={
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label={t(
                  "Choose application and view",
                  "选择应用与统计视图",
                )}
              />
            }
          >
            <SlidersHorizontal />
          </PopoverTrigger>
          <PopoverContent className="w-[220px] p-3" align="start">
            <ViewOptions
              view={view}
              service={service}
              services={overview.data?.visibleServices ?? []}
              onView={changeView}
              onService={setService}
            />
          </PopoverContent>
        </Popover>
        {range === "custom" && view !== "quota" && view !== "overview" && (
          <div className="flex items-center gap-1">
            <Input
              type="date"
              aria-label={t("From", "起")}
              value={customFrom}
              max={customTo}
              onChange={(event) => setCustomFrom(event.target.value)}
              className="h-7 w-[142px] text-[11px]"
            />
            <span>–</span>
            <Input
              type="date"
              aria-label={t("To", "止")}
              value={customTo}
              min={customFrom}
              onChange={(event) => setCustomTo(event.target.value)}
              className="h-7 w-[142px] text-[11px]"
            />
          </div>
        )}
        {view !== "quota" && view !== "overview" && (
          <div className="flex flex-wrap items-center gap-1 max-[1200px]:w-full">
            <Segmented
              value={granularity}
              options={[
                { value: "day", label: t("Day", "日") },
                { value: "week", label: t("Week", "周") },
                { value: "month", label: t("Month", "月") },
              ]}
              onChange={(value) => {
                setGranularity(value);
                if (!rangesFor(value).includes(range))
                  setRange(rangesFor(value)[0]!);
              }}
              ariaLabel={t("Granularity", "统计粒度")}
            />
            <Segmented
              value={range}
              options={rangesFor(granularity).map((item) => ({
                value: item,
                label: rangeLabel(item, t),
              }))}
              onChange={setRange}
              ariaLabel={t("Time range", "时间范围")}
              className="max-w-full overflow-x-auto"
            />
          </div>
        )}
      </div>
      <div className="min-h-0 flex-1">
        {view === "overview" && (
          <DashboardPage service={service} onService={setService} />
        )}
        {view === "conversations" && (
          <ConversationsPage
            query={query}
            services={overview.data?.visibleServices ?? []}
            navigation={navigationRequest}
            onNavigationConsumed={() => setNavigationRequest({})}
          />
        )}
        {view === "projects" && (
          <ProjectsPage
            query={query}
            navigation={navigationRequest}
            navigate={navigateWithinStats}
            onNavigationConsumed={() => setNavigationRequest({})}
          />
        )}
        {view === "quota" && (
          <QuotaAnalyticsPage
            service={service}
            visibleServices={overview.data?.visibleServices ?? []}
          />
        )}
      </div>
    </div>
  );
}

function ViewOptions({
  view,
  service,
  services,
  onView,
  onService,
}: {
  view: StatsView;
  service?: UsageService;
  services: UsageService[];
  onView: (view: StatsView) => void;
  onService: (service?: UsageService) => void;
}) {
  const { settings, bootstrap } = useHost();
  const t = useTranslation();
  const views: { id: StatsView; label: string }[] = [
    { id: "overview", label: t("Overview", "概览") },
    { id: "conversations", label: t("Conversations", "对话") },
    { id: "projects", label: t("Projects", "项目") },
    { id: "quota", label: t("Quota", "额度") },
  ];
  return (
    <div className="space-y-4">
      <div>
        <p className="cc-tertiary mb-1 px-1 text-[10px] font-semibold uppercase">
          {t("Application", "应用")}
        </p>
        <ViewOption
          active={!service}
          label={t("All", "全部")}
          onClick={() => onService(undefined)}
        />
        {services
          .filter(
            (item) =>
              !(
                (view === "conversations" || view === "projects") &&
                item === "cursor"
              ),
          )
          .map((item) => (
            <ViewOption
              key={item}
              active={service === item}
              label={serviceDisplayName(item)}
              icon={
                <ServiceIcon
                  name={serviceDisplayName(item)}
                  color={brandColor(
                    item,
                    settings,
                    bootstrap.appearance === "dark",
                  )}
                  size={14}
                />
              }
              onClick={() => onService(item)}
            />
          ))}
      </div>
      <div>
        <p className="cc-tertiary mb-1 px-1 text-[10px] font-semibold uppercase">
          {t("View", "视图")}
        </p>
        {views.map((item) => (
          <ViewOption
            key={item.id}
            active={view === item.id}
            label={item.label}
            onClick={() => onView(item.id)}
          />
        ))}
      </div>
    </div>
  );
}

function ViewOption({
  active,
  label,
  icon,
  onClick,
}: {
  active: boolean;
  label: string;
  icon?: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={cn(
        "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12px]",
        active && "bg-blue-600 text-white",
      )}
    >
      {icon}
      {label}
    </button>
  );
}

export function rangesFor(granularity: StatsGranularity): StatsRange[] {
  if (granularity === "day")
    return [
      "today",
      "yesterday",
      "last7",
      "last30",
      "thisWeek",
      "thisMonth",
      "thisYear",
      "all",
      "custom",
    ];
  if (granularity === "week")
    return [
      "thisWeek",
      "lastWeek",
      "last4Weeks",
      "last12Weeks",
      "all",
      "custom",
    ];
  return ["thisMonth", "lastMonth", "last6Months", "thisYear", "all", "custom"];
}

function rangeLabel(
  range: StatsRange,
  t: (en: string, zh: string) => string,
): string {
  const labels: Record<StatsRange, [string, string]> = {
    today: ["Today", "今天"],
    yesterday: ["Yesterday", "昨天"],
    last7: ["7d", "7 天"],
    last30: ["30d", "30 天"],
    thisWeek: ["This week", "本周"],
    lastWeek: ["Last week", "上周"],
    last4Weeks: ["4w", "4 周"],
    last12Weeks: ["12w", "12 周"],
    thisMonth: ["This month", "本月"],
    lastMonth: ["Last month", "上月"],
    last6Months: ["6m", "6 个月"],
    thisYear: ["Year", "本年"],
    all: ["All", "全部"],
    custom: ["Custom", "自定义"],
  };
  return t(...labels[range]);
}

function inputDate(offsetDays: number): string {
  const date = new Date();
  date.setDate(date.getDate() + offsetDays);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}
