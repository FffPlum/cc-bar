import { useEffect, useId, useMemo, useState } from "react";
import { BarChart3, CircleHelp, RefreshCw } from "lucide-react";
import type {
  DashboardQuery,
  StatsQuery,
  UsageOverview,
  UsageService,
} from "@ccbar/host-api/window";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { InlineNotice } from "@/components/workspace";
import { errorMessage, useHost, useHostResource } from "@/host/host-context";
import { useTranslation } from "@/lib/i18n";
import { formatDate } from "@/lib/display";
import { DashboardPage } from "@/features/stats/dashboard-page";
import { ConversationsPage } from "@/features/stats/conversations-page";
import { ProjectsPage } from "@/features/stats/projects-page";
import { QuotaAnalyticsPage } from "@/features/stats/quota-analytics-page";
import { StatsViewDrawer } from "@/features/stats/stats-view-drawer";
import { civilInput } from "@/features/stats/dashboard-filters";
import { cn } from "@/lib/utils";

export type StatsView = "overview" | "conversations" | "projects" | "quota";
export interface StatsNavigation {
  conversationID?: string;
  conversationTitle?: string | null;
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
  const [navigationRequest, setNavigationRequest] = useState<StatsNavigation>(
    {},
  );
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [refreshPending, setRefreshPending] = useState(false);
  const refreshStatusID = useId();
  const overview = useHostResource<UsageOverview>(
    () => api.usageOverview({ range: "today", granularity: "day" }),
    usageDomains,
    [api],
  );
  const refreshing =
    refreshPending ||
    Boolean(!refreshError && !overview.error && overview.data?.status.scanning);

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
    if (refreshing) return;
    setRefreshPending(true);
    try {
      setRefreshError(null);
      await api.usageRefresh();
      await overview.reload();
    } catch (reason) {
      setRefreshError(errorMessage(reason));
    } finally {
      setRefreshPending(false);
    }
  };

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex shrink-0 items-center gap-3 border-b px-5 py-3.5">
        <BarChart3 className="size-4" aria-hidden="true" />
        <h1 className="text-[17px] font-bold tracking-[-0.4px]">
          {t("Usage statistics", "用量统计")}
        </h1>
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
        <span className="flex-1" />
        <div
          role="group"
          aria-label={t("Usage actions", "用量操作")}
          data-slot="button-group"
          className="inline-flex shrink-0 items-center"
        >
          <Button
            variant="outline"
            className="cc-number rounded-r-none text-[13px] focus-visible:z-10"
            onClick={() => void refresh()}
            aria-label={t("Refresh local usage", "刷新本机用量")}
            aria-describedby={refreshStatusID}
            aria-busy={refreshing}
            disabled={refreshing}
          >
            <span id={refreshStatusID} role="status">
              {refreshing ? (
                t("Refreshing…", "刷新中…")
              ) : refreshError || overview.error ? (
                t("Refresh failed", "刷新失败")
              ) : overview.data?.status.error ? (
                t("Refresh issue", "刷新异常")
              ) : (
                <RefreshAge lastScanAt={overview.data?.status.lastScanAt} />
              )}
            </span>
            <RefreshCw
              aria-hidden="true"
              data-icon="inline-end"
              className={cn(
                refreshing && "animate-spin motion-reduce:animate-none",
              )}
            />
          </Button>
          <StatsViewDrawer
            view={view}
            onView={changeView}
            className="-ml-px rounded-l-none"
          />
        </div>
      </div>
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
      <div className="min-h-0 flex-1">
        <DashboardPage
          service={service}
          onService={setService}
          title={
            view === "overview"
              ? t("Overview", "概览")
              : view === "conversations"
                ? t("Conversations", "对话")
                : view === "projects"
                  ? t("Projects", "项目")
                  : t("Quota", "额度")
          }
          filterMode={
            view === "overview" ? "full" : view === "quota" ? "quota" : "daily"
          }
          renderView={
            view === "overview"
              ? undefined
              : (query) =>
                  view === "quota" ? (
                    <QuotaAnalyticsPage
                      service={service}
                      visibleServices={overview.data?.visibleServices ?? []}
                    />
                  ) : (
                    <DailyStatsView
                      view={view}
                      filter={query}
                      services={overview.data?.visibleServices ?? []}
                      navigation={navigationRequest}
                      navigate={navigateWithinStats}
                      onNavigationConsumed={() => setNavigationRequest({})}
                    />
                  )
          }
        />
      </div>
    </div>
  );
}

function RefreshAge({ lastScanAt }: { lastScanAt?: string | null }) {
  const t = useTranslation();
  const [now, setNow] = useState(Date.now);
  const scannedAt = Date.parse(lastScanAt ?? "");

  useEffect(() => {
    if (!Number.isFinite(scannedAt)) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const update = () => {
      clearTimeout(timer);
      if (document.visibilityState === "hidden") return;
      const current = Date.now();
      setNow(current);
      // Update only this label at the next age boundary, without querying data.
      timer = setTimeout(
        update,
        60_000 - (Math.max(0, current - scannedAt) % 60_000),
      );
    };
    update();
    document.addEventListener("visibilitychange", update);
    window.addEventListener("focus", update);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", update);
      window.removeEventListener("focus", update);
    };
  }, [scannedAt]);

  if (!Number.isFinite(scannedAt)) return t("Not refreshed yet", "尚未刷新");
  const minutes = Math.max(0, Math.floor((now - scannedAt) / 60_000));
  if (minutes < 1) return t("Just refreshed", "刚刚刷新");
  if (minutes < 60) return t(`${minutes}m ago`, `${minutes}分钟前`);
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t(`${hours}h ago`, `${hours}小时前`);
  const days = Math.floor(hours / 24);
  return t(`${days}d ago`, `${days}天前`);
}

function DailyStatsView({
  view,
  filter,
  services,
  navigation,
  navigate,
  onNavigationConsumed,
}: {
  view: StatsView;
  filter: DashboardQuery;
  services: UsageService[];
  navigation: StatsNavigation;
  navigate: (view: StatsView, request: StatsNavigation) => void;
  onNavigationConsumed: () => void;
}) {
  const { bootstrap } = useHost();
  const today = civilInput(new Date(), bootstrap.timeZone).slice(0, 10);
  const { range, customFrom, customTo, service } = filter;
  const query = useMemo<StatsQuery>(() => {
    const base = {
      granularity: "day" as const,
      ...(service ? { service } : {}),
    };
    if (range === "custom" && customFrom && customTo) {
      return {
        ...base,
        range: "custom",
        customFrom: civilInput(new Date(customFrom), bootstrap.timeZone).slice(
          0,
          10,
        ),
        customTo: civilInput(
          new Date(Date.parse(customTo) - 1),
          bootstrap.timeZone,
        ).slice(0, 10),
      };
    }
    if (range === "last14") {
      const first = new Date(`${today}T00:00:00Z`);
      first.setUTCDate(first.getUTCDate() - 13);
      return {
        ...base,
        range: "custom",
        customFrom: first.toISOString().slice(0, 10),
        customTo: today,
      };
    }
    return {
      ...base,
      range: range === "last24h" || range === "custom" ? "today" : range,
    };
  }, [range, customFrom, customTo, service, today, bootstrap.timeZone]);

  return view === "conversations" ? (
    <ConversationsPage
      query={query}
      services={services}
      navigation={navigation}
      onNavigationConsumed={onNavigationConsumed}
    />
  ) : (
    <ProjectsPage
      query={query}
      navigation={navigation}
      navigate={navigate}
      onNavigationConsumed={onNavigationConsumed}
    />
  );
}
